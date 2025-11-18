// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Balancer} from "../../src/Balancer.sol";

contract BalancerHarness is Balancer {
    constructor(
        address weth,
        address usdc,
        address router,
        address priceFeed,
        uint256 rebalanceThreshold,
        uint8 maxSupportedTokens
    ) Balancer(weth, usdc, router, priceFeed, rebalanceThreshold, maxSupportedTokens) {}

    // Add test helper to set portfolio directly
    function setTestPortfolio(address user, address[] memory tokens, uint256[] memory balances) external {
        UserPortfolio storage portfolio = s_userToPortfolio[user];
        for (uint256 i = 0; i < tokens.length; i++) {
            portfolio.tokens.push(tokens[i]);
            portfolio.balances.push(balances[i]);
        }
    }

    function rebalanceUserPortfolio() external {
        _rebalanceUserPortfolio(msg.sender);
    }
}
