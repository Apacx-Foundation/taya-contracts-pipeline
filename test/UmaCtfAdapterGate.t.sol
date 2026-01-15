// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import { Test } from "forge-std/Test.sol";
import { UmaCtfAdapterGate } from "../src/UmaCtfAdapterGate.sol";
import { QuestionData } from "lib/taya-uma-ctf-adapter/src/interfaces/IUmaCtfAdapter.sol";

/// @dev Mock adapter that simulates the UmaCtfAdapter for testing the gate
contract MockUmaCtfAdapter {
    mapping(bytes32 => address) public questionCreators;
    mapping(bytes32 => bool) public flaggedQuestions;
    mapping(bytes32 => bool) public pausedQuestions;
    mapping(bytes32 => bool) public resolvedQuestions;

    error NotAdmin();

    mapping(address => bool) public admins;

    modifier onlyAdmin() {
        if (!admins[msg.sender]) revert NotAdmin();
        _;
    }

    function addAdmin(address _admin) external {
        admins[_admin] = true;
    }

    function isAdmin(address _admin) external view returns (bool) {
        return admins[_admin];
    }

    function setQuestionCreator(bytes32 questionID, address creator) external {
        questionCreators[questionID] = creator;
    }

    function getQuestion(bytes32 questionID) external view returns (QuestionData memory) {
        return QuestionData({
            requestTimestamp: block.timestamp,
            reward: 0,
            proposalBond: 0,
            liveness: 0,
            manualResolutionTimestamp: 0,
            resolved: resolvedQuestions[questionID],
            paused: pausedQuestions[questionID],
            reset: false,
            refund: false,
            rewardToken: address(0),
            creator: questionCreators[questionID],
            ancillaryData: ""
        });
    }

    function flag(bytes32 questionID) external onlyAdmin {
        flaggedQuestions[questionID] = true;
    }

    function unflag(bytes32 questionID) external onlyAdmin {
        flaggedQuestions[questionID] = false;
    }

    function pause(bytes32 questionID) external onlyAdmin {
        pausedQuestions[questionID] = true;
    }

    function unpause(bytes32 questionID) external onlyAdmin {
        pausedQuestions[questionID] = false;
    }

    function reset(bytes32) external onlyAdmin {}

    function resolveManually(bytes32 questionID, uint256[] calldata) external onlyAdmin {
        resolvedQuestions[questionID] = true;
    }

    function isFlagged(bytes32 questionID) external view returns (bool) {
        return flaggedQuestions[questionID];
    }
}

contract UmaCtfAdapterGateTest is Test {
    UmaCtfAdapterGate public gate;
    MockUmaCtfAdapter public adapter;

    address public creator = makeAddr("creator");
    address public other = makeAddr("other");
    bytes32 public questionID = keccak256("test-question");

    function setUp() public {
        adapter = new MockUmaCtfAdapter();
        gate = new UmaCtfAdapterGate(address(adapter));

        // Add gate as admin on the adapter
        adapter.addAdmin(address(gate));

        // Set up a question with creator
        adapter.setQuestionCreator(questionID, creator);
    }

    function testSetup() public view {
        assertEq(address(gate.adapter()), address(adapter));
        assertTrue(adapter.isAdmin(address(gate)));
    }

    function testConstructorRevertsZeroAddress() public {
        vm.expectRevert(UmaCtfAdapterGate.ZeroAddress.selector);
        new UmaCtfAdapterGate(address(0));
    }

    function testFlagAsCreator() public {
        vm.prank(creator);
        gate.flag(questionID);

        assertTrue(adapter.isFlagged(questionID));
    }

    function testFlagRevertsNotCreator() public {
        vm.expectRevert(UmaCtfAdapterGate.NotQuestionCreator.selector);
        vm.prank(other);
        gate.flag(questionID);
    }

    function testUnflagAsCreator() public {
        // Flag first via direct admin call
        adapter.addAdmin(address(this));
        adapter.flag(questionID);
        assertTrue(adapter.isFlagged(questionID));

        // Creator can unflag through the gate
        vm.prank(creator);
        gate.unflag(questionID);

        assertFalse(adapter.isFlagged(questionID));
    }

    function testUnflagRevertsNotCreator() public {
        adapter.addAdmin(address(this));
        adapter.flag(questionID);

        vm.expectRevert(UmaCtfAdapterGate.NotQuestionCreator.selector);
        vm.prank(other);
        gate.unflag(questionID);
    }

    function testPauseAsCreator() public {
        vm.prank(creator);
        gate.pause(questionID);

        assertTrue(adapter.pausedQuestions(questionID));
    }

    function testPauseRevertsNotCreator() public {
        vm.expectRevert(UmaCtfAdapterGate.NotQuestionCreator.selector);
        vm.prank(other);
        gate.pause(questionID);
    }

    function testUnpauseAsCreator() public {
        adapter.addAdmin(address(this));
        adapter.pause(questionID);
        assertTrue(adapter.pausedQuestions(questionID));

        vm.prank(creator);
        gate.unpause(questionID);

        assertFalse(adapter.pausedQuestions(questionID));
    }

    function testUnpauseRevertsNotCreator() public {
        adapter.addAdmin(address(this));
        adapter.pause(questionID);

        vm.expectRevert(UmaCtfAdapterGate.NotQuestionCreator.selector);
        vm.prank(other);
        gate.unpause(questionID);
    }

    function testResetAsCreator() public {
        vm.prank(creator);
        gate.reset(questionID);
        // No revert means success - mock doesn't track reset state
    }

    function testResetRevertsNotCreator() public {
        vm.expectRevert(UmaCtfAdapterGate.NotQuestionCreator.selector);
        vm.prank(other);
        gate.reset(questionID);
    }

    function testResolveManuallyAsCreator() public {
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        payouts[1] = 0;

        vm.prank(creator);
        gate.resolveManually(questionID, payouts);

        assertTrue(adapter.resolvedQuestions(questionID));
    }

    function testResolveManuallyRevertsNotCreator() public {
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        payouts[1] = 0;

        vm.expectRevert(UmaCtfAdapterGate.NotQuestionCreator.selector);
        vm.prank(other);
        gate.resolveManually(questionID, payouts);
    }

    function testDifferentCreatorsCanOnlyManageTheirQuestions() public {
        bytes32 otherQuestionID = keccak256("other-question");
        adapter.setQuestionCreator(otherQuestionID, other);

        // Creator cannot flag other's question
        vm.expectRevert(UmaCtfAdapterGate.NotQuestionCreator.selector);
        vm.prank(creator);
        gate.flag(otherQuestionID);

        // Other can flag their own question
        vm.prank(other);
        gate.flag(otherQuestionID);
        assertTrue(adapter.isFlagged(otherQuestionID));

        // Other cannot flag creator's question
        vm.expectRevert(UmaCtfAdapterGate.NotQuestionCreator.selector);
        vm.prank(other);
        gate.flag(questionID);
    }
}
