// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {RobinhoodFork, IERC20Like} from "./RobinhoodFork.sol";
import {UsdgSeller} from "../../src/swappers/UsdgSeller.sol";
import {UsdgSwapper} from "../../src/swappers/UsdgSwapper.sol";
import {SellSwapperBase} from "../../src/swappers/SellSwapperBase.sol";
import {SwapperBase} from "../../src/swappers/SwapperBase.sol";
import {V4ExactIn} from "../../src/swappers/V4ExactIn.sol";
import {PoolKey, IV4PoolManager} from "../../src/interfaces/IV4PoolManager.sol";

/// Both routes against the real native ETH / USDG v4 pool. The tests push the input first, as the vault does.
contract UsdgRoutesTest is RobinhoodFork {
    UsdgSeller internal seller;
    UsdgSwapper internal swapper;
    address internal recipient = address(0xCAFE);
    address internal caller = address(0xCA11);

    function setUp() public override {
        super.setUp();
        if (!forked) return;
        seller = new UsdgSeller(USDG, POOL_MANAGER, ethUsdgPool());
        swapper = new UsdgSwapper(USDG, POOL_MANAGER, ethUsdgPool());
    }

    function bal(address who) internal view returns (uint256) {
        return IERC20Like(USDG).balanceOf(who);
    }

    /// The pool's price as sqrt(price) in Q64.96, read from the PoolManager's storage (slot0 of the pool state,
    /// which sits in the mapping at slot 6). The price is USDG units per wei of ETH.
    function sqrtPrice() internal view returns (uint256) {
        bytes32 poolId = keccak256(abi.encode(ethUsdgPool()));
        bytes32 slot0 = IV4PoolManager(POOL_MANAGER).extsload(keccak256(abi.encode(poolId, uint256(6))));
        return uint256(slot0) & ((1 << 160) - 1);
    }

    /// What `ethIn` wei should buy at the pool's price, before the 0.05% fee.
    function usdgForEth(uint256 ethIn) internal view returns (uint256) {
        uint256 sp = sqrtPrice();
        return (ethIn * sp / (1 << 96)) * sp / (1 << 96);
    }

    /// What `usdgIn` USDG should buy at the pool's price, before the 0.05% fee.
    function ethForUsdg(uint256 usdgIn) internal view returns (uint256) {
        uint256 sp = sqrtPrice();
        return (((usdgIn << 96) / sp) << 96) / sp;
    }

    /// `got` is within 1% of the amount the price implies after the 0.05% fee.
    function assertNearPrice(uint256 got, uint256 spot, string memory why) internal pure {
        uint256 expected = spot * 9995 / 10_000;
        assertTrue(got * 100 >= expected * 99 && got * 100 <= expected * 101, why);
    }

    /// Reads what a swap would pay by asking for an impossible minimum; the revert reports the amount received.
    function quoteSell(uint256 amountIn) internal returns (uint256 received) {
        vm.prank(caller);
        (bool ok, bytes memory ret) =
            address(seller).call(abi.encodeCall(seller.swapForEth, (USDG, amountIn, type(uint256).max, recipient)));
        return decodeShortfall(ok, ret);
    }

    function quoteBuy(uint256 ethIn) internal returns (uint256 received) {
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(swapper).call{value: ethIn}(
            abi.encodeCall(swapper.swapEthFor, (USDG, type(uint256).max, recipient))
        );
        return decodeShortfall(ok, ret);
    }

    function decodeShortfall(bool ok, bytes memory ret) internal pure returns (uint256 received) {
        assertTrue(!ok && ret.length == 68, "quote: expected InsufficientOutput");
        bytes4 sel;
        assembly {
            sel := mload(add(ret, 32))
            received := mload(add(ret, 36))
        }
        assertTrue(sel == SellSwapperBase.InsufficientOutput.selector, "quote: wrong error");
    }

    function test_seller_paysEth() public {
        if (!forked) return;
        fund(USDG, address(seller), 100e6);
        uint256 before = recipient.balance;
        uint256 pmUsdg = bal(POOL_MANAGER);
        uint256 spot = ethForUsdg(100e6);
        vm.prank(caller);
        uint256 out = seller.swapForEth(USDG, 100e6, 1, recipient);
        assertNearPrice(out, spot, "output follows the pool price");
        assertEq(recipient.balance - before, out, "recipient eth");
        assertEq(bal(POOL_MANAGER) - pmUsdg, 100e6, "pool took exactly the input");
        assertEq(bal(address(seller)), 0, "route usdg");
        assertEq(address(seller).balance, 0, "route eth");
        assertEq(bal(caller), 0, "no refund");
    }

    function test_swapper_paysUsdg() public {
        if (!forked) return;
        vm.deal(caller, 1 ether);
        uint256 before = bal(recipient);
        uint256 pmEth = POOL_MANAGER.balance;
        uint256 spot = usdgForEth(0.01 ether);
        vm.prank(caller);
        uint256 out = swapper.swapEthFor{value: 0.01 ether}(USDG, 1, recipient);
        assertNearPrice(out, spot, "output follows the pool price");
        assertEq(bal(recipient) - before, out, "recipient usdg");
        assertEq(POOL_MANAGER.balance - pmEth, 0.01 ether, "pool took exactly the input");
        assertEq(address(swapper).balance, 0, "route eth");
        assertEq(caller.balance, 1 ether - 0.01 ether, "no refund");
    }

    function test_wrongPool_reverts() public {
        if (!forked) return;
        PoolKey memory key = ethUsdgPool();
        key.currency0 = USDG;
        key.currency1 = address(0xBEEF);
        vm.expectRevert(UsdgSeller.WrongPool.selector);
        new UsdgSeller(USDG, POOL_MANAGER, key);
        vm.expectRevert(UsdgSwapper.WrongPool.selector);
        new UsdgSwapper(USDG, POOL_MANAGER, key);
        // A native pool against some other token is wrong too.
        key = ethUsdgPool();
        key.currency1 = address(0xBEEF);
        vm.expectRevert(UsdgSeller.WrongPool.selector);
        new UsdgSeller(USDG, POOL_MANAGER, key);
    }

    function test_pool_isReadable() public view {
        if (!forked) return;
        (address c0, address c1, uint24 fee, int24 spacing, address hooks) = seller.pool();
        assertEq(c0, address(0), "currency0");
        assertEq(c1, USDG, "currency1");
        assertEq(uint256(fee), 500, "fee");
        assertTrue(spacing == 10, "spacing");
        assertEq(hooks, address(0), "hooks");
        (c0, c1,,,) = swapper.pool();
        assertEq(c1, USDG, "swapper currency1");
    }

    function test_minimum_enforced() public {
        if (!forked) return;
        fund(USDG, address(seller), 100e6);
        uint256 got = quoteSell(100e6);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(SellSwapperBase.InsufficientOutput.selector, got, 100 ether));
        seller.swapForEth(USDG, 100e6, 100 ether, recipient);

        vm.deal(caller, 1 ether);
        got = quoteBuy(0.01 ether);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(SwapperBase.InsufficientOutput.selector, got, 1_000_000e6));
        swapper.swapEthFor{value: 0.01 ether}(USDG, 1_000_000e6, recipient);
    }

    /// A minimum equal to the output passes, and one unit more reverts, for both routes.
    function test_minimum_exactBoundary() public {
        if (!forked) return;
        fund(USDG, address(seller), 100e6);
        uint256 got = quoteSell(100e6);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(SellSwapperBase.InsufficientOutput.selector, got, got + 1));
        seller.swapForEth(USDG, 100e6, got + 1, recipient);
        vm.prank(caller);
        assertEq(seller.swapForEth(USDG, 100e6, got, recipient), got, "seller at the minimum");

        vm.deal(caller, 1 ether);
        got = quoteBuy(0.01 ether);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(SwapperBase.InsufficientOutput.selector, got, got + 1));
        swapper.swapEthFor{value: 0.01 ether}(USDG, got + 1, recipient);
        vm.prank(caller);
        assertEq(swapper.swapEthFor{value: 0.01 ether}(USDG, got, recipient), got, "swapper at the minimum");
    }

    function test_wrongToken_reverts() public {
        if (!forked) return;
        vm.expectRevert(SellSwapperBase.WrongToken.selector);
        seller.swapForEth(address(0xBEEF), 1, 0, recipient);
        vm.expectRevert(SwapperBase.WrongToken.selector);
        swapper.swapEthFor(address(0xBEEF), 0, recipient);
    }

    function test_directUnlockCallback_reverts() public {
        if (!forked) return;
        vm.expectRevert(V4ExactIn.NotPoolManager.selector);
        seller.unlockCallback("");
        vm.expectRevert(V4ExactIn.NotPoolManager.selector);
        swapper.unlockCallback("");
    }

    /// A balance the route already held before the call is not spent by the swap and does not reach the
    /// recipient. `SellSwapperBase` and `SwapperBase` return the route's whole leftover balance to the caller,
    /// so the 50 USDG and 0.5 ETH seeded here come back to the caller, not to the recipient and not lost.
    function test_preexistingBalances_goNowhereButTheCaller() public {
        if (!forked) return;
        fund(USDG, address(seller), 150e6);
        vm.deal(address(seller), 0.5 ether);
        // 50 USDG was already here; the caller pushed 100.
        uint256 recipientEth = recipient.balance;
        vm.prank(caller);
        uint256 out = seller.swapForEth(USDG, 100e6, 1, recipient);
        assertEq(recipient.balance - recipientEth, out, "recipient got exactly the swap output");
        assertEq(bal(address(seller)), 0, "seller usdg swept to the caller");
        assertEq(bal(caller), 50e6, "caller holds the seeded usdg");
        assertEq(address(seller).balance, 0.5 ether, "seller eth untouched by the usdg sell");

        fund(USDG, address(swapper), 50e6);
        vm.deal(address(swapper), 0.5 ether);
        vm.deal(caller, 1 ether);
        uint256 recipientUsdg = bal(recipient);
        vm.prank(caller);
        out = swapper.swapEthFor{value: 0.01 ether}(USDG, 1, recipient);
        assertEq(bal(recipient) - recipientUsdg, out, "recipient got exactly the swap output");
        assertEq(address(swapper).balance, 0, "swapper eth swept to the caller");
        assertEq(caller.balance, 1 ether - 0.01 ether + 0.5 ether, "caller holds the seeded eth");
        assertEq(bal(address(swapper)), 50e6, "swapper usdg untouched by the eth swap");
    }
}
