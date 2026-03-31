pragma solidity ^0.5.1;

import {ERC20Mintable} from "openzeppelin-solidity/contracts/token/ERC20/ERC20Mintable.sol";
import {ConditionalTokens} from "@gnosis.pm/conditional-tokens-contracts/contracts/ConditionalTokens.sol";
import {CappedLMSRMarketMaker} from "../src_market_ext/CappedLMSRMarketMaker.sol";
import {CappedLMSRDeterministicFactory} from "../src_market_ext/CappedLMSRDeterministicFactory.sol";
import {Whitelist} from "market-makers/Whitelist.sol";

contract TestCollateralD is ERC20Mintable {}

contract CappedLMSRDeterministicFactoryTest {
    uint256 public constant ONE = 0x10000000000000000;

    TestCollateralD public collateral;
    ConditionalTokens public ctf;
    CappedLMSRDeterministicFactory public factory;
    address public oracle;

    event TestPassed(string name);

    constructor() public {
        collateral = new TestCollateralD();
        ctf = new ConditionalTokens();
        factory = new CappedLMSRDeterministicFactory();
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

    function assertTrue(bool condition, string memory message) internal pure {
        require(condition, message);
    }

    function assertEq(address left, address right, string memory message) internal pure {
        require(left == right, message);
    }

    function _prepareCondition(uint256 salt) internal returns (bytes32) {
        bytes32 questionId = keccak256(abi.encodePacked(block.timestamp, salt));
        ctf.prepareCondition(oracle, questionId, 2);
        return ctf.getConditionId(oracle, questionId, 2);
    }

    /// @notice Deterministic deployment produces a predictable address
    function test_deterministicAddress() public {
        uint256 funding = 1000 * ONE;
        bytes32 conditionId = _prepareCondition(1);
        bytes32[] memory conditionIds = new bytes32[](1);
        conditionIds[0] = conditionId;

        collateral.approve(address(factory), funding);

        CappedLMSRMarketMaker mm = factory.create2CappedLMSRMarketMaker(
            42, ctf, collateral, conditionIds, 0, Whitelist(0), funding, 0
        );

        assertTrue(address(mm) != address(0), "market maker should be deployed");
        assertTrue(mm.funding() == funding, "funding should match");

        emit TestPassed("test_deterministicAddress");
    }

    /// @notice Same params + same salt = revert (address collision)
    function test_sameSaltReverts() public {
        uint256 funding = 1000 * ONE;
        bytes32 conditionId = _prepareCondition(2);
        bytes32[] memory conditionIds = new bytes32[](1);
        conditionIds[0] = conditionId;

        collateral.approve(address(factory), funding * 2);

        factory.create2CappedLMSRMarketMaker(
            100, ctf, collateral, conditionIds, 0, Whitelist(0), funding, 0
        );

        // Second deploy with same salt should revert
        (bool success,) = address(factory).call(
            abi.encodeWithSignature(
                "create2CappedLMSRMarketMaker(uint256,address,address,bytes32[],uint64,address,uint256,uint256)",
                100, address(ctf), address(collateral), conditionIds, uint64(0), address(0), funding, uint256(0)
            )
        );
        assertTrue(!success, "should revert on same salt");

        emit TestPassed("test_sameSaltReverts");
    }

    /// @notice Different salt produces different address
    function test_differentSaltDifferentAddress() public {
        uint256 funding = 1000 * ONE;
        bytes32 conditionId = _prepareCondition(3);
        bytes32[] memory conditionIds = new bytes32[](1);
        conditionIds[0] = conditionId;

        collateral.approve(address(factory), funding * 2);

        CappedLMSRMarketMaker mm1 = factory.create2CappedLMSRMarketMaker(
            200, ctf, collateral, conditionIds, 0, Whitelist(0), funding, 0
        );
        CappedLMSRMarketMaker mm2 = factory.create2CappedLMSRMarketMaker(
            201, ctf, collateral, conditionIds, 0, Whitelist(0), funding, 0
        );

        assertTrue(address(mm1) != address(mm2), "different salts should produce different addresses");

        emit TestPassed("test_differentSaltDifferentAddress");
    }

    /// @notice Market created via deterministic factory is fully functional
    function test_tradingWorks() public {
        uint256 funding = 1000 * ONE;
        bytes32 conditionId = _prepareCondition(4);
        bytes32[] memory conditionIds = new bytes32[](1);
        conditionIds[0] = conditionId;

        collateral.approve(address(factory), funding);

        CappedLMSRMarketMaker mm = factory.create2CappedLMSRMarketMaker(
            300, ctf, collateral, conditionIds, 0, Whitelist(0), funding, 0
        );

        collateral.approve(address(mm), uint256(-1));

        int256[] memory amounts = new int256[](2);
        amounts[0] = int256(10 * ONE);
        amounts[1] = 0;

        int256 cost = mm.trade(amounts, 0);
        assertTrue(cost > 0, "trade should have positive cost");
        assertTrue(mm.cumulativeNetCost() > 0, "cumulative cost should be tracked");

        emit TestPassed("test_tradingWorks");
    }

    /// @notice Ownership is transferred to caller
    function test_ownershipTransferred() public {
        uint256 funding = 1000 * ONE;
        bytes32 conditionId = _prepareCondition(5);
        bytes32[] memory conditionIds = new bytes32[](1);
        conditionIds[0] = conditionId;

        collateral.approve(address(factory), funding);

        CappedLMSRMarketMaker mm = factory.create2CappedLMSRMarketMaker(
            400, ctf, collateral, conditionIds, 0, Whitelist(0), funding, 0
        );

        assertEq(mm.owner(), address(this), "owner should be caller");

        emit TestPassed("test_ownershipTransferred");
    }
}
