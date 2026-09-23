// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SettlementVault} from "../../src/SettlementVault.sol";
import {ISettlementVault} from "../../src/interfaces/ISettlementVault.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {FxMath} from "../../src/libraries/FxMath.sol";

/// @notice Drives random but valid sequences of settle / return / refund / sweep / warp and tracks ghost state.
contract SettlementVaultHandler is Test {
    SettlementVault internal vault;
    MockUSDC internal usdc;
    address internal operator;
    address internal admin;
    address internal partner;
    address internal oracle;
    address internal refundTo;

    bytes32[] public refs;
    bytes32[] public cancelledRefs;
    uint256 public ghostSettled;
    uint256 public ghostReturned;
    uint256 public ghostRefunded;
    uint256 public ghostSwept;
    uint256 public ghostTopUps;
    uint256 public ghostFunded;
    uint256 public ghostFundingReturned;
    uint256 public ghostFundingSettled;
    bytes32[] internal fundedRefs;
    uint256 internal nonce;

    constructor(
        SettlementVault vault_,
        MockUSDC usdc_,
        address operator_,
        address admin_,
        address partner_,
        address refundTo_,
        address oracle_
    ) {
        vault = vault_;
        usdc = usdc_;
        operator = operator_;
        admin = admin_;
        partner = partner_;
        refundTo = refundTo_;
        oracle = oracle_;
    }

    /// @dev The oracle publishes continuously in production; without this, `warp` would make every lock
    ///      revert with ReferenceRateUnavailable and the handler would stop exercising the contract.
    /// @dev Mirrors the contract's own solvency guard, so the handler exercises success paths rather than
    ///      bouncing off a revert it could have predicted.
    function _spendable() internal view returns (uint256) {
        uint256 encumbered = vault.reservedForRefunds() + vault.reservedForFunding();
        uint256 balance = usdc.balanceOf(address(vault));
        return balance > encumbered ? balance - encumbered : 0;
    }

    function _refreshRate() internal {
        vm.prank(oracle);
        vault.setReferenceRate("NGN", 164_525_000_000);
    }

    function fundedRefCount() external view returns (uint256) {
        return fundedRefs.length;
    }

    function refCount() external view returns (uint256) {
        return refs.length;
    }

    function settle(uint256 amount) external {
        amount = bound(amount, 10_000, vault.maxPerSettlement());
        if (amount > vault.remainingDailyLimit()) return;
        if (amount > _spendable()) return;

        _refreshRate();
        bytes32 ref = keccak256(abi.encode("handler", nonce++));
        ISettlementVault.QuoteInput memory q = ISettlementVault.QuoteInput({
            quoteId: keccak256(abi.encode("quote", ref)),
            receiveCurrency: "NGN",
            expiresAt: uint64(block.timestamp) + 60,
            rate: 164_525_000_000,
            usdcAmount: amount,
            feeUsdc: 0,
            receiveAmountMinor: FxMath.receiveAmount(amount, 164_525_000_000, 2)
        });
        vm.startPrank(operator);
        vault.lockQuote(ref, q);
        vault.settle(ref, partner, amount);
        vm.stopPrank();
        refs.push(ref);
        ghostSettled += amount;
    }

    /// @dev Locks a quote carrying a fee, has the on-ramp partner fund it, then settles it.
    function fundAndSettle(uint256 amount) external {
        amount = bound(amount, 10_000, vault.maxPerSettlement());
        if (amount > vault.remainingDailyLimit()) return;
        if (amount > _spendable()) return;

        uint256 fee = amount / 100;
        uint256 gross = amount + fee;
        _refreshRate();
        bytes32 ref = keccak256(abi.encode("handler-fund", nonce++));
        ISettlementVault.QuoteInput memory q = ISettlementVault.QuoteInput({
            quoteId: keccak256(abi.encode("quote", ref)),
            receiveCurrency: "NGN",
            expiresAt: uint64(block.timestamp) + 60,
            rate: 164_525_000_000,
            usdcAmount: amount,
            feeUsdc: fee,
            receiveAmountMinor: FxMath.receiveAmount(amount, 164_525_000_000, 2)
        });
        vm.prank(operator);
        vault.lockQuote(ref, q);

        usdc.mint(refundTo, gross);
        vm.startPrank(refundTo);
        usdc.approve(address(vault), gross);
        vault.fund(ref, gross);
        vm.stopPrank();
        ghostFunded += gross;

        vm.prank(operator);
        vault.settle(ref, partner, amount);
        refs.push(ref);
        ghostSettled += amount;
        ghostFundingSettled += gross;
    }

    /// @dev Funds a ref and leaves it outstanding, so the funding reserve is non-zero across other actions.
    function fundOnly(uint256 amount) external {
        amount = bound(amount, 10_000, vault.maxPerSettlement());
        uint256 fee = amount / 100;
        uint256 gross = amount + fee;

        _refreshRate();
        bytes32 ref = keccak256(abi.encode("handler-fundonly", nonce++));
        ISettlementVault.QuoteInput memory q = ISettlementVault.QuoteInput({
            quoteId: keccak256(abi.encode("quote", ref)),
            receiveCurrency: "NGN",
            expiresAt: uint64(block.timestamp) + 60,
            rate: 164_525_000_000,
            usdcAmount: amount,
            feeUsdc: fee,
            receiveAmountMinor: FxMath.receiveAmount(amount, 164_525_000_000, 2)
        });
        vm.prank(operator);
        vault.lockQuote(ref, q);

        usdc.mint(refundTo, gross);
        vm.startPrank(refundTo);
        usdc.approve(address(vault), gross);
        vault.fund(ref, gross);
        vm.stopPrank();

        ghostFunded += gross;
        fundedRefs.push(ref);
    }

    /// @dev Cancels a funded ref and returns the capital, exercising the issue #23 path.
    function cancelAndReturnFunding(uint256 index) external {
        if (fundedRefs.length == 0) return;
        index = bound(index, 0, fundedRefs.length - 1);
        bytes32 ref = fundedRefs[index];

        ISettlementVault.Funding memory f = vault.getFunding(ref);
        if (f.returnedAt != 0) return;
        if (vault.getSettlement(ref).status != ISettlementVault.Status.None) return;

        if (!vault.getQuote(ref).cancelled) {
            vm.prank(operator);
            vault.cancelQuote(ref);
        }
        vault.returnFunding(ref);
        ghostFundingReturned += f.amount;
    }

    /// @dev Locks a quote and cancels it; the ref must never become settleable.
    function lockAndCancel(uint256 amount) external {
        amount = bound(amount, 10_000, vault.maxPerSettlement());
        bytes32 ref = keccak256(abi.encode("cancelled", nonce++));
        ISettlementVault.QuoteInput memory q = ISettlementVault.QuoteInput({
            quoteId: keccak256(abi.encode("quote", ref)),
            receiveCurrency: "NGN",
            expiresAt: uint64(block.timestamp) + 60,
            rate: 164_525_000_000,
            usdcAmount: amount,
            feeUsdc: 0,
            receiveAmountMinor: FxMath.receiveAmount(amount, 164_525_000_000, 2)
        });
        vm.startPrank(operator);
        vault.lockQuote(ref, q);
        vault.cancelQuote(ref);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.QuoteIsCancelled.selector, ref));
        vault.settle(ref, partner, amount);
        vm.stopPrank();
        cancelledRefs.push(ref);
    }

    /// @dev A second lock with a reused quote id must always fail.
    function reuseQuoteId(uint256 index) external {
        if (refs.length == 0) return;
        bytes32 used = refs[index % refs.length];
        ISettlementVault.LockedQuote memory l = vault.getQuote(used);
        bytes32 fresh = keccak256(abi.encode("reuse", nonce++));
        ISettlementVault.QuoteInput memory q = ISettlementVault.QuoteInput({
            quoteId: l.quoteId,
            receiveCurrency: "NGN",
            expiresAt: uint64(block.timestamp) + 60,
            rate: l.rate,
            usdcAmount: l.usdcAmount,
            feeUsdc: 0,
            receiveAmountMinor: l.receiveAmountMinor
        });
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.QuoteAlreadyUsed.selector, l.quoteId));
        vault.lockQuote(fresh, q);
    }

    function cancelledCount() external view returns (uint256) {
        return cancelledRefs.length;
    }

    function settleDuplicate(uint256 index) external {
        if (refs.length == 0) return;
        bytes32 ref = refs[index % refs.length];
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(ISettlementVault.RefAlreadyUsed.selector, ref));
        vault.settle(ref, partner, 1);
    }

    function returnSettlement(uint256 index) external {
        if (refs.length == 0) return;
        bytes32 ref = refs[index % refs.length];
        ISettlementVault.Settlement memory s = vault.getSettlement(ref);
        if (s.status != ISettlementVault.Status.Settled) return;

        vm.startPrank(partner);
        usdc.approve(address(vault), s.amount);
        vault.returnSettlement(ref);
        vm.stopPrank();
        ghostReturned += s.amount;
    }

    function refund(uint256 index) external {
        if (refs.length == 0) return;
        bytes32 ref = refs[index % refs.length];
        ISettlementVault.Settlement memory s = vault.getSettlement(ref);
        if (s.status != ISettlementVault.Status.Returned) return;

        vm.prank(operator);
        vault.refund(ref, refundTo);
        ghostRefunded += s.amount;
    }

    function sweep(uint256 amount) external {
        uint256 free = usdc.balanceOf(address(vault)) - vault.reservedForRefunds();
        if (free == 0) return;
        amount = bound(amount, 1, free);
        vm.prank(admin);
        vault.sweep(admin, amount);
        ghostSwept += amount;
    }

    function topUp(uint256 amount) external {
        amount = bound(amount, 1, 1_000_000e6);
        usdc.mint(address(vault), amount);
        ghostTopUps += amount;
    }

    function warp(uint256 secondsForward) external {
        vm.warp(block.timestamp + bound(secondsForward, 1, 2 days));
    }
}
