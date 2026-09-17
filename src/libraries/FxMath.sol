// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @title FxMath
/// @notice Integer-only FX conversions shared by the vault and (by specification) the backend.
/// @dev Rates are "receive-currency major units per 1 USD" with `RATE_DECIMALS` decimals, e.g. a USD->NGN rate
///      of 1,645.25 is `164_525_000_000`. The backend MUST use the exact same rounding (floor) so that the
///      counterparty amount it shows the customer is the amount the vault verifies.
library FxMath {
    uint8 internal constant RATE_DECIMALS = 8;
    uint8 internal constant USDC_DECIMALS = 6;
    uint8 internal constant MAX_CURRENCY_DECIMALS = 18;
    uint256 internal constant BPS = 10_000;
    /// @notice Upper bound for rates (1e12 receive units per USD) so maths can never overflow for sane amounts.
    uint256 internal constant MAX_RATE = 1e20;

    error UnsupportedCurrencyDecimals(uint8 decimals);

    /// @notice Counterparty amount in receive-currency minor units, rounded down.
    /// @param usdcAmount USDC base units (6 decimals) that will be settled.
    /// @param rate Receive units per 1 USD, `RATE_DECIMALS` decimals.
    /// @param receiveDecimals Minor-unit exponent of the receive currency (NGN = 2, XOF = 0).
    /// @dev receiveMinor = floor(usdcAmount * rate * 10^receiveDecimals / 10^(6 + 8))
    function receiveAmount(uint256 usdcAmount, uint256 rate, uint8 receiveDecimals) internal pure returns (uint256) {
        if (receiveDecimals > MAX_CURRENCY_DECIMALS) revert UnsupportedCurrencyDecimals(receiveDecimals);
        return (usdcAmount * rate * (10 ** receiveDecimals)) / (10 ** (USDC_DECIMALS + RATE_DECIMALS));
    }

    /// @notice Absolute deviation of `rate` from `referenceRate`, in basis points, rounded UP so that
    ///         thresholds are never under-reported (5.0001% counts as 501 bps).
    function deviationBps(uint256 rate, uint256 referenceRate) internal pure returns (uint256) {
        uint256 diff = rate > referenceRate ? rate - referenceRate : referenceRate - rate;
        return (diff * BPS + referenceRate - 1) / referenceRate;
    }
}
