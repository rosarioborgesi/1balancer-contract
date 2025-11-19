// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {IUSDC} from "../../src/interfaces/IUSDC.sol";
import {IUniswapV2Router02} from "../../src/interfaces/uniswap-v2/IUniswapV2Router02.sol";
import {IUniswapV2Pair} from "../../src/interfaces/uniswap-v2/IUniswapV2Pair.sol";
import {
    WETH_MAINNET,
    USDC_MAINNET,
    UNISWAP_V2_PAIR_USDC_WETH_MAINNET,
    UNISWAP_V2_ROUTER_02_MAINNET,
    CHAINLINK_FEED_ETH_USD_MAINNET,
    USDC_MAINNET
} from "../../src/Constants.sol";
import {PriceConverter} from "../../src/PriceConverter.sol";

contract SwapWithChainlinkTest is Test {
    AggregatorV3Interface private s_priceFeed;
    IWETH private constant weth = IWETH(WETH_MAINNET);
    IUSDC private constant usdc = IUSDC(USDC_MAINNET);

    IUniswapV2Router02 private constant router = IUniswapV2Router02(UNISWAP_V2_ROUTER_02_MAINNET);
    IUniswapV2Pair private constant pair = IUniswapV2Pair(UNISWAP_V2_PAIR_USDC_WETH_MAINNET);

    address user = makeAddr("user");

    uint256 constant STARTING_BALANCE = 100 ether;

    uint256 constant SLIPPAGE_TOLERANCE = 1 * 1e17; // 10%
    uint256 constant PERCENTAGE_FACTOR = 1e18; // 100%

    using PriceConverter for uint256;

    function setUp() public {
        vm.createSelectFork(vm.envString("FORK_URL"));
        s_priceFeed = AggregatorV3Interface(CHAINLINK_FEED_ETH_USD_MAINNET);
        vm.deal(user, STARTING_BALANCE);
    }

    /* 
    logs:
        ETH / USD rate 328634000000
        ETH / USD rate in 18 decimals 3286340000000000000000
        amountOutMin 2784423060
        WETH 1000000000000000000
        USDC 3273362536
    */
    // Swap all input tokens for as many output tokens as possible
    function testSwapWethToUsdcWithOraclePrices() public {
        // Deposit and approve WETH
        vm.startPrank(user);
        weth.deposit{value: 100 ether}();
        weth.approve(address(router), type(uint256).max);
        vm.stopPrank();

        address[] memory path = new address[](2);
        path[0] = WETH_MAINNET;
        path[1] = USDC_MAINNET;

        uint256 wethAmountIn = 1 ether;

        uint256 wethAmountInUsd = wethAmountIn.getConversionRate(s_priceFeed);

        uint256 minAcceptedUsdc =
            (wethAmountInUsd - ((wethAmountInUsd * SLIPPAGE_TOLERANCE) / PERCENTAGE_FACTOR)) / 1e12; // ETH / USD rate - 10%

        console2.log("amountOutMin", minAcceptedUsdc); // 2784423060 - USDC 6 decimals

        vm.prank(user);
        // Input token amount and all subsequent output token amounts
        uint256[] memory amounts = router.swapExactTokensForTokens({
            amountIn: wethAmountIn,
            amountOutMin: minAcceptedUsdc,
            path: path,
            to: user,
            deadline: block.timestamp
        });

        console2.log("Input WETH", amounts[0]); // Input WETH 1000000000000000000 - 18 decimals
        console2.log("Output USDC", amounts[1]); // Output USDC 3078208354 - 6 decimals

        assertGe(usdc.balanceOf(user), minAcceptedUsdc, "USDC balance of user is not greater than minAcceptedUsdc");
        assertEq(usdc.balanceOf(user), amounts[1], "USDC balance of user is not equal to amounts[1]");
    }

    /*
    logs:
        ETH / USD rate 332441760000
        ETH / USD rate in 18 decimals 3324417600000000000000
        amountOutMin 900000000000000000
        USDC 3324417600
        WETH 997702531702557978
    */
    function testSwapUsdcToWethWithOraclePrices() public {
        address masterMinter = usdc.masterMinter();
        vm.prank(masterMinter);
        usdc.configureMinter(user, type(uint256).max);

        vm.startPrank(user);
        usdc.mint(user, 100_000 * 1e6); // Mint 100,000 USDC to the user
        usdc.approve(address(router), type(uint256).max);
        vm.stopPrank();

        address[] memory path = new address[](2);
        path[0] = USDC_MAINNET;
        path[1] = WETH_MAINNET;

        uint256 ethAmount = 1 ether;

        uint256 ethUsdRate = ethAmount.getConversionRate(s_priceFeed);

        uint256 usdcAmountIn = ethUsdRate / 1e12;

        console2.log("usdcAmountIn", usdcAmountIn); // 3076289657 - USDC 6 decimals

        uint256 minAcceptedWeth = (ethAmount - ((ethAmount * SLIPPAGE_TOLERANCE) / PERCENTAGE_FACTOR)); // 1 ether - 10%

        console2.log("amountOutMin", minAcceptedWeth); // 900000000000000000 - WETH 18 decimals

        vm.prank(user);
        // Input token amount and all subsequent output token amounts
        uint256[] memory amounts = router.swapExactTokensForTokens({
            amountIn: usdcAmountIn,
            amountOutMin: minAcceptedWeth,
            path: path,
            to: user,
            deadline: block.timestamp
        });

        console2.log("Input USDC", amounts[0]); // Input USDC 3076289657 - 6 decimals
        console2.log("Output WETH", amounts[1]); // Output WETH 994045455604138669 -18 decimals

        assertGe(weth.balanceOf(user), minAcceptedWeth, "WETH balance of user is not greater than minAcceptedWeth");
        assertEq(weth.balanceOf(user), amounts[1], "WETH balance of user is not equal to amounts[1]");
    }
}
