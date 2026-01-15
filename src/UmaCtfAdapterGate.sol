// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {QuestionData, IUmaCtfAdapter} from "../lib/taya-uma-ctf-adapter/src/interfaces/IUmaCtfAdapter.sol";

interface IUmaCtfAdapterFull is IUmaCtfAdapter {
    function unflag(bytes32 questionID) external;
    function resolveManually(bytes32 questionID, uint256[] calldata payouts) external;
}

/// @title UmaCtfAdapterGate
/// @notice A gate contract that allows question creators to call admin functions on the UMA CTF Adapter
/// @dev This contract must be added as an admin on the target UMA CTF Adapter
/// @dev It checks if msg.sender is the question creator before forwarding admin calls
contract UmaCtfAdapterGate {
    error NotQuestionCreator();
    error ZeroAddress();

    event AdapterSet(address indexed adapter);

    /// @notice The UMA CTF Adapter this gate forwards calls to
    IUmaCtfAdapterFull public immutable adapter;

    /// @param _adapter The address of the UMA CTF Adapter
    constructor(address _adapter) {
        if (_adapter == address(0)) revert ZeroAddress();
        adapter = IUmaCtfAdapterFull(_adapter);
        emit AdapterSet(_adapter);
    }

    /// @notice Ensures the caller is the creator of the specified question
    modifier onlyQuestionCreator(bytes32 questionID) {
        QuestionData memory question = adapter.getQuestion(questionID);
        if (msg.sender != question.creator) revert NotQuestionCreator();
        _;
    }

    /// @notice Flag a question for manual resolution
    /// @dev Only callable by the question creator
    /// @param questionID The unique question identifier
    function flag(bytes32 questionID) external onlyQuestionCreator(questionID) {
        adapter.flag(questionID);
    }

    /// @notice Unflag a question, canceling manual resolution
    /// @dev Only callable by the question creator
    /// @param questionID The unique question identifier
    function unflag(bytes32 questionID) external onlyQuestionCreator(questionID) {
        adapter.unflag(questionID);
    }

    /// @notice Pause a question
    /// @dev Only callable by the question creator
    /// @param questionID The unique question identifier
    function pause(bytes32 questionID) external onlyQuestionCreator(questionID) {
        adapter.pause(questionID);
    }

    /// @notice Unpause a question
    /// @dev Only callable by the question creator
    /// @param questionID The unique question identifier
    function unpause(bytes32 questionID) external onlyQuestionCreator(questionID) {
        adapter.unpause(questionID);
    }

    /// @notice Reset a question
    /// @dev Only callable by the question creator
    /// @param questionID The unique question identifier
    function reset(bytes32 questionID) external onlyQuestionCreator(questionID) {
        adapter.reset(questionID);
    }

    /// @notice Manually resolve a flagged question
    /// @dev Only callable by the question creator
    /// @dev Question must be flagged and safety period must have passed
    /// @param questionID The unique question identifier
    /// @param payouts Array of position payouts (e.g., [1, 0] for YES, [0, 1] for NO, [1, 1] for TIE)
    function resolveManually(bytes32 questionID, uint256[] calldata payouts) external onlyQuestionCreator(questionID) {
        adapter.resolveManually(questionID, payouts);
    }
}
