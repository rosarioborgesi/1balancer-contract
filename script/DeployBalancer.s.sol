// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script} from "forge-std/Script.sol";
import {Balancer} from "../src/Balancer.sol";
import {HelperConfig} from "./HelperConfig.s.sol";

contract DeployBalancer is Script {
    uint256 constant REBALANCE_THRESHOLD = 5 * 1e16; // 5% in 18 decimals
    uint8 constant MAX_SUPPORTED_TOKENS = 2;

    function run() public {
        deployContract();
    }

    function deployContract() public returns (Balancer, HelperConfig) {
        HelperConfig helperConfig = new HelperConfig();
        HelperConfig.NetworkConfig memory config = helperConfig.getConfig();

        vm.startBroadcast(config.account);
        Balancer balancer = new Balancer(
            config.weth,
            config.usdc,
            config.router,
            config.priceFeed,
            REBALANCE_THRESHOLD,
            MAX_SUPPORTED_TOKENS,
            config.interval
        );
        vm.stopBroadcast();

        return (balancer, helperConfig);
    }
}
