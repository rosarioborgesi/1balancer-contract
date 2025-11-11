// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test} from "forge-std/Test.sol";
import {Balancer} from "../../src/Balancer.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {WETH, USDC} from "../mocks/Tokens.sol";

contract BalancerTest is Test {
    Balancer public balancer;
    WETH public weth;
    USDC public usdc;
    /* address public constant WETH_TOKEN =
        0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; */
    address public constant ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    uint8 public constant MAX_SUPPORTED_TOKENS = 2;

    address USER = makeAddr("user");

    function setUp() public {
        weth = new WETH();
        weth.mint(USER, 10_000 ether);

        usdc = new USDC();
        usdc.mint(USER, 10_000 * 10 ** 6);

        balancer = new Balancer(address(weth), ROUTER, MAX_SUPPORTED_TOKENS);

        balancer.addAllowedToken(address(weth));
        balancer.addAllowedToken(address(usdc));
    }

    function testUserAllocationIs100Percent() public {
        address[] memory investmentTokens = new address[](2);
        investmentTokens[0] = address(weth);
        investmentTokens[1] = address(usdc);

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 5 * 10 ** 17;
        allocations[1] = 5 * 10 ** 17;

        Balancer.AllocationPreference memory allocationPreference = Balancer
            .AllocationPreference(investmentTokens, allocations);

        vm.startPrank(USER);
        balancer.setUserAllocation(allocationPreference);
        vm.stopPrank();

        Balancer.AllocationPreference memory userAllocation = balancer
            .getUserAllocation(USER);
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

        Balancer.AllocationPreference memory allocationPreference = Balancer
            .AllocationPreference(investmentTokens, allocations);

        vm.startPrank(USER);
        vm.expectRevert(
            abi.encodeWithSelector(
                Balancer.Balancer__AllocationNotEqualTo100Percent.selector,
                11 * 10 ** 17
            )
        );
        balancer.setUserAllocation(allocationPreference);
        vm.stopPrank();
    }
}
