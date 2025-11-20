# 1balancer-contract

An automated portfolio rebalancing protocol built on Ethereum that maintains user-defined token allocations using Uniswap V2 and Chainlink price feeds.

## Table of Contents

- [Overview](#overview)
- [How It Works](#how-it-works)
- [User Flow](#user-flow)
- [Features](#features)
- [Architecture](#architecture)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Configuration](#configuration)
- [Testing](#testing)
- [Deployment](#deployment)
- [Contract Interaction](#contract-interaction)
- [Technical Details](#technical-details)

## Overview

1balancer-contract is a smart contract system that automatically rebalances crypto portfolios to maintain target allocations. Users deposit tokens (WETH or USDC), set their desired allocation percentages, and the protocol automatically rebalances their portfolio when it drifts beyond a configurable threshold.

The system uses:
- Uniswap V2 for token swaps
- Chainlink oracles for accurate price feeds
- Chainlink Automation for periodic rebalancing triggers

## How It Works

The Balancer contract enables users to create and maintain a balanced portfolio between WETH and USDC:

1. **Set Allocation**: Users define their target allocation (e.g., 50% WETH / 50% USDC)
2. **Deposit Funds**: Users deposit either ETH, WETH, or USDC
3. **Automatic Rebalancing**: When portfolio drift exceeds the threshold (default 5%), the contract automatically swaps tokens to restore the target allocation
4. **Chainlink Automation**: Chainlink Keepers monitor portfolios and trigger rebalancing when conditions are met
5. **Withdraw**: Users can withdraw their entire portfolio at any time

### Example Scenario

```
Initial State:
- User sets allocation: 50% WETH / 50% USDC
- User deposits 2 ETH (worth $6,000)
- Contract wraps ETH to WETH and rebalances:
  - Swaps ~1 WETH for ~$3,000 USDC
  - Final: 1 WETH ($3,000) + 3,000 USDC ($3,000)

After Price Movement:
- WETH price increases 40%
- Portfolio becomes: 1 WETH ($4,200) + 3,000 USDC ($3,000)
- Current allocation: 58.3% WETH / 41.7% USDC
- Drift: 8.3% (exceeds 5% threshold)

Automatic Rebalancing:
- Chainlink Automation triggers rebalance
- Contract swaps ~0.2 WETH for ~$600 USDC
- Final: 0.8 WETH ($3,600) + 3,600 USDC ($3,600)
- Restored to ~50% / 50%
```

## User Flow

### 1. Initial Setup (One-time)

Users interact with the Balancer contract to configure their portfolio:

```solidity
// Step 1: Set your target allocation
AllocationPreference memory allocation = AllocationPreference({
    investmentTokens: [WETH_ADDRESS, USDC_ADDRESS],
    allocations: [5e17, 5e17]  // 50% each (in 18 decimal format)
});
balancer.setUserAllocation(allocation);
```

### 2. Deposit Funds

Users can deposit in three ways:

**Option A: Deposit Native ETH**
```solidity
// Deposit 1 ETH (automatically wrapped to WETH)
balancer.deposit{value: 1 ether}(WETH_ADDRESS, 1 ether);
```

**Option B: Deposit WETH**
```solidity
// First approve the Balancer contract
WETH.approve(BALANCER_ADDRESS, amount);
// Then deposit
balancer.deposit(WETH_ADDRESS, amount);
```

**Option C: Deposit USDC**
```solidity
// First approve the Balancer contract
USDC.approve(BALANCER_ADDRESS, amount);
// Then deposit
balancer.deposit(USDC_ADDRESS, amount);
```

### 3. Automatic Rebalancing

Once deposited, the protocol automatically manages your portfolio:

- Chainlink Automation monitors your portfolio allocation
- When drift exceeds 5% (configurable), automatic rebalancing occurs
- Rebalancing interval: configurable (e.g., every 24 hours)
- Users can also check if rebalancing is needed: `balancer.needsRebalancing()`

### 4. Withdraw Funds

Users can withdraw their entire portfolio at any time:

```solidity
balancer.withdraw();
// All tokens (WETH and USDC) are transferred back to user
```

## Features

- **Automated Rebalancing**: Maintains target allocations without user intervention
- **Flexible Deposits**: Accept ETH, WETH, or USDC
- **Price Oracle Integration**: Uses Chainlink for accurate WETH/USD prices
- **Decentralized Automation**: Chainlink Keepers trigger rebalancing
- **Security**: Built with OpenZeppelin contracts (ReentrancyGuard, Ownable, SafeERC20)
- **Configurable Thresholds**: Adjustable rebalancing triggers (1%-10%)
- **Gas Efficient**: Only rebalances when necessary
- **Transparent**: All swaps and rebalancing events are emitted on-chain

## Architecture

### Core Components

1. **Balancer.sol**: Main contract handling deposits, withdrawals, and rebalancing logic
2. **PriceConverter.sol**: Helper library for Chainlink price feed integration
3. **HelperConfig.s.sol**: Configuration for different networks (Sepolia, Mainnet, Local)
4. **DeployBalancer.s.sol**: Deployment script

### Key Contracts

```
src/
├── Balancer.sol              # Main portfolio manager
├── PriceConverter.sol        # Price feed helper
└── interfaces/
    ├── IWETH.sol             # WETH interface
    ├── IERC20Token.sol       # ERC20 interface
    └── uniswap-v2/           # Uniswap V2 interfaces
```

### External Dependencies

- **OpenZeppelin**: Security and utility contracts
- **Chainlink**: Price feeds and automation
- **Uniswap V2**: Token swapping mechanism

## Prerequisites

Before setting up the project, ensure you have:

- **Git**: For cloning the repository
- **Foundry**: Ethereum development toolkit
- **Node.js** (optional): For additional tooling

## Installation

### 1. Install Foundry

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

### 2. Clone the Repository

```bash
git clone https://github.com/yourusername/1balancer-contract.git
cd 1balancer-contract
```

### 3. Install Dependencies

```bash
# Install required libraries
make install

# Or manually:
forge install smartcontractkit/chainlink-brownie-contracts
forge install foundry-rs/forge-std
forge install openzeppelin/openzeppelin-contracts
```

### 4. Compile Contracts

```bash
forge build
```

## Configuration

### Environment Variables

Create a `.env` file in the project root:

```bash
# Network RPC URLs
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_API_KEY
MAINNET_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_API_KEY

# For fork testing
FORK_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_API_KEY

# Deployment
ETHERSCAN_API_KEY=your_etherscan_api_key

# Private keys (for testing only, use keystore for production)
PRIVATE_KEY=your_private_key
```

Load environment variables:

```bash
source .env
```

### Contract Parameters

The Balancer contract requires these constructor parameters:

- `wethToken`: WETH token address
- `usdcToken`: USDC token address
- `router`: Uniswap V2 Router address
- `priceFeed`: Chainlink WETH/USD price feed address
- `rebalanceThreshold`: Minimum drift to trigger rebalancing (1%-10%, in 18 decimals)
- `maxSupportedTokens`: Maximum tokens per portfolio (currently 2)
- `rebalanceInterval`: Minimum time between rebalances (in seconds)

## Testing

The project includes comprehensive test suites:

### Run All Tests

```bash
# Run all tests
forge test

# Run with verbosity
forge test -vvv
```

### Unit Tests

Test individual contract functions in isolation:

```bash
# Test core Balancer functionality
forge test --match-path test/unit/BalancerTest.t.sol -vvv

# Test with harness (internal functions exposed)
forge test --match-path test/unit/BalancerHarnessTest.t.sol -vvv
```

### Integration Tests

Test contract interactions with external protocols (requires forking):

```bash
# Set fork URL
export FORK_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_API_KEY

# Run integration tests
forge test --fork-url $FORK_URL --match-path test/integration/BalancerForkTest.t.sol -vvv

# Test with harness
forge test --fork-url $FORK_URL --match-path test/integration/BalancerHarnessForkTest.t.sol -vvv
```

### Research Tests

Exploratory tests for understanding external protocols:

```bash
# Test Uniswap V2 swaps
forge test --fork-url $FORK_URL \
    --match-path test/research/UniswapV2SwapTest.t.sol \
    --match-test testSwapExactTokensForTokens \
    -vvv

# Test Chainlink price feeds with swaps
forge test --fork-url $FORK_URL \
    --match-path test/research/SwapWithChainlinkTest.t.sol \
    -vvv
```

### Specific Test Execution

```bash
# Run a specific test function
forge test --match-test testDepositWeth -vvv

# Run tests in a specific file
forge test --match-path test/unit/BalancerTest.t.sol

# Run with gas reporting
forge test --gas-report
```

### Coverage

```bash
# Generate coverage report
forge coverage

# Generate detailed coverage report
forge coverage --report lcov
```

## Deployment

### Local Deployment (Anvil)

Start a local Ethereum node:

```bash
# Terminal 1: Start Anvil
make anvil

# Terminal 2: Deploy contract
make deploy-anvil
```

The contract will be deployed with the default Anvil private key.

### Testnet Deployment (Sepolia)

1. **Setup Account**

```bash
# Store your private key securely using Foundry's keystore
cast wallet import default --interactive
```

2. **Fund Account**

Get Sepolia ETH from a faucet:
- [Alchemy Sepolia Faucet](https://sepoliafaucet.com/)
- [Chainlink Faucet](https://faucets.chain.link/)

3. **Deploy**

```bash
# Deploy to Sepolia
make deploy-sepolia
```

The deployment script will:
- Deploy the Balancer contract
- Verify the contract on Etherscan
- Output the deployed contract address

### Mainnet Deployment

**WARNING**: Mainnet deployment requires real ETH. Ensure you have:
- Sufficient ETH for gas fees
- Audited contracts
- Tested thoroughly on testnet

```bash
# Deploy to mainnet (use with caution)
forge script script/DeployBalancer.s.sol:DeployBalancer \
    --rpc-url $MAINNET_RPC_URL \
    --account default \
    --broadcast \
    --verify \
    --etherscan-api-key $ETHERSCAN_API_KEY \
    -vvvv
```

### Post-Deployment Setup

After deployment, the owner must:

1. **Add Allowed Tokens**

```bash
cast send $BALANCER_ADDRESS "addAllowedToken(address)" $WETH_ADDRESS --account default
cast send $BALANCER_ADDRESS "addAllowedToken(address)" $USDC_ADDRESS --account default
```

2. **Register with Chainlink Automation**

- Visit [Chainlink Automation](https://automation.chain.link/)
- Register a new Upkeep with your Balancer contract address
- Fund the Upkeep with LINK tokens

3. **Verify Configuration**

```bash
cast call $BALANCER_ADDRESS "getWethTokenAddress()(address)"
cast call $BALANCER_ADDRESS "getMaxSupportedTokens()(uint8)"
cast call $BALANCER_ADDRESS "getTokenToAllowed(address)(bool)" $WETH_ADDRESS
```

## Contract Interaction

### Read Functions

Query contract state:

```bash
# Check if a token is allowed
cast call $BALANCER_ADDRESS "getTokenToAllowed(address)(bool)" $TOKEN_ADDRESS

# Get user's allocation preference
cast call $BALANCER_ADDRESS "getUserToAllocationPreference(address)" $USER_ADDRESS

# Get user's current portfolio
cast call $BALANCER_ADDRESS "getUserToPortfolio(address)" $USER_ADDRESS

# Check if user needs rebalancing
cast call $BALANCER_ADDRESS "needsRebalancing()(bool)" --from $USER_ADDRESS

# Get number of users
cast call $BALANCER_ADDRESS "getUsersLength()(uint256)"
```

### Write Functions

Interact with the contract:

```bash
# Set allocation (50% WETH, 50% USDC)
cast send $BALANCER_ADDRESS \
    "setUserAllocation((address[],uint256[]))" \
    "[$WETH_ADDRESS,$USDC_ADDRESS]" \
    "[500000000000000000,500000000000000000]" \
    --account default

# Deposit 1 ETH
cast send $BALANCER_ADDRESS \
    "deposit(address,uint256)" \
    $WETH_ADDRESS \
    1000000000000000000 \
    --value 1ether \
    --account default

# Withdraw all funds
cast send $BALANCER_ADDRESS "withdraw()" --account default
```

### Using Web3 Libraries

**Ethers.js Example:**

```javascript
const balancer = new ethers.Contract(BALANCER_ADDRESS, BALANCER_ABI, signer);

// Set allocation
const allocation = {
    investmentTokens: [WETH_ADDRESS, USDC_ADDRESS],
    allocations: [
        ethers.parseEther("0.5"),  // 50%
        ethers.parseEther("0.5")   // 50%
    ]
};
await balancer.setUserAllocation(allocation);

// Deposit 1 ETH
await balancer.deposit(WETH_ADDRESS, ethers.parseEther("1"), {
    value: ethers.parseEther("1")
});

// Check portfolio
const portfolio = await balancer.getUserToPortfolio(userAddress);
console.log("Tokens:", portfolio.tokens);
console.log("Balances:", portfolio.balances);

// Withdraw
await balancer.withdraw();
```

## Technical Details

### Allocation Format

Allocations use 18 decimal precision where `1e18 = 100%`:

- 50% = `500000000000000000` (5e17)
- 30% = `300000000000000000` (3e17)
- 100% = `1000000000000000000` (1e18)

Example allocations must sum to 1e18:
```solidity
allocations: [5e17, 5e17]     // Valid: 50% + 50% = 100%
allocations: [7e17, 3e17]     // Valid: 70% + 30% = 100%
allocations: [6e17, 3e17]     // Invalid: 60% + 30% = 90%
```

### Rebalancing Logic

The contract rebalances when:

1. **Time Condition**: Minimum interval has passed since last rebalance
2. **Drift Condition**: At least one token's allocation exceeds: `target ± threshold`

Formula:
```
drift = |current_allocation - target_allocation|
needs_rebalancing = drift > threshold
```

Example with 5% threshold and 50% target:
- Acceptable range: 45% - 55%
- Current 60%: drift = 10%, triggers rebalancing
- Current 52%: drift = 2%, no rebalancing needed

### Price Calculations

**WETH Valuation:**
- Uses Chainlink ETH/USD price feed
- Returns price in 18 decimals
- Example: $3,000 = 3000000000000000000000

**USDC Valuation:**
- Assumed 1:1 with USD
- Converted from 6 decimals to 18 decimals
- 1 USDC (1000000) = 1 USD (1000000000000000000)

### Security Considerations

1. **Reentrancy Protection**: Uses OpenZeppelin's ReentrancyGuard
2. **Safe Token Transfers**: Uses SafeERC20 for all token operations
3. **Access Control**: Owner-only functions for critical operations
4. **Slippage**: Currently uses minimal slippage protection (amountOutMin: 1)
5. **Price Oracle**: Depends on Chainlink oracle accuracy and availability

### Known Limitations

- Currently supports only 2 tokens (WETH and USDC)
- Hardcoded to Uniswap V2 (no V3 support)
- Minimal slippage protection in swaps
- No emergency pause mechanism
- Assumes USDC maintains 1:1 USD peg

### Events

The contract emits events for monitoring:

```solidity
event AllocationSet(address indexed user, AllocationPreference allocation);
event Swap(address indexed user, address indexed inputToken, address indexed outputToken, uint256 amountIn, uint256 amountOut);
event PortfolioUpdated(address indexed user, UserPortfolio portfolio);
event Withdrawal(address indexed user);
event UpkeepPerformed(uint256 blockTimestamp);
event UserAdded(address indexed user);
event UserRemoved(address indexed user);
```

## Project Structure

```
1balancer-contract/
├── src/
│   ├── Balancer.sol              # Main contract
│   ├── PriceConverter.sol        # Price feed helper
│   └── interfaces/               # Contract interfaces
├── script/
│   ├── DeployBalancer.s.sol      # Deployment script
│   └── HelperConfig.s.sol        # Network configurations
├── test/
│   ├── unit/                     # Unit tests
│   ├── integration/              # Integration tests
│   ├── research/                 # Protocol research tests
│   └── mocks/                    # Test mocks
├── lib/                          # Dependencies
├── foundry.toml                  # Foundry configuration
├── Makefile                      # Build automation
└── README.md                     # This file
```

## Troubleshooting

### Common Issues

**Issue**: "Balancer__AllocationNotSet" error

**Solution**: Set your allocation preference before depositing:
```bash
cast send $BALANCER_ADDRESS "setUserAllocation((address[],uint256[]))" ...
```

**Issue**: "Balancer__TokenNotSupported" error

**Solution**: Ensure the owner has added the token to allowed list:
```bash
cast send $BALANCER_ADDRESS "addAllowedToken(address)" $TOKEN_ADDRESS --account owner
```

**Issue**: Fork tests failing

**Solution**: Ensure FORK_URL is set and points to a valid archive node:
```bash
export FORK_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY
```

**Issue**: Deployment fails on Sepolia

**Solution**: Ensure you have:
1. Sufficient Sepolia ETH
2. Correct RPC URL in `.env`
3. Valid Etherscan API key for verification

## Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Write tests for new functionality
4. Ensure all tests pass
5. Submit a pull request

## License

This project is licensed under the MIT License.

## Disclaimer

This software is provided "as is", without warranty of any kind. Use at your own risk. This is experimental software and has not been audited. Do not use with real funds without proper security audits.
