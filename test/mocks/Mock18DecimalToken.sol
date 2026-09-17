// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test-only stand-in for bridged 18-decimal "USDC" (e.g. Binance-Peg USDC on BNB Chain).
contract Mock18DecimalToken is ERC20 {
    constructor() ERC20("Bridged USD Coin", "USDC") {}
}
