// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {BettingToken} from "../../src/BettingToken.sol";

interface IAdminAuth {
    function isAdmin(address addr) external view returns (bool);
    function addAdmin(address admin) external;
}

/**
 * @title 20260331-migrate-admin
 * @notice Ensures all admin-capable contracts on the chain have the correct admins set.
 *
 * Reads admins from config/networks/<chainId>.json and deployed addresses from
 * script/output/<chainId>.json, then grants admin on:
 *   - UmaCtfAdapterDemo  (addAdmin)
 *   - WhitelistAccessControl (addAdmin)
 *   - BettingToken (DEFAULT_ADMIN_ROLE, MINTER_ROLE, BLACKLISTER_ROLE)
 */
contract MigrateAdmin is Script {
    using stdJson for string;

    function run() external {
        // Read config
        string memory configPath = string(
            abi.encodePacked(vm.projectRoot(), "/config/networks/", vm.toString(block.chainid), ".json")
        );
        string memory configJson = vm.readFile(configPath);
        address[] memory admins = abi.decode(vm.parseJson(configJson, ".admins"), (address[]));

        // Read deployed addresses
        string memory outputPath = string(
            abi.encodePacked(vm.projectRoot(), "/script/output/", vm.toString(block.chainid), ".json")
        );
        string memory outputJson = vm.readFile(outputPath);
        address umaAdapter = abi.decode(vm.parseJson(outputJson, ".umaAdapter"), (address));
        address whitelist = abi.decode(vm.parseJson(outputJson, ".whitelist"), (address));
        address bettingTokenProxy = abi.decode(vm.parseJson(outputJson, ".bettingToken"), (address));

        vm.startBroadcast();

        for (uint256 i = 0; i < admins.length; i++) {
            address admin = admins[i];

            // --- UmaCtfAdapterDemo ---
            _ensureAdminAuth(umaAdapter, admin, "UmaCtfAdapterDemo");

            // --- WhitelistAccessControl ---
            _ensureAdminAuth(whitelist, admin, "WhitelistAccessControl");

            // --- BettingToken ---
            _ensureBettingTokenRoles(BettingToken(bettingTokenProxy), admin);
        }

        vm.stopBroadcast();
        console2.log("Migration complete");
    }

    function _ensureAdminAuth(address target, address admin, string memory label) internal {
        IAdminAuth auth = IAdminAuth(target);
        if (!auth.isAdmin(admin)) {
            auth.addAdmin(admin);
            console2.log(string(abi.encodePacked(label, ": granted admin to")), admin);
        } else {
            console2.log(string(abi.encodePacked(label, ": already admin")), admin);
        }
    }

    function _ensureBettingTokenRoles(BettingToken token, address admin) internal {
        bytes32 adminRole = token.DEFAULT_ADMIN_ROLE();
        bytes32 minterRole = token.MINTER_ROLE();
        bytes32 blacklisterRole = token.BLACKLISTER_ROLE();

        if (!token.hasRole(adminRole, admin)) {
            token.grantRole(adminRole, admin);
            console2.log("BettingToken: granted DEFAULT_ADMIN_ROLE to", admin);
        }
        if (!token.hasRole(minterRole, admin)) {
            token.grantRole(minterRole, admin);
            console2.log("BettingToken: granted MINTER_ROLE to", admin);
        }
        if (!token.hasRole(blacklisterRole, admin)) {
            token.grantRole(blacklisterRole, admin);
            console2.log("BettingToken: granted BLACKLISTER_ROLE to", admin);
        }
    }
}
