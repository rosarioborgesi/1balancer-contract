// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {Balancer} from "../../src/Balancer.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {IUSDC} from "../../src/interfaces/IUSDC.sol";
import {IUniswapV2Router02} from "../../src/interfaces/uniswap-v2/IUniswapV2Router02.sol";
import {IUniswapV2Pair} from "../../src/interfaces/uniswap-v2/IUniswapV2Pair.sol";
import {WETH, USDC, UNISWAP_V2_PAIR_USDC_WETH, UNISWAP_V2_ROUTER_02, CHAINLINK_FEED_ETH_USD} from "../../src/Constants.sol";

contract RebalancingTest is Test {
    AggregatorV3Interface private s_priceFeed;
    IWETH private constant weth = IWETH(WETH);
    IUSDC private constant usdc = IUSDC(USDC);

    IUniswapV2Router02 private constant router = IUniswapV2Router02(UNISWAP_V2_ROUTER_02);
    IUniswapV2Pair private constant pair = IUniswapV2Pair(UNISWAP_V2_PAIR_USDC_WETH);

    address USER = makeAddr("user");

    uint256 constant STARTING_BALANCE = 100 ether;

    function setUp() public {
        s_priceFeed = AggregatorV3Interface(CHAINLINK_FEED_ETH_USD);
        vm.deal(USER, STARTING_BALANCE);
    }

    function getEthUsdRateInWei() public view returns (uint256) {
        (, int256 answer,,,) = s_priceFeed.latestRoundData();
        console2.log("ETH / USD rate", answer); // answer: 329817000000 - 8 decimals

        // ETH/USD rate in 18 decimals
        uint256 ethUsdRateInWei = uint256(answer * 1e10);
        console2.log("ETH / USD rate in 18 decimals", ethUsdRateInWei);

        return ethUsdRateInWei; // 3298170000000000000000 - 18 decimals (wei)
    }
}
