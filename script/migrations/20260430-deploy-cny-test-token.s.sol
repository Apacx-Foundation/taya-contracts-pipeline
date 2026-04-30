// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {BettingToken} from "../../src/BettingToken.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployCnyTestToken is Script {
    using stdJson for string;

    string constant TOKEN_NAME = "BET-CNY Token";
    string constant TOKEN_SYMBOL = "CNY";

    function run() external {
        address[] memory admins = _readAdmins(block.chainid);

        vm.startBroadcast();
        BettingToken impl = new BettingToken();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeWithSelector(BettingToken.initialize.selector, TOKEN_NAME, TOKEN_SYMBOL, admins)
        );
        vm.stopBroadcast();

        console2.log("BettingToken impl deployed at:", address(impl));
        console2.log("CNY Test Token (proxy) deployed at:", address(proxy));

        _writeOutput(block.chainid, address(proxy), address(impl));
    }

    function _readAdmins(uint256 chainId) internal view returns (address[] memory) {
        string memory path =
            string(abi.encodePacked(vm.projectRoot(), "/config/networks/", vm.toString(chainId), ".json"));
        string memory json = vm.readFile(path);
        return abi.decode(vm.parseJson(json, ".admins"), (address[]));
    }

    function _writeOutput(uint256 chainId, address proxy, address impl) internal {
        string memory path =
            string(abi.encodePacked(vm.projectRoot(), "/script/output/", vm.toString(chainId), ".json"));
        string memory proxyJson = string(abi.encodePacked('"', vm.toString(proxy), '"'));
        vm.writeJson(proxyJson, path, ".bettingTokenCny");
    }
}
