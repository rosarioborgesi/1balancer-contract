// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {Balancer} from "../../src/Balancer.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {WETH, USDC} from "../mocks/Tokens.sol";
import {CHAINLINK_FEED_ETH_USD_MAINNET} from "../../src/Constants.sol";
import {stdError} from "forge-std/StdError.sol";
import {DeployBalancer} from "../../script/DeployBalancer.s.sol";

contract BalancerTest is Test {
    Balancer public balancer;
    WETH public weth;
    USDC public usdc;

    uint8 public constant MAX_SUPPORTED_TOKENS = 2;
    uint8 public constant REBALANCE_THRESHOLD = 5;

    address USER = makeAddr("user");
    address USER2 = makeAddr("user2");

    function setUp() public {
        DeployBalancer deployBalancer = new DeployBalancer();
        balancer = deployBalancer.run();
        balancer.addAllowedToken(address(weth));
        balancer.addAllowedToken(address(usdc));

        weth.mint(USER, 10_000 ether);
        usdc.mint(USER, 10_000 * 10 ** 6);
    }

    function testUserAllocationIs100Percent() public {
        address[] memory investmentTokens = new address[](2);
        investmentTokens[0] = address(weth);
        investmentTokens[1] = address(usdc);

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 5 * 10 ** 17;
        allocations[1] = 5 * 10 ** 17;

        Balancer.AllocationPreference memory allocationPreference =
            Balancer.AllocationPreference(investmentTokens, allocations);

        vm.startPrank(USER);
        balancer.setUserAllocation(allocationPreference);
        vm.stopPrank();

        Balancer.AllocationPreference memory userAllocation = balancer.getUserToAllocationPreference(USER);
        assertEq(userAllocation.investmentTokens.length, 2);
        assertEq(userAllocation.investmentTokens[0], address(weth));
        assertEq(userAllocation.investmentTokens[1], address(usdc));
        assertEq(userAllocation.allocations[0], 5 * 10 ** 17);
        assertEq(userAllocation.allocations[1], 5 * 10 ** 17);
    }

    function testRevertsUserAllocationIsNot100Percent() public {
        address[] memory investmentTokens = new address[](2);
        investmentTokens[0] = address(weth);
        investmentTokens[1] = address(usdc);

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 5 * 10 ** 17;
        allocations[1] = 6 * 10 ** 17;

        Balancer.AllocationPreference memory allocationPreference =
            Balancer.AllocationPreference(investmentTokens, allocations);

        vm.startPrank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(Balancer.Balancer__AllocationNotEqualTo100Percent.selector, 11 * 10 ** 17)
        );
        balancer.setUserAllocation(allocationPreference);
        vm.stopPrank();
    }

    function testAddOneUser() public {
        vm.prank(USER);
        balancer.addUser();

        assertEq(balancer.getUsersLength(), 1);
        assertEq(balancer.getUserAtIndex(0), USER);
        assertEq(balancer.isUser(USER), true);
    }

    function testAddTwoUsers() public {
        vm.prank(USER);
        balancer.addUser();
        vm.prank(USER2);
        balancer.addUser();

        assertEq(balancer.getUsersLength(), 2);
        assertEq(balancer.getUserAtIndex(0), USER);
        assertEq(balancer.getUserAtIndex(1), USER2);
        assertEq(balancer.isUser(USER), true);
        assertEq(balancer.isUser(USER2), true);
    }

    function testRemoveUser() public {
        vm.prank(USER);
        balancer.addUser();
        vm.prank(USER2);
        balancer.addUser();

        vm.prank(USER);
        balancer.removeUser();

        console2.log("Users length:", balancer.getUsersLength());
        console2.log("User 0:", balancer.getUserAtIndex(0));
        console2.log("Address to is user USER:", balancer.isUser(USER));
        console2.log("Address to is user USER2:", balancer.isUser(USER2));

        assertEq(balancer.getUsersLength(), 1);
        assertEq(balancer.getUserAtIndex(0), USER2);
        assertEq(balancer.isUser(USER), false);
        assertEq(balancer.isUser(USER2), true);
    }
}
