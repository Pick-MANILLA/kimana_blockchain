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
    address internal refundTo;

    bytes32[] public refs;
    bytes32[] public cancelledRefs;
    uint256 public ghostSettled;
    uint256 public ghostReturned;
    uint256 public ghostRefunded;
    uint256 public ghostSwept;
    uint256 public ghostTopUps;
    uint256 internal nonce;

    constructor(
        SettlementVault vault_,
        MockUSDC usdc_,
        address operator_,
        address admin_,
        address partner_,
        address refundTo_
    ) {
        vault = vault_;
        usdc = usdc_;
        operator = operator_;
        admin = admin_;
        partner = partner_;
        refundTo = refundTo_;
    }

    function refCount() external view returns (uint256) {
        return refs.length;
    }

    function settle(uint256 amount) external {
        amount = bound(amount, 10_000, vault.maxPerSettlement());
        if (amount > vault.remainingDailyLimit()) return;
        if (amount > usdc.balanceOf(address(vault)) - vault.reservedForRefunds()) return;

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
