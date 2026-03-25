// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "openzeppelin-contracts/contracts/access/AccessControl.sol";
import "openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";
import "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import "openzeppelin-contracts/contracts/proxy/beacon/UpgradeableBeacon.sol";
import "openzeppelin-contracts/contracts/proxy/beacon/BeaconProxy.sol";
import "openzeppelin-contracts/contracts/utils/Create2.sol";
import "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {PlatformUser} from "./PlatformUser.sol";

// ─── Interfaces ───────────────────────────────────────────────────────────────

interface IWhitelistFactory {
    function createWhitelist() external returns (address);
}

interface IWhitelist {
    function addToWhitelist(address[] calldata) external;
}

interface ICappedLMSRFactory {
    function create2CappedLMSRMarketMaker(
        uint256 saltNonce,
        address pmSystem,
        address collateralToken,
        bytes32[] calldata conditionIds,
        uint64 fee,
        address whitelist,
        uint256 funding,
        uint256 maxCostPerTx
    ) external returns (address);
}

interface ICappedLMSRPool {
    function tradeWithSurcharge(
        int256[] calldata outcomeTokenAmounts,
        int256 collateralLimit,
        uint64 surcharge,
        bool coverCollateral
    ) external returns (int256);
    function pmSystem() external view returns (address);
}

interface IConditionalTokens {
    function redeemPositions(
        address collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata indexSets
    ) external;
    function getOutcomeSlotCount(bytes32 conditionId) external view returns (uint256);
    function prepareCondition(address oracle, bytes32 questionId, uint256 outcomeSlotCount) external;
}

interface IERC1155 {
    function setApprovalForAll(address operator, bool approved) external;
}

interface IUmaCtfAdapter {
    function initialize(
        bytes memory ancillaryData,
        address rewardToken,
        uint256 reward,
        uint256 proposalBond,
        uint256 liveness
    ) external returns (bytes32 questionId);
    function getQuestion(bytes32 questionId) external view returns (bytes memory);
    function ready(bytes32 questionId) external view returns (bool);
    function resolve(bytes32 questionId) external;
    function flag(bytes32 questionId) external returns (bool);
    function unflag(bytes32 questionId) external;
    function pause(bytes32 questionId) external;
    function unpause(bytes32 questionId) external;
}

interface IUmaCtfAdapterGate {
    function flag(bytes32 questionId) external returns (bool);
    function unflag(bytes32 questionId) external;
    function pause(bytes32 questionId) external;
    function unpause(bytes32 questionId) external;
    function reset(bytes32 questionId) external;
    function resolveManually(bytes32 questionId, uint256[] calldata payouts) external;
}

// ─── WalletLib ────────────────────────────────────────────────────────────────

library WalletLib {
    function deployBeacon(address walletImplementation) external returns (address) {
        return address(new UpgradeableBeacon(walletImplementation));
    }

    function computeWalletAddress(address beacon, bytes32 salt) external view returns (address) {
        bytes memory initData = abi.encodeWithSelector(PlatformUser.initialize.selector, address(this));
        bytes memory creationCode = abi.encodePacked(type(BeaconProxy).creationCode, abi.encode(beacon, initData));
        return Create2.computeAddress(salt, keccak256(creationCode));
    }

    function deployWallet(address beacon, bytes32 salt) external returns (address) {
        bytes memory initData = abi.encodeWithSelector(PlatformUser.initialize.selector, address(this));
        return address(new BeaconProxy{salt: salt}(beacon, initData));
    }
}

// ─── PlatformRegistry ─────────────────────────────────────────────────────────

