// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PlatformRegistry} from "../src/PlatformRegistry.sol";
import {PlatformUser} from "../src/PlatformUser.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

// ============================================================================
// Mocks
// ============================================================================

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MCK", 18) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockWhitelist {
    mapping(address => bool) public isWhitelisted;

    function addToWhitelist(address[] calldata users) external {
        for (uint256 i = 0; i < users.length; i++) {
            isWhitelisted[users[i]] = true;
        }
    }
}

contract MockWhitelistFactory {
    function createWhitelist() external returns (address) {
        return address(new MockWhitelist());
    }
}

// ============================================================================
// Unit tests (no fork)
// ============================================================================

contract PlatformRegistryTest is Test {
    PlatformRegistry public registry;
    MockERC20 public token;

    address admin = address(0xA);
    address kms = address(0xB);
    address defaultAdmin = address(0xC);

    bytes32 platformId = keccak256("platform-1");
    bytes32 userId = keccak256("user-1");

    function setUp() public {
        token = new MockERC20();

        PlatformRegistry impl = new PlatformRegistry();
        MockWhitelistFactory wlFactory = new MockWhitelistFactory();
        PlatformUser walletImpl = new PlatformUser();

        address[] memory admins = new address[](1);
        admins[0] = admin;
        address[] memory kmsSigners = new address[](1);
        kmsSigners[0] = kms;

        bytes memory initData = abi.encodeWithSelector(
            PlatformRegistry.initialize.selector,
            defaultAdmin,
            address(walletImpl),
            address(wlFactory),
            admins,
            kmsSigners
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        registry = PlatformRegistry(address(proxy));
    }

    function test_initializeSetsRoles() public view {
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), defaultAdmin));
        assertTrue(registry.hasRole(registry.ADMIN_ROLE(), admin));
        assertTrue(registry.hasRole(registry.KMS_ROLE(), kms));
    }

    function test_initializeSetsBeaconAndWhitelist() public view {
        assertTrue(address(registry.walletBeacon()) != address(0));
        assertTrue(registry.whitelist() != address(0));
    }

    function test_registerPlatform() public {
        vm.prank(kms);
        registry.registerPlatform(platformId);
        assertTrue(registry.platformExists(platformId));
    }

    function test_deposit() public {
        vm.prank(kms);
        registry.registerPlatform(platformId);

        uint256 amount = 1000e18;
        token.mint(address(this), amount);
        token.approve(address(registry), amount);

        registry.deposit(platformId, address(token), amount);
        assertEq(registry.platformBalance(platformId, address(token)), amount);
    }

    function test_deployUserWallet() public {
        vm.prank(kms);
        registry.registerPlatform(platformId);

        address predicted = registry.computeUserWalletAddress(platformId, userId);

        vm.prank(kms);
        address wallet = registry.deployUserWallet(platformId, userId);

        assertEq(wallet, predicted);
        assertTrue(wallet.code.length > 0);
        assertEq(PlatformUser(payable(wallet)).registry(), address(registry));
    }

    function test_deployUserWalletDeterministic() public {
        vm.prank(kms);
        registry.registerPlatform(platformId);

        vm.prank(kms);
        address wallet1 = registry.deployUserWallet(platformId, userId);

        // Same platform+user should not revert
        vm.prank(kms);
        registry.deployUserWallet(platformId, userId);
    }

    function test_fundUserWallet() public {
        vm.prank(kms);
        registry.registerPlatform(platformId);

        uint256 depositAmt = 1000e18;
        token.mint(address(this), depositAmt);
        token.approve(address(registry), depositAmt);
        registry.deposit(platformId, address(token), depositAmt);

        uint256 fundAmt = 100e18;
        vm.prank(kms);
        address wallet = registry.fundUserWallet(platformId, userId, address(token), fundAmt);

        assertEq(token.balanceOf(wallet), fundAmt);
        assertEq(registry.platformBalance(platformId, address(token)), depositAmt - fundAmt);
    }

    function test_fundUserWalletDeploysIfNeeded() public {
        vm.prank(kms);
        registry.registerPlatform(platformId);

        uint256 depositAmt = 1000e18;
        token.mint(address(this), depositAmt);
        token.approve(address(registry), depositAmt);
        registry.deposit(platformId, address(token), depositAmt);

        // Wallet not yet deployed
        address predicted = registry.computeUserWalletAddress(platformId, userId);
        assertEq(predicted.code.length, 0);

        vm.prank(kms);
        address wallet = registry.fundUserWallet(platformId, userId, address(token), 50e18);

        assertEq(wallet, predicted);
        assertTrue(wallet.code.length > 0);
    }

    function test_withdrawToAdmin() public {
        vm.prank(kms);
        registry.registerPlatform(platformId);

        uint256 amount = 500e18;
        token.mint(address(this), amount);
        token.approve(address(registry), amount);
        registry.deposit(platformId, address(token), amount);

        uint256 withdrawAmt = 200e18;
        vm.prank(kms);
        registry.withdrawToAdmin(platformId, address(token), admin, withdrawAmt);

        assertEq(token.balanceOf(admin), withdrawAmt);
        assertEq(registry.platformBalance(platformId, address(token)), amount - withdrawAmt);
    }

}
