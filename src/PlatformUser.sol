// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";

/// @notice Minimal upgradeable wallet that only accepts calls from PlatformRegistry.
contract PlatformUser is Initializable {
    address public registry;

    function initialize(address _registry) external initializer {
        registry = _registry;
    }

    function execute(address to, uint256 value, bytes calldata data) external returns (bytes memory) {
        require(msg.sender == registry, "PlatformUser: not registry");
        (bool ok, bytes memory ret) = to.call{value: value}(data);
        require(ok, "PlatformUser: call failed");
        return ret;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }
}
