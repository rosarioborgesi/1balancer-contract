// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {IUSDC} from "../../src/interfaces/IUSDC.sol";
import {IUniswapV2Router02} from "../../src/interfaces/uniswap-v2/IUniswapV2Router02.sol";
import {IUniswapV2Pair} from "../../src/interfaces/uniswap-v2/IUniswapV2Pair.sol";
import {WETH_MAINNET, USDC_MAINNET, UNISWAP_V2_PAIR_USDC_WETH_MAINNET, UNISWAP_V2_ROUTER_02_MAINNET, CHAINLINK_FEED_ETH_USD_MAINNET} from "../../src/Constants.sol";
import {BalancerHarness} from "../mocks/BalancerHarness.sol";
import {Balancer} from "../../src/Balancer.sol";
import {PriceConverter} from "../../src/PriceConverter.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract BalancerHarnessForkTest is Test {
    BalancerHarness public harness;

    IWETH public constant weth = IWETH(WETH_MAINNET);
    IUSDC public constant usdc = IUSDC(USDC_MAINNET);

    IUniswapV2Router02 public constant router =
        IUniswapV2Router02(UNISWAP_V2_ROUTER_02_MAINNET);
    IUniswapV2Pair public constant pair =
        IUniswapV2Pair(UNISWAP_V2_PAIR_USDC_WETH_MAINNET);

    AggregatorV3Interface public constant priceFeed =
        AggregatorV3Interface(CHAINLINK_FEED_ETH_USD_MAINNET);

    uint256 constant STARTING_BALANCE = 100 ether;
    uint8 constant REBALANCE_THRESHOLD = 5;
    uint8 constant MAX_SUPPORTED_TOKENS = 2;

    using PriceConverter for uint256;

    address user = makeAddr("user");
    uint256 constant PERCENTAGE_FACTOR = 1e18;

    function setUp() public {
        vm.createSelectFork(vm.envString("FORK_URL"));
        vm.deal(user, STARTING_BALANCE);

        harness = new BalancerHarness(
            address(weth),
            address(usdc),
            address(router),
            CHAINLINK_FEED_ETH_USD_MAINNET,
            REBALANCE_THRESHOLD,
            2
        );

        harness.addAllowedToken(address(weth));
        harness.addAllowedToken(address(usdc));
    }

    /*////////////////////////////////////////////////////////////// 
                            REBALANCE USER PORTFOLIO
    //////////////////////////////////////////////////////////////*/

    function testRebalancesUserPortfolioWhenWethIsHigherThanUsdc() public {
        // Depositing 1 WETH and 1 USDC to the contract
        deal(address(weth), address(harness), 1 ether);
        deal(address(usdc), address(harness), 1 * 1e6);

        console2.log("WETH address", address(weth));
        console2.log("USDC address", address(usdc));
        // Creating User Portfolio
        address[] memory tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(usdc);

        uint256[] memory balances = new uint256[](2);
        balances[0] = 1 ether;
        balances[1] = 1 * 1e6; // 1 USDC

        address[] memory investmentTokens = new address[](2);
        investmentTokens[0] = address(weth);
        investmentTokens[1] = address(usdc);

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 5 * 10 ** 17; // 50%
        allocations[1] = 5 * 10 ** 17; // 50%

        Balancer.AllocationPreference memory allocationPreference = Balancer
            .AllocationPreference(investmentTokens, allocations);

        // Check balances BEFORE rebalancing
        uint256 wethBefore = weth.balanceOf(address(harness));
        uint256 usdcBefore = usdc.balanceOf(address(harness));

        console2.log("WETH balance before rebalancing", wethBefore);
        console2.log("USDC balance before rebalancing", usdcBefore);

        // Rebalancing the user portfolio
        vm.startPrank(user);
        harness.setUserAllocation(allocationPreference);
        harness.setTestPortfolio(user, tokens, balances);
        harness.rebalanceUserPortfolio();
        vm.stopPrank();

        // Check balances AFTER rebalancing
        uint256 wethAfter = weth.balanceOf(address(harness));
        uint256 usdcAfter = usdc.balanceOf(address(harness));

        console2.log("WETH balance after rebalancing", wethAfter);
        console2.log("USDC balance after rebalancing", usdcAfter);

        // ASSERTIONS
        // 1. WETH allocation should decrease
        assertLt(
            wethAfter,
            wethBefore,
            "WETH should decrease after rebalancing"
        );
        // 2. USDC allocation should increase
        assertGt(
            usdcAfter,
            usdcBefore,
            "USDC should increase after rebalancing"
        );

        // 3. WETH should decrease by approximately the expected swap amount
        uint256 actualWethSwapped = wethBefore - wethAfter;
        uint256 expectedWethToSwap = (1 ether * allocations[0]) /
            PERCENTAGE_FACTOR; // 1/2 ether
        console2.log("Expected WETH to swap", expectedWethToSwap);
        console2.log("Actual WETH swapped", actualWethSwapped);
        assertApproxEqRel(
            actualWethSwapped,
            expectedWethToSwap,
            5e16,
            "Should swap expected amount of WETH (within 5% tolerance)"
        );

        // 4. USDC should increase by approximately the expected swap amount
        uint256 expectedUsdcReceived = actualWethSwapped.getConversionRate(
            priceFeed
        ) / 1e12;
        console2.log("Expected USDC received", expectedUsdcReceived);
        uint256 actualUsdcReceived = usdcAfter - usdcBefore;
        console2.log("Actual USDC received", actualUsdcReceived);
        assertApproxEqRel(
            actualUsdcReceived,
            expectedUsdcReceived,
            5 * 1e16,
            "Should receive expected amount of USDC (within 5% tolerance)"
        );
    }

    
}
