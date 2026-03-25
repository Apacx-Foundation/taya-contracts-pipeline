// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UmaCtfAdapter} from "lib/taya-uma-ctf-adapter/src/UmaCtfAdapter.sol";
import {UmaCtfAdapterGate} from "../src/UmaCtfAdapterGate.sol";
import {PlatformRegistry} from "../src/PlatformRegistry.sol";
import {PlatformUser} from "../src/PlatformUser.sol";
import {DeploymentHelper, DeployResult, DeployParams} from "./DeploymentHelper.sol";

contract DeployAdapter is Script {
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
        address fpmmFactory = vm.deployCode("out_market/FPMMDeterministicFactory.sol/FPMMDeterministicFactory.json");
        // Note: CappedLMSRDeterministicFactory requires Fixed192x64Math library to be pre-linked via --libraries flag
        address cappedLmsrFactory = vm.deployCode("out_market_ext/CappedLMSRDeterministicFactory.sol/CappedLMSRDeterministicFactory.json");
        address whitelistFactory = vm.deployCode("out_market_ext/WhitelistFactory.sol/WhitelistFactory.json");

        UmaCtfAdapter ctfAdapter = new UmaCtfAdapter(ctf, finder, oo);
        UmaCtfAdapterGate ctfAdapterGate = new UmaCtfAdapterGate(address(ctfAdapter));

        // Add admin auth to the Admin addresses and the gate
        ctfAdapter.addAdmin(address(ctfAdapterGate));
        bool isDeployerAdmin = false;
        for (uint256 i = 0; i < admins.length; i++) {
            ctfAdapter.addAdmin(admins[i]);
            isDeployerAdmin = isDeployerAdmin || admins[i] == msg.sender;
        }
        // revoke deployer's auth
        if (!isDeployerAdmin) ctfAdapter.renounceAdmin();

        address registry = _deployRegistry(admins, whitelistFactory);

        vm.stopBroadcast();

        // Verify
        for (uint256 i = 0; i < admins.length; i++) {
            _verifyStatePostDeployment(admins[i], ctf, address(ctfAdapter), address(ctfAdapterGate));
        }
        result = DeployResult({
            ctf: ctf,
            umaCtfAdapter: address(ctfAdapter),
            umaCtfAdapterGate: address(ctfAdapterGate),
            fpmmFactory: fpmmFactory,
            cappedLmsrFactory: cappedLmsrFactory,
            whitelistFactory: whitelistFactory,
            platformRegistry: registry,
            deployedAtBlock: block.number
        });

        console2.log("ConditionalTokens deployed at:", result.ctf);
        console2.log("UmaCtfAdapter deployed at:", result.umaCtfAdapter);
        console2.log("UmaCtfAdapterGate deployed at:", result.umaCtfAdapterGate);
        console2.log("FPMMDeterministicFactory deployed at:", result.fpmmFactory);
        console2.log("CappedLMSRDeterministicFactory deployed at:", result.cappedLmsrFactory);
        console2.log("WhitelistFactory deployed at:", result.whitelistFactory);
        console2.log("PlatformRegistry deployed at:", result.platformRegistry);
    }

    function _deployRegistry(address[] memory admins, address wlFactory) internal returns (address) {
        PlatformRegistry impl = new PlatformRegistry();
        PlatformUser walletImpl = new PlatformUser();
        address[] memory kmsSigners = new address[](0); // granted post-deploy by admins
        bytes memory initData = abi.encodeWithSelector(
            PlatformRegistry.initialize.selector, msg.sender, address(walletImpl), wlFactory, admins, kmsSigners
        );
        return address(new ERC1967Proxy(address(impl), initData));
    }

    function _verifyStatePostDeployment(address admin, address ctf, address adapter, address gate)
        internal
        view
        returns (bool)
    {
        UmaCtfAdapter ctfAdapter = UmaCtfAdapter(adapter);
        UmaCtfAdapterGate ctfAdapterGate = UmaCtfAdapterGate(gate);

        if (!ctfAdapter.isAdmin(admin)) revert("Adapter admin not set");
        if (!ctfAdapter.isAdmin(gate)) revert("Adapter gate admin not set");
        if (address(ctfAdapter.ctf()) != ctf) revert("Unexpected ConditionalTokensFramework set on adapter");
        if (address(ctfAdapterGate.adapter()) != adapter) revert("Unexpected adapter set on gate");

        return true;
    }
}
