// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {BaseTest} from "./BaseTest.sol";
import {ISettlementVault} from "../src/interfaces/ISettlementVault.sol";

/// @notice Issue #2 (inbound USDC accounting) and issue #8 (partner types and payout currencies).
contract FundingAndPartnersTest is BaseTest {
    bytes32 internal ref = _ref("fund_001");
    uint256 internal constant AMOUNT = 1000 * USDC;
    uint256 internal constant FEE = 25 * USDC;
    uint256 internal constant GROSS = AMOUNT + FEE;

    bytes3 internal constant GHS = "GHS";
    bytes3 internal constant ANY = bytes3(0);

    function setUp() public override {
        super.setUp();
        usdc.mint(onRampPartner, 10_000_000 * USDC);
        vm.prank(onRampPartner);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ------------------------------------------------------------------
    // fund(): happy path
    // ------------------------------------------------------------------

    function test_fund_recordsDepositAgainstTheLockedQuote() public {
        _lock(ref, AMOUNT);
        uint256 vaultBefore = usdc.balanceOf(address(vault));

        vm.expectEmit(address(vault));
        emit ISettlementVault.SettlementFunded(ref, onRampPartner, GROSS, FEE);
        vm.prank(onRampPartner);
        vault.fund(ref, GROSS);

        ISettlementVault.Funding memory f = vault.getFunding(ref);
        assertEq(f.partner, onRampPartner, "funder");
        assertEq(f.amount, GROSS, "gross amount");
        assertEq(f.fundedAt, uint64(block.timestamp), "fundedAt");
        assertEq(usdc.balanceOf(address(vault)) - vaultBefore, GROSS, "vault received gross");
        assertEq(vault.totalFunded(), GROSS, "totalFunded");
    }

    function test_fund_thenSettle_leavesTheFeeInTheVault() public {
        _lock(ref, AMOUNT);
        vm.prank(onRampPartner);
        vault.fund(ref, GROSS);

        uint256 before = usdc.balanceOf(address(vault));
        vm.prank(operator);
        vault.settle(ref, ngnPartner, AMOUNT);

        assertEq(before - usdc.balanceOf(address(vault)), AMOUNT, "only the net amount leaves");
        // The fee is free balance, so admin can sweep it.
        vm.prank(admin);
        vault.sweep(admin, FEE);
        assertEq(usdc.balanceOf(admin), FEE, "fee swept");
    }

    function testFuzz_fund_acceptsExactlyGross(uint256 amount) public {
        amount = bound(amount, MIN_AMOUNT, MAX_PER_SETTLEMENT);
        bytes32 r = _ref("fuzz_fund");
        _lock(r, amount);

        vm.prank(onRampPartner);
        vault.fund(r, amount + FEE);
        assertEq(vault.getFunding(r).amount, amount + FEE);
    }

    // ------------------------------------------------------------------
    // fund(): rejections
    // ------------------------------------------------------------------

    function test_fund_rejectsNonPartner() public {
        _lock(ref, AMOUNT);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.PartnerNotAllowed.selector, stranger));
        vault.fund(ref, GROSS);
    }

    function test_fund_rejectsOffRampOnlyPartner() public {
        _lock(ref, AMOUNT);
        vm.prank(ngnPartner);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.PartnerNotAllowed.selector, ngnPartner));
        vault.fund(ref, GROSS);
    }

    function test_fund_rejectsDisabledOnRampPartner() public {
        _lock(ref, AMOUNT);
        vm.prank(admin);
        vault.setPartner(onRampPartner, pDisabled());

        vm.prank(onRampPartner);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.PartnerNotAllowed.selector, onRampPartner));
        vault.fund(ref, GROSS);
    }

    function test_fund_requiresALockedQuote() public {
        vm.prank(onRampPartner);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.QuoteNotLocked.selector, ref));
        vault.fund(ref, GROSS);
    }

    function test_fund_rejectsCancelledQuote() public {
        _lock(ref, AMOUNT);
        vm.prank(operator);
        vault.cancelQuote(ref);

        vm.prank(onRampPartner);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.QuoteIsCancelled.selector, ref));
        vault.fund(ref, GROSS);
    }

    function test_fund_rejectsWrongAmount() public {
        _lock(ref, AMOUNT);
        vm.startPrank(onRampPartner);

        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.FundAmountMismatch.selector, ref, AMOUNT, GROSS));
        vault.fund(ref, AMOUNT); // forgot the fee

        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.FundAmountMismatch.selector, ref, GROSS + 1, GROSS));
        vault.fund(ref, GROSS + 1); // one unit too much

        vm.stopPrank();
    }

    function test_fund_rejectsDoubleFunding() public {
        _lock(ref, AMOUNT);
        vm.startPrank(onRampPartner);
        vault.fund(ref, GROSS);

        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.AlreadyFunded.selector, ref));
        vault.fund(ref, GROSS);
        vm.stopPrank();
    }

    function test_fund_rejectsAfterSettlement() public {
        _lock(ref, AMOUNT);
        vm.prank(operator);
        vault.settle(ref, ngnPartner, AMOUNT);

        vm.prank(onRampPartner);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.RefAlreadyUsed.selector, ref));
        vault.fund(ref, GROSS);
    }

    function test_fund_revertsWhenPaused() public {
        _lock(ref, AMOUNT);
        vm.prank(pauser);
        vault.pause();

        vm.prank(onRampPartner);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.fund(ref, GROSS);
    }

    // ------------------------------------------------------------------
    // requireFunding
    // ------------------------------------------------------------------

    function test_settle_doesNotRequireFundingByDefault() public {
        assertFalse(vault.requireFunding(), "default off");
        _lock(ref, AMOUNT);
        vm.prank(operator);
        vault.settle(ref, ngnPartner, AMOUNT);
        assertEq(uint8(vault.getSettlement(ref).status), uint8(ISettlementVault.Status.Settled));
    }

    function test_setRequireFunding_onlyAdminAndEmits() public {
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, operator, DEFAULT_ADMIN_ROLE
            )
        );
        vault.setRequireFunding(true);

        vm.expectEmit(address(vault));
        emit ISettlementVault.RequireFundingUpdated(true);
        vm.prank(admin);
        vault.setRequireFunding(true);
        assertTrue(vault.requireFunding());
    }

    function test_settle_revertsWhenFundingRequiredButMissing() public {
        vm.prank(admin);
        vault.setRequireFunding(true);
        _lock(ref, AMOUNT);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.NotFunded.selector, ref));
        vault.settle(ref, ngnPartner, AMOUNT);
    }

    function test_settle_succeedsWhenFundingRequiredAndPresent() public {
        vm.prank(admin);
        vault.setRequireFunding(true);
        _lock(ref, AMOUNT);

        vm.prank(onRampPartner);
        vault.fund(ref, GROSS);

        vm.prank(operator);
        vault.settle(ref, ngnPartner, AMOUNT);
        assertEq(uint8(vault.getSettlement(ref).status), uint8(ISettlementVault.Status.Settled));
    }

    // ------------------------------------------------------------------
    // Issue #22: a partner's deposit is not sweepable treasury float
    // ------------------------------------------------------------------

    function test_fund_reservesTheDeposit() public {
        assertEq(vault.reservedForFunding(), 0);
        _lock(ref, AMOUNT);
        vm.prank(onRampPartner);
        vault.fund(ref, GROSS);
        assertEq(vault.reservedForFunding(), GROSS, "deposit is encumbered");
    }

    function test_sweep_cannotTakeFundedCapital() public {
        _lock(ref, AMOUNT);
        vm.prank(onRampPartner);
        vault.fund(ref, GROSS);

        uint256 balance = usdc.balanceOf(address(vault));
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(ISettlementVault.InsufficientFreeBalance.selector, balance, balance - GROSS)
        );
        vault.sweep(admin, balance);
    }

    function test_sweep_canStillTakeGenuinelyFreeFloat() public {
        _lock(ref, AMOUNT);
        vm.prank(onRampPartner);
        vault.fund(ref, GROSS);

        uint256 free = usdc.balanceOf(address(vault)) - GROSS;
        vm.prank(admin);
        vault.sweep(admin, free);
        assertEq(usdc.balanceOf(admin), free);
        // The deposit is still there, so the settlement it was made for can still be honoured.
        assertEq(usdc.balanceOf(address(vault)), GROSS);

        vm.prank(operator);
        vault.settle(ref, ngnPartner, AMOUNT);
        assertEq(usdc.balanceOf(ngnPartner), AMOUNT);
    }

    function test_settle_releasesTheFundingReserve() public {
        _lock(ref, AMOUNT);
        vm.prank(onRampPartner);
        vault.fund(ref, GROSS);
        vm.prank(operator);
        vault.settle(ref, ngnPartner, AMOUNT);

        assertEq(vault.reservedForFunding(), 0, "no longer encumbered");
        // The fee is now genuinely free and can be swept.
        vm.prank(admin);
        vault.sweep(admin, FEE);
        assertEq(usdc.balanceOf(admin), FEE);
    }

    function test_sweep_respectsBothReservesTogether() public {
        // One ref funded and awaiting settlement, another returned and awaiting refund.
        _lock(ref, AMOUNT);
        vm.prank(onRampPartner);
        vault.fund(ref, GROSS);

        bytes32 other = _ref("both_reserves");
        _lock(other, AMOUNT);
        vm.prank(operator);
        vault.settle(other, ngnPartner, AMOUNT);
        vm.startPrank(ngnPartner);
        usdc.approve(address(vault), AMOUNT);
        vault.returnSettlement(other);
        vm.stopPrank();

        assertEq(vault.reservedForFunding(), GROSS);
        assertEq(vault.reservedForRefunds(), AMOUNT);

        uint256 balance = usdc.balanceOf(address(vault));
        uint256 free = balance - GROSS - AMOUNT;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.InsufficientFreeBalance.selector, free + 1, free));
        vault.sweep(admin, free + 1);

        vm.prank(admin);
        vault.sweep(admin, free);
    }

    /// @dev Found by the new invariant: fencing `sweep` alone was not enough. A settlement for one transfer
    ///      could still spend the deposit made for another, leaving the vault unable to honour it.
    function test_settle_cannotSpendAnotherTransfersDeposit() public {
        // Take the house float out of the picture so only the deposit is left.
        uint256 houseFloat = usdc.balanceOf(address(vault));
        vm.prank(admin);
        vault.sweep(admin, houseFloat);

        bytes32 funded = _ref("funded_one");
        _lock(funded, AMOUNT);
        vm.prank(onRampPartner);
        vault.fund(funded, GROSS);
        assertEq(usdc.balanceOf(address(vault)), GROSS, "only the deposit remains");

        // A different, unfunded transfer must not be able to spend it.
        bytes32 other = _ref("unfunded_other");
        _lock(other, AMOUNT);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.InsufficientFreeBalance.selector, AMOUNT, 0));
        vault.settle(other, ngnPartner, AMOUNT);

        // The transfer that was actually funded still settles.
        vm.prank(operator);
        vault.settle(funded, ngnPartner, AMOUNT);
        assertEq(usdc.balanceOf(ngnPartner), AMOUNT);
    }

    function test_settle_canSpendItsOwnDeposit() public {
        uint256 houseFloat = usdc.balanceOf(address(vault));
        vm.prank(admin);
        vault.sweep(admin, houseFloat);

        _lock(ref, AMOUNT);
        vm.prank(onRampPartner);
        vault.fund(ref, GROSS);

        vm.prank(operator);
        vault.settle(ref, ngnPartner, AMOUNT);
        assertEq(usdc.balanceOf(ngnPartner), AMOUNT);
        assertEq(vault.reservedForFunding(), 0);
        assertEq(usdc.balanceOf(address(vault)), FEE, "the fee is what is left");
    }

    // ------------------------------------------------------------------
    // Issue #23: funded capital can always find its way home
    // ------------------------------------------------------------------

    function test_returnFunding_afterCancelledQuote() public {
        _lock(ref, AMOUNT);
        vm.prank(onRampPartner);
        vault.fund(ref, GROSS);
        uint256 before = usdc.balanceOf(onRampPartner);

        vm.prank(operator);
        vault.cancelQuote(ref);

        vm.expectEmit(address(vault));
        emit ISettlementVault.FundingReturned(ref, onRampPartner, GROSS);
        vault.returnFunding(ref);

        assertEq(usdc.balanceOf(onRampPartner) - before, GROSS, "partner made whole");
        assertEq(vault.reservedForFunding(), 0);
        assertEq(vault.totalFundingReturned(), GROSS);
        assertEq(vault.getFunding(ref).returnedAt, uint64(block.timestamp));
    }

    function test_returnFunding_afterTheLockIsTooOldToSettle() public {
        _lock(ref, AMOUNT);
        vm.prank(onRampPartner);
        vault.fund(ref, GROSS);

        // The operator abandoned the transfer without cancelling. Capital must not be stuck.
        vm.warp(block.timestamp + 7 days + 1);
        vault.returnFunding(ref);
        assertEq(vault.reservedForFunding(), 0);
    }

    function test_returnFunding_revertsWhileTheTransferCanStillSettle() public {
        _lock(ref, AMOUNT);
        vm.prank(onRampPartner);
        vault.fund(ref, GROSS);

        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.FundingStillSettleable.selector, ref));
        vault.returnFunding(ref);
    }

    function test_returnFunding_revertsWhenNothingWasFunded() public {
        _lock(ref, AMOUNT);
        vm.prank(operator);
        vault.cancelQuote(ref);

        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.NotFunded.selector, ref));
        vault.returnFunding(ref);
    }

    function test_returnFunding_cannotBeDoneTwice() public {
        _lock(ref, AMOUNT);
        vm.prank(onRampPartner);
        vault.fund(ref, GROSS);
        vm.prank(operator);
        vault.cancelQuote(ref);
        vault.returnFunding(ref);

        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.FundingAlreadyReturned.selector, ref));
        vault.returnFunding(ref);
    }

    function test_returnFunding_revertsAfterSettlement() public {
        _lock(ref, AMOUNT);
        vm.prank(onRampPartner);
        vault.fund(ref, GROSS);
        vm.prank(operator);
        vault.settle(ref, ngnPartner, AMOUNT);

        vm.warp(block.timestamp + 7 days + 1);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.RefAlreadyUsed.selector, ref));
        vault.returnFunding(ref);
    }

    /// @dev A pause must not trap a partner's capital — that is the bug this whole path exists to prevent.
    function test_returnFunding_worksWhilePaused() public {
        _lock(ref, AMOUNT);
        vm.prank(onRampPartner);
        vault.fund(ref, GROSS);
        vm.prank(operator);
        vault.cancelQuote(ref);
        vm.prank(pauser);
        vault.pause();

        uint256 before = usdc.balanceOf(onRampPartner);
        vault.returnFunding(ref);
        assertEq(usdc.balanceOf(onRampPartner) - before, GROSS);
    }

    /// @dev Anyone may trigger it; the money can only ever go back to the address that deposited it.
    function test_returnFunding_byAStranger_paysTheOriginalFunder() public {
        _lock(ref, AMOUNT);
        vm.prank(onRampPartner);
        vault.fund(ref, GROSS);
        vm.prank(operator);
        vault.cancelQuote(ref);

        uint256 before = usdc.balanceOf(onRampPartner);
        vm.prank(stranger);
        vault.returnFunding(ref);

        assertEq(usdc.balanceOf(onRampPartner) - before, GROSS, "original funder paid");
        assertEq(usdc.balanceOf(stranger), 0, "caller gains nothing");
    }

    function test_returnFunding_releasesTheReserveForSweep() public {
        _lock(ref, AMOUNT);
        vm.prank(onRampPartner);
        vault.fund(ref, GROSS);
        vm.prank(operator);
        vault.cancelQuote(ref);
        vault.returnFunding(ref);

        uint256 balance = usdc.balanceOf(address(vault));
        vm.prank(admin);
        vault.sweep(admin, balance);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    // ------------------------------------------------------------------
    // Partner types (#8)
    // ------------------------------------------------------------------

    function test_settle_rejectsOnRampOnlyPartner() public {
        _lock(ref, AMOUNT);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.PartnerNotAllowed.selector, onRampPartner));
        vault.settle(ref, onRampPartner, AMOUNT);
    }

    function test_settle_rejectsPartnerWhoPaysADifferentCurrency() public {
        address ghsPartner = makeAddr("GHS off-ramp partner");
        vm.prank(admin);
        vault.setPartner(ghsPartner, pOffRamp(GHS));

        _lock(ref, AMOUNT);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.PartnerCurrencyMismatch.selector, ghsPartner, GHS, NGN));
        vault.settle(ref, ghsPartner, AMOUNT);
    }

    function test_settle_allowsPartnerWithNoCurrencyRestriction() public {
        address anyPartner = makeAddr("multi-currency off-ramp partner");
        vm.prank(admin);
        vault.setPartner(anyPartner, pOffRamp(ANY));

        _lock(ref, AMOUNT);
        vm.prank(operator);
        vault.settle(ref, anyPartner, AMOUNT);
        assertEq(usdc.balanceOf(anyPartner), AMOUNT);
    }

    function test_refund_rejectsOffRampOnlyDestination() public {
        _lock(ref, AMOUNT);
        vm.prank(operator);
        vault.settle(ref, ngnPartner, AMOUNT);
        _return(ref);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.PartnerNotAllowed.selector, ngnPartner));
        vault.refund(ref, ngnPartner);
    }

    function test_refund_allowsOnRampDestination() public {
        _lock(ref, AMOUNT);
        vm.prank(operator);
        vault.settle(ref, ngnPartner, AMOUNT);
        _return(ref);

        vm.prank(operator);
        vault.refund(ref, onRampPartner);
        assertEq(uint8(vault.getSettlement(ref).status), uint8(ISettlementVault.Status.Refunded));
        assertEq(vault.reservedForRefunds(), 0);
    }

    function test_partnerCanBeBothRamps() public {
        address both = makeAddr("both ramps");
        vm.prank(admin);
        vault.setPartner(both, pBoth());
        usdc.mint(both, GROSS);
        vm.prank(both);
        usdc.approve(address(vault), GROSS);

        _lock(ref, AMOUNT);
        vm.prank(both);
        vault.fund(ref, GROSS);
        vm.prank(operator);
        vault.settle(ref, both, AMOUNT);
        assertEq(vault.getFunding(ref).partner, both);
    }

    // ------------------------------------------------------------------
    // setPartner validation
    // ------------------------------------------------------------------

    function test_setPartner_rejectsEnabledPartnerWithNoRamp() public {
        vm.prank(admin);
        vm.expectRevert(ISettlementVault.InvalidPartnerConfig.selector);
        vault.setPartner(
            stranger, ISettlementVault.PartnerInfo({onRamp: false, offRamp: false, enabled: true, payoutCurrency: ANY})
        );
    }

    function test_setPartner_rejectsPayoutCurrencyOnNonOffRamp() public {
        vm.prank(admin);
        vm.expectRevert(ISettlementVault.InvalidPartnerConfig.selector);
        vault.setPartner(
            stranger, ISettlementVault.PartnerInfo({onRamp: true, offRamp: false, enabled: true, payoutCurrency: NGN})
        );
    }

    function test_setPartner_rejectsMalformedCurrencyCode() public {
        bytes3 lower = "ngn";
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.CurrencyNotSupported.selector, lower));
        vault.setPartner(stranger, pOffRamp(lower));
    }

    function test_setPartner_allowsDisabledWithNoRamp() public {
        vm.prank(admin);
        vault.setPartner(ngnPartner, pDisabled());
        assertFalse(vault.isPartner(ngnPartner));
        ISettlementVault.PartnerInfo memory p = vault.getPartner(ngnPartner);
        assertFalse(p.onRamp);
        assertFalse(p.offRamp);
    }

    function test_getPartner_returnsTheStoredConfig() public view {
        ISettlementVault.PartnerInfo memory p = vault.getPartner(ngnPartner);
        assertTrue(p.enabled);
        assertTrue(p.offRamp);
        assertFalse(p.onRamp);
        assertEq(p.payoutCurrency, NGN);
        assertTrue(vault.isPartner(ngnPartner));
    }
}
