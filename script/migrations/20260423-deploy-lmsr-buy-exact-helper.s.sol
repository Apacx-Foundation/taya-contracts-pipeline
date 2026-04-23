// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";

/*
 * Deploy LMSRBuyExactHelper
 *
 * Deploys the stateless LMSRBuyExactHelper helper and records its address in
 * script/output/<chainId>.json under the key `LMSRBuyExactHelper`.
 *
 * Preconditions:
 *   - Fixed192x64Math is already deployed and its address is stored as `fixedMathLib` in
 *     the per-chain output json (happens during initial chain bootstrap via
 *     deploy_sepolia.sh / deploy_polygon.sh).
 *   - The market_ext artifacts in out_market_ext/ are built with library linkage pointing
 *     at that fixedMathLib address. The helper depends on Fixed192x64Math, so an unlinked
 *     artifact will fail to deploy. Ensure you ran (once, after fixedMathLib was deployed):
 *
 *       FOUNDRY_PROFILE=market_ext forge build --force \
 *         --libraries "node_modules/AT-gnosis.pm/util-contracts/contracts/Fixed192x64Math.sol:Fixed192x64Math:<addr>"
 *
 *     (Replace AT with @ — kept as a placeholder here so solc's natspec parser doesn't choke.)
 *
 * Usage: ./script/cmd/run_migration.sh <chainId> 20260423-deploy-lmsr-buy-exact-collateral
 */
contract DeployLMSRBuyExactHelper is Script {
    using stdJson for string;

    function run() external {
        string memory outputPath =
            string(abi.encodePacked(vm.projectRoot(), "/script/output/", vm.toString(block.chainid), ".json"));
        string memory json = vm.readFile(outputPath);

        // Sanity: require fixedMathLib to exist; the helper won't function without the linked lib.
        address fixedMathLib = abi.decode(vm.parseJson(json, ".fixedMathLib"), (address));
        require(fixedMathLib != address(0), "fixedMathLib not deployed for this chain");
        require(fixedMathLib.code.length > 0, "fixedMathLib address has no code");

        vm.startBroadcast();
        address helper = vm.deployCode("out_market_ext/LMSRBuyExactHelper.sol/LMSRBuyExactHelper.json");
        vm.stopBroadcast();

        require(helper != address(0), "deploy failed");
        require(helper.code.length > 0, "deployed bytecode empty");

        console2.log("LMSRBuyExactHelper deployed at:", helper);
        console2.log("  Linked against Fixed192x64Math at:", fixedMathLib);

        _writeOutput(outputPath, json, helper);
    }

    /// @dev Merge the new deployment into the existing per-chain output json without clobbering
    ///      any pre-existing keys.
    function _writeOutput(string memory path, string memory existingJson, address helper) internal {
        // stdJson's `.serialize` overwrites the file with a single namespace, so we read each
        // key explicitly and re-serialize. Adding a new key here means adding a new line.
        string memory artifacts = "artifacts";

        artifacts.serialize("ctf", _readAddr(existingJson, ".ctf"));
        artifacts.serialize("fpmmFactory", _readAddr(existingJson, ".fpmmFactory"));
        artifacts.serialize("cappedLmsrFactory", _readAddr(existingJson, ".cappedLmsrFactory"));
        artifacts.serialize("whitelist", _readAddr(existingJson, ".whitelist"));
        artifacts.serialize("umaAdapter", _readAddr(existingJson, ".umaAdapter"));
        artifacts.serialize("umaAdapterGate", _readAddr(existingJson, ".umaAdapterGate"));
        artifacts.serialize("bettingToken", _readAddr(existingJson, ".bettingToken"));
        artifacts.serialize("fixedMathLib", _readAddr(existingJson, ".fixedMathLib"));
        artifacts.serialize("deployedAtBlock", abi.decode(vm.parseJson(existingJson, ".deployedAtBlock"), (uint256)));
        string memory final_ = artifacts.serialize("LMSRBuyExactHelper", helper);
        final_.write(path);
    }

    function _readAddr(string memory json, string memory key) internal pure returns (address) {
        return abi.decode(vm.parseJson(json, key), (address));
    }
}
