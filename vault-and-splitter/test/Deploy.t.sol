// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Deploy} from "../script/Deploy.s.sol";
import {MothTaxSplitter} from "../src/MothTaxSplitter.sol";
import {Test} from "./utils/Test.sol";

/// Runs the deploy script inside the test EVM only: no network, no key, nothing broadcast.
contract DeployTest is Test {
    function setEnv() internal {
        vm.setEnv("USDG", "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168");
        vm.setEnv("POOL_MANAGER", "0x8366a39CC670B4001A1121B8F6A443A643e40951");
        vm.setEnv("PONS_FACTORY", "0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e");
        vm.setEnv("PONS_FEE_ESCROW", "0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e");
        vm.setEnv("KEEPER", "0x0000000000000000000000000000000000004eE9");
        vm.setEnv("DEV_WALLET", "0x0000000000000000000000000000000000000De5");
        vm.setEnv("CREDIT_TARGET", "0x0000000000000000000000000000000000C4eD17");
        vm.setEnv("USDG_BUYER", "0x095f4E391912153B73FeF7956F0eAb353b0612C8");
    }

    function test_readsEveryAddressFromTheEnvironment() public {
        setEnv();
        // The constructor wants code at the pool manager, the factory and the escrow; they have none offline.
        vm.etch(0x8366a39CC670B4001A1121B8F6A443A643e40951, hex"00");
        vm.etch(0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e, hex"00");
        vm.etch(0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e, hex"00");
        vm.chainId(4663);
        MothTaxSplitter splitter = new Deploy().run();
        assertEq(splitter.usdg(), 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168, "usdg");
        assertEq(address(splitter.poolManager()), 0x8366a39CC670B4001A1121B8F6A443A643e40951, "pool manager");
        assertEq(address(splitter.ponsFactory()), 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e, "pons factory");
        assertEq(address(splitter.feeEscrow()), 0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e, "escrow");
        assertEq(splitter.keeper(), address(0x4EE9), "keeper");
        assertEq(splitter.devWallet(), address(0xDE5), "dev wallet");
        assertEq(splitter.creditTarget(), address(0xC4ED17), "credit target");
        assertEq(address(splitter.usdgBuyer()), 0x095f4E391912153B73FeF7956F0eAb353b0612C8, "usdg buyer");
        assertEq(address(splitter.token()), address(0), "token set after launch");
        assertEq(splitter.burnBps() + splitter.creditBps() + splitter.devBps(), 10_000, "default split");
        assertTrue(splitter.owner() != address(0), "owned by the broadcaster");
    }

    function test_refusesAnyOtherChain() public {
        setEnv();
        Deploy script = new Deploy();
        vm.expectRevert(bytes("Deploy: Robinhood Chain (4663) only"));
        script.run();
    }
}