/// @title PlatformRegistry — multi-tenant vault for platform collateral & user wallets
/// @notice All user wallet addresses are derived via CREATE2. No per-user storage.
contract PlatformRegistry is Initializable, AccessControl, UUPSUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─── Roles ────────────────────────────────────────────────────────────────
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant KMS_ROLE = keccak256("KMS_ROLE");

    // ─── State ────────────────────────────────────────────────────────────────
    address public walletBeacon;
    address public whitelist;

    /// @notice Platform existence
    mapping(bytes32 => bool) public platformExists;

    /// @notice Per-platform token balances held in this contract
    mapping(bytes32 => mapping(address => uint256)) public platformBalances;

    /// @notice Registered pools (deployed via deployPool)
    mapping(address => bool) public isRegisteredPool;

    // ─── Errors ───────────────────────────────────────────────────────────────
    error PlatformAlreadyRegistered();
    error PlatformNotRegistered();
    error InsufficientPlatformBalance();
    error NotAdminAddress();
    error PoolNotRegistered();
    error UserWalletNotDeployed();

    // ─── Events ───────────────────────────────────────────────────────────────
    event PlatformRegistered(bytes32 indexed platformId);
    event Deposited(bytes32 indexed platformId, address indexed token, uint256 amount);
    event UserWalletDeployed(bytes32 indexed platformId, bytes32 indexed userId, address wallet);
    event UserWalletFunded(bytes32 indexed platformId, address indexed wallet, address indexed token, uint256 amount);
    event WithdrawnToAdmin(bytes32 indexed platformId, address indexed admin, address indexed token, uint256 amount);
    event PoolDeployed(bytes32 indexed platformId, address indexed pool);

    // ─── Modifiers ────────────────────────────────────────────────────────────
    modifier platformMustExist(bytes32 platformId) {
        if (!platformExists[platformId]) revert PlatformNotRegistered();
        _;
    }

    // ─── Structs ──────────────────────────────────────────────────────────────
    struct DeployPoolParams {
        bytes32 platformId;
        address factory;
        uint256 saltNonce;
        address pmSystem;
        address collateralToken;
        bytes32[] conditionIds;
        uint64 fee;
        uint256 funding;
        uint256 maxCostPerTx;
    }

    // ─── Initializer ──────────────────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _defaultAdmin,
        address _walletImplementation,
        address _whitelistFactory,
        address[] calldata _admins,
        address[] calldata _kmsSigners
    ) external initializer {
        // Deploy beacon for user wallets
        walletBeacon = WalletLib.deployBeacon(_walletImplementation);

        // Create the shared whitelist
        whitelist = IWhitelistFactory(_whitelistFactory).createWhitelist();

        // Set up roles
        _grantRole(DEFAULT_ADMIN_ROLE, _defaultAdmin);
        _setRoleAdmin(KMS_ROLE, ADMIN_ROLE);
        for (uint256 i = 0; i < _admins.length; i++) {
            _grantRole(ADMIN_ROLE, _admins[i]);
        }
        for (uint256 i = 0; i < _kmsSigners.length; i++) {
            _grantRole(KMS_ROLE, _kmsSigners[i]);
        }
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ================================================================
    // Platform registration (KMS_ROLE)
    // ================================================================

    function registerPlatform(bytes32 platformId) external onlyRole(KMS_ROLE) {
        if (platformExists[platformId]) revert PlatformAlreadyRegistered();
        platformExists[platformId] = true;
        emit PlatformRegistered(platformId);
    }

    // ================================================================
    // Deposit / withdraw (ADMIN_ROLE for withdraw)
    // ================================================================

    function deposit(bytes32 platformId, address token, uint256 amount)
        external
        nonReentrant
        platformMustExist(platformId)
    {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        platformBalances[platformId][token] += amount;
        emit Deposited(platformId, token, amount);
    }

    function platformBalance(bytes32 platformId, address token) external view returns (uint256) {
        return platformBalances[platformId][token];
    }

    function withdrawToAdmin(bytes32 platformId, address token, address admin, uint256 amount)
        external
        nonReentrant
        onlyRole(KMS_ROLE)
        platformMustExist(platformId)
    {
        if (!hasRole(ADMIN_ROLE, admin)) revert NotAdminAddress();
        if (platformBalances[platformId][token] < amount) revert InsufficientPlatformBalance();
        platformBalances[platformId][token] -= amount;
        IERC20(token).safeTransfer(admin, amount);
        emit WithdrawnToAdmin(platformId, admin, token, amount);
    }

    // ================================================================
    // Wallet beacon upgrade (ADMIN_ROLE)
    // ================================================================

    function upgradeWalletImplementation(address newImpl) external onlyRole(ADMIN_ROLE) {
        UpgradeableBeacon(walletBeacon).upgradeTo(newImpl);
    }

    // ================================================================
    // CREATE2 user wallet — pure derivation, NO per-user storage
    // ================================================================

    function computeUserWalletAddress(bytes32 platformId, bytes32 userId) public view returns (address) {
        bytes32 salt = keccak256(abi.encode(platformId, userId));
        return WalletLib.computeWalletAddress(walletBeacon, salt);
    }

    function deployUserWallet(bytes32 platformId, bytes32 userId)
        external
        nonReentrant
        onlyRole(KMS_ROLE)
        platformMustExist(platformId)
        returns (address wallet)
    {
        wallet = computeUserWalletAddress(platformId, userId);
        require(wallet.code.length == 0, "already deployed");
        return _getOrDeployUserWallet(platformId, userId, true);
    }

    function _getOrDeployUserWallet(bytes32 platformId, bytes32 userId, bool deploy) internal returns (address wallet) {
        wallet = computeUserWalletAddress(platformId, userId);
        if (wallet.code.length > 0) return wallet;
        if (!deploy) revert UserWalletNotDeployed();

        bytes32 salt = keccak256(abi.encode(platformId, userId));
        wallet = WalletLib.deployWallet(walletBeacon, salt);

        address[] memory users = new address[](1);
        users[0] = wallet;
        IWhitelist(whitelist).addToWhitelist(users);

        emit UserWalletDeployed(platformId, userId, wallet);
    }

    // ================================================================
    // Fund user wallet (KMS_ROLE)
    // ================================================================

    function fundUserWallet(bytes32 platformId, bytes32 userId, address token, uint256 amount)
        external
        nonReentrant
        onlyRole(KMS_ROLE)
        platformMustExist(platformId)
        returns (address userWallet)
    {
        if (platformBalances[platformId][token] < amount) revert InsufficientPlatformBalance();
        userWallet = _getOrDeployUserWallet(platformId, userId, true);
        platformBalances[platformId][token] -= amount;
        IERC20(token).safeTransfer(userWallet, amount);
        emit UserWalletFunded(platformId, userWallet, token, amount);
    }

    // ================================================================
    // Pool deployment (KMS_ROLE)
    // ================================================================

    function deployPool(DeployPoolParams calldata p)
        external
        nonReentrant
        onlyRole(KMS_ROLE)
        platformMustExist(p.platformId)
        returns (address pool)
    {
        if (platformBalances[p.platformId][p.collateralToken] < p.funding) {
            revert InsufficientPlatformBalance();
        }
        platformBalances[p.platformId][p.collateralToken] -= p.funding;

        IERC20(p.collateralToken).approve(p.factory, p.funding);
        pool = ICappedLMSRFactory(p.factory)
            .create2CappedLMSRMarketMaker(
                p.saltNonce, p.pmSystem, p.collateralToken, p.conditionIds, p.fee, whitelist, p.funding, p.maxCostPerTx
            );
        isRegisteredPool[pool] = true;
        emit PoolDeployed(p.platformId, pool);
    }

    // ================================================================
    // Trade execution (KMS_ROLE)
    // ================================================================

    function buyTrade(
        bytes32 platformId,
        bytes32 userId,
        address pool,
        address collateralToken,
        int256[] calldata outcomeAmounts,
        int256 collateralLimit,
        uint64 surchargeRate,
        bool coverCollateral
    ) external nonReentrant onlyRole(KMS_ROLE) {
        address uw = _getOrDeployUserWallet(platformId, userId, false);
        if (!isRegisteredPool[pool]) revert PoolNotRegistered();

        PlatformUser(payable(uw))
            .execute(
                collateralToken, 0, abi.encodeWithSelector(IERC20.approve.selector, pool, uint256(collateralLimit))
            );
        PlatformUser(payable(uw))
            .execute(
                pool,
                0,
                abi.encodeWithSelector(
                    ICappedLMSRPool.tradeWithSurcharge.selector,
                    outcomeAmounts,
                    collateralLimit,
                    surchargeRate,
                    coverCollateral
                )
            );
    }

    function sellTrade(
        bytes32 platformId,
        bytes32 userId,
        address pool,
        address ctf,
        int256[] calldata outcomeAmounts,
        int256 collateralLimit,
        uint64 surchargeRate,
        bool coverCollateral
    ) external nonReentrant onlyRole(KMS_ROLE) {
        address uw = _getOrDeployUserWallet(platformId, userId, false);
        if (!isRegisteredPool[pool]) revert PoolNotRegistered();

        PlatformUser(payable(uw))
            .execute(ctf, 0, abi.encodeWithSelector(IERC1155.setApprovalForAll.selector, pool, true));
        PlatformUser(payable(uw))
            .execute(
                pool,
                0,
                abi.encodeWithSelector(
                    ICappedLMSRPool.tradeWithSurcharge.selector,
                    outcomeAmounts,
                    collateralLimit,
                    surchargeRate,
                    coverCollateral
                )
            );
    }

    function redeem(bytes32 platformId, bytes32 userId, address ctf, address collateralToken, bytes32 conditionId)
        external
        nonReentrant
        onlyRole(KMS_ROLE)
    {
        address uw = _getOrDeployUserWallet(platformId, userId, false);

        uint256 outcomeSlotCount = IConditionalTokens(ctf).getOutcomeSlotCount(conditionId);
        uint256[] memory indexSets = new uint256[](outcomeSlotCount);
        for (uint256 i = 0; i < outcomeSlotCount; i++) {
            indexSets[i] = 1 << i;
        }

        PlatformUser(payable(uw))
            .execute(
                ctf,
                0,
                abi.encodeWithSelector(
                    IConditionalTokens.redeemPositions.selector, collateralToken, bytes32(0), conditionId, indexSets
                )
            );
    }

    // ================================================================
    // Oracle operations (KMS_ROLE)
    // ================================================================

    function initializeCondition(address ctf, address oracle, bytes32 questionId, uint256 outcomeSlotCount)
        external
        onlyRole(KMS_ROLE)
    {
        IConditionalTokens(ctf).prepareCondition(oracle, questionId, outcomeSlotCount);
    }

    function initializeQuestion(
        address adapter,
        bytes memory ancillaryData,
        address rewardToken,
        uint256 reward,
        uint256 proposalBond,
        uint256 liveness
    ) external onlyRole(KMS_ROLE) returns (bytes32) {
        return IUmaCtfAdapter(adapter).initialize(ancillaryData, rewardToken, reward, proposalBond, liveness);
    }

    function flagQuestion(address gate, bytes32 questionId) external onlyRole(KMS_ROLE) {
        IUmaCtfAdapterGate(gate).flag(questionId);
    }

    function unflagQuestion(address gate, bytes32 questionId) external onlyRole(KMS_ROLE) {
        IUmaCtfAdapterGate(gate).unflag(questionId);
    }

    function pauseQuestion(address gate, bytes32 questionId) external onlyRole(KMS_ROLE) {
        IUmaCtfAdapterGate(gate).pause(questionId);
    }

    function unpauseQuestion(address gate, bytes32 questionId) external onlyRole(KMS_ROLE) {
        IUmaCtfAdapterGate(gate).unpause(questionId);
    }

    function resolveQuestion(address gate, bytes32 questionId, uint256[] calldata payouts) external onlyRole(KMS_ROLE) {
        IUmaCtfAdapterGate(gate).resolveManually(questionId, payouts);
    }

    // ================================================================
    // Whitelist management (ADMIN_ROLE)
    // ================================================================

    function addToWhitelist(address[] calldata accounts) external onlyRole(ADMIN_ROLE) {
        IWhitelist(whitelist).addToWhitelist(accounts);
    }
}
