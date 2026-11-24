// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "./utils/Test.sol";
import {MockERC20} from "./utils/Mocks.sol";
import {MockPoolManager} from "./utils/MockPoolManager.sol";
import {UsdgSeller} from "../src/swappers/UsdgSeller.sol";
import {UsdgSwapper} from "../src/swappers/UsdgSwapper.sol";
import {SellSwapperBase} from "../src/swappers/SellSwapperBase.sol";
import {PoolKey} from "../src/interfaces/IV4PoolManager.sol";

/// Offline checks of both routes against a mock PoolManager that fills only part of the input, as a real pool
/// does when the swap stops at its price limit.
contract UsdgRoutesUnitTest is Test {
    MockERC20 internal usdg;
    MockPoolManager internal pm;
    UsdgSeller internal seller;
    UsdgSwapper internal swapper;
    address internal caller = address(0xCA11);
    address internal recipient = address(0xCAFE);

    function setUp() public {
        usdg = new MockERC20(6);
        pm = new MockPoolManager();
        PoolKey memory key =
            PoolKey({currency0: address(0), currency1: address(usdg), fee: 500, tickSpacing: 10, hooks: address(0)});
        seller = new UsdgSeller(address(usdg), address(pm), key);
        swapper = new UsdgSwapper(address(usdg), address(pm), key);
        vm.deal(address(pm), 1_000 ether);
        usdg.mint(address(pm), 1_000_000e6);
    }

    function test_seller_partialFill_returnsUnusedUsdg() public {
        pm.configure(4_000, 1e12, 1); // 40% of the input is used; 1 USDG buys 1 ETH
        usdg.mint(address(seller), 100e6);
        uint256 pmUsdg = usdg.balanceOf(address(pm));
        vm.prank(caller);
        uint256 out = seller.swapForEth(address(usdg), 100e6, 1, recipient);
        assertEq(out, 40 ether, "output");
        assertEq(recipient.balance, 40 ether, "recipient eth");
        assertEq(usdg.balanceOf(caller), 60e6, "unused usdg back to the caller");
        assertEq(usdg.balanceOf(address(seller)), 0, "route usdg");
        assertEq(usdg.balanceOf(address(pm)) - pmUsdg, 40e6, "pool took only what it used");
        assertEq(usdg.balanceOf(recipient), 0, "recipient usdg");
    }

    function test_swapper_partialFill_returnsUnusedEth() public {
        pm.configure(4_000, 1, 1e12); // 40% of the input is used; 1 ETH buys 1 USDG
        vm.deal(caller, 20 ether);
        uint256 pmEth = address(pm).balance;
        vm.prank(caller);
        uint256 out = swapper.swapEthFor{value: 10 ether}(address(usdg), 1, recipient);
        assertEq(out, 4e6, "output");
        assertEq(usdg.balanceOf(recipient), 4e6, "recipient usdg");
        assertEq(caller.balance, 20 ether - 4 ether, "unused eth back to the caller");
        assertEq(address(swapper).balance, 0, "route eth");
        assertEq(address(pm).balance - pmEth, 4 ether, "pool took only what it used");
    }

    function test_partialFill_belowMinimum_reverts() public {
        pm.configure(4_000, 1e12, 1);
        usdg.mint(address(seller), 100e6);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(SellSwapperBase.InsufficientOutput.selector, 40 ether, 50 ether));
        seller.swapForEth(address(usdg), 100e6, 50 ether, recipient);

        pm.configure(4_000, 1, 1e12);
        vm.deal(caller, 10 ether);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(SellSwapperBase.InsufficientOutput.selector, 4e6, 5e6));
        swapper.swapEthFor{value: 10 ether}(address(usdg), 5e6, recipient);
    }

    function test_fullFill_returnsNothing() public {
        pm.configure(10_000, 1e12, 1);
        usdg.mint(address(seller), 100e6);
        vm.prank(caller);
        uint256 out = seller.swapForEth(address(usdg), 100e6, 1, recipient);
        assertEq(out, 100 ether, "output");
        assertEq(usdg.balanceOf(caller), 0, "no refund");
    }
}
