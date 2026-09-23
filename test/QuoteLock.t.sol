// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Vm} from "forge-std/Vm.sol";

import {BaseTest} from "./BaseTest.sol";
import {ISettlementVault} from "../src/interfaces/ISettlementVault.sol";
import {FxMath} from "../src/libraries/FxMath.sol";

/// @notice FX quote acceptance criteria, as far as the settlement layer enforces them.
///         Each section header names the PRD criterion it covers.
contract QuoteLockTest is BaseTest {
    bytes32 internal ref = keccak256(abi.encodePacked("kimana:transfer:", "txn_quote_01"));
    uint256 internal amount = 45_000 * USDC;
    bytes3 internal constant GHS = "GHS";
    bytes3 internal constant LOWER_NGN = "ngn";
    bytes3 internal constant BAD_DIGIT = "gh1";
    bytes3 internal constant BAD_SYMBOL = "GH[";

    // ------------------------------------------------------------------
    // Criteria 3-5: rate, fees and counterparty amount are recorded on-chain
    // ------------------------------------------------------------------

    function test_lock_recordsRateFeeAndCounterpartyAmount() public {
        ISettlementVault.QuoteInput memory q = _quoteInput(ref, amount);

        vm.expectEmit(address(vault));
        emit ISettlementVault.QuoteLocked(
            ref, q.quoteId, NGN, NGN_RATE, amount, q.feeUsdc, q.receiveAmountMinor, q.expiresAt
        );
        vm.prank(operator);
        vault.lockQuote(ref, q);

        ISettlementVault.LockedQuote memory l = vault.getQuote(ref);
        assertEq(l.quoteId, q.quoteId);
        assertEq(l.receiveCurrency, NGN);
        assertEq(l.receiveDecimals, NGN_DECIMALS, "decimals come from the registry");
        assertEq(l.rate, NGN_RATE);
        assertEq(l.usdcAmount, amount);
        assertEq(l.feeUsdc, 25 * USDC);
        assertEq(l.receiveAmountMinor, q.receiveAmountMinor);
        assertEq(l.expiresAt, block.timestamp + QUOTE_TTL);
        assertEq(l.lockedAt, block.timestamp);
        assertFalse(l.cancelled);
        assertTrue(vault.isQuoteUsed(q.quoteId));
    }

    function test_counterpartyAmount_knownValue() public pure {
        // $45,000 at 1,645.25 NGN/USD = NGN 74,036,250.00 = 7,403,625,000 kobo
        assertEq(FxMath.receiveAmount(45_000 * 1e6, NGN_RATE, 2), 7_403_625_000);
        // XOF has 0 decimals: $100 at 600.50 XOF/USD = 60,050 XOF
        assertEq(FxMath.receiveAmount(100 * 1e6, 60_050_000_000, 0), 60_050);
    }

    function test_lock_rejectsWrongCounterpartyAmount() public {
        ISettlementVault.QuoteInput memory q = _quoteInput(ref, amount);
        uint256 expected = q.receiveAmountMinor;
        q.receiveAmountMinor = expected + 1;

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.ReceiveAmountMismatch.selector, expected + 1, expected));
        vault.lockQuote(ref, q);
    }

    function test_lock_rejectsInvalidInputs() public {
        ISettlementVault.QuoteInput memory q = _quoteInput(ref, amount);
        vm.startPrank(operator);

        vm.expectRevert(ISettlementVault.ZeroRef.selector);
        vault.lockQuote(bytes32(0), q);

        q.quoteId = bytes32(0);
        vm.expectRevert(ISettlementVault.ZeroQuoteId.selector);
        vault.lockQuote(ref, q);

        q = _quoteInput(ref, amount);
        q.receiveCurrency = bytes3(0);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.CurrencyNotSupported.selector, bytes3(0)));
        vault.lockQuote(ref, q);

        q = _quoteInput(ref, amount);
        q.rate = FxMath.MAX_RATE + 1;
        vm.expectRevert(ISettlementVault.InvalidQuote.selector);
        vault.lockQuote(ref, q);

        q = _quoteInput(ref, amount);
        q.feeUsdc = MAX_PER_SETTLEMENT + 1;
        vm.expectRevert(ISettlementVault.InvalidQuote.selector);
        vault.lockQuote(ref, q);

        // Counterparty amount that rounds to zero
        q = _quoteInput(ref, 1);
        q.rate = 1;
        q.receiveAmountMinor = 0;
        vm.expectRevert(ISettlementVault.InvalidQuote.selector);
        vault.lockQuote(ref, q);

        q = _quoteInput(ref, amount);
        q.rate = 0;
        vm.expectRevert(ISettlementVault.InvalidQuote.selector);
        vault.lockQuote(ref, q);

        q = _quoteInput(ref, amount);
        q.usdcAmount = 0;
        vm.expectRevert(ISettlementVault.InvalidQuote.selector);
        vault.lockQuote(ref, q);

        vm.stopPrank();
    }

    function test_lock_rejectsAmountAbovePerSettlementLimit() public {
        ISettlementVault.QuoteInput memory q = _quoteInput(ref, MAX_PER_SETTLEMENT + 1);
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISettlementVault.ExceedsPerSettlementLimit.selector, MAX_PER_SETTLEMENT + 1, MAX_PER_SETTLEMENT
            )
        );
        vault.lockQuote(ref, q);
    }

    // ------------------------------------------------------------------
    // Criterion 6: quote has an expiry time
    // ------------------------------------------------------------------

    function test_lock_rejectsTtlLongerThanConfigured() public {
        ISettlementVault.QuoteInput memory q = _quoteInput(ref, amount);
        uint64 maxAllowed = uint64(block.timestamp) + 15 minutes;
        q.expiresAt = maxAllowed + 1;

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.QuoteTtlTooLong.selector, maxAllowed + 1, maxAllowed));
        vault.lockQuote(ref, q);
    }

    // ------------------------------------------------------------------
    // Criterion 7: expired quotes cannot be accepted
    // ------------------------------------------------------------------

    function test_lock_rejectsExpiredQuote() public {
        ISettlementVault.QuoteInput memory q = _quoteInput(ref, amount);
        vm.warp(q.expiresAt); // expiry instant counts as expired

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.QuoteExpired.selector, ref, q.expiresAt));
        vault.lockQuote(ref, q);
    }

    function test_lock_acceptsOneSecondBeforeExpiry() public {
        ISettlementVault.QuoteInput memory q = _quoteInput(ref, amount);
        vm.warp(q.expiresAt - 1);
        vm.prank(operator);
        vault.lockQuote(ref, q);
        assertGt(vault.getQuote(ref).lockedAt, 0);
    }

    function test_settle_requiresLockedQuote() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.QuoteNotLocked.selector, ref));
        vault.settle(ref, ngnPartner, amount);
    }

    // ------------------------------------------------------------------
    // Criterion 8: accepted quotes are locked within their validity period
    // ------------------------------------------------------------------

    function test_lockedQuote_isHonouredAfterExpiry() public {
        _lock(ref, amount);
        vm.warp(block.timestamp + 1 days); // funding took a day; locked rate still applies
        _settle(ref, amount);
        assertEq(usdc.balanceOf(ngnPartner), amount);
    }

    function test_lockedQuote_cannotBeRelocked() public {
        _lock(ref, amount);
        ISettlementVault.QuoteInput memory q = _quoteInput(ref, amount);
        q.quoteId = keccak256("another quote");
        q.rate = NGN_RATE + 1e8;
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.QuoteAlreadyLocked.selector, ref));
        vault.lockQuote(ref, q);
    }

    function test_quoteId_isSingleUse() public {
        _lock(ref, amount);
        bytes32 otherRef = _ref("txn_quote_02");
        ISettlementVault.QuoteInput memory q = _quoteInput(ref, amount); // same quote id, different transfer
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.QuoteAlreadyUsed.selector, q.quoteId));
        vault.lockQuote(otherRef, q);
    }

    function test_settle_mustMatchLockedAmount() public {
        _lock(ref, amount);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.SettleAmountMismatch.selector, ref, amount - 1, amount));
        vault.settle(ref, ngnPartner, amount - 1);
    }

    function test_lock_rejectedAfterSettlement() public {
        // A ref settled under a quote can never get a second quote.
        _settle(ref, amount);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.QuoteAlreadyLocked.selector, ref));
        vault.lockQuote(ref, _quoteInput(ref, amount));
    }

    function test_cancelQuote_blocksSettlement() public {
        _lock(ref, amount);
        bytes32 qid = _quoteId(ref);

        vm.expectEmit(address(vault));
        emit ISettlementVault.QuoteCancelled(ref, qid);
        vm.prank(operator);
        vault.cancelQuote(ref);

        assertTrue(vault.getQuote(ref).cancelled);
        assertTrue(vault.isQuoteUsed(qid), "cancelled quote id stays used");

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.QuoteIsCancelled.selector, ref));
        vault.settle(ref, ngnPartner, amount);
    }

    function test_cancelQuote_failureModes() public {
        vm.startPrank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.QuoteNotLocked.selector, ref));
        vault.cancelQuote(ref);
        vm.stopPrank();

        _lock(ref, amount);
        vm.prank(operator);
        vault.cancelQuote(ref);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.QuoteIsCancelled.selector, ref));
        vault.cancelQuote(ref);

        bytes32 settledRef = _ref("settled");
        _settle(settledRef, amount);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.RefAlreadyUsed.selector, settledRef));
        vault.cancelQuote(settledRef);
    }

    // ------------------------------------------------------------------
    // Criterion 9: provider divergence triggers an internal alert
    // ------------------------------------------------------------------

    function _quoteAtRate(uint256 rate) internal view returns (ISettlementVault.QuoteInput memory q) {
        q = _quoteInput(ref, amount);
        q.rate = rate;
        q.receiveAmountMinor = FxMath.receiveAmount(amount, rate, NGN_DECIMALS);
    }

    function _countLogs(Vm.Log[] memory logs, bytes32 topic) internal pure returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == topic) ++n;
        }
    }

    function test_divergence_belowAlertThreshold_noAlert() public {
        uint256 rate = NGN_RATE + (NGN_RATE * 99) / 10_000; // +0.99%
        vm.recordLogs();
        vm.prank(operator);
        vault.lockQuote(ref, _quoteAtRate(rate));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countLogs(logs, ISettlementVault.RateDivergence.selector), 0);
        assertEq(_countLogs(logs, ISettlementVault.ReferenceRateStale.selector), 0);
    }

    function test_divergence_atAlertThreshold_emitsAlertAndLocks() public {
        uint256 rate = NGN_RATE - (NGN_RATE * 100) / 10_000; // -1.00%
        vm.expectEmit(address(vault));
        emit ISettlementVault.RateDivergence(ref, NGN, rate, NGN_RATE, 100);
        vm.prank(operator);
        vault.lockQuote(ref, _quoteAtRate(rate));
        assertGt(vault.getQuote(ref).lockedAt, 0);
    }

    function test_divergence_atMax_stillLocksWithAlert() public {
        uint256 rate = NGN_RATE + (NGN_RATE * 500) / 10_000; // +5.00%
        vm.expectEmit(address(vault));
        emit ISettlementVault.RateDivergence(ref, NGN, rate, NGN_RATE, 500);
        vm.prank(operator);
        vault.lockQuote(ref, _quoteAtRate(rate));
    }

    function test_divergence_aboveMax_blocksLock() public {
        uint256 rate = NGN_RATE + (NGN_RATE * 501) / 10_000; // +5.01%
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.RateDivergenceTooHigh.selector, ref, 501, 500));
        vault.lockQuote(ref, _quoteAtRate(rate));
        assertFalse(vault.isQuoteUsed(_quoteId(ref)), "blocked quote is not consumed");
    }

    // ------------------------------------------------------------------
    // Issue #24: the divergence check fails CLOSED
    // ------------------------------------------------------------------

    function test_staleReference_blocksTheLockByDefault() public {
        uint64 refUpdatedAt = uint64(block.timestamp);
        vm.warp(block.timestamp + 1 hours + 1);

        assertFalse(vault.allowStaleReferenceRate(), "fail-closed is the default");
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.ReferenceRateUnavailable.selector, NGN, refUpdatedAt));
        vault.lockQuote(ref, _quoteInput(ref, amount));
        assertEq(vault.getQuote(ref).lockedAt, 0, "nothing locked");
    }

    function test_missingReference_blocksTheLockByDefault() public {
        vm.prank(admin);
        vault.setCurrency(GHS, 2, true);
        ISettlementVault.QuoteInput memory q = _quoteInput(ref, amount);
        q.receiveCurrency = GHS;

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.ReferenceRateUnavailable.selector, GHS, 0));
        vault.lockQuote(ref, q);
    }

    function test_staleReference_emitsAlertAndLocksWhenAdminAllowsIt() public {
        uint64 refUpdatedAt = uint64(block.timestamp);
        vm.prank(admin);
        vault.setAllowStaleReferenceRate(true);
        vm.warp(block.timestamp + 1 hours + 1);

        vm.expectEmit(address(vault));
        emit ISettlementVault.ReferenceRateStale(ref, NGN, refUpdatedAt);
        vm.prank(operator);
        vault.lockQuote(ref, _quoteInput(ref, amount));
        assertGt(vault.getQuote(ref).lockedAt, 0);
    }

    function test_missingReference_emitsAlertWhenAdminAllowsIt() public {
        vm.startPrank(admin);
        vault.setCurrency(GHS, 2, true);
        vault.setAllowStaleReferenceRate(true);
        vm.stopPrank();

        ISettlementVault.QuoteInput memory q = _quoteInput(ref, amount);
        q.receiveCurrency = GHS;
        vm.expectEmit(address(vault));
        emit ISettlementVault.ReferenceRateStale(ref, GHS, 0);
        vm.prank(operator);
        vault.lockQuote(ref, q);
    }

    function test_setAllowStaleReferenceRate_onlyAdminAndEmits() public {
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, operator, DEFAULT_ADMIN_ROLE
            )
        );
        vault.setAllowStaleReferenceRate(true);

        vm.expectEmit(address(vault));
        emit ISettlementVault.AllowStaleReferenceRateUpdated(true);
        vm.prank(admin);
        vault.setAllowStaleReferenceRate(true);
        assertTrue(vault.allowStaleReferenceRate());
    }

    /// @dev A fresh rate published again after a stale period restores normal locking without the override.
    function test_freshReferenceAfterStaleness_locksAgain() public {
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(rateOracle);
        vault.setReferenceRate(NGN, NGN_RATE);

        vm.prank(operator);
        vault.lockQuote(ref, _quoteInput(ref, amount));
        assertGt(vault.getQuote(ref).lockedAt, 0);
    }

    function testFuzz_divergence_behaviour(uint256 bps, bool up) public {
        bps = bound(bps, 0, 2000);
        uint256 delta = (NGN_RATE * bps) / 10_000;
        uint256 rate = up ? NGN_RATE + delta : NGN_RATE - delta;
        uint256 dev = FxMath.deviationBps(rate, NGN_RATE);

        vm.recordLogs();
        vm.prank(operator);
        if (dev > 500) {
            vm.expectRevert(abi.encodeWithSelector(ISettlementVault.RateDivergenceTooHigh.selector, ref, dev, 500));
            vault.lockQuote(ref, _quoteAtRate(rate));
            return;
        }
        vault.lockQuote(ref, _quoteAtRate(rate));
        uint256 alerts = _countLogs(vm.getRecordedLogs(), ISettlementVault.RateDivergence.selector);
        assertEq(alerts, dev >= 100 ? 1 : 0);
    }

    // ------------------------------------------------------------------
    // Reference rates and configuration (access control, validation, audit events)
    // ------------------------------------------------------------------

    function test_setReferenceRate_onlyOracle() public {
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, operator, RATE_ORACLE_ROLE)
        );
        vault.setReferenceRate(NGN, NGN_RATE);
    }

    function test_setReferenceRate_validatesAndEmits() public {
        vm.startPrank(rateOracle);
        vm.expectRevert(ISettlementVault.ZeroRate.selector);
        vault.setReferenceRate(NGN, 0);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.CurrencyNotSupported.selector, GHS));
        vault.setReferenceRate(GHS, NGN_RATE);
        vm.expectRevert(ISettlementVault.InvalidQuote.selector);
        vault.setReferenceRate(NGN, FxMath.MAX_RATE + 1);

        vm.expectEmit(address(vault));
        emit ISettlementVault.ReferenceRateUpdated(NGN, NGN_RATE + 1, uint64(block.timestamp));
        vault.setReferenceRate(NGN, NGN_RATE + 1);
        vm.stopPrank();

        ISettlementVault.ReferenceRate memory r = vault.getReferenceRate(NGN);
        assertEq(r.rate, NGN_RATE + 1);
        assertEq(r.updatedAt, block.timestamp);
    }

    function test_quoteConfig_defaults() public view {
        ISettlementVault.QuoteConfig memory c = vault.quoteConfig();
        assertEq(c.maxQuoteTtl, 15 minutes);
        assertEq(c.referenceMaxAge, 1 hours);
        assertEq(c.maxSettleDelay, 7 days);
        assertEq(c.divergenceAlertBps, 100);
        assertEq(c.divergenceMaxBps, 500);
    }

    function test_setQuoteConfig_onlyAdmin_andValidates() public {
        ISettlementVault.QuoteConfig memory c = ISettlementVault.QuoteConfig({
            maxQuoteTtl: 5 minutes,
            referenceMaxAge: 10 minutes,
            maxSettleDelay: 2 days,
            divergenceAlertBps: 50,
            divergenceMaxBps: 200
        });

        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, operator, DEFAULT_ADMIN_ROLE
            )
        );
        vault.setQuoteConfig(c);

        vm.prank(admin);
        vm.expectEmit(address(vault));
        emit ISettlementVault.QuoteConfigUpdated(c);
        vault.setQuoteConfig(c);
        assertEq(vault.quoteConfig().divergenceMaxBps, 200);

        ISettlementVault.QuoteConfig memory bad = c;
        vm.startPrank(admin);
        bad.maxQuoteTtl = 0;
        vm.expectRevert(ISettlementVault.InvalidQuoteConfig.selector);
        vault.setQuoteConfig(bad);

        bad = c;
        bad.maxQuoteTtl = uint64(1 days) + 1;
        vm.expectRevert(ISettlementVault.InvalidQuoteConfig.selector);
        vault.setQuoteConfig(bad);

        bad = c;
        bad.maxQuoteTtl = type(uint64).max; // would overflow expiry maths if accepted
        vm.expectRevert(ISettlementVault.InvalidQuoteConfig.selector);
        vault.setQuoteConfig(bad);

        bad = c;
        bad.referenceMaxAge = uint64(7 days) + 1;
        vm.expectRevert(ISettlementVault.InvalidQuoteConfig.selector);
        vault.setQuoteConfig(bad);

        bad = c;
        bad.maxSettleDelay = 0;
        vm.expectRevert(ISettlementVault.InvalidQuoteConfig.selector);
        vault.setQuoteConfig(bad);

        bad = c;
        bad.maxSettleDelay = uint64(30 days) + 1;
        vm.expectRevert(ISettlementVault.InvalidQuoteConfig.selector);
        vault.setQuoteConfig(bad);

        bad = c;
        bad.referenceMaxAge = 0;
        vm.expectRevert(ISettlementVault.InvalidQuoteConfig.selector);
        vault.setQuoteConfig(bad);

        bad = c;
        bad.divergenceAlertBps = 0;
        vm.expectRevert(ISettlementVault.InvalidQuoteConfig.selector);
        vault.setQuoteConfig(bad);

        bad = c;
        bad.divergenceAlertBps = 300; // above max
        vm.expectRevert(ISettlementVault.InvalidQuoteConfig.selector);
        vault.setQuoteConfig(bad);

        bad = c;
        bad.divergenceMaxBps = 10_001;
        vm.expectRevert(ISettlementVault.InvalidQuoteConfig.selector);
        vault.setQuoteConfig(bad);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Security: access control and pause
    // ------------------------------------------------------------------

    function test_lockAndCancel_onlyOperator() public {
        ISettlementVault.QuoteInput memory q = _quoteInput(ref, amount);
        vm.startPrank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, OPERATOR_ROLE)
        );
        vault.lockQuote(ref, q);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, OPERATOR_ROLE)
        );
        vault.cancelQuote(ref);
        vm.stopPrank();
    }

    function test_lock_blockedWhilePaused() public {
        ISettlementVault.QuoteInput memory q = _quoteInput(ref, amount);
        vm.prank(pauser);
        vault.pause();
        vm.prank(operator);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.lockQuote(ref, q);
    }

    // ------------------------------------------------------------------
    // Fuzz: counterparty amount maths
    // ------------------------------------------------------------------

    function testFuzz_receiveAmount_matchesFormula(uint64 usdcAmount, uint64 rate, uint8 decimals) public pure {
        decimals = uint8(bound(decimals, 0, 18));
        uint256 got = FxMath.receiveAmount(usdcAmount, rate, decimals);
        uint256 numerator = uint256(usdcAmount) * uint256(rate) * (10 ** decimals);
        assertEq(got, numerator / 1e14);
        assertLe(got * 1e14, numerator, "rounds down");
        assertLt(numerator - got * 1e14, 1e14, "remainder below one minor unit");
    }

    function testFuzz_lockThenSettle(uint256 amt, uint256 ttl) public {
        amt = bound(amt, MIN_AMOUNT, MAX_PER_SETTLEMENT);
        ttl = bound(ttl, 1, 15 minutes);
        ISettlementVault.QuoteInput memory q = _quoteInput(ref, amt);
        // forge-lint: disable-next-line(unsafe-typecast)
        q.expiresAt = uint64(block.timestamp + ttl); // ttl bounded to 15 minutes
        vm.startPrank(operator);
        vault.lockQuote(ref, q);
        vault.settle(ref, ngnPartner, amt);
        vm.stopPrank();
        assertEq(usdc.balanceOf(ngnPartner), amt);
        assertEq(vault.getSettlement(ref).amount, vault.getQuote(ref).usdcAmount);
    }

    // ------------------------------------------------------------------
    // Review follow-ups: currency registry, rounding, settle delay, boundaries
    // ------------------------------------------------------------------

    function test_unknownCurrency_cannotBypassDivergence() public {
        // Lower-case or unregistered codes used to skip the divergence check; now they are rejected.
        ISettlementVault.QuoteInput memory q = _quoteInput(ref, amount);
        q.receiveCurrency = LOWER_NGN;
        q.rate = NGN_RATE * 1000;
        q.receiveAmountMinor = FxMath.receiveAmount(amount, q.rate, NGN_DECIMALS);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.CurrencyNotSupported.selector, LOWER_NGN));
        vault.lockQuote(ref, q);
    }

    function test_wrongDecimals_rejected() public {
        // Caller cannot choose decimals: an amount computed with 0 decimals fails the check for NGN (2).
        ISettlementVault.QuoteInput memory q = _quoteInput(ref, amount);
        uint256 withZeroDecimals = FxMath.receiveAmount(amount, NGN_RATE, 0);
        q.receiveAmountMinor = withZeroDecimals;
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISettlementVault.ReceiveAmountMismatch.selector,
                withZeroDecimals,
                FxMath.receiveAmount(amount, NGN_RATE, NGN_DECIMALS)
            )
        );
        vault.lockQuote(ref, q);
    }

    function test_disabledCurrency_blocksNewLocks() public {
        _lock(ref, amount);
        vm.prank(admin);
        vault.setCurrency(NGN, NGN_DECIMALS, false);

        bytes32 other = _ref("after-disable");
        ISettlementVault.QuoteInput memory q = _quoteInput(other, amount);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.CurrencyNotSupported.selector, NGN));
        vault.lockQuote(other, q);

        // Already-locked quotes still settle.
        _settle(ref, amount);
    }

    function test_setCurrency_adminOnly_validates_emits() public {
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, operator, DEFAULT_ADMIN_ROLE
            )
        );
        vault.setCurrency(GHS, 2, true);

        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.CurrencyNotSupported.selector, BAD_DIGIT));
        vault.setCurrency(BAD_DIGIT, 2, true);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.CurrencyNotSupported.selector, BAD_SYMBOL));
        vault.setCurrency(BAD_SYMBOL, 2, true);
        vm.expectRevert(abi.encodeWithSelector(FxMath.UnsupportedCurrencyDecimals.selector, 19));
        vault.setCurrency(GHS, 19, true);

        vm.expectEmit(address(vault));
        emit ISettlementVault.CurrencyUpdated(GHS, 2, true);
        vault.setCurrency(GHS, 2, true);
        vm.stopPrank();

        ISettlementVault.CurrencyInfo memory info = vault.getCurrency(GHS);
        assertEq(info.decimals, 2);
        assertTrue(info.enabled);
    }

    function test_zeroDecimalCurrency() public {
        bytes3 xof = "XOF";
        vm.prank(admin);
        vault.setCurrency(xof, 0, true);
        vm.prank(rateOracle);
        vault.setReferenceRate(xof, 60_050_000_000);
        ISettlementVault.QuoteInput memory q = _quoteInput(ref, 100 * USDC);
        q.receiveCurrency = xof;
        q.rate = 60_050_000_000;
        q.receiveAmountMinor = 60_050;
        vm.prank(operator);
        vault.lockQuote(ref, q);
        assertEq(vault.getQuote(ref).receiveDecimals, 0);
    }

    function test_divergence_roundsUp_blocksJustAboveMax() public {
        // 5.0099% must not be treated as 5.00%.
        uint256 rate = NGN_RATE + (NGN_RATE * 50_099) / 1_000_000;
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.RateDivergenceTooHigh.selector, ref, 501, 500));
        vault.lockQuote(ref, _quoteAtRate(rate));
    }

    function test_divergence_roundsUp_alertsJustBelowThreshold() public {
        // 0.9999% rounds up to 100 bps and must alert.
        uint256 rate = NGN_RATE - (NGN_RATE * 9999) / 1_000_000;
        vm.expectEmit(address(vault));
        emit ISettlementVault.RateDivergence(ref, NGN, rate, NGN_RATE, 100);
        vm.prank(operator);
        vault.lockQuote(ref, _quoteAtRate(rate));
    }

    function test_referenceAgeExactlyMax_isFresh() public {
        vm.warp(block.timestamp + 1 hours);
        vm.recordLogs();
        vm.prank(operator);
        vault.lockQuote(ref, _quoteInput(ref, amount));
        assertEq(_countLogs(vm.getRecordedLogs(), ISettlementVault.ReferenceRateStale.selector), 0);
    }

    function test_settle_rejectsLockOlderThanMaxDelay() public {
        _lock(ref, amount);
        uint64 lockedAt = vault.getQuote(ref).lockedAt;
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.QuoteLockTooOld.selector, ref, lockedAt, 7 days));
        vault.settle(ref, ngnPartner, amount);
    }

    function test_settle_atExactlyMaxDelay_succeeds() public {
        _lock(ref, amount);
        vm.warp(block.timestamp + 7 days);
        _settle(ref, amount);
        assertEq(usdc.balanceOf(ngnPartner), amount);
    }

    function test_cancelQuote_worksWhilePaused() public {
        _lock(ref, amount);
        vm.prank(pauser);
        vault.pause();
        vm.prank(operator);
        vault.cancelQuote(ref);
        assertTrue(vault.getQuote(ref).cancelled);
    }

    function test_cancelledRef_cannotBeRelocked() public {
        _lock(ref, amount);
        vm.prank(operator);
        vault.cancelQuote(ref);
        ISettlementVault.QuoteInput memory q = _quoteInput(ref, amount);
        q.quoteId = keccak256("new quote, same transfer");
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.QuoteAlreadyLocked.selector, ref));
        vault.lockQuote(ref, q);
    }

    function test_settle_afterLimitsLowered_isBlocked() public {
        _lock(ref, amount);
        vm.prank(admin);
        vault.setLimits(10_000 * USDC, 20_000 * USDC);
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(ISettlementVault.ExceedsPerSettlementLimit.selector, amount, 10_000 * USDC)
        );
        vault.settle(ref, ngnPartner, amount);
    }

    function test_receiveAmount_independentVectors() public pure {
        // Hand-computed values (not derived from the formula under test).
        assertEq(FxMath.receiveAmount(1_000_000, 164_525_000_000, 2), 164_525); // $1 -> NGN 1,645.25
        assertEq(FxMath.receiveAmount(1, 164_525_000_000, 2), 0); // 0.000001 USDC -> 0.0016 NGN -> 0 kobo
        assertEq(FxMath.receiveAmount(10_000, 164_525_000_000, 2), 1645); // $0.01 -> NGN 16.4525 -> 1,645 kobo
        assertEq(FxMath.receiveAmount(2_500_000_000, 1_210_000_000, 2), 3_025_000); // $2,500 at GHS 12.10 = 30,250.00
        assertEq(FxMath.receiveAmount(1_000_000, 100_000_000, 18), 1e18); // 1:1, 18 decimals
    }

    function test_receiveAmount_bounds_doNotOverflow() public pure {
        // Largest sane inputs: 1e12 USDC, MAX_RATE, 18 decimals.
        uint256 v = FxMath.receiveAmount(1e18, FxMath.MAX_RATE, 18);
        assertEq(v, 1e18 * 1e20 * 1e18 / 1e14);
    }

    function test_deviationBps_knownValues() public pure {
        assertEq(FxMath.deviationBps(100, 100), 0);
        assertEq(FxMath.deviationBps(101, 100), 100);
        assertEq(FxMath.deviationBps(99, 100), 100);
        assertEq(FxMath.deviationBps(1_000_001, 1_000_000), 1); // 0.01 bps rounds up to 1
        assertEq(FxMath.deviationBps(150, 100), 5000);
    }
}
