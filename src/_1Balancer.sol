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

contract _1Balancer is Ownable, ReentrancyGuard {
    /*
     * Errors
     */
    error _1Balancer__ExceededMaxSupportedTokens(
        uint256 investmentTokensLength,
        uint256 maxSupportedTokens
    );
    error _1Balancer__ArrayLengthMismatch(
        uint256 allocationsLength,
        uint256 investmentTokensLength
    );
    error _1Balancer__AllocationSetToZero();
    error _1Balancer__TokenNotSupported(address investmentToken);
    error _1Balancer__AllocationNotEqualTo100Percent(uint256 allocation);
    error _1Balancer__AllocationNotSet();
    error _1Balancer__ZeroAmount();
    error _1Balancer__InputNotWeth();
    error _1Balancer__MsgValueAmountMismatch(uint256 amount, uint256 msgValue);

    /*
     * Libraries
     */
    using SafeERC20 for IERC20Token;

    /*
     * Type declarations
     */
    struct AllocationPreference {
        address[] investmentTokens; // must be supported
        uint256[] allocations; // must add up to 1e18 (representing 100%)
    }

    /*
     * State Variables
     */
    // Represents 100% for allocations
    uint256 private constant PERCENTAGE_FACTOR = 1e18;
    address private immutable i_wethToken;

    IUniswapV2Router02 private immutable i_router;

    uint8 private s_maxSupportedTokens;
    // user -> allocation preference
    mapping(address => AllocationPreference)
        private s_userToAllocationPreference;
    // token -> supported
    mapping(address => bool) private s_tokenToAllowed;

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
    event Deposit(
        address indexed user,
        address indexed inputToken,
        uint256 amount,
        uint256 fee
    );

    /*
     * Constructor
     */
    constructor(
        address wethToken,
        address router,
        uint8 maxSupportedTokens
    ) Ownable(msg.sender) {
        i_wethToken = wethToken;
        i_router = IUniswapV2Router02(router);
        s_maxSupportedTokens = maxSupportedTokens;
    }

    /*
     * External functions
     */
    /*
     * @dev set the allocation preference for msg.sender
     * @param allocationPreference - the allocation preference for the user
     */
    function setUserAllocation(
        AllocationPreference calldata allocationPreference
    ) external {
        uint256 allocationsLength = allocationPreference.allocations.length;
        uint256 investmentTokensLength = allocationPreference
            .investmentTokens
            .length;
        if (investmentTokensLength > s_maxSupportedTokens) {
            revert _1Balancer__ExceededMaxSupportedTokens(
                investmentTokensLength,
                s_maxSupportedTokens
            );
        }
        if (allocationsLength != investmentTokensLength) {
            revert _1Balancer__ArrayLengthMismatch(
                allocationsLength,
                investmentTokensLength
            );
        }
        uint256 total = 0;
        for (uint256 i = 0; i < investmentTokensLength; i++) {
            if (allocationPreference.allocations[i] == 0) {
                revert _1Balancer__AllocationSetToZero();
            }
            address investmentToken = allocationPreference.investmentTokens[i];
            if (!s_tokenToAllowed[investmentToken]) {
                revert _1Balancer__TokenNotSupported(investmentToken);
            }
            total += allocationPreference.allocations[i];
        }
        if (total != PERCENTAGE_FACTOR) {
            revert _1Balancer__AllocationNotEqualTo100Percent(total);
        }
        s_userToAllocationPreference[msg.sender] = allocationPreference;

        emit AllocationSet(msg.sender, allocationPreference);
    }

    /*
     * @dev deposit an asset and invest it based on the allocation preference set by msg.sender
     * @dev requires that the user's allocation preference is set
     * @dev requires that amount is non-zero or msg.value is non-zero
     * @dev requires that the user has a sufficient balance and allowance (if using an ERC20 token)
     * @dev deducts the amasa deposit fee
     * @param depositToken - the token deposited. The WETH address should be used if depositing native ETH.
     * @param amount - the amount to be deposited (0 if using native matic)
     */
    function deposit(
        address inputToken,
        uint256 amount
    ) external payable nonReentrant {
        uint256 allocationsLength = s_userToAllocationPreference[msg.sender]
            .allocations
            .length;
        if (allocationsLength == 0) {
            revert _1Balancer__AllocationNotSet();
        }
        if (!s_tokenToAllowed[inputToken]) {
            revert _1Balancer__TokenNotSupported(inputToken);
        }
        if (amount == 0 && msg.value == 0) {
            revert _1Balancer__ZeroAmount();
        }
        if (msg.value > 0) {
            if (inputToken != i_wethToken) {
                revert _1Balancer__InputNotWeth();
            }
            if (amount != msg.value) {
                revert _1Balancer__MsgValueAmountMismatch(amount, msg.value);
            }
            IERC20Token(inputToken).deposit{value: amount}();
        } else {
            IERC20Token(inputToken).safeTransferFrom(
                msg.sender,
                address(this),
                amount
            );
        }

        AllocationPreference memory pref = s_userToAllocationPreference[
            msg.sender
        ];
        uint256 amountOutMin = 1;
        address[] memory path = new address[](2);
        path[0] = inputToken;

        for (uint256 i = 0; i < pref.investmentTokens.length; i++) {
            path[1] = pref.investmentTokens[i];
            uint256 amountToSwap = (pref.allocations[i] * amount) /
                PERCENTAGE_FACTOR;

            uint256[] memory amounts = i_router.swapExactTokensForTokens({
                amountIn: amountToSwap,
                amountOutMin: amountOutMin,
                path: path,
                to: msg.sender,
                deadline: block.timestamp
            });
            emit Swap(
                msg.sender,
                inputToken,
                pref.investmentTokens[i],
                amountToSwap,
                amounts[1]
            );
        }

        emit Deposit(msg.sender, inputToken, amount, 0);
    }

    function setMaxSupportedTokens(
        uint8 maxSupportedTokens
    ) external onlyOwner {
        s_maxSupportedTokens = maxSupportedTokens;
    }

    function addAllowedToken(address token) external onlyOwner {
        s_tokenToAllowed[token] = true;
        emit InvestmentTokenAdded(token);
    }

    function removeAllowedToken(address token) external onlyOwner {
        s_tokenToAllowed[token] = false;
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
}
