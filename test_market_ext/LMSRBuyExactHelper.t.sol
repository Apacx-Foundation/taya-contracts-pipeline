pragma solidity ^0.5.1;

import {ERC20Mintable} from "openzeppelin-solidity/contracts/token/ERC20/ERC20Mintable.sol";
import {ConditionalTokens} from "@gnosis.pm/conditional-tokens-contracts/contracts/ConditionalTokens.sol";
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

contract LMSRBuyExactHelperTest {
    /*
     *  Constants
     */
    uint256 public constant ONE = 0x10000000000000000;
    uint64 public constant FEE_RANGE = 10 ** 18;
    address public constant HEVM_ADDRESS = 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D;

    // Test contracts
    TestCollateral2 public collateral;
    ConditionalTokens public ctf;
    CappedLMSRDeterministicFactory public factory;
    LMSRBuyExactHelper public lib;
    uint256 internal saltNonce;

    address public oracle;

    // -------- setup --------
    constructor() public {
        collateral = new TestCollateral2();
        ctf = new ConditionalTokens();
        factory = new CappedLMSRDeterministicFactory();
        lib = new LMSRBuyExactHelper();
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
        // Dust fee bound: well below 1% of collateralIn for reasonable pool sizes.
        assertLe(poolDust, collateralIn / 100, "coverTrue: dust larger than sanity bound");
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
        (bool ok,) = address(proxy).call(abi.encodeWithSignature("execute(address,bytes)", address(lib), data));
        assertTrue(!ok, "should revert when minOutcomeTokens unreachable");
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
        (bool ok,) = address(proxy).call(abi.encodeWithSignature("execute(address,bytes)", address(lib), data));
        assertTrue(!ok, "should revert when computed trade exceeds maxCostPerTx");
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

    function _callCalcLib(
        CappedLMSRMarketMaker mm,
        uint256 yesId,
        uint256 noId,
        uint8 outcomeIndex,
        uint256 collateralIn,
        uint64 surcharge
    ) internal view returns (bool ok, uint256 q) {
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
        bytes memory ret;
        (ok, ret) = address(lib).staticcall(data);
        if (ok && ret.length == 32) q = abi.decode(ret, (uint256));
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

    /// @notice INVARIANT (critical): for any reasonable inputs, cost(q) + fee(q) <= collateralIn.
    ///         An on-chain trade with collateralLimit = collateralIn would revert otherwise.
    function testFuzz_neverOverspend(
        uint256 fundingSeed,
        uint256 collateralInSeed,
        uint256 priorTradeSeed,
        uint8 outcomeIndex,
        uint8 priorOutcomeIndex,
        uint64 surchargeSeed
    ) public {
        _runNoOverspend(
            (fundingSeed % (10 ** 24 - 10 ** 6)) + 10 ** 6,
            collateralInSeed,
            priorTradeSeed,
            outcomeIndex % 2,
            priorOutcomeIndex % 2,
            uint64(uint256(surchargeSeed) % (uint256(FEE_RANGE) / 2))
        );
    }

    function _runNoOverspend(
        uint256 funding,
        uint256 collateralInSeed,
        uint256 priorTradeSeed,
        uint8 outcomeIndex,
        uint8 priorOutcomeIndex,
        uint64 surcharge
    ) internal {
        uint256 collateralIn = (collateralInSeed % (2 * funding)) + 1;
        uint256 priorAmount = priorTradeSeed % (10 * funding);

        CappedLMSRMarketMaker mm;
        uint256 yesId;
        uint256 noId;
        (mm, yesId, noId) = createBinaryMarket(funding, 0, 0);
        if (!_doPriorTrade(mm, priorOutcomeIndex, priorAmount)) return;

        (bool ok, uint256 q) = _callCalcLib(mm, yesId, noId, outcomeIndex, collateralIn, surcharge);
        if (!ok || q == 0) return;

        _assertInvariantHolds(mm, q, outcomeIndex, surcharge, collateralIn);
    }

    function _assertInvariantHolds(
        CappedLMSRMarketMaker mm,
        uint256 q,
        uint8 outcomeIndex,
        uint64 surcharge,
        uint256 collateralIn
    ) internal {
        (uint256 totalCost, int256 rawCost) = _totalCostViaPool(mm, q, outcomeIndex, surcharge);
        assertTrue(rawCost > 0, "fuzz: cost should be positive for buy");
        assertLe(totalCost, collateralIn, "fuzz: OVERSPEND");
    }

    /// @notice INVARIANT (near-maximal): q + SLACK overspends ⇒ q is within SLACK of the true optimum.
    function testFuzz_nearMaximal(uint256 fundingSeed, uint256 collateralInSeed, uint8 outcomeIndex) public {
        uint256 funding = (fundingSeed % (10 ** 24 - 10 ** 9)) + 10 ** 9;
        uint256 collateralIn = (collateralInSeed % funding) + (funding / 1000);
        outcomeIndex = outcomeIndex % 2;

        (CappedLMSRMarketMaker mm, uint256 yesId, uint256 noId) = createBinaryMarket(funding, 0, 0);
        (bool ok, uint256 q) = _callCalcLib(mm, yesId, noId, outcomeIndex, collateralIn, uint64(0));
        if (!ok || q == 0) return;

        // Try q + SLACK and verify it exceeds collateralIn. SLACK = 16 wei + 1ppm of funding.
        uint256 slack = 16 + funding / 1_000_000;
        (uint256 plusCost,) = _totalCostViaPool(mm, q + slack, outcomeIndex, 0);
        assertTrue(plusCost > collateralIn, "fuzz: q+slack should overspend (not near-maximal)");
    }

    /// @notice ROUND-TRIP (fee=0): given arbitrary pool state and collateralIn,
    ///           q = lib.calcBuyExactCollateral(mm, yesBal, noBal, 0, collateralIn, 0)
    ///         ⇒ mm.calcNetCost([q, 0]) ≈ collateralIn, with residual bounded by
    ///           Fixed192x64Math's relative precision.
    ///         Binds the lib's output directly to the pool's `calcNetCost` — any drift means
    ///         the closed-form inverse disagrees with the on-chain cost function.
    /// forge-config: market_ext.fuzz.runs = 5000
    /// forge-config: market_ext.fuzz.show-logs = true
    function testFuzz_roundTrip(
        uint256 fundingSeed,
        uint256 yesPrimeSeed,
        uint256 noPrimeSeed,
        uint256 collateralInSeed
    ) public {
        uint256 funding = (fundingSeed % (10 ** 24 - 10 ** 9)) + 10 ** 9;
        // collateralIn floored at funding/1000 so the absolute slack doesn't dominate q.
        uint256 collateralIn = (collateralInSeed % funding) + (funding / 1000);

        CappedLMSRMarketMaker mm;
        uint256 yesId;
        uint256 noId;
        (mm, yesId, noId) = createBinaryMarket(funding, 0, 0);

        // Prime balances to arbitrary state. Either prior trade may revert for extreme values —
        // acceptable, just skip that fuzz run.
        collateral.approve(address(mm), uint256(-1));
        if (!_doPriorTrade(mm, 0, yesPrimeSeed % funding)) return;
        if (!_doPriorTrade(mm, 1, noPrimeSeed % funding)) return;

        (bool ok, uint256 q) = _callCalcLib(mm, yesId, noId, 0, collateralIn, uint64(0));
        if (!ok || q == 0) return;

        int256[] memory amounts = new int256[](2);
        amounts[0] = int256(q);
        int256 cost = mm.calcNetCost(amounts);
        assertTrue(cost > 0, "round-trip: cost should be positive for buy");

        // Invariant 1 (hard): cost <= collateralIn. Overspend would revert on-chain.
        assertLe(uint256(cost), collateralIn, "round-trip: OVERSPEND");
        // Invariant 2 (tight): residual is bounded. Fixed192x64Math is ~2^-62 relative precision;
        //   allow funding>>60 collateral units plus a 1024-wei floor for scale independence.
        uint256 slack = 1024 + (funding >> 60);
        assertLe(collateralIn - uint256(cost), slack, "round-trip: q too conservative");
    }
}
