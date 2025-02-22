// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "solmate/src/tokens/ERC20.sol";

/**
 * @title DamnValuableToken
 * @author Damn Vulnerable DeFi (https://damnvulnerabledefi.xyz)
 */
contract RSwell is ERC20 {
    constructor() ERC20("Swell", "SWELL", 18) {
        _mint(msg.sender, type(uint256).max);
    }
}
