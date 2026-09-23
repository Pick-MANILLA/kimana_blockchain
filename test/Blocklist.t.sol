// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SettlementVault} from "../src/SettlementVault.sol";
import {ISettlementVault} from "../src/interfaces/ISettlementVault.sol";
import {FxMath} from "../src/libraries/FxMath.sol";
import {MockBlocklistUSDC} from "./mocks/MockBlocklistUSDC.sol";

/// @notice Issue #3. Documents how the vault behaves when Circle blocklists an address on USDC.
/// @dev Conclusion: no contract change is needed. `settle(ref, partner, amount)` and `refund(ref, to)` both
///      take the destination as a parameter, so the operator routes around a blocklisted counterparty by
///      choosing another allowlisted partner. The failing transaction reverts atomically, leaving vault state
///      untouched, and `monitor/` raises a critical alert because it decodes reverted vault transactions.
///      The one case with no on-chain remedy is the vault itself being blocklisted; see
///      `docs/security/threat-model.md`.
contract BlocklistTest is Test {
    uint256 internal constant USDC = 1e6;
    uint256 internal constant MAX_PER_SETTLEMENT = 50_000 * USDC;
    uint256 internal constant DAILY_LIMIT = 100_000 * USDC;
    uint256 internal constant AMOUNT = 1000 * USDC;
    uint256 internal constant FEE = 25 * USDC;
    bytes3 internal constant NGN = "NGN";
    uint256 internal constant NGN_RATE = 164_525_000_000;

    MockBlocklistUSDC internal usdc;
    SettlementVault internal vault;

    address internal admin = makeAddr("admin");
    address internal operator = makeAddr("operator");
    address internal pauser = makeAddr("pauser");
    address internal oracle = makeAddr("oracle");
    address internal offRampA = makeAddr("off-ramp A");
    address internal offRampB = makeAddr("off-ramp B (spare)");
    address internal onRampA = makeAddr("on-ramp A");
    address internal onRampB = makeAddr("on-ramp B (spare)");

    bytes32 internal ref = keccak256("kimana:transfer:blocklist_001");

    function setUp() public {
        vm.warp(1_780_000_000);
        usdc = new MockBlocklistUSDC();
        vault = new SettlementVault(usdc, admin, operator, pauser, oracle, 2 days, MAX_PER_SETTLEMENT, DAILY_LIMIT);

        vm.startPrank(admin);
        vault.setCurrency(NGN, 2, true);
        vault.setPartner(
            offRampA, ISettlementVault.PartnerInfo({onRamp: false, offRamp: true, enabled: true, payoutCurrency: NGN})
        );
        vault.setPartner(
            offRampB, ISettlementVault.PartnerInfo({onRamp: false, offRamp: true, enabled: true, payoutCurrency: NGN})
        );
        vault.setPartner(
            onRampA,
            ISettlementVault.PartnerInfo({onRamp: true, offRamp: false, enabled: true, payoutCurrency: bytes3(0)})
        );
        vault.setPartner(
            onRampB,
            ISettlementVault.PartnerInfo({onRamp: true, offRamp: false, enabled: true, payoutCurrency: bytes3(0)})
        );
        vm.stopPrank();

        // A fresh reference rate is required now that the divergence check fails closed (issue #24).
        vm.prank(oracle);
        vault.setReferenceRate(NGN, NGN_RATE);

        usdc.mint(address(vault), 1_000_000 * USDC);
        usdc.mint(onRampA, 1_000_000 * USDC);
        vm.prank(onRampA);
        usdc.approve(address(vault), type(uint256).max);

        _lock(ref, AMOUNT);
    }

    function _lock(bytes32 r, uint256 amount) internal {
        ISettlementVault.QuoteInput memory q = ISettlementVault.QuoteInput({
            quoteId: keccak256(abi.encode("quote", r)),
            receiveCurrency: NGN,
            expiresAt: uint64(block.timestamp) + 90,
            rate: NGN_RATE,
            usdcAmount: amount,
            feeUsdc: FEE,
            receiveAmountMinor: FxMath.receiveAmount(amount, NGN_RATE, 2)
        });
        vm.prank(operator);
        vault.lockQuote(r, q);
    }

    // ------------------------------------------------------------------
    // What happens today
    // ------------------------------------------------------------------

    function test_settle_revertsWhenThePartnerIsBlocklisted_andStateIsUnchanged() public {
        usdc.setBlocklisted(offRampA, true);

        uint256 balanceBefore = usdc.balanceOf(address(vault));
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(MockBlocklistUSDC.Blacklisted.selector, offRampA));
        vault.settle(ref, offRampA, AMOUNT);

        // Nothing moved and nothing was recorded: the whole transaction reverted.
        assertEq(usdc.balanceOf(address(vault)), balanceBefore, "balance untouched");
        assertEq(uint8(vault.getSettlement(ref).status), uint8(ISettlementVault.Status.None), "status untouched");
        assertEq(vault.totalSettled(), 0, "counter untouched");
        assertEq(vault.remainingDailyLimit(), DAILY_LIMIT, "daily limit not consumed");
    }

    function test_fund_revertsWhenTheOnRampPartnerIsBlocklisted() public {
        usdc.setBlocklisted(onRampA, true);

        vm.prank(onRampA);
        vm.expectRevert(abi.encodeWithSelector(MockBlocklistUSDC.Blacklisted.selector, onRampA));
        vault.fund(ref, AMOUNT + FEE);

        assertEq(vault.getFunding(ref).fundedAt, 0, "no funding recorded");
        assertEq(vault.totalFunded(), 0);
    }

    function test_returnSettlement_stillWorksWhenTheDestinationOnRampIsBlocklisted() public {
        // The payout failed and the partner wants to hand the USDC back. Blocklisting the *refund destination*
        // must not trap the money at the partner.
        vm.prank(operator);
        vault.settle(ref, offRampA, AMOUNT);
        usdc.setBlocklisted(onRampA, true);

        vm.startPrank(offRampA);
        usdc.approve(address(vault), AMOUNT);
        vault.returnSettlement(ref);
        vm.stopPrank();

        assertEq(uint8(vault.getSettlement(ref).status), uint8(ISettlementVault.Status.Returned));
        assertEq(vault.reservedForRefunds(), AMOUNT, "funds are back and reserved");
    }

    function test_refund_revertsToABlocklistedDestination() public {
        vm.prank(operator);
        vault.settle(ref, offRampA, AMOUNT);
        vm.startPrank(offRampA);
        usdc.approve(address(vault), AMOUNT);
        vault.returnSettlement(ref);
        vm.stopPrank();

        usdc.setBlocklisted(onRampA, true);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(MockBlocklistUSDC.Blacklisted.selector, onRampA));
        vault.refund(ref, onRampA);

        assertEq(uint8(vault.getSettlement(ref).status), uint8(ISettlementVault.Status.Returned), "still returned");
        assertEq(vault.reservedForRefunds(), AMOUNT, "still reserved");
    }

    // ------------------------------------------------------------------
    // The mitigation: route around the blocklisted address
    // ------------------------------------------------------------------

    function test_settle_succeedsToASpareOffRampPartner() public {
        usdc.setBlocklisted(offRampA, true);

        vm.prank(operator);
        vault.settle(ref, offRampB, AMOUNT);

        assertEq(usdc.balanceOf(offRampB), AMOUNT, "paid the spare partner");
        assertEq(vault.getSettlement(ref).partner, offRampB);
    }

    function test_refund_succeedsToASpareOnRampPartner() public {
        vm.prank(operator);
        vault.settle(ref, offRampA, AMOUNT);
        vm.startPrank(offRampA);
        usdc.approve(address(vault), AMOUNT);
        vault.returnSettlement(ref);
        vm.stopPrank();

        usdc.setBlocklisted(onRampA, true);
        vm.prank(operator);
        vault.refund(ref, onRampB);

        assertEq(usdc.balanceOf(onRampB), AMOUNT, "refunded to the spare on-ramp");
        assertEq(vault.reservedForRefunds(), 0);
        assertEq(uint8(vault.getSettlement(ref).status), uint8(ISettlementVault.Status.Refunded));
    }

    function test_blockedRefCanBeCancelledAndReQuoted() public {
        usdc.setBlocklisted(offRampA, true);
        usdc.setBlocklisted(offRampB, true);

        // No route out today: unwind the lock so the ref is not left dangling.
        vm.prank(operator);
        vault.cancelQuote(ref);
        assertTrue(vault.getQuote(ref).cancelled);

        // The transfer is re-quoted under a NEW backend transfer id, never the old ref.
        usdc.setBlocklisted(offRampB, false);
        bytes32 ref2 = keccak256("kimana:transfer:blocklist_001_retry");
        _lock(ref2, AMOUNT);
        vm.prank(operator);
        vault.settle(ref2, offRampB, AMOUNT);
        assertEq(usdc.balanceOf(offRampB), AMOUNT);
    }

    // ------------------------------------------------------------------
    // The case with no on-chain remedy
    // ------------------------------------------------------------------

    function test_vaultItselfBlocklisted_haltsEverything() public {
        usdc.setBlocklisted(address(vault), true);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(MockBlocklistUSDC.Blacklisted.selector, address(vault)));
        vault.settle(ref, offRampA, AMOUNT);

        vm.prank(onRampA);
        vm.expectRevert(abi.encodeWithSelector(MockBlocklistUSDC.Blacklisted.selector, address(vault)));
        vault.fund(ref, AMOUNT + FEE);

        // Even the admin cannot rescue the float. This is a trust assumption on the issuer, not a bug:
        // recovery requires Circle. See docs/security/threat-model.md.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(MockBlocklistUSDC.Blacklisted.selector, address(vault)));
        vault.sweep(admin, AMOUNT);
    }
}
