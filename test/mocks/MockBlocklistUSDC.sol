// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test-only USDC stand-in that mimics Circle's blocklist: any transfer touching a blocklisted
///         address reverts, exactly as real USDC does.
/// @dev Circle can blocklist any address at any time, without warning and without the vault's involvement.
///      Kimana cannot prevent this; these tests exist to document how the vault behaves when it happens.
contract MockBlocklistUSDC is ERC20 {
    error Blacklisted(address account);

    mapping(address account => bool) public isBlocklisted;

    constructor() ERC20("Mock USD Coin (blocklist)", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocklisted(address account, bool blocked) external {
        isBlocklisted[account] = blocked;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (isBlocklisted[from]) revert Blacklisted(from);
        if (isBlocklisted[to]) revert Blacklisted(to);
        super._update(from, to, value);
    }
}
