// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SettlementVault} from "../src/SettlementVault.sol";

/// @notice Deploys SettlementVault. The deployer receives no roles.
/// @dev Usage (keystore account, never a raw private key in env):
///   forge script script/DeploySettlementVault.s.sol --rpc-url base_sepolia --account kimana-deployer \
///     --broadcast --verify
contract DeploySettlementVault is Script {
    function run() external returns (SettlementVault vault) {
        address asset = vm.envAddress("USDC_ADDRESS");
        address admin = vm.envAddress("ADMIN_ADDRESS");
        address operator = vm.envAddress("OPERATOR_ADDRESS");
        address pauser = vm.envAddress("PAUSER_ADDRESS");
        address rateOracle = vm.envOr("RATE_ORACLE_ADDRESS", address(0));
        uint48 adminDelay = uint48(vm.envOr("ADMIN_TRANSFER_DELAY", uint256(2 days)));
        uint256 maxPerSettlement = vm.envUint("MAX_PER_SETTLEMENT");
        uint256 dailyLimit = vm.envUint("DAILY_LIMIT");

        require(asset.code.length > 0, "USDC_ADDRESS has no code");

        vm.startBroadcast();
        vault = new SettlementVault(
            IERC20(asset), admin, operator, pauser, rateOracle, adminDelay, maxPerSettlement, dailyLimit
        );
        vm.stopBroadcast();

        console2.log("SettlementVault:", address(vault));
        console2.log("admin:", admin);
        console2.log("operator:", operator);
        console2.log("pauser:", pauser);
        console2.log("rateOracle:", rateOracle);
    }
}
