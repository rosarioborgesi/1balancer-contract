// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

library PriceConverter {
    /**
     * @notice Gets the current ETH/USD price from a Chainlink price feed
     * @dev Fetches the latest price data and converts from 8 decimals to 18 decimals
     * For example: if 1 ETH is 3000 USD, then it returns 3000e18 (3000 USD)
     * @param priceFeed The Chainlink AggregatorV3Interface price feed contract
     * @return The current ETH/USD price with 18 decimals of precision
     */
    function getPrice(AggregatorV3Interface priceFeed) internal view returns (uint256) {
        (, int256 answer,,,) = priceFeed.latestRoundData(); // answer is ETH/USD rate with 8 decimals. For example if 1 ETH is 3000 USD answer is 3000e8
        return uint256(answer * 1e10); // ETH/USD rate in 18 decimals. So answer becames 3000e18 (3000 USD)
    }

    /**
     * @notice Converts an ETH amount to its USD equivalent value
     * @dev Multiplies the ETH amount by the current ETH/USD price and adjusts for decimals
     * For example: if 1 ETH = $3000, then input of 1e18 returns 3000e18
     * @param ethAmount The amount of ETH to convert (in wei, 18 decimals)
     * @param priceFeed The Chainlink AggregatorV3Interface price feed contract
     * @return The USD value of the ETH amount with 18 decimals of precision
     */
    function getConversionRate(uint256 ethAmount, AggregatorV3Interface priceFeed) internal view returns (uint256) {
        uint256 ethPrice = getPrice(priceFeed);
        uint256 ethAmountInUsd = (ethPrice * ethAmount) / 1e18;
        // the actual ETH/USD conversion rate, after adjusting the extra 0s.
        return ethAmountInUsd;
    }
}
