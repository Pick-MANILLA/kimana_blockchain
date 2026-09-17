// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {UsdcUnits} from "../src/libraries/UsdcUnits.sol";
import {TransferRef} from "../src/libraries/TransferRef.sol";

/// @dev Wrapper so reverts from internal library calls can be asserted.
contract UnitsHarness {
    function toCents(uint256 usdcAmount) external pure returns (uint256) {
        return UsdcUnits.toCents(usdcAmount);
    }
}

contract LibrariesTest is Test {
    UnitsHarness internal harness = new UnitsHarness();

    function test_fromCents_knownValues() public pure {
        assertEq(UsdcUnits.fromCents(1), 10_000); // $0.01
        assertEq(UsdcUnits.fromCents(100), 1_000_000); // $1.00
        assertEq(UsdcUnits.fromCents(4_500_000), 45_000_000_000); // $45,000.00
    }

    function test_toCents_revertsOnSubCentAmounts() public {
        vm.expectRevert(abi.encodeWithSelector(UsdcUnits.NotWholeCents.selector, 10_001));
        harness.toCents(10_001);
    }

    function testFuzz_centsRoundTrip(uint128 cents) public view {
        assertEq(harness.toCents(UsdcUnits.fromCents(cents)), cents);
    }

    function test_transferRef_matchesBackendFormula() public pure {
        // Backend (Rust, alloy): keccak256(format!("kimana:transfer:{id}").as_bytes())
        assertEq(TransferRef.fromTransferId("txn_0001"), keccak256(bytes("kimana:transfer:txn_0001")));
    }

    function test_transferRef_differentIdsDiffer() public pure {
        assertTrue(TransferRef.fromTransferId("txn_0001") != TransferRef.fromTransferId("txn_0002"));
    }
}
