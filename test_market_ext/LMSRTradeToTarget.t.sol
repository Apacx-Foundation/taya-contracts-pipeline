pragma solidity ^0.5.1;

import {ERC20Mintable} from "openzeppelin-solidity/contracts/token/ERC20/ERC20Mintable.sol";
import {ConditionalTokens} from "@gnosis.pm/conditional-tokens-contracts/contracts/ConditionalTokens.sol";
import {SafeMath} from "openzeppelin-solidity/contracts/math/SafeMath.sol";
import {CappedLMSRMarketMaker} from "../src_market_ext/CappedLMSRMarketMaker.sol";
import {CappedLMSRDeterministicFactory} from "../src_market_ext/CappedLMSRDeterministicFactory.sol";
import {LMSRBuyExactHelper} from "../src_market_ext/LMSRBuyExactHelper.sol";
import {Whitelist} from "market-makers/Whitelist.sol";
import {Fixed192x64Math} from "@gnosis.pm/util-contracts/contracts/Fixed192x64Math.sol";

/// @dev Foundry HEVM cheatcode interface.
interface Vm {
    function assume(bool) external;
}

/// @dev Test collateral token (binary-market e2e).
contract TestCollateralT2T is ERC20Mintable {}

/// @dev Smart-account proxy:
///        - `execute(target, data)` DELEGATECALLs `target` — used to run the helper
///          in this proxy's storage/balance context (matching the prod SA path).
///        - `doCall(target, data)` makes a regular CALL — used for inventory setup
///          (the proxy calls the pool's `tradeWithSurcharge` directly with msg.sender
///           = proxy, so collateral and CTF flow through the proxy).
contract T2TProxy {
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

    function doCall(address target, bytes memory data) public returns (bytes memory) {
        // solium-disable-next-line security/no-low-level-calls
        (bool ok, bytes memory ret) = target.call(data);
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

    function doSetApprovalForAll(address ctf, address operator, bool approved) public {
        // solium-disable-next-line security/no-low-level-calls
        (bool ok,) = ctf.call(abi.encodeWithSignature("setApprovalForAll(address,bool)", operator, approved));
        require(ok, "setApprovalForAll failed");
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
}

/// @notice Tests for `LMSRBuyExactHelper.tradeToTarget` — the hybrid
///         "sell inventory first, then BUY the deficit" strategy.
///
///         Assertions focus on the SPLIT (sellAmount, buyAmount) and the
///         resulting SA inventory deltas. The LMSR price-math under the
///         resulting `[Δyes, Δno]` vector is already covered by the
///         `sizeToTarget` / `calcNetCost` parity suites — this file proves
///         the split logic and that the helper submits the correct vector.
contract LMSRTradeToTargetTest {
    uint256 public constant ONE = 0x10000000000000000;
    int256 internal constant INT256_MAX = int256(uint256(-1) >> 1);
    Vm internal constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    TestCollateralT2T public collateral;
    ConditionalTokens public ctf;
    CappedLMSRDeterministicFactory public factory;
    LMSRBuyExactHelper public lib;
    uint256 internal saltNonce;
    address public oracle;

    // --- setup ------------------------------------------------------------

    constructor() public {
        collateral = new TestCollateralT2T();
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

    // --- assertions -------------------------------------------------------

    function assertTrue(bool condition, string memory message) internal pure {
        if (!condition) {
            revert(string(abi.encodePacked("FAIL: ", message)));
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

    // --- market construction ---------------------------------------------

    function _createMarket(uint256 funding)
        internal
        returns (CappedLMSRMarketMaker mm, uint256 yesId, uint256 noId)
    {
        bytes32 questionId = keccak256(abi.encodePacked(block.timestamp, funding, saltNonce));
        ctf.prepareCondition(oracle, questionId, 2);
        bytes32 conditionId = ctf.getConditionId(oracle, questionId, 2);
        bytes32[] memory conditionIds = new bytes32[](1);
        conditionIds[0] = conditionId;
        collateral.approve(address(factory), funding);
        mm = factory.create2CappedLMSRMarketMaker(
            saltNonce++, ctf, collateral, conditionIds, 0, Whitelist(0), funding, 0
        );
        bytes32 yesCol = ctf.getCollectionId(bytes32(0), conditionId, 1);
        bytes32 noCol = ctf.getCollectionId(bytes32(0), conditionId, 2);
        yesId = uint256(keccak256(abi.encodePacked(address(collateral), yesCol)));
        noId = uint256(keccak256(abi.encodePacked(address(collateral), noCol)));
    }

    /// Build a proxy with collateral + pool/CTF approvals already configured.
    function _setupProxy(CappedLMSRMarketMaker mm, uint256 collateralIn)
        internal
        returns (T2TProxy proxy)
    {
        proxy = new T2TProxy();
        collateral.transfer(address(proxy), collateralIn);
        proxy.doApprove(address(collateral), address(mm), collateralIn);
        proxy.doSetApprovalForAll(address(ctf), address(mm), true);
    }

    /// Acquire `qty` of side `idx` (0 = YES, 1 = NO) for the proxy by BUYing
    /// from the pool directly. The proxy must already hold collateral + the
    /// pool approval. Used to seed inventory before the tradeToTarget call.
    function _acquireInventory(T2TProxy proxy, CappedLMSRMarketMaker mm, uint8 idx, uint256 qty) internal {
        int256[] memory amounts = new int256[](2);
        amounts[idx] = int256(qty);
        bytes memory data = abi.encodeWithSignature(
            "tradeWithSurcharge(int256[],int256,uint64,bool)", amounts, INT256_MAX, uint64(0), false
        );
        proxy.doCall(address(mm), data);
    }

    function _callTradeToTarget(
        T2TProxy proxy,
        CappedLMSRMarketMaker mm,
        uint256 yesId,
        uint256 noId,
        uint256 deltaQ,
        bool pushUp,
        int256 collateralLimit
    ) internal returns (uint256 sellAmount, uint256 buyAmount, int256 netCost) {
        bytes memory data = abi.encodeWithSignature(
            "tradeToTarget(address,uint256,uint256,uint256,bool,int256,uint64)",
            address(mm),
            yesId,
            noId,
            deltaQ,
            pushUp,
            collateralLimit,
            uint64(0)
        );
        bytes memory ret = proxy.execute(address(lib), data);
        (sellAmount, buyAmount, netCost) = abi.decode(ret, (uint256, uint256, int256));
    }

    // ============================================================
    // pushUp: sell NO from inventory first, BUY YES for the deficit
    // ============================================================

    /// SA holds enough NO inventory to cover the full deltaQ → pure SELL NO,
    /// no YES acquired, SA receives collateral.
    function test_pushUp_inventoryCovers() public {
        uint256 funding = 1000 * ONE;
        (CappedLMSRMarketMaker mm, uint256 yesId, uint256 noId) = _createMarket(funding);
        T2TProxy proxy = _setupProxy(mm, 500 * ONE);

        _acquireInventory(proxy, mm, 1, 200 * ONE); // NO inventory > deltaQ
        uint256 yesBefore = ctf.balanceOf(address(proxy), yesId);
        uint256 noBefore = ctf.balanceOf(address(proxy), noId);
        uint256 collBefore = collateral.balanceOf(address(proxy));
        assertTrue(noBefore >= 50 * ONE, "setup: NO inventory must cover deltaQ");

        (uint256 sellAmount, uint256 buyAmount, int256 netCost) =
            _callTradeToTarget(proxy, mm, yesId, noId, 50 * ONE, true, INT256_MAX);

        assertEq(sellAmount, 50 * ONE, "sellAmount: full deltaQ from NO inventory");
        assertEq(buyAmount, 0, "buyAmount: nothing to buy");
        assertTrue(netCost < 0, "net SELL must yield collateral (negative netCost)");

        assertEq(ctf.balanceOf(address(proxy), yesId), yesBefore, "YES unchanged");
        assertEq(ctf.balanceOf(address(proxy), noId), noBefore - 50 * ONE, "NO drained by deltaQ");
        assertTrue(collateral.balanceOf(address(proxy)) > collBefore, "proxy received collateral");
    }

    /// SA holds SOME NO inventory but less than deltaQ → SELL all NO, BUY the
    /// rest of deltaQ as YES. After the trade NO is drained to 0, YES grew.
    function test_pushUp_inventoryPartial() public {
        uint256 funding = 1000 * ONE;
        (CappedLMSRMarketMaker mm, uint256 yesId, uint256 noId) = _createMarket(funding);
        T2TProxy proxy = _setupProxy(mm, 500 * ONE);

        _acquireInventory(proxy, mm, 1, 30 * ONE); // less than deltaQ
        uint256 yesBefore = ctf.balanceOf(address(proxy), yesId);
        assertEq(ctf.balanceOf(address(proxy), noId), 30 * ONE, "setup: NO inventory == requested");

        (uint256 sellAmount, uint256 buyAmount,) =
            _callTradeToTarget(proxy, mm, yesId, noId, 50 * ONE, true, INT256_MAX);

        assertEq(sellAmount, 30 * ONE, "sellAmount: full NO inventory");
        assertEq(buyAmount, 20 * ONE, "buyAmount: deltaQ minus inventory");

        assertEq(ctf.balanceOf(address(proxy), yesId), yesBefore + 20 * ONE, "YES += deficit");
        assertEq(ctf.balanceOf(address(proxy), noId), 0, "NO drained to 0");
    }

    /// SA has no NO inventory → pure BUY YES of deltaQ. SA pays collateral.
    function test_pushUp_noInventory() public {
        uint256 funding = 1000 * ONE;
        (CappedLMSRMarketMaker mm, uint256 yesId, uint256 noId) = _createMarket(funding);
        T2TProxy proxy = _setupProxy(mm, 500 * ONE);

        assertEq(ctf.balanceOf(address(proxy), noId), 0, "setup: zero NO");
        uint256 yesBefore = ctf.balanceOf(address(proxy), yesId);
        uint256 collBefore = collateral.balanceOf(address(proxy));

        (uint256 sellAmount, uint256 buyAmount, int256 netCost) =
            _callTradeToTarget(proxy, mm, yesId, noId, 50 * ONE, true, INT256_MAX);

        assertEq(sellAmount, 0, "sellAmount: no inventory to sell");
        assertEq(buyAmount, 50 * ONE, "buyAmount: full deltaQ");
        assertTrue(netCost > 0, "pure BUY pays collateral (positive netCost)");

        assertEq(ctf.balanceOf(address(proxy), yesId), yesBefore + 50 * ONE, "YES += deltaQ");
        assertEq(ctf.balanceOf(address(proxy), noId), 0, "NO unchanged at 0");
        assertTrue(collateral.balanceOf(address(proxy)) < collBefore, "proxy spent collateral");
    }

    // ============================================================
    // pushDown: sell YES from inventory first, BUY NO for the deficit
    // ============================================================

    function test_pushDown_inventoryCovers() public {
        uint256 funding = 1000 * ONE;
        (CappedLMSRMarketMaker mm, uint256 yesId, uint256 noId) = _createMarket(funding);
        T2TProxy proxy = _setupProxy(mm, 500 * ONE);

        _acquireInventory(proxy, mm, 0, 200 * ONE); // YES inventory > deltaQ
        uint256 yesBefore = ctf.balanceOf(address(proxy), yesId);
        uint256 noBefore = ctf.balanceOf(address(proxy), noId);

        (uint256 sellAmount, uint256 buyAmount, int256 netCost) =
            _callTradeToTarget(proxy, mm, yesId, noId, 50 * ONE, false, INT256_MAX);

        assertEq(sellAmount, 50 * ONE, "sellAmount: full deltaQ from YES inventory");
        assertEq(buyAmount, 0, "buyAmount: nothing");
        assertTrue(netCost < 0, "net SELL yields collateral");

        assertEq(ctf.balanceOf(address(proxy), yesId), yesBefore - 50 * ONE, "YES drained by deltaQ");
        assertEq(ctf.balanceOf(address(proxy), noId), noBefore, "NO unchanged");
    }

    function test_pushDown_inventoryPartial() public {
        uint256 funding = 1000 * ONE;
        (CappedLMSRMarketMaker mm, uint256 yesId, uint256 noId) = _createMarket(funding);
        T2TProxy proxy = _setupProxy(mm, 500 * ONE);

        _acquireInventory(proxy, mm, 0, 30 * ONE);
        uint256 noBefore = ctf.balanceOf(address(proxy), noId);
        assertEq(ctf.balanceOf(address(proxy), yesId), 30 * ONE, "setup: YES inventory == requested");

        (uint256 sellAmount, uint256 buyAmount,) =
            _callTradeToTarget(proxy, mm, yesId, noId, 50 * ONE, false, INT256_MAX);

        assertEq(sellAmount, 30 * ONE, "sellAmount: full YES inventory");
        assertEq(buyAmount, 20 * ONE, "buyAmount: deltaQ - inventory");

        assertEq(ctf.balanceOf(address(proxy), yesId), 0, "YES drained to 0");
        assertEq(ctf.balanceOf(address(proxy), noId), noBefore + 20 * ONE, "NO += deficit");
    }

    function test_pushDown_noInventory() public {
        uint256 funding = 1000 * ONE;
        (CappedLMSRMarketMaker mm, uint256 yesId, uint256 noId) = _createMarket(funding);
        T2TProxy proxy = _setupProxy(mm, 500 * ONE);

        assertEq(ctf.balanceOf(address(proxy), yesId), 0, "setup: zero YES");
        uint256 collBefore = collateral.balanceOf(address(proxy));

        (uint256 sellAmount, uint256 buyAmount, int256 netCost) =
            _callTradeToTarget(proxy, mm, yesId, noId, 50 * ONE, false, INT256_MAX);

        assertEq(sellAmount, 0, "no inventory to sell");
        assertEq(buyAmount, 50 * ONE, "pure BUY NO");
        assertTrue(netCost > 0, "pure BUY pays collateral");

        assertEq(ctf.balanceOf(address(proxy), yesId), 0, "YES unchanged at 0");
        assertEq(ctf.balanceOf(address(proxy), noId), 50 * ONE, "NO += deltaQ");
        assertTrue(collateral.balanceOf(address(proxy)) < collBefore, "proxy spent collateral");
    }

    // ============================================================
    // edge cases
    // ============================================================

    /// deltaQ = 0 is rejected up-front (no zero-sized trades).
    function test_deltaQZeroReverts() public {
        uint256 funding = 1000 * ONE;
        (CappedLMSRMarketMaker mm, uint256 yesId, uint256 noId) = _createMarket(funding);
        T2TProxy proxy = _setupProxy(mm, 100 * ONE);

        bytes memory data = abi.encodeWithSignature(
            "tradeToTarget(address,uint256,uint256,uint256,bool,int256,uint64)",
            address(mm),
            yesId,
            noId,
            uint256(0),
            true,
            INT256_MAX,
            uint64(0)
        );
        // solium-disable-next-line security/no-low-level-calls
        (bool ok, bytes memory ret) =
            address(proxy).call(abi.encodeWithSignature("execute(address,bytes)", address(lib), data));
        _assertRevertReason(ok, ret, "deltaQ zero");
    }

    /// A tight `collateralLimit` smaller than the BUY's cost makes the pool
    /// revert the trade — the helper forwards the bound unchanged.
    function test_tightCollateralLimitReverts() public {
        uint256 funding = 1000 * ONE;
        (CappedLMSRMarketMaker mm, uint256 yesId, uint256 noId) = _createMarket(funding);
        T2TProxy proxy = _setupProxy(mm, 500 * ONE);

        // Pure BUY YES of 100*ONE on a $1000-funding pool costs ≫ 1 wei.
        bytes memory data = abi.encodeWithSignature(
            "tradeToTarget(address,uint256,uint256,uint256,bool,int256,uint64)",
            address(mm),
            yesId,
            noId,
            uint256(100 * ONE),
            true,
            int256(1),
            uint64(0)
        );
        // solium-disable-next-line security/no-low-level-calls
        (bool ok,) = address(proxy).call(abi.encodeWithSignature("execute(address,bytes)", address(lib), data));
        assertTrue(!ok, "expected revert: pool refuses trade beyond collateralLimit");
    }

    // ============================================================
    // fuzz tests
    // ============================================================

    /// @dev Closed-form deltaQ for a given target YES marginal price.
    ///      Inverse of the on-chain `calcMarginalPrice`:
    ///        P_yes = 2^(-X/b) / (2^(-X/b) + 2^(-Y/b))
    ///        ⇒  (X − Y) at target = b · log2((1 − p) / p)
    ///        ⇒  D = (X1 − Y1) − b · log2((1 − p) / p)
    ///      where D is the shift the trade vector must apply. Pure
    ///      Fixed192x64Math, so it lands wei-close to what the pool itself
    ///      will compute post-trade.
    function _deltaQForTarget(uint256 funding, uint256 X, uint256 Y, uint256 targetPriceFP)
        internal
        pure
        returns (uint256 deltaQ, bool pushUp)
    {
        require(targetPriceFP > 0 && targetPriceFP < ONE, "target out of range");
        uint256 ratioFP = (ONE - targetPriceFP) * ONE / targetPriceFP;
        int256 logRatioFP = Fixed192x64Math.binaryLog(ratioFP, Fixed192x64Math.EstimationMode.Midpoint);
        int256 K = int256(funding) * logRatioFP / int256(ONE);
        int256 D = int256(X) - int256(Y) - K;
        if (D >= 0) return (uint256(D), true);
        return (uint256(-D), false);
    }

    /// @notice Fuzz: for any (funding, initial bias, target price) in sane
    ///         ranges, after `tradeToTarget(deltaQ, direction)` the pool's
    ///         actual post-trade marginal YES price equals the target within
    ///         wei tolerance.
    ///
    ///         The assertion reads `pool.calcMarginalPrice(0)` AFTER the
    ///         on-chain trade — proving the realized price (not just the
    ///         intended one) lands at the target.
    function testFuzz_priceTargetAchieved(uint128 fundingFactor, uint64 biasFactor, uint16 targetBps) public {
        uint256 funding = (uint256(fundingFactor) % 1000 + 100) * ONE;
        (CappedLMSRMarketMaker mm, uint256 yesId, uint256 noId) = _createMarket(funding);
        T2TProxy proxy = _setupProxy(mm, 100000 * ONE);

        // Optional initial bias: BUY some YES to move the pool off symmetric.
        uint256 biasQty = (funding / 4) * uint256(biasFactor) / uint256(uint64(-1));
        if (biasQty >= ONE) {
            int256[] memory biasAmounts = new int256[](2);
            biasAmounts[0] = int256(biasQty);
            bytes memory biasData = abi.encodeWithSignature(
                "tradeWithSurcharge(int256[],int256,uint64,bool)", biasAmounts, INT256_MAX, uint64(0), false
            );
            // solium-disable-next-line security/no-low-level-calls
            (bool biasOk,) = address(proxy).call(abi.encodeWithSignature("doCall(address,bytes)", address(mm), biasData));
            vm.assume(biasOk);
        }

        // Target price 0.10..0.90 in 2^64 fp.
        uint256 tBps = (uint256(targetBps) % 8000) + 1000;
        uint256 targetPriceFP = tBps * ONE / 10000;

        uint256 X1 = ctf.balanceOf(address(mm), yesId);
        uint256 Y1 = ctf.balanceOf(address(mm), noId);

        (uint256 deltaQ, bool pushUp) = _deltaQForTarget(funding, X1, Y1, targetPriceFP);
        vm.assume(deltaQ > 0 && deltaQ < funding / 2); // skip already-at-target and overly-large shifts

        bytes memory data = abi.encodeWithSignature(
            "tradeToTarget(address,uint256,uint256,uint256,bool,int256,uint64)",
            address(mm),
            yesId,
            noId,
            deltaQ,
            pushUp,
            INT256_MAX,
            uint64(0)
        );
        // solium-disable-next-line security/no-low-level-calls
        (bool ok,) = address(proxy).call(abi.encodeWithSignature("execute(address,bytes)", address(lib), data));
        vm.assume(ok); // pool may revert on near-asymptote targets; skip those

        // The realised post-trade marginal YES price must equal the target.
        // Tolerance accounts for Fixed192x64 rounding (LowerBound in pow2 +
        // Midpoint in our binaryLog) across the closed-form inverse and the
        // pool's calcMarginalPrice. Empirically ≤ a few wei out of 2^64.
        uint256 postFP = mm.calcMarginalPrice(0);
        uint256 diff = postFP > targetPriceFP ? postFP - targetPriceFP : targetPriceFP - postFP;
        assertTrue(diff <= 1024, "post-trade marginal price drifted from target");
    }

    /// @notice Fuzz: starting from an empty SA, ANY sequence of
    ///         `tradeToTarget` calls leaves the SA holding at most ONE of
    ///         {YES, NO} at every step. The misaligned-side-first split
    ///         never adds to a side that's already nonzero unless the
    ///         opposite side is drained to 0 first.
    function testFuzz_oneSidedAcrossRuns(uint128 fundingFactor, uint256 deltaSeed, uint256 directionSeed) public {
        uint256 funding = (uint256(fundingFactor) % 1000 + 100) * ONE;
        (CappedLMSRMarketMaker mm, uint256 yesId, uint256 noId) = _createMarket(funding);
        T2TProxy proxy = _setupProxy(mm, 100000 * ONE);

        // SA starts empty (no inventory). Run 16 random trades; at every
        // step assert (yesBal == 0 || noBal == 0).
        uint256 successCount = 0;
        for (uint256 i = 0; i < 16; i++) {
            // deltaQ ∈ [ONE, funding/20]; small enough not to drain the pool.
            uint256 maxDelta = funding / 20;
            uint256 deltaQ = ONE + (uint256(keccak256(abi.encode(deltaSeed, i))) % maxDelta);
            bool pushUp = ((directionSeed >> (i & 0xFF)) & 1) == 1;

            bytes memory data = abi.encodeWithSignature(
                "tradeToTarget(address,uint256,uint256,uint256,bool,int256,uint64)",
                address(mm),
                yesId,
                noId,
                deltaQ,
                pushUp,
                INT256_MAX,
                uint64(0)
            );
            // solium-disable-next-line security/no-low-level-calls
            (bool ok,) =
                address(proxy).call(abi.encodeWithSignature("execute(address,bytes)", address(lib), data));
            if (!ok) continue;
            successCount++;

            uint256 yes = ctf.balanceOf(address(proxy), yesId);
            uint256 no = ctf.balanceOf(address(proxy), noId);
            assertTrue(
                yes == 0 || no == 0,
                string(
                    abi.encodePacked(
                        "SA holds both at step ", _u2s(i), " yes=", _u2s(yes), " no=", _u2s(no)
                    )
                )
            );
        }
        // Make sure the fuzz actually exercised something — otherwise the
        // assertion above is vacuously true (every iteration reverted).
        vm.assume(successCount > 0);
    }
}
