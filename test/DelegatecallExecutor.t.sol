// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import {Test} from "forge-std/Test.sol";
import {DelegatecallExecutor} from "../src/DelegatecallExecutor.sol";

/// @dev Minimal ERC-7579-style account that honors a single executor module and performs
///      the actual delegatecall for CALLTYPE_DELEGATECALL. Enough surface to prove
///      `DelegatecallExecutor` constructs mode + executionCalldata correctly.
contract MockAccount {
    address public installedExecutor;
    bytes32 internal constant MODE_DELEGATECALL =
        0xff00000000000000000000000000000000000000000000000000000000000000;

    error NotInstalled();
    error UnknownMode();
    error DelegatecallFailed();

    function installExecutor(address executor, bytes calldata initData) external {
        installedExecutor = executor;
        DelegatecallExecutor(executor).onInstall(initData);
    }

    function uninstallExecutor(bytes calldata uninstallData) external {
        address executor = installedExecutor;
        installedExecutor = address(0);
        DelegatecallExecutor(executor).onUninstall(uninstallData);
    }

    /// Helper so tests can drive the executor from the account's context (matching
    /// the production flow: OwnableExecutor makes the account call DelegatecallExecutor,
    /// so msg.sender into execute() is the account).
    function callExecutor(address executor, address target, bytes calldata data)
        external
        returns (bytes[] memory)
    {
        return DelegatecallExecutor(executor).execute(address(this), target, data);
    }

    function executeFromExecutor(bytes32 mode, bytes calldata executionCalldata)
        external
        payable
        returns (bytes[] memory returnData)
    {
        if (msg.sender != installedExecutor) revert NotInstalled();
        if (mode != MODE_DELEGATECALL) revert UnknownMode();

        // Single-DELEGATECALL executionCalldata = abi.encodePacked(target, data).
        address target = address(bytes20(executionCalldata[0:20]));
        bytes memory data = executionCalldata[20:];

        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, bytes memory ret) = target.delegatecall(data);
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        returnData = new bytes[](1);
        returnData[0] = ret;
    }
}

/// @dev Records whoever called `record()` last. Used to verify msg.sender as seen by
///      nested external calls made from within a delegatecalled context.
contract MsgSenderSink {
    address public lastCaller;

    function record() external {
        lastCaller = msg.sender;
    }
}

/// @dev Called via DELEGATECALL from the account. `address(this)` read here = account.
///      When it calls `sink.record()`, sink should see msg.sender = account — the
///      critical property LMSRBuyExactHelper relies on.
contract Probe {
    event Touched(address codeContext, address msgSenderIntoProbe);

    function touch(address sink) external {
        MsgSenderSink(sink).record();
        emit Touched(address(this), msg.sender);
    }

    function readThis() external view returns (address) {
        return address(this);
    }
}

contract DelegatecallExecutorTest is Test {
    DelegatecallExecutor internal executor;
    MockAccount internal account;
    Probe internal probe;
    MsgSenderSink internal sink;

    function setUp() public {
        executor = new DelegatecallExecutor();
        account = new MockAccount();
        probe = new Probe();
        sink = new MsgSenderSink();

        account.installExecutor(address(executor), "");
    }

    function test_isModuleType() public {
        assertTrue(executor.isModuleType(2));
        assertFalse(executor.isModuleType(0));
        assertFalse(executor.isModuleType(1));
        assertFalse(executor.isModuleType(3));
    }

    function test_installFlipsFlag() public {
        assertTrue(executor.isInitialized(address(account)));

        MockAccount fresh = new MockAccount();
        assertFalse(executor.isInitialized(address(fresh)));
        fresh.installExecutor(address(executor), "");
        assertTrue(executor.isInitialized(address(fresh)));
    }

    function test_uninstallClearsFlag() public {
        account.uninstallExecutor("");
        assertFalse(executor.isInitialized(address(account)));
    }

    /// Core property: after delegatecall through the executor, `address(this)` inside
    /// the probe equals the account — proof that code ran in the account's context.
    function test_delegatecallRunsInAccountContext() public {
        bytes memory data = abi.encodeWithSelector(Probe.touch.selector, address(sink));
        account.callExecutor(address(executor), address(probe), data);

        // Sink saw msg.sender = account (because probe.touch() was a nested external
        // call from within account's delegatecalled frame).
        assertEq(sink.lastCaller(), address(account), "sink.msg.sender != account");
    }

    /// Core property #2: an external CALL from the probe's delegatecalled frame has
    /// msg.sender == account. This is what the LMSR helper's pool.tradeWithSurcharge()
    /// relies on.
    function test_externalCallFromDelegatecalledFrame() public {
        bytes memory data = abi.encodeWithSelector(Probe.readThis.selector);
        bytes[] memory ret = account.callExecutor(address(executor), address(probe), data);
        address observedThis = abi.decode(ret[0], (address));
        assertEq(observedThis, address(account), "address(this) inside probe != account");
    }

    /// Access-control: a direct external caller (not the account itself) must revert.
    /// Without this guard, ANY address could drain an account that has the executor
    /// installed, because Kernel's executeFromExecutor only authorizes the module — not
    /// who called the module.
    function test_externalCallerIsUnauthorized() public {
        bytes memory data = abi.encodeWithSelector(Probe.touch.selector, address(sink));
        vm.expectRevert("DelegatecallExecutor: unauthorized");
        executor.execute(address(account), address(probe), data);
    }

    function test_revertsWhenExecutorNotInstalled() public {
        MockAccount fresh = new MockAccount();
        bytes memory data = abi.encodeWithSelector(Probe.touch.selector, address(sink));

        // Account tries to use the executor without having it installed — Kernel's
        // auth check rejects before any delegatecall happens.
        vm.expectRevert(MockAccount.NotInstalled.selector);
        fresh.callExecutor(address(executor), address(probe), data);
    }
}
