pragma solidity ^0.5.1;

import {LMSRBuyExactMath} from "../src_market_ext/LMSRBuyExactMath.sol";

/// @dev Pure-library unit tests. These cover the math primitives in isolation —
///      the integration tests in `CappedLMSRBuyExact.t.sol` exercise the
///      convergence loop against a live pool's `calcNetCost`/`calcMarginalPrice`.
contract LMSRBuyExactMathTest {
    uint256 public constant ONE = 0x10000000000000000;
    uint64 public constant FEE_RANGE = 10 ** 18;

    // -------- assertion helpers --------
    function assertTrue(bool condition, string memory message) internal pure {
        if (!condition) revert(string(abi.encodePacked("FAIL: ", message)));
    }

    function assertEq(uint256 a, uint256 b, string memory message) internal pure {
        if (a != b) {
            revert(string(abi.encodePacked("FAIL(==): ", message, " a=", _u2s(a), " b=", _u2s(b))));
        }
    }

    function assertLe(uint256 a, uint256 b, string memory message) internal pure {
        if (a > b) {
            revert(string(abi.encodePacked("FAIL(<=): ", message, " a=", _u2s(a), " b=", _u2s(b))));
        }
    }

    function _u2s(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) { digits++; temp /= 10; }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    // -------- totalFee --------

    function test_totalFee_zeroSurchargeReturnsBase() public pure {
        assertEq(uint256(LMSRBuyExactMath.totalFee(uint64(2 * 10 ** 16), 0)), uint256(2 * 10 ** 16), "base only");
    }

    function test_totalFee_sumsCorrectly() public pure {
        uint64 total = LMSRBuyExactMath.totalFee(uint64(2 * 10 ** 16), uint64(3 * 10 ** 16));
        assertEq(uint256(total), uint256(5 * 10 ** 16), "2% + 3%");
    }

    function test_totalFee_revertsOnOverflow() public {
        bytes memory data = abi.encodeWithSignature(
            "_totalFeeWrap(uint64,uint64)",
            FEE_RANGE / 2 + 1,
            FEE_RANGE / 2 + 1
        );
        (bool ok,) = address(this).call(data);
        assertTrue(!ok, "should revert on fee overflow");
    }

    /// @dev Reachable wrapper so the revert can be observed via low-level call (the
    ///      pure-library function on its own is `internal` — wrapping it is the
    ///      cleanest way to assert revert semantics from test code).
    function _totalFeeWrap(uint64 baseFee, uint64 surcharge) external pure returns (uint64) {
        return LMSRBuyExactMath.totalFee(baseFee, surcharge);
    }

    // -------- netCostTargetFromCollateralIn --------

    function test_netCostTarget_feeZeroIsIdentity() public pure {
        assertEq(
            LMSRBuyExactMath.netCostTargetFromCollateralIn(123 * ONE, 0),
            123 * ONE,
            "fee=0 → target=collateralIn"
        );
    }

    function test_netCostTarget_stripsFee() public pure {
        // 100 * (1 + 0.05) ⇒ collateralIn=105, fee=5%, netCostTarget≈100.
        // 100*1e18 / (1e18 + 5e16) = 100*1e18 / 1.05e18 ≈ 95.238...% of 105*ONE
        // Equivalent: 105*ONE / 1.05 = 100*ONE
        uint256 collateralIn = 105 * ONE;
        uint64 fee = uint64(5 * 10 ** 16);
        uint256 expected = 100 * ONE;
        // Allow off-by-one due to integer division.
        uint256 result = LMSRBuyExactMath.netCostTargetFromCollateralIn(collateralIn, fee);
        assertTrue(
            result == expected || result == expected - 1,
            "stripsFee within rounding"
        );
    }

    function test_netCostTarget_smallInputsRoundToZero() public pure {
        // collateralIn = 1 wei, totalFee very high → target rounds to 0.
        assertEq(
            LMSRBuyExactMath.netCostTargetFromCollateralIn(1, FEE_RANGE),
            0,
            "1 wei vs 100% fee → 0"
        );
    }

    // -------- closedFormQ --------

    function test_closedFormQ_freshSymmetricMarket() public pure {
        // Fresh balanced market: changeFunding(amount) splits the collateral into
        // `amount` YES + `amount` NO held by the pool, so bSelf = bOther = funding
        // for any outcome. Sanity-check: q > 0 and monotone in netCostTarget.
        uint256 funding = 1000 * ONE;
        uint256 qSmall = LMSRBuyExactMath.closedFormQ(funding, funding, funding, 10 * ONE);
        uint256 qLarge = LMSRBuyExactMath.closedFormQ(funding, funding, funding, 100 * ONE);
        assertTrue(qSmall > 0, "small q positive");
        assertTrue(qLarge > qSmall, "monotone in netCostTarget");
    }

    function test_closedFormQ_zeroNetCostTargetReturnsZero() public pure {
        uint256 q = LMSRBuyExactMath.closedFormQ(1000 * ONE, 0, 0, 0);
        assertEq(q, 0, "netCostTarget=0 → q=0");
    }

    function test_closedFormQ_higherBSelfMeansMoreTokensForSameTarget() public pure {
        // In `LMSRMarketMaker.calcNetCost`, otExpNums[i] = trade[i] - bSelf, so a
        // higher pool inventory of self-tokens (bSelf) shifts the exponent down ⇒
        // cheaper per token ⇒ for the same netCostTarget, q is larger. This is the
        // direction the algorithm depends on: buying on the side the pool is heavy
        // in is cheap. Doubling bSelf should never decrease q.
        uint256 funding = 1000 * ONE;
        uint256 target = 50 * ONE;
        uint256 baseline = LMSRBuyExactMath.closedFormQ(funding, funding, funding, target);
        uint256 heavySelf =
            LMSRBuyExactMath.closedFormQ(funding, 2 * funding, funding, target);
        assertTrue(heavySelf >= baseline, "higher bSelf ⇒ cheaper per token ⇒ q does not shrink");
        assertTrue(heavySelf > baseline, "strictly larger q when self side is deeper");
    }

    function test_closedFormQ_revertsOnZeroFunding() public {
        bytes memory data = abi.encodeWithSignature(
            "_closedFormQWrap(uint256,uint256,uint256,uint256)",
            uint256(0), uint256(0), uint256(0), uint256(1)
        );
        (bool ok,) = address(this).call(data);
        assertTrue(!ok, "funding=0 should revert");
    }

    function _closedFormQWrap(uint256 funding, uint256 bSelf, uint256 bOther, uint256 netCostTarget)
        external
        pure
        returns (uint256)
    {
        return LMSRBuyExactMath.closedFormQ(funding, bSelf, bOther, netCostTarget);
    }

    // -------- estimateDecrement --------

    function test_estimateDecrement_zeroPriceTreatedAsOne() public pure {
        // priceFP=0 should be sanitised to 1 (avoid div-by-zero), still returns
        // a finite dq (with the +2 safety margin).
        uint256 dq = LMSRBuyExactMath.estimateDecrement(0, 1, 0);
        assertTrue(dq > 0, "dq finite even at priceFP=0");
    }

    function test_estimateDecrement_largerOvershootBiggerDecrement() public pure {
        uint256 priceFP = ONE / 2; // 0.5
        uint256 small = LMSRBuyExactMath.estimateDecrement(priceFP, 100, 0);
        uint256 big = LMSRBuyExactMath.estimateDecrement(priceFP, 10_000, 0);
        assertTrue(big > small, "monotone in overshoot");
    }

    function test_estimateDecrement_feeShrinksDq() public pure {
        // With higher fee, the same overshoot maps to a smaller dq because we divide by (1+fee).
        uint256 priceFP = ONE / 2;
        uint256 noFee = LMSRBuyExactMath.estimateDecrement(priceFP, 1000, 0);
        uint256 withFee = LMSRBuyExactMath.estimateDecrement(priceFP, 1000, uint64(5 * 10 ** 16));
        assertTrue(withFee < noFee, "fee shrinks dq");
    }
}
