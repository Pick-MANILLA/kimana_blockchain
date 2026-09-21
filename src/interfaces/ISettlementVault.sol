// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ISettlementVault
/// @notice On-chain settlement leg of a Kimana transfer. The vault holds USDC and releases it to allowlisted
///         off-ramp partners, who pay out naira (or another local currency) off-chain.
/// @dev The Kimana backend ledger is authoritative. Every call is keyed by `ref`, the keccak256 hash of the
///      backend transfer id, so each transfer can be settled at most once on-chain.
interface ISettlementVault {
    /// @notice Lifecycle of a single settlement reference.
    /// @dev None -> Settled -> Returned -> Refunded. Settled and Refunded are the only terminal states the
    ///      backend should expect; Returned means the partner sent the funds back and a refund is pending.
    enum Status {
        None,
        Settled,
        Returned,
        Refunded
    }

    struct Settlement {
        address partner;
        uint64 settledAt;
        Status status;
        uint256 amount;
    }

    /// @notice Firm quote the customer accepted, as sent by the backend when the customer confirms.
    /// @dev `usdcAmount` is what the vault will settle (net of `feeUsdc`). `receiveAmountMinor` must equal
    ///      `FxMath.receiveAmount(usdcAmount, rate, decimals)` exactly, where `decimals` comes from the admin
    ///      currency registry (never from the caller).
    struct QuoteInput {
        bytes32 quoteId;
        bytes3 receiveCurrency;
        uint64 expiresAt;
        uint256 rate;
        uint256 usdcAmount;
        uint256 feeUsdc;
        uint256 receiveAmountMinor;
    }

    /// @notice A quote locked on-chain for a transfer `ref`.
    struct LockedQuote {
        bytes32 quoteId;
        bytes3 receiveCurrency;
        uint8 receiveDecimals;
        bool cancelled;
        uint64 expiresAt;
        uint64 lockedAt;
        uint256 rate;
        uint256 usdcAmount;
        uint256 feeUsdc;
        uint256 receiveAmountMinor;
    }

    /// @notice USDC received from an on-ramp partner for a transfer `ref`.
    /// @dev `amount` is the gross deposit: the quote's `usdcAmount` plus `feeUsdc`. The fee stays in the vault
    ///      and is withdrawn by admin `sweep`.
    struct Funding {
        address partner;
        uint64 fundedAt;
        uint256 amount;
    }

    /// @notice What a partner address is allowed to do.
    /// @dev A partner may be an on-ramp, an off-ramp, or both. `payoutCurrency` restricts an off-ramp partner to
    ///      settlements quoted in that currency; `bytes3(0)` means any registered currency.
    struct PartnerInfo {
        bool onRamp;
        bool offRamp;
        bool enabled;
        bytes3 payoutCurrency;
    }

    /// @notice A receive currency the vault may quote, with its minor-unit exponent (NGN = 2, XOF = 0).
    struct CurrencyInfo {
        uint8 decimals;
        bool enabled;
    }

    /// @notice Independent reference rate for a receive currency, used to detect provider divergence.
    struct ReferenceRate {
        uint256 rate;
        uint64 updatedAt;
    }

    /// @notice Risk parameters for quote locking.
    struct QuoteConfig {
        uint64 maxQuoteTtl; // longest allowed time between lock and quote expiry (<= 1 day)
        uint64 referenceMaxAge; // reference rates older than this are treated as stale (<= 7 days)
        uint64 maxSettleDelay; // longest allowed time between lock and settlement (<= 30 days)
        uint16 divergenceAlertBps; // deviation that emits RateDivergence (alert, lock still succeeds)
        uint16 divergenceMaxBps; // deviation that blocks the lock
    }

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event SettlementInitiated(bytes32 indexed ref, address indexed partner, uint256 amount);
    event SettlementReturned(bytes32 indexed ref, address indexed partner, uint256 amount);
    event SettlementRefunded(bytes32 indexed ref, address indexed to, uint256 amount);
    event SettlementFunded(bytes32 indexed ref, address indexed partner, uint256 amount, uint256 feeUsdc);
    event PartnerUpdated(address indexed partner, bool onRamp, bool offRamp, bool enabled, bytes3 payoutCurrency);
    event RequireFundingUpdated(bool required);
    event LimitsUpdated(uint256 maxPerSettlement, uint256 dailyLimit);
    event Swept(address indexed to, uint256 amount);
    event TokenRescued(IERC20 indexed token, address indexed to, uint256 amount);

    event QuoteLocked(
        bytes32 indexed ref,
        bytes32 indexed quoteId,
        bytes3 receiveCurrency,
        uint256 rate,
        uint256 usdcAmount,
        uint256 feeUsdc,
        uint256 receiveAmountMinor,
        uint64 expiresAt
    );
    event QuoteCancelled(bytes32 indexed ref, bytes32 indexed quoteId);
    event CurrencyUpdated(bytes3 indexed currency, uint8 decimals, bool enabled);
    event ReferenceRateUpdated(bytes3 indexed currency, uint256 rate, uint64 updatedAt);
    event QuoteConfigUpdated(QuoteConfig config);

