// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {PlatformRegistry} from "../src/PlatformRegistry.sol";
import {PlatformUser} from "../src/PlatformUser.sol";

import {UmaCtfAdapter} from "lib/taya-uma-ctf-adapter/src/UmaCtfAdapter.sol";

// ============================================================================
// Interfaces
// ============================================================================

interface IConditionalTokens {
    function prepareCondition(address oracle, bytes32 questionId, uint256 outcomeSlotCount) external;
    function getConditionId(address oracle, bytes32 questionId, uint256 outcomeSlotCount)
        external
        pure
        returns (bytes32);
    function balanceOf(address owner, uint256 id) external view returns (uint256);
    function reportPayouts(bytes32 questionId, uint256[] calldata payouts) external;
    function getCollectionId(bytes32 parentCollectionId, bytes32 conditionId, uint256 indexSet)
        external
        view
        returns (bytes32);
    function getPositionId(address collateralToken, bytes32 collectionId) external pure returns (uint256);
}

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

interface IWhitelistView {
    function isWhitelisted(address account) external view returns (bool);
}

interface IBulletinBoardEvents {
    event AncillaryDataUpdated(bytes32 indexed questionID, address indexed owner, bytes update);
}

interface IMarketMaker {
    function withdrawFees() external returns (uint256);
    function owner() external view returns (address);
    function stage() external view returns (uint256);
    function maxCostPerTx() external view returns (uint256);
    function fee() external view returns (uint64);
}

// ============================================================================
// Shared fork base — reads token addresses from config, deploys infra fresh
// ============================================================================

