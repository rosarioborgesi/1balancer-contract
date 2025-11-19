// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Test, console2} from "forge-std/Test.sol";
import {BalancerHarness} from "../mocks/BalancerHarness.sol";
import {HelperConfig} from "script/HelperConfig.s.sol";
import {WETH, USDC} from "../mocks/Tokens.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {Balancer} from "../../src/Balancer.sol";
import {PriceConverter} from "../../src/PriceConverter.sol";

contract BalancerHarnessTest is Test {
    BalancerHarness public harness;
    HelperConfig public helperConfig;
    HelperConfig.NetworkConfig public config;

    WETH public weth;
    USDC public usdc;

    AggregatorV3Interface public priceFeed;

    uint8 public constant MAX_SUPPORTED_TOKENS = 2;
    uint256 public constant REBALANCE_THRESHOLD = 5 * 1e16; // 5%

    address owner;
    address USER = makeAddr("user");

    using PriceConverter for uint256;

    function setUp() public {
        helperConfig = new HelperConfig();
        config = helperConfig.getConfig();

        priceFeed = AggregatorV3Interface(config.priceFeed);
        weth = WETH(payable(config.weth));
        usdc = USDC(payable(config.usdc));
        owner = config.account;

        vm.startPrank(owner);
        harness = new BalancerHarness(
            config.weth, config.usdc, config.router, config.priceFeed, REBALANCE_THRESHOLD, MAX_SUPPORTED_TOKENS
        );
        harness.addAllowedToken(address(weth));
        harness.addAllowedToken(address(usdc));
        vm.stopPrank();

        weth.mint(USER, 10_000 ether);
        usdc.mint(USER, 10_000 * 10 ** 6);
    }

    /*////////////////////////////////////////////////////////////// 
                            NEEDS REBALANCING
    //////////////////////////////////////////////////////////////*/

    function testRebalancesWhenWethIsHigherThanUsdc() public {
        // Deploying the harness

        console2.log("WETH address", address(weth));
        console2.log("USDC address", address(usdc));

        // Creating AllocationPreference
        address[] memory investmentTokens = new address[](2);
        investmentTokens[0] = address(weth);
        investmentTokens[1] = address(usdc);

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 5 * 10 ** 17; // 50%
        allocations[1] = 5 * 10 ** 17; // 50%

        Balancer.AllocationPreference memory allocationPreference =
            Balancer.AllocationPreference(investmentTokens, allocations);

        // Creating User Portfolio
        address[] memory tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(usdc);

        uint256[] memory balances = new uint256[](2);
        balances[0] = 1 ether; // 1 WETH, approximately 99% of the portfolio value
        balances[1] = 1e6; // 1 USDC, approximately 1% of the portfolio value

        vm.startPrank(USER);
        harness.setUserAllocation(allocationPreference);
        harness.setTestPortfolio(USER, tokens, balances);
        bool needsRebalancing = harness.needsRebalancing();
        vm.stopPrank();

        assertTrue(needsRebalancing);
    }

    function testRebalancesWhenUsdcIsHigherThanWeth() public {
        // Deploying the harness

        console2.log("WETH address", address(weth));
        console2.log("USDC address", address(usdc));

        // Creating AllocationPreference
        address[] memory investmentTokens = new address[](2);
        investmentTokens[0] = address(weth);
        investmentTokens[1] = address(usdc);

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 5 * 10 ** 17; // 50%
        allocations[1] = 5 * 10 ** 17; // 50%

        Balancer.AllocationPreference memory allocationPreference =
            Balancer.AllocationPreference(investmentTokens, allocations);

        // Creating User Portfolio
        address[] memory tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(usdc);

        uint256[] memory balances = new uint256[](2);
        balances[0] = 100000000000000 wei; // equivalent to 0.0001 WETH approximately 0.3 USD so less then 1% of the portfolio value
        balances[1] = 1000 * 1e6; // 1000 USDC so more then 99% of the portfolio value

        vm.startPrank(USER);
        harness.setUserAllocation(allocationPreference);
        harness.setTestPortfolio(USER, tokens, balances);
        bool needsRebalancing = harness.needsRebalancing();
        vm.stopPrank();

        assertTrue(needsRebalancing);
    }

    function testDoesNotRebalanceWhenBalanced() public {
        // Creating AllocationPreference: 50% WETH, 50% USDC
        address[] memory investmentTokens = new address[](2);
        investmentTokens[0] = address(weth);
        investmentTokens[1] = address(usdc);

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 5e17; // 50%
        allocations[1] = 5e17; // 50%

        Balancer.AllocationPreference memory allocationPreference =
            Balancer.AllocationPreference(investmentTokens, allocations);

        // Creating User Portfolio with BALANCED values
        // Assuming ETH price is ~$3000 (from mock price feed)
        address[] memory tokens = new address[](2);
        tokens[0] = address(weth);
        tokens[1] = address(usdc);

        uint256[] memory balances = new uint256[](2);
        balances[0] = 1 ether; // 1 WETH = ~$3000 USD  50% of the portfolio value
        balances[1] = 3000 * 1e6; // 3000 USDC  50% of the portfolio value

        // Total value: $6000, split 50/50 = balanced!
        uint256 wethAmount = 1 ether;
        uint256 wethPrice = wethAmount.getConversionRate(priceFeed);
        console2.log("1 WETH = ~$", wethPrice); // 3000000000000000000000 (3000 USD)

        vm.startPrank(USER);
        harness.setUserAllocation(allocationPreference);
        harness.setTestPortfolio(USER, tokens, balances);
        bool needsRebalancing = harness.needsRebalancing();
        vm.stopPrank();

        assertFalse(needsRebalancing); // Should NOT need rebalancing
    }
}
