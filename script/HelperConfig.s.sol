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
    UNISWAP_V2_ROUTER_02_SEPOLIA,
    LOCAL_CHAIN_ID,
    SEPOLIA_CHAIN_ID,
    MAINNET_CHAIN_ID
} from "../src/Constants.sol";
import {WETH, USDC} from "../test/mocks/Tokens.sol";

contract HelperConfig is Script {
    error HelperConfig__InvalidChainId();

    uint8 public constant DECIMALS = 8;
    int256 public constant INITIAL_PRICE = 3000e8; // 3000 USD

    struct NetworkConfig {
        address priceFeed; // ETH/USD price feed address
        //address vrfCoordinator; // VRF coordinator address
        address weth; // WETH address
        address usdc; // USDC address
        address router; // Uniswap V2 router address
        address account; // account address to use for deployment
        uint256 interval; // interval in seconds
    }

    NetworkConfig public activeNetworkConfig;
    mapping(uint256 chainId => NetworkConfig) public networkConfigs;

    constructor() {
        networkConfigs[SEPOLIA_CHAIN_ID] = getSepoliaEthConfig();
        networkConfigs[MAINNET_CHAIN_ID] = getMainnetEthConfig();
    }

    function getConfigByChainId(uint256 chainId) public returns (NetworkConfig memory) {
        if (networkConfigs[chainId].priceFeed != address(0)) {
            return networkConfigs[chainId];
        } else if (chainId == LOCAL_CHAIN_ID) {
            return getOrCreateAnvilEthConfig();
        } else {
            revert HelperConfig__InvalidChainId();
        }
    }

    function getConfig() public returns (NetworkConfig memory) {
        return getConfigByChainId(block.chainid);
    }

    function getSepoliaEthConfig() public pure returns (NetworkConfig memory) {
        return NetworkConfig({
            priceFeed: CHAINLINK_FEED_ETH_USD_SEPOLIA,
            //vrfCoordinator: 0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B, // TODO need to deploy a VFR coordinator for sepolia
            weth: WETH_SEPOLIA,
            usdc: USDC_SEPOLIA,
            router: UNISWAP_V2_ROUTER_02_SEPOLIA,
            account: 0x01BF49D75f2b73A2FDEFa7664AEF22C86c5Be3df,
            interval: 30 // 30 seconds
        });
    }

    function getMainnetEthConfig() public pure returns (NetworkConfig memory) {
        return NetworkConfig({
            priceFeed: CHAINLINK_FEED_ETH_USD_MAINNET,
            //vrfCoordinator: 0x271682736F0902e401497749a1b4a393788a2fe4, // TODO need to deploy a VFR coordinator for mainnet
            weth: WETH_MAINNET,
            usdc: USDC_MAINNET,
            router: UNISWAP_V2_ROUTER_02_MAINNET,
            account: 0x01BF49D75f2b73A2FDEFa7664AEF22C86c5Be3df,
            interval: 3600 // 1 hour in seconds
        });
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
            router: UNISWAP_V2_ROUTER_02_MAINNET, // TODO: need to deploy a mock router for anvil
            account: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266,
            interval: 30 // 30 seconds
        });

        return anvilConfig;
    }
}
