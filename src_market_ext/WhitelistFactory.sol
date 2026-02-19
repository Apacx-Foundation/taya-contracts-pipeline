pragma solidity ^0.5.1;

import {Whitelist} from "market-makers/Whitelist.sol";

/// @title Factory for creating Whitelist contracts
/// @notice Deploys new Whitelist instances and transfers ownership to the caller
contract WhitelistFactory {
    event WhitelistCreated(address indexed creator, Whitelist whitelist);

    /// @notice Create a new Whitelist contract
    /// @return whitelist The newly created Whitelist contract
    function createWhitelist() external returns (Whitelist whitelist) {
        whitelist = new Whitelist();
        whitelist.transferOwnership(msg.sender);
        emit WhitelistCreated(msg.sender, whitelist);
    }

    /// @notice Create a new Whitelist contract with initial users
    /// @param initialUsers Array of addresses to whitelist immediately
    /// @return whitelist The newly created Whitelist contract
    function createWhitelistWithUsers(address[] calldata initialUsers) external returns (Whitelist whitelist) {
        whitelist = new Whitelist();
        if (initialUsers.length > 0) {
            whitelist.addToWhitelist(initialUsers);
        }
        whitelist.transferOwnership(msg.sender);
        emit WhitelistCreated(msg.sender, whitelist);
    }
}
