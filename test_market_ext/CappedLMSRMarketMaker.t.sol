pragma solidity ^0.5.1;

import {ERC20Mintable} from "openzeppelin-solidity/contracts/token/ERC20/ERC20Mintable.sol";
import {ConditionalTokens} from "@gnosis.pm/conditional-tokens-contracts/contracts/ConditionalTokens.sol";
import {CappedLMSRMarketMaker} from "../src_market_ext/CappedLMSRMarketMaker.sol";
import {CappedLMSRMarketMakerFactory} from "../src_market_ext/CappedLMSRMarketMakerFactory.sol";
import {LMSRMarketMaker} from "market-makers/LMSRMarketMaker.sol";
import {LMSRMarketMakerFactory} from "market-makers/LMSRMarketMakerFactory.sol";
import {Whitelist} from "market-makers/Whitelist.sol";
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
    CappedLMSRMarketMakerFactory public factory;
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
        factory = new CappedLMSRMarketMakerFactory();
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

        return factory.createCappedLMSRMarketMaker(
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
            factory.createCappedLMSRMarketMaker(ctf, collateral, conditionIds, 0, Whitelist(0), funding, 0);

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
    // maxTxCostIncrease
    // ----------------------------------------------------------------

    function test_maxTxCostIncreaseRevertsOnExceed() public {
        uint256 funding = 1000 * ONE;

        int256[] memory amounts = new int256[](2);
        amounts[0] = int256(10 * ONE);
        amounts[1] = 0;

        // --- Part 1: tiny cap blocks all positive-cost trades ---
        uint256 tinyCap = 1;
        CappedLMSRMarketMaker capped = createBinaryMarketWithCap(funding, tinyCap);
        assertEq(capped.maxTxCostIncrease(), tinyCap, "maxTxCostIncrease not stored");
        collateral.approve(address(capped), uint256(-1));

        int256 cost = capped.calcNetCost(amounts);
        assertTrue(cost > int256(tinyCap), "test setup: cost should exceed tiny cap");

        (bool success,) = address(capped).call(abi.encodeWithSignature("trade(int256[],int256)", amounts, int256(0)));
        assertTrue(!success, "should revert when cost exceeds maxTxCostIncrease");

        // --- Part 2: large cap allows trade ---
        uint256 largeCap = funding;
        CappedLMSRMarketMaker uncapped = createBinaryMarketWithCap(funding, largeCap);
        collateral.approve(address(uncapped), uint256(-1));

        uncapped.trade(amounts, 0);
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

        return factory.createCappedLMSRMarketMaker(
            ctf,
            collateral,
            conditionIds,
            0, // fee
            wl,
            funding,
            0 // no tx cap
        );
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
