// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    AccessControlDefaultAdminRules
} from "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ISettlementVault} from "./interfaces/ISettlementVault.sol";
import {FxMath} from "./libraries/FxMath.sol";

/// @title SettlementVault
/// @notice Holds USDC for Kimana transfers and releases it to allowlisted off-ramp partners.
/// @dev Roles:
///      - DEFAULT_ADMIN_ROLE: Safe multisig. Manages partners, limits, sweeps and unpausing. Transfers of this
///        role are two-step with a delay (AccessControlDefaultAdminRules).
///      - OPERATOR_ROLE: custody-provider (MPC) wallet used by the backend. Settles and refunds.
///      - PAUSER_ROLE: emergency key(s). Can pause only.
///      - RATE_ORACLE_ROLE: independent rate publisher used to detect FX provider divergence.
///
///      Safety properties this contract enforces:
///      - a `ref` can be settled at most once (no duplicate money movement);
///      - funds only ever leave to allowlisted partners, except admin sweeps;
///      - per-settlement and per-UTC-day limits cap exposure;
///      - returned funds are reserved for their refund and cannot be swept;
///      - nothing is settled without a firm quote that was locked before it expired, used only once, and
///        whose counterparty amount matches the quoted rate exactly;
///      - quotes that diverge from the reference rate raise an on-chain alert, or are blocked if too far off.
contract SettlementVault is ISettlementVault, AccessControlDefaultAdminRules, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant RATE_ORACLE_ROLE = keccak256("RATE_ORACLE_ROLE");

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

    mapping(bytes32 ref => LockedQuote) private _quotes;
    mapping(bytes32 quoteId => bool) private _quoteUsed;
    mapping(bytes3 currency => ReferenceRate) private _referenceRates;
    mapping(bytes3 currency => CurrencyInfo) private _currencies;
    QuoteConfig private _quoteConfig;

    constructor(
        IERC20 asset_,
        address admin,
        address operator,
        address pauser,
        address rateOracle,
        uint48 adminTransferDelay,
        uint256 maxPerSettlement_,
        uint256 dailyLimit_
    ) AccessControlDefaultAdminRules(adminTransferDelay, admin) {
        if (address(asset_) == address(0) || operator == address(0) || pauser == address(0)) {
            revert ZeroAddress();
        }
        // All amount maths assumes native USDC (6 decimals). Bridged 18-decimal tokens (e.g. on BNB Chain) are refused.
        uint8 assetDecimals = IERC20Metadata(address(asset_)).decimals();
        if (assetDecimals != FxMath.USDC_DECIMALS) revert UnsupportedAssetDecimals(assetDecimals);
        asset = asset_;
        _grantRole(OPERATOR_ROLE, operator);
        _grantRole(PAUSER_ROLE, pauser);
        if (rateOracle != address(0)) _grantRole(RATE_ORACLE_ROLE, rateOracle);
        _setLimits(maxPerSettlement_, dailyLimit_);
        _setQuoteConfig(
            QuoteConfig({
                maxQuoteTtl: 15 minutes,
                referenceMaxAge: 1 hours,
                maxSettleDelay: 7 days,
                divergenceAlertBps: 100,
                divergenceMaxBps: 500
            })
        );
    }

    // ---------------------------------------------------------------------
    // Operator actions
    // ---------------------------------------------------------------------

    /// @inheritdoc ISettlementVault
    function lockQuote(bytes32 ref, QuoteInput calldata q) external onlyRole(OPERATOR_ROLE) whenNotPaused {
        if (ref == bytes32(0)) revert ZeroRef();
        if (q.quoteId == bytes32(0)) revert ZeroQuoteId();
        if (q.rate == 0 || q.rate > FxMath.MAX_RATE || q.usdcAmount == 0) revert InvalidQuote();
        CurrencyInfo memory cur = _currencies[q.receiveCurrency];
        if (!cur.enabled) revert CurrencyNotSupported(q.receiveCurrency);
        // Settling requires a lock, so an existing lock also covers already-settled refs.
        if (_quotes[ref].lockedAt != 0) revert QuoteAlreadyLocked(ref);
        if (_quoteUsed[q.quoteId]) revert QuoteAlreadyUsed(q.quoteId);

        // Expired quotes cannot be accepted; unrealistically long quotes are rejected too.
        if (q.expiresAt <= block.timestamp) revert QuoteExpired(ref, q.expiresAt);
        uint64 maxExpiry = uint64(block.timestamp) + _quoteConfig.maxQuoteTtl;
        if (q.expiresAt > maxExpiry) revert QuoteTtlTooLong(q.expiresAt, maxExpiry);

        if (q.usdcAmount > maxPerSettlement) revert ExceedsPerSettlementLimit(q.usdcAmount, maxPerSettlement);
        if (q.feeUsdc > maxPerSettlement) revert InvalidQuote();

        // The counterparty amount shown to the customer must follow from the rate exactly.
        uint256 expected = FxMath.receiveAmount(q.usdcAmount, q.rate, cur.decimals);
        if (expected == 0) revert InvalidQuote();
        if (q.receiveAmountMinor != expected) revert ReceiveAmountMismatch(q.receiveAmountMinor, expected);

        _checkDivergence(ref, q.receiveCurrency, q.rate);

        _quoteUsed[q.quoteId] = true;
        _quotes[ref] = LockedQuote({
            quoteId: q.quoteId,
            receiveCurrency: q.receiveCurrency,
            receiveDecimals: cur.decimals,
            cancelled: false,
            expiresAt: q.expiresAt,
            lockedAt: uint64(block.timestamp),
            rate: q.rate,
            usdcAmount: q.usdcAmount,
            feeUsdc: q.feeUsdc,
            receiveAmountMinor: q.receiveAmountMinor
        });

        emit QuoteLocked(
            ref, q.quoteId, q.receiveCurrency, q.rate, q.usdcAmount, q.feeUsdc, q.receiveAmountMinor, q.expiresAt
        );
    }

    /// @inheritdoc ISettlementVault
    function cancelQuote(bytes32 ref) external onlyRole(OPERATOR_ROLE) {
        LockedQuote storage q = _quotes[ref];
        if (q.lockedAt == 0) revert QuoteNotLocked(ref);
        if (q.cancelled) revert QuoteIsCancelled(ref);
        if (_settlements[ref].status != Status.None) revert RefAlreadyUsed(ref);
        q.cancelled = true;
        emit QuoteCancelled(ref, q.quoteId);
    }

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

        LockedQuote storage q = _quotes[ref];
        if (q.lockedAt == 0) revert QuoteNotLocked(ref);
        if (q.cancelled) revert QuoteIsCancelled(ref);
        if (amount != q.usdcAmount) revert SettleAmountMismatch(ref, amount, q.usdcAmount);
        if (block.timestamp > uint256(q.lockedAt) + _quoteConfig.maxSettleDelay) {
            revert QuoteLockTooOld(ref, q.lockedAt, _quoteConfig.maxSettleDelay);
        }

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
    // Rate oracle actions
    // ---------------------------------------------------------------------

    /// @inheritdoc ISettlementVault
    function setReferenceRate(bytes3 currency, uint256 rate) external onlyRole(RATE_ORACLE_ROLE) {
        if (!_currencies[currency].enabled) revert CurrencyNotSupported(currency);
        if (rate == 0) revert ZeroRate();
        if (rate > FxMath.MAX_RATE) revert InvalidQuote();
        uint64 nowTs = uint64(block.timestamp);
        _referenceRates[currency] = ReferenceRate({rate: rate, updatedAt: nowTs});
        emit ReferenceRateUpdated(currency, rate, nowTs);
    }

    // ---------------------------------------------------------------------
    // Admin actions
    // ---------------------------------------------------------------------

    /// @inheritdoc ISettlementVault
    function setQuoteConfig(QuoteConfig calldata config) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setQuoteConfig(config);
    }

    /// @inheritdoc ISettlementVault
    /// @dev Codes are ISO 4217 upper-case ASCII, e.g. "NGN". Disabling a currency blocks new locks only.
    function setCurrency(bytes3 currency, uint8 decimals, bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i; i < 3; ++i) {
            if (currency[i] < 0x41 || currency[i] > 0x5A) revert CurrencyNotSupported(currency);
        }
        if (decimals > FxMath.MAX_CURRENCY_DECIMALS) revert FxMath.UnsupportedCurrencyDecimals(decimals);
        _currencies[currency] = CurrencyInfo({decimals: decimals, enabled: enabled});
        emit CurrencyUpdated(currency, decimals, enabled);
    }

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
    function getQuote(bytes32 ref) external view returns (LockedQuote memory) {
        return _quotes[ref];
    }

    /// @inheritdoc ISettlementVault
    function isQuoteUsed(bytes32 quoteId) external view returns (bool) {
        return _quoteUsed[quoteId];
    }

    /// @inheritdoc ISettlementVault
    function getReferenceRate(bytes3 currency) external view returns (ReferenceRate memory) {
        return _referenceRates[currency];
    }

    /// @inheritdoc ISettlementVault
    function getCurrency(bytes3 currency) external view returns (CurrencyInfo memory) {
        return _currencies[currency];
    }

    /// @inheritdoc ISettlementVault
    function quoteConfig() external view returns (QuoteConfig memory) {
        return _quoteConfig;
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

    /// @dev Emits an alert when the reference is missing/stale or the deviation reaches the alert threshold;
    ///      reverts when the deviation exceeds the hard maximum.
    function _checkDivergence(bytes32 ref, bytes3 currency, uint256 rate) internal {
        ReferenceRate memory r = _referenceRates[currency];
        if (r.updatedAt == 0 || block.timestamp - r.updatedAt > _quoteConfig.referenceMaxAge) {
            emit ReferenceRateStale(ref, currency, r.updatedAt);
            return;
        }
        uint256 dev = FxMath.deviationBps(rate, r.rate);
        if (dev > _quoteConfig.divergenceMaxBps) revert RateDivergenceTooHigh(ref, dev, _quoteConfig.divergenceMaxBps);
        if (dev >= _quoteConfig.divergenceAlertBps) emit RateDivergence(ref, currency, rate, r.rate, dev);
    }

    function _setQuoteConfig(QuoteConfig memory config) internal {
        if (
            config.maxQuoteTtl == 0 || config.maxQuoteTtl > 1 days || config.referenceMaxAge == 0
                || config.referenceMaxAge > 7 days || config.maxSettleDelay == 0 || config.maxSettleDelay > 30 days
                || config.divergenceAlertBps == 0 || config.divergenceAlertBps > config.divergenceMaxBps
                || config.divergenceMaxBps > FxMath.BPS
        ) revert InvalidQuoteConfig();
        _quoteConfig = config;
        emit QuoteConfigUpdated(config);
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
