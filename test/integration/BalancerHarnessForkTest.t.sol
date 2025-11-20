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
import {BalancerHarness} from "../mocks/BalancerHarness.sol";
import {Balancer} from "../../src/Balancer.sol";
import {PriceConverter} from "../../src/PriceConverter.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract BalancerHarnessForkTest is Test {
    BalancerHarness public harness;

    IWETH public constant weth = IWETH(WETH_MAINNET);
    IUSDC public constant usdc = IUSDC(USDC_MAINNET);

    IUniswapV2Router02 public constant router = IUniswapV2Router02(UNISWAP_V2_ROUTER_02_MAINNET);
    IUniswapV2Pair public constant pair = IUniswapV2Pair(UNISWAP_V2_PAIR_USDC_WETH_MAINNET);

    AggregatorV3Interface public constant priceFeed = AggregatorV3Interface(CHAINLINK_FEED_ETH_USD_MAINNET);

    uint256 constant STARTING_BALANCE = 100 ether;
    uint256 constant REBALANCE_THRESHOLD = 5 * 1e16; // 5%
    uint8 constant MAX_SUPPORTED_TOKENS = 2;
    uint256 constant INTERVAL = 30; // 30 seconds

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
            MAX_SUPPORTED_TOKENS,
            INTERVAL
        );

        harness.addAllowedToken(address(weth));
        harness.addAllowedToken(address(usdc));
    }

    /*////////////////////////////////////////////////////////////// 
                            REBALANCE USER PORTFOLIO
    //////////////////////////////////////////////////////////////*/

    function testRebalancesUserPortfolioWhenWethIsHigherThanUsdc() public {
        uint256 WETH_AMOUNT = 1 ether;
        uint256 USDC_AMOUNT = 1 * 1e6;

        // Depositing 1 WETH and 1 USDC to the contract
        deal(address(weth), address(harness), WETH_AMOUNT);
        deal(address(usdc), address(harness), USDC_AMOUNT);

        console2.log("WETH address", address(weth));
        console2.log("USDC address", address(usdc));
        // Creating User Portfolio
        address[] memory tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(usdc);

        uint256[] memory balances = new uint256[](2);
        balances[0] = WETH_AMOUNT;
        balances[1] = USDC_AMOUNT; // 1 USDC

        address[] memory investmentTokens = new address[](2);
        investmentTokens[0] = address(weth);
        investmentTokens[1] = address(usdc);

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 5 * 10 ** 17; // 50%
        allocations[1] = 5 * 10 ** 17; // 50%

        Balancer.AllocationPreference memory allocationPreference =
            Balancer.AllocationPreference(investmentTokens, allocations);

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
        assertLt(wethAfter, wethBefore, "WETH should decrease after rebalancing");
        // 2. USDC allocation should increase
        assertGt(usdcAfter, usdcBefore, "USDC should increase after rebalancing");

        // Get total portfolio value in USD
        uint256 wethValueUsd = PriceConverter.getConversionRate(WETH_AMOUNT, priceFeed);
        uint256 usdcValueUsd = USDC_AMOUNT * 1e12; // normalize to 18 decimals
        uint256 totalValueUsd = wethValueUsd + usdcValueUsd;

        // Calculate target WETH value (50% of total)
        uint256 targetWethValueUsd = (totalValueUsd * allocations[0]) / PERCENTAGE_FACTOR;

        // Calculate excess WETH value that needs to be swapped
        uint256 excessWethValueUsd = wethValueUsd - targetWethValueUsd;

        // Convert excess USD back to WETH amount
        uint256 ethPriceUsd = PriceConverter.getPrice(priceFeed);
        uint256 expectedWethToSwap = (excessWethValueUsd * 1e18) / ethPriceUsd;

        console2.log("Expected WETH to swap", expectedWethToSwap); // 499836631509197180 - WETH 18 decimals

        // 3. WETH should decrease by approximately the expected swap amount
        uint256 actualWethSwapped = wethBefore - wethAfter;

        console2.log("Actual WETH swapped", actualWethSwapped); // 499673369740579426 - WETH 18 decimals

        assertApproxEqRel(
            actualWethSwapped, expectedWethToSwap, 5e16, "Should swap expected amount of WETH (within 5% tolerance)"
        );

        // 4. USDC should increase by approximately the expected swap amount
        uint256 expectedUsdcReceived = actualWethSwapped.getConversionRate(priceFeed) / 1e12;
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

    function testRebalancesUserPortfolioWhenUsdcIsHigherThanWeth() public {
        uint256 WETH_AMOUNT = 1e13 wei; // equivalent to  0.00001 Ether  (approximately 0.03 USD) -  WETH 18 decimals
        uint256 USDC_AMOUNT = 1000 * 1e6; // 1000 USDC - USDC 6 decimals

        // Depositing 1 WETH and 1 USDC to the contract
        deal(address(weth), address(harness), WETH_AMOUNT);
        deal(address(usdc), address(harness), USDC_AMOUNT);

        console2.log("WETH address", address(weth));
        console2.log("USDC address", address(usdc));
        // Creating User Portfolio
        address[] memory tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(usdc);

        uint256[] memory balances = new uint256[](2);
        balances[0] = WETH_AMOUNT;
        balances[1] = USDC_AMOUNT;

        address[] memory investmentTokens = new address[](2);
        investmentTokens[0] = address(weth);
        investmentTokens[1] = address(usdc);

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 5 * 10 ** 17; // 50%
        allocations[1] = 5 * 10 ** 17; // 50%

        Balancer.AllocationPreference memory allocationPreference =
            Balancer.AllocationPreference(investmentTokens, allocations);

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
        // 1. WETH allocation should increase
        assertGt(wethAfter, wethBefore, "WETH should increase after rebalancing");
        // 2. USDC allocation should decrease
        assertLt(usdcAfter, usdcBefore, "USDC should decrease after rebalancing");

        // Get total portfolio value in USD
        uint256 wethValueUsd = PriceConverter.getConversionRate(WETH_AMOUNT, priceFeed);
        uint256 usdcValueUsd = USDC_AMOUNT * 1e12; // normalize to 18 decimals
        uint256 totalValueUsd = wethValueUsd + usdcValueUsd;

        // Calculate target USDC value (50% of total)
        uint256 targetUsdcValueUsd = (totalValueUsd * allocations[1]) / PERCENTAGE_FACTOR;

        // Calculate excess WETH value that needs to be swapped
        uint256 excessUsdcValueUsd = usdcValueUsd - targetUsdcValueUsd;

        // Convert excess USD back to WETH amount
        uint256 ethPriceUsd = PriceConverter.getPrice(priceFeed);
        uint256 expectedUsdcToSwap = excessUsdcValueUsd / 1e12; // Normalize to 6 decimals

        console2.log("Expected USDC to swap", expectedUsdcToSwap); //

        // 3. WETH should decrease by approximately the expected swap amount
        uint256 actualUsdcSwapped = usdcBefore - usdcAfter;

        console2.log("Actual USDC swapped", actualUsdcSwapped); //

        // 3. USDC should decrease by approximately the expected swap amount

        assertApproxEqRel(
            actualUsdcSwapped,
            expectedUsdcToSwap,
            5 * 1e16,
            "Should receive expected amount of USDC (within 5% tolerance)"
        );

        // 4. WETH should increase by approximately the expected swap amount
        uint256 actualWethSwapped = wethAfter - wethBefore;
        console2.log("Actual WETH swapped", actualWethSwapped);

        // Convert excess USD back to WETH amount
        uint256 expectedWethToSwap = (actualUsdcSwapped * 1e12 * 1e18) / ethPriceUsd;

        console2.log("Expected WETH to swap", expectedWethToSwap);
        assertApproxEqRel(
            actualWethSwapped, expectedWethToSwap, 5e16, "Should swap expected amount of WETH (within 5% tolerance)"
        );
    }

    // Let's write a new test where there is no rebalance because the allocation is already 50/50
    function testNoRebalanceWhenWethAndUsdcAreBalanced() public {
        uint256 WETH_AMOUNT = 1 ether;
        uint256 USDC_AMOUNT = PriceConverter.getConversionRate(WETH_AMOUNT, priceFeed) / 1e12;

        // Depositing 1 WETH and 1 USDC to the contract
        deal(address(weth), address(harness), WETH_AMOUNT);
        deal(address(usdc), address(harness), USDC_AMOUNT);

        console2.log("WETH address", address(weth));
        console2.log("USDC address", address(usdc));
        // Creating User Portfolio
        address[] memory tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(usdc);

        uint256[] memory balances = new uint256[](2);
        balances[0] = WETH_AMOUNT;
        balances[1] = USDC_AMOUNT;

        address[] memory investmentTokens = new address[](2);
        investmentTokens[0] = address(weth);
        investmentTokens[1] = address(usdc);

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 5 * 10 ** 17; // 50%
        allocations[1] = 5 * 10 ** 17; // 50%

        Balancer.AllocationPreference memory allocationPreference =
            Balancer.AllocationPreference(investmentTokens, allocations);

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
        // 1. WETH balance should be the same
        assertEq(wethAfter, wethBefore, "WETH balance should be the same");
        // 2. USDC balance should be the same
        assertEq(usdcAfter, usdcBefore, "USDC balance should be the same");
    }

    /*////////////////////////////////////////////////////////////// 
                            PERFORM UPKEEP
    //////////////////////////////////////////////////////////////*/

    function testPerformUpkeepCanOnlyRunIfCheckUpkeepIsTrue() public {
        uint256 WETH_AMOUNT = 100000000000000 wei;
        uint256 USDC_AMOUNT = 1000 * 1e6;

        vm.warp(block.timestamp + INTERVAL + 1);
        vm.roll(block.number + 1);

        // Depositing 1 WETH and 1 USDC to the contract
        deal(address(weth), address(harness), WETH_AMOUNT);
        deal(address(usdc), address(harness), USDC_AMOUNT);

        // Creating AllocationPreference
        address[] memory investmentTokens = new address[](2);
        investmentTokens[0] = address(weth);
        investmentTokens[1] = address(usdc);

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 5 * 10 ** 17; // 50%
        allocations[1] = 5 * 10 ** 17; // 50%

        Balancer.AllocationPreference memory allocationPreference =
            Balancer.AllocationPreference(investmentTokens, allocations);

        // Creating User Portfolio
        address[] memory tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(usdc);

        uint256[] memory balances = new uint256[](2);
        balances[0] = WETH_AMOUNT; // equivalent to 0.0001 WETH approximately 0.3 USD so less then 1% of the portfolio value
        balances[1] = USDC_AMOUNT; // 1000 USDC so more then 99% of the portfolio value

        vm.startPrank(user);
        harness.setUserAllocation(allocationPreference);
        harness.setTestPortfolio(user, tokens, balances);
        vm.stopPrank();

        // Act / Assert
        harness.performUpkeep("");
    }

    function testPerformUpkeepRevertsIfCheckUpkeepIsFalse() public {
        uint256 WETH_AMOUNT = 1 ether;
        uint256 USDC_AMOUNT = PriceConverter.getConversionRate(WETH_AMOUNT, priceFeed) / 1e12;

        // Depositing 1 WETH and 1 USDC to the contract
        deal(address(weth), address(harness), WETH_AMOUNT);
        deal(address(usdc), address(harness), USDC_AMOUNT);

        // Creating User Portfolio
        address[] memory tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(usdc);

        uint256[] memory balances = new uint256[](2);
        balances[0] = WETH_AMOUNT;
        balances[1] = USDC_AMOUNT;

        address[] memory investmentTokens = new address[](2);
        investmentTokens[0] = address(weth);
        investmentTokens[1] = address(usdc);

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 5 * 10 ** 17; // 50%
        allocations[1] = 5 * 10 ** 17; // 50%

        Balancer.AllocationPreference memory allocationPreference =
            Balancer.AllocationPreference(investmentTokens, allocations);

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

        // Act / Assert
        vm.expectRevert(abi.encodeWithSelector(Balancer.Balancer__UpkeepNotNeeded.selector));
        harness.performUpkeep("");
    }
}
