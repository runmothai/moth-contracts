// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {MothTaxSplitter} from "../src/MothTaxSplitter.sol";

/// The cheatcodes the script uses, declared here so no library has to be downloaded.
interface VmScript {
    function envAddress(string calldata name) external view returns (address);
    function envOr(string calldata name, address defaultValue) external view returns (address);
    function startBroadcast() external;
    function stopBroadcast() external;
}

/// @title Deploy
/// @notice Deploys MothTaxSplitter with every address read from the environment. The broadcasting wallet
/// becomes the owner, and it must be the wallet that then creates $MOTH on Pons, naming this contract as
/// the creator fee recipient. Use a hardware wallet (for example `--ledger`); no key belongs in a file.
/// Robinhood Chain (4663) only.
///
/// Required: USDG, POOL_MANAGER, PONS_FACTORY, PONS_FEE_ESCROW (the zero address skips the fee sweep and the
/// claim), KEEPER, DEV_WALLET, CREDIT_TARGET, USDG_BUYER (the ETH to USDG route for the credit share; the zero
/// address leaves it unset until setUsdgBuyer).
/// Optional, zero when unset: MOTH_TOKEN (set or change it later with setToken).
contract Deploy {
    VmScript private constant vm = VmScript(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 public constant ROBINHOOD_CHAIN_ID = 4663;

    function run() external returns (MothTaxSplitter splitter) {
        require(block.chainid == ROBINHOOD_CHAIN_ID, "Deploy: Robinhood Chain (4663) only");
        address usdg = vm.envAddress("USDG");
        address poolManager = vm.envAddress("POOL_MANAGER");
        address ponsFactory = vm.envAddress("PONS_FACTORY");
        address feeEscrow = vm.envAddress("PONS_FEE_ESCROW");
        address keeper = vm.envAddress("KEEPER");
        address devWallet = vm.envAddress("DEV_WALLET");
        address creditTarget = vm.envAddress("CREDIT_TARGET");
        address usdgBuyer = vm.envAddress("USDG_BUYER");
        address token = vm.envOr("MOTH_TOKEN", address(0));

        vm.startBroadcast();
        splitter = new MothTaxSplitter(
            token, usdg, poolManager, ponsFactory, feeEscrow, keeper, devWallet, creditTarget, usdgBuyer
        );
        vm.stopBroadcast();
    }
}
