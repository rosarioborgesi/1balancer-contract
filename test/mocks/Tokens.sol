// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract WETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 wad) public {
        require(balanceOf(msg.sender) >= wad);
        _burn(msg.sender, wad);
        msg.sender.call{value: wad}("");
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

contract USDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function decimals() public view override returns (uint8) {
        return 6;
    }
}
