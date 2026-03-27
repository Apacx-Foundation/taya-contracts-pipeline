// SPDX-License-Identifier: MIT
pragma solidity ^0.8.15;

import "openzeppelin-contracts/contracts/access/AccessControl.sol";
import "openzeppelin-contracts/contracts/proxy/utils/Initializable.sol";
import "openzeppelin-contracts/contracts/proxy/utils/UUPSUpgradeable.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract BettingToken is Initializable, ERC20, AccessControl, UUPSUpgradeable {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BLACKLISTER_ROLE = keccak256("BLACKLISTER_ROLE");

    string private _tokenName;
    string private _tokenSymbol;

    mapping(address => bool) public blacklisted;

    event Blacklisted(address indexed account);
    event Unblacklisted(address indexed account);
    event NameChanged(string newName);
    event SymbolChanged(string newSymbol);

    error BlacklistedAddress(address account);

    modifier notBlacklisted(address account) {
        if (blacklisted[account]) revert BlacklistedAddress(account);
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() ERC20("", "") {
        _disableInitializers();
    }

    function initialize(string calldata name_, string calldata symbol_, address defaultAdmin) external initializer {
        _tokenName = name_;
        _tokenSymbol = symbol_;

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(MINTER_ROLE, defaultAdmin);
        _grantRole(BLACKLISTER_ROLE, defaultAdmin);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ---- ERC20 metadata overrides ----

    function name() public view override returns (string memory) {
        return _tokenName;
    }

    function symbol() public view override returns (string memory) {
        return _tokenSymbol;
    }

    // ---- Name / Symbol (DEFAULT_ADMIN_ROLE) ----

    function setName(string calldata newName) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _tokenName = newName;
        emit NameChanged(newName);
    }

    function setSymbol(string calldata newSymbol) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _tokenSymbol = newSymbol;
        emit SymbolChanged(newSymbol);
    }

    // ---- Blacklist (BLACKLISTER_ROLE) ----

    function blacklist(address account) external onlyRole(BLACKLISTER_ROLE) {
        blacklisted[account] = true;
        emit Blacklisted(account);
    }

    function unblacklist(address account) external onlyRole(BLACKLISTER_ROLE) {
        blacklisted[account] = false;
        emit Unblacklisted(account);
    }

    // ---- Minting (MINTER_ROLE) ----

    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    // ---- Transfer hooks (blacklist enforcement) ----

    function _beforeTokenTransfer(address from, address to, uint256 amount)
        internal
        override
        notBlacklisted(from)
        notBlacklisted(to)
    {
        super._beforeTokenTransfer(from, to, amount);
    }

    // ---- ERC165 ----

    function supportsInterface(bytes4 interfaceId) public view override(AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
