// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {IUSDC} from "../../src/interfaces/IUSDC.sol";
import {IUniswapV2Router02} from "../../src/interfaces/uniswap-v2/IUniswapV2Router02.sol";
import {IUniswapV2Pair} from "../../src/interfaces/uniswap-v2/IUniswapV2Pair.sol";
import {WETH, USDC, UNISWAP_V2_PAIR_USDC_WETH, UNISWAP_V2_ROUTER_02} from "../../src/Constants.sol";
import {Balancer} from "../../src/Balancer.sol";

contract BalancerForkTest is Test {
    Balancer public balancer;

    IWETH public constant weth = IWETH(WETH);
    IUSDC public constant usdc = IUSDC(USDC);

    IUniswapV2Router02 public constant router = IUniswapV2Router02(UNISWAP_V2_ROUTER_02);
    IUniswapV2Pair public constant pair = IUniswapV2Pair(UNISWAP_V2_PAIR_USDC_WETH);

    uint256 constant STARTING_BALANCE = 100 ether;

    address user = makeAddr("user");

    function setUp() public {
        vm.createSelectFork(vm.envString("FORK_URL"));
        vm.deal(user, STARTING_BALANCE);

        balancer = new Balancer(address(weth), address(router), 2);

        balancer.addAllowedToken(address(weth));
        balancer.addAllowedToken(address(usdc));
    }

    function testCreatingUserAllocationAndDepositingEth() public {
        address[] memory investmentTokens = new address[](2);
        investmentTokens[0] = address(weth);
        investmentTokens[1] = address(usdc);

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 5 * 10 ** 17;
        allocations[1] = 5 * 10 ** 17;

        Balancer.AllocationPreference memory allocationPreference =
            Balancer.AllocationPreference(investmentTokens, allocations);

        vm.startPrank(user);

        balancer.setUserAllocation(allocationPreference);
        balancer.deposit{value: 1 ether}(address(weth), 1 ether);
        vm.stopPrank();

        Balancer.UserPortfolio memory portfolio = balancer.getUserPortfolio(user);
        console2.log("=== User Portfolio ===");
        console2.log("WETH balance:", portfolio.balances[0]); // 500000000000000000 - 18 decimals
        console2.log("USDC balance:", portfolio.balances[1]); // 1737258970 - 6 decimals
    }

    function testCreatingUserAllocationAndDepositingWeth() public {
        address[] memory investmentTokens = new address[](2);
        investmentTokens[0] = address(weth);
        investmentTokens[1] = address(usdc);

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 5 * 10 ** 17;
        allocations[1] = 5 * 10 ** 17;

        Balancer.AllocationPreference memory allocationPreference =
            Balancer.AllocationPreference(investmentTokens, allocations);

        vm.startPrank(user);

        weth.deposit{value: 1 ether}();
        weth.approve(address(balancer), 1 ether);

        balancer.setUserAllocation(allocationPreference);
        balancer.deposit(address(weth), 1 ether);
        vm.stopPrank();

        Balancer.UserPortfolio memory portfolio = balancer.getUserPortfolio(user);
        console2.log("=== User Portfolio ===");
        console2.log("WETH balance:", portfolio.balances[0]); // 500000000000000000 - 18 decimals
        console2.log("USDC balance:", portfolio.balances[1]); // 1734811332 - 6 decimals
    }

    function testCreatingUserAllocationAndDepositingUsdc() public {
        address[] memory investmentTokens = new address[](2);
        investmentTokens[0] = address(weth);
        investmentTokens[1] = address(usdc);

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 5 * 10 ** 17;
        allocations[1] = 5 * 10 ** 17;

        Balancer.AllocationPreference memory allocationPreference =
            Balancer.AllocationPreference(investmentTokens, allocations);

        vm.startPrank(user);

        weth.deposit{value: 1 ether}();
        weth.approve(address(balancer), 1 ether);

        balancer.setUserAllocation(allocationPreference);
        balancer.deposit(address(weth), 1 ether);
        vm.stopPrank();

        Balancer.UserPortfolio memory portfolio = balancer.getUserPortfolio(user);
        console2.log("=== User Portfolio ===");
        console2.log("WETH balance:", portfolio.balances[0]); // 500000000000000000 - 18 decimals
        console2.log("USDC balance:", portfolio.balances[1]); // 1734811332 - 6 decimals
    }
}
