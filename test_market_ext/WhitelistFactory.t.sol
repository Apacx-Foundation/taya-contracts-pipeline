pragma solidity ^0.5.1;

import {Whitelist} from "market-makers/Whitelist.sol";
import {WhitelistFactory} from "../src_market_ext/WhitelistFactory.sol";

/// @title WhitelistFactory Tests
contract WhitelistFactoryTest {
    WhitelistFactory public factory;

    event TestPassed(string name);

    constructor() public {
        factory = new WhitelistFactory();
    }

    function assertTrue(bool condition, string memory message) internal pure {
        require(condition, message);
    }

    function assertEq(address left, address right, string memory message) internal pure {
        require(left == right, message);
    }

    /// @notice Test creating an empty whitelist
    function test_createWhitelist() public {
        Whitelist wl = factory.createWhitelist();
        
        // Verify ownership transferred to this contract
        assertEq(wl.owner(), address(this), "owner should be caller");
        
        // Verify no one is whitelisted initially
        assertTrue(!wl.isWhitelisted(address(this)), "should not be whitelisted");
        
        emit TestPassed("test_createWhitelist");
    }

    /// @notice Test creating a whitelist with initial users
    function test_createWhitelistWithUsers() public {
        address[] memory users = new address[](2);
        users[0] = address(this);
        users[1] = address(0x1234);
        
        Whitelist wl = factory.createWhitelistWithUsers(users);
        
        // Verify ownership transferred
        assertEq(wl.owner(), address(this), "owner should be caller");
        
        // Verify users are whitelisted
        assertTrue(wl.isWhitelisted(address(this)), "caller should be whitelisted");
        assertTrue(wl.isWhitelisted(address(0x1234)), "user should be whitelisted");
        assertTrue(!wl.isWhitelisted(address(0x5678)), "random address should not be whitelisted");
        
        emit TestPassed("test_createWhitelistWithUsers");
    }

    /// @notice Test that owner can add/remove users after creation
    function test_ownerCanModifyWhitelist() public {
        Whitelist wl = factory.createWhitelist();
        
        // Add a user
        address[] memory toAdd = new address[](1);
        toAdd[0] = address(0xABCD);
        wl.addToWhitelist(toAdd);
        assertTrue(wl.isWhitelisted(address(0xABCD)), "user should be whitelisted after add");
        
        // Remove the user
        wl.removeFromWhitelist(toAdd);
        assertTrue(!wl.isWhitelisted(address(0xABCD)), "user should not be whitelisted after remove");
        
        emit TestPassed("test_ownerCanModifyWhitelist");
    }

    /// @notice Test creating whitelist with empty users array
    function test_createWhitelistWithEmptyUsers() public {
        address[] memory empty = new address[](0);
        Whitelist wl = factory.createWhitelistWithUsers(empty);
        
        assertEq(wl.owner(), address(this), "owner should be caller");
        
        emit TestPassed("test_createWhitelistWithEmptyUsers");
    }
}
