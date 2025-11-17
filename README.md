## 1balancer-contract

## Tools

Make sure to install the tools.

```shell
# Install foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

## Tests

```shell
# Make sure to execute foundry command inside the foundry founder
cd foundry

# Compile
forge build --via-ir
```

```shell
# Make sure to execute foundry command inside the foundry founder
cd foundry

# Set FORK_URL
FORK_URL= rpc url for testing on fork

# Test exercises
source .env

# SWAP WETH -> MKR
forge test --fork-url $FORK_URL \
    --match-path test/research/UniswapV2SwapTest.t.sol \
    --match-test testSwapExactTokensForTokens \
    -vvv

# SWAP WETH -> USDC
forge test --fork-url $FORK_URL \
    --match-path test/research/SwapWithChainlinkTest.t.sol \
    --match-test testSwapWethToUsdcWithOraclePrices \
    -vvv

# SWAP USDC -> WETH	
forge test --fork-url $FORK_URL \
    --match-path test/research/SwapWithChainlinkTest.t.sol \
    --match-test testSwapUsdcToWethWithOraclePrices\
    -vvv	

# Execute an entire file
forge test --match-path test/research/SwapWithChainlinkTest.t.sol
forge test --match-path test/research/UniswapV2SwapTest.t.sol
```
