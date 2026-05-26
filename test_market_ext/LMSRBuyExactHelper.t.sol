pragma solidity ^0.5.1;

import {ERC20Mintable} from "openzeppelin-solidity/contracts/token/ERC20/ERC20Mintable.sol";
import {ConditionalTokens} from "@gnosis.pm/conditional-tokens-contracts/contracts/ConditionalTokens.sol";
import {SafeMath} from "openzeppelin-solidity/contracts/math/SafeMath.sol";
import {CappedLMSRMarketMaker} from "../src_market_ext/CappedLMSRMarketMaker.sol";
import {CappedLMSRDeterministicFactory} from "../src_market_ext/CappedLMSRDeterministicFactory.sol";
import {LMSRBuyExactHelper} from "../src_market_ext/LMSRBuyExactHelper.sol";
import {Whitelist} from "market-makers/Whitelist.sol";

/// @dev Foundry HEVM cheatcode address.
interface Vm {
    function assume(bool) external;
}

/// @dev Test collateral token.
contract TestCollateral2 is ERC20Mintable {}

/// @dev Delegatecall proxy that mimics a smart-account user in production.
///      `execute` runs `target`'s code in this proxy's storage/balance context — i.e., the
///      pool will see msg.sender = proxy, and the proxy's ERC20 approval is what's used.
contract UserProxy {
    function execute(address target, bytes memory data) public returns (bytes memory) {
        // solium-disable-next-line security/no-low-level-calls
        (bool ok, bytes memory ret) = target.delegatecall(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        return ret;
    }

    function doApprove(address token, address spender, uint256 amount) public {
        // solium-disable-next-line security/no-low-level-calls
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spender, amount));
        require(ok, "approve failed");
    }

    // ERC1155 receiver hooks — required for the CTF to transfer outcome tokens into this account.
    function onERC1155Received(address, address, uint256, uint256, bytes memory) public pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] memory, uint256[] memory, bytes memory)
        public
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }
}

contract InstrumentedLMSRBuyExactHelper is LMSRBuyExactHelper {
    using SafeMath for uint256;

    function calcBuyExactCollateralWithCorrectionCount(
        address pool,
        uint256 yesBalance,
        uint256 noBalance,
        uint8 outcomeIndex,
        uint256 collateralIn,
        uint64 surchargeRate
    ) public view returns (uint256 outcomeTokens, uint256 correctionCount) {
        require(outcomeIndex < 2, "binary only");
        require(collateralIn > 0, "collateralIn zero");
        require(CappedLMSRMarketMaker(pool).atomicOutcomeSlotCount() == 2, "not binary market");

        uint64 totalFee = _totalFee(pool, surchargeRate);
        uint256 netCostTarget = collateralIn.mul(uint256(FEE_RANGE)) / (uint256(FEE_RANGE) + uint256(totalFee));
        if (netCostTarget == 0) return (0, 0);

        uint256 qInitial = _closedFormQ(
            CappedLMSRMarketMaker(pool).funding(),
            (outcomeIndex == 0) ? yesBalance : noBalance,
            (outcomeIndex == 0) ? noBalance : yesBalance,
            netCostTarget
        );
        if (qInitial == 0) return (0, 0);

        return _postCorrectWithCorrectionCount(pool, outcomeIndex, qInitial, collateralIn, totalFee);
    }

    function _postCorrectWithCorrectionCount(
        address pool,
        uint8 outcomeIndex,
        uint256 qInitial,
        uint256 collateralIn,
        uint64 totalFee
    ) internal view returns (uint256 outcomeTokens, uint256 correctionCount) {
        int256[] memory amounts = new int256[](2);
        uint256 q = qInitial;
        amounts[outcomeIndex] = int256(q);
        for (uint256 i = 0; i <= MAX_CORRECTION_ITERATIONS; i++) {
            (bool done, uint256 newQ) = _correctOnce(pool, amounts, outcomeIndex, q, collateralIn, totalFee);
            if (done) return (newQ, correctionCount);
            correctionCount++;
            q = newQ;
            amounts[outcomeIndex] = int256(q);
        }
        revert("correction did not converge");
    }
}

