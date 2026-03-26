// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UmaCtfAdapterDemo} from "taya-uma-ctf-adapter/UmaCtfAdapterDemo.sol";
import {PlatformRegistry} from "../src/PlatformRegistry.sol";
import {PlatformUser} from "../src/PlatformUser.sol";
import {DeploymentHelper, DeployResult, DeployParams} from "./DeploymentHelper.sol";

contract DeployAdapterDemo is Script {
    function run() external returns (DeployResult memory result) {
        DeploymentHelper helper = new DeploymentHelper();
        DeployParams memory params = helper.readDeploymentConfig(block.chainid);
        result = deployAdapter(params.admins, params.uma.finder, params.uma.optimisticOracleV2);
        helper.writeDeploymentOutput(block.chainid, result);
    }

    function deployAdapter(address[] memory admins, address finder, address oo)
        internal
        returns (DeployResult memory result)
    {
        vm.startBroadcast();
        address ctf = vm.deployCode("out_ctf/ConditionalTokens.sol/ConditionalTokens.json");
        // Note: CappedLMSRDeterministicFactory requires Fixed192x64Math library to be pre-linked via --libraries flag
        address cappedLmsrFactory =
            vm.deployCode("out_market_ext/CappedLMSRDeterministicFactory.sol/CappedLMSRDeterministicFactory.json");
        address whitelistFactory = vm.deployCode("out_market_ext/WhitelistFactory.sol/WhitelistFactory.json");

        UmaCtfAdapterDemo ctfAdapter = new UmaCtfAdapterDemo(ctf, finder, oo);
        address registry = _deployRegistry(admins, whitelistFactory, address(ctfAdapter), cappedLmsrFactory, ctf);

        // Assign registry as admin
        ctfAdapter.addAdmin(registry);

        // Additionally add Admin addresses
        bool isDeployerAdmin = false;
        for (uint256 i = 0; i < admins.length; i++) {
            ctfAdapter.addAdmin(admins[i]);
            isDeployerAdmin = isDeployerAdmin || admins[i] == msg.sender;
        }

        // revoke deployer's auth
        if (!isDeployerAdmin) ctfAdapter.renounceAdmin();

        vm.stopBroadcast();

        // Verify
        for (uint256 i = 0; i < admins.length; i++) {
            _verifyStatePostDeployment(admins[i], ctf, address(ctfAdapter), address(registry));
        }
        // Check registry is admin
        require(ctfAdapter.isAdmin(registry), "Adapter gate admin is not set");

        result = DeployResult({
            ctf: ctf,
            umaCtfAdapter: address(ctfAdapter),
            cappedLmsrFactory: cappedLmsrFactory,
            whitelistFactory: whitelistFactory,
            platformRegistry: registry,
            deployedAtBlock: block.number
        });

        console2.log("ConditionalTokens deployed at:", result.ctf);
        console2.log("UmaCtfAdapterDemo deployed at:", result.umaCtfAdapter);
        console2.log("CappedLMSRDeterministicFactory deployed at:", result.cappedLmsrFactory);
        console2.log("WhitelistFactory deployed at:", result.whitelistFactory);
        console2.log("PlatformRegistry deployed at:", result.platformRegistry);
    }

    function _deployRegistry(address[] memory admins, address wlFactory, address adapterAddr, address factoryAddr, address ctfAddr) internal returns (address) {
        PlatformRegistry impl = new PlatformRegistry();
        address walletImpl = address(new PlatformUser());
        address[] memory kmsSigners = new address[](0);
        bytes memory initData = abi.encodeCall(
            PlatformRegistry.initialize, (msg.sender, walletImpl, wlFactory, adapterAddr, factoryAddr, ctfAddr, admins, kmsSigners)
        );
        return address(new ERC1967Proxy(address(impl), initData));
    }

    function _verifyStatePostDeployment(address admin, address ctf, address adapter, address registry)
        internal
        view
        returns (bool)
    {
        UmaCtfAdapterDemo ctfAdapter = UmaCtfAdapterDemo(adapter);
        PlatformRegistry platformRegistry = PlatformRegistry(registry);

        if (!platformRegistry.hasRole(platformRegistry.ADMIN_ROLE(), admin)) revert("Registry admin not set");
        if (!ctfAdapter.isAdmin(admin)) revert("Adapter admin not set");
        if (address(ctfAdapter.ctf()) != ctf) revert("Unexpected ConditionalTokensFramework set on adapter");

        return true;
    }
}
