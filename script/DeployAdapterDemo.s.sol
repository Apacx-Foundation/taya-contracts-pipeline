// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {UmaCtfAdapterDemo} from "taya-uma-ctf-adapter/UmaCtfAdapterDemo.sol";
import {UmaCtfAdapterGate} from "../src/UmaCtfAdapterGate.sol";
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
        address fpmmFactory = vm.deployCode("out_market/FPMMDeterministicFactory.sol/FPMMDeterministicFactory.json");
        // Note: CappedLMSRDeterministicFactory requires Fixed192x64Math library to be pre-linked via --libraries flag
        address cappedLmsrFactory = vm.deployCode("out_market_ext/CappedLMSRDeterministicFactory.sol/CappedLMSRDeterministicFactory.json");
        address whitelist = vm.deployCode("out_market_ext/WhitelistAccessControl.sol/WhitelistAccessControl.json");

        UmaCtfAdapterDemo ctfAdapter = new UmaCtfAdapterDemo(ctf, finder, oo);
        UmaCtfAdapterGate ctfAdapterGate = new UmaCtfAdapterGate(address(ctfAdapter));

        // Add admin auth to the Admin addresses and the gate
        ctfAdapter.addAdmin(address(ctfAdapterGate));
        bool isDeployerAdmin = false;
        for (uint256 i = 0; i < admins.length; i++) {
            ctfAdapter.addAdmin(admins[i]);
            // Grant each admin the admin role on the whitelist
            (bool aOk,) = whitelist.call(abi.encodeWithSignature("addAdmin(address)", admins[i]));
            require(aOk, "whitelist addAdmin failed");
            isDeployerAdmin = isDeployerAdmin || admins[i] == msg.sender;
        }
        // Deployer renounces whitelist admin if not in admins list
        if (!isDeployerAdmin) {
            (bool rOk,) = whitelist.call(abi.encodeWithSignature("renounceAdmin()"));
            require(rOk, "whitelist renounceAdmin failed");
        }
        // revoke deployer's adapter auth
        if (!isDeployerAdmin) ctfAdapter.renounceAdmin();
        vm.stopBroadcast();

        // Verify
        for (uint256 i = 0; i < admins.length; i++) {
            _verifyStatePostDeployment(admins[i], ctf, address(ctfAdapter), address(ctfAdapterGate), whitelist);
        }
        result = DeployResult({
            ctf: ctf,
            umaCtfAdapter: address(ctfAdapter),
            umaCtfAdapterGate: address(ctfAdapterGate),
            fpmmFactory: fpmmFactory,
            cappedLmsrFactory: cappedLmsrFactory,
            whitelist: whitelist,
            deployedAtBlock: block.number
        });

        console2.log("ConditionalTokens deployed at:", result.ctf);
        console2.log("UmaCtfAdapterDemo deployed at:", result.umaCtfAdapter);
        console2.log("UmaCtfAdapterGate deployed at:", result.umaCtfAdapterGate);
        console2.log("FPMMDeterministicFactory deployed at:", result.fpmmFactory);
        console2.log("CappedLMSRDeterministicFactory deployed at:", result.cappedLmsrFactory);
        console2.log("WhitelistAccessControl deployed at:", result.whitelist);
    }

    function _verifyStatePostDeployment(address admin, address ctf, address adapter, address gate, address whitelist)
        internal
        view
        returns (bool)
    {
        UmaCtfAdapterDemo ctfAdapter = UmaCtfAdapterDemo(adapter);
        UmaCtfAdapterGate ctfAdapterGate = UmaCtfAdapterGate(gate);

        if (!ctfAdapter.isAdmin(admin)) revert("Adapter admin not set");
        if (!ctfAdapter.isAdmin(gate)) revert("Adapter gate admin not set");
        if (address(ctfAdapter.ctf()) != ctf) revert("Unexpected ConditionalTokensFramework set on adapter");
        if (address(ctfAdapterGate.adapter()) != adapter) revert("Unexpected adapter set on gate");

        // Verify whitelist admin role
        (bool ok, bytes memory ret) = whitelist.staticcall(abi.encodeWithSignature("isAdmin(address)", admin));
        if (!ok || !abi.decode(ret, (bool))) revert("Whitelist admin not set");

        // Verify whitelist is not yet initialized (KMS does this at runtime)
        (bool ok2, bytes memory ret2) = whitelist.staticcall(abi.encodeWithSignature("initialized()"));
        if (!ok2 || abi.decode(ret2, (bool))) revert("Whitelist should not be initialized at deploy time");

        return true;
    }
}
