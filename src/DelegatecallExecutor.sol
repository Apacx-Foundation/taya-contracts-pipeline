// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

interface IERC7579Account {
    function executeFromExecutor(bytes32 mode, bytes calldata executionCalldata)
        external
        payable
        returns (bytes[] memory returnData);
}

/// @title DelegatecallExecutor
/// @notice ERC-7579 executor module for Kernel v3.1 that triggers a DELEGATECALL from an
///         installed smart account into an arbitrary target. Sibling of Rhinestone's
///         OwnableExecutor, but uses CALLTYPE_DELEGATECALL (0xFF) instead of single-CALL.
///
///         When invoked via `execute(account, target, data)`:
///           account.executeFromExecutor(MODE_DELEGATECALL, abi.encodePacked(target, data))
///         → Kernel runs `target`'s code in `account`'s storage context.
///
/// @dev    Authorization: enforced by `account.executeFromExecutor`, which requires
///         msg.sender to be an installed executor module. This contract adds no
///         additional auth. Safe because only code running *inside* `account` can cause
///         a delegatecall anyway — execution control already lives at the account layer.
contract DelegatecallExecutor {
    /// @dev ERC-7579 single-DELEGATECALL mode.
    ///      Layout: callType(1) || execType(1) || modeSelector(4) || modePayload(22).
    ///      CALLTYPE_DELEGATECALL = 0xFF, exec type DEFAULT, no selector/payload.
    bytes32 internal constant MODE_DELEGATECALL =
        0xff00000000000000000000000000000000000000000000000000000000000000;

    /// @dev ERC-7579 module type id for executor.
    uint256 internal constant MODULE_TYPE_EXECUTOR = 2;

    /// @notice Per-account install flag. Read via isInitialized(account).
    mapping(address => bool) public isInstalled;

    event Installed(address indexed account);
    event Uninstalled(address indexed account);
    event Delegatecalled(address indexed account, address indexed target);

    // --- ERC-7579 lifecycle --------------------------------------------------

    function onInstall(bytes calldata) external {
        isInstalled[msg.sender] = true;
        emit Installed(msg.sender);
    }

    function onUninstall(bytes calldata) external {
        isInstalled[msg.sender] = false;
        emit Uninstalled(msg.sender);
    }

    function isInitialized(address account) external view returns (bool) {
        return isInstalled[account];
    }

    function isModuleType(uint256 typeID) external pure returns (bool) {
        return typeID == MODULE_TYPE_EXECUTOR;
    }

    // --- Execution -----------------------------------------------------------

    /// @notice Trigger a DELEGATECALL from `account` into `target` with `data`.
    /// @dev    The account's `executeFromExecutor` requires msg.sender (this contract)
    ///         to be an installed executor module — that's the access control.
    function execute(address account, address target, bytes calldata data)
        external
        returns (bytes[] memory returnData)
    {
        // ERC-7579 executionCalldata for single DELEGATECALL: encodePacked(target, data).
        // No value field — delegatecall uses the caller's context/balance.
        returnData = IERC7579Account(account).executeFromExecutor(
            MODE_DELEGATECALL,
            abi.encodePacked(target, data)
        );
        emit Delegatecalled(account, target);
    }
}
