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
/// @dev    Authorization: `execute` requires `msg.sender == account`. The intended call
///         path is OwnableExecutor → account → DelegatecallExecutor.execute(account, ...),
///         which satisfies this naturally. Without this check, ANY address could call
///         `execute(victimAccount, evilTarget, evilData)` and — as long as this contract
///         is installed as an executor on the victim — Kernel would authorize the
///         delegatecall (executeFromExecutor authorizes the *module*, not the module's
///         caller). `isInstalled`/`onInstall` also require `msg.sender == account` so a
///         random EOA can't pollute the mapping by faking install events.
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
    /// @dev    Only `account` itself can invoke this — Kernel's `executeFromExecutor`
    ///         only authorizes that the MODULE is installed, not who called the module,
    ///         so we must enforce caller==account here. The intended chain is:
    ///         OwnableExecutor → account.execute → DelegatecallExecutor.execute(account, ...)
    ///         which satisfies this naturally. A direct external call from a random EOA
    ///         fails here.
    function execute(address account, address target, bytes calldata data)
        external
        returns (bytes[] memory returnData)
    {
        require(msg.sender == account, "DelegatecallExecutor: unauthorized");
        // ERC-7579 executionCalldata for single DELEGATECALL: encodePacked(target, data).
        // No value field — delegatecall uses the caller's context/balance.
        returnData = IERC7579Account(account).executeFromExecutor(
            MODE_DELEGATECALL,
            abi.encodePacked(target, data)
        );
        emit Delegatecalled(account, target);
    }
}
