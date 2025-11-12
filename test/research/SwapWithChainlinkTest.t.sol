// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {CHAINLINK_FEED_ETH_USD} from "../../src/Constants.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {IUSDC} from "../../src/interfaces/IUSDC.sol";
import {IUniswapV2Router02} from "../../src/interfaces/uniswap-v2/IUniswapV2Router02.sol";
import {IUniswapV2Pair} from "../../src/interfaces/uniswap-v2/IUniswapV2Pair.sol";
import {WETH, USDC, UNISWAP_V2_PAIR_USDC_WETH, UNISWAP_V2_ROUTER_02} from "../../src/Constants.sol";

contract SwapWithChainlinkTest is Test {
    AggregatorV3Interface private s_priceFeed;
    IWETH private constant weth = IWETH(WETH);
    IUSDC private constant usdc = IUSDC(USDC);

    IUniswapV2Router02 private constant router = IUniswapV2Router02(UNISWAP_V2_ROUTER_02);
    IUniswapV2Pair private constant pair = IUniswapV2Pair(UNISWAP_V2_PAIR_USDC_WETH);

    address user = makeAddr("user");

    uint256 constant STARTING_BALANCE = 100 ether;

    uint8 constant SLIPPAGE_TOLERANCE = 10;

    function setUp() public {
        s_priceFeed = AggregatorV3Interface(CHAINLINK_FEED_ETH_USD);
        vm.deal(user, STARTING_BALANCE);
    }

    function getEthUsdRateInWei() public view returns (uint256) {
        (, int256 answer,,,) = s_priceFeed.latestRoundData();
        console2.log("ETH / USD rate", answer); // answer: 329817000000 - 8 decimals

        // ETH/USD rate in 18 decimals
        uint256 ethUsdRateInWei = uint256(answer * 1e10);
        console2.log("ETH / USD rate in 18 decimals", ethUsdRateInWei);

        return ethUsdRateInWei; // 3298170000000000000000 - 18 decimals (wei)
    }

    /* 
    logs:
        ETH / USD rate 328634000000
        ETH / USD rate in 18 decimals 3286340000000000000000
        amountOutMin 2957
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
        path[0] = WETH;
        path[1] = USDC;

        uint256 wethAmountIn = 1 ether;
        uint256 ethUsdRate = getEthUsdRateInWei();

        uint256 minAcceptedUsdc = (ethUsdRate - ((ethUsdRate * SLIPPAGE_TOLERANCE) / 100)) / 1e18; // ETH / USD rate - 10%

        console2.log("amountOutMin", minAcceptedUsdc);

        vm.prank(user);
        // Input token amount and all subsequent output token amounts
        uint256[] memory amounts = router.swapExactTokensForTokens({
            amountIn: wethAmountIn,
            amountOutMin: minAcceptedUsdc,
            path: path,
            to: user,
            deadline: block.timestamp
        });

        console2.log("WETH", amounts[0]); // Input WETH 1000000000000000000 - 18 decimals
        console2.log("USDC", amounts[1]); // Output USDC 3224338599 - 6 decimals

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
        // Mint USDC to the user. Only the master minter can mint USDC.
        // https://github.com/circlefin/stablecoin-evm/blob/master/doc/tokendesign.md
        address masterMinter = usdc.masterMinter();
        vm.prank(masterMinter);
        usdc.configureMinter(user, type(uint256).max);

        vm.startPrank(user);
        usdc.mint(user, 100_000 * 1e6); // Mint 100,000 USDC to the user
        usdc.approve(address(router), type(uint256).max);
        vm.stopPrank();

        address[] memory path = new address[](2);
        path[0] = USDC;
        path[1] = WETH;

        uint256 ethUsdRate = getEthUsdRateInWei();

        uint256 usdcAmountIn = ethUsdRate / 1e12; // 3298170000 - 6 decimals

        uint256 minAcceptedWeth = (1 ether - ((1 ether * SLIPPAGE_TOLERANCE) / 100)); // 1 ether - 10%

        console2.log("amountOutMin", minAcceptedWeth);

        vm.prank(user);
        // Input token amount and all subsequent output token amounts
        uint256[] memory amounts = router.swapExactTokensForTokens({
            amountIn: usdcAmountIn,
            amountOutMin: minAcceptedWeth,
            path: path,
            to: user,
            deadline: block.timestamp
        });

        console2.log("USDC", amounts[0]); // Input USDC 3302912100 - 6 decimals
        console2.log("WETH", amounts[1]); // Output WETH 998256268662043214 -18 decimals

        assertGe(weth.balanceOf(user), minAcceptedWeth, "WETH balance of user is not greater than minAcceptedWeth");
        assertEq(weth.balanceOf(user), amounts[1], "WETH balance of user is not equal to amounts[1]");
    }
}