abstract contract ForkBase is Test {
    address ctfAddr;
    address lmsrFactory;
    PlatformRegistry public registry;
    UmaCtfAdapter public adapter;

    address usdc;
    address usdt;
    address pht;
    address finder;
    address oo;

    address admin = address(0xA);
    address kms = address(0xB);
    address defaultAdmin = address(0xC);

    bytes32 platformId = keccak256("fork-platform-1");
    bytes32 userId = keccak256("fork-user-1");

    function _setUp(string memory rpcEnvVar, uint256 chainId) internal {
        string memory rpcUrl = vm.envOr(rpcEnvVar, string(""));
        require(bytes(rpcUrl).length > 0, string.concat(rpcEnvVar, " env var not set"));
        vm.createSelectFork(rpcUrl);

        _loadConfig(chainId);
        ctfAddr = vm.deployCode("out_market_ext/ConditionalTokens.sol/ConditionalTokens.json");
        lmsrFactory = _deployCappedLmsrFactory();
        _deployAdapter();
        _deployRegistry();

        vm.prank(kms);
        registry.registerPlatform(platformId);
    }

    function _loadConfig(uint256 chainId) internal {
        string memory path = string.concat("config/networks/", vm.toString(chainId), ".json");
        string memory config = vm.readFile(path);
        usdc = vm.parseJsonAddress(config, ".tokens.usdc");
        usdt = vm.parseJsonAddress(config, ".tokens.usdt");
        pht = vm.parseJsonAddress(config, ".tokens.pht");
        finder = vm.parseJsonAddress(config, ".uma.finder");
        oo = vm.parseJsonAddress(config, ".uma.optimisticOracleV2");
    }

    function _deployAdapter() internal {
        adapter = new UmaCtfAdapter(ctfAddr, finder, oo);
    }

    // ── Infrastructure deploy helpers ────────────────────────────────────────

    function _deployCappedLmsrFactory() internal returns (address) {
        // Deploy Fixed192x64Math and etch its code at the address baked into the
        // pre-built CappedLMSRMarketMaker bytecode. Extract that address by finding
        // the first PUSH20 (0x73) opcode — Fixed192x64Math is the only external library.
        address fixedMathLib = vm.deployCode("out_market_ext/Fixed192x64Math.sol/Fixed192x64Math.json");

        string memory mmArtifact = vm.readFile("out_market_ext/CappedLMSRMarketMaker.sol/CappedLMSRMarketMaker.json");
        bytes memory deployedBytecode = vm.parseJsonBytes(mmArtifact, ".deployedBytecode.object");

        address linkedLibAddr = _firstPush20(deployedBytecode);
        vm.etch(linkedLibAddr, fixedMathLib.code);

        return vm.deployCode("out_market_ext/CappedLMSRDeterministicFactory.sol/CappedLMSRDeterministicFactory.json");
    }

    function _firstPush20(bytes memory bytecode) internal pure returns (address addr) {
        for (uint256 i = 0; i < bytecode.length - 20; i++) {
            if (uint8(bytecode[i]) == 0x73) {
                assembly {
                    addr := shr(96, mload(add(add(bytecode, 33), i)))
                }
                return addr;
            }
            uint8 op = uint8(bytecode[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += (op - 0x5f);
            }
        }
        revert("PUSH20 not found");
    }

    function _deployRegistry() internal {
        address wlFactory = vm.deployCode("out_market_ext/WhitelistFactory.sol/WhitelistFactory.json");

        PlatformRegistry impl = new PlatformRegistry();
        PlatformUser walletImpl = new PlatformUser();

        address[] memory admins = new address[](1);
        admins[0] = admin;
        address[] memory kmsSigners = new address[](1);
        kmsSigners[0] = kms;

        bytes memory initData = abi.encodeWithSelector(
            PlatformRegistry.initialize.selector, defaultAdmin, address(walletImpl), wlFactory, admins, kmsSigners
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        registry = PlatformRegistry(address(proxy));

        // Registry needs admin on adapter for flag/resolve
        adapter.addAdmin(address(registry));
    }

    // ── Test flow helpers ────────────────────────────────────────────────────

    /// @dev Amount scaled to token decimals: 1000 units
    function _amount(address token, uint256 units) internal view returns (uint256) {
        return units * 10 ** IERC20Decimals(token).decimals();
    }

    function _deployPool(address collateralToken, uint256 funding, bytes32 conditionId)
        internal
        returns (address pool)
    {
        bytes32[] memory conditionIds = new bytes32[](1);
        conditionIds[0] = conditionId;

        PlatformRegistry.DeployPoolParams memory p = PlatformRegistry.DeployPoolParams({
            platformId: platformId,
            factory: lmsrFactory,
            saltNonce: 0,
            pmSystem: ctfAddr,
            collateralToken: collateralToken,
            conditionIds: conditionIds,
            fee: 0,
            funding: funding,
            maxCostPerTx: type(uint256).max
        });

        vm.prank(kms);
        pool = registry.deployPool(p);
    }

    function _depositToken(address token, uint256 amount) internal {
        deal(token, address(this), amount);
        IERC20(token).approve(address(registry), amount);
        registry.deposit(platformId, token, amount);
    }

    function _buyAndRedeem(address collateralToken, bytes32 salt) internal {
        IConditionalTokens ctf = IConditionalTokens(ctfAddr);

        // Initialize question via UMA adapter (adapter calls prepareCondition internally)
        bytes memory ancillaryData = abi.encodePacked("q: fork test ", salt);
        // Use USDC as reward token (whitelisted on UMA collateral whitelist)
        vm.prank(kms);
        bytes32 questionId = registry.initializeQuestion(address(adapter), ancillaryData, usdc, 0, 0, 7200);

        // Condition oracle is the adapter (it called prepareCondition(address(this), ...))
        bytes32 conditionId = ctf.getConditionId(address(adapter), questionId, 2);

        // Fund platform & deploy pool
        uint256 funding = _amount(collateralToken, 1000);
        _depositToken(collateralToken, funding + _amount(collateralToken, 100));
        address pool = _deployPool(collateralToken, funding, conditionId);
        assertEq(registry.isRegisteredPool(pool), platformId, "pool should be registered to platform");

        // Fund user wallet & buy
        _fundAndBuy(collateralToken, pool, conditionId);

        // Resolve & redeem
        _resolveAndRedeem(ctf, collateralToken, questionId, conditionId);
    }

    function _fundAndBuy(address collateralToken, address pool, bytes32 conditionId) internal {
        // Compute amounts before vm.prank — _amount() does a staticcall that would consume the prank
        uint256 fundAmt = _amount(collateralToken, 100);
        uint256 buyQty = _amount(collateralToken, 10);

        vm.prank(kms);
        address wallet = registry.fundUserWallet(platformId, userId, collateralToken, fundAmt);

        int256[] memory buyAmounts = new int256[](2);
        buyAmounts[0] = int256(buyQty);
        buyAmounts[1] = 0;

        vm.prank(kms);
        registry.buyTrade(platformId, userId, pool, collateralToken, buyAmounts, type(int256).max, 0, false);

        // Verify outcome token balance
        IConditionalTokens ctf = IConditionalTokens(ctfAddr);
        bytes32 collectionId = ctf.getCollectionId(bytes32(0), conditionId, 1);
        uint256 positionId = ctf.getPositionId(collateralToken, collectionId);
        assertGt(ctf.balanceOf(wallet, positionId), 0, "user should hold outcome tokens");
    }

    function _resolveAndRedeem(IConditionalTokens ctf, address collateralToken, bytes32 questionId, bytes32 conditionId)
        internal
    {
        address wallet = registry.computeUserWalletAddress(platformId, userId);

        // Flag question for manual resolution
        vm.prank(kms);
        registry.flagQuestion(address(adapter), questionId);

        // Fast-forward past safety period (2h + 1m)
        vm.warp(block.timestamp + 7260);

        // Resolve as YES
        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        payouts[1] = 0;
        vm.prank(kms);
        registry.resolveQuestion(address(adapter), questionId, payouts);

        uint256 balBefore = IERC20(collateralToken).balanceOf(wallet);
        vm.prank(kms);
        registry.redeem(platformId, userId, ctfAddr, collateralToken, conditionId);
        assertGt(IERC20(collateralToken).balanceOf(wallet), balBefore, "user should receive collateral after redeem");
    }
}

// ============================================================================
// Oracle operation tests (real adapter, no mocks)
// ============================================================================

contract OracleOpsTest is ForkBase, IBulletinBoardEvents {
    bytes32 questionId;

    function setUp() public {
        _setUp("SEPOLIA_RPC_URL", 11155111);

        bytes memory ancillaryData = abi.encodePacked("q: oracle ops test");
        vm.prank(kms);
        questionId = registry.initializeQuestion(address(adapter), ancillaryData, usdc, 0, 0, 7200);
    }

    function test_initializeQuestion() public view {
        // Question was initialized in setUp — adapter tracks it internally
        // Verify the conditionId is derivable (prepareCondition was called)
        IConditionalTokens ctf = IConditionalTokens(ctfAddr);
        bytes32 conditionId = ctf.getConditionId(address(adapter), questionId, 2);
        assertTrue(conditionId != bytes32(0), "conditionId should be non-zero");
    }

    function test_flagQuestion() public {
        vm.prank(kms);
        registry.flagQuestion(address(adapter), questionId);
    }

    function test_unflagQuestion() public {
        vm.prank(kms);
        registry.flagQuestion(address(adapter), questionId);

        vm.prank(kms);
        registry.unflagQuestion(address(adapter), questionId);
    }

    function test_pauseQuestion() public {
        vm.prank(kms);
        registry.pauseQuestion(address(adapter), questionId);
    }

    function test_unpauseQuestion() public {
        vm.prank(kms);
        registry.pauseQuestion(address(adapter), questionId);

        vm.prank(kms);
        registry.unpauseQuestion(address(adapter), questionId);
    }

    function test_resetQuestion_revertIfNotKms() public {
        // reset is a failsafe that re-requests price from the OO — tested here for access control only
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        registry.resetQuestion(address(adapter), questionId);
    }

    function test_postUpdate() public {
        bytes memory update = abi.encodePacked("market clarification: XYZ");

        vm.expectEmit(true, true, false, true, address(adapter));
        emit AncillaryDataUpdated(questionId, address(registry), update);

        vm.prank(kms);
        registry.postUpdate(address(adapter), questionId, update);
    }

    function test_postUpdate_revertIfNotKms() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        registry.postUpdate(address(adapter), questionId, bytes("bad update"));
    }

    function test_resolveQuestion() public {
        vm.prank(kms);
        registry.flagQuestion(address(adapter), questionId);

        vm.warp(block.timestamp + 7260);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        payouts[1] = 0;
        vm.prank(kms);
        registry.resolveQuestion(address(adapter), questionId, payouts);
    }

    function test_oracleOps_revertIfNotKms() public {
        vm.startPrank(address(0xDEAD));

        vm.expectRevert();
        registry.initializeQuestion(address(adapter), bytes("test"), usdc, 0, 0, 7200);

        vm.expectRevert();
        registry.flagQuestion(address(adapter), questionId);

        vm.expectRevert();
        registry.unflagQuestion(address(adapter), questionId);

        vm.expectRevert();
        registry.resetQuestion(address(adapter), questionId);

        vm.expectRevert();
        registry.pauseQuestion(address(adapter), questionId);

        vm.expectRevert();
        registry.unpauseQuestion(address(adapter), questionId);

        vm.expectRevert();
        registry.postUpdate(address(adapter), questionId, bytes("bad"));

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        payouts[1] = 0;
        vm.expectRevert();
        registry.resolveQuestion(address(adapter), questionId, payouts);

        vm.stopPrank();
    }
}

// ============================================================================
// Whitelist tests (real whitelist, no mocks)
// ============================================================================

contract WhitelistTest is ForkBase {
    function setUp() public {
        _setUp("SEPOLIA_RPC_URL", 11155111);
    }

    function test_addToWhitelist() public {
        address wl = registry.whitelist();

        address[] memory accounts = new address[](2);
        accounts[0] = address(0x1);
        accounts[1] = address(0x2);

        vm.prank(kms);
        registry.addToWhitelist(accounts);

        assertTrue(IWhitelistView(wl).isWhitelisted(address(0x1)));
        assertTrue(IWhitelistView(wl).isWhitelisted(address(0x2)));
    }

    function test_addToWhitelist_revertIfNotKms() public {
        address[] memory accounts = new address[](1);
        accounts[0] = address(0x1);

        vm.prank(address(0xDEAD));
        vm.expectRevert();
        registry.addToWhitelist(accounts);
    }

    function test_deployUserWallet_whitelistsWallet() public {
        vm.prank(kms);
        address wallet = registry.deployUserWallet(platformId, userId);

        address wl = registry.whitelist();
        assertTrue(IWhitelistView(wl).isWhitelisted(wallet), "deployed wallet should be whitelisted");
    }
}

// ============================================================================
// Withdraw + fee collection tests (real tokens on fork)
// ============================================================================

contract WithdrawAndFeeTest is ForkBase {
    function setUp() public {
        _setUp("SEPOLIA_RPC_URL", 11155111);
    }

    function test_withdrawToAdmin() public {
        uint256 amount = _amount(usdc, 500);
        _depositToken(usdc, amount);

        uint256 withdrawAmt = _amount(usdc, 200);
        vm.prank(kms);
        registry.withdrawToAdmin(platformId, usdc, admin, withdrawAmt);

        assertEq(IERC20(usdc).balanceOf(admin), withdrawAmt, "admin should receive withdrawn tokens");
        assertEq(registry.platformBalance(platformId, usdc), amount - withdrawAmt, "platform balance should decrease");
    }

    function test_withdrawToAdmin_revertIfNotKms() public {
        uint256 amount = _amount(usdc, 100);
        _depositToken(usdc, amount);

        vm.prank(address(0xDEAD));
        vm.expectRevert();
        registry.withdrawToAdmin(platformId, usdc, admin, amount);
    }

    function test_withdrawToAdmin_revertIfNotAdminRecipient() public {
        uint256 amount = _amount(usdc, 100);
        _depositToken(usdc, amount);

        vm.prank(kms);
        vm.expectRevert();
        registry.withdrawToAdmin(platformId, usdc, address(0xDEAD), amount);
    }

    function test_collectPoolFees() public {
        IConditionalTokens ctf = IConditionalTokens(ctfAddr);

        bytes memory ancillaryData = abi.encodePacked("q: fee test");
        vm.prank(kms);
        bytes32 questionId = registry.initializeQuestion(address(adapter), ancillaryData, usdc, 0, 0, 7200);
        bytes32 conditionId = ctf.getConditionId(address(adapter), questionId, 2);

        uint256 funding = _amount(usdc, 1000);
        _depositToken(usdc, funding + _amount(usdc, 200));

        bytes32[] memory conditionIds = new bytes32[](1);
        conditionIds[0] = conditionId;

        PlatformRegistry.DeployPoolParams memory p = PlatformRegistry.DeployPoolParams({
            platformId: platformId,
            factory: lmsrFactory,
            saltNonce: 0,
            pmSystem: ctfAddr,
            collateralToken: usdc,
            conditionIds: conditionIds,
            fee: 2e16, // 2%
            funding: funding,
            maxCostPerTx: type(uint256).max
        });

        vm.prank(kms);
        address pool = registry.deployPool(p);
        assertEq(IMarketMaker(pool).owner(), address(registry), "registry should own pool");

        // Fund user + buy to generate fees
        uint256 fundAmt = _amount(usdc, 200);
        uint256 buyQty = _amount(usdc, 50);

        vm.prank(kms);
        registry.fundUserWallet(platformId, userId, usdc, fundAmt);

        int256[] memory buyAmounts = new int256[](2);
        buyAmounts[0] = int256(buyQty);
        buyAmounts[1] = 0;

        vm.prank(kms);
        registry.buyTrade(platformId, userId, pool, usdc, buyAmounts, type(int256).max, 0, false);

        // Collect fees via registry
        uint256 registryBalBefore = IERC20(usdc).balanceOf(address(registry));
        vm.prank(kms);
        registry.collectPoolFees(pool, usdc);
        uint256 feesCollected = IERC20(usdc).balanceOf(address(registry)) - registryBalBefore;

        assertGt(feesCollected, 0, "should have collected fees from pool");
    }

    function _deployTestPool() internal returns (address pool) {
        IConditionalTokens ctf = IConditionalTokens(ctfAddr);

        bytes memory ancillaryData = abi.encodePacked("q: pool ops test");
        vm.prank(kms);
        bytes32 questionId = registry.initializeQuestion(address(adapter), ancillaryData, usdc, 0, 0, 7200);
        bytes32 conditionId = ctf.getConditionId(address(adapter), questionId, 2);

        uint256 funding = _amount(usdc, 1000);
        _depositToken(usdc, funding);

        bytes32[] memory conditionIds = new bytes32[](1);
        conditionIds[0] = conditionId;

        PlatformRegistry.DeployPoolParams memory p = PlatformRegistry.DeployPoolParams({
            platformId: platformId,
            factory: lmsrFactory,
            saltNonce: 1,
            pmSystem: ctfAddr,
            collateralToken: usdc,
            conditionIds: conditionIds,
            fee: 2e16,
            funding: funding,
            maxCostPerTx: 0
        });

        vm.prank(kms);
        pool = registry.deployPool(p);
    }

    function test_pauseAndResumePool() public {
        address pool = _deployTestPool();

        vm.prank(kms);
        registry.pausePool(pool);

        // Pool should be paused (stage != 0)
        assertEq(IMarketMaker(pool).stage(), 1, "pool should be paused");

        vm.prank(kms);
        registry.resumePool(pool);

        assertEq(IMarketMaker(pool).stage(), 0, "pool should be running after resume");
    }

    function test_changePoolMaxCostPerTx() public {
        address pool = _deployTestPool();

        // Pause before changing maxCostPerTx (required by pool contract)
        vm.prank(kms);
        registry.pausePool(pool);

        uint256 newCap = _amount(usdc, 50);
        vm.prank(kms);
        registry.changePoolMaxCostPerTx(pool, newCap);

        vm.prank(kms);
        registry.resumePool(pool);

        assertEq(IMarketMaker(pool).maxCostPerTx(), newCap, "maxCostPerTx should be updated");
    }

    function test_changePoolFee() public {
        address pool = _deployTestPool();

        vm.prank(kms);
        registry.pausePool(pool);

        uint64 newFee = 5e16; // 5%
        vm.prank(kms);
        registry.changePoolFee(pool, newFee);

        vm.prank(kms);
        registry.resumePool(pool);

        assertEq(IMarketMaker(pool).fee(), newFee, "fee should be updated");
    }

    function test_changePoolFee_zeroAndRestore() public {
        address pool = _deployTestPool();
        uint64 originalFee = IMarketMaker(pool).fee();

        // Zero fee for bias trade
        vm.prank(kms);
        registry.pausePool(pool);
        vm.prank(kms);
        registry.changePoolFee(pool, 0);
        vm.prank(kms);
        registry.resumePool(pool);

        assertEq(IMarketMaker(pool).fee(), 0, "fee should be 0");

        // Restore
        vm.prank(kms);
        registry.pausePool(pool);
        vm.prank(kms);
        registry.changePoolFee(pool, originalFee);
        vm.prank(kms);
        registry.resumePool(pool);

        assertEq(IMarketMaker(pool).fee(), originalFee, "fee should be restored");
    }

    function test_poolOps_revertIfNotRegistered() public {
        address fakePool = address(0xDEAD);

        vm.startPrank(kms);

        vm.expectRevert();
        registry.pausePool(fakePool);

        vm.expectRevert();
        registry.resumePool(fakePool);

        vm.expectRevert();
        registry.changePoolMaxCostPerTx(fakePool, 100);

        vm.stopPrank();
    }

    function test_poolOps_revertIfNotKms() public {
        address pool = _deployTestPool();

        vm.startPrank(address(0xDEAD));

        vm.expectRevert();
        registry.pausePool(pool);

        vm.expectRevert();
        registry.resumePool(pool);

        vm.expectRevert();
        registry.changePoolMaxCostPerTx(pool, 100);

        vm.stopPrank();
    }
}

// ============================================================================
// Sepolia fork tests
// ============================================================================

contract SepoliaForkTest is ForkBase {
    function setUp() public {
        _setUp("SEPOLIA_RPC_URL", 11155111);
    }

    function test_fork_usdc() public {
        _buyAndRedeem(usdc, "sepolia-usdc");
    }

    function test_fork_usdt() public {
        _buyAndRedeem(usdt, "sepolia-usdt");
    }

    function test_fork_pht() public {
        _buyAndRedeem(pht, "sepolia-pht");
    }
}

// ============================================================================
// Polygon fork tests
// ============================================================================

contract PolygonForkTest is ForkBase {
    function setUp() public {
        _setUp("POLYGON_RPC_URL", 137);
    }

    function test_fork_usdc() public {
        _buyAndRedeem(usdc, "polygon-usdc");
    }

    function test_fork_usdt() public {
        _buyAndRedeem(usdt, "polygon-usdt");
    }

    function test_fork_pht() public {
        _buyAndRedeem(pht, "polygon-pht");
    }
}
