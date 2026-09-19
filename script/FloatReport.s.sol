// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SettlementVault} from "../src/SettlementVault.sol";
import {ISettlementVault} from "../src/interfaces/ISettlementVault.sol";

/// @notice Issue #13. On-demand treasury report for ops. Read-only: no broadcast, no keys, no state change.
/// @dev Usage:
///   VAULT_ADDRESS=0x... forge script script/FloatReport.s.sol --rpc-url base_sepolia
///   VAULT_ADDRESS=0x... CURRENCIES=NGN,GHS forge script script/FloatReport.s.sol --rpc-url base_sepolia
///
///   The vault has no currency enumeration on-chain, so the codes to inspect come from `CURRENCIES`
///   (comma separated, default "NGN"). All amount maths is integer only, like the contract's.
contract FloatReport is Script {
    uint256 internal constant ONE_USDC = 1e6;

    function run() external view {
        SettlementVault vault = SettlementVault(vm.envAddress("VAULT_ADDRESS"));
        IERC20 asset = vault.asset();

        uint256 balance = asset.balanceOf(address(vault));
        uint256 reserved = vault.reservedForRefunds();
        uint256 free = balance - reserved;

        console2.log("=== Kimana SettlementVault float report ===");
        console2.log("vault:      %s", address(vault));
        console2.log("asset:      %s", address(asset));
        console2.log("chain id:   %s", block.chainid);
        console2.log("as of:      %s (unix)", block.timestamp);
        console2.log("paused:     %s", vault.paused() ? "YES" : "no");
        console2.log("requireFunding: %s", vault.requireFunding() ? "on" : "off");

        console2.log("");
        console2.log("--- Balances ---");
        _amount("balance          ", balance);
        _amount("reserved (refunds)", reserved);
        _amount("free (sweepable) ", free);

        console2.log("");
        console2.log("--- Lifetime totals ---");
        _amount("funded in        ", vault.totalFunded());
        _amount("settled out      ", vault.totalSettled());
        _amount("returned by partners", vault.totalReturned());
        _amount("refunded out     ", vault.totalRefunded());

        console2.log("");
        console2.log("--- Limits ---");
        uint256 today = block.timestamp / 1 days;
        uint256 usedToday = vault.settledOnDay(today);
        uint256 remaining = vault.remainingDailyLimit();
        _amount("max per settlement", vault.maxPerSettlement());
        _amount("daily limit      ", vault.dailyLimit());
        _amount("used today       ", usedToday);
        _amount("remaining today  ", remaining);
        console2.log("  (UTC day index %s)", today);

        console2.log("");
        console2.log("--- Quote config ---");
        ISettlementVault.QuoteConfig memory c = vault.quoteConfig();
        console2.log("  maxQuoteTtl       %s s", uint256(c.maxQuoteTtl));
        console2.log("  referenceMaxAge   %s s", uint256(c.referenceMaxAge));
        console2.log("  maxSettleDelay    %s s", uint256(c.maxSettleDelay));
        console2.log("  divergence alert  %s bps", uint256(c.divergenceAlertBps));
        console2.log("  divergence max    %s bps", uint256(c.divergenceMaxBps));

        console2.log("");
        console2.log("--- Currencies ---");
        string[] memory codes = vm.split(vm.envOr("CURRENCIES", string("NGN")), ",");
        for (uint256 i; i < codes.length; ++i) {
            _currency(vault, codes[i], c.referenceMaxAge);
        }
    }

    function _currency(SettlementVault vault, string memory code, uint64 maxAge) internal view {
        bytes memory raw = bytes(code);
        if (raw.length != 3) {
            console2.log("  %s: SKIPPED (not a 3-letter code)", code);
            return;
        }
        // Safe: `raw.length == 3` was just checked, so nothing is truncated.
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes3 cur = bytes3(raw);

        ISettlementVault.CurrencyInfo memory info = vault.getCurrency(cur);
        if (!info.enabled) {
            console2.log("  %s: NOT ENABLED - lockQuote will revert with CurrencyNotSupported", code);
            return;
        }
        console2.log("  %s: enabled, %s minor decimals", code, uint256(info.decimals));

        ISettlementVault.ReferenceRate memory r = vault.getReferenceRate(cur);
        if (r.updatedAt == 0) {
            console2.log("      reference rate: NONE - every lock raises ReferenceRateStale (see issue #15)");
            return;
        }
        uint256 age = block.timestamp - r.updatedAt;
        // Rate has 8 decimals; show whole units and 4 decimal places without floating point.
        console2.log("      reference rate: %s.%s per USD", r.rate / 1e8, _pad(((r.rate % 1e8) / 1e4), 4));
        console2.log("      age: %s s%s", age, age > maxAge ? "  <-- STALE" : "");
    }

    /// @dev Prints USDC base units and the same value as whole dollars with 2 decimals, integer maths only.
    function _amount(string memory label, uint256 v) internal pure {
        console2.log("  %s  %s.%s USDC", label, v / ONE_USDC, _pad((v % ONE_USDC) / 1e4, 2));
        console2.log("      (%s base units)", v);
    }

    /// @dev Left-pads `v` with zeros to `width` digits, so 5 cents prints as "05", not "5".
    function _pad(uint256 v, uint256 width) internal pure returns (string memory out) {
        out = vm.toString(v);
        while (bytes(out).length < width) {
            out = string.concat("0", out);
        }
    }
}
