// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PlatformRegistry} from "../src/PlatformRegistry.sol";
import {PlatformUser} from "../src/PlatformUser.sol";
import {UpgradeableBeacon} from "openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol";
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

contract MockUmaCtfAdapter {
    mapping(bytes32 => bool) public initialized;
    uint256 public nextQuestionNonce;

    function initialize(bytes memory, address, uint256, uint256, uint256) external returns (bytes32 questionId) {
        questionId = keccak256(abi.encode(nextQuestionNonce++));
        initialized[questionId] = true;
    }
}

contract MockUmaCtfAdapterGate {
    mapping(bytes32 => bool) public flagged;
    mapping(bytes32 => bool) public paused;
    mapping(bytes32 => bool) public resolved;

    function flag(bytes32 questionId) external returns (bool) {
        flagged[questionId] = true;
        return true;
    }

    function unflag(bytes32 questionId) external {
        flagged[questionId] = false;
    }

    function pause(bytes32 questionId) external {
        paused[questionId] = true;
    }

    function unpause(bytes32 questionId) external {
        paused[questionId] = false;
    }

    function reset(bytes32 questionId) external {
        flagged[questionId] = false;
        paused[questionId] = false;
    }

    function resolveManually(bytes32 questionId, uint256[] calldata) external {
        resolved[questionId] = true;
    }
}

contract MockConditionalTokens {
    mapping(bytes32 => bool) public conditionPrepared;

    function prepareCondition(address, bytes32 questionId, uint256) external {
        conditionPrepared[questionId] = true;
    }

    function getOutcomeSlotCount(bytes32) external pure returns (uint256) {
        return 2;
    }

    function redeemPositions(address, bytes32, bytes32, uint256[] calldata) external {}
}

// ============================================================================
// V2 mocks for upgrade tests
// ============================================================================

