// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "./IERC20.sol";

// https://github.com/circlefin/stablecoin-evm/blob/master/contracts/v1/FiatTokenV1.sol
interface IUSDC is IERC20 {
    function masterMinter() external view returns (address);
    // https://github.com/circlefin/stablecoin-evm/blob/master/contracts/minting/MinterManagementInterface.sol
    function configureMinter(address minter, uint256 minterAllowedAmount) external returns (bool);
    function mint(address _to, uint256 _amount) external returns (bool);
}