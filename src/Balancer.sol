// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

/*
 * @title Balancer
 * @author Rosario Borgesi
 * @notice This is an auto rebalancing portfolio
 */
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV2Router02} from "./interfaces/uniswap-v2/IUniswapV2Router02.sol";
import {IERC20Token} from "./interfaces/IERC20Token.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {PriceConverter} from "./PriceConverter.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {console2} from "forge-std/console2.sol";

contract Balancer is Ownable, ReentrancyGuard {
    /*
     * Errors
     */
    error Balancer__ExceededMaxSupportedTokens(uint256 investmentTokensLength, uint256 maxSupportedTokens);
    error Balancer__ArrayLengthMismatch(uint256 allocationsLength, uint256 investmentTokensLength);
    error Balancer__AllocationSetToZero();
    error Balancer__TokenNotSupported(address investmentToken);
    error Balancer__AllocationNotEqualTo100Percent(uint256 allocation);
    error Balancer__AllocationNotSet();
    error Balancer__ZeroAmount();
    error Balancer__InputNotWeth();
    error Balancer__MsgValueAmountMismatch(uint256 amount, uint256 msgValue);
    error Balancer__InvalidPortfolio();
    error Balancer__InvalidRebalanceThreshold(uint256 rebalanceThreshold);
    error Balancer__InvalidMaxSupportedTokens(uint256 maxSupportedTokens);

    /*
     * Libraries
     */
    using SafeERC20 for IERC20Token;
    using PriceConverter for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    /*
     * Type declarations
     */
    struct AllocationPreference {
        address[] investmentTokens; // must be supported
        uint256[] allocations; // must add up to 1e18 (representing 100%)
    }

    struct UserPortfolio {
        address[] tokens; // tokens the user currently holds
        uint256[] balances; // balance of each token
    }

    /*
     * State Variables
     */
    // Represents 100% for allocations
    uint256 private constant PERCENTAGE_FACTOR = 1e18;
    address private immutable i_wethToken;
    address private immutable i_usdcToken;
    uint256 private immutable i_rebalanceThreshold;

    IUniswapV2Router02 private immutable i_router;

    AggregatorV3Interface private immutable i_priceFeed;

    uint8 private s_maxSupportedTokens;
    // user -> allocation preference
    mapping(address => AllocationPreference) private s_userToAllocationPreference;
    // token -> supported
    mapping(address => bool) private s_tokenToAllowed;
    // user -> their portfolio holdings
    mapping(address => UserPortfolio) internal s_userToPortfolio;

    EnumerableSet.AddressSet private s_users;

    /*
     * Events
     */
    event AllocationSet(address indexed user, AllocationPreference allocation);
    event InvestmentTokenAdded(address indexed token);
    event InvestmentTokenRemoved(address indexed token);
    event Swap(
        address indexed user,
        address indexed inputToken,
        address indexed outputToken,
        uint256 amountIn,
        uint256 amountOut
    );
    event PortfolioUpdated(address indexed user, UserPortfolio portfolio);
    event UserAdded(address indexed user);
    event UserRemoved(address indexed user);

    /*
     * Constructor
     */
    constructor(
        address wethToken,
        address usdcToken,
        address router,
        address priceFeed,
        uint256 rebalanceThreshold,
        uint8 maxSupportedTokens
    ) Ownable(msg.sender) {
        i_wethToken = wethToken;
        i_usdcToken = usdcToken;
        i_router = IUniswapV2Router02(router);
        i_priceFeed = AggregatorV3Interface(priceFeed);

        if (rebalanceThreshold < 1 * 1e16 || rebalanceThreshold > 1 * 1e17) {
            // Rebalance threshold Min 1% Max 10%
            revert Balancer__InvalidRebalanceThreshold(rebalanceThreshold);
        }
        if (maxSupportedTokens != 2) {
            // Max 2 tokens
            revert Balancer__InvalidMaxSupportedTokens(maxSupportedTokens);
        }
        i_rebalanceThreshold = rebalanceThreshold;
        s_maxSupportedTokens = maxSupportedTokens;
    }

    /*
     * External functions
     */
    /*
     * @dev set the allocation preference for msg.sender
     * @param allocationPreference - the allocation preference for the user
     */
    function setUserAllocation(AllocationPreference calldata allocationPreference) external {
        uint256 allocationsLength = allocationPreference.allocations.length;
        uint256 investmentTokensLength = allocationPreference.investmentTokens.length;
        if (investmentTokensLength > s_maxSupportedTokens) {
            revert Balancer__ExceededMaxSupportedTokens(investmentTokensLength, s_maxSupportedTokens);
        }
        if (allocationsLength != investmentTokensLength) {
            revert Balancer__ArrayLengthMismatch(allocationsLength, investmentTokensLength);
        }
        uint256 total = 0;
        for (uint256 i = 0; i < investmentTokensLength; i++) {
            if (allocationPreference.allocations[i] == 0) {
                revert Balancer__AllocationSetToZero();
            }
            address investmentToken = allocationPreference.investmentTokens[i];
            if (!s_tokenToAllowed[investmentToken]) {
                revert Balancer__TokenNotSupported(investmentToken);
            }
            total += allocationPreference.allocations[i];
        }
        if (total != PERCENTAGE_FACTOR) {
            revert Balancer__AllocationNotEqualTo100Percent(total);
        }
        s_userToAllocationPreference[msg.sender] = allocationPreference;

        emit AllocationSet(msg.sender, allocationPreference);
    }

    /**
     * @notice Deposit an asset and automatically invest it based on your allocation preference
     * @dev Requires that the user's allocation preference is set via setUserAllocation()
     * @dev Supports two deposit methods:
     *      1. Native ETH: Send ETH with msg.value (contract wraps to WETH automatically)
     *      2. ERC20 tokens: Pre-approve this contract, then call with amount (msg.value = 0)
     * @param inputToken The token address to deposit. Use WETH address if depositing native ETH
     * @param amount The amount to deposit. Must equal msg.value if depositing ETH, otherwise the ERC20 amount
     * @dev The contract swaps the input token into your portfolio tokens according to your allocation
     * @dev Portfolio balances are tracked and can be withdrawn later
     */
    function deposit(address inputToken, uint256 amount) external payable nonReentrant {
        uint256 allocationsLength = s_userToAllocationPreference[msg.sender].allocations.length;
        if (allocationsLength == 0) {
            revert Balancer__AllocationNotSet();
        }
        if (!s_tokenToAllowed[inputToken]) {
            revert Balancer__TokenNotSupported(inputToken);
        }
        if (amount == 0 && msg.value == 0) {
            revert Balancer__ZeroAmount();
        }
        if (msg.value > 0) {
            if (inputToken != i_wethToken) {
                revert Balancer__InputNotWeth();
            }
            if (amount != msg.value) {
                revert Balancer__MsgValueAmountMismatch(amount, msg.value);
            }
            IERC20Token(inputToken).deposit{value: amount}();
        } else {
            IERC20Token(inputToken).safeTransferFrom(msg.sender, address(this), amount);
        }

        AllocationPreference memory pref = s_userToAllocationPreference[msg.sender];
        uint256 amountOutMin = 1;
        address[] memory path = new address[](2);
        path[0] = inputToken;

        for (uint256 i = 0; i < pref.investmentTokens.length; i++) {
            // Swaps either WETH -> USDC or USDC -> WETH according to the allocation preference
            path[1] = pref.investmentTokens[i];
            uint256 amountToSwap = (pref.allocations[i] * amount) / PERCENTAGE_FACTOR;

            if (pref.investmentTokens[i] == inputToken) {
                s_userToPortfolio[msg.sender].tokens.push(pref.investmentTokens[i]);
                s_userToPortfolio[msg.sender].balances.push(amountToSwap);
                continue;
            }

            uint256[] memory amounts = i_router.swapExactTokensForTokens({
                amountIn: amountToSwap,
                amountOutMin: amountOutMin,
                path: path,
                to: address(this),
                deadline: block.timestamp
            });

            s_userToPortfolio[msg.sender].tokens.push(pref.investmentTokens[i]);
            s_userToPortfolio[msg.sender].balances.push(amounts[1]);

            emit Swap(msg.sender, inputToken, pref.investmentTokens[i], amountToSwap, amounts[1]);
        }

        _addUser(msg.sender);

        emit PortfolioUpdated(msg.sender, s_userToPortfolio[msg.sender]);
    }

    function addUser() external {
        _addUser(msg.sender);
    }

    function _addUser(address _address) internal {
        if (s_users.contains(_address)) {
            return;
        }
        s_users.add(_address);
        emit UserAdded(_address);
    }

    function removeUser() external {
        _removeUser(msg.sender);
    }

    function _removeUser(address _address) internal {
        if (!s_users.contains(_address)) {
            return;
        }
        s_users.remove(_address);
        emit UserRemoved(_address);
    }

    function needsRebalancing() external view returns (bool) {
        return _needsRebalancing(msg.sender);
    }

    /**
     * @dev Check if a user's portfolio has drifted from target allocation
     * @param user The user to check
     * @return true if rebalancing is needed
     */
    function _needsRebalancing(address user) internal view returns (bool) {
        UserPortfolio memory portfolio = s_userToPortfolio[user];
        AllocationPreference memory allocationPreference = s_userToAllocationPreference[user];

        address[] memory tokens = portfolio.tokens;
        uint256[] memory balances = portfolio.balances;

        if (tokens.length == 0 || allocationPreference.allocations.length == 0) {
            return false;
        }

        // Calculate total portfolio value in USD
        uint256 totalPortfolioValueInUsd = 0;
        uint256[] memory tokenValuesUsd = new uint256[](tokens.length);
        uint256 totalValueUsd = 0;

        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == i_wethToken) {
                // WETH - convert to USD using price feed (returns 18 decimals)
                tokenValuesUsd[i] = balances[i].getConversionRate(i_priceFeed);
            } else if (tokens[i] == i_usdcToken) {
                // USDC
                tokenValuesUsd[i] = balances[i] * 1e12;
            } else {
                revert Balancer__TokenNotSupported(tokens[i]);
            }

            totalValueUsd += tokenValuesUsd[i];
        }

        if (totalValueUsd == 0) {
            return false;
        }

        // Check if any allocation drifted beyond threshold
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 currentAllocation = (tokenValuesUsd[i] * PERCENTAGE_FACTOR) / totalValueUsd;
            uint256 targetAllocation = allocationPreference.allocations[i];
            uint256 drift = currentAllocation > targetAllocation
                ? currentAllocation - targetAllocation
                : targetAllocation - currentAllocation;

            // If drift exceeds threshold (e.g., 5%), rebalance needed
            if (drift > i_rebalanceThreshold) {
                return true;
            }
        }

        return false;
    }

    /**
     * @notice Rebalances a user's portfolio to match their target allocation
     * @dev Swaps tokens to bring allocations within the rebalance threshold
     * @dev Only supports two-token portfolios (WETH and USDC) currently
     * @param user The address of the user whose portfolio should be rebalanced
     *
     * Requirements:
     * - User must have set an allocation preference
     * - User must have a valid portfolio with matching token/balance arrays
     * - Portfolio must contain exactly 2 tokens (WETH and USDC)
     * - Tokens must have sufficient balance for swaps
     * - Router must have approval to spend tokens
     *
     * Emits:
     * - {Swap} event for each token swap performed
     * - {PortfolioUpdated} event only if rebalancing occurred
     *
     * @custom:security This function assumes the router has unlimited approval
     * @custom:limitation Only works with WETH/USDC pairs currently
     */
    function _rebalanceUserPortfolio(address user) internal {
        AllocationPreference memory allocationPreference = s_userToAllocationPreference[user];

        if (allocationPreference.allocations.length == 0) {
            revert Balancer__AllocationNotSet();
        }

        UserPortfolio storage portfolio = s_userToPortfolio[user];

        if (
            portfolio.tokens.length == 0 || portfolio.balances.length == 0
                || allocationPreference.allocations.length != portfolio.tokens.length
                || allocationPreference.allocations.length != portfolio.balances.length
        ) {
            revert Balancer__InvalidPortfolio();
        }

        // Find token indices
        (uint256 wethTokenIndex, uint256 usdcTokenIndex) = _findTokenIndices(portfolio.tokens);

        // Calculate values - returns (tokenValuesUsd array, totalValueUsd)
        (uint256[] memory tokenValuesUsd, uint256 totalValueUsd) =
            _calculatePortfolioValue(portfolio.tokens, portfolio.balances);

        if (totalValueUsd == 0) return;

        bool rebalanced = _executeRebalancing(
            user,
            portfolio,
            allocationPreference.allocations,
            tokenValuesUsd,
            totalValueUsd,
            wethTokenIndex,
            usdcTokenIndex
        );

        if (rebalanced) {
            emit PortfolioUpdated(user, portfolio);
        }
    }

    // Helper function to find token indices
    function _findTokenIndices(address[] memory tokens) private view returns (uint256 wethIndex, uint256 usdcIndex) {
        wethIndex = type(uint256).max;
        usdcIndex = type(uint256).max;

        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == i_wethToken) wethIndex = i;
            else if (tokens[i] == i_usdcToken) usdcIndex = i;
        }

        if (wethIndex == type(uint256).max || usdcIndex == type(uint256).max) {
            revert Balancer__InvalidPortfolio();
        }
    }

    // Helper function to calculate portfolio value
    function _calculatePortfolioValue(address[] memory tokens, uint256[] memory balances)
        private
        view
        returns (uint256[] memory tokenValuesUsd, uint256 totalValueUsd)
    {
        tokenValuesUsd = new uint256[](tokens.length);

        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == i_wethToken) {
                tokenValuesUsd[i] = balances[i].getConversionRate(i_priceFeed);
            } else if (tokens[i] == i_usdcToken) {
                tokenValuesUsd[i] = balances[i] * 1e12;
            } else {
                revert Balancer__TokenNotSupported(tokens[i]);
            }
            totalValueUsd += tokenValuesUsd[i];
        }
    }

    // Helper function to execute the actual rebalancing
    function _executeRebalancing(
        address user,
        UserPortfolio storage portfolio,
        uint256[] memory allocations,
        uint256[] memory tokenValuesUsd,
        uint256 totalValueUsd,
        uint256 wethTokenIndex,
        uint256 usdcTokenIndex
    ) private returns (bool rebalanced) {
        for (uint256 i = 0; i < portfolio.tokens.length; i++) {
            uint256 currentAllocation = (tokenValuesUsd[i] * PERCENTAGE_FACTOR) / totalValueUsd;
            uint256 targetAllocation = allocations[i];
            // calculate 5 % of the target allocation
            uint256 fivePercentOfTargetAllocation = (targetAllocation * i_rebalanceThreshold) / PERCENTAGE_FACTOR;
            if (currentAllocation <= (targetAllocation + fivePercentOfTargetAllocation)) {
                continue;
            }

            uint256 excessValueUsd = tokenValuesUsd[i] - ((targetAllocation * totalValueUsd) / PERCENTAGE_FACTOR);

            if (portfolio.tokens[i] == i_wethToken) {
                _swapWethToUsdc(user, portfolio, excessValueUsd, wethTokenIndex, usdcTokenIndex);
                rebalanced = true;
            } else if (portfolio.tokens[i] == i_usdcToken) {
                _swapUsdcToWeth(user, portfolio, excessValueUsd, wethTokenIndex, usdcTokenIndex);
                rebalanced = true;
            }
        }
    }

    // Helper for WETH -> USDC swap
    function _swapWethToUsdc(
        address user,
        UserPortfolio storage portfolio,
        uint256 excessValueUsd,
        uint256 wethIndex,
        uint256 usdcIndex
    ) private {
        uint256 ethPriceUsd = PriceConverter.getPrice(i_priceFeed);
        uint256 amountToSwap = (excessValueUsd * 1e18) / ethPriceUsd;

        address[] memory path = new address[](2);
        path[0] = i_wethToken;
        path[1] = i_usdcToken;

        uint256[] memory amounts = i_router.swapExactTokensForTokens({
            amountIn: amountToSwap,
            amountOutMin: 1,
            path: path,
            to: address(this),
            deadline: block.timestamp
        });

        portfolio.balances[wethIndex] -= amounts[0];
        portfolio.balances[usdcIndex] += amounts[1];

        emit Swap(user, i_wethToken, i_usdcToken, amounts[0], amounts[1]);
    }

    // Helper for USDC -> WETH swap
    function _swapUsdcToWeth(
        address user,
        UserPortfolio storage portfolio,
        uint256 excessValueUsd,
        uint256 wethIndex,
        uint256 usdcIndex
    ) private {
        uint256 amountToSwap = excessValueUsd / 1e12;

        address[] memory path = new address[](2);
        path[0] = i_usdcToken;
        path[1] = i_wethToken;

        uint256[] memory amounts = i_router.swapExactTokensForTokens({
            amountIn: amountToSwap,
            amountOutMin: 1,
            path: path,
            to: address(this),
            deadline: block.timestamp
        });

        portfolio.balances[usdcIndex] -= amounts[0];
        portfolio.balances[wethIndex] += amounts[1];

        emit Swap(user, i_usdcToken, i_wethToken, amounts[0], amounts[1]);
    }

    function setMaxSupportedTokens(uint8 maxSupportedTokens) external onlyOwner {
        if (maxSupportedTokens != 2) {
            revert Balancer__InvalidMaxSupportedTokens(maxSupportedTokens);
        }
        s_maxSupportedTokens = maxSupportedTokens;
    }

    function addAllowedToken(address token) external onlyOwner {
        s_tokenToAllowed[token] = true;
        IERC20Token(token).safeIncreaseAllowance(address(i_router), type(uint256).max);

        emit InvestmentTokenAdded(token);
    }

    function removeAllowedToken(address token) external onlyOwner {
        s_tokenToAllowed[token] = false;
        IERC20Token(token).safeDecreaseAllowance(address(i_router), type(uint256).max);
        emit InvestmentTokenRemoved(token);
    }

    /*
     * View and pure functions
     */
    function getPercentageFactor() external pure returns (uint256) {
        return PERCENTAGE_FACTOR;
    }

    function getTokenToAllowed(address token) external view returns (bool) {
        return s_tokenToAllowed[token];
    }

    function getMaxSupportedTokens() external view returns (uint8) {
        return s_maxSupportedTokens;
    }

    function getRouterAddress() external view returns (address) {
        return address(i_router);
    }

    function getWethTokenAddress() external view returns (address) {
        return i_wethToken;
    }

    function getUserToAllocationPreference(address user) external view returns (AllocationPreference memory) {
        return s_userToAllocationPreference[user];
    }

    function getUserToPortfolio(address user) external view returns (UserPortfolio memory) {
        return s_userToPortfolio[user];
    }

    function getUserAtIndex(uint256 index) external view returns (address) {
        return s_users.at(index);
    }

    function isUser(address _address) external view returns (bool) {
        return s_users.contains(_address);
    }

    function getUsersLength() external view returns (uint256) {
        return s_users.length();
    }
}