/// @dev PlatformRegistry with an extra function to prove the upgrade took effect
contract PlatformRegistryV2 is PlatformRegistry {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @dev PlatformUser with an extra function to prove the beacon upgrade took effect
contract PlatformUserV2 is PlatformUser {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @dev Non-UUPS contract — upgradeTo should reject it
contract NotUUPS {}

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

    function test_initializeSetsRoles() public {
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), defaultAdmin));
        assertTrue(registry.hasRole(registry.ADMIN_ROLE(), admin));
        assertTrue(registry.hasRole(registry.KMS_ROLE(), kms));
    }

    function test_initializeSetsBeaconAndWhitelist() public {
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

        // Same platform+user should revert
        vm.prank(kms);
        vm.expectRevert("already deployed");
        registry.deployUserWallet(platformId, userId);

        // Different user should succeed
        vm.prank(kms);
        address wallet2 = registry.deployUserWallet(platformId, keccak256("user-2"));
        assertTrue(wallet2 != wallet1);
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

    function test_upgradeWalletImplementation() public {
        PlatformUser newImpl = new PlatformUser();

        vm.prank(admin);
        registry.upgradeWalletImplementation(address(newImpl));

        assertEq(UpgradeableBeacon(registry.walletBeacon()).implementation(), address(newImpl));
    }

    // ================================================================
    // Oracle operation tests
    // ================================================================

    function test_initializeCondition() public {
        MockConditionalTokens mockCtf = new MockConditionalTokens();
        bytes32 qId = keccak256("q1");

        vm.prank(kms);
        registry.initializeCondition(address(mockCtf), address(this), qId, 2);

        assertTrue(mockCtf.conditionPrepared(qId));
    }

    function test_initializeQuestion() public {
        MockUmaCtfAdapter mockAdapter = new MockUmaCtfAdapter();

        vm.prank(kms);
        bytes32 qId = registry.initializeQuestion(
            address(mockAdapter), bytes("test ancillary"), address(token), 1e18, 5e17, 7200
        );

        assertTrue(mockAdapter.initialized(qId));
    }

    function test_flagQuestion() public {
        MockUmaCtfAdapterGate mockGate = new MockUmaCtfAdapterGate();
        bytes32 qId = keccak256("q1");

        vm.prank(kms);
        registry.flagQuestion(address(mockGate), qId);
        assertTrue(mockGate.flagged(qId));
    }

    function test_unflagQuestion() public {
        MockUmaCtfAdapterGate mockGate = new MockUmaCtfAdapterGate();
        bytes32 qId = keccak256("q1");

        mockGate.flag(qId);
        assertTrue(mockGate.flagged(qId));

        vm.prank(kms);
        registry.unflagQuestion(address(mockGate), qId);
        assertFalse(mockGate.flagged(qId));
    }

    function test_pauseQuestion() public {
        MockUmaCtfAdapterGate mockGate = new MockUmaCtfAdapterGate();
        bytes32 qId = keccak256("q1");

        vm.prank(kms);
        registry.pauseQuestion(address(mockGate), qId);
        assertTrue(mockGate.paused(qId));
    }

    function test_unpauseQuestion() public {
        MockUmaCtfAdapterGate mockGate = new MockUmaCtfAdapterGate();
        bytes32 qId = keccak256("q1");

        mockGate.pause(qId);
        assertTrue(mockGate.paused(qId));

        vm.prank(kms);
        registry.unpauseQuestion(address(mockGate), qId);
        assertFalse(mockGate.paused(qId));
    }

    function test_resolveQuestion() public {
        MockUmaCtfAdapterGate mockGate = new MockUmaCtfAdapterGate();
        bytes32 qId = keccak256("q1");

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        payouts[1] = 0;

        vm.prank(kms);
        registry.resolveQuestion(address(mockGate), qId, payouts);
        assertTrue(mockGate.resolved(qId));
    }

    // ================================================================
    // Whitelist management tests
    // ================================================================

    function test_addToWhitelist() public {
        address wl = registry.whitelist();

        address[] memory accounts = new address[](2);
        accounts[0] = address(0x1);
        accounts[1] = address(0x2);

        vm.prank(admin);
        registry.addToWhitelist(accounts);

        assertTrue(MockWhitelist(wl).isWhitelisted(address(0x1)));
        assertTrue(MockWhitelist(wl).isWhitelisted(address(0x2)));
    }

    function test_addToWhitelist_revertIfNotAdmin() public {
        address[] memory accounts = new address[](1);
        accounts[0] = address(0x1);

        vm.prank(kms);
        vm.expectRevert();
        registry.addToWhitelist(accounts);
    }

    // ================================================================
    // UUPS upgrade tests
    // ================================================================

    function test_upgradeRegistry_preservesState() public {
        // Set up state before upgrade
        vm.prank(kms);
        registry.registerPlatform(platformId);

        uint256 depositAmt = 500e18;
        token.mint(address(this), depositAmt);
        token.approve(address(registry), depositAmt);
        registry.deposit(platformId, address(token), depositAmt);

        vm.prank(kms);
        address wallet = registry.deployUserWallet(platformId, userId);

        // Upgrade
        PlatformRegistryV2 v2Impl = new PlatformRegistryV2();
        vm.prank(defaultAdmin);
        registry.upgradeTo(address(v2Impl));

        // State preserved
        assertTrue(registry.platformExists(platformId));
        assertEq(registry.platformBalance(platformId, address(token)), depositAmt);
        assertEq(registry.computeUserWalletAddress(platformId, userId), wallet);
        assertTrue(registry.hasRole(registry.ADMIN_ROLE(), admin));
        assertTrue(registry.hasRole(registry.KMS_ROLE(), kms));

        // New function accessible
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
    // Beacon upgrade tests (wallet implementation)
    // ================================================================

    function test_beaconUpgrade_existingWalletsGetNewLogic() public {
        vm.prank(kms);
        registry.registerPlatform(platformId);

        // Deploy a wallet before upgrade
        vm.prank(kms);
        address wallet = registry.deployUserWallet(platformId, userId);

        // V2 function should not exist yet
        (bool ok,) = wallet.staticcall(abi.encodeWithSignature("version()"));
        assertFalse(ok);

        // Upgrade beacon
        PlatformUserV2 v2Impl = new PlatformUserV2();
        vm.prank(admin);
        registry.upgradeWalletImplementation(address(v2Impl));

        // Existing wallet now has V2 logic
        assertEq(PlatformUserV2(payable(wallet)).version(), 2);
        // State preserved
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

        // Upgrade beacon first
        PlatformUserV2 v2Impl = new PlatformUserV2();
        vm.prank(admin);
        registry.upgradeWalletImplementation(address(v2Impl));

        // Deploy wallet after upgrade
        vm.prank(kms);
        address wallet = registry.deployUserWallet(platformId, userId);

        assertEq(PlatformUserV2(payable(wallet)).version(), 2);
        assertEq(PlatformUser(payable(wallet)).registry(), address(registry));
    }

    // ================================================================
    // Access control tests for oracle ops
    // ================================================================

    function test_oracleOps_revertIfNotKms() public {
        MockConditionalTokens mockCtf = new MockConditionalTokens();
        MockUmaCtfAdapterGate mockGate = new MockUmaCtfAdapterGate();
        bytes32 qId = keccak256("q1");

        vm.startPrank(address(0xDEAD));

        vm.expectRevert();
        registry.initializeCondition(address(mockCtf), address(this), qId, 2);

        vm.expectRevert();
        registry.flagQuestion(address(mockGate), qId);

        vm.expectRevert();
        registry.unflagQuestion(address(mockGate), qId);

        vm.expectRevert();
        registry.pauseQuestion(address(mockGate), qId);

        vm.expectRevert();
        registry.unpauseQuestion(address(mockGate), qId);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        payouts[1] = 0;
        vm.expectRevert();
        registry.resolveQuestion(address(mockGate), qId, payouts);

        vm.stopPrank();
    }
}
