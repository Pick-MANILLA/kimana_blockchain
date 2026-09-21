// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {SettlementVault} from "../../src/SettlementVault.sol";
import {ISettlementVault} from "../../src/interfaces/ISettlementVault.sol";
import {FxMath} from "../../src/libraries/FxMath.sol";

/// @notice Minimal view/write interface for Circle's real USDC (FiatTokenV2_2-style proxy). The full token
///         interface is much bigger; these are the members the fork test needs, including the governance
///         surface exercised to simulate blocklisting (issue #3) and pausing.
interface IUSDC {
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function isBlacklisted(address account) external view returns (bool);
    function blacklist(address account) external;
    function unblacklist(address account) external;
    function blacklister() external view returns (address);
    function paused() external view returns (bool);
    function pause() external;
    function unpause() external;
    function pauser() external view returns (address);
}

/// @title SettlementVault fork tests against Circle's real USDC
/// @notice The unit tests run against MockUSDC. These tests fork a configured testnet and exercise the vault
///         against Circle's real USDC proxy (6-decimal check, blocklist, pause). They only run when the RPC
///         environment variable is set; otherwise every test is skipped, so `forge test` stays green in CI.
/// @dev Run:
///         BASE_SEPOLIA_RPC_URL=... forge test --match-path test/fork/SettlementVault.fork.t.sol -vvv
///      Optionally also set ARBITRUM_SEPOLIA_RPC_URL and POLYGON_AMOY_RPC_URL to run the same tests on those
///      testnets. See docs/networks.md for the USDC addresses.
///
///      USDC on these networks is a FiatTokenV2_2-style proxy: balances share a packed storage slot with the
///      blacklist flag, transfers/approvals are `whenNotPaused`, and only Circle's `blacklister` may
///      block/`unblocklist`. The tests impersonate the real `blacklister`/`pauser` role holders to flip state
///      exactly as Circle can.
abstract contract SettlementVaultForkBase is Test {
    uint256 internal constant USDC = 1e6;
    uint256 internal constant MAX_PER_SETTLEMENT = 50_000 * USDC;
    uint256 internal constant DAILY_LIMIT = 100_000 * USDC;
    uint256 internal constant INITIAL_FLOAT = 250_000 * USDC;
    uint256 internal constant AMOUNT = 1000 * USDC;
    uint256 internal constant FEE = 25 * USDC;
    uint48 internal constant ADMIN_DELAY = 2 days;

    bytes32 internal constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 internal constant RATE_ORACLE_ROLE = keccak256("RATE_ORACLE_ROLE");

    bytes3 internal constant NGN = "NGN";
    /// @dev 1,645.25 NGN per USD, 8 decimals. Equal to the reference rate so no divergence alert fires.
    uint256 internal constant NGN_RATE = 164_525_000_000;
    uint64 internal constant QUOTE_TTL = 90;

    string internal rpcEnvName;
    uint256 internal forkChainId;
    address internal usdcAddress;

    IUSDC internal usdc;
    SettlementVault internal vault;

    address internal admin = makeAddr("admin");
    address internal operator = makeAddr("operator");
    address internal pauser = makeAddr("vault pauser");
    address internal rateOracle = makeAddr("rate oracle");
    address internal ngnPartner = makeAddr("NGN off-ramp partner");
    address internal onRampPartner = makeAddr("USD on-ramp partner");
    address internal spareOnRamp = makeAddr("spare on-ramp partner");
    address internal blockedOffRamp = makeAddr("blocklisted off-ramp partner");

    constructor(string memory rpcEnvName_, uint256 forkChainId_, address usdcAddress_) {
        rpcEnvName = rpcEnvName_;
        forkChainId = forkChainId_;
        usdcAddress = usdcAddress_;
    }

    function setUp() public virtual {
        string memory noUrl = "";
        string memory url = vm.envOr(rpcEnvName, noUrl);
        if (bytes(url).length == 0) {
            vm.skip(true, string.concat("no ", rpcEnvName, " set; skipping real-USDC fork tests"));
            return;
        }
        vm.createSelectFork(url);

        usdc = IUSDC(usdcAddress);
        vault = new SettlementVault(
            IERC20(usdcAddress), admin, operator, pauser, rateOracle, ADMIN_DELAY, MAX_PER_SETTLEMENT, DAILY_LIMIT
        );

        vm.startPrank(admin);
        vault.setCurrency(NGN, 2, true);
        vault.setPartner(ngnPartner, pOffRamp());
        vault.setPartner(blockedOffRamp, pOffRamp());
        vault.setPartner(onRampPartner, pOnRamp());
        vault.setPartner(spareOnRamp, pOnRamp());
        vm.stopPrank();

        vm.prank(rateOracle);
        vault.setReferenceRate(NGN, NGN_RATE);

        deal(address(usdc), address(vault), INITIAL_FLOAT);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function pOffRamp() internal pure returns (ISettlementVault.PartnerInfo memory) {
        return ISettlementVault.PartnerInfo({onRamp: false, offRamp: true, enabled: true, payoutCurrency: NGN});
    }

    function pOnRamp() internal pure returns (ISettlementVault.PartnerInfo memory) {
        return ISettlementVault.PartnerInfo({onRamp: true, offRamp: false, enabled: true, payoutCurrency: bytes3(0)});
    }

    function _ref(string memory transferId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("kimana:transfer:", transferId));
    }

    function _lock(bytes32 ref, uint256 amount) internal {
        ISettlementVault.QuoteInput memory q = ISettlementVault.QuoteInput({
            quoteId: keccak256(abi.encode("quote", ref)),
            receiveCurrency: NGN,
            expiresAt: uint64(block.timestamp) + QUOTE_TTL,
            rate: NGN_RATE,
            usdcAmount: amount,
            feeUsdc: FEE,
            receiveAmountMinor: FxMath.receiveAmount(amount, NGN_RATE, 2)
        });
        vm.prank(operator);
        vault.lockQuote(ref, q);
    }

    /// @dev Blacklists `account` on real USDC as Circle would (impersonating the token's blacklister role) and
    ///      returns the exact bytes any transfer to that account reverts with, for precise expectRevert matching.
    function _blacklistAsCircle(address account) internal returns (bytes memory revertData) {
        vm.prank(usdc.blacklister());
        usdc.blacklist(account);
        (bool ok, bytes memory reason) = address(usdc).call(abi.encodeCall(usdc.transfer, (account, 1)));
        assertFalse(ok, "real USDC must block a transfer to a freshly blacklisted address");
        return reason;
    }

    // ------------------------------------------------------------------
    // Deployment against the real token
    // ------------------------------------------------------------------

    function testFork_constructorAcceptsReal6DecimalUsdc() public view {
        assertEq(block.chainid, forkChainId);
        assertEq(address(vault.asset()), usdcAddress);
        assertEq(usdc.decimals(), 6, "network USDC must be Circle native USDC with 6 decimals");
        assertEq(vault.getCurrency(NGN).decimals, 2);
        assertTrue(vault.getCurrency(NGN).enabled);
        assertTrue(vault.hasRole(OPERATOR_ROLE, operator));
        assertTrue(vault.hasRole(RATE_ORACLE_ROLE, rateOracle));
        assertEq(vault.getReferenceRate(NGN).rate, NGN_RATE);
        assertEq(usdc.balanceOf(address(vault)), INITIAL_FLOAT, "vault funded by deal");
    }

    // ------------------------------------------------------------------
    // Full lifecycle against the real token
    // ------------------------------------------------------------------

    function testFork_fullLifecycle_lockSettleReturnRefund() public {
        bytes32 ref = _ref("fork-lifecycle");
        _lock(ref, AMOUNT);

        vm.prank(operator);
        vault.settle(ref, ngnPartner, AMOUNT);

        assertEq(usdc.balanceOf(ngnPartner), AMOUNT);
        assertEq(usdc.balanceOf(address(vault)), INITIAL_FLOAT - AMOUNT);
        assertEq(uint8(vault.getSettlement(ref).status), uint8(ISettlementVault.Status.Settled));

        vm.startPrank(ngnPartner);
        usdc.approve(address(vault), AMOUNT);
        vault.returnSettlement(ref);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(vault)), INITIAL_FLOAT);
        assertEq(vault.reservedForRefunds(), AMOUNT);
        assertEq(uint8(vault.getSettlement(ref).status), uint8(ISettlementVault.Status.Returned));

        vm.prank(operator);
        vault.refund(ref, onRampPartner);

        assertEq(usdc.balanceOf(onRampPartner), AMOUNT);
        assertEq(vault.reservedForRefunds(), 0);
        assertEq(uint8(vault.getSettlement(ref).status), uint8(ISettlementVault.Status.Refunded));
        assertEq(vault.totalSettled(), AMOUNT);
        assertEq(vault.totalReturned(), AMOUNT);
        assertEq(vault.totalRefunded(), AMOUNT);
    }

    function testFork_fundFromOnRamp_thenSettle() public {
        deal(address(usdc), onRampPartner, AMOUNT + FEE);
        bytes32 ref = _ref("fork-fund");
        _lock(ref, AMOUNT);

        vm.startPrank(onRampPartner);
        usdc.approve(address(vault), AMOUNT + FEE);
        vault.fund(ref, AMOUNT + FEE);
        vm.stopPrank();

        assertEq(vault.getFunding(ref).partner, onRampPartner);
        assertEq(vault.totalFunded(), AMOUNT + FEE);
        assertEq(usdc.balanceOf(address(vault)), INITIAL_FLOAT + AMOUNT + FEE);

        vm.prank(operator);
        vault.settle(ref, ngnPartner, AMOUNT);

        assertEq(usdc.balanceOf(ngnPartner), AMOUNT);
        assertEq(usdc.balanceOf(address(vault)), INITIAL_FLOAT + FEE);
        assertEq(uint8(vault.getSettlement(ref).status), uint8(ISettlementVault.Status.Settled));
    }

    // ------------------------------------------------------------------
    // Round-trip of a returned settlement funded by an on-ramp partner
    // ------------------------------------------------------------------

    function testFork_roundTrip_onRampFund_toRefund() public {
        deal(address(usdc), onRampPartner, AMOUNT + FEE);
        bytes32 ref = _ref("fork-round-trip");
        _lock(ref, AMOUNT);

        vm.startPrank(onRampPartner);
        usdc.approve(address(vault), AMOUNT + FEE);
        vault.fund(ref, AMOUNT + FEE);
        vm.stopPrank();

        vm.prank(operator);
        vault.settle(ref, ngnPartner, AMOUNT);

        vm.startPrank(ngnPartner);
        usdc.approve(address(vault), AMOUNT);
        vault.returnSettlement(ref);
        vm.stopPrank();

        vm.prank(operator);
        vault.refund(ref, onRampPartner);

        assertEq(usdc.balanceOf(onRampPartner), AMOUNT, "on-ramp partner is fully round-tripped");
        assertEq(usdc.balanceOf(address(vault)), INITIAL_FLOAT + FEE, "fee stays in the vault");
        assertEq(vault.reservedForRefunds(), 0);
        assertEq(vault.totalFunded(), AMOUNT + FEE);
        assertEq(vault.totalRefunded(), AMOUNT);
    }

    // ------------------------------------------------------------------
    // Blocklisting (issue #3) against the real token
    // ------------------------------------------------------------------

    function testFork_settle_revertsWhenPartnerIsBlocklisted_stateUntouched() public {
        bytes memory reason = _blacklistAsCircle(blockedOffRamp);
        assertTrue(usdc.isBlacklisted(blockedOffRamp));

        uint256 balanceBefore = usdc.balanceOf(address(vault));
        bytes32 ref = _ref("fork-blocklist-settle");
        _lock(ref, AMOUNT);

        vm.prank(operator);
        vm.expectRevert(reason);
        vault.settle(ref, blockedOffRamp, AMOUNT);

        assertEq(usdc.balanceOf(address(vault)), balanceBefore, "nothing moved");
        assertEq(uint8(vault.getSettlement(ref).status), uint8(ISettlementVault.Status.None), "status untouched");
        assertEq(vault.totalSettled(), 0, "counter untouched");
    }

    function testFork_fund_revertsWhenOnRampPartnerIsBlocklisted() public {
        deal(address(usdc), onRampPartner, AMOUNT + FEE);
        bytes memory reason = _blacklistAsCircle(onRampPartner);

        bytes32 ref = _ref("fork-blocklist-fund");
        _lock(ref, AMOUNT);

        vm.startPrank(onRampPartner);
        usdc.approve(address(vault), AMOUNT + FEE);
        vm.expectRevert(reason);
        vault.fund(ref, AMOUNT + FEE);
        vm.stopPrank();

        assertEq(vault.getFunding(ref).fundedAt, 0, "no funding recorded");
        assertEq(vault.totalFunded(), 0);
    }

    function testFork_refund_revertsToBlocklistedDestination_andRoutesAroundToSpare() public {
        bytes32 ref = _ref("fork-blocklist-refund");
        _lock(ref, AMOUNT);
        vm.prank(operator);
        vault.settle(ref, ngnPartner, AMOUNT);
        vm.startPrank(ngnPartner);
        usdc.approve(address(vault), AMOUNT);
        vault.returnSettlement(ref);
        vm.stopPrank();

        bytes memory reason = _blacklistAsCircle(onRampPartner);

        vm.prank(operator);
        vm.expectRevert(reason);
        vault.refund(ref, onRampPartner);
        assertEq(uint8(vault.getSettlement(ref).status), uint8(ISettlementVault.Status.Returned), "still returned");
        assertEq(vault.reservedForRefunds(), AMOUNT, "still reserved");

        vm.prank(operator);
        vault.refund(ref, spareOnRamp);
        assertEq(usdc.balanceOf(spareOnRamp), AMOUNT, "refunded to the spare on-ramp");
        assertEq(vault.reservedForRefunds(), 0);
    }

    // ------------------------------------------------------------------
    // Real-USDC pause
    // ------------------------------------------------------------------

    function testFork_usdcPaused_blocksSettle_andUnpauseRestores() public {
        assertFalse(usdc.paused(), "testnet USDC should start unpaused");

        vm.prank(usdc.pauser());
        usdc.pause();
        assertTrue(usdc.paused());

        (bool ok, bytes memory reason) = address(usdc).call(abi.encodeCall(usdc.transfer, (ngnPartner, 1)));
        assertFalse(ok, "real USDC must block transfers while paused");

        bytes32 ref = _ref("fork-paused");
        _lock(ref, AMOUNT);

        vm.prank(operator);
        vm.expectRevert(reason);
        vault.settle(ref, ngnPartner, AMOUNT);
        assertEq(uint8(vault.getSettlement(ref).status), uint8(ISettlementVault.Status.None), "nothing settled");

        vm.prank(usdc.pauser());
        usdc.unpause();
        assertFalse(usdc.paused());

        vm.prank(operator);
        vault.settle(ref, ngnPartner, AMOUNT);
        assertEq(usdc.balanceOf(ngnPartner), AMOUNT);
        assertEq(uint8(vault.getSettlement(ref).status), uint8(ISettlementVault.Status.Settled));
    }
}

contract SettlementVaultForkBaseSepoliaTest is SettlementVaultForkBase {
    constructor()
        SettlementVaultForkBase("BASE_SEPOLIA_RPC_URL", 84_532, address(0x036CbD53842c5426634e7929541eC2318f3dCF7e))
    {}
}

contract SettlementVaultForkArbitrumSepoliaTest is SettlementVaultForkBase {
    constructor()
        SettlementVaultForkBase(
            "ARBITRUM_SEPOLIA_RPC_URL", 421_614, address(0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d)
        )
    {}
}

contract SettlementVaultForkPolygonAmoyTest is SettlementVaultForkBase {
    constructor()
        SettlementVaultForkBase("POLYGON_AMOY_RPC_URL", 80_002, address(0x41E94Eb019C0762f9Bfcf9Fb1E58725BfB0e7582))
    {}
}
