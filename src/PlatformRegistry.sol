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
import {IERC1155} from "openzeppelin-contracts/contracts/token/ERC1155/IERC1155.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {PlatformUser} from "./PlatformUser.sol";
import {IUmaCtfAdapter} from "../lib/taya-uma-ctf-adapter/src/interfaces/IUmaCtfAdapter.sol";

interface IUmaCtfAdapterFull is IUmaCtfAdapter {
    function unflag(bytes32 questionID) external;
    function resolveManually(bytes32 questionID, uint256[] calldata payouts) external;
    function postUpdate(bytes32 questionID, bytes memory update) external;
}

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
    ) external returns (address marketMaker);
}

interface ICappedLMSRPool {
    function tradeWithSurcharge(
        int256[] calldata outcomeTokenAmounts,
        int256 collateralLimit,
        uint64 surcharge,
        bool coverCollateral
    ) external returns (int256);
    function pmSystem() external view returns (address);
    function withdrawFees() external returns (uint256);
    function pause() external;
    function resume() external;
    function changeMaxCostPerTx(uint256 newMaxCostPerTx) external;
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
    mapping(address => bytes32) public isRegisteredPool;

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
    event FeesCollected(bytes32 indexed platformId, address indexed pool, address indexed token, uint256 amount);

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
        isRegisteredPool[pool] = p.platformId;
        emit PoolDeployed(p.platformId, pool);
    }

    // ================================================================
    // Fee collection (KMS_ROLE)
    // ================================================================
    function collectPoolFees(address pool, address collateralToken) external nonReentrant onlyRole(KMS_ROLE) {
        bytes32 platformId = isRegisteredPool[pool];
        if (platformId == bytes32(0)) revert PoolNotRegistered();
        uint256 balBefore = IERC20(collateralToken).balanceOf(address(this));
        ICappedLMSRPool(pool).withdrawFees();
        uint256 collected = IERC20(collateralToken).balanceOf(address(this)) - balBefore;
        emit FeesCollected(platformId, pool, collateralToken, collected);
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
        if (isRegisteredPool[pool] == bytes32(0)) revert PoolNotRegistered();

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
        if (isRegisteredPool[pool] == bytes32(0)) revert PoolNotRegistered();

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

    function initializeQuestion(
        address adapter,
        bytes memory ancillaryData,
        address rewardToken,
        uint256 reward,
        uint256 proposalBond,
        uint256 liveness
    ) external onlyRole(KMS_ROLE) returns (bytes32) {
        return IUmaCtfAdapterFull(adapter).initialize(ancillaryData, rewardToken, reward, proposalBond, liveness);
    }

    function resolveQuestion(address adapter, bytes32 questionID, uint256[] calldata payouts)
        external
        onlyRole(KMS_ROLE)
    {
        return IUmaCtfAdapterFull(adapter).resolveManually(questionID, payouts);
    }

    function flagQuestion(address adapter, bytes32 questionID) external onlyRole(KMS_ROLE) {
        return IUmaCtfAdapterFull(adapter).flag(questionID);
    }

    function unflagQuestion(address adapter, bytes32 questionID) external onlyRole(KMS_ROLE) {
        return IUmaCtfAdapterFull(adapter).unflag(questionID);
    }

    function resetQuestion(address adapter, bytes32 questionID) external onlyRole(KMS_ROLE) {
        return IUmaCtfAdapterFull(adapter).reset(questionID);
    }

    function pauseQuestion(address adapter, bytes32 questionID) external onlyRole(KMS_ROLE) {
        return IUmaCtfAdapterFull(adapter).pause(questionID);
    }

    function unpauseQuestion(address adapter, bytes32 questionID) external onlyRole(KMS_ROLE) {
        return IUmaCtfAdapterFull(adapter).unpause(questionID);
    }

    function postUpdate(address adapter, bytes32 questionID, bytes calldata update) external onlyRole(KMS_ROLE) {
        IUmaCtfAdapterFull(adapter).postUpdate(questionID, update);
    }

    function addToWhitelist(address[] calldata accounts) external onlyRole(KMS_ROLE) {
        IWhitelist(whitelist).addToWhitelist(accounts);
    }

    // ================================================================
    // Pool operations (KMS_ROLE) — registry is pool owner
    // ================================================================

    function pausePool(address pool) external onlyRole(KMS_ROLE) {
        if (isRegisteredPool[pool] == bytes32(0)) revert PoolNotRegistered();
        ICappedLMSRPool(pool).pause();
    }

    function resumePool(address pool) external onlyRole(KMS_ROLE) {
        if (isRegisteredPool[pool] == bytes32(0)) revert PoolNotRegistered();
        ICappedLMSRPool(pool).resume();
    }

    function changePoolMaxCostPerTx(address pool, uint256 newMaxCostPerTx) external onlyRole(KMS_ROLE) {
        if (isRegisteredPool[pool] == bytes32(0)) revert PoolNotRegistered();
        ICappedLMSRPool(pool).changeMaxCostPerTx(newMaxCostPerTx);
    }

}
