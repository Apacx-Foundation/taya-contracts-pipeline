// SPDX-License-Identifier: MIT
pragma solidity 0.8.15;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {PlatformRegistry} from "../src/PlatformRegistry.sol";
import {PlatformUser} from "../src/PlatformUser.sol";

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

// ============================================================================
// Shared fork base — reads token addresses from config, deploys infra fresh
// ============================================================================

abstract contract ForkBase is Test {
    address ctfAddr;
    address lmsrFactory;
    PlatformRegistry public registry;

    address usdc;
    address usdt;
    address pht;

    address admin = address(0xA);
    address kms = address(0xB);
    address defaultAdmin = address(0xC);

    bytes32 platformId = keccak256("fork-platform-1");
    bytes32 userId = keccak256("fork-user-1");

    function _setUp(string memory rpcEnvVar, uint256 chainId) internal {
        string memory rpcUrl = vm.envOr(rpcEnvVar, string(""));
        vm.skip(bytes(rpcUrl).length == 0);
        vm.createSelectFork(rpcUrl);

        _loadConfig(chainId);
        ctfAddr = vm.deployCode("out_market_ext/ConditionalTokens.sol/ConditionalTokens.json");
        lmsrFactory = _deployCappedLmsrFactory();
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
    }

    // ── Infrastructure deploy helpers ────────────────────────────────────────

    function _deployCappedLmsrFactory() internal returns (address) {
        // Deploy Fixed192x64Math and etch its code at the address baked into the
        // pre-built CappedLMSRMarketMaker bytecode. Extract that address by finding
        // the first PUSH20 (0x73) opcode — Fixed192x64Math is the only external library.
        address fixedMathLib = vm.deployCode("out_market_ext/Fixed192x64Math.sol/Fixed192x64Math.json");

        string memory mmArtifact =
            vm.readFile("out_market_ext/CappedLMSRMarketMaker.sol/CappedLMSRMarketMaker.json");
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
        bytes32 questionId = keccak256(abi.encode("fork-q", collateralToken, salt));

        vm.prank(kms);
        registry.initializeCondition(ctfAddr, address(registry), questionId, 2);
        bytes32 conditionId = ctf.getConditionId(address(registry), questionId, 2);

        // Fund platform & deploy pool
        uint256 funding = _amount(collateralToken, 1000);
        _depositToken(collateralToken, funding + _amount(collateralToken, 100));
        address pool = _deployPool(collateralToken, funding, conditionId);
        assertTrue(registry.isRegisteredPool(pool), "pool should be registered");

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

    function _resolveAndRedeem(
        IConditionalTokens ctf,
        address collateralToken,
        bytes32 questionId,
        bytes32 conditionId
    ) internal {
        address wallet = registry.computeUserWalletAddress(platformId, userId);

        uint256[] memory payouts = new uint256[](2);
        payouts[0] = 1;
        payouts[1] = 0;
        vm.prank(address(registry));
        ctf.reportPayouts(questionId, payouts);

        uint256 balBefore = IERC20(collateralToken).balanceOf(wallet);
        vm.prank(kms);
        registry.redeem(platformId, userId, ctfAddr, collateralToken, conditionId);
        assertGt(IERC20(collateralToken).balanceOf(wallet), balBefore, "user should receive collateral after redeem");
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
