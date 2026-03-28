pragma solidity ^0.5.1;

import {Whitelist} from "market-makers/Whitelist.sol";
import {WhitelistAccessControl} from "../src_market_ext/WhitelistAccessControl.sol";

contract ExternalCaller {
    WhitelistAccessControl public wl;

    constructor(WhitelistAccessControl _wl) public {
        wl = _wl;
    }

    function tryAddAdmin(address account) external {
        wl.addAdmin(account);
    }

    function tryRemoveAdmin(address account) external {
        wl.removeAdmin(account);
    }

    function tryAddWhitelister(address account) external {
        wl.addWhitelister(account);
    }

    function tryRemoveWhitelister(address account) external {
        wl.removeWhitelister(account);
    }

    function tryaddToWhitelist(address[] calldata users) external {
        wl.addToWhitelist(users);
    }

    function tryremoveFromWhitelist(address[] calldata users) external {
        wl.removeFromWhitelist(users);
    }

    function tryRenounceWhitelister() external {
        wl.renounceWhitelister();
    }

    function tryRenounceAdmin() external {
        wl.renounceAdmin();
    }
}

/// @title WhitelistAccessControl Tests
contract WhitelistAccessControlTest {
    WhitelistAccessControl public wl;
    ExternalCaller public stranger;

    event TestPassed(string name);

    constructor() public {
        wl = new WhitelistAccessControl();
        stranger = new ExternalCaller(wl);
    }

    function assertTrue(bool condition, string memory message) internal pure {
        require(condition, message);
    }

    // ── Type compatibility ──────────────────────────────────────────────

    function test_isWhitelistSubtype() public {
        Whitelist base = Whitelist(address(wl));
        assertTrue(base.owner() == address(this), "owner via base type should match");
        emit TestPassed("test_isWhitelistSubtype");
    }

    // ── Admin role ──────────────────────────────────────────────────────

    function test_deployerIsAdmin() public {
        assertTrue(wl.isAdmin(address(this)), "deployer should be admin");
        emit TestPassed("test_deployerIsAdmin");
    }

    function test_addAdmin() public {
        wl.addAdmin(address(stranger));
        assertTrue(wl.isAdmin(address(stranger)), "should be admin");
        emit TestPassed("test_addAdmin");
    }

    function test_removeAdmin() public {
        wl.addAdmin(address(stranger));
        wl.removeAdmin(address(stranger));
        assertTrue(!wl.isAdmin(address(stranger)), "should no longer be admin");
        emit TestPassed("test_removeAdmin");
    }

    function test_renounceAdmin() public {
        wl.addAdmin(address(stranger));
        stranger.tryRenounceAdmin();
        assertTrue(!wl.isAdmin(address(stranger)), "should no longer be admin after renounce");
        emit TestPassed("test_renounceAdmin");
    }

    function test_nonAdminCannotAddAdmin() public {
        (bool success,) = address(stranger).call(abi.encodeWithSelector(stranger.tryAddAdmin.selector, address(0x9999)));
        assertTrue(!success, "non-admin addAdmin should revert");
        emit TestPassed("test_nonAdminCannotAddAdmin");
    }

    function test_nonAdminCannotRemoveAdmin() public {
        (bool success,) =
            address(stranger).call(abi.encodeWithSelector(stranger.tryRemoveAdmin.selector, address(this)));
        assertTrue(!success, "non-admin removeAdmin should revert");
        emit TestPassed("test_nonAdminCannotRemoveAdmin");
    }

    // ── Admin as implicit whitelister ───────────────────────────────────

    function test_adminCanWhitelist() public {
        address[] memory users = new address[](1);
        users[0] = address(0xBEEF);

        wl.addToWhitelist(users);
        assertTrue(wl.isWhitelisted(address(0xBEEF)), "should be whitelisted");

        wl.removeFromWhitelist(users);
        assertTrue(!wl.isWhitelisted(address(0xBEEF)), "should not be whitelisted");
        emit TestPassed("test_adminCanWhitelist");
    }

    // ── Whitelister role management ─────────────────────────────────────

    function test_whitelisterCanAddWhitelister() public {
        ExternalCaller kms = new ExternalCaller(wl);
        wl.addWhitelister(address(kms));

        ExternalCaller platformSA = new ExternalCaller(wl);
        kms.tryAddWhitelister(address(platformSA));
        assertTrue(wl.isWhitelister(address(platformSA)), "platformSA should be whitelister");
        emit TestPassed("test_whitelisterCanAddWhitelister");
    }

    function test_whitelisterCannotRevokeWhitelister() public {
        ExternalCaller kms = new ExternalCaller(wl);
        wl.addWhitelister(address(kms));

        ExternalCaller platformSA = new ExternalCaller(wl);
        kms.tryAddWhitelister(address(platformSA));

        // kms tries to revoke platformSA — should fail (onlyAdmin)
        (bool success,) =
            address(kms).call(abi.encodeWithSelector(kms.tryRemoveWhitelister.selector, address(platformSA)));
        assertTrue(!success, "whitelister should not be able to revoke");
        emit TestPassed("test_whitelisterCannotRevokeWhitelister");
    }

    function test_adminCanRevokeWhitelister() public {
        ExternalCaller kms = new ExternalCaller(wl);
        wl.addWhitelister(address(kms));

        // Admin revokes kms
        wl.removeWhitelister(address(kms));
        assertTrue(!wl.isWhitelister(address(kms)), "kms should be revoked");
        emit TestPassed("test_adminCanRevokeWhitelister");
    }

    function test_whitelisterCanManageUsers() public {
        ExternalCaller kms = new ExternalCaller(wl);
        wl.addWhitelister(address(kms));

        address[] memory users = new address[](2);
        users[0] = address(0x1111);
        users[1] = address(0x2222);

        kms.tryaddToWhitelist(users);
        assertTrue(wl.isWhitelisted(address(0x1111)), "user1 should be whitelisted");
        assertTrue(wl.isWhitelisted(address(0x2222)), "user2 should be whitelisted");

        address[] memory toRemove = new address[](1);
        toRemove[0] = address(0x1111);
        kms.tryremoveFromWhitelist(toRemove);
        assertTrue(!wl.isWhitelisted(address(0x1111)), "user1 should be removed");
        assertTrue(wl.isWhitelisted(address(0x2222)), "user2 still whitelisted");
        emit TestPassed("test_whitelisterCanManageUsers");
    }

    function test_renounceWhitelister() public {
        ExternalCaller kms = new ExternalCaller(wl);
        wl.addWhitelister(address(kms));
        kms.tryRenounceWhitelister();
        assertTrue(!wl.isWhitelister(address(kms)), "should no longer be whitelister");
        emit TestPassed("test_renounceWhitelister");
    }

    // ── Access control enforcement ──────────────────────────────────────

    function test_strangerCannotAdd() public {
        address[] memory users = new address[](1);
        users[0] = address(0xDEAD);

        (bool success,) = address(stranger).call(abi.encodeWithSelector(stranger.tryaddToWhitelist.selector, users));
        assertTrue(!success, "stranger add should revert");
        emit TestPassed("test_strangerCannotAdd");
    }

    function test_strangerCannotRemove() public {
        address[] memory users = new address[](1);
        users[0] = address(0xDEAD);

        (bool success,) =
            address(stranger).call(abi.encodeWithSelector(stranger.tryremoveFromWhitelist.selector, users));
        assertTrue(!success, "stranger remove should revert");
        emit TestPassed("test_strangerCannotRemove");
    }

    function test_strangerCannotAddWhitelister() public {
        (bool success,) =
            address(stranger).call(abi.encodeWithSelector(stranger.tryAddWhitelister.selector, address(0x9999)));
        assertTrue(!success, "stranger addWhitelister should revert");
        emit TestPassed("test_strangerCannotAddWhitelister");
    }

    // ── Full flow: deploy → add whitelister → add platform SA → trade ──

    function test_fullFlow() public {
        // 1. Deploy time: admins are set (this contract is admin via constructor)

        // 2. Admin adds KMS as whitelister
        ExternalCaller kms = new ExternalCaller(wl);
        wl.addWhitelister(address(kms));
        assertTrue(wl.isWhitelister(address(kms)), "kms is whitelister");

        // 3. KMS adds platform SA as whitelister
        ExternalCaller platformSA = new ExternalCaller(wl);
        kms.tryAddWhitelister(address(platformSA));
        assertTrue(wl.isWhitelister(address(platformSA)), "platformSA is whitelister");

        // 4. Platform SA whitelists a user
        address[] memory users = new address[](1);
        users[0] = address(0xAAAA);
        platformSA.tryaddToWhitelist(users);
        assertTrue(wl.isWhitelisted(address(0xAAAA)), "user whitelisted by platformSA");

        // 5. Admin revokes compromised KMS
        wl.removeWhitelister(address(kms));
        assertTrue(!wl.isWhitelister(address(kms)), "kms revoked");

        // 6. Platform SA still works
        address[] memory users2 = new address[](1);
        users2[0] = address(0xBBBB);
        platformSA.tryaddToWhitelist(users2);
        assertTrue(wl.isWhitelisted(address(0xBBBB)), "platformSA still works after kms revoke");

        emit TestPassed("test_fullFlow");
    }

    /// @notice After revoking a whitelister, they can no longer manage users
    function test_revokedWhitelisterBlocked() public {
        ExternalCaller kms = new ExternalCaller(wl);
        wl.addWhitelister(address(kms));

        address[] memory users = new address[](1);
        users[0] = address(0xFACE);
        kms.tryaddToWhitelist(users);
        assertTrue(wl.isWhitelisted(address(0xFACE)), "should be whitelisted");

        wl.removeWhitelister(address(kms));

        address[] memory users2 = new address[](1);
        users2[0] = address(0xFEED);
        (bool success,) = address(kms).call(abi.encodeWithSelector(kms.tryaddToWhitelist.selector, users2));
        assertTrue(!success, "revoked whitelister should not be able to add");
        emit TestPassed("test_revokedWhitelisterBlocked");
    }
}
