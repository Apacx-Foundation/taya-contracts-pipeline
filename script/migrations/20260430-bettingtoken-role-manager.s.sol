// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {BettingToken} from "../../src/BettingToken.sol";

/// @notice Upgrades each deployed BettingToken proxy on the current chain to a
/// new implementation that introduces ROLE_MANAGER_ROLE + BURNER_ROLE and
/// rewires MINTER/BURNER/BLACKLISTER role admins to ROLE_MANAGER_ROLE.
///
/// Targets: every BettingToken proxy listed in script/output/<chainId>.json
/// under the keys "bettingToken" and "bettingTokenCny" (skipped if missing).
/// Bootstrap roleManagers + burners = the admin set in
/// config/networks/<chainId>.json.
///
/// Post-upgrade assertions run inside the broadcast block; if any fail the
/// script reverts and run_migration.sh does NOT record the migration in
/// history, so the migration can be re-run after fixing the cause.
contract Migration_20260430_BettingTokenRoleManager is Script {
    using stdJson for string;

    string[2] internal PROXY_KEYS = [".bettingToken", ".bettingTokenCny"];

    function run() external {
        uint256 chainId = block.chainid;
        address[] memory admins = _readAdmins(chainId);
        address[] memory proxies = _readProxies(chainId);

        require(admins.length > 0, "no admins configured");
        require(proxies.length > 0, "no BettingToken proxies on this chain");

        vm.startBroadcast();
        BettingToken newImpl = new BettingToken();

        for (uint256 i = 0; i < proxies.length; i++) {
            address proxy = proxies[i];
            console2.log("Upgrading BettingToken proxy:", proxy);

            BettingToken token = BettingToken(proxy);
            token.upgradeToAndCall(
                address(newImpl), abi.encodeCall(BettingToken.initializeV2, (admins, admins))
            );

            _verifyUpgrade(token, admins);
            console2.log("  ok");
        }
        vm.stopBroadcast();

        console2.log("New BettingToken impl:", address(newImpl));
    }

    function _verifyUpgrade(BettingToken token, address[] memory expectedHolders) internal view {
        bytes32 minterRole = token.MINTER_ROLE();
        bytes32 burnerRole = token.BURNER_ROLE();
        bytes32 blacklisterRole = token.BLACKLISTER_ROLE();
        bytes32 roleManagerRole = token.ROLE_MANAGER_ROLE();
        bytes32 defaultAdminRole = token.DEFAULT_ADMIN_ROLE();

        require(token.getRoleAdmin(minterRole) == roleManagerRole, "MINTER admin != ROLE_MANAGER");
        require(token.getRoleAdmin(burnerRole) == roleManagerRole, "BURNER admin != ROLE_MANAGER");
        require(token.getRoleAdmin(blacklisterRole) == roleManagerRole, "BLACKLISTER admin != ROLE_MANAGER");
        require(token.getRoleAdmin(roleManagerRole) == defaultAdminRole, "ROLE_MANAGER admin != DEFAULT_ADMIN");

        for (uint256 i = 0; i < expectedHolders.length; i++) {
            require(token.hasRole(roleManagerRole, expectedHolders[i]), "role-manager not granted");
            require(token.hasRole(burnerRole, expectedHolders[i]), "burner not granted");
        }
    }

    function _readAdmins(uint256 chainId) internal view returns (address[] memory) {
        string memory path =
            string(abi.encodePacked(vm.projectRoot(), "/config/networks/", vm.toString(chainId), ".json"));
        string memory json = vm.readFile(path);
        return abi.decode(vm.parseJson(json, ".admins"), (address[]));
    }

    function _readProxies(uint256 chainId) internal view returns (address[] memory) {
        string memory path =
            string(abi.encodePacked(vm.projectRoot(), "/script/output/", vm.toString(chainId), ".json"));
        string memory json = vm.readFile(path);

        address[] memory tmp = new address[](PROXY_KEYS.length);
        uint256 count;
        for (uint256 i = 0; i < PROXY_KEYS.length; i++) {
            if (!vm.keyExists(json, PROXY_KEYS[i])) continue;
            address addr = abi.decode(vm.parseJson(json, PROXY_KEYS[i]), (address));
            if (addr == address(0)) continue;
            tmp[count++] = addr;
        }

        address[] memory out = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            out[i] = tmp[i];
        }
        return out;
    }
}
