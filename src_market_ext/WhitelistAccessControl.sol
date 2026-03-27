pragma solidity ^0.5.1;

import {Whitelist} from "market-makers/Whitelist.sol";
import {Roles} from "openzeppelin-solidity/contracts/access/Roles.sol";

/// @title Whitelist with role-based access control
/// @notice Extends Whitelist so it is type-compatible with MarketMaker.
///
///         Roles:
///           Admin       – can add/remove whitelisters, add/remove other admins.
///                         Set at deploy time from the admin list.
///           Whitelister – can add/remove users AND add new whitelisters (but NOT revoke).
///                         KMS calls initialize() to become the first whitelister,
///                         then adds each new platform SA as a whitelister.
///
///         Only admins can revoke a whitelister (e.g. if KMS is compromised).
contract WhitelistAccessControl is Whitelist {
    using Roles for Roles.Role;

    event AdminAdded(address indexed account);
    event AdminRemoved(address indexed account);
    event WhitelisterAdded(address indexed account);
    event WhitelisterRemoved(address indexed account);
    event Initialized(address indexed firstWhitelister);

    Roles.Role private _admins;
    Roles.Role private _whitelisters;
    bool public initialized;

    modifier onlyAdmin() {
        require(_admins.has(msg.sender), "WhitelistAC: caller is not admin");
        _;
    }

    modifier onlyWhitelister() {
        require(
            _whitelisters.has(msg.sender) || _admins.has(msg.sender),
            "WhitelistAC: caller is not whitelister or admin"
        );
        _;
    }

    constructor() public {
        _admins.add(msg.sender);
        emit AdminAdded(msg.sender);
    }

    // ── Initialization (one-shot, called by KMS) ────────────────────────

    /// @notice Called once by KMS to become the first whitelister
    function initialize() external {
        require(!initialized, "WhitelistAC: already initialized");
        initialized = true;
        _whitelisters.add(msg.sender);
        emit WhitelisterAdded(msg.sender);
        emit Initialized(msg.sender);
    }

    // ── Admin role management ───────────────────────────────────────────

    function isAdmin(address account) public view returns (bool) {
        return _admins.has(account);
    }

    function addAdmin(address account) external onlyAdmin {
        if (!_admins.has(account)) {
            _admins.add(account);
            emit AdminAdded(account);
        }
    }

    function removeAdmin(address account) external onlyAdmin {
        if (_admins.has(account)) {
            _admins.remove(account);
            emit AdminRemoved(account);
        }
    }

    function renounceAdmin() external {
        if (_admins.has(msg.sender)) {
            _admins.remove(msg.sender);
            emit AdminRemoved(msg.sender);
        }
    }

    // ── Whitelister role management ─────────────────────────────────────

    function isWhitelister(address account) public view returns (bool) {
        return _whitelisters.has(account);
    }

    /// @notice Whitelisters can add new whitelisters (e.g. KMS adds platform SAs)
    function addWhitelister(address account) external onlyWhitelister {
        if (!_whitelisters.has(account)) {
            _whitelisters.add(account);
            emit WhitelisterAdded(account);
        }
    }

    /// @notice Only admins can revoke a whitelister
    function removeWhitelister(address account) external onlyAdmin {
        if (_whitelisters.has(account)) {
            _whitelisters.remove(account);
            emit WhitelisterRemoved(account);
        }
    }

    function renounceWhitelister() external {
        if (_whitelisters.has(msg.sender)) {
            _whitelisters.remove(msg.sender);
            emit WhitelisterRemoved(msg.sender);
        }
    }

    // ── Whitelist operations (any whitelister or admin) ─────────────────

    function whitelisterAdd(address[] calldata users) external onlyWhitelister {
        for (uint i = 0; i < users.length; i++) {
            isWhitelisted[users[i]] = true;
        }
        emit UsersAddedToWhitelist(users);
    }

    function whitelisterRemove(address[] calldata users) external onlyWhitelister {
        for (uint i = 0; i < users.length; i++) {
            isWhitelisted[users[i]] = false;
        }
        emit UsersRemovedFromWhitelist(users);
    }
}
