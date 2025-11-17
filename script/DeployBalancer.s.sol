// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {Balancer} from "../src/Balancer.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployBalancer is Script {
    uint8 constant REBALANCE_THRESHOLD = 5;
    uint8 constant MAX_SUPPORTED_TOKENS = 2;

    function run() external returns (Balancer) {
        HelperConfig helperConfig = new HelperConfig();
        (address priceFeed, address weth, address usdc, address router) = helperConfig.activeNetworkConfig();

        vm.startBroadcast();
        Balancer balancer = new Balancer(priceFeed, weth, router, REBALANCE_THRESHOLD, MAX_SUPPORTED_TOKENS);
        vm.stopBroadcast();

        return balancer;
    }
}
