// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {SettlementVault} from "../src/SettlementVault.sol";
import {ISettlementVault} from "../src/interfaces/ISettlementVault.sol";
import {FxMath} from "../src/libraries/FxMath.sol";
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
    bytes32 internal constant RATE_ORACLE_ROLE = keccak256("RATE_ORACLE_ROLE");

    bytes3 internal constant NGN = "NGN";
    uint8 internal constant NGN_DECIMALS = 2;
    /// @dev 1,645.25 NGN per USD with 8 decimals.
    uint256 internal constant NGN_RATE = 164_525_000_000;
    uint64 internal constant QUOTE_TTL = 90;
    /// @dev $0.01: smallest amount whose NGN counterparty amount is non-zero at NGN_RATE.
    uint256 internal constant MIN_AMOUNT = 10_000;

    MockUSDC internal usdc;
    SettlementVault internal vault;

    address internal admin = makeAddr("admin (Safe multisig)");
    address internal operator = makeAddr("operator (custody MPC wallet)");
    address internal pauser = makeAddr("pauser");
    address internal rateOracle = makeAddr("rate oracle");
    address internal ngnPartner = makeAddr("NGN off-ramp partner");
    address internal onRampPartner = makeAddr("USD on-ramp partner");
    address internal stranger = makeAddr("stranger");

    function setUp() public virtual {
        vm.warp(1_780_000_000); // fixed, realistic timestamp
        usdc = new MockUSDC();
        vault = new SettlementVault(
            usdc, admin, operator, pauser, rateOracle, ADMIN_DELAY, MAX_PER_SETTLEMENT, DAILY_LIMIT
        );

        vm.startPrank(admin);
        vault.setPartner(ngnPartner, pOffRamp(NGN));
        vault.setPartner(onRampPartner, pOnRamp());
        vault.setCurrency(NGN, NGN_DECIMALS, true);
        vm.stopPrank();

        vm.prank(rateOracle);
        vault.setReferenceRate(NGN, NGN_RATE);

        usdc.mint(address(vault), INITIAL_FLOAT);
    }

    // ------------------------------------------------------------------
    // Partner config helpers
    // ------------------------------------------------------------------

    /// @dev Off-ramp partner restricted to one payout currency (`bytes3(0)` for any).
    function pOffRamp(bytes3 payoutCurrency) internal pure returns (ISettlementVault.PartnerInfo memory) {
        return
            ISettlementVault.PartnerInfo({onRamp: false, offRamp: true, enabled: true, payoutCurrency: payoutCurrency});
    }

    function pOnRamp() internal pure returns (ISettlementVault.PartnerInfo memory) {
        return ISettlementVault.PartnerInfo({onRamp: true, offRamp: false, enabled: true, payoutCurrency: bytes3(0)});
    }

    function pBoth() internal pure returns (ISettlementVault.PartnerInfo memory) {
        return ISettlementVault.PartnerInfo({onRamp: true, offRamp: true, enabled: true, payoutCurrency: bytes3(0)});
    }

    function pDisabled() internal pure returns (ISettlementVault.PartnerInfo memory) {
        return ISettlementVault.PartnerInfo({onRamp: false, offRamp: false, enabled: false, payoutCurrency: bytes3(0)});
    }

    function _quoteId(bytes32 ref) internal pure returns (bytes32) {
        return keccak256(abi.encode("quote", ref));
    }

    /// @dev A valid NGN quote for `amount` USDC that expires in QUOTE_TTL seconds.
    function _quoteInput(bytes32 ref, uint256 amount) internal view returns (ISettlementVault.QuoteInput memory q) {
        q.quoteId = _quoteId(ref);
        q.receiveCurrency = NGN;
        q.expiresAt = uint64(block.timestamp) + QUOTE_TTL;
        q.rate = NGN_RATE;
        q.usdcAmount = amount;
        q.feeUsdc = 25 * USDC;
        q.receiveAmountMinor = FxMath.receiveAmount(amount, NGN_RATE, NGN_DECIMALS);
    }

    function _lock(bytes32 ref, uint256 amount) internal {
        ISettlementVault.QuoteInput memory q = _quoteInput(ref, amount);
        vm.prank(operator);
        vault.lockQuote(ref, q);
    }

    function _ref(string memory transferId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("kimana:transfer:", transferId));
    }

    /// @dev Locks a quote first if `ref` has none, then settles.
    function _settle(bytes32 ref, uint256 amount) internal {
        if (vault.getQuote(ref).lockedAt == 0) _lock(ref, amount);
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
