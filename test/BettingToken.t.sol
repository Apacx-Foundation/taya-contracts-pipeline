// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {Test} from "forge-std/Test.sol";
import {BettingToken} from "../src/BettingToken.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract BettingTokenTest is Test {
    BettingToken public token;
    BettingToken public impl;

    address public admin;
    address public minter = makeAddr("minter");
    address public burner = makeAddr("burner");
    address public blacklister = makeAddr("blacklister");
    address public roleManager = makeAddr("roleManager");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    event Blacklisted(address indexed account);
    event Unblacklisted(address indexed account);
    event NameChanged(string newName);
    event SymbolChanged(string newSymbol);

    function setUp() public {
        admin = address(this);
        impl = new BettingToken();
        address[] memory admins = new address[](1);
        admins[0] = admin;
        bytes memory initData =
            abi.encodeWithSelector(BettingToken.initialize.selector, "Betting Token", "BET", admins);
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        token = BettingToken(address(proxy));
    }

    // ---- Deployment / Initialization ----

    function testInitialization() public view {
        assertEq(token.name(), "Betting Token");
        assertEq(token.symbol(), "BET");
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(token.hasRole(token.ROLE_MANAGER_ROLE(), admin));
        assertTrue(token.hasRole(token.MINTER_ROLE(), admin));
        assertTrue(token.hasRole(token.BURNER_ROLE(), admin));
        assertTrue(token.hasRole(token.BLACKLISTER_ROLE(), admin));
        assertEq(token.totalSupply(), 0);
    }

    function testInitializationWiresRoleAdmins() public view {
        assertEq(token.getRoleAdmin(token.MINTER_ROLE()), token.ROLE_MANAGER_ROLE());
        assertEq(token.getRoleAdmin(token.BURNER_ROLE()), token.ROLE_MANAGER_ROLE());
        assertEq(token.getRoleAdmin(token.BLACKLISTER_ROLE()), token.ROLE_MANAGER_ROLE());
        assertEq(token.getRoleAdmin(token.ROLE_MANAGER_ROLE()), token.DEFAULT_ADMIN_ROLE());
    }

    function testCannotInitializeTwice() public {
        address[] memory admins = new address[](1);
        admins[0] = alice;
        vm.expectRevert("Initializable: contract is already initialized");
        token.initialize("Other", "OTH", admins);
    }

    function testImplCannotBeInitialized() public {
        address[] memory admins = new address[](1);
        admins[0] = alice;
        vm.expectRevert("Initializable: contract is already initialized");
        impl.initialize("Other", "OTH", admins);
    }

    // ---- Name / Symbol ----

    function testSetName() public {
        token.setName("New Name");
        assertEq(token.name(), "New Name");
    }

    function testSetSymbol() public {
        token.setSymbol("NEW");
        assertEq(token.symbol(), "NEW");
    }

    function testSetNameRevertsNonAdmin() public {
        vm.expectRevert();
        vm.prank(alice);
        token.setName("Hacked");
    }

    function testSetSymbolRevertsNonAdmin() public {
        vm.expectRevert();
        vm.prank(alice);
        token.setSymbol("HACK");
    }

    function testSetNameEmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit NameChanged("New Name");
        token.setName("New Name");
    }

    function testSetSymbolEmitsEvent() public {
        vm.expectEmit(false, false, false, true);
        emit SymbolChanged("NEW");
        token.setSymbol("NEW");
    }

    // ---- Minting ----

    function testAdminCanMint() public {
        token.mint(alice, 1000e18);
        assertEq(token.balanceOf(alice), 1000e18);
    }

    function testGrantedMinterCanMint() public {
        token.grantRole(token.MINTER_ROLE(), minter);
        vm.prank(minter);
        token.mint(alice, 500e18);
        assertEq(token.balanceOf(alice), 500e18);
    }

    function testNonMinterCannotMint() public {
        vm.expectRevert();
        vm.prank(alice);
        token.mint(alice, 100e18);
    }

    function testRevokeMinterStopsMinting() public {
        token.grantRole(token.MINTER_ROLE(), minter);
        token.revokeRole(token.MINTER_ROLE(), minter);

        vm.expectRevert();
        vm.prank(minter);
        token.mint(alice, 1e18);
    }

    // ---- Blacklist ----

    function testBlacklistBlocksSending() public {
        token.mint(alice, 100e18);
        token.blacklist(alice);

        vm.expectRevert(abi.encodeWithSelector(BettingToken.BlacklistedAddress.selector, alice));
        vm.prank(alice);
        token.transfer(bob, 50e18);
    }

    function testBlacklistBlocksReceiving() public {
        token.mint(alice, 100e18);
        token.blacklist(bob);

        vm.expectRevert(abi.encodeWithSelector(BettingToken.BlacklistedAddress.selector, bob));
        vm.prank(alice);
        token.transfer(bob, 50e18);
    }

    function testBlacklistBlocksMinting() public {
        token.blacklist(alice);

        vm.expectRevert(abi.encodeWithSelector(BettingToken.BlacklistedAddress.selector, alice));
        token.mint(alice, 100e18);
    }

    function testBlacklistBlocksTransferFrom() public {
        token.mint(alice, 100e18);

        vm.prank(alice);
        token.approve(bob, 100e18);

        token.blacklist(alice);

        vm.expectRevert(abi.encodeWithSelector(BettingToken.BlacklistedAddress.selector, alice));
        vm.prank(bob);
        token.transferFrom(alice, bob, 50e18);
    }

    function testUnblacklistRestoresTransfers() public {
        token.mint(alice, 100e18);
        token.blacklist(alice);
        token.unblacklist(alice);

        vm.prank(alice);
        token.transfer(bob, 50e18);
        assertEq(token.balanceOf(bob), 50e18);
    }

    function testBlacklistRevertsNonBlacklister() public {
        vm.expectRevert();
        vm.prank(alice);
        token.blacklist(bob);
    }

    function testUnblacklistRevertsNonBlacklister() public {
        token.blacklist(bob);
        vm.expectRevert();
        vm.prank(alice);
        token.unblacklist(bob);
    }

    function testGrantedBlacklisterCanBlacklist() public {
        token.grantRole(token.BLACKLISTER_ROLE(), blacklister);
        vm.prank(blacklister);
        token.blacklist(alice);
        assertTrue(token.blacklisted(alice));
    }

    function testBlacklistEmitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit Blacklisted(alice);
        token.blacklist(alice);
    }

    function testUnblacklistEmitsEvent() public {
        token.blacklist(alice);
        vm.expectEmit(true, false, false, false);
        emit Unblacklisted(alice);
        token.unblacklist(alice);
    }

    // ---- Transfers (happy path) ----

    function testTransfer() public {
        token.mint(alice, 100e18);
        vm.prank(alice);
        token.transfer(bob, 40e18);
        assertEq(token.balanceOf(alice), 60e18);
        assertEq(token.balanceOf(bob), 40e18);
    }

    function testTransferFrom() public {
        token.mint(alice, 100e18);
        vm.prank(alice);
        token.approve(bob, 60e18);

        vm.prank(bob);
        token.transferFrom(alice, bob, 60e18);
        assertEq(token.balanceOf(bob), 60e18);
    }

    // ---- Upgrade ----

    function testAdminCanUpgrade() public {
        BettingToken newImpl = new BettingToken();
        token.upgradeTo(address(newImpl));
        // Still works after upgrade
        assertEq(token.name(), "Betting Token");
    }

    function testNonAdminCannotUpgrade() public {
        BettingToken newImpl = new BettingToken();
        vm.expectRevert();
        vm.prank(alice);
        token.upgradeTo(address(newImpl));
    }

    function testStatePreservedAfterUpgrade() public {
        token.mint(alice, 100e18);
        token.blacklist(bob);

        BettingToken newImpl = new BettingToken();
        token.upgradeTo(address(newImpl));

        assertEq(token.balanceOf(alice), 100e18);
        assertTrue(token.blacklisted(bob));
        assertTrue(token.hasRole(token.MINTER_ROLE(), admin));
    }

    // ---- Fuzz ----

    function testFuzzMint(address to, uint256 amount) public {
        vm.assume(to != address(0));
        vm.assume(!token.blacklisted(to));
        token.mint(to, amount);
        assertEq(token.balanceOf(to), amount);
    }

    function testFuzzBlacklistBlocksTransfer(uint256 amount) public {
        vm.assume(amount > 0 && amount <= type(uint128).max);
        token.mint(alice, amount);
        token.blacklist(alice);

        vm.expectRevert(abi.encodeWithSelector(BettingToken.BlacklistedAddress.selector, alice));
        vm.prank(alice);
        token.transfer(bob, amount);
    }

    // ---- Burning (BURNER_ROLE) ----

    function testAdminCanBurn() public {
        token.mint(alice, 100e18);
        token.burn(alice, 40e18);
        assertEq(token.balanceOf(alice), 60e18);
    }

    function testGrantedBurnerCanBurn() public {
        token.mint(alice, 100e18);
        token.grantRole(token.BURNER_ROLE(), burner);
        vm.prank(burner);
        token.burn(alice, 30e18);
        assertEq(token.balanceOf(alice), 70e18);
    }

    function testNonBurnerCannotBurn() public {
        token.mint(alice, 100e18);
        vm.expectRevert();
        vm.prank(alice);
        token.burn(alice, 10e18);
    }

    function testBurnRespectsBlacklist() public {
        token.mint(alice, 100e18);
        token.blacklist(alice);
        vm.expectRevert(abi.encodeWithSelector(BettingToken.BlacklistedAddress.selector, alice));
        token.burn(alice, 10e18);
    }

    // ---- Role Manager (ROLE_MANAGER_ROLE) ----

    function testRoleManagerCanGrantMinter() public {
        token.grantRole(token.ROLE_MANAGER_ROLE(), roleManager);
        vm.prank(roleManager);
        token.grantRole(token.MINTER_ROLE(), minter);
        assertTrue(token.hasRole(token.MINTER_ROLE(), minter));
    }

    function testRoleManagerCanGrantBurner() public {
        token.grantRole(token.ROLE_MANAGER_ROLE(), roleManager);
        vm.prank(roleManager);
        token.grantRole(token.BURNER_ROLE(), burner);
        assertTrue(token.hasRole(token.BURNER_ROLE(), burner));
    }

    function testRoleManagerCanGrantBlacklister() public {
        token.grantRole(token.ROLE_MANAGER_ROLE(), roleManager);
        vm.prank(roleManager);
        token.grantRole(token.BLACKLISTER_ROLE(), blacklister);
        assertTrue(token.hasRole(token.BLACKLISTER_ROLE(), blacklister));
    }

    function testRoleManagerCanRevokeMinter() public {
        token.grantRole(token.ROLE_MANAGER_ROLE(), roleManager);
        token.grantRole(token.MINTER_ROLE(), minter);
        vm.prank(roleManager);
        token.revokeRole(token.MINTER_ROLE(), minter);
        assertFalse(token.hasRole(token.MINTER_ROLE(), minter));
    }

    function testRoleManagerCannotGrantSelf() public {
        bytes32 rmRole = token.ROLE_MANAGER_ROLE();
        token.grantRole(rmRole, roleManager);
        vm.expectRevert();
        vm.prank(roleManager);
        token.grantRole(rmRole, alice);
    }

    function testRoleManagerCannotGrantDefaultAdmin() public {
        bytes32 rmRole = token.ROLE_MANAGER_ROLE();
        bytes32 defaultAdminRole = token.DEFAULT_ADMIN_ROLE();
        token.grantRole(rmRole, roleManager);
        vm.expectRevert();
        vm.prank(roleManager);
        token.grantRole(defaultAdminRole, alice);
    }

    function testNonRoleManagerCannotGrantMinter() public {
        bytes32 minterRole = token.MINTER_ROLE();
        vm.expectRevert();
        vm.prank(alice);
        token.grantRole(minterRole, bob);
    }

    function testDefaultAdminCanGrantRoleManager() public {
        token.grantRole(token.ROLE_MANAGER_ROLE(), roleManager);
        assertTrue(token.hasRole(token.ROLE_MANAGER_ROLE(), roleManager));
    }

    // ---- initializeV2 ----

    function testInitializeV2CannotRunAfterInitialize() public {
        // setUp() already ran initialize(), which is reinitializer(1). After
        // that, initializeV2() (reinitializer(2)) must still be callable
        // exactly once for migration purposes.
        address[] memory rms = new address[](1);
        rms[0] = roleManager;
        address[] memory burners = new address[](1);
        burners[0] = burner;
        token.initializeV2(rms, burners);
        assertTrue(token.hasRole(token.ROLE_MANAGER_ROLE(), roleManager));
        assertTrue(token.hasRole(token.BURNER_ROLE(), burner));

        vm.expectRevert("Initializable: contract is already initialized");
        token.initializeV2(rms, burners);
    }

    function testInitializeV2PreservesRoleAdminGraph() public {
        address[] memory rms = new address[](1);
        rms[0] = roleManager;
        address[] memory burners = new address[](0);
        token.initializeV2(rms, burners);

        assertEq(token.getRoleAdmin(token.MINTER_ROLE()), token.ROLE_MANAGER_ROLE());
        assertEq(token.getRoleAdmin(token.BURNER_ROLE()), token.ROLE_MANAGER_ROLE());
        assertEq(token.getRoleAdmin(token.BLACKLISTER_ROLE()), token.ROLE_MANAGER_ROLE());
        assertEq(token.getRoleAdmin(token.ROLE_MANAGER_ROLE()), token.DEFAULT_ADMIN_ROLE());
    }
}
