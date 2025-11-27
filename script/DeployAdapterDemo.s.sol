// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import { Script } from "forge-std/Script.sol";
import { console2 } from "forge-std/console2.sol";

import { UmaCtfAdapterDemo } from "taya-uma-ctf-adapter/UmaCtfAdapterDemo.sol";
import { DeploymentHelper, DeployResult, DeployParams } from "./DeploymentHelper.sol";

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

        UmaCtfAdapterDemo ctfAdapter = new UmaCtfAdapterDemo(ctf, finder, oo);

        // Add admin auth to the Admin address
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
            _verifyStatePostDeployment(admins[i], ctf, address(ctfAdapter));
        }
        result = DeployResult({ ctf: ctf, umaCtfAdapter: address(ctfAdapter), fpmmFactory: fpmmFactory });

        console2.log("ConditionalTokens deployed at:", result.ctf);
        console2.log("UmaCtfAdapterDemo deployed at:", result.umaCtfAdapter);
        console2.log("FPMMDeterministicFactory deployed at:", result.fpmmFactory);
    }

    function _verifyStatePostDeployment(address admin, address ctf, address adapter) internal view returns (bool) {
        UmaCtfAdapterDemo ctfAdapter = UmaCtfAdapterDemo(adapter);

        if (!ctfAdapter.isAdmin(admin)) revert("Adapter admin not set");
        if (address(ctfAdapter.ctf()) != ctf) revert("Unexpected ConditionalTokensFramework set on adapter");

        return true;
    }
}
