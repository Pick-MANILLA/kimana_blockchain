// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title UsdcUnits
/// @notice Conversions between the backend's minor units (US cents, 2 decimals) and USDC base units
///         (6 decimals). All math is integer-only; never use floating point for money.
library UsdcUnits {
    /// @dev 10 ** (USDC decimals - cents decimals) = 10 ** (6 - 2).
    uint256 internal constant CENTS_TO_USDC = 1e4;

    error NotWholeCents(uint256 usdcAmount);

    /// @notice 1 cent = 10_000 USDC base units. $1,500.00 = 150_000 cents = 1_500_000_000 units.
    function fromCents(uint256 cents) internal pure returns (uint256) {
        return cents * CENTS_TO_USDC;
    }

    /// @notice Reverts if `usdcAmount` has sub-cent precision, so no value is silently dropped.
    function toCents(uint256 usdcAmount) internal pure returns (uint256) {
        if (usdcAmount % CENTS_TO_USDC != 0) revert NotWholeCents(usdcAmount);
        return usdcAmount / CENTS_TO_USDC;
    }
}
