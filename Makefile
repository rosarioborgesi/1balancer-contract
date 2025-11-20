-include .env

.PHONY: all test clean deploy fund help install snapshot format anvil 

DEFAULT_ANVIL_KEY := 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

build :; forge build

test :; forge test

anvil :; anvil -m 'test test test test test test test test test test test junk' --steps-tracing --block-time 1

# Clean the repo
clean  :; forge clean

# Remove modules
remove :; rm -rf .gitmodules && rm -rf .git/modules/* && rm -rf lib && touch .gitmodules && git add . && git commit -m "modules"

install :
	forge install smartcontractkit/chainlink-brownie-contracts
	forge install foundry-rs/forge-std
	forge install openzeppelin/openzeppelin-contracts

deploy-anvil:
	@forge script script/DeployBalancer.s.sol:DeployBalancer --rpc-url http://localhost:8545 --private-key $(DEFAULT_ANVIL_KEY) --broadcast  -vvvv

deploy-sepolia:
	@forge script script/DeployBalancer.s.sol:DeployBalancer --rpc-url $(SEPOLIA_RPC_URL) --account default --broadcast --verify --etherscan-api-key $(ETHERSCAN_API_KEY) -vvvv