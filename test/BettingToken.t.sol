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
    address public blacklister = makeAddr("blacklister");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    event Blacklisted(address indexed account);
    event Unblacklisted(address indexed account);
    event NameChanged(string newName);
    event SymbolChanged(string newSymbol);

    function setUp() public {
        admin = address(this);
        impl = new BettingToken();
        bytes memory initData =
            abi.encodeWithSelector(BettingToken.initialize.selector, "Betting Token", "BET", admin);
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        token = BettingToken(address(proxy));
    }

    // ---- Deployment / Initialization ----

    function testInitialization() public view {
        assertEq(token.name(), "Betting Token");
        assertEq(token.symbol(), "BET");
        assertTrue(token.hasRole(token.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(token.hasRole(token.MINTER_ROLE(), admin));
        assertTrue(token.hasRole(token.BLACKLISTER_ROLE(), admin));
        assertEq(token.totalSupply(), 0);
    }

    function testCannotInitializeTwice() public {
        vm.expectRevert("Initializable: contract is already initialized");
        token.initialize("Other", "OTH", alice);
    }

    function testImplCannotBeInitialized() public {
        vm.expectRevert("Initializable: contract is already initialized");
        impl.initialize("Other", "OTH", alice);
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
}
