// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {BaseTest} from "./BaseTest.sol";
import {SettlementVault} from "../src/SettlementVault.sol";
import {ISettlementVault} from "../src/interfaces/ISettlementVault.sol";
import {Mock18DecimalToken} from "./mocks/Mock18DecimalToken.sol";

contract SettlementVaultTest is BaseTest {
    bytes32 internal ref = keccak256(abi.encodePacked("kimana:transfer:", "txn_0001"));

    // ------------------------------------------------------------------
    // Deployment
    // ------------------------------------------------------------------

    function test_constructor_setsRolesAndLimits() public view {
        assertEq(address(vault.asset()), address(usdc));
        assertEq(vault.defaultAdmin(), admin);
        assertEq(vault.defaultAdminDelay(), ADMIN_DELAY);
        assertTrue(vault.hasRole(OPERATOR_ROLE, operator));
        assertTrue(vault.hasRole(PAUSER_ROLE, pauser));
        assertTrue(vault.hasRole(RATE_ORACLE_ROLE, rateOracle));
        assertFalse(vault.hasRole(OPERATOR_ROLE, address(this)), "deployer must hold no roles");
        assertEq(vault.OPERATOR_ROLE(), OPERATOR_ROLE);
        assertEq(vault.PAUSER_ROLE(), PAUSER_ROLE);
        assertEq(vault.DEFAULT_ADMIN_ROLE(), DEFAULT_ADMIN_ROLE);
        assertEq(vault.RATE_ORACLE_ROLE(), RATE_ORACLE_ROLE);
        assertEq(vault.maxPerSettlement(), MAX_PER_SETTLEMENT);
        assertEq(vault.dailyLimit(), DAILY_LIMIT);
    }

    function test_constructor_revertsOnZeroAddresses() public {
        vm.expectRevert(ISettlementVault.ZeroAddress.selector);
        new SettlementVault(IERC20(address(0)), admin, operator, pauser, rateOracle, ADMIN_DELAY, 1, 1);

        vm.expectRevert(ISettlementVault.ZeroAddress.selector);
        new SettlementVault(usdc, admin, address(0), pauser, rateOracle, ADMIN_DELAY, 1, 1);

        vm.expectRevert(ISettlementVault.ZeroAddress.selector);
        new SettlementVault(usdc, admin, operator, address(0), rateOracle, ADMIN_DELAY, 1, 1);
    }

    function test_constructor_rejectsNon6DecimalAsset() public {
        Mock18DecimalToken bridged = new Mock18DecimalToken();
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.UnsupportedAssetDecimals.selector, 18));
        new SettlementVault(bridged, admin, operator, pauser, rateOracle, ADMIN_DELAY, 1, 1);
    }

    function test_constructor_revertsOnInvalidLimits() public {
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.InvalidLimits.selector, 0, 10));
        new SettlementVault(usdc, admin, operator, pauser, rateOracle, ADMIN_DELAY, 0, 10);

        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.InvalidLimits.selector, 11, 10));
        new SettlementVault(usdc, admin, operator, pauser, rateOracle, ADMIN_DELAY, 11, 10);
    }

    // ------------------------------------------------------------------
    // settle
    // ------------------------------------------------------------------

    function test_settle_transfersToPartnerAndRecords() public {
        uint256 amount = 45_000 * USDC;
        _lock(ref, amount);

        vm.expectEmit(address(vault));
        emit ISettlementVault.SettlementInitiated(ref, ngnPartner, amount);
        _settle(ref, amount);

        assertEq(usdc.balanceOf(ngnPartner), amount);
        assertEq(usdc.balanceOf(address(vault)), INITIAL_FLOAT - amount);

        ISettlementVault.Settlement memory s = vault.getSettlement(ref);
        assertEq(s.partner, ngnPartner);
        assertEq(s.amount, amount);
        assertEq(uint8(s.status), uint8(ISettlementVault.Status.Settled));
        assertEq(s.settledAt, block.timestamp);
        assertEq(vault.totalSettled(), amount);
        assertEq(vault.remainingDailyLimit(), DAILY_LIMIT - amount);
    }

    function test_settle_revertsOnDuplicateRef() public {
        _settle(ref, 1 * USDC);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.RefAlreadyUsed.selector, ref));
        vault.settle(ref, ngnPartner, 1 * USDC);
    }

    function test_settle_revertsOnDuplicateRefEvenAfterRefund() public {
        _settle(ref, 1 * USDC);
        _return(ref);
        vm.prank(operator);
        vault.refund(ref, onRampPartner);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.RefAlreadyUsed.selector, ref));
        vault.settle(ref, ngnPartner, 1 * USDC);
    }

    function test_settle_revertsForNonOperator() public {
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, OPERATOR_ROLE)
        );
        vault.settle(ref, ngnPartner, 1 * USDC);
    }

    function test_settle_revertsForUnknownPartner() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.PartnerNotAllowed.selector, stranger));
        vault.settle(ref, stranger, 1 * USDC);
    }

    function test_settle_revertsForRemovedPartner() public {
        vm.prank(admin);
        vault.setPartner(ngnPartner, false);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.PartnerNotAllowed.selector, ngnPartner));
        vault.settle(ref, ngnPartner, 1 * USDC);
    }

    function test_settle_revertsOnZeroRefOrAmount() public {
        vm.startPrank(operator);
        vm.expectRevert(ISettlementVault.ZeroRef.selector);
        vault.settle(bytes32(0), ngnPartner, 1 * USDC);

        vm.expectRevert(ISettlementVault.ZeroAmount.selector);
        vault.settle(ref, ngnPartner, 0);
        vm.stopPrank();
    }

    function test_settle_revertsAbovePerSettlementLimit() public {
        uint256 amount = MAX_PER_SETTLEMENT + 1;
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(ISettlementVault.ExceedsPerSettlementLimit.selector, amount, MAX_PER_SETTLEMENT)
        );
        vault.settle(ref, ngnPartner, amount);
    }

    function test_settle_enforcesDailyLimit_andResetsNextDay() public {
        _settle(_ref("a"), MAX_PER_SETTLEMENT);
        _settle(_ref("b"), MAX_PER_SETTLEMENT);
        assertEq(vault.remainingDailyLimit(), 0);

        _lock(_ref("c"), 1 * USDC);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.ExceedsDailyLimit.selector, 1 * USDC, 0));
        vault.settle(_ref("c"), ngnPartner, 1 * USDC);

        vm.warp(block.timestamp + 1 days);
        assertEq(vault.remainingDailyLimit(), DAILY_LIMIT);
        _settle(_ref("c"), 1 * USDC);
    }

    function test_settle_dailyLimitNotRestoredByReturn() public {
        _settle(_ref("a"), MAX_PER_SETTLEMENT);
        _return(_ref("a"));
        assertEq(vault.remainingDailyLimit(), DAILY_LIMIT - MAX_PER_SETTLEMENT);
    }

    function test_settle_revertsWhenPaused() public {
        vm.prank(pauser);
        vault.pause();

        vm.prank(operator);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.settle(ref, ngnPartner, 1 * USDC);
    }

    function test_settle_revertsWhenVaultUnderfunded() public {
        vm.prank(admin);
        vault.sweep(admin, INITIAL_FLOAT);

        _lock(ref, 1 * USDC);
        vm.prank(operator);
        vm.expectRevert(); // ERC20InsufficientBalance bubbles up from the token
        vault.settle(ref, ngnPartner, 1 * USDC);
        assertEq(uint8(vault.getSettlement(ref).status), uint8(ISettlementVault.Status.None));
    }

    // ------------------------------------------------------------------
    // returnSettlement
    // ------------------------------------------------------------------

    function test_return_pullsFundsBackAndReserves() public {
        uint256 amount = 10_000 * USDC;
        _settle(ref, amount);

        vm.startPrank(ngnPartner);
        usdc.approve(address(vault), amount);
        vm.expectEmit(address(vault));
        emit ISettlementVault.SettlementReturned(ref, ngnPartner, amount);
        vault.returnSettlement(ref);
        vm.stopPrank();

        assertEq(usdc.balanceOf(ngnPartner), 0);
        assertEq(usdc.balanceOf(address(vault)), INITIAL_FLOAT);
        assertEq(uint8(vault.getSettlement(ref).status), uint8(ISettlementVault.Status.Returned));
        assertEq(vault.reservedForRefunds(), amount);
        assertEq(vault.totalReturned(), amount);
    }

    function test_return_onlySettlementPartner() public {
        _settle(ref, 1 * USDC);
        vm.prank(onRampPartner);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.NotSettlementPartner.selector, ref, onRampPartner));
        vault.returnSettlement(ref);
    }

    function test_return_revertsForUnknownRef() public {
        vm.prank(ngnPartner);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISettlementVault.InvalidStatus.selector,
                ref,
                ISettlementVault.Status.None,
                ISettlementVault.Status.Settled
            )
        );
        vault.returnSettlement(ref);
    }

    function test_return_cannotReturnTwice() public {
        _settle(ref, 1 * USDC);
        _return(ref);

        vm.prank(ngnPartner);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISettlementVault.InvalidStatus.selector,
                ref,
                ISettlementVault.Status.Returned,
                ISettlementVault.Status.Settled
            )
        );
        vault.returnSettlement(ref);
    }

    function test_return_revertsWithoutApproval() public {
        _settle(ref, 1 * USDC);
        vm.prank(ngnPartner);
        vm.expectRevert(); // ERC20InsufficientAllowance
        vault.returnSettlement(ref);
        assertEq(uint8(vault.getSettlement(ref).status), uint8(ISettlementVault.Status.Settled));
    }

    function test_return_allowedWhilePaused() public {
        _settle(ref, 1 * USDC);
        vm.prank(pauser);
        vault.pause();
        _return(ref);
        assertEq(uint8(vault.getSettlement(ref).status), uint8(ISettlementVault.Status.Returned));
    }

    // ------------------------------------------------------------------
    // refund
    // ------------------------------------------------------------------

    function test_refund_sendsReturnedFunds() public {
        uint256 amount = 2500 * USDC;
        _settle(ref, amount);
        _return(ref);

        vm.expectEmit(address(vault));
        emit ISettlementVault.SettlementRefunded(ref, onRampPartner, amount);
        vm.prank(operator);
        vault.refund(ref, onRampPartner);

        assertEq(usdc.balanceOf(onRampPartner), amount);
        assertEq(vault.reservedForRefunds(), 0);
        assertEq(vault.totalRefunded(), amount);
        assertEq(uint8(vault.getSettlement(ref).status), uint8(ISettlementVault.Status.Refunded));
    }

    function test_refund_revertsIfNotReturned() public {
        _settle(ref, 1 * USDC);
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISettlementVault.InvalidStatus.selector,
                ref,
                ISettlementVault.Status.Settled,
                ISettlementVault.Status.Returned
            )
        );
        vault.refund(ref, onRampPartner);
    }

    function test_refund_cannotRefundTwice() public {
        _settle(ref, 1 * USDC);
        _return(ref);
        vm.startPrank(operator);
        vault.refund(ref, onRampPartner);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISettlementVault.InvalidStatus.selector,
                ref,
                ISettlementVault.Status.Refunded,
                ISettlementVault.Status.Returned
            )
        );
        vault.refund(ref, onRampPartner);
        vm.stopPrank();
    }

    function test_refund_onlyToAllowlisted() public {
        _settle(ref, 1 * USDC);
        _return(ref);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.PartnerNotAllowed.selector, stranger));
        vault.refund(ref, stranger);
    }

    function test_refund_onlyOperator() public {
        _settle(ref, 1 * USDC);
        _return(ref);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, OPERATOR_ROLE)
        );
        vault.refund(ref, onRampPartner);
    }

    // ------------------------------------------------------------------
    // Admin
    // ------------------------------------------------------------------

    function test_setPartner_onlyAdmin() public {
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, operator, DEFAULT_ADMIN_ROLE
            )
        );
        vault.setPartner(stranger, true);
    }

    function test_setPartner_emitsAndRejectsZero() public {
        vm.startPrank(admin);
        vm.expectEmit(address(vault));
        emit ISettlementVault.PartnerUpdated(stranger, true);
        vault.setPartner(stranger, true);
        assertTrue(vault.isPartner(stranger));

        vm.expectRevert(ISettlementVault.ZeroAddress.selector);
        vault.setPartner(address(0), true);
        vm.stopPrank();
    }

    function test_setLimits() public {
        vm.prank(admin);
        vm.expectEmit(address(vault));
        emit ISettlementVault.LimitsUpdated(10 * USDC, 20 * USDC);
        vault.setLimits(10 * USDC, 20 * USDC);
        assertEq(vault.maxPerSettlement(), 10 * USDC);
        assertEq(vault.dailyLimit(), 20 * USDC);
    }

    function test_setLimits_loweringBelowUsageBlocksSettlement() public {
        _settle(_ref("a"), 30 * USDC);
        vm.prank(admin);
        vault.setLimits(10 * USDC, 20 * USDC);
        assertEq(vault.remainingDailyLimit(), 0);
    }

    function test_sweep_cannotTouchReservedFunds() public {
        uint256 amount = 5000 * USDC;
        _settle(ref, amount);
        _return(ref);

        uint256 free = INITIAL_FLOAT - amount;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.InsufficientFreeBalance.selector, free + 1, free));
        vault.sweep(admin, free + 1);

        vm.prank(admin);
        vault.sweep(admin, free);
        assertEq(usdc.balanceOf(address(vault)), amount);

        vm.prank(operator);
        vault.refund(ref, onRampPartner);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    function test_sweep_revertsOnZeroInputs() public {
        vm.startPrank(admin);
        vm.expectRevert(ISettlementVault.ZeroAddress.selector);
        vault.sweep(address(0), 1);
        vm.expectRevert(ISettlementVault.ZeroAmount.selector);
        vault.sweep(admin, 0);
        vm.stopPrank();
    }

    function test_sweep_onlyAdmin() public {
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, operator, DEFAULT_ADMIN_ROLE
            )
        );
        vault.sweep(operator, 1);
    }

    function test_pause_onlyPauser_unpause_onlyAdmin() public {
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, operator, PAUSER_ROLE)
        );
        vault.pause();

        vm.prank(pauser);
        vault.pause();
        assertTrue(vault.paused());

        vm.prank(pauser);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, pauser, DEFAULT_ADMIN_ROLE)
        );
        vault.unpause();

        vm.prank(admin);
        vault.unpause();
        assertFalse(vault.paused());
    }

    function test_adminTransfer_isTwoStepWithDelay() public {
        address newAdmin = makeAddr("new Safe");
        vm.prank(admin);
        vault.beginDefaultAdminTransfer(newAdmin);

        vm.prank(newAdmin);
        vm.expectRevert(); // delay not elapsed
        vault.acceptDefaultAdminTransfer();

        vm.warp(block.timestamp + ADMIN_DELAY + 1);
        vm.prank(newAdmin);
        vault.acceptDefaultAdminTransfer();
        assertEq(vault.defaultAdmin(), newAdmin);
    }

    // ------------------------------------------------------------------
    // Fuzz
    // ------------------------------------------------------------------

    function testFuzz_settle_respectsLimits(uint256 amount) public {
        amount = bound(amount, MIN_AMOUNT, DAILY_LIMIT * 2);
        if (amount > MAX_PER_SETTLEMENT) {
            vm.prank(operator);
            vm.expectRevert(
                abi.encodeWithSelector(ISettlementVault.ExceedsPerSettlementLimit.selector, amount, MAX_PER_SETTLEMENT)
            );
            vault.settle(ref, ngnPartner, amount);
        } else {
            _settle(ref, amount);
            assertEq(usdc.balanceOf(ngnPartner), amount);
        }
    }

    function testFuzz_fullLifecycle_conservesFunds(uint256 amount, string calldata transferId) public {
        amount = bound(amount, MIN_AMOUNT, MAX_PER_SETTLEMENT);
        bytes32 r = _ref(transferId);

        _settle(r, amount);
        _return(r);
        vm.prank(operator);
        vault.refund(r, onRampPartner);

        assertEq(usdc.balanceOf(address(vault)) + usdc.balanceOf(onRampPartner), INITIAL_FLOAT);
        assertEq(vault.reservedForRefunds(), 0);
    }
}
