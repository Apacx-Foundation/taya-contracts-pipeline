pragma solidity ^0.5.1;

import {ERC20Mintable} from "openzeppelin-solidity/contracts/token/ERC20/ERC20Mintable.sol";
import {ConditionalTokens} from "@gnosis.pm/conditional-tokens-contracts/contracts/ConditionalTokens.sol";
import {CappedLMSRMarketMaker} from "../src_market_ext/CappedLMSRMarketMaker.sol";
import {CappedLMSRDeterministicFactory} from "../src_market_ext/CappedLMSRDeterministicFactory.sol";
import {LMSRMarketMaker} from "market-makers/LMSRMarketMaker.sol";
import {LMSRMarketMakerFactory} from "market-makers/LMSRMarketMakerFactory.sol";
import {Whitelist} from "market-makers/Whitelist.sol";
import {WhitelistAccessControl} from "../src_market_ext/WhitelistAccessControl.sol";
import {Fixed192x64Math} from "@gnosis.pm/util-contracts/contracts/Fixed192x64Math.sol";

/// @title Test collateral token for CappedLMSR tests
contract TestCollateral is ERC20Mintable {}

contract TestUtils {
    function assertTrue(bool condition, string memory message) internal pure {
        if (!condition) {
            revert(string(abi.encodePacked("message: ", message, " expected true but got false")));
        }
    }

    function assertEq(uint256 left, uint256 right, string memory message) internal pure {
        if (left != right) {
            revert(
                string(
                    abi.encodePacked(
                        "message: ", message, " expected ", uintToString(left), " but got ", uintToString(right)
                    )
                )
            );
        }
    }

    function assertApproxEq(uint256 left, uint256 right, uint256 tolerance, string memory message) internal pure {
        uint256 diff = left > right ? left - right : right - left;
        if (diff > tolerance) {
            revert(
                string(
                    abi.encodePacked(
                        "message: ", message, " expected ~", uintToString(left), " but got ", uintToString(right)
                    )
                )
            );
        }
    }

    function uintToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
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
}

