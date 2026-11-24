// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {RobinhoodFork, IERC20Like} from "./RobinhoodFork.sol";
import {PonsRoute} from "../../src/swappers/PonsRoute.sol";
import {IPonsV2Factory, GraduationPhase} from "../../src/interfaces/IPonsV2.sol";

/// A concrete holder that exposes the internal native route. A buy brings its ETH with the call and a sell's
/// token is pushed here first, as the vault does. `receive()` takes the curve's refund and a pool's ETH.
contract PonsRouteEthHarness is PonsRoute {
    constructor(address poolManager_, address ponsFactory_) PonsRoute(poolManager_, ponsFactory_) {}

    function buy(address token, uint256 minTokenOut, address recipient) external payable returns (uint256) {
        return _ponsBuy(token, msg.value, minTokenOut, recipient, msg.sender);
    }

    /// Like `buy`, but any ETH the trade did not use stays here.
    function buyKeep(address token, uint256 minTokenOut, address recipient) external payable returns (uint256) {
        return _ponsBuy(token, msg.value, minTokenOut, recipient, address(this));
    }

    function sell(address token, uint256 tokenIn, uint256 minEthOut, address recipient) external returns (uint256) {
        return _ponsSell(token, tokenIn, minEthOut, recipient, msg.sender);
    }

    receive() external payable {}
}

