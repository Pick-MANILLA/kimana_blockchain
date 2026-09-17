// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

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

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event SettlementInitiated(bytes32 indexed ref, address indexed partner, uint256 amount);
    event SettlementReturned(bytes32 indexed ref, address indexed partner, uint256 amount);
    event SettlementRefunded(bytes32 indexed ref, address indexed to, uint256 amount);
    event PartnerUpdated(address indexed partner, bool allowed);
    event LimitsUpdated(uint256 maxPerSettlement, uint256 dailyLimit);
    event Swept(address indexed to, uint256 amount);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error ZeroAddress();
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

    // ---------------------------------------------------------------------
    // Operator actions (backend, via custody provider)
    // ---------------------------------------------------------------------

    /// @notice Send `amount` USDC to `partner` for transfer `ref`.
    function settle(bytes32 ref, address partner, uint256 amount) external;

    /// @notice Send the USDC of a returned settlement to an allowlisted `to` address.
    function refund(bytes32 ref, address to) external;

    // ---------------------------------------------------------------------
    // Partner actions
    // ---------------------------------------------------------------------

    /// @notice Called by the settlement's partner when the off-chain payout failed. Pulls the exact settled
    ///         amount back into the vault (partner must `approve` the vault first).
    function returnSettlement(bytes32 ref) external;

    // ---------------------------------------------------------------------
    // Admin actions (multisig)
    // ---------------------------------------------------------------------

    function setPartner(address partner, bool allowed) external;
    function setLimits(uint256 maxPerSettlement, uint256 dailyLimit) external;
    function sweep(address to, uint256 amount) external;
    function pause() external;
    function unpause() external;

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function getSettlement(bytes32 ref) external view returns (Settlement memory);
    function isPartner(address account) external view returns (bool);
    function remainingDailyLimit() external view returns (uint256);
}
