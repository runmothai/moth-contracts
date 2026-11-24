// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Vm} from "../utils/Test.sol";
import {RobinhoodFork, IERC20Like, IPonsFactory} from "./RobinhoodFork.sol";
import {PonsTokenSeller} from "../../src/swappers/PonsTokenSeller.sol";
import {PonsTokenBuyer} from "../../src/swappers/PonsTokenBuyer.sol";
import {PonsRoute} from "../../src/swappers/PonsRoute.sol";
import {SellSwapperBase} from "../../src/swappers/SellSwapperBase.sol";
import {SwapperBase} from "../../src/swappers/SwapperBase.sol";

/// Buys a native launch token with the ETH sent along, so the tests can hand tokens to a route on either venue.
contract TokenSource is PonsRoute {
    constructor(address poolManager_, address ponsFactory_) PonsRoute(poolManager_, ponsFactory_) {}

    function buy(address token, address recipient) external payable {
        _ponsBuy(token, msg.value, 1, recipient, msg.sender);
    }

    receive() external payable {}
}

/// Fork tests for the vault's $MOTH routes on a launch paired with native ETH. A Pons launch stands in for $MOTH.
/// The tests push the input to the route first, as the vault does, and check that the route holds nothing
/// afterwards.
contract TokenRoutesTest is RobinhoodFork {
    bytes32 internal constant CURVE_BUY_TOPIC =
        keccak256("CurveBuy(address,address,uint256,uint256,uint256,uint256)");
    bytes32 internal constant CURVE_REFUND_TOPIC = keccak256("CurveBuyRefunded(address,uint256)");
    /// The Pons curve's own slippage error. On the curve the minimum is passed to the curve, which reverts before
    /// the route's checks are reached.
    bytes4 internal constant CURVE_SLIPPAGE_SELECTOR = bytes4(keccak256("SlippageExceeded(uint256,uint256)"));
    /// A minimum no trade can meet. Not `type(uint256).max`: that makes the curve panic on overflow while it prices.
    uint256 internal constant TOO_MUCH = 1e30;

    address internal recipient = address(0xCAFE);

    function setUp() public override {
        super.setUp();
        if (!forked) return;
        vm.deal(address(this), 100 ether);
    }

    function bal(address token, address who) internal view returns (uint256) {
        return IERC20Like(token).balanceOf(who);
    }

    function newSeller(address token) internal returns (PonsTokenSeller) {
        return new PonsTokenSeller(token, POOL_MANAGER, PONS_FACTORY);
    }

    function newBuyer(address token) internal returns (PonsTokenBuyer) {
        return new PonsTokenBuyer(token, POOL_MANAGER, PONS_FACTORY);
    }

    function curveToken() internal returns (address token) {
        (token,) = launchTestToken();
        vm.warp(block.timestamp + SNIPE_WINDOW);
    }

    function poolToken() internal returns (address token) {
        (token,) = launchTestToken();
        buyToGraduation(token);
        createPool(token);
    }

    /// Gives `to` tokens by buying them with `ethSpend` on whichever venue the launch is on.
    function giveToken(address token, address to, uint256 ethSpend) internal {
        TokenSource source = new TokenSource(POOL_MANAGER, PONS_FACTORY);
        source.buy{value: ethSpend}(token, to);
    }

    function assertEmpty(address route, address token) internal view {
        assertEq(bal(token, route), 0, "route token");
        assertEq(route.balance, 0, "route eth");
    }

    /// The first four bytes of revert data, the error's selector.
    function selectorOf(bytes memory ret) internal pure returns (bytes4) {
        // Keeping only the first four bytes, the selector, is the point of this cast.
        // forge-lint: disable-next-line(unsafe-typecast)
        return bytes4(ret);
    }

    function sellCase(address token) internal {
        PonsTokenSeller route = newSeller(token);
        giveToken(token, address(route), 0.05 ether);
        uint256 amountIn = bal(token, address(route));
        assertTrue(amountIn > 0, "token in");
        uint256 callerTokenBefore = bal(token, address(this));
        uint256 before = recipient.balance;
        uint256 out = route.swapForEth(token, amountIn, 1, recipient);
        assertTrue(out > 0, "eth out");
        assertEq(recipient.balance - before, out, "recipient eth");
        assertEq(bal(token, address(this)), callerTokenBefore, "the whole input was sold");
        assertEmpty(address(route), token);
    }

    function buyCase(address token) internal {
        PonsTokenBuyer route = newBuyer(token);
        uint256 callerBefore = address(this).balance;
        uint256 before = bal(token, recipient);
        uint256 out = route.swapEthFor{value: 0.05 ether}(token, 1, recipient);
        assertTrue(out > 0, "token out");
        assertEq(bal(token, recipient) - before, out, "recipient token");
        assertEq(callerBefore - address(this).balance, 0.05 ether, "the whole input was spent");
        assertEmpty(address(route), token);
    }

    function test_tokenSeller_paysEth_onCurve() public {
        if (!forked) return;
        sellCase(curveToken());
    }

    function test_tokenSeller_paysEth_inPool() public {
        if (!forked) return;
        sellCase(poolToken());
    }

    function test_tokenBuyer_paysToken_onCurve() public {
        if (!forked) return;
        buyCase(curveToken());
    }

    function test_tokenBuyer_paysToken_inPool() public {
        if (!forked) return;
        buyCase(poolToken());
    }

    /// A buy larger than what is left on the curve completes it. The curve spends part of the ETH and refunds the
    /// rest to the route, which passes it to its caller once: the caller's ETH falls by exactly what the curve took,
    /// as the curve's own `CurveBuy` event reports it, and the route keeps nothing.
    function test_buyer_partialLastBuy_refundsCallerOnce() public {
        if (!forked) return;
        address token = curveToken();
        PonsTokenBuyer route = newBuyer(token);
        uint256 amount = graduationBuyEth(token);
        uint256 callerBefore = address(this).balance;

        vm.recordLogs();
        uint256 out = route.swapEthFor{value: amount}(token, 1, recipient);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        address curve = IPonsFactory(PONS_FACTORY).getLaunchedToken(token).curve;
        uint256 curveTook;
        uint256 curveRefund;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != curve) continue;
            if (logs[i].topics[0] == CURVE_BUY_TOPIC) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(route), "curve buyer");
                (curveTook,,,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            }
            if (logs[i].topics[0] == CURVE_REFUND_TOPIC) curveRefund = abi.decode(logs[i].data, (uint256));
        }

        assertTrue(out > 0, "token out");
        assertEq(uint256(IPonsFactory(PONS_FACTORY).getLaunchedToken(token).phase), 1, "the buy completed the curve");
        assertTrue(curveRefund > 0, "the curve refunded part of the buy");
        assertEq(curveTook + curveRefund, amount, "the curve took or refunded every wei");
        assertEq(callerBefore - address(this).balance, curveTook, "caller paid exactly what the curve took");
        assertEmpty(address(route), token);
    }

    /// Both routes, on the curve and again in the pool: after each call the route holds no token and no ETH.
    function test_routesHoldNothing() public {
        if (!forked) return;
        address token = curveToken();
        buyCase(token);
        sellCase(token);

        address pooled = poolToken();
        buyCase(pooled);
        sellCase(pooled);
    }

    /// A minimum no trade can meet reverts on each route and venue, and nothing stays in the route. On the curve
    /// the curve's own slippage check refuses first; in the pool the route checks what the recipient received.
    function test_minimum_enforced() public {
        if (!forked) return;
        address token = curveToken();
        expectBuyRevert(token, CURVE_SLIPPAGE_SELECTOR);
        expectSellRevert(token, CURVE_SLIPPAGE_SELECTOR);

        address pooled = poolToken();
        expectBuyRevert(pooled, PonsRoute.RouteInsufficientOutput.selector);
        expectSellRevert(pooled, PonsRoute.RouteInsufficientOutput.selector);
    }

    function expectBuyRevert(address token, bytes4 selector) internal {
        PonsTokenBuyer route = newBuyer(token);
        uint256 callerBefore = address(this).balance;
        (bool ok, bytes memory ret) =
            address(route).call{value: 0.05 ether}(abi.encodeCall(route.swapEthFor, (token, TOO_MUCH, recipient)));
        assertTrue(!ok, "buy reverted");
        assertEq(bytes32(selectorOf(ret)), bytes32(selector), "buy revert selector");
        assertEq(address(this).balance, callerBefore, "caller eth unchanged");
        assertEmpty(address(route), token);
    }

    function expectSellRevert(address token, bytes4 selector) internal {
        PonsTokenSeller route = newSeller(token);
        giveToken(token, address(route), 0.05 ether);
        uint256 amountIn = bal(token, address(route));
        (bool ok, bytes memory ret) =
            address(route).call(abi.encodeCall(route.swapForEth, (token, amountIn, TOO_MUCH, recipient)));
        assertTrue(!ok, "sell reverted");
        assertEq(bytes32(selectorOf(ret)), bytes32(selector), "sell revert selector");
        // The revert rolls the trade back, so the pushed input is still in the route for its pusher to deal with.
        assertEq(bal(token, address(route)), amountIn, "input not moved");
        assertEq(address(route).balance, 0, "route eth");
    }

    /// A route trades only its own token, and only a token Pons launched against native ETH. Asking for another
    /// token fails the base check; a route built for a token the factory does not know, or for a USDG-paired
    /// launch, fails the pair check before anything moves.
    function test_wrongToken_reverts() public {
        if (!forked) return;
        address token = curveToken();
        PonsTokenSeller seller = newSeller(token);
        PonsTokenBuyer buyer_ = newBuyer(token);
        vm.expectRevert(SellSwapperBase.WrongToken.selector);
        seller.swapForEth(USDG, 1, 0, recipient);
        vm.expectRevert(SwapperBase.WrongToken.selector);
        buyer_.swapEthFor{value: 0.05 ether}(USDG, 0, recipient);

        // The factory answers an unknown token with an empty record, whose pair is the zero address.
        UnknownToken unknown = new UnknownToken();
        assertTrue(!IPonsFactory(PONS_FACTORY).getLaunchedToken(address(unknown)).exists, "unknown");
        unknown.mint(address(this), 1e18);
        expectWrongPair(address(unknown));

        // A USDG-paired launch, with tokens bought on its curve for the sale.
        (address usdgToken, address usdgCurve) = launchUsdgTestToken();
        vm.warp(block.timestamp + SNIPE_WINDOW);
        fund(USDG, address(this), 100e6);
        IERC20Like(USDG).approve(usdgCurve, 100e6);
        IPonsCurveBuy(usdgCurve).buy(100e6, 1, address(this));
        expectWrongPair(usdgToken);
    }

    /// Both routes for `token` refuse it, with the caller's ETH and the pushed token left where they were.
    function expectWrongPair(address token) internal {
        PonsTokenBuyer buyer_ = newBuyer(token);
        uint256 callerBefore = address(this).balance;
        vm.expectRevert(PonsRoute.WrongPair.selector);
        buyer_.swapEthFor{value: 0.05 ether}(token, 0, recipient);
        assertEq(address(this).balance, callerBefore, "caller eth unchanged");

        PonsTokenSeller seller = newSeller(token);
        uint256 held = bal(token, address(this));
        assertTrue(held > 0, "tokens to push");
        assertTrue(IERC20Transfer(token).transfer(address(seller), held), "pushed");
        vm.expectRevert(PonsRoute.WrongPair.selector);
        seller.swapForEth(token, held, 0, recipient);
        assertEq(bal(token, address(seller)), held, "input not moved");
    }

    receive() external payable {}
}

interface IPonsCurveBuy {
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256);
}

interface IERC20Transfer {
    function transfer(address to, uint256 amount) external returns (bool);
}

/// A plain ERC-20 the factory never launched.
contract UnknownToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
