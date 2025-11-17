// SPDX-License-Identifier: MIT

// 1. Deploy mocks when we are on a local anvil chain
// 2. Keep track of contract address across different chains

pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol";
import {
    CHAINLINK_FEED_ETH_USD_MAINNET,
    CHAINLINK_FEED_ETH_USD_SEPOLIA,
    WETH_SEPOLIA,
    USDC_SEPOLIA,
    WETH_MAINNET,
    USDC_MAINNET,
    UNISWAP_V2_ROUTER_02_MAINNET,
    UNISWAP_V2_ROUTER_02_SEPOLIA
} from "../src/Constants.sol";
import {WETH, USDC} from "../test/mocks/Tokens.sol";

contract HelperConfig is Script {
    NetworkConfig public activeNetworkConfig;

    uint8 public constant DECIMALS = 8;
    int256 public constant INITIAL_PRICE = 3000e8; // 3000 USD

    struct NetworkConfig {
        address priceFeed; // ETH/USD price feed address
        address weth; // WETH address
        address usdc; // USDC address
        address router; // Uniswap V2 router address
    }

    constructor() {
        if (block.chainid == 11155111) {
            activeNetworkConfig = getSepoliaEthConfig();
        } else if (block.chainid == 1) {
            activeNetworkConfig = getMainnetEthConfig();
        } else {
            activeNetworkConfig = getOrCreateAnvilEthConfig();
        }
    }

    function getSepoliaEthConfig() public pure returns (NetworkConfig memory) {
        NetworkConfig memory sepoliaConfig = NetworkConfig({
            priceFeed: CHAINLINK_FEED_ETH_USD_SEPOLIA,
            weth: WETH_SEPOLIA,
            usdc: USDC_SEPOLIA,
            router: UNISWAP_V2_ROUTER_02_SEPOLIA
        });
        return sepoliaConfig;
    }

    function getMainnetEthConfig() public pure returns (NetworkConfig memory) {
        NetworkConfig memory ethConfig = NetworkConfig({
            priceFeed: CHAINLINK_FEED_ETH_USD_MAINNET,
            weth: WETH_MAINNET,
            usdc: USDC_MAINNET,
            router: UNISWAP_V2_ROUTER_02_MAINNET
        });
        return ethConfig;
    }

    function getOrCreateAnvilEthConfig() public returns (NetworkConfig memory) {
        if (activeNetworkConfig.priceFeed != address(0)) {
            return activeNetworkConfig;
        }

        vm.startBroadcast();
        MockV3Aggregator mockPriceFeed = new MockV3Aggregator(DECIMALS, INITIAL_PRICE);
        WETH weth = new WETH();
        USDC usdc = new USDC();
        vm.stopBroadcast();

        NetworkConfig memory anvilConfig = NetworkConfig({
            priceFeed: address(mockPriceFeed),
            weth: address(weth),
            usdc: address(usdc),
            router: UNISWAP_V2_ROUTER_02_MAINNET // TODO: need to deploy a mock router for anvil
        });

        return anvilConfig;
    }
}
