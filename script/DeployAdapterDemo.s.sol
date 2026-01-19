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
        // Note: LMSRMarketMakerFactory requires Fixed192x64Math library to be pre-linked via --libraries flag
        address lmsrFactory = vm.deployCode("out_market/LMSRMarketMakerFactory.sol/LMSRMarketMakerFactory.json");

        UmaCtfAdapterDemo ctfAdapter = new UmaCtfAdapterDemo(ctf, finder, oo);
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
            lmsrFactory: lmsrFactory
        });

        console2.log("ConditionalTokens deployed at:", result.ctf);
        console2.log("UmaCtfAdapterDemo deployed at:", result.umaCtfAdapter);
        console2.log("UmaCtfAdapterGate deployed at:", result.umaCtfAdapterGate);
        console2.log("FPMMDeterministicFactory deployed at:", result.fpmmFactory);
        console2.log("LMSRMarketMakerFactory deployed at:", result.lmsrFactory);
    }

    function _verifyStatePostDeployment(address admin, address ctf, address adapter, address gate)
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

        return true;
    }
}
