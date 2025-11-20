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
    error Balancer__InvalidPortfolio(address user);
    error Balancer__InvalidRebalanceThreshold(uint256 rebalanceThreshold);
    error Balancer__InvalidMaxSupportedTokens(uint256 maxSupportedTokens);
    error Balancer__UpkeepNotNeeded();
    error Balancer__UserNotAdded(address user);
    /**
     * Libraries
     */

    using SafeERC20 for IERC20Token;
    using PriceConverter for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;

    /**
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

    /**
     * State Variables
     */
    // Represents 100% for allocations
    uint256 private constant PERCENTAGE_FACTOR = 1e18;
    address private immutable i_wethToken;
    address private immutable i_usdcToken;
    uint256 private immutable i_rebalanceThreshold;
    uint256 private immutable i_rebalanceInterval; // Rebalancing interval in seconds
    uint256 private s_lastTimeStamp;

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

    /**
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
    event UpkeepPerformed(uint256 blockTimestamp);
    event Withdrawal(address indexed user);

    /**
     * Constructor
     */
    constructor(
        address wethToken,
        address usdcToken,
        address router,
        address priceFeed,
        uint256 rebalanceThreshold,
        uint8 maxSupportedTokens,
        uint256 rebalanceInterval
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
        s_lastTimeStamp = block.timestamp;
        i_rebalanceInterval = rebalanceInterval;
    }

    /**
     * External functions
     */

    /**
     * @notice Executes portfolio rebalancing for all users that need it
     * @dev Part of Chainlink Automation interface - called by Chainlink nodes when upkeep is needed
     * @dev Only executes if checkUpkeep returns true (time passed + users need rebalancing)
     * @dev Loops through all registered users and rebalances portfolios that exceed threshold
     * @dev performData parameter is not used in current implementation
     * 
     * Requirements:
     * - checkUpkeep must return true
     * - Sufficient time must have passed since last upkeep (i_rebalanceInterval)
     * - At least one user must need rebalancing
     * 
     * Effects:
     * - Updates s_lastTimeStamp to current block timestamp
     * - Rebalances all portfolios that need it via _rebalanceUserPortfolio
     * 
     * Emits:
     * - {UpkeepPerformed} event with current timestamp
     * - {Swap} events for each rebalancing swap (from _rebalanceUserPortfolio)
     * - {PortfolioUpdated} events for each rebalanced portfolio
     * 
     * @custom:chainlink Called by Chainlink Automation network
     * @custom:security Reverts if upkeep is not needed (prevents unauthorized calls)
     */
    function performUpkeep(bytes calldata /*performData*/ ) external {
        (bool upkeepNeeded,) = checkUpkeep("");
        if (!upkeepNeeded) {
            revert Balancer__UpkeepNotNeeded();
        }

        s_lastTimeStamp = block.timestamp;

        for (uint256 i = 0; i < s_users.length(); i++) {
            address user = s_users.at(i);

            if (_needsRebalancing(user)) {
                _rebalanceUserPortfolio(user);
            }
        }

        emit UpkeepPerformed(block.timestamp);
    }

    /**
     * @notice Sets or updates the caller's target allocation preferences for their portfolio
     * @dev Must be called before making any deposits. Can be updated at any time.
     * @dev Validates that allocations sum to exactly 100% and all tokens are supported
     *
     * @param allocationPreference Struct containing:
     *        - investmentTokens: Array of token addresses to invest in
     *        - allocations: Array of target percentages (must sum to 1e18 = 100%)
     *
     * Requirements:
     * - Number of tokens must not exceed s_maxSupportedTokens
     * - investmentTokens and allocations arrays must have equal length
     * - No allocation can be zero
     * - All tokens must be in the allowed tokens list (added by owner)
     * - Allocations must sum to exactly PERCENTAGE_FACTOR (1e18 = 100%)
     *
     * Example:
     * ```
     * AllocationPreference({
     *     investmentTokens: [WETH_ADDRESS, USDC_ADDRESS],
     *     allocations: [5e17, 5e17]  // 50% WETH, 50% USDC
     * })
     * ```
     *
     * Effects:
     * - Overwrites any previous allocation preference for the caller
     * - Does NOT automatically rebalance existing portfolio (call deposit/rebalance separately)
     * - Future deposits will follow this new allocation
     *
     * Emits:
     * - {AllocationSet} event with user address and new allocation preference
     *
     * @custom:validation Performs comprehensive validation before accepting allocation
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

        _addUser(msg.sender);

        emit AllocationSet(msg.sender, allocationPreference);
        
    }

    /**
     * @notice Deposit tokens and automatically invest them according to your allocation preference
     * @dev Requires allocation preference to be set via setUserAllocation() before depositing
     * @dev Tokens are deposited then automatically rebalanced to match target allocation
     *
     * Supported Deposit Methods:
     * 1. Native ETH: Send ETH via msg.value (automatically wrapped to WETH)
     *    - Set inputToken to WETH address
     *    - Set amount equal to msg.value
     * 2. WETH (ERC20): Pre-approve this contract, call with msg.value = 0
     * 3. USDC (ERC20): Pre-approve this contract, call with msg.value = 0
     *
     * @param inputToken The token to deposit (must be WETH or USDC address)
     * @param amount The amount to deposit (in token's native decimals)
     *
     * Process Flow:
     * 1. Receives tokens from user (wraps ETH to WETH if needed)
     * 2. Adds deposited amount to portfolio
     * 3. Automatically rebalances portfolio to match target allocation
     *
     * Example:
     * - User has 50/50 WETH/USDC allocation
     * - Deposits 1 WETH
     * - Contract adds 1 WETH to portfolio (now unbalanced)
     * - Rebalancing swaps ~0.5 WETH → USDC
     * - Final portfolio: ~0.5 WETH + ~$1500 USDC
     *
     * Requirements:
     * - User must have set allocation preference
     * - inputToken must be in allowed tokens list
     * - For ETH deposits: inputToken must be WETH and amount must equal msg.value
     * - For ERC20 deposits: Must have approved this contract to spend inputToken
     *
     * Emits:
     * - {Swap} events from rebalancing (if swaps occur)
     * - {PortfolioUpdated} with final portfolio state
     *
     * @custom:security Uses nonReentrant to prevent reentrancy attacks
     */
    function deposit(address inputToken, uint256 amount) external payable nonReentrant {
        // Validation checks
        if (s_userToAllocationPreference[msg.sender].allocations.length == 0) {
            revert Balancer__AllocationNotSet();
        }
        if (!s_users.contains(msg.sender)) {
            revert Balancer__UserNotAdded(msg.sender);
        }
        if (!s_tokenToAllowed[inputToken]) {
            revert Balancer__TokenNotSupported(inputToken);
        }
        if (amount == 0 && msg.value == 0) {
            revert Balancer__ZeroAmount();
        }

        // Handle ETH vs ERC20 deposits
        if (msg.value > 0) {
            if (inputToken != i_wethToken) {
                revert Balancer__InputNotWeth();
            }
            if (amount != msg.value) {
                revert Balancer__MsgValueAmountMismatch(amount, msg.value);
            }
            // Wrap ETH to WETH
            IWETH(inputToken).deposit{value: amount}();
        } else {
            // Transfer ERC20 from user
            IERC20Token(inputToken).safeTransferFrom(msg.sender, address(this), amount);
        }

        // Add deposited tokens to portfolio
        _addToPortfolio(msg.sender, inputToken, amount);

        // Rebalance portfolio to match target allocation
        _rebalanceUserPortfolio(msg.sender);
    }

    /**
     * @notice Withdraws all tokens from the caller's portfolio and transfers them back to the caller
     * @dev Follows CEI pattern: validates, deletes storage, then transfers tokens
     * @dev Removes user from tracking but keeps their allocation preference for future deposits
     * 
     * Requirements:
     * - Caller must be a registered user
     * - Portfolio must have at least one token with non-zero balance
     * 
     * Process:
     * 1. Validates user is registered and has a valid portfolio
     * 2. Checks that at least one token has a non-zero balance
     * 3. Deletes portfolio from storage and removes user from tracking
     * 4. Transfers all token balances to the caller
     * 
     * Effects:
     * - All token balances transferred to caller
     * - Portfolio completely deleted from storage
     * - User removed from s_users tracking set
     * - Allocation preference remains (can deposit again with same allocation)
     * 
     * Emits:
     * - {Withdrawal} event with user address
     * 
     * @custom:security Uses nonReentrant modifier and follows CEI pattern
     * @custom:note User's allocation preference is NOT deleted
     */
    function withdraw() external nonReentrant {
        if (!s_users.contains(msg.sender)) {
            revert Balancer__UserNotAdded(msg.sender);
        }

        UserPortfolio memory portfolio = s_userToPortfolio[msg.sender];

        if (portfolio.tokens.length == 0 || portfolio.balances.length == 0) {
            revert Balancer__InvalidPortfolio(msg.sender);
        }

        // Check if all balances are zero
        bool hasBalance = false;
        for (uint256 i = 0; i < portfolio.balances.length; i++) {
            if (portfolio.balances[i] > 0) {
                hasBalance = true;
                break;
            }
        }

        if (!hasBalance) {
            revert Balancer__InvalidPortfolio(msg.sender);
        }

        delete s_userToPortfolio[msg.sender];
        _removeUser(msg.sender);

        for (uint256 i = 0; i < portfolio.tokens.length; i++) {
            if (portfolio.balances[i] == 0) {
                continue;
            }
            IERC20Token(portfolio.tokens[i]).safeTransfer(msg.sender, portfolio.balances[i]);
        }

        emit Withdrawal(msg.sender);
    }

    /**
     * @notice Manually adds the caller to the users tracking set
     * @dev Users are automatically added when setting allocation or making deposits
     * @dev This function allows manual addition if needed for any reason
     * 
     * Effects:
     * - Adds caller to s_users EnumerableSet
     * - Does nothing if user is already in the set
     * 
     * Emits:
     * - {UserAdded} event if user was not already in the set
     */
    function addUser() external {
        _addUser(msg.sender);
    }

    /**
     * @notice Manually removes the caller from the users tracking set
     * @dev Does not affect portfolio or allocation preference
     * @dev User can still deposit/withdraw even after removal
     * 
     * Effects:
     * - Removes caller from s_users EnumerableSet
     * - Does nothing if user is not in the set
     * 
     * Emits:
     * - {UserRemoved} event if user was in the set
     */
    function removeUser() external {
        _removeUser(msg.sender);
    }

    /**
     * @notice Sets the maximum number of tokens supported per user allocation
     * @dev Only callable by contract owner
     * @dev Currently restricted to exactly 2 tokens (WETH and USDC)
     * 
     * @param maxSupportedTokens The new maximum (must be 2)
     * 
     * Requirements:
     * - Caller must be contract owner
     * - maxSupportedTokens must equal 2
     * 
     * Effects:
     * - Updates s_maxSupportedTokens
     * 
     * @custom:limitation Currently hardcoded to only accept 2 tokens
     */
    function setMaxSupportedTokens(uint8 maxSupportedTokens) external onlyOwner {
        if (maxSupportedTokens != 2) {
            revert Balancer__InvalidMaxSupportedTokens(maxSupportedTokens);
        }
        s_maxSupportedTokens = maxSupportedTokens;
    }

    /**
     * @notice Adds a token to the list of allowed investment tokens
     * @dev Only callable by contract owner
     * @dev Automatically approves the Uniswap router to spend this token (unlimited approval)
     * 
     * @param token The ERC20 token address to allow
     * 
     * Requirements:
     * - Caller must be contract owner
     * - Token must be a valid ERC20 contract
     * 
     * Effects:
     * - Sets s_tokenToAllowed[token] to true
     * - Approves router to spend unlimited amount of this token
     * 
     * Emits:
     * - {InvestmentTokenAdded} event with token address
     * 
     * @custom:security Unlimited approval given to router - ensure router is trusted
     */
    function addAllowedToken(address token) external onlyOwner {
        s_tokenToAllowed[token] = true;
        IERC20Token(token).safeIncreaseAllowance(address(i_router), type(uint256).max);

        emit InvestmentTokenAdded(token);
    }

    /**
     * @notice Removes a token from the list of allowed investment tokens
     * @dev Only callable by contract owner
     * @dev Removes the router's approval to spend this token
     * 
     * @param token The ERC20 token address to disallow
     * 
     * Requirements:
     * - Caller must be contract owner
     * 
     * Effects:
     * - Sets s_tokenToAllowed[token] to false
     * - Removes router's approval to spend this token
     * 
     * Emits:
     * - {InvestmentTokenRemoved} event with token address
     * 
     * @custom:warning Existing user portfolios with this token will not be affected
     */
    function removeAllowedToken(address token) external onlyOwner {
        s_tokenToAllowed[token] = false;
        IERC20Token(token).safeDecreaseAllowance(address(i_router), type(uint256).max);
        emit InvestmentTokenRemoved(token);
    }

    /**
     * @notice Checks if the caller's portfolio needs rebalancing
     * @dev Wrapper around _needsRebalancing for external access
     * @dev Compares current allocation against target allocation and threshold
     * 
     * @return True if the caller's portfolio drift exceeds the rebalance threshold, false otherwise
     * 
     * Example Usage:
     * - User can call this before manually triggering a rebalance
     * - Frontend can display rebalancing status to users
     * 
     * @custom:view This is a view function and does not modify state
     */
    function needsRebalancing() external view returns (bool) {
        return _needsRebalancing(msg.sender);
    }

    /**
     * public
     */

    /**
     * @notice Checks if any user's portfolio needs rebalancing
     * @dev Part of Chainlink Automation interface - called by Chainlink nodes
     * @dev Loops through all users and checks if any need rebalancing
     * @dev Returns true on first user found that needs rebalancing (gas efficient)
     *
     *
     * @return upkeepNeeded True if at least one user needs rebalancing, false otherwise
     * @return performData Additional data to pass to performUpkeep (not used currently)
     *
     * @custom:chainlink This function is called off-chain by Chainlink nodes
     */
    function checkUpkeep(bytes memory /* checkData */ )
        public
        view
        returns (bool upkeepNeeded, bytes memory /* performData */ )
    {
        bool timeHasPassed = ((block.timestamp - s_lastTimeStamp) >= i_rebalanceInterval);

        console2.log("Time has passed:", timeHasPassed);
        console2.log("Block timestamp:", block.timestamp);
        console2.log("Last time stamp:", s_lastTimeStamp);
        console2.log("Rebalance interval:", i_rebalanceInterval);

        if (!timeHasPassed) {
            return (false, "");
        }

        bool hasUsersToRebalance = false;
        for (uint256 i = 0; i < s_users.length(); i++) {
            address user = s_users.at(i);
            console2.log("User:", user);
            if (_needsRebalancing(user)) {
                hasUsersToRebalance = true;
                break;
            }
        }
        return (hasUsersToRebalance, "");
    }

    /**
     * internal
     */

    /**
     * @notice Checks if a user's portfolio allocation has drifted beyond the rebalance threshold
     * @dev Compares current token allocations (as % of total portfolio value) against target allocations
     * @dev Returns true if ANY token's allocation drift exceeds the threshold percentage
     *
     * @param user The address of the user whose portfolio to check
     * @return needsRebalance True if rebalancing is needed, false otherwise
     *
     * Calculation Logic:
     * 1. Converts all token balances to USD value (18 decimals)
     * 2. Calculates total portfolio value
     * 3. For each token, calculates current allocation % = (tokenValue / totalValue) * 1e18
     * 4. Compares current % vs target % - if difference > threshold, needs rebalancing
     *
     * Example:
     * - Total portfolio: $6000 (3000 WETH + 3000 USDC)
     * - Target: 50% WETH, 50% USDC
     * - Current: 80% WETH ($4800), 20% USDC ($1200)
     * - Drift: 30% for both tokens
     * - If threshold is 5% (5e16), returns true
     *
     * @custom:security Uses Chainlink price feed for WETH valuation
     * @custom:assumption Assumes USDC is pegged 1:1 with USD
     */
    function _needsRebalancing(address user) internal view returns (bool) {
        UserPortfolio memory portfolio = s_userToPortfolio[user];
        AllocationPreference memory allocationPreference = s_userToAllocationPreference[user];

        address[] memory tokens = portfolio.tokens;
        uint256[] memory balances = portfolio.balances;

        if (allocationPreference.allocations.length == 0) {
            revert Balancer__AllocationNotSet();
        }

        if (tokens.length == 0) {
            revert Balancer__InvalidPortfolio(user);
        }

        // Calculate token values and total portfolio value
        (uint256[] memory tokenValuesUsd, uint256 totalValueUsd) =
            _calculatePortfolioValue(portfolio.tokens, portfolio.balances);

        if (totalValueUsd == 0) {
            return false;
        }

        // Check if any token's allocation has drifted beyond threshold
        for (uint256 i = 0; i < portfolio.tokens.length; i++) {
            // Calculate current allocation as percentage (with 18 decimals)
            uint256 currentAllocation = (tokenValuesUsd[i] * PERCENTAGE_FACTOR) / totalValueUsd;
            uint256 targetAllocation = allocationPreference.allocations[i];

            // Calculate absolute drift
            uint256 drift = currentAllocation > targetAllocation
                ? currentAllocation - targetAllocation
                : targetAllocation - currentAllocation;

            // Return immediately if any token exceeds threshold
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
            revert Balancer__InvalidPortfolio(user);
        }

        // Find token indices
        (uint256 wethTokenIndex, uint256 usdcTokenIndex) = _findTokenIndices(portfolio.tokens, user);

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

    /**
     * private
     */

    /**
     * @dev Adds deposited tokens to user's portfolio
     * @dev Creates portfolio if first deposit, otherwise updates existing balance
     * @param user The user making the deposit
     * @param token The token being deposited
     * @param amount The amount to add
     */
    function _addToPortfolio(address user, address token, uint256 amount) private {
        UserPortfolio storage portfolio = s_userToPortfolio[user];

        // Check if portfolio is empty (first deposit)
        if (portfolio.tokens.length == 0) {
            // Initialize portfolio with all tokens from allocation preference
            AllocationPreference memory pref = s_userToAllocationPreference[user];

            for (uint256 i = 0; i < pref.investmentTokens.length; i++) {
                portfolio.tokens.push(pref.investmentTokens[i]);
                // Set balance to amount if it's the deposit token, otherwise 0
                if (pref.investmentTokens[i] == token) {
                    portfolio.balances.push(amount);
                } else {
                    portfolio.balances.push(0);
                }
            }
        } else {
            // Find token index and update balance
            uint256 tokenIndex = _findTokenIndex(portfolio.tokens, token);
            portfolio.balances[tokenIndex] += amount;
        }
    }

    /**
     * @dev Internal function to add a user to the users tracking set
     * @dev Does nothing if user is already in the set (idempotent)
     * 
     * @param _address The address to add
     * 
     * Effects:
     * - Adds address to s_users EnumerableSet if not already present
     * 
     * Emits:
     * - {UserAdded} event only if user was not already in the set
     */
    function _addUser(address _address) private {
        if (s_users.contains(_address)) {
            return;
        }
        s_users.add(_address);
        emit UserAdded(_address);
    }

    /**
     * @dev Internal function to remove a user from the users tracking set
     * @dev Does nothing if user is not in the set (idempotent)
     * 
     * @param _address The address to remove
     * 
     * Effects:
     * - Removes address from s_users EnumerableSet if present
     * 
     * Emits:
     * - {UserRemoved} event only if user was in the set
     * 
     * @custom:note Does not affect user's portfolio or allocation preference
     */
    function _removeUser(address _address) private {
        if (!s_users.contains(_address)) {
            return;
        }
        s_users.remove(_address);
        emit UserRemoved(_address);
    }

    /**
     * @dev Executes token swaps to rebalance portfolio towards target allocations
     * @dev Only swaps tokens that exceed their target allocation + threshold
     * @dev Skips tokens that are within acceptable range (target ± threshold)
     *
     * @param user The address of the user whose portfolio is being rebalanced
     * @param portfolio Storage reference to the user's portfolio (updated in place)
     * @param allocations Array of target allocation percentages (18 decimals, sums to 1e18)
     * @param tokenValuesUsd Array of current token values in USD (18 decimals)
     * @param totalValueUsd Total portfolio value in USD (18 decimals)
     * @param wethTokenIndex Index of WETH in the portfolio arrays
     * @param usdcTokenIndex Index of USDC in the portfolio arrays
     *
     * @return rebalanced True if any swaps were executed, false otherwise
     *
     * Logic:
     * 1. For each token, calculate current allocation % = (tokenValue / totalValue) * 1e18
     * 2. Check if current allocation exceeds (target + threshold)
     * 3. If yes, calculate excess USD value and swap to other token
     * 4. Portfolio balances are updated in storage via _executeSwap
     *
     * Example:
     * - Target: 50% WETH (5e17), threshold: 5% (5e16)
     * - Current: 60% WETH (6e17)
     * - Acceptable range: 45% - 55% (target ± threshold)
     * - 60% > 55%, so rebalancing needed
     * - Excess: 10% of portfolio value swapped WETH → USDC
     *
     * @custom:note Uses i_rebalanceThreshold as the acceptable drift percentage
     */
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

            // If the current allocation is within the rebalance threshold, skip the swap
            uint256 rebalanceThresholdAllocation = (targetAllocation * i_rebalanceThreshold) / PERCENTAGE_FACTOR;
            if (currentAllocation <= (targetAllocation + rebalanceThresholdAllocation)) {
                continue;
            }

            uint256 excessValueUsd = tokenValuesUsd[i] - ((targetAllocation * totalValueUsd) / PERCENTAGE_FACTOR);

            if (portfolio.tokens[i] == i_wethToken) {
                // Swap WETH -> USDC
                _executeSwap(user, portfolio, excessValueUsd, i_wethToken, i_usdcToken, wethTokenIndex, usdcTokenIndex);
                rebalanced = true;
            } else if (portfolio.tokens[i] == i_usdcToken) {
                // Swap USDC -> WETH
                _executeSwap(user, portfolio, excessValueUsd, i_usdcToken, i_wethToken, usdcTokenIndex, wethTokenIndex);
                rebalanced = true;
            }
        }
    }

    /**
     * @dev Swaps tokens to rebalance portfolio
     * @param user The user whose portfolio is being rebalanced
     * @param portfolio Storage reference to the user's portfolio
     * @param excessValueUsd The USD value (18 decimals) that needs to be swapped
     * @param fromToken The token to swap from
     * @param toToken The token to swap to
     * @param fromIndex The index of fromToken in the portfolio
     * @param toIndex The index of toToken in the portfolio
     */
    function _executeSwap(
        address user,
        UserPortfolio storage portfolio,
        uint256 excessValueUsd,
        address fromToken,
        address toToken,
        uint256 fromIndex,
        uint256 toIndex
    ) private {
        // Calculate amount to swap based on the from token
        uint256 amountToSwap;

        if (fromToken == i_wethToken) {
            // WETH -> USDC: Convert USD value to WETH amount
            uint256 ethPriceUsd = PriceConverter.getPrice(i_priceFeed);
            amountToSwap = (excessValueUsd * 1e18) / ethPriceUsd;
        } else if (fromToken == i_usdcToken) {
            // USDC -> WETH: Convert from 18 decimals to 6 decimals
            amountToSwap = excessValueUsd / 1e12;
        } else {
            revert Balancer__TokenNotSupported(fromToken);
        }

        // Set up swap path
        address[] memory path = new address[](2);
        path[0] = fromToken;
        path[1] = toToken;

        // Execute swap
        uint256[] memory amounts = i_router.swapExactTokensForTokens({
            amountIn: amountToSwap,
            amountOutMin: 1,
            path: path,
            to: address(this),
            deadline: block.timestamp
        });

        // Update balances
        portfolio.balances[fromIndex] -= amounts[0];
        portfolio.balances[toIndex] += amounts[1];

        emit Swap(user, fromToken, toToken, amounts[0], amounts[1]);
    }

    /**
     * @dev Finds the index of a token in the tokens array
     * @param tokens Array of token addresses
     * @param token Token to find
     * @return index The index of the token (reverts if not found)
     */
    function _findTokenIndex(address[] memory tokens, address token) private pure returns (uint256 index) {
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == token) {
                return i;
            }
        }
        revert Balancer__TokenNotSupported(token);
    }

    /**
     * @dev Helper function to calculate USD value of all tokens in a portfolio
     * @param tokens Array of token addresses
     * @param balances Array of token balances (in token's native decimals)
     * @return tokenValuesUsd Array of token values in USD (18 decimals)
     * @return totalValueUsd Sum of all token values in USD (18 decimals)
     */
    function _calculatePortfolioValue(address[] memory tokens, uint256[] memory balances)
        private
        view
        returns (uint256[] memory tokenValuesUsd, uint256 totalValueUsd)
    {
        tokenValuesUsd = new uint256[](tokens.length);

        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == i_wethToken) {
                // WETH: Convert to USD using Chainlink price feed (returns 18 decimals)
                tokenValuesUsd[i] = balances[i].getConversionRate(i_priceFeed);
            } else if (tokens[i] == i_usdcToken) {
                // USDC: Normalize from 6 decimals to 18 decimals (assume 1 USDC = 1 USD)
                tokenValuesUsd[i] = balances[i] * 1e12;
            } else {
                // Unsupported token
                revert Balancer__TokenNotSupported(tokens[i]);
            }

            totalValueUsd += tokenValuesUsd[i];
        }
    }

    /**
     * @dev Finds the indices of WETH and USDC tokens in a portfolio
     * @dev Reverts if either token is not found
     * 
     * @param tokens Array of token addresses from portfolio
     * @param user The user address (used for error messages)
     * @return wethIndex The index of WETH in the tokens array
     * @return usdcIndex The index of USDC in the tokens array
     * 
     * Requirements:
     * - Both i_wethToken and i_usdcToken must be present in the tokens array
     * 
     * @custom:revert Balancer__InvalidPortfolio if either token is not found
     */
    function _findTokenIndices(address[] memory tokens, address user) private view returns (uint256 wethIndex, uint256 usdcIndex) {
        wethIndex = type(uint256).max;
        usdcIndex = type(uint256).max;

        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == i_wethToken) wethIndex = i;
            else if (tokens[i] == i_usdcToken) usdcIndex = i;
        }

        if (wethIndex == type(uint256).max || usdcIndex == type(uint256).max) {
            revert Balancer__InvalidPortfolio(user);
        }
    }

    /**
     * View and pure functions
     */
    
    /**
     * @notice Returns the percentage factor used for allocation calculations
     * @dev This constant represents 100% = 1e18
     * @return The percentage factor (1e18)
     */
    function getPercentageFactor() external pure returns (uint256) {
        return PERCENTAGE_FACTOR;
    }

    /**
     * @notice Checks if a token is in the allowed investment tokens list
     * @param token The token address to check
     * @return True if the token is allowed, false otherwise
     */
    function getTokenToAllowed(address token) external view returns (bool) {
        return s_tokenToAllowed[token];
    }

    /**
     * @notice Returns the maximum number of tokens supported per user allocation
     * @return The maximum supported tokens (currently 2)
     */
    function getMaxSupportedTokens() external view returns (uint8) {
        return s_maxSupportedTokens;
    }

    /**
     * @notice Returns the Uniswap V2 Router address used for token swaps
     * @return The router contract address
     */
    function getRouterAddress() external view returns (address) {
        return address(i_router);
    }

    /**
     * @notice Returns the WETH token address
     * @return The WETH token contract address
     */
    function getWethTokenAddress() external view returns (address) {
        return i_wethToken;
    }

    /**
     * @notice Returns a user's target allocation preference
     * @param user The user address to query
     * @return AllocationPreference struct containing investment tokens and their target allocations
     */
    function getUserToAllocationPreference(address user) external view returns (AllocationPreference memory) {
        return s_userToAllocationPreference[user];
    }

    /**
     * @notice Returns a user's current portfolio holdings
     * @param user The user address to query
     * @return UserPortfolio struct containing token addresses and balances
     */
    function getUserToPortfolio(address user) external view returns (UserPortfolio memory) {
        return s_userToPortfolio[user];
    }

    /**
     * @notice Returns the user address at a specific index in the users set
     * @dev Useful for iterating through all users off-chain
     * @param index The index in the users EnumerableSet (0-based)
     * @return The user address at that index
     * @custom:revert Will revert if index is out of bounds
     */
    function getUserAtIndex(uint256 index) external view returns (address) {
        return s_users.at(index);
    }

    /**
     * @notice Checks if an address is registered as a user
     * @param _address The address to check
     * @return True if the address is in the users tracking set, false otherwise
     */
    function isUser(address _address) external view returns (bool) {
        return s_users.contains(_address);
    }

    /**
     * @notice Returns the total number of registered users
     * @dev This is the size of the s_users EnumerableSet
     * @return The number of users currently tracked by the contract
     */
    function getUsersLength() external view returns (uint256) {
        return s_users.length();
    }
}
