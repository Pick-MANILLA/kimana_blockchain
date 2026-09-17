// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {BaseTest} from "../BaseTest.sol";
import {ISettlementVault} from "../../src/interfaces/ISettlementVault.sol";
import {SettlementVaultHandler} from "./SettlementVaultHandler.sol";

contract SettlementVaultInvariantTest is StdInvariant, BaseTest {
    SettlementVaultHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new SettlementVaultHandler(vault, usdc, operator, admin, ngnPartner, onRampPartner);
        targetContract(address(handler));
    }

    /// Vault balance always equals what went in minus what went out.
    function invariant_balanceMatchesAccounting() public view {
        uint256 inflow = INITIAL_FLOAT + handler.ghostTopUps() + handler.ghostReturned();
        uint256 outflow = handler.ghostSettled() + handler.ghostRefunded() + handler.ghostSwept();
        assertEq(usdc.balanceOf(address(vault)), inflow - outflow);
    }

    /// On-chain counters agree with the handler's ghost counters.
    function invariant_countersMatchGhosts() public view {
        assertEq(vault.totalSettled(), handler.ghostSettled());
        assertEq(vault.totalReturned(), handler.ghostReturned());
        assertEq(vault.totalRefunded(), handler.ghostRefunded());
    }

    /// Money can only be refunded after it was returned, and only returned after it was settled.
    function invariant_refundedLeReturnedLeSettled() public view {
        assertLe(vault.totalRefunded(), vault.totalReturned());
        assertLe(vault.totalReturned(), vault.totalSettled());
    }

    /// Funds awaiting refund are always held by the vault.
    function invariant_reservedFundsAreBacked() public view {
        assertEq(vault.reservedForRefunds(), vault.totalReturned() - vault.totalRefunded());
        assertGe(usdc.balanceOf(address(vault)), vault.reservedForRefunds());
    }

    /// Sum of per-ref amounts by status matches the aggregate counters.
    function invariant_perRefStateConsistent() public view {
        uint256 reserved;
        uint256 n = handler.refCount();
        for (uint256 i; i < n; ++i) {
            ISettlementVault.Settlement memory s = vault.getSettlement(handler.refs(i));
            assertTrue(s.status != ISettlementVault.Status.None, "tracked ref must exist");
            if (s.status == ISettlementVault.Status.Returned) reserved += s.amount;
        }
        assertEq(reserved, vault.reservedForRefunds());
    }
}
