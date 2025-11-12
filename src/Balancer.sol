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

    /*
     * Libraries
     */
    using SafeERC20 for IERC20Token;
    using PriceConverter for uint256;

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
    uint256 private immutable i_rebalanceThreshold;

    IUniswapV2Router02 private immutable i_router;

    AggregatorV3Interface private immutable i_priceFeed;

    uint8 private s_maxSupportedTokens;
    // user -> allocation preference
    mapping(address => AllocationPreference) private s_userToAllocationPreference;
    // token -> supported
    mapping(address => bool) private s_tokenToAllowed;
    // user -> their portfolio holdings
    mapping(address => UserPortfolio) private s_userToPortfolio;

    // Dynamic array of monitored users for rebalancing
    address[] private s_usersToMonitor;
    // Track if user is already in array for rebalancing
    mapping(address => bool) private s_isUserToMonitor;
    // Track user's position in array for rebalancing
    mapping(address => uint256) private s_userIndexToMonitor;

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

    /*
     * Constructor
     */
    constructor(
        address wethToken,
        address router,
        address priceFeed,
        uint256 rebalanceThreshold,
        uint8 maxSupportedTokens
    ) Ownable(msg.sender) {
        i_wethToken = wethToken;
        i_router = IUniswapV2Router02(router);
        i_priceFeed = AggregatorV3Interface(priceFeed);
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

        emit PortfolioUpdated(msg.sender, s_userToPortfolio[msg.sender]);
    }

    // Initially: s_usersToMonitor = []

    // Alice calls enableAutoRebalance():
    // s_usersToMonitor = [0xAlice]
    // s_userIndex[0xAlice] = 0
    // s_isMonitored[0xAlice] = true

    // Bob calls enableAutoRebalance():
    // s_usersToMonitor = [0xAlice, 0xBob]
    // s_userIndex[0xBob] = 1
    // s_isMonitored[0xBob] = true

    // Charlie calls enableAutoRebalance():
    // s_usersToMonitor = [0xAlice, 0xBob, 0xCharlie]
    // s_userIndex[0xCharlie] = 2
    // s_isMonitored[0xCharlie] = true
    /**
     * @notice Opt into automated portfolio rebalancing
     * @dev Adds msg.sender to the monitoring list if not already present
     */
    function enableAutoRebalance() external {
        if (!s_isMonitored[msg.sender]) {
            // Get current array length (will be the new index)
            s_userIndex[msg.sender] = s_usersToMonitor.length;

            // Add user to array
            s_usersToMonitor.push(msg.sender); // ← This is where array is set

            // Mark as monitored
            s_isMonitored[msg.sender] = true;

            emit AutoRebalanceEnabled(msg.sender);
        }
    }

    // Before: [Alice, Bob, Charlie, Dave]
    // Bob calls disableAutoRebalance() (index 1)

    // Step 1: Move Dave (last) to Bob's position
    // [Alice, Dave, Charlie, Dave]

    // Step 2: Update Dave's index mapping
    // s_userIndex[Dave] = 1

    // Step 3: Pop last element
    // [Alice, Dave, Charlie]

    // Final: [Alice, Dave, Charlie]
    /**
     * @notice Opt out of automated portfolio rebalancing
     * @dev Removes msg.sender from monitoring list using swap-and-pop
     */
    function disableAutoRebalance() external {
        if (s_isMonitored[msg.sender]) {
            uint256 index = s_userIndex[msg.sender];
            uint256 lastIndex = s_usersToMonitor.length - 1;

            // If not the last element, swap with last element
            if (index != lastIndex) {
                address lastUser = s_usersToMonitor[lastIndex];
                s_usersToMonitor[index] = lastUser; // Move last user to deleted spot
                s_userIndex[lastUser] = index; // Update moved user's index
            }

            // Remove last element
            s_usersToMonitor.pop();

            // Clean up mappings
            delete s_isMonitored[msg.sender];
            delete s_userIndex[msg.sender];

            emit AutoRebalanceDisabled(msg.sender);
        }
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
        uint256[] balances = portfolio.balances;

        if (portfolio.tokens.length == 0 || allocationPreference.allocations.length == 0) {
            return false;
        }

        // Calculate total portfolio value in USD
        uint256 totalPortfolioValueInUsd = 0;
        uint256[] tokenValuesInUsd = new uint256[](tokens.length);

        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == i_wethToken) {
                // WETH
                tokenBalancesInUsd[i] = balances[i].getConversionRate(i_priceFeed);
            } else {
                // USDC
                tokenBalancesInUsd[i] = balances[i];
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
     * @dev Rebalance a user's portfolio to match their target allocation
     */
    function _rebalanceUser(address user) internal {
        // Implementation: swap tokens to restore target allocation
        // This is where you'd implement the actual rebalancing logic
        emit PortfolioRebalanced(user);
    }

    function setMaxSupportedTokens(uint8 maxSupportedTokens) external onlyOwner {
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

    function isAllowedToken(address token) external view returns (bool) {
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

    function getUserAllocation(address user) external view returns (AllocationPreference memory) {
        return s_userToAllocationPreference[user];
    }

    function getUserPortfolio(address user) external view returns (UserPortfolio memory) {
        return s_userToPortfolio[user];
    }
}
