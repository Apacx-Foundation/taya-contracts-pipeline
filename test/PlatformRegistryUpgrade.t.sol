// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {PlatformRegistry} from "../src/PlatformRegistry.sol";
import {PlatformUser} from "../src/PlatformUser.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

// ============================================================================
// Minimal mocks (upgrade tests only need whitelist + token scaffolding)
// ============================================================================

contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MCK", 18) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockWhitelist {
    function addToWhitelist(address[] calldata) external {}
}

contract MockWhitelistFactory {
    function createWhitelist() external returns (address) {
        return address(new MockWhitelist());
    }
}

// ============================================================================
// V2 mocks — prove upgrade took effect
// ============================================================================

contract PlatformRegistryV2 is PlatformRegistry {
    function version() external pure returns (uint256) { return 2; }
}

contract PlatformUserV2 is PlatformUser {
    function version() external pure returns (uint256) { return 2; }
}

contract NotUUPS {}

// ============================================================================
// Upgrade tests
// ============================================================================

contract PlatformRegistryUpgradeTest is Test {
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

    // ================================================================
    // UUPS proxy upgrade
    // ================================================================

    function test_upgradeRegistry_preservesState() public {
        vm.prank(kms);
        registry.registerPlatform(platformId);

        uint256 depositAmt = 500e18;
        token.mint(address(this), depositAmt);
        token.approve(address(registry), depositAmt);
        registry.deposit(platformId, address(token), depositAmt);

        vm.prank(kms);
        address wallet = registry.deployUserWallet(platformId, userId);

        PlatformRegistryV2 v2Impl = new PlatformRegistryV2();
        vm.prank(defaultAdmin);
        registry.upgradeTo(address(v2Impl));

        assertTrue(registry.platformExists(platformId));
        assertEq(registry.platformBalance(platformId, address(token)), depositAmt);
        assertEq(registry.computeUserWalletAddress(platformId, userId), wallet);
        assertTrue(registry.hasRole(registry.ADMIN_ROLE(), admin));
        assertTrue(registry.hasRole(registry.KMS_ROLE(), kms));
        assertEq(PlatformRegistryV2(address(registry)).version(), 2);
    }

    function test_upgradeRegistry_revertIfNotDefaultAdmin() public {
        PlatformRegistryV2 v2Impl = new PlatformRegistryV2();

        vm.prank(admin);
        vm.expectRevert();
        registry.upgradeTo(address(v2Impl));

        vm.prank(kms);
        vm.expectRevert();
        registry.upgradeTo(address(v2Impl));

        vm.prank(address(0xDEAD));
        vm.expectRevert();
        registry.upgradeTo(address(v2Impl));
    }

    function test_upgradeRegistry_revertIfNotUUPS() public {
        NotUUPS notUups = new NotUUPS();

        vm.prank(defaultAdmin);
        vm.expectRevert();
        registry.upgradeTo(address(notUups));
    }

    function test_cannotReinitialize() public {
        address[] memory admins = new address[](1);
        admins[0] = address(0xDEAD);
        address[] memory kmsSigners = new address[](1);
        kmsSigners[0] = address(0xBEEF);

        vm.expectRevert("Initializable: contract is already initialized");
        registry.initialize(address(0xDEAD), address(0xBEEF), address(0xCAFE), admins, kmsSigners);
    }

    // ================================================================
    // Beacon upgrade (wallet implementation)
    // ================================================================

    function test_beaconUpgrade_existingWalletsGetNewLogic() public {
        vm.prank(kms);
        registry.registerPlatform(platformId);

        vm.prank(kms);
        address wallet = registry.deployUserWallet(platformId, userId);

        (bool ok,) = wallet.staticcall(abi.encodeWithSignature("version()"));
        assertFalse(ok);

        PlatformUserV2 v2Impl = new PlatformUserV2();
        vm.prank(admin);
        registry.upgradeWalletImplementation(address(v2Impl));

        assertEq(PlatformUserV2(payable(wallet)).version(), 2);
        assertEq(PlatformUser(payable(wallet)).registry(), address(registry));
    }

    function test_beaconUpgrade_revertIfNotAdmin() public {
        PlatformUserV2 v2Impl = new PlatformUserV2();

        vm.prank(kms);
        vm.expectRevert();
        registry.upgradeWalletImplementation(address(v2Impl));

        vm.prank(address(0xDEAD));
        vm.expectRevert();
        registry.upgradeWalletImplementation(address(v2Impl));
    }

    function test_beaconUpgrade_newWalletsUseNewImpl() public {
        vm.prank(kms);
        registry.registerPlatform(platformId);

        PlatformUserV2 v2Impl = new PlatformUserV2();
        vm.prank(admin);
        registry.upgradeWalletImplementation(address(v2Impl));

        vm.prank(kms);
        address wallet = registry.deployUserWallet(platformId, userId);

        assertEq(PlatformUserV2(payable(wallet)).version(), 2);
        assertEq(PlatformUser(payable(wallet)).registry(), address(registry));
    }

    function test_upgradeWalletImplementation() public {
        PlatformUser newImpl = new PlatformUser();

        vm.prank(admin);
        registry.upgradeWalletImplementation(address(newImpl));

        assertEq(UpgradeableBeacon(registry.walletBeacon()).implementation(), address(newImpl));
    }
}
