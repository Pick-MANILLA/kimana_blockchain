// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    AccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ISettlementVault} from "./interfaces/ISettlementVault.sol";

/// @title SettlementVault
/// @notice Holds USDC for Kimana transfers and releases it to allowlisted off-ramp partners.
/// @dev Roles:
///      - DEFAULT_ADMIN_ROLE: Safe multisig. Manages partners, limits, sweeps and unpausing. Transfers of this
///        role are two-step with a delay (AccessControlDefaultAdminRules).
///      - OPERATOR_ROLE: custody-provider (MPC) wallet used by the backend. Settles and refunds.
///      - PAUSER_ROLE: emergency key(s). Can pause only.
///
///      Safety properties this contract enforces:
///      - a `ref` can be settled at most once (no duplicate money movement);
///      - funds only ever leave to allowlisted partners, except admin sweeps;
///      - per-settlement and per-UTC-day limits cap exposure;
///      - returned funds are reserved for their refund and cannot be swept.
contract SettlementVault is ISettlementVault, AccessControlDefaultAdminRules, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @notice The settlement token (USDC, 6 decimals).
    IERC20 public immutable asset;

    uint256 public maxPerSettlement;
    uint256 public dailyLimit;

    /// @notice Amount settled per UTC day index (block.timestamp / 1 days).
    mapping(uint256 day => uint256 amount) public settledOnDay;

    /// @notice Sum of amounts that were returned by partners but not yet refunded.
    uint256 public reservedForRefunds;

    uint256 public totalSettled;
    uint256 public totalReturned;
    uint256 public totalRefunded;

    mapping(bytes32 ref => Settlement) private _settlements;
    mapping(address account => bool) private _partners;

    constructor(
        IERC20 asset_,
        address admin,
        address operator,
        address pauser,
        uint48 adminTransferDelay,
        uint256 maxPerSettlement_,
        uint256 dailyLimit_
    ) AccessControlDefaultAdminRules(adminTransferDelay, admin) {
        if (address(asset_) == address(0) || operator == address(0) || pauser == address(0)) {
            revert ZeroAddress();
        }
        asset = asset_;
        _grantRole(OPERATOR_ROLE, operator);
        _grantRole(PAUSER_ROLE, pauser);
        _setLimits(maxPerSettlement_, dailyLimit_);
    }

    // ---------------------------------------------------------------------
    // Operator actions
    // ---------------------------------------------------------------------

    /// @inheritdoc ISettlementVault
    function settle(bytes32 ref, address partner, uint256 amount)
        external
        onlyRole(OPERATOR_ROLE)
        whenNotPaused
        nonReentrant
    {
        if (ref == bytes32(0)) revert ZeroRef();
        if (amount == 0) revert ZeroAmount();
        if (_settlements[ref].status != Status.None) revert RefAlreadyUsed(ref);
        if (!_partners[partner]) revert PartnerNotAllowed(partner);
        if (amount > maxPerSettlement) revert ExceedsPerSettlementLimit(amount, maxPerSettlement);

        uint256 today = block.timestamp / 1 days;
        uint256 remaining = _remainingOn(today);
        if (amount > remaining) revert ExceedsDailyLimit(amount, remaining);

        settledOnDay[today] += amount;
        totalSettled += amount;
        _settlements[ref] =
            Settlement({partner: partner, settledAt: uint64(block.timestamp), status: Status.Settled, amount: amount});

        emit SettlementInitiated(ref, partner, amount);
        asset.safeTransfer(partner, amount);
    }

    /// @inheritdoc ISettlementVault
    function refund(bytes32 ref, address to) external onlyRole(OPERATOR_ROLE) whenNotPaused nonReentrant {
        Settlement storage s = _settlements[ref];
        if (s.status != Status.Returned) revert InvalidStatus(ref, s.status, Status.Returned);
        if (!_partners[to]) revert PartnerNotAllowed(to);

        uint256 amount = s.amount;
        s.status = Status.Refunded;
        reservedForRefunds -= amount;
        totalRefunded += amount;

        emit SettlementRefunded(ref, to, amount);
        asset.safeTransfer(to, amount);
    }

    // ---------------------------------------------------------------------
    // Partner actions
    // ---------------------------------------------------------------------

    /// @inheritdoc ISettlementVault
    /// @dev Intentionally allowed while paused: returning funds only reduces risk.
    function returnSettlement(bytes32 ref) external nonReentrant {
        Settlement storage s = _settlements[ref];
        if (s.status != Status.Settled) revert InvalidStatus(ref, s.status, Status.Settled);
        if (msg.sender != s.partner) revert NotSettlementPartner(ref, msg.sender);

        uint256 amount = s.amount;
        s.status = Status.Returned;
        reservedForRefunds += amount;
        totalReturned += amount;

        emit SettlementReturned(ref, msg.sender, amount);
        asset.safeTransferFrom(msg.sender, address(this), amount);
    }

    // ---------------------------------------------------------------------
    // Admin actions
    // ---------------------------------------------------------------------

    /// @inheritdoc ISettlementVault
    function setPartner(address partner, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (partner == address(0)) revert ZeroAddress();
        _partners[partner] = allowed;
        emit PartnerUpdated(partner, allowed);
    }

    /// @inheritdoc ISettlementVault
    function setLimits(uint256 maxPerSettlement_, uint256 dailyLimit_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setLimits(maxPerSettlement_, dailyLimit_);
    }

    /// @inheritdoc ISettlementVault
    /// @dev Treasury rebalancing. Cannot touch funds reserved for pending refunds.
    function sweep(address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        uint256 free = asset.balanceOf(address(this)) - reservedForRefunds;
        if (amount > free) revert InsufficientFreeBalance(amount, free);
        emit Swept(to, amount);
        asset.safeTransfer(to, amount);
    }

    /// @inheritdoc ISettlementVault
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @inheritdoc ISettlementVault
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @inheritdoc ISettlementVault
    function getSettlement(bytes32 ref) external view returns (Settlement memory) {
        return _settlements[ref];
    }

    /// @inheritdoc ISettlementVault
    function isPartner(address account) external view returns (bool) {
        return _partners[account];
    }

    /// @inheritdoc ISettlementVault
    function remainingDailyLimit() external view returns (uint256) {
        return _remainingOn(block.timestamp / 1 days);
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    function _remainingOn(uint256 day) internal view returns (uint256) {
        uint256 used = settledOnDay[day];
        return used >= dailyLimit ? 0 : dailyLimit - used;
    }

    function _setLimits(uint256 maxPerSettlement_, uint256 dailyLimit_) internal {
        if (maxPerSettlement_ == 0 || maxPerSettlement_ > dailyLimit_) {
            revert InvalidLimits(maxPerSettlement_, dailyLimit_);
        }
        maxPerSettlement = maxPerSettlement_;
        dailyLimit = dailyLimit_;
        emit LimitsUpdated(maxPerSettlement_, dailyLimit_);
    }
}
