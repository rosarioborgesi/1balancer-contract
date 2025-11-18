// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {IUSDC} from "../../src/interfaces/IUSDC.sol";
import {IUniswapV2Router02} from "../../src/interfaces/uniswap-v2/IUniswapV2Router02.sol";
import {IUniswapV2Pair} from "../../src/interfaces/uniswap-v2/IUniswapV2Pair.sol";
import {
    WETH_MAINNET,
    USDC_MAINNET,
    UNISWAP_V2_PAIR_USDC_WETH_MAINNET,
    UNISWAP_V2_ROUTER_02_MAINNET,
    CHAINLINK_FEED_ETH_USD_MAINNET
} from "../../src/Constants.sol";
import {Balancer} from "../../src/Balancer.sol";

contract BalancerForkTest is Test {
    Balancer public balancer;

    IWETH public constant weth = IWETH(WETH_MAINNET);
    IUSDC public constant usdc = IUSDC(USDC_MAINNET);

    IUniswapV2Router02 public constant router = IUniswapV2Router02(UNISWAP_V2_ROUTER_02_MAINNET);
    IUniswapV2Pair public constant pair = IUniswapV2Pair(UNISWAP_V2_PAIR_USDC_WETH_MAINNET);

    uint256 constant STARTING_BALANCE = 100 ether;
    uint8 constant REBALANCE_THRESHOLD = 5;
    uint8 constant MAX_SUPPORTED_TOKENS = 2;

    address user = makeAddr("user");

    function setUp() public {
        vm.createSelectFork(vm.envString("FORK_URL"));
        vm.deal(user, STARTING_BALANCE);

        balancer = new Balancer(
            address(weth), address(usdc), address(router), CHAINLINK_FEED_ETH_USD_MAINNET, REBALANCE_THRESHOLD, 2
        );

        balancer.addAllowedToken(address(weth));
        balancer.addAllowedToken(address(usdc));
    }

    /*////////////////////////////////////////////////////////////// 
                            DEPOSIT
    //////////////////////////////////////////////////////////////*/

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

        Balancer.UserPortfolio memory portfolio = balancer.getUserToPortfolio(user);
        console2.log("=== User Portfolio ===");
        console2.log("WETH balance:", portfolio.balances[0]); // 500000000000000000 - 18 decimals (0.5 WETH ~ 1,734 USD of value)
        console2.log("USDC balance:", portfolio.balances[1]); // 1737258970 - 6 decimals (1,737.258970 USDC ~ 1,734 USD of value)

        assertEq(portfolio.tokens.length, 2, "Portfolio tokens length is not 2");
        assertEq(portfolio.tokens[0], address(weth), "Portfolio token 0 is not WETH");
        assertEq(portfolio.tokens[1], address(usdc), "Portfolio token 1 is not USDC");
        assertEq(portfolio.balances[0], 5 * 10 ** 17, "WETH balance is not 500000000000000000");
        assertGt(portfolio.balances[1], 1 * 1e6, "USDC balance is not greater than 1 USDC");
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

        Balancer.UserPortfolio memory portfolio = balancer.getUserToPortfolio(user);
        console2.log("=== User Portfolio ===");
        console2.log("WETH balance:", portfolio.balances[0]); // 500000000000000000 - 18 decimals (0.5 WETH ~ 1,734 USD of value)
        console2.log("USDC balance:", portfolio.balances[1]); // 1734811332 - 6 decimals (1,734.811332 USDC ~ 1,734 USD of value)

        assertEq(portfolio.tokens.length, 2, "Portfolio tokens length is not 2");
        assertEq(portfolio.tokens[0], address(weth), "Portfolio token 0 is not WETH");
        assertEq(portfolio.tokens[1], address(usdc), "Portfolio token 1 is not USDC");
        assertEq(portfolio.balances[0], 5 * 10 ** 17, "WETH balance is not 500000000000000000");
        assertGt(portfolio.balances[1], 1 * 1e6, "USDC balance is not greater than 1 USDC");
    }

    function testCreatingUserAllocationAndDepositingUsdc() public {
        // Mint USDC to the user. Only the master minter can mint USDC.
        address masterMinter = usdc.masterMinter();
        vm.prank(masterMinter);
        usdc.configureMinter(user, type(uint256).max);

        uint256 depositAmount = 10_000 * 1e6; // ~ 10,000 USD of value

        vm.startPrank(user);
        usdc.mint(user, depositAmount); // Mint 100,000 USDC to the user
        usdc.approve(address(balancer), depositAmount);
        vm.stopPrank();

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
        balancer.deposit(address(usdc), depositAmount);
        vm.stopPrank();

        Balancer.UserPortfolio memory portfolio = balancer.getUserToPortfolio(user);
        console2.log("=== User Portfolio ===");
        console2.log("WETH balance:", portfolio.balances[0]); // 1429502594553796163 - 18 decimals (1.429502594553796163 WETH ~ 5,000 USD of value)
        console2.log("USDC balance:", portfolio.balances[1]); // 5000000000 - 6 decimals  (5,000 USDC ~ 5,000 USD of value)

        assertEq(portfolio.tokens.length, 2, "Portfolio tokens length is not 2");
        assertEq(portfolio.tokens[0], address(weth), "Portfolio token 0 is not WETH");
        assertEq(portfolio.tokens[1], address(usdc), "Portfolio token 1 is not USDC");
        assertGt(portfolio.balances[0], 1 * 1e17, "USDC balance is not greater than 1e17 wei");
        assertEq(portfolio.balances[1], 5_000 * 1e6, "WETH balance is not greater then 1 USDC");
    }

    
}