contract LMSRBuyExactHelperTest {
    /*
     *  Constants
     */
    uint256 public constant ONE = 0x10000000000000000;
    uint64 public constant FEE_RANGE = 10 ** 18;
    address public constant HEVM_ADDRESS = 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D;

    event BuyExactCorrectionCount(uint256 correctionCount);

    // Test contracts
    TestCollateral2 public collateral;
    ConditionalTokens public ctf;
    CappedLMSRDeterministicFactory public factory;
    LMSRBuyExactHelper public lib;
    InstrumentedLMSRBuyExactHelper public instrumentedLib;
    uint256 internal saltNonce;

    address public oracle;

    // -------- setup --------
    constructor() public {
        collateral = new TestCollateral2();
        ctf = new ConditionalTokens();
        factory = new CappedLMSRDeterministicFactory();
        lib = new LMSRBuyExactHelper();
        instrumentedLib = new InstrumentedLMSRBuyExactHelper();
        oracle = address(this);

        collateral.mint(address(this), 10 ** 30);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes memory) public pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] memory, uint256[] memory, bytes memory)
        public
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    // -------- assertion helpers --------
    function assertTrue(bool condition, string memory message) internal pure {
        if (!condition) {
            revert(string(abi.encodePacked("FAIL: ", message)));
        }
    }

    function assertLe(uint256 a, uint256 b, string memory message) internal pure {
        if (a > b) {
            revert(string(abi.encodePacked("FAIL(<=): ", message, " a=", _u2s(a), " b=", _u2s(b))));
        }
    }

    function assertEq(uint256 a, uint256 b, string memory message) internal pure {
        if (a != b) {
            revert(string(abi.encodePacked("FAIL(==): ", message, " a=", _u2s(a), " b=", _u2s(b))));
        }
    }

    function assertEqInt(int256 a, int256 b, string memory message) internal pure {
        if (a != b) {
            revert(message);
        }
    }

    function _u2s(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    // -------- market construction --------
    function createBinaryMarket(uint256 funding, uint64 fee, uint256 maxCost)
        internal
        returns (CappedLMSRMarketMaker mm, uint256 yesPositionId, uint256 noPositionId)
    {
        bytes32 conditionId = _prepareCondition(funding);
        mm = _deployMarket(conditionId, funding, fee, maxCost);
        (yesPositionId, noPositionId) = _derivePositionIds(conditionId);
    }

    function _prepareCondition(uint256 funding) internal returns (bytes32 conditionId) {
        bytes32 questionId = keccak256(abi.encodePacked(block.timestamp, funding, saltNonce));
        ctf.prepareCondition(oracle, questionId, 2);
        conditionId = ctf.getConditionId(oracle, questionId, 2);
    }

    function _deployMarket(bytes32 conditionId, uint256 funding, uint64 fee, uint256 maxCost)
        internal
        returns (CappedLMSRMarketMaker)
    {
        bytes32[] memory conditionIds = new bytes32[](1);
        conditionIds[0] = conditionId;
        collateral.approve(address(factory), funding);
        return factory.create2CappedLMSRMarketMaker(
            saltNonce++, ctf, collateral, conditionIds, fee, Whitelist(0), funding, maxCost
        );
    }

    function _derivePositionIds(bytes32 conditionId) internal view returns (uint256 yesId, uint256 noId) {
        // Binary: indexSet 1 = YES, 2 = NO. getPositionId = keccak256(collateral || collectionId).
        bytes32 yesCollection = ctf.getCollectionId(bytes32(0), conditionId, 1);
        bytes32 noCollection = ctf.getCollectionId(bytes32(0), conditionId, 2);
        yesId = uint256(keccak256(abi.encodePacked(address(collateral), yesCollection)));
        noId = uint256(keccak256(abi.encodePacked(address(collateral), noCollection)));
    }

    /// @dev Compute (cost + fee) using the POOL's own `calcMarketFee` by temporarily swapping
    ///      the fee rate to `baseFee + surcharge`. This mirrors `tradeWithSurcharge`'s effective
    ///      rate exactly — no hand-rolled fee math that could drift from the contract's.
    function _totalCostViaPool(CappedLMSRMarketMaker mm, uint256 outcomeTokens, uint8 outcomeIndex, uint64 surcharge)
        internal
        returns (uint256 totalCost, int256 rawCost)
    {
        int256[] memory amounts = new int256[](2);
        amounts[outcomeIndex] = int256(outcomeTokens);
        rawCost = mm.calcNetCost(amounts);
        if (rawCost <= 0) return (0, rawCost);

        uint64 originalFee = mm.fee();
        uint64 combinedFee = originalFee + surcharge;
        mm.pause();
        mm.changeFee(combinedFee);
        mm.resume();

        uint256 feeAmt = mm.calcMarketFee(uint256(rawCost));

        mm.pause();
        mm.changeFee(originalFee);
        mm.resume();

        totalCost = uint256(rawCost) + feeAmt;
    }

    function _assertPureNetCostMatchesPool(
        CappedLMSRMarketMaker mm,
        uint256 yesBal,
        uint256 noBal,
        int256 yesAmount,
        int256 noAmount
    ) internal view {
        int256[] memory amounts = new int256[](2);
        amounts[0] = yesAmount;
        amounts[1] = noAmount;
        int256 poolCost = mm.calcNetCost(amounts);
        int256 pureCost = lib.calcNetCost(mm.funding(), yesBal, noBal, yesAmount, noAmount, uint64(0));
        assertEqInt(pureCost, poolCost, "pure calcNetCost mismatch");
    }

    function _assertPureTotalNetCostMatchesPool(
        CappedLMSRMarketMaker mm,
        uint256 yesBal,
        uint256 noBal,
        int256 yesAmount,
        int256 noAmount,
        uint64 totalFee
    ) internal {
        int256[] memory amounts = new int256[](2);
        amounts[0] = yesAmount;
        amounts[1] = noAmount;
        int256 rawCost = mm.calcNetCost(amounts);

        uint64 originalFee = mm.fee();
        mm.pause();
        mm.changeFee(totalFee);
        mm.resume();
        uint256 feeAmount = rawCost < 0 ? mm.calcMarketFee(uint256(-rawCost)) : mm.calcMarketFee(uint256(rawCost));
        mm.pause();
        mm.changeFee(originalFee);
        mm.resume();

        int256 expectedCost = rawCost + int256(feeAmount);
        int256 pureCost = lib.calcNetCost(mm.funding(), yesBal, noBal, yesAmount, noAmount, totalFee);
        assertEqInt(pureCost, expectedCost, "pure fee-inclusive calcNetCost mismatch");
    }

    // ============================================================
    // Deterministic tests
    // ============================================================

    /// @notice Fresh market, buy YES with a simple collateralIn. Verify invariant cost+fee <= collateralIn.
    function test_buyExact_freshMarket_yes() public {
        uint256 funding = 1000 * ONE;
        uint256 collateralIn = 100 * ONE;
        (CappedLMSRMarketMaker mm, uint256 yesId, uint256 noId) = createBinaryMarket(funding, 0, 0);

        uint256 yesBal = ctf.balanceOf(address(mm), yesId);
        uint256 noBal = ctf.balanceOf(address(mm), noId);
        uint256 q = lib.calcBuyExactCollateral(address(mm), yesBal, noBal, 0, collateralIn, 0);

        assertTrue(q > 0, "computed zero tokens");
        (uint256 totalCost,) = _totalCostViaPool(mm, q, 0, 0);
        assertLe(totalCost, collateralIn, "overspend!");
    }

    /// @notice Same, outcome NO.
    function test_buyExact_freshMarket_no() public {
        uint256 funding = 1000 * ONE;
        uint256 collateralIn = 50 * ONE;
        (CappedLMSRMarketMaker mm, uint256 yesId, uint256 noId) = createBinaryMarket(funding, 0, 0);

        uint256 yesBal = ctf.balanceOf(address(mm), yesId);
        uint256 noBal = ctf.balanceOf(address(mm), noId);
        uint256 q = lib.calcBuyExactCollateral(address(mm), yesBal, noBal, 1, collateralIn, 0);

        assertTrue(q > 0, "computed zero tokens");
        (uint256 totalCost,) = _totalCostViaPool(mm, q, 1, 0);
        assertLe(totalCost, collateralIn, "overspend!");
    }

    /// @notice After prior trade shifted balances, exact-buy still satisfies invariant.
    function test_buyExact_afterOtherTrade() public {
        uint256 funding = 1000 * ONE;
        (CappedLMSRMarketMaker mm, uint256 yesId, uint256 noId) = createBinaryMarket(funding, 0, 0);
        collateral.approve(address(mm), uint256(-1));

        // Prior trade: buy 200 NO, shifts balances
        int256[] memory priorAmts = new int256[](2);
        priorAmts[1] = int256(200 * ONE);
        mm.trade(priorAmts, 0);

        uint256 yesBal = ctf.balanceOf(address(mm), yesId);
        uint256 noBal = ctf.balanceOf(address(mm), noId);
        uint256 q = lib.calcBuyExactCollateral(address(mm), yesBal, noBal, 0, 100 * ONE, 0);

        assertTrue(q > 0, "computed zero tokens");
        (uint256 totalCost,) = _totalCostViaPool(mm, q, 0, 0);
        assertLe(totalCost, 100 * ONE, "overspend after prior trade");
    }

    /// @notice With surcharge, the invariant still holds using the combined (baseFee + surcharge) rate.
    function test_buyExact_withSurcharge() public {
        uint256 funding = 1000 * ONE;
        uint64 surcharge = uint64(5 * 10 ** 16); // 5%
        (CappedLMSRMarketMaker mm, uint256 yesId, uint256 noId) = createBinaryMarket(funding, 0, 0);

        uint256 yesBal = ctf.balanceOf(address(mm), yesId);
        uint256 noBal = ctf.balanceOf(address(mm), noId);
        uint256 q = lib.calcBuyExactCollateral(address(mm), yesBal, noBal, 0, 100 * ONE, surcharge);

        assertTrue(q > 0, "computed zero tokens");
        (uint256 totalCost,) = _totalCostViaPool(mm, q, 0, surcharge);
        assertLe(totalCost, 100 * ONE, "overspend with surcharge");
    }

    /// @notice With a non-zero base fee on the pool, invariant still holds.
    function test_buyExact_withBaseFee() public {
        uint256 funding = 1000 * ONE;
        uint64 baseFee = uint64(2 * 10 ** 16); // 2%
        (CappedLMSRMarketMaker mm, uint256 yesId, uint256 noId) = createBinaryMarket(funding, baseFee, 0);

        uint256 yesBal = ctf.balanceOf(address(mm), yesId);
        uint256 noBal = ctf.balanceOf(address(mm), noId);
        uint256 q = lib.calcBuyExactCollateral(address(mm), yesBal, noBal, 0, 100 * ONE, 0);

        assertTrue(q > 0, "computed zero tokens");
        (uint256 totalCost,) = _totalCostViaPool(mm, q, 0, 0);
        assertLe(totalCost, 100 * ONE, "overspend with base fee");
    }

    function test_calcNetCostPure_matchesPool_freshMarket() public {
        uint256 funding = 1000 * ONE;
        (CappedLMSRMarketMaker mm, uint256 yesId, uint256 noId) = createBinaryMarket(funding, 0, 0);
        uint256 yesBal = ctf.balanceOf(address(mm), yesId);
        uint256 noBal = ctf.balanceOf(address(mm), noId);

        _assertPureNetCostMatchesPool(mm, yesBal, noBal, int256(100 * ONE), 0);
        _assertPureNetCostMatchesPool(mm, yesBal, noBal, 0, int256(75 * ONE));
        _assertPureNetCostMatchesPool(mm, yesBal, noBal, -int256(25 * ONE), 0);
        _assertPureNetCostMatchesPool(mm, yesBal, noBal, 0, -int256(25 * ONE));
    }

    function test_calcNetCostPure_matchesPool_afterTrade() public {
        uint256 funding = 1000 * ONE;
        (CappedLMSRMarketMaker mm, uint256 yesId, uint256 noId) = createBinaryMarket(funding, 0, 0);
        collateral.approve(address(mm), uint256(-1));

        int256[] memory priorAmts = new int256[](2);
        priorAmts[1] = int256(200 * ONE);
        mm.trade(priorAmts, 0);

        uint256 yesBal = ctf.balanceOf(address(mm), yesId);
        uint256 noBal = ctf.balanceOf(address(mm), noId);
        _assertPureNetCostMatchesPool(mm, yesBal, noBal, int256(100 * ONE), 0);
        _assertPureNetCostMatchesPool(mm, yesBal, noBal, 0, int256(100 * ONE));
        _assertPureNetCostMatchesPool(mm, yesBal, noBal, -int256(25 * ONE), 0);
    }

    function test_calcNetCostPure_withFee_matchesPool() public {
        uint256 funding = 1000 * ONE;
        uint64 baseFee = uint64(2 * 10 ** 16);
        uint64 surcharge = uint64(5 * 10 ** 16);
        uint64 totalFee = baseFee + surcharge;
        (CappedLMSRMarketMaker mm, uint256 yesId, uint256 noId) = createBinaryMarket(funding, baseFee, 0);

        uint256 yesBal = ctf.balanceOf(address(mm), yesId);
        uint256 noBal = ctf.balanceOf(address(mm), noId);
        _assertPureTotalNetCostMatchesPool(mm, yesBal, noBal, int256(100 * ONE), 0, totalFee);
        _assertPureTotalNetCostMatchesPool(mm, yesBal, noBal, 0, int256(75 * ONE), totalFee);
        _assertPureTotalNetCostMatchesPool(mm, yesBal, noBal, -int256(25 * ONE), 0, totalFee);
        _assertPureTotalNetCostMatchesPool(mm, yesBal, noBal, 0, -int256(25 * ONE), uint64(FEE_RANGE));
    }

    /// @notice Full execution via delegatecall, coverCollateral=false (power-user path).
    ///         User spends `cost+fee` (≤ collateralIn) — residual stays with them.
    function test_buyExact_exec_coverFalse_residualStaysWithUser() public {
        uint256 funding = 1000 * ONE;
        uint256 collateralIn = 100 * ONE;
        (CappedLMSRMarketMaker mm, uint256 yesId, uint256 noId) = createBinaryMarket(funding, 0, 0);

        UserProxy proxy = new UserProxy();
        collateral.transfer(address(proxy), collateralIn);
        proxy.doApprove(address(collateral), address(mm), collateralIn);

        uint256 balBefore = collateral.balanceOf(address(proxy));

        bytes memory data = abi.encodeWithSignature(
            "buyExactCollateral(address,uint256,uint256,uint8,uint256,uint256,uint64,bool)",
            address(mm),
            yesId,
            noId,
            uint8(0),
            collateralIn,
            uint256(0),
            uint64(0),
            false
        );
        bytes memory ret = proxy.execute(address(lib), data);
        uint256 qTokens = abi.decode(ret, (uint256));

        uint256 spent = balBefore - collateral.balanceOf(address(proxy));
        assertTrue(qTokens > 0, "no tokens delivered");
        assertLe(spent, collateralIn, "coverFalse: overspent");
        // Same fresh-market dust regime as the coverTrue test: closed-form q₀ is
        // feasible at iteration 0, so residual is bounded by `_closedFormQ`'s
        // LowerBound rounding only — `1024 + funding/2^60` wei. This proves
        // coverFalse actually behaved differently from coverTrue: the contract
        // pulled only `cost+fee`, not the full `collateralIn`.
        uint256 residual = collateralIn - spent;
        assertLe(residual, 1024 + (funding >> 60), "coverFalse: residual exceeded fresh-market floor");
        assertEq(ctf.balanceOf(address(proxy), yesId), qTokens, "user did not receive q tokens");
    }

    /// @notice Full execution via delegatecall, coverCollateral=true (retail UX path).
    ///         User spends EXACTLY collateralIn — dust fee goes to pool.
    function test_buyExact_exec_coverTrue_exactSpend() public {
        uint256 funding = 1000 * ONE;
        uint256 collateralIn = 100 * ONE;
        (CappedLMSRMarketMaker mm, uint256 yesId, uint256 noId) = createBinaryMarket(funding, 0, 0);

        UserProxy proxy = new UserProxy();
        collateral.transfer(address(proxy), collateralIn);
        proxy.doApprove(address(collateral), address(mm), collateralIn);

        uint256 userBalBefore = collateral.balanceOf(address(proxy));
        uint256 poolBalBefore = collateral.balanceOf(address(mm));

        bytes memory data = abi.encodeWithSignature(
            "buyExactCollateral(address,uint256,uint256,uint8,uint256,uint256,uint64,bool)",
            address(mm),
            yesId,
            noId,
            uint8(0),
            collateralIn,
            uint256(0),
            uint64(0),
            true
        );
        bytes memory ret = proxy.execute(address(lib), data);
        uint256 qTokens = abi.decode(ret, (uint256));

        uint256 spent = userBalBefore - collateral.balanceOf(address(proxy));
        // The pool forwards `cost+fee` to the CTF during `splitPosition`; only the dust fee
        // (collateralIn - cost - fee) remains on the pool as collateral.
        uint256 poolDust = collateral.balanceOf(address(mm)) - poolBalBefore;

        assertTrue(qTokens > 0, "no tokens delivered");
        // Retail UX invariant: user spent EXACTLY collateralIn.
        assertEq(spent, collateralIn, "coverTrue: exact-spend violated");
        // Empirical dust bound for THIS deterministic state — fresh symmetric market,
        // fee=0, where the closed-form q₀ is already feasible and `_postCorrect`
        // returns at iteration 0 without invoking `_estimateDecrement`. In that
        // regime dust comes only from `_closedFormQ`'s LowerBound rounding and is
        // bounded by Fixed192x64Math's 4-ULP floor → `1024 + funding/2^60` wei.
        // The helper's *general* provable bound across all states is much looser
        // (see `_estimateDecrement` NatSpec: `collateralIn/2000 + 2·ε(f)·(1+φ) + 1`);
        // this assertion is a regression sentinel on the happy-path, not a proof
        // of the worst-case bound.
        uint256 dustBound = 1024 + (funding >> 60);
        assertLe(poolDust, dustBound, "coverTrue: dust exceeded fresh-market floor");
        assertEq(ctf.balanceOf(address(proxy), yesId), qTokens, "user did not receive q tokens");
    }

    /// @notice minOutcomeTokens enforcement: if lib computes q < minimum, trade reverts.
    function test_buyExact_slippageRevert() public {
        uint256 funding = 1000 * ONE;
        uint256 collateralIn = 100 * ONE;
        (CappedLMSRMarketMaker mm, uint256 yesId, uint256 noId) = createBinaryMarket(funding, 0, 0);

        UserProxy proxy = new UserProxy();
        collateral.transfer(address(proxy), collateralIn);
        proxy.doApprove(address(collateral), address(mm), collateralIn);

        // Set minOutcomeTokens unrealistically high: 10x the funding → impossible
        bytes memory data = abi.encodeWithSignature(
            "buyExactCollateral(address,uint256,uint256,uint8,uint256,uint256,uint64,bool)",
            address(mm),
            yesId,
            noId,
            uint8(0),
            collateralIn,
            funding * 10,
            uint64(0),
            false
        );
        (bool ok, bytes memory ret) =
            address(proxy).call(abi.encodeWithSignature("execute(address,bytes)", address(lib), data));
        _assertRevertReason(ok, ret, "slippage");
    }

    /// @notice Exact-buy respects the pool's maxCostPerTx cap.
    function test_buyExact_respectsMaxCostPerTx() public {
        uint256 funding = 1000 * ONE;
        uint256 maxCost = 5 * ONE; // very tight cap
        (CappedLMSRMarketMaker mm, uint256 yesId, uint256 noId) = createBinaryMarket(funding, 0, maxCost);

        UserProxy proxy = new UserProxy();
        collateral.transfer(address(proxy), 100 * ONE);
        proxy.doApprove(address(collateral), address(mm), 100 * ONE);

        bytes memory data = abi.encodeWithSignature(
            "buyExactCollateral(address,uint256,uint256,uint8,uint256,uint256,uint64,bool)",
            address(mm),
            yesId,
            noId,
            uint8(0),
            100 * ONE,
            uint256(0),
            uint64(0),
            false
        );
        (bool ok, bytes memory ret) =
            address(proxy).call(abi.encodeWithSignature("execute(address,bytes)", address(lib), data));
        _assertRevertReason(ok, ret, "trade cost exceeds maxCostPerTx");
    }

    /// @notice Budget far exceeding pool funding reverts (rather than silently
    ///         returning garbage). Bound: `Fixed192x64Math.pow2` requires its
    ///         argument ≤ `MAX_POWER ≈ 192 · ONE_FP`, and `_closedFormQ` feeds
    ///         it `netCostTarget · ONE_FP / funding`. With
    ///         `netCostTarget = collateralIn · FEE_RANGE / (FEE_RANGE + φ)`,
    ///         the effective `collateralIn` ceiling is `~192 · funding · (1+φ)`:
    ///         ~192× at fee=0, ~346× at 80% fee. Test exercises the fee=0 case.
    function test_buyExact_amountTooLargeReverts() public {
        uint256 funding = 10 * ONE;
        (CappedLMSRMarketMaker mm, uint256 yesId, uint256 noId) = createBinaryMarket(funding, 0, 0);
        uint256 yesBal = ctf.balanceOf(address(mm), yesId);
        uint256 noBal = ctf.balanceOf(address(mm), noId);

        // Budget 300× funding — comfortably above the ~192× cutoff at fee=0.
        uint256 collateralIn = 300 * funding;
        bytes memory data = abi.encodeWithSignature(
            "calcBuyExactCollateral(address,uint256,uint256,uint8,uint256,uint64)",
            address(mm),
            yesBal,
            noBal,
            uint8(0),
            collateralIn,
            uint64(0)
        );
        (bool ok,) = address(lib).staticcall(data);
        assertTrue(!ok, "expected revert for amount above ~192x funding");
    }

    /// @notice Just below the ~192× cutoff, the helper still produces a valid
    ///         q — confirms the library bound doesn't over-reject realistic
    ///         budgets.
    function test_buyExact_belowAmountTooLargeBoundary() public {
        uint256 funding = 10 * ONE;
        (CappedLMSRMarketMaker mm, uint256 yesId, uint256 noId) = createBinaryMarket(funding, 0, 0);

        // 100× funding — well below the ~192× cutoff. Should produce a valid q.
        uint256 q = _callCalcLib(mm, yesId, noId, uint8(0), 100 * funding, uint64(0));
        assertTrue(q > 0, "100x funding should be feasible");
    }

    /// @notice Monotonic: larger collateralIn → non-decreasing q, same market state.
    function test_buyExact_monotonicInCollateral() public {
        uint256 funding = 1000 * ONE;
        (CappedLMSRMarketMaker mm, uint256 yesId, uint256 noId) = createBinaryMarket(funding, 0, 0);

        uint256 yesBal = ctf.balanceOf(address(mm), yesId);
        uint256 noBal = ctf.balanceOf(address(mm), noId);

        uint256 qSmall = lib.calcBuyExactCollateral(address(mm), yesBal, noBal, 0, 10 * ONE, 0);
        uint256 qMid = lib.calcBuyExactCollateral(address(mm), yesBal, noBal, 0, 100 * ONE, 0);
        uint256 qBig = lib.calcBuyExactCollateral(address(mm), yesBal, noBal, 0, 500 * ONE, 0);

        assertLe(qSmall, qMid, "monotonic small->mid");
        assertLe(qMid, qBig, "monotonic mid->big");
    }

    // ============================================================
    // Fuzz tests — the critical algorithm safety net
    // ============================================================

    /// @notice Call `calcBuyExactCollateral` via staticcall and return `q`.
    ///         If the helper *reverts*, this fails the test loudly with the
    ///         decoded revert reason — reverts are never swallowed. `q == 0`
    ///         is a legitimate "no feasible q for this budget" output and
    ///         stays a skip at the call sites.
    function _callCalcLib(
        CappedLMSRMarketMaker mm,
        uint256 yesId,
        uint256 noId,
        uint8 outcomeIndex,
        uint256 collateralIn,
        uint64 surcharge
    ) internal view returns (uint256 q) {
        uint256 yesBal = ctf.balanceOf(address(mm), yesId);
        uint256 noBal = ctf.balanceOf(address(mm), noId);
        bytes memory data = abi.encodeWithSignature(
            "calcBuyExactCollateral(address,uint256,uint256,uint8,uint256,uint64)",
            address(mm),
            yesBal,
            noBal,
            outcomeIndex,
            collateralIn,
            surcharge
        );
        (bool ok, bytes memory ret) = address(lib).staticcall(data);
        if (!ok) {
            _failWithCalcLibRevert(ret, yesBal, noBal, outcomeIndex, collateralIn, surcharge);
        }
        if (ret.length == 32) q = abi.decode(ret, (uint256));
    }

    /// @dev Builds a detailed failure message with the decoded revert reason
    ///      and the input state that triggered it, then `revert()`s so the
    ///      fuzz harness reports the full context as the failing counterexample.
    ///      Split out of `_callCalcLib` to keep that function under the
    ///      solc-0.5 stack depth limit.
    function _failWithCalcLibRevert(
        bytes memory ret,
        uint256 yesBal,
        uint256 noBal,
        uint8 outcomeIndex,
        uint256 collateralIn,
        uint64 surcharge
    ) internal pure {
        string memory reason = _decodeRevertReason(ret);
        bytes memory head = bytes(reason).length == 0
            ? bytes("calcBuyExactCollateral reverted: <no-reason>")
            : abi.encodePacked("calcBuyExactCollateral reverted: '", reason, "'");
        revert(
            string(
                abi.encodePacked(
                    head,
                    " yesBal=",
                    _u2s(yesBal),
                    " noBal=",
                    _u2s(noBal),
                    " outcome=",
                    _u2s(uint256(outcomeIndex)),
                    " collateralIn=",
                    _u2s(collateralIn),
                    " surcharge=",
                    _u2s(uint256(surcharge))
                )
            )
        );
    }

    function _doPriorTrade(CappedLMSRMarketMaker mm, uint8 priorOutcomeIndex, uint256 priorAmount)
        internal
        returns (bool)
    {
        if (priorAmount == 0) return true;
        collateral.approve(address(mm), uint256(-1));
        int256[] memory priorAmts = new int256[](2);
        priorAmts[priorOutcomeIndex] = int256(priorAmount);
        (bool ok,) = address(mm).call(abi.encodeWithSignature("trade(int256[],int256)", priorAmts, int256(0)));
        return ok;
    }

    function testFuzz_calcNetCostPure_matchesPool(
        uint256 fundingSeed,
        uint256 yesPrimeSeed,
        uint256 noPrimeSeed,
        uint256 amountSeed,
        bool outcomeIndexBool,
        uint64 totalFeeSeed
    ) public {
        uint256 funding = (fundingSeed % (10 ** 24 - 10 ** 9)) + 10 ** 9;
        (CappedLMSRMarketMaker mm, uint256 yesId, uint256 noId) = createBinaryMarket(funding, 0, 0);
        Vm(HEVM_ADDRESS).assume(_doPriorTrade(mm, 0, yesPrimeSeed % (funding / 4)));
        Vm(HEVM_ADDRESS).assume(_doPriorTrade(mm, 1, noPrimeSeed % (funding / 4)));

        uint256 yesBal = ctf.balanceOf(address(mm), yesId);
        uint256 noBal = ctf.balanceOf(address(mm), noId);
        uint256 amount = amountSeed % (funding / 4);
        uint64 totalFee = uint64(uint256(totalFeeSeed) % uint256(FEE_RANGE));
        if (outcomeIndexBool) {
            _assertPureNetCostMatchesPool(mm, yesBal, noBal, int256(amount), 0);
            _assertPureTotalNetCostMatchesPool(mm, yesBal, noBal, int256(amount), 0, totalFee);
            _assertPureNetCostMatchesPool(mm, yesBal, noBal, -int256(amount), 0);
            _assertPureTotalNetCostMatchesPool(mm, yesBal, noBal, -int256(amount), 0, totalFee);
        } else {
            _assertPureNetCostMatchesPool(mm, yesBal, noBal, 0, int256(amount));
            _assertPureTotalNetCostMatchesPool(mm, yesBal, noBal, 0, int256(amount), totalFee);
            _assertPureNetCostMatchesPool(mm, yesBal, noBal, 0, -int256(amount));
            _assertPureTotalNetCostMatchesPool(mm, yesBal, noBal, 0, -int256(amount), totalFee);
        }
    }

    /// @notice INVARIANT (near-maximal): q + SLACK overspends ⇒ q is within SLACK of the true optimum.
    /// forge-config: market_ext.fuzz.runs = 100000
    /// forge-config: market_ext.fuzz.show-logs = true
    function testFuzz_nearMaximal(uint256 fundingSeed, uint256 collateralInSeed, bool outcomeIndexBool) public {
        uint256 funding = (fundingSeed % (10 ** 24 - 10 ** 9)) + 10 ** 9;
        uint256 collateralIn = (collateralInSeed % funding) + (funding / 1000);
        uint8 outcomeIndex = outcomeIndexBool ? 0 : 1;

        (CappedLMSRMarketMaker mm, uint256 yesId, uint256 noId) = createBinaryMarket(funding, 0, 0);
        uint256 q = _callCalcLib(mm, yesId, noId, outcomeIndex, collateralIn, uint64(0));
        if (q == 0) return;

        // Try q + SLACK and verify it exceeds collateralIn. SLACK = 16 wei + 1ppm of funding.
        uint256 slack = 16 + funding / 1_000_000;
        (uint256 totalCost,) = _totalCostViaPool(mm, q, outcomeIndex, 0);
        assertLe(totalCost, collateralIn, "fuzz: q itself should be feasible");
        (uint256 plusCost,) = _totalCostViaPool(mm, q + slack, outcomeIndex, 0);
        assertTrue(plusCost > collateralIn, "fuzz: q+slack should overspend (not near-maximal)");
    }

    /// @notice ROUND-TRIP (fee=0): thin entry point — fuzzes funding, balance priming,
    ///         collateralIn, and outcomeIndex. fee=0 keeps the parameter space tight
    ///         so the fuzz samples each axis densely. Delegates to `_runRoundTrip`.
    /// forge-config: market_ext.fuzz.runs = 100000
    /// forge-config: market_ext.fuzz.show-logs = true
    function testFuzz_roundTrip(
        uint256 fundingSeed,
        uint256 yesPrimeSeed,
        uint256 noPrimeSeed,
        uint256 collateralInSeed,
        bool outcomeIndex
    ) public {
        uint256 funding = (fundingSeed % (10 ** 24 - 10 ** 9)) + 10 ** 9;
        _runRoundTrip(
            funding,
            yesPrimeSeed % (10 * funding),
            noPrimeSeed % (10 * funding),
            (collateralInSeed % funding) + (funding / 1000),
            outcomeIndex ? 0 : 1,
            uint64(0),
            uint64(0)
        );
    }

    /// @notice ROUND-TRIP with fees: same invariants over the full fee path. Adds
    ///         baseFee + surcharge to the fuzz axes. Delegates to `_runRoundTrip`.
    /// forge-config: market_ext.fuzz.runs = 100000
    function testFuzz_roundTrip_withFees(
        uint256 fundingSeed,
        uint256 yesPrimeSeed,
        uint256 noPrimeSeed,
        uint256 collateralInSeed,
        bool outcomeIndex,
        uint64 baseFeeSeed,
        uint64 surchargeSeed
    ) public {
        // Cap total fee at 80% of FEE_RANGE — tradeWithSurcharge enforces ≤ FEE_RANGE and
        // higher rates make realistic collateralIn yield q==0 too often.
        uint64 totalFeeCap = uint64(uint256(FEE_RANGE) * 8 / 10);
        uint64 baseFee = uint64(uint256(baseFeeSeed) % totalFeeCap);
        uint64 surcharge = uint64(uint256(surchargeSeed) % (uint256(totalFeeCap) - uint256(baseFee)));
        uint256 funding = (fundingSeed % (10 ** 24 - 10 ** 9)) + 10 ** 9;

        _runRoundTrip(
            funding,
            yesPrimeSeed % (funding / 4),
            noPrimeSeed % (funding / 4),
            (collateralInSeed % (funding / 4)) + (funding / 1000),
            outcomeIndex ? 0 : 1,
            baseFee,
            surcharge
        );
    }

    /// @dev Shared round-trip body. For the given pool state + budget + fees,
    ///      computes q via `calcBuyExactCollateral` and asserts three invariants:
    ///        (1) OVERSPEND          — `T̃(q) ≤ collateralIn`
    ///        (2) TIGHTNESS (below)  — `collateralIn − T̃(q) ≤ 3 · plateau + (fees ? 16 : 0)`
    ///        (3) EXECUTION DELTAS   — running the trade actually moves balances
    ///                                 by exactly `T̃(q)` collateral and `q` tokens
    function _runRoundTrip(
        uint256 funding,
        uint256 yesPrime,
        uint256 noPrime,
        uint256 collateralIn,
        uint8 outcomeIndex,
        uint64 baseFee,
        uint64 surcharge
    ) internal {
        (CappedLMSRMarketMaker mm, uint256 yesId, uint256 noId) = createBinaryMarket(funding, baseFee, 0);
        collateral.approve(address(mm), uint256(-1));
        // Prime balances; either prior trade may revert at extreme values, which are outside this fuzz case.
        Vm(HEVM_ADDRESS).assume(_doPriorTrade(mm, 0, yesPrime));
        Vm(HEVM_ADDRESS).assume(_doPriorTrade(mm, 1, noPrime));

        uint256 q = _callCalcLib(mm, yesId, noId, outcomeIndex, collateralIn, surcharge);
        if (q == 0) return;

        uint256 outcomeId = (outcomeIndex == 0) ? yesId : noId;
        _assertCorrectionInstrumentation(mm, yesId, noId, outcomeIndex, q, surcharge, collateralIn);
        _assertRoundTripInvariants(mm, outcomeId, outcomeIndex, q, surcharge, collateralIn);
    }

    function _assertCorrectionInstrumentation(
        CappedLMSRMarketMaker mm,
        uint256 yesId,
        uint256 noId,
        uint8 outcomeIndex,
        uint256 q,
        uint64 surcharge,
        uint256 collateralIn
    ) internal {
        (uint256 instrumentedQ, uint256 correctionCount) = instrumentedLib.calcBuyExactCollateralWithCorrectionCount(
            address(mm),
            ctf.balanceOf(address(mm), yesId),
            ctf.balanceOf(address(mm), noId),
            outcomeIndex,
            collateralIn,
            surcharge
        );
        assertEq(instrumentedQ, q, "round-trip: instrumented q mismatch");
        emit BuyExactCorrectionCount(correctionCount);
        assertLe(correctionCount, 5, "round-trip: correction count exceeded max");
    }

    /// @dev Asserts the round-trip invariants for (q, outcomeIndex, collateralIn)
    ///      on the given pool:
    ///        (1) OVERSPEND — `T̃(q) ≤ collateralIn` (the on-chain trade gate).
    ///        (2) TIGHTNESS — `collateralIn − T̃(q) ≤ collateralIn/2000
    ///            + 2·(1024 + funding/2^60)·(1+φ) + 1 wei`. This is the
    ///            provable upper bound from `_estimateDecrement`'s per-iter
    ///            cost cap (collateralIn/4000) plus the closed-form's initial
    ///            `2·ε(f)·(1+φ)` overshoot, both scaled by the fee multiplier.
    ///            For collateralIn ≥ 4000·ε(f) (any sensible trade), this is
    ///            < 0.1% of collateralIn at fees up to 80% — strictly under
    ///            the documented dust budget.
    ///        (3) EXECUTION DELTAS — executing the trade actually moves
    ///            balances by exactly `T̃(q)` collateral and `q` outcome tokens.
    function _assertRoundTripInvariants(
        CappedLMSRMarketMaker mm,
        uint256 outcomeId,
        uint8 outcomeIndex,
        uint256 q,
        uint64 surcharge,
        uint256 collateralIn
    ) internal {
        (uint256 totalCost, int256 rawCost) = _totalCostViaPool(mm, q, outcomeIndex, surcharge);
        assertTrue(rawCost > 0, "round-trip: cost should be positive for buy");

        // (1) OVERSPEND. An on-chain trade would revert if violated.
        assertLe(totalCost, collateralIn, "round-trip: OVERSPEND");

        // (2) TIGHTNESS. Provable: at the iteration where `_postCorrect` returns
        // done=true, `T̃(q_{prev}) > C` and `T̃(q) ≤ C`, so leftover < per-iter
        // cost movement ≤ cap = C/2000 collateral. Plus 2·ε(f)·(1+φ) for the
        // two UpperBound `calcNetCost` evaluations and +1 wei for fee-mul rounding.
        // Relative bound: ≤ C/2000 = 0.05% for any trade ≫ ε(f).
        uint64 totalFee = mm.fee() + surcharge;
        uint256 epsilon = 1024 + (mm.funding() >> 60);
        uint256 epsilonPlusFee = 2 * epsilon * (uint256(FEE_RANGE) + uint256(totalFee)) / uint256(FEE_RANGE);
        uint256 slack = collateralIn / 2000 + epsilonPlusFee + 1;
        assertLe(collateralIn - totalCost, slack, "round-trip: q too conservative");

        // (3) EXECUTION DELTAS — execute and confirm observable balance changes.
        _assertTradeDeltas(mm, outcomeId, outcomeIndex, q, totalCost, surcharge);
    }

    /// @dev Execute the trade via `tradeWithSurcharge(amounts, max, surcharge, false)`
    ///      and assert: caller spent exactly `expectedSpend` collateral, and received
    ///      exactly `q` outcome-`outcomeIndex` tokens. `collateralLimit = int256.max`
    ///      so the helper's tightness — not the limit — is what's exercised.
    function _assertTradeDeltas(
        CappedLMSRMarketMaker mm,
        uint256 outcomeId,
        uint8 outcomeIndex,
        uint256 q,
        uint256 expectedSpend,
        uint64 surcharge
    ) internal {
        uint256 collatBefore = collateral.balanceOf(address(this));
        uint256 outcomeBefore = ctf.balanceOf(address(this), outcomeId);

        int256[] memory amounts = new int256[](2);
        amounts[outcomeIndex] = int256(q);
        mm.tradeWithSurcharge(amounts, int256(uint256(-1) >> 1), surcharge, false);

        uint256 spent = collatBefore - collateral.balanceOf(address(this));
        uint256 gained = ctf.balanceOf(address(this), outcomeId) - outcomeBefore;
        assertEq(spent, expectedSpend, "trade delta: spent != expected cost+fee");
        assertEq(gained, q, "trade delta: outcome tokens received != q");
    }

    /// @dev Decode an `Error(string)` revert return-data blob (selector
    ///      0x08c379a0). Returns "" for non-string reverts. Used by the
    ///      loud-fuzz harness (`_failWithCalcLibRevert`) and the
    ///      "amount too large for pool" boundary test.
    function _decodeRevertReason(bytes memory ret) internal pure returns (string memory) {
        if (ret.length < 4 + 32 + 32) return "";
        bytes4 sel;
        assembly {
            sel := mload(add(ret, 32))
        }
        if (sel != 0x08c379a0) return "";
        bytes memory inner = new bytes(ret.length - 4);
        for (uint256 i = 0; i < inner.length; i++) {
            inner[i] = ret[i + 4];
        }
        return abi.decode(inner, (string));
    }

    function _assertRevertReason(bool ok, bytes memory ret, string memory expected) internal pure {
        assertTrue(!ok, "expected revert");
        string memory reason = _decodeRevertReason(ret);
        assertTrue(
            keccak256(bytes(reason)) == keccak256(bytes(expected)),
            string(abi.encodePacked("wrong revert reason: ", reason))
        );
    }
}
