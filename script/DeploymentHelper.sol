// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import { Script } from "forge-std/Script.sol";
import { CommonBase } from "forge-std/Base.sol";
import { stdJson } from "forge-std/StdJson.sol";

struct DeployResult {
    address ctf;
    address umaCtfAdapter;
    address fpmmFactory;
}

struct DeployParams {
    address[] admins;
    UmaConfig uma;
}

struct UmaConfig {
    address finder;
    address optimisticOracleV2;
}

contract DeploymentHelper is CommonBase {
    using stdJson for string;

    function readDeploymentConfig(uint256 chainId) public view returns (DeployParams memory) {
        string memory path =
            string(abi.encodePacked(vm.projectRoot(), "/config/networks/", vm.toString(chainId), ".json"));
        string memory json = vm.readFile(path);
        DeployParams memory params;
        params.admins = abi.decode(vm.parseJson(json, ".admins"), (address[]));
        params.uma.finder = abi.decode(vm.parseJson(json, ".uma.finder"), (address));
        params.uma.optimisticOracleV2 = abi.decode(vm.parseJson(json, ".uma.optimisticOracleV2"), (address));
        return params;
    }

    function writeDeploymentOutput(uint256 chainId, DeployResult memory result) public {
        string memory path =
            string(abi.encodePacked(vm.projectRoot(), "/script/output/", vm.toString(chainId), ".json"));

        string memory artifacts = "artifacts";
        artifacts.serialize("ctf", result.ctf);
        artifacts.serialize("fpmmFactory", result.fpmmFactory);
        string memory json = artifacts.serialize("umaAdapter", result.umaCtfAdapter);
        json.write(path);
    }
}
