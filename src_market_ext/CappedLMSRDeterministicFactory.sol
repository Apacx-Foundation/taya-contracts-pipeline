pragma solidity ^0.5.1;

import {IERC20} from "openzeppelin-solidity/contracts/token/ERC20/IERC20.sol";
import {ConditionalTokens} from "@gnosis.pm/conditional-tokens-contracts/contracts/ConditionalTokens.sol";
import {CTHelpers} from "@gnosis.pm/conditional-tokens-contracts/contracts/CTHelpers.sol";
import {Create2CloneFactory} from "market-makers/Create2CloneFactory.sol";
import {CappedLMSRMarketMaker} from "./CappedLMSRMarketMaker.sol";
import {Whitelist} from "market-makers/Whitelist.sol";
import {LMSRMarketMakerData} from "market-makers/LMSRMarketMakerFactory.sol";
import {ERC1155TokenReceiver} from "@gnosis.pm/conditional-tokens-contracts/contracts/ERC1155/ERC1155TokenReceiver.sol";

contract CappedLMSRMarketMakerData is LMSRMarketMakerData {
    uint256 internal maxCostPerTx;
    uint256 internal lossUsed;
    int256 internal cumulativeNetCost;
}

contract CappedLMSRDeterministicFactory is Create2CloneFactory, CappedLMSRMarketMakerData {
    event CappedLMSRMarketMakerCreation(
        address indexed creator,
        CappedLMSRMarketMaker marketMaker,
        ConditionalTokens pmSystem,
        IERC20 collateralToken,
        bytes32[] conditionIds,
        uint64 fee,
        uint256 funding,
        uint256 maxCostPerTx
    );

    CappedLMSRMarketMaker public implementationMaster;

    constructor() public {
        implementationMaster = new CappedLMSRMarketMaker();
    }

    function cloneConstructor(bytes calldata consData) external {
        (
            ConditionalTokens _pmSystem,
            IERC20 _collateralToken,
            bytes32[] memory _conditionIds,
            uint64 _fee,
            Whitelist _whitelist,
            uint256 _maxCostPerTx
        ) = abi.decode(consData, (ConditionalTokens, IERC20, bytes32[], uint64, Whitelist, uint256));

        _owner = msg.sender;
        emit OwnershipTransferred(address(0), _owner);

        _supportedInterfaces[_INTERFACE_ID_ERC165] = true;
        _supportedInterfaces[
            ERC1155TokenReceiver(0).onERC1155Received.selector ^ ERC1155TokenReceiver(0).onERC1155BatchReceived.selector
        ] = true;

        require(address(_pmSystem) != address(0) && _fee < FEE_RANGE);
        pmSystem = _pmSystem;
        collateralToken = _collateralToken;
        conditionIds = _conditionIds;
        fee = _fee;
        whitelist = _whitelist;
        maxCostPerTx = _maxCostPerTx;

        atomicOutcomeSlotCount = 1;
        outcomeSlotCounts = new uint256[](conditionIds.length);
        for (uint256 i = 0; i < conditionIds.length; i++) {
            uint256 outcomeSlotCount = pmSystem.getOutcomeSlotCount(conditionIds[i]);
            atomicOutcomeSlotCount *= outcomeSlotCount;
            outcomeSlotCounts[i] = outcomeSlotCount;
        }
        require(atomicOutcomeSlotCount > 1, "conditions must be valid");

        collectionIds = new bytes32[][](conditionIds.length);
        _recordCollectionIDsForAllConditions(conditionIds.length, bytes32(0));

        stage = Stage.Paused;
        emit AMMCreated(funding);
    }

    function _recordCollectionIDsForAllConditions(uint256 conditionsLeft, bytes32 parentCollectionId) private {
        if (conditionsLeft == 0) {
            positionIds.push(CTHelpers.getPositionId(collateralToken, parentCollectionId));
            return;
        }

        conditionsLeft--;

        uint256 outcomeSlotCount = outcomeSlotCounts[conditionsLeft];

        collectionIds[conditionsLeft].push(parentCollectionId);
        for (uint256 i = 0; i < outcomeSlotCount; i++) {
            _recordCollectionIDsForAllConditions(
                conditionsLeft, CTHelpers.getCollectionId(parentCollectionId, conditionIds[conditionsLeft], 1 << i)
            );
        }
    }

    function create2CappedLMSRMarketMaker(
        uint256 saltNonce,
        ConditionalTokens pmSystem,
        IERC20 collateralToken,
        bytes32[] calldata conditionIds,
        uint64 fee,
        Whitelist whitelist,
        uint256 funding,
        uint256 maxCostPerTx
    ) external returns (CappedLMSRMarketMaker marketMaker) {
        require(funding > 0, "funding must be positive");

        marketMaker = CappedLMSRMarketMaker(
            create2Clone(
                address(implementationMaster),
                saltNonce,
                abi.encode(pmSystem, collateralToken, conditionIds, fee, whitelist, maxCostPerTx)
            )
        );

        collateralToken.transferFrom(msg.sender, address(this), funding);
        collateralToken.approve(address(marketMaker), funding);
        marketMaker.changeFunding(int256(funding));
        marketMaker.resume();
        marketMaker.transferOwnership(msg.sender);

        emit CappedLMSRMarketMakerCreation(
            msg.sender, marketMaker, pmSystem, collateralToken, conditionIds, fee, funding, maxCostPerTx
        );
    }
}
