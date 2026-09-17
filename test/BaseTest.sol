// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SettlementVault} from "../src/SettlementVault.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";

abstract contract BaseTest is Test {
    uint256 internal constant USDC = 1e6;
    uint256 internal constant MAX_PER_SETTLEMENT = 50_000 * USDC;
    uint256 internal constant DAILY_LIMIT = 100_000 * USDC;
    uint256 internal constant INITIAL_FLOAT = 1_000_000 * USDC;
    uint48 internal constant ADMIN_DELAY = 2 days;

    // Precomputed so `vm.prank` is not consumed by a role getter call.
    bytes32 internal constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    MockUSDC internal usdc;
    SettlementVault internal vault;

    address internal admin = makeAddr("admin (Safe multisig)");
    address internal operator = makeAddr("operator (custody MPC wallet)");
    address internal pauser = makeAddr("pauser");
    address internal ngnPartner = makeAddr("NGN off-ramp partner");
    address internal onRampPartner = makeAddr("USD on-ramp partner");
    address internal stranger = makeAddr("stranger");

    function setUp() public virtual {
        vm.warp(1_780_000_000); // fixed, realistic timestamp
        usdc = new MockUSDC();
        vault = new SettlementVault(usdc, admin, operator, pauser, ADMIN_DELAY, MAX_PER_SETTLEMENT, DAILY_LIMIT);

        vm.startPrank(admin);
        vault.setPartner(ngnPartner, true);
        vault.setPartner(onRampPartner, true);
        vm.stopPrank();

        usdc.mint(address(vault), INITIAL_FLOAT);
    }

    function _ref(string memory transferId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("kimana:transfer:", transferId));
    }

    function _settle(bytes32 ref, uint256 amount) internal {
        vm.prank(operator);
        vault.settle(ref, ngnPartner, amount);
    }

    function _return(bytes32 ref) internal {
        uint256 amount = vault.getSettlement(ref).amount;
        vm.startPrank(ngnPartner);
        usdc.approve(address(vault), amount);
        vault.returnSettlement(ref);
        vm.stopPrank();
    }
}