/// @title CappedLMSRMarketMaker Tests
/// @notice Tests for LMSR market maker with loss tracking and per-trade caps
contract CappedLMSRMarketMakerTest is TestUtils {
    /*
     *  Constants
     */
    uint256 public constant ONE = 0x10000000000000000;

    // Test contracts
    TestCollateral public collateral;
    ConditionalTokens public ctf;
    CappedLMSRDeterministicFactory public factory;
    uint256 internal saltNonce;
    LMSRMarketMakerFactory public lmsrFactory;

    // Test oracle for condition creation
    address public oracle;

    // Events for test logging
    event TestPassed(string name);
    event TestFailed(string name, string reason);
    event Log(string message, uint256 value);
    event LogInt(string message, int256 value);

    constructor() public {
        collateral = new TestCollateral();
        ctf = new ConditionalTokens();
        factory = new CappedLMSRDeterministicFactory();
        lmsrFactory = new LMSRMarketMakerFactory();
        oracle = address(this);

        collateral.mint(address(this), 1000000 * ONE);
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

    /// @notice Helper to create a binary market (no tx cost cap)
    function createBinaryMarket(uint256 funding) internal returns (CappedLMSRMarketMaker) {
        return createMarket(funding, 2, 0);
    }

    /// @notice Helper to create a binary market with tx cost cap
    function createBinaryMarketWithCap(uint256 funding, uint256 maxTxCost) internal returns (CappedLMSRMarketMaker) {
        return createMarket(funding, 2, maxTxCost);
    }

    /// @notice Helper to create a market with given funding, outcome count, and tx cost cap
    function createMarket(uint256 funding, uint256 outcomeSlotCount, uint256 maxTxCost)
        internal
        returns (CappedLMSRMarketMaker)
    {
        bytes32 questionId = keccak256(abi.encodePacked(block.timestamp, funding, outcomeSlotCount, maxTxCost));
        ctf.prepareCondition(oracle, questionId, outcomeSlotCount);
        bytes32 conditionId = ctf.getConditionId(oracle, questionId, outcomeSlotCount);

        bytes32[] memory conditionIds = new bytes32[](1);
        conditionIds[0] = conditionId;

        collateral.approve(address(factory), funding);

        return factory.create2CappedLMSRMarketMaker(
            saltNonce++,
            ctf,
            collateral,
            conditionIds,
            0, // fee
            Whitelist(0), // no whitelist
            funding,
            maxTxCost
        );
    }

    // ----------------------------------------------------------------
    // Core LMSR behavior (b = funding)
    // ----------------------------------------------------------------

    function test_pricesSumToOne() public {
        CappedLMSRMarketMaker mm = createBinaryMarket(1000 * ONE);
        uint256 price0 = mm.calcMarginalPrice(0);
        uint256 price1 = mm.calcMarginalPrice(1);
        uint256 sum = price0 + price1;
        uint256 diff = sum > ONE ? sum - ONE : ONE - sum;
        assertTrue(diff <= ONE / 10000, "prices do not sum to ONE");
    }

    function test_spreadTightensWithHigherFunding() public {
        // Higher funding (= higher b) means tighter spreads after the same trade
        CappedLMSRMarketMaker low = createBinaryMarket(500 * ONE);
        CappedLMSRMarketMaker high = createBinaryMarket(1000 * ONE);
        int256[] memory amounts = new int256[](2);
        amounts[0] = int256(10 * ONE);
        amounts[1] = 0;

        collateral.approve(address(low), uint256(-1));
        collateral.approve(address(high), uint256(-1));

        low.trade(amounts, 0);
        high.trade(amounts, 0);

        uint256 half = ONE / 2;
        uint256 lowPrice = low.calcMarginalPrice(0);
        uint256 highPrice = high.calcMarginalPrice(0);

        uint256 lowDiff = lowPrice > half ? lowPrice - half : half - lowPrice;
        uint256 highDiff = highPrice > half ? highPrice - half : half - highPrice;

        assertTrue(highDiff <= lowDiff, "higher funding should tighten spread");
    }

    function test_matchesOriginalLMSR() public {
        uint256 funding = 1000 * ONE;

        bytes32 questionId = keccak256(abi.encodePacked(block.timestamp, "lmsr-compare"));
        ctf.prepareCondition(oracle, questionId, 2);
        bytes32 conditionId = ctf.getConditionId(oracle, questionId, 2);

        bytes32[] memory conditionIds = new bytes32[](1);
        conditionIds[0] = conditionId;

        collateral.approve(address(factory), uint256(-1));
        collateral.approve(address(lmsrFactory), uint256(-1));

        CappedLMSRMarketMaker capped =
            factory.create2CappedLMSRMarketMaker(saltNonce++, ctf, collateral, conditionIds, 0, Whitelist(0), funding, 0);

        LMSRMarketMaker lmsr =
            lmsrFactory.createLMSRMarketMaker(ctf, collateral, conditionIds, 0, Whitelist(0), funding);

        int256[] memory amounts = new int256[](2);
        amounts[0] = int256(10 * ONE);
        amounts[1] = 0;

        int256 cappedCost = capped.calcNetCost(amounts);
        int256 lmsrCost = lmsr.calcNetCost(amounts);
        int256 diff = cappedCost > lmsrCost ? cappedCost - lmsrCost : lmsrCost - cappedCost;
        assertTrue(diff <= 1, "capped should match original LMSR exactly");
    }

    // ----------------------------------------------------------------
    // maxCostPerTx
    // ----------------------------------------------------------------

    function test_maxCostPerTxRevertsOnExceed() public {
        uint256 funding = 1000 * ONE;

        int256[] memory amounts = new int256[](2);
        amounts[0] = int256(10 * ONE);
        amounts[1] = 0;

        // --- Part 1: tiny cap blocks all positive-cost trades ---
        uint256 tinyCap = 1;
        CappedLMSRMarketMaker capped = createBinaryMarketWithCap(funding, tinyCap);
        assertEq(capped.maxCostPerTx(), tinyCap, "maxCostPerTx not stored");
        collateral.approve(address(capped), uint256(-1));

        int256 cost = capped.calcNetCost(amounts);
        assertTrue(cost > int256(tinyCap), "test setup: cost should exceed tiny cap");

        (bool success,) = address(capped).call(abi.encodeWithSignature("trade(int256[],int256)", amounts, int256(0)));
        assertTrue(!success, "should revert when cost exceeds maxCostPerTx");

        // --- Part 2: large cap allows trade ---
        uint256 largeCap = funding;
        CappedLMSRMarketMaker uncapped = createBinaryMarketWithCap(funding, largeCap);
        collateral.approve(address(uncapped), uint256(-1));

        uncapped.trade(amounts, 0);
    }

    function test_changeMaxCostPerTx() public {
        CappedLMSRMarketMaker mm = createBinaryMarket(1000 * ONE);
        assertEq(mm.maxCostPerTx(), 0, "maxCostPerTx should be 0");
        mm.pause();
        mm.changeMaxCostPerTx(1000 * ONE);
        assertEq(mm.maxCostPerTx(), 1000 * ONE, "maxCostPerTx should be 1000 * ONE");
    }

    // ----------------------------------------------------------------
    // Whitelist
    // ----------------------------------------------------------------

    /// @notice Helper to create a binary market with an actual Whitelist contract
    function createBinaryMarketWithWhitelist(uint256 funding, Whitelist wl) internal returns (CappedLMSRMarketMaker) {
        bytes32 questionId = keccak256(abi.encodePacked(block.timestamp, funding, "wl"));
        ctf.prepareCondition(oracle, questionId, 2);
        bytes32 conditionId = ctf.getConditionId(oracle, questionId, 2);

        bytes32[] memory conditionIds = new bytes32[](1);
        conditionIds[0] = conditionId;

        collateral.approve(address(factory), funding);

        return factory.create2CappedLMSRMarketMaker(
            saltNonce++,
            ctf,
            collateral,
            conditionIds,
            0, // fee
            wl,
            funding,
            0 // no tx cap
        );
    }

    /// @notice Helper to prepare two binary conditions and return both IDs.
    function createTwoBinaryConditions(uint256 funding) internal returns (bytes32[] memory conditionIds) {
        bytes32 q1 = keccak256(abi.encodePacked(block.timestamp, funding, "multi-cond-1"));
        bytes32 q2 = keccak256(abi.encodePacked(block.timestamp, funding, "multi-cond-2"));
        ctf.prepareCondition(oracle, q1, 2);
        ctf.prepareCondition(oracle, q2, 2);

        conditionIds = new bytes32[](2);
        conditionIds[0] = ctf.getConditionId(oracle, q1, 2);
        conditionIds[1] = ctf.getConditionId(oracle, q2, 2);
    }

    function test_whitelistBlocksNonWhitelistedTrader() public {
        Whitelist wl = new Whitelist();
        // Do NOT add this contract to the whitelist
        CappedLMSRMarketMaker mm = createBinaryMarketWithWhitelist(1000 * ONE, wl);

        collateral.approve(address(mm), uint256(-1));

        int256[] memory amounts = new int256[](2);
        amounts[0] = int256(10 * ONE);
        amounts[1] = 0;

        (bool success,) = address(mm).call(abi.encodeWithSignature("trade(int256[],int256)", amounts, int256(0)));
        assertTrue(!success, "trade should revert for non-whitelisted address");
        assertEq(uint256(mm.cumulativeNetCost()), 0, "cumulativeNetCost should be 0");
    }

    function test_whitelistAllowsWhitelistedTrader() public {
        Whitelist wl = new Whitelist();

        // Add this contract to the whitelist
        address[] memory users = new address[](1);
        users[0] = address(this);
        wl.addToWhitelist(users);

        CappedLMSRMarketMaker mm = createBinaryMarketWithWhitelist(1000 * ONE, wl);

        collateral.approve(address(mm), uint256(-1));

        int256[] memory amounts = new int256[](2);
        amounts[0] = int256(10 * ONE);
        amounts[1] = 0;

        // Should succeed
        mm.trade(amounts, 0);
    }

    function test_whitelistAccessControlIntegration() public {
        // Create WhitelistAccessControl directly and whitelist this contract
        WhitelistAccessControl wl = new WhitelistAccessControl();
        address[] memory users = new address[](1);
        users[0] = address(this);
        wl.whitelisterAdd(users);

        // Use the whitelist with a market
        CappedLMSRMarketMaker mm = createBinaryMarketWithWhitelist(1000 * ONE, Whitelist(address(wl)));
        collateral.approve(address(mm), uint256(-1));

        int256[] memory amounts = new int256[](2);
        amounts[0] = int256(10 * ONE);
        amounts[1] = 0;

        // Trade should succeed (we're whitelisted)
        mm.trade(amounts, 0);
        assertTrue(mm.cumulativeNetCost() > 0, "trade should have occurred");
    }

    // ----------------------------------------------------------------
    // Stage gating
    // ----------------------------------------------------------------

    function test_tradeRevertsWhenPaused() public {
        CappedLMSRMarketMaker mm = createBinaryMarket(1000 * ONE);
        collateral.approve(address(mm), uint256(-1));

        mm.pause();

        int256[] memory amounts = new int256[](2);
        amounts[0] = int256(10 * ONE);
        amounts[1] = 0;

        (bool success,) = address(mm).call(abi.encodeWithSignature("trade(int256[],int256)", amounts, int256(0)));
        assertTrue(!success, "trade should revert when market is paused");
    }

    function test_tradeRevertsWhenClosed() public {
        CappedLMSRMarketMaker mm = createBinaryMarket(1000 * ONE);
        collateral.approve(address(mm), uint256(-1));
        ctf.setApprovalForAll(address(mm), true);

        mm.close();

        int256[] memory amounts = new int256[](2);
        amounts[0] = int256(10 * ONE);
        amounts[1] = 0;

        (bool success,) = address(mm).call(abi.encodeWithSignature("trade(int256[],int256)", amounts, int256(0)));
        assertTrue(!success, "trade should revert when market is closed");
    }

    function test_pauseResumeOnlyOwner() public {
        CappedLMSRMarketMaker mm = createBinaryMarket(1000 * ONE);

        // Transfer ownership to a different address so this contract is no longer owner
        mm.transferOwnership(address(1));

        // pause should revert (not owner)
        (bool okPause,) = address(mm).call(abi.encodeWithSignature("pause()"));
        assertTrue(!okPause, "pause should revert for non-owner");
    }

    // ----------------------------------------------------------------
    // Storage slot alignment
    // ----------------------------------------------------------------

    /// @notice Verify all storage-backed fields read correctly through the clone proxy.
    ///         If the Data contract layout diverges from the implementation inheritance
    ///         chain (Ownable → ERC165 → MarketMaker → LMSRMarketMaker → CappedLMSRMarketMaker),
    ///         any of these getter checks will return garbage and fail.
    function test_storageSlotAlignment() public {
        uint256 funding = 1000 * ONE;
        uint256 maxCap = 500 * ONE;

        Whitelist wl = new Whitelist();
        address[] memory users = new address[](1);
        users[0] = address(this);
        wl.addToWhitelist(users);

        bytes32 questionId = keccak256(abi.encodePacked(block.timestamp, funding, "slot-check"));
        ctf.prepareCondition(oracle, questionId, 2);
        bytes32 conditionId = ctf.getConditionId(oracle, questionId, 2);

        bytes32[] memory conditionIds = new bytes32[](1);
        conditionIds[0] = conditionId;

        collateral.approve(address(factory), funding);

        CappedLMSRMarketMaker mm = factory.create2CappedLMSRMarketMaker(
            saltNonce++, ctf, collateral, conditionIds, 0, wl, funding, maxCap
        );

        {
            // --- Ownable slot ---
            assertTrue(mm.owner() == address(this), "slot: owner");

            // --- MarketMaker slots ---
            assertTrue(address(mm.pmSystem()) == address(ctf), "slot: pmSystem");
            assertTrue(address(mm.collateralToken()) == address(collateral), "slot: collateralToken");
            assertTrue(mm.conditionIds(0) == conditionId, "slot: conditionIds[0]");
            assertEq(mm.atomicOutcomeSlotCount(), 2, "slot: atomicOutcomeSlotCount");
            assertEq(uint256(mm.fee()), 0, "slot: fee");
            assertEq(mm.funding(), funding, "slot: funding");
            assertEq(uint256(mm.stage()), 0, "slot: stage (Running=0)");
            assertTrue(address(mm.whitelist()) == address(wl), "slot: whitelist");
        }

        // --- CappedLMSRMarketMaker slots (pre-trade) ---
        assertEq(mm.maxCostPerTx(), maxCap, "slot: maxCostPerTx");
        assertEq(mm.lossUsed(), 0, "slot: lossUsed init");
        assertTrue(mm.cumulativeNetCost() == 0, "slot: cumulativeNetCost init");

        // --- Mutate CappedLMSR-specific state via a trade ---
        collateral.approve(address(mm), uint256(-1));
        int256[] memory amounts = new int256[](2);
        amounts[0] = int256(10 * ONE);
        amounts[1] = 0;
        int256 cost = mm.trade(amounts, 0);

        // --- Mutate Fee & Pause ---
        {
            uint64 newFee = 211;
            mm.pause();
            mm.changeFee(newFee);
            assertEq(mm.fee(), newFee, "slot: fee post-change");
            mm.changeFee(0);
            mm.resume();
        }

        assertTrue(cost > 0, "trade should have positive cost");
        assertTrue(mm.cumulativeNetCost() == cost, "slot: cumulativeNetCost post-trade");
        assertEq(mm.lossUsed(), uint256(cost), "slot: lossUsed post-trade");

        // --- Sell back, verify cumulativeNetCost decreases but lossUsed stays (high-water mark) ---
        ctf.setApprovalForAll(address(mm), true);
        amounts[0] = -int256(5 * ONE);
        amounts[1] = 0;
        int256 sellCost = mm.trade(amounts, 0);
        assertTrue(sellCost < 0, "sell should return collateral");
        assertTrue(mm.cumulativeNetCost() < cost, "cumulativeNetCost should decrease after sell");
        assertEq(mm.lossUsed(), uint256(cost), "slot: lossUsed should not decrease (high-water mark)");

        // --- Verify MarketMaker state still intact after trades ---
        assertTrue(address(mm.pmSystem()) == address(ctf), "slot: pmSystem post-trade");
        assertEq(mm.funding(), funding, "slot: funding post-trade");
        assertTrue(address(mm.whitelist()) == address(wl), "slot: whitelist post-trade");
        assertEq(mm.maxCostPerTx(), maxCap, "slot: maxCostPerTx post-trade");
    }

    /// @notice Multi-condition smoke test for storage + trading path.
    ///         Creates 2 binary conditions (4 atomic outcomes) and verifies
    ///         condition array slots, outcome count, and buy/sell accounting.
    function test_multiConditionStorageAndTrading() public {
        uint256 funding = 2000 * ONE;
        uint256 maxCap = 1500 * ONE;

        Whitelist wl = new Whitelist();
        {
            address[] memory users = new address[](1);
            users[0] = address(this);
            wl.addToWhitelist(users);
        }

        bytes32[] memory conditionIds = createTwoBinaryConditions(funding);

        collateral.approve(address(factory), funding);
        CappedLMSRMarketMaker mm = factory.create2CappedLMSRMarketMaker(
            saltNonce++, ctf, collateral, conditionIds, 0, wl, funding, maxCap
        );

        // Validate multi-condition storage-backed fields.
        assertTrue(mm.conditionIds(0) == conditionIds[0], "multi: conditionIds[0]");
        assertTrue(mm.conditionIds(1) == conditionIds[1], "multi: conditionIds[1]");
        assertEq(mm.atomicOutcomeSlotCount(), 4, "multi: atomicOutcomeSlotCount");
        assertEq(mm.funding(), funding, "multi: funding");
        assertEq(mm.maxCostPerTx(), maxCap, "multi: maxCostPerTx");

        // Prices across 4 atomic outcomes should still sum to ~1.
        uint256 sum =
            mm.calcMarginalPrice(0) + mm.calcMarginalPrice(1) + mm.calcMarginalPrice(2) + mm.calcMarginalPrice(3);
        uint256 diff = sum > ONE ? sum - ONE : ONE - sum;
        assertTrue(diff <= ONE / 10000, "multi: prices do not sum to ONE");

        collateral.approve(address(mm), uint256(-1));

        int256[] memory amounts = new int256[](4);
        amounts[0] = int256(8 * ONE);
        amounts[1] = 0;
        amounts[2] = 0;
        amounts[3] = 0;
        int256 buyCost = mm.trade(amounts, 0);
        assertTrue(buyCost > 0, "multi: buy should cost collateral");
        assertTrue(mm.cumulativeNetCost() == buyCost, "multi: cumulativeNetCost post-buy");
        assertEq(mm.lossUsed(), uint256(buyCost), "multi: lossUsed post-buy");

        ctf.setApprovalForAll(address(mm), true);
        amounts[0] = -int256(3 * ONE);
        amounts[1] = 0;
        amounts[2] = 0;
        amounts[3] = 0;
        int256 sellCost = mm.trade(amounts, 0);
        assertTrue(sellCost < 0, "multi: sell should return collateral");
        assertTrue(mm.cumulativeNetCost() == buyCost + sellCost, "multi: cumulativeNetCost post-sell");
        assertEq(mm.lossUsed(), uint256(buyCost), "multi: lossUsed high-water mark");
    }

    // ----------------------------------------------------------------
    // tradeWithSurcharge
    // ----------------------------------------------------------------

    function test_tradeWithSurcharge_basic() public {
        CappedLMSRMarketMaker mm = createBinaryMarket(1000 * ONE);
        collateral.approve(address(mm), uint256(-1));

        int256[] memory amounts = new int256[](2);
        amounts[0] = int256(10 * ONE);
        amounts[1] = 0;

        int256 cost = mm.tradeWithSurcharge(amounts, 0, 0, false);
        assertTrue(cost > 0, "buy should have positive cost");
        assertTrue(mm.cumulativeNetCost() == cost, "cumulativeNetCost should match");
    }

    function test_tradeWithSurcharge_increasedCost() public {
        CappedLMSRMarketMaker mm = createBinaryMarket(1000 * ONE);
        collateral.approve(address(mm), uint256(-1));
        ctf.setApprovalForAll(address(mm), true);

        int256[] memory amounts = new int256[](2);
        amounts[0] = int256(10 * ONE);
        amounts[1] = 0;

        // Trade without surcharge
        int256 plainCost = mm.trade(amounts, 0);

        // Sell back to reset position
        int256[] memory sellAmounts = new int256[](2);
        sellAmounts[0] = -int256(10 * ONE);
        sellAmounts[1] = 0;
        mm.trade(sellAmounts, 0);

        // Trade with 5% surcharge from same state
        uint64 surchargeRate = uint64(5 * 10**16);
        int256 surchargeCost = mm.tradeWithSurcharge(amounts, 0, surchargeRate, false);

        assertTrue(surchargeCost > plainCost, "surcharge should increase cost");
    }

    function test_tradeWithSurcharge_feeRestored() public {
        CappedLMSRMarketMaker mm = createBinaryMarket(1000 * ONE);
        collateral.approve(address(mm), uint256(-1));

        uint64 originalFee = mm.fee();

        int256[] memory amounts = new int256[](2);
        amounts[0] = int256(10 * ONE);
        amounts[1] = 0;

        uint64 surchargeRate = uint64(5 * 10**16);
        mm.tradeWithSurcharge(amounts, 0, surchargeRate, false);

        assertEq(uint256(mm.fee()), uint256(originalFee), "fee should be restored after tradeWithSurcharge");
    }

    function test_tradeWithSurcharge_feeRestoredWithExistingFee() public {
        // Create market, set a base fee, then trade with surcharge
        CappedLMSRMarketMaker mm = createBinaryMarket(1000 * ONE);
        collateral.approve(address(mm), uint256(-1));

        uint64 baseFee = uint64(2 * 10**16); // 2%
        mm.pause();
        mm.changeFee(baseFee);
        mm.resume();

        int256[] memory amounts = new int256[](2);
        amounts[0] = int256(10 * ONE);
        amounts[1] = 0;

        uint64 surchargeRate = uint64(3 * 10**16); // 3% surcharge on top of 2% base
        mm.tradeWithSurcharge(amounts, 0, surchargeRate, false);

        assertEq(uint256(mm.fee()), uint256(baseFee), "base fee should be restored");
    }

    function test_tradeWithSurcharge_updatesLossTracking() public {
        CappedLMSRMarketMaker mm = createBinaryMarket(1000 * ONE);
        collateral.approve(address(mm), uint256(-1));

        int256[] memory amounts = new int256[](2);
        amounts[0] = int256(10 * ONE);
        amounts[1] = 0;

        int256 cost = mm.tradeWithSurcharge(amounts, 0, uint64(5 * 10**16), false);

        assertTrue(cost > 0, "cost should be positive");
        // lossUsed and cumulativeNetCost track fee-stripped outcomeTokenNetCost, not netCost
        assertTrue(mm.lossUsed() > 0, "lossUsed should be positive");
        assertTrue(mm.lossUsed() < uint256(cost), "lossUsed should be less than netCost (fee-stripped)");
        assertTrue(mm.cumulativeNetCost() > 0, "cumulativeNetCost should be positive");
        assertTrue(mm.cumulativeNetCost() < cost, "cumulativeNetCost should be less than netCost (fee-stripped)");
    }

    function test_tradeWithSurcharge_respectsMaxCostPerTx() public {
        uint256 funding = 1000 * ONE;
        uint256 tinyCap = 1; // Very small cap

        CappedLMSRMarketMaker mm = createBinaryMarketWithCap(funding, tinyCap);
        collateral.approve(address(mm), uint256(-1));

        int256[] memory amounts = new int256[](2);
        amounts[0] = int256(10 * ONE);
        amounts[1] = 0;

        (bool success,) = address(mm).call(
            abi.encodeWithSignature("tradeWithSurcharge(int256[],int256,uint64,bool)", amounts, int256(0), uint64(0), false)
        );
        assertTrue(!success, "tradeWithSurcharge should revert when cost exceeds maxCostPerTx");
    }

    function test_tradeWithSurcharge_revertsWhenPaused() public {
        CappedLMSRMarketMaker mm = createBinaryMarket(1000 * ONE);
        collateral.approve(address(mm), uint256(-1));
        mm.pause();

        int256[] memory amounts = new int256[](2);
        amounts[0] = int256(10 * ONE);
        amounts[1] = 0;

        (bool success,) = address(mm).call(
            abi.encodeWithSignature("tradeWithSurcharge(int256[],int256,uint64,bool)", amounts, int256(0), uint64(0), false)
        );
        assertTrue(!success, "tradeWithSurcharge should revert when paused");
    }

    function test_tradeWithSurcharge_sell() public {
        CappedLMSRMarketMaker mm = createBinaryMarket(1000 * ONE);
        collateral.approve(address(mm), uint256(-1));
        ctf.setApprovalForAll(address(mm), true);

        // Buy first
        int256[] memory amounts = new int256[](2);
        amounts[0] = int256(10 * ONE);
        amounts[1] = 0;
        mm.tradeWithSurcharge(amounts, 0, uint64(5 * 10**16), false);
        uint256 lossAfterBuy = mm.lossUsed();
        assertTrue(lossAfterBuy > 0, "lossUsed should be positive after buy");

        // Sell back with surcharge
        amounts[0] = -int256(5 * ONE);
        amounts[1] = 0;
        int256 sellCost = mm.tradeWithSurcharge(amounts, 0, uint64(5 * 10**16), false);

        assertTrue(sellCost < 0, "sell should return collateral");
        assertTrue(mm.cumulativeNetCost() < int256(lossAfterBuy), "cumulativeNetCost should decrease after sell");
        assertEq(mm.lossUsed(), lossAfterBuy, "lossUsed high-water mark should not decrease");
    }

    function test_tradeWithSurcharge_zeroSurchargeMatchesTrade() public {
        // With zero surcharge, tradeWithSurcharge should cost the same as calcNetCost predicts
        CappedLMSRMarketMaker mm = createBinaryMarket(1000 * ONE);
        collateral.approve(address(mm), uint256(-1));

        int256[] memory amounts = new int256[](2);
        amounts[0] = int256(10 * ONE);
        amounts[1] = 0;

        // Get expected cost before trade
        int256 expectedCost = mm.calcNetCost(amounts);
        int256 actualCost = mm.tradeWithSurcharge(amounts, 0, 0, false);

        int256 diff = actualCost > expectedCost ? actualCost - expectedCost : expectedCost - actualCost;
        assertTrue(diff <= 1, "zero surcharge should match calcNetCost");
    }

    function test_tradeWithSurcharge_overflowReverts() public {
        CappedLMSRMarketMaker mm = createBinaryMarket(1000 * ONE);
        collateral.approve(address(mm), uint256(-1));

        int256[] memory amounts = new int256[](2);
        amounts[0] = int256(10 * ONE);
        amounts[1] = 0;

        // uint64 max = 2^64 - 1; surcharge that overflows when added to fee (0)
        // Set a base fee first, then use a surcharge that wraps around
        mm.pause();
        mm.changeFee(1);
        mm.resume();

        // max uint64 should overflow when added to fee of 1
        uint64 maxSurcharge = uint64(-1); // 2^64 - 1

        (bool success,) = address(mm).call(
            abi.encodeWithSignature("tradeWithSurcharge(int256[],int256,uint64,bool)", amounts, int256(0), maxSurcharge, false)
        );
        assertTrue(!success, "tradeWithSurcharge should revert on surcharge overflow");
    }

    function test_tradeWithSurcharge_coverCollateral() public {
        CappedLMSRMarketMaker mm = createBinaryMarket(1000 * ONE);
        collateral.approve(address(mm), uint256(-1));

        int256[] memory amounts = new int256[](2);
        amounts[0] = int256(10 * ONE);
        amounts[1] = 0;

        int256 expectedCost = mm.calcNetCost(amounts);
        int256 limit = expectedCost * 2; // generous limit

        uint256 balBefore = collateral.balanceOf(address(this));
        mm.tradeWithSurcharge(amounts, limit, 0, true);
        uint256 balAfter = collateral.balanceOf(address(this));
        uint256 totalPaid = balBefore - balAfter;

        // Should have paid exactly collateralLimit
        assertEq(totalPaid, uint256(limit), "coverCollateral should eat full collateralLimit");
    }

    function test_tradeWithSurcharge_coverCollateralNoopOnSell() public {
        CappedLMSRMarketMaker mm = createBinaryMarket(1000 * ONE);
        collateral.approve(address(mm), uint256(-1));
        ctf.setApprovalForAll(address(mm), true);

        // Buy first
        int256[] memory amounts = new int256[](2);
        amounts[0] = int256(10 * ONE);
        amounts[1] = 0;
        mm.trade(amounts, 0);

        // Sell with coverCollateral — should not transfer extra
        amounts[0] = -int256(5 * ONE);
        amounts[1] = 0;
        uint256 balBefore = collateral.balanceOf(address(this));
        mm.tradeWithSurcharge(amounts, 0, 0, true);
        uint256 balAfter = collateral.balanceOf(address(this));

        assertTrue(balAfter > balBefore, "sell should return collateral even with coverCollateral");
    }

    function test_tradeWithSurcharge_whitelistBlocks() public {
        Whitelist wl = new Whitelist();
        // Do NOT add this contract to the whitelist
        CappedLMSRMarketMaker mm = createBinaryMarketWithWhitelist(1000 * ONE, wl);
        collateral.approve(address(mm), uint256(-1));

        int256[] memory amounts = new int256[](2);
        amounts[0] = int256(10 * ONE);
        amounts[1] = 0;

        (bool success,) = address(mm).call(
            abi.encodeWithSignature("tradeWithSurcharge(int256[],int256,uint64,bool)", amounts, int256(0), uint64(0), false)
        );
        assertTrue(!success, "tradeWithSurcharge should revert for non-whitelisted address");
    }

    // ----------------------------------------------------------------
    // Funding management
    // ----------------------------------------------------------------

    function test_changeFundingOnlyWhenPaused() public {
        CappedLMSRMarketMaker mm = createBinaryMarket(1000 * ONE);
        collateral.approve(address(mm), uint256(-1));

        // Market is Running — changeFunding should revert
        (bool success,) = address(mm).call(abi.encodeWithSignature("changeFunding(int256)", int256(100 * ONE)));
        assertTrue(!success, "changeFunding should revert when market is running");

        // Pause — now it should work
        mm.pause();
        mm.changeFunding(int256(100 * ONE));
        assertEq(mm.funding(), 1100 * ONE, "funding should increase after changeFunding");
    }
}