contract PonsRouteEthTest is RobinhoodFork {
    PonsRouteEthHarness internal route;
    /// An address with no history is not guaranteed on a fork, so the tests compare against the balance before.
    address internal recipient = address(0xCAFE);

    /// The test contract is the route's caller, so refunds come back here.
    receive() external payable {}

    function setUp() public override {
        super.setUp();
        if (!forked) return;
        route = new PonsRouteEthHarness(POOL_MANAGER, PONS_FACTORY);
        vm.deal(address(this), 100 ether);
    }

    function bal(address token, address who) internal view returns (uint256) {
        return IERC20Like(token).balanceOf(who);
    }

    /// A native launch past the snipe window, still on the curve.
    function curveToken() internal returns (address token, address curve) {
        (token, curve) = launchTestToken();
        vm.warp(block.timestamp + SNIPE_WINDOW);
    }

    function poolToken() internal returns (address token) {
        (token,) = launchTestToken();
        buyToGraduation(token);
        createPool(token);
    }

    function assertRouteEmpty(address token) internal view {
        assertEq(address(route).balance, 0, "route eth");
        assertEq(bal(token, address(route)), 0, "route token");
    }

    function test_buy_onCurve() public {
        if (!forked) return;
        (address token,) = curveToken();
        uint256 before = bal(token, recipient);
        uint256 out = route.buy{value: 0.1 ether}(token, 1, recipient);
        assertTrue(out > 0, "amount out");
        assertEq(bal(token, recipient) - before, out, "recipient token");
        assertRouteEmpty(token);
    }

    function test_sell_onCurve() public {
        if (!forked) return;
        (address token, address curve) = curveToken();
        uint256 held = route.buy{value: 0.1 ether}(token, 1, address(route));
        assertEq(bal(token, address(route)), held, "route token");
        uint256 before = recipient.balance;
        uint256 out = route.sell(token, held, 1, recipient);
        assertTrue(out > 0, "amount out");
        assertEq(recipient.balance - before, out, "recipient eth");
        assertRouteEmpty(token);
        assertEq(IERC20Like(token).allowance(address(route), curve), 0, "curve allowance reset");
    }

    function test_buy_inPool() public {
        if (!forked) return;
        address token = poolToken();
        uint256 before = bal(token, recipient);
        uint256 out = route.buy{value: 0.1 ether}(token, 1, recipient);
        assertTrue(out > 0, "amount out");
        assertEq(bal(token, recipient) - before, out, "recipient token");
        assertRouteEmpty(token);
    }

    function test_sell_inPool() public {
        if (!forked) return;
        address token = poolToken();
        uint256 held = route.buy{value: 0.1 ether}(token, 1, address(route));
        uint256 before = recipient.balance;
        uint256 out = route.sell(token, held, 1, recipient);
        assertTrue(out > 0, "amount out");
        assertEq(recipient.balance - before, out, "recipient eth");
        assertRouteEmpty(token);
    }

    function test_sweptPhase_reverts() public {
        if (!forked) return;
        (address token,) = launchTestToken();
        buyToGraduation(token);
        assertEq(
            uint256(IPonsV2Factory(PONS_FACTORY).getLaunchedToken(token).phase), uint256(GraduationPhase.Swept), "phase"
        );
        vm.expectRevert(abi.encodeWithSelector(PonsRoute.RouteUnavailable.selector, uint8(1)));
        route.buy{value: 0.1 ether}(token, 0, recipient);
        vm.expectRevert(abi.encodeWithSelector(PonsRoute.RouteUnavailable.selector, uint8(1)));
        route.sell(token, 1e18, 0, recipient);
        assertEq(address(route).balance, 0, "route eth");
    }

    function test_partialLastBuy_refundsCaller() public {
        if (!forked) return;
        (address token,) = curveToken();
        uint256 amount = graduationBuyEth(token);
        uint256 callerBefore = address(this).balance;
        uint256 out = route.buy{value: amount}(token, 0, recipient);
        assertTrue(out > 0, "amount out");
        uint256 spent = callerBefore - address(this).balance;
        assertTrue(spent > 0, "something was spent");
        assertTrue(spent < amount, "caller refunded");
        // The buy completed the curve, which proves it was the partial, graduating one.
        assertEq(
            uint256(IPonsV2Factory(PONS_FACTORY).getLaunchedToken(token).phase), uint256(GraduationPhase.Swept), "Swept"
        );
        assertRouteEmpty(token);
    }

    function test_refundToSelf_keepsEth() public {
        if (!forked) return;
        (address token,) = curveToken();
        uint256 amount = graduationBuyEth(token);
        uint256 callerBefore = address(this).balance;
        uint256 out = route.buyKeep{value: amount}(token, 0, recipient);
        assertTrue(out > 0, "amount out");
        assertEq(callerBefore - address(this).balance, amount, "caller not refunded");
        uint256 kept = address(route).balance;
        assertTrue(kept > 0, "route kept the refund");
        assertTrue(kept < amount, "something was spent");
    }

    function test_minimum_enforced() public {
        if (!forked) return;
        // On the curve the curve's own price bound refuses the buy.
        (address token,) = curveToken();
        vm.expectRevert();
        route.buy{value: 0.1 ether}(token, type(uint128).max, recipient);

        // In the pool the route checks the amount the recipient received. It is only known after the swap, so
        // the test matches the error's selector alone.
        address pooled = poolToken();
        (bool ok, bytes memory ret) = address(route).call{value: 0.1 ether}(
            abi.encodeCall(PonsRouteEthHarness.buy, (pooled, type(uint128).max, recipient))
        );
        assertTrue(!ok, "buy reverted");
        // Keeping only the first four bytes, the selector, is the point of this cast.
        // forge-lint: disable-next-line(unsafe-typecast)
        assertTrue(bytes4(ret) == PonsRoute.RouteInsufficientOutput.selector, "RouteInsufficientOutput");
        assertRouteEmpty(pooled);
    }

    function test_unknownToken_reverts() public {
        if (!forked) return;
        // The factory answers an unknown token with an empty record, whose pair is the zero address.
        assertTrue(!IPonsV2Factory(PONS_FACTORY).getLaunchedToken(address(0xDEAD)).exists, "unknown");
        vm.expectRevert(PonsRoute.WrongPair.selector);
        route.buy{value: 0.1 ether}(address(0xDEAD), 0, recipient);
        vm.expectRevert(PonsRoute.WrongPair.selector);
        route.sell(address(0xDEAD), 1e18, 0, recipient);
    }

    function test_usdgPairedToken_reverts() public {
        if (!forked) return;
        (address token,) = launchUsdgTestToken();
        vm.expectRevert(PonsRoute.WrongPair.selector);
        route.buy{value: 0.1 ether}(token, 0, recipient);
        vm.expectRevert(PonsRoute.WrongPair.selector);
        route.sell(token, 1e18, 0, recipient);
    }

    function test_routeHoldsNothing() public {
        if (!forked) return;
        (address token,) = curveToken();
        route.buy{value: 0.1 ether}(token, 1, recipient);
        assertRouteEmpty(token);
        uint256 held = route.buy{value: 0.1 ether}(token, 1, address(route));
        route.sell(token, held, 1, recipient);
        assertRouteEmpty(token);

        address pooled = poolToken();
        route.buy{value: 0.1 ether}(pooled, 1, recipient);
        assertRouteEmpty(pooled);
        held = route.buy{value: 0.1 ether}(pooled, 1, address(route));
        route.sell(pooled, held, 1, recipient);
        assertRouteEmpty(pooled);
    }
}