    /// @notice ALERT: the quoted rate deviates from the reference rate by at least `divergenceAlertBps`.
    event RateDivergence(
        bytes32 indexed ref, bytes3 indexed currency, uint256 quotedRate, uint256 referenceRate, uint256 deviationBps
    );
    /// @notice ALERT: no fresh reference rate was available, so divergence could not be checked.
    event ReferenceRateStale(bytes32 indexed ref, bytes3 indexed currency, uint64 referenceUpdatedAt);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error ZeroAddress();
    error UnsupportedAssetDecimals(uint8 decimals);
    error ZeroRef();
    error ZeroAmount();
    error InvalidLimits(uint256 maxPerSettlement, uint256 dailyLimit);
    error RefAlreadyUsed(bytes32 ref);
    error PartnerNotAllowed(address account);
    error ExceedsPerSettlementLimit(uint256 amount, uint256 limit);
    error ExceedsDailyLimit(uint256 attempted, uint256 remaining);
    error InvalidStatus(bytes32 ref, Status current, Status expected);
    error NotSettlementPartner(bytes32 ref, address caller);
    error InsufficientFreeBalance(uint256 requested, uint256 available);

    error ZeroQuoteId();
    error InvalidQuote();
    error QuoteExpired(bytes32 ref, uint64 expiresAt);
    error QuoteTtlTooLong(uint64 expiresAt, uint64 maxAllowed);
    error QuoteAlreadyLocked(bytes32 ref);
    error QuoteAlreadyUsed(bytes32 quoteId);
    error QuoteNotLocked(bytes32 ref);
    error QuoteIsCancelled(bytes32 ref);
    error ReceiveAmountMismatch(uint256 provided, uint256 expected);
    error SettleAmountMismatch(bytes32 ref, uint256 provided, uint256 locked);
    error RateDivergenceTooHigh(bytes32 ref, uint256 deviationBps, uint256 maxBps);
    error InvalidQuoteConfig();
    error ZeroRate();
    error CurrencyNotSupported(bytes3 currency);
    error QuoteLockTooOld(bytes32 ref, uint64 lockedAt, uint64 maxSettleDelay);
    error CannotRescueAssetToken();

    error AlreadyFunded(bytes32 ref);
    error FundAmountMismatch(bytes32 ref, uint256 provided, uint256 expected);
    error NotFunded(bytes32 ref);
    error PartnerCurrencyMismatch(address partner, bytes3 required, bytes3 quoted);
    error InvalidPartnerConfig();

    // ---------------------------------------------------------------------
    // Operator actions (backend, via custody provider)
    // ---------------------------------------------------------------------

    /// @notice Lock the firm quote the customer accepted for transfer `ref`. Reverts if the quote has expired,
    ///         was already used, has inconsistent amounts, or diverges too far from the reference rate.
    function lockQuote(bytes32 ref, QuoteInput calldata quote) external;

    /// @notice Cancel a locked quote that will never be settled (e.g. funding never arrived). Both the quote id
    ///         and the transfer `ref` stay used: a re-quoted transfer needs a new backend transfer id.
    function cancelQuote(bytes32 ref) external;

    /// @notice Send `amount` USDC to `partner` for transfer `ref`. Requires a locked, non-cancelled quote for
    ///         `ref` whose `usdcAmount` equals `amount`. A locked quote is honoured after its expiry, but only
    ///         for up to `maxSettleDelay` after it was locked.
    function settle(bytes32 ref, address partner, uint256 amount) external;

    /// @notice Send the USDC of a returned settlement to an allowlisted `to` address.
    function refund(bytes32 ref, address to) external;

    // ---------------------------------------------------------------------
    // Partner actions
    // ---------------------------------------------------------------------

    /// @notice Called by an on-ramp partner to deliver the USDC for transfer `ref`, binding the deposit on-chain
    ///         to the quote the customer accepted. `amount` must equal `usdcAmount + feeUsdc` of the locked quote
    ///         (the partner must `approve` the vault first).
    /// @dev Optional by default. Turn `requireFunding` on once the on-ramp partner is known to deliver per
    ///      transfer rather than into a shared float; `settle` then refuses an unfunded `ref`.
    function fund(bytes32 ref, uint256 amount) external;

    /// @notice Called by the settlement's partner when the off-chain payout failed. Pulls the exact settled
    ///         amount back into the vault (partner must `approve` the vault first).
    function returnSettlement(bytes32 ref) external;

    // ---------------------------------------------------------------------
    // Rate oracle actions
    // ---------------------------------------------------------------------

    /// @notice Publish an independent reference rate (receive units per 1 USD, 8 decimals).
    function setReferenceRate(bytes3 currency, uint256 rate) external;

    // ---------------------------------------------------------------------
    // Admin actions (multisig)
    // ---------------------------------------------------------------------

    function setPartner(address partner, PartnerInfo calldata info) external;
    function setRequireFunding(bool required) external;
    function setLimits(uint256 maxPerSettlement, uint256 dailyLimit) external;
    function setQuoteConfig(QuoteConfig calldata config) external;
    function setCurrency(bytes3 currency, uint8 decimals, bool enabled) external;
    function sweep(address to, uint256 amount) external;
    function rescueToken(IERC20 token, address to, uint256 amount) external;

    function pause() external;
    function unpause() external;

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function getSettlement(bytes32 ref) external view returns (Settlement memory);
    function getQuote(bytes32 ref) external view returns (LockedQuote memory);
    function isQuoteUsed(bytes32 quoteId) external view returns (bool);
    function getReferenceRate(bytes3 currency) external view returns (ReferenceRate memory);
    function getCurrency(bytes3 currency) external view returns (CurrencyInfo memory);
    function quoteConfig() external view returns (QuoteConfig memory);
    function getFunding(bytes32 ref) external view returns (Funding memory);
    function getPartner(address account) external view returns (PartnerInfo memory);
    function isPartner(address account) external view returns (bool);
    function remainingDailyLimit() external view returns (uint256);
}
