// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {SettlementVault} from "../src/SettlementVault.sol";
import {ISettlementVault} from "../src/interfaces/ISettlementVault.sol";
import {FxMath} from "../src/libraries/FxMath.sol";
import {TransferRef} from "../src/libraries/TransferRef.sol";
import {UsdcUnits} from "../src/libraries/UsdcUnits.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";

/// @notice Local end-to-end run against Anvil (never a public network): deploys a mock USDC and the vault,
///         then walks a transfer through quote lock -> settle -> partner return -> refund, locks a second quote
///         that diverges from the reference rate (alert), and finally pauses the vault (critical alert).
/// @dev Uses Anvil's publicly known development keys. `script/e2e-local.sh` runs this and checks the results.
contract LocalE2E is Script {
    // Anvil default accounts 0-6.
    uint256 internal constant DEPLOYER_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 internal constant ADMIN_PK = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 internal constant OPERATOR_PK = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 internal constant PAUSER_PK = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;
    uint256 internal constant ORACLE_PK = 0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a;
    uint256 internal constant PARTNER_PK = 0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba;
    uint256 internal constant ONRAMP_PK = 0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e;

    bytes3 internal constant NGN = "NGN";
    uint256 internal constant NGN_RATE = 164_525_000_000; // 1,645.25

    function run() external {
        require(block.chainid == 31_337, "LocalE2E only runs on Anvil");

        address admin = vm.addr(ADMIN_PK);
        address operator = vm.addr(OPERATOR_PK);
        address partner = vm.addr(PARTNER_PK);
        address onRamp = vm.addr(ONRAMP_PK);

        // 1. Deploy
        vm.startBroadcast(DEPLOYER_PK);
        MockUSDC usdc = new MockUSDC();
        SettlementVault vault = new SettlementVault(
            usdc,
            admin,
            operator,
            vm.addr(PAUSER_PK),
            vm.addr(ORACLE_PK),
            2 days,
            UsdcUnits.fromCents(5_000_000), // $50,000 per settlement
            UsdcUnits.fromCents(10_000_000) // $100,000 per day
        );
        usdc.mint(address(vault), UsdcUnits.fromCents(100_000_000)); // $1,000,000 float
        vm.stopBroadcast();

        // 2. Admin (multisig in production) approves partners
        vm.startBroadcast(ADMIN_PK);
        vault.setPartner(partner, true);
        vault.setPartner(onRamp, true);
        vault.setCurrency(NGN, 2, true);
        vm.stopBroadcast();

        // 3. Oracle publishes the reference rate
        vm.broadcast(ORACLE_PK);
        vault.setReferenceRate(NGN, NGN_RATE);

        // 4. Customer accepts a $45,000 quote; backend locks it and settles
        bytes32 ref1 = TransferRef.fromTransferId("e2e_txn_001");
        uint256 amount = UsdcUnits.fromCents(4_500_000);
        vm.startBroadcast(OPERATOR_PK);
        vault.lockQuote(ref1, _quote("e2e_quote_001", NGN_RATE, amount));
        vault.settle(ref1, partner, amount);
        vm.stopBroadcast();

        // 5. The NGN payout fails; partner returns the USDC and the backend refunds the on-ramp
        vm.startBroadcast(PARTNER_PK);
        usdc.approve(address(vault), amount);
        vault.returnSettlement(ref1);
        vm.stopBroadcast();
        vm.broadcast(OPERATOR_PK);
        vault.refund(ref1, onRamp);

        // 6. A second quote 2% away from the reference rate locks, but raises an alert
        bytes32 ref2 = TransferRef.fromTransferId("e2e_txn_002");
        uint256 divergent = NGN_RATE + (NGN_RATE * 200) / 10_000;
        vm.broadcast(OPERATOR_PK);
        vault.lockQuote(ref2, _quote("e2e_quote_002", divergent, UsdcUnits.fromCents(100_000)));

        // 7. Emergency pause
        vm.broadcast(PAUSER_PK);
        vault.pause();

        console2.log("VAULT", address(vault));
        console2.log("USDC", address(usdc));
        console2.log("REF1");
        console2.logBytes32(ref1);
        console2.log("REF2");
        console2.logBytes32(ref2);
    }

    function _quote(string memory id, uint256 rate, uint256 usdcAmount)
        internal
        view
        returns (ISettlementVault.QuoteInput memory q)
    {
        q = ISettlementVault.QuoteInput({
            quoteId: keccak256(bytes(id)),
            receiveCurrency: NGN,
            expiresAt: uint64(block.timestamp + 90),
            rate: rate,
            usdcAmount: usdcAmount,
            feeUsdc: UsdcUnits.fromCents(2500),
            receiveAmountMinor: FxMath.receiveAmount(usdcAmount, rate, 2)
        });
    }
}
