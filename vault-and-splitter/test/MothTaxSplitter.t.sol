// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {MothTaxSplitter} from "../src/MothTaxSplitter.sol";
import {PonsRoute} from "../src/swappers/PonsRoute.sol";
import {V4ExactIn} from "../src/swappers/V4ExactIn.sol";
import {GraduationPhase} from "../src/interfaces/IPonsV2.sol";
import {
    MockERC20,
    MockEscrow,
    MockPonsCurve,
    MockPonsFactory,
    MockPonsHook,
    MockSwapper,
    ReentrantEscrow,
    ReentrantReceiver,
    ReentrantSwapper,
    RejectingReceiver
} from "./utils/Mocks.sol";
import {Test, Vm} from "./utils/Test.sol";

/// Offline tests of the splitter against a mock escrow paying ETH, a mock Pons factory, curve and hook for a native
/// launch, and a mock USDG route. The real route code runs (`PonsRoute._ponsBuy`); only Pons and the USDG route are
/// mocked. The real Pons contracts and the real USDG route are covered by test/fork/Splitter.t.sol.
contract MothTaxSplitterTest is Test {
    address constant OWNER = address(0x0E1);
    address constant NEW_OWNER = address(0x0E2);
    address constant KEEPER = address(0x4EE9);
    address constant STRANGER = address(0xBAD);
    address constant DEV = address(0xDE5);
    address constant DEV2 = address(0xDE52);
    address constant CREDIT = address(0xC4ED17);
    address constant CREDIT2 = address(0xC4ED172);
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant POOL_MANAGER = address(0xB001);

    /// 1,000,000 $MOTH per ETH on the mock curve, and 3,000 USDG per ETH on the mock USDG route.
    uint256 constant TOKEN_PER_ETH = 1_000_000e18;
    uint256 constant USDG_PER_ETH = 3_000e6;

    /// The default split of 1 ETH: 833, 2,500 and 6,667 basis points.
    uint256 constant BURN_OF_ONE = 0.0833 ether;
    uint256 constant CREDIT_OF_ONE = 0.25 ether;
    uint256 constant DEV_OF_ONE = 0.6667 ether;
    uint256 constant TOKENS_OF_ONE = 83_300e18;
    uint256 constant USDG_OF_ONE = 750e6;

    MockERC20 token;
    MockERC20 usdg;
    MockEscrow escrow;
    MockPonsFactory factory;
    MockPonsCurve curve;
    MockPonsHook hook;
    MockSwapper usdgBuyer;
    MothTaxSplitter splitter;

    function setUp() public {
        token = new MockERC20(18);
        usdg = new MockERC20(6);
        escrow = new MockEscrow();
        factory = new MockPonsFactory();
        curve = new MockPonsCurve(token, TOKEN_PER_ETH);
        hook = new MockPonsHook();
        usdgBuyer = new MockSwapper(usdg, USDG_PER_ETH);
        vm.etch(POOL_MANAGER, hex"00"); // the constructor wants code at the pool manager
        factory.setLaunch(address(token), address(curve), GraduationPhase.NotGraduated, 3_000, 60);
        factory.setHook(address(hook));
        splitter = deploy(address(token), address(escrow));
    }

    function deploy(address token_, address escrow_) internal returns (MothTaxSplitter) {
        vm.prank(OWNER);
        return new MothTaxSplitter(
            token_, address(usdg), POOL_MANAGER, address(factory), escrow_, KEEPER, DEV, CREDIT, address(usdgBuyer)
        );
    }

    function distribute(uint256 minTokenOut, uint256 minUsdgOut) internal returns (uint256, uint256, uint256, uint256) {
        vm.prank(KEEPER);
        return splitter.distribute(minTokenOut, minUsdgOut);
    }

    function distribute() internal returns (uint256, uint256, uint256, uint256) {
        return distribute(0, 0);
    }

    function setSplit(uint16 b, uint16 c, uint16 d) internal {
        vm.prank(OWNER);
        splitter.setSplit(b, c, d);
    }

    function fundSplitter(uint256 amount) internal {
        vm.deal(address(splitter), address(splitter).balance + amount);
    }

    function creditEscrow(uint256 amount) internal {
        vm.deal(address(this), amount);
        escrow.credit{value: amount}(address(splitter));
    }

    // ---------------------------------------------------------------- defaults and split maths

    function test_defaults() public view {
        assertEq(splitter.owner(), OWNER, "owner is the deployer");
        assertEq(splitter.pendingOwner(), address(0), "no pending owner");
        assertEq(splitter.keeper(), KEEPER, "keeper");
        assertEq(splitter.devWallet(), DEV, "dev wallet");
        assertEq(splitter.creditTarget(), CREDIT, "credit target");
        assertEq(address(splitter.token()), address(token), "token");
        assertEq(splitter.usdg(), address(usdg), "usdg");
        assertEq(address(splitter.usdgBuyer()), address(usdgBuyer), "usdg buyer");
        assertEq(address(splitter.feeEscrow()), address(escrow), "escrow");
        assertEq(address(splitter.ponsFactory()), address(factory), "factory");
        assertEq(address(splitter.poolManager()), POOL_MANAGER, "pool manager");
        assertEq(splitter.DEAD(), DEAD, "dead address");
        assertEq(splitter.burnBps(), 833, "burn bps");
        assertEq(splitter.creditBps(), 2_500, "credit bps");
        assertEq(splitter.devBps(), 6_667, "dev bps");
    }

    function test_distribute_splitsEth() public {
        fundSplitter(1 ether);
        (uint256 ethIn, uint256 burned, uint256 credited, uint256 toDev) = distribute();
        assertEq(ethIn, 1 ether, "eth in");
        assertEq(address(curve).balance, BURN_OF_ONE, "the curve took the burn share");
        assertEq(burned, TOKENS_OF_ONE, "tokens burned: 0.0833 ETH bought on the curve");
        assertEq(token.balanceOf(DEAD), TOKENS_OF_ONE, "burn reached the dead address");
        assertEq(address(usdgBuyer).balance, CREDIT_OF_ONE, "the USDG route took the credit share");
        assertEq(credited, USDG_OF_ONE, "usdg to credit");
        assertEq(toDev, DEV_OF_ONE, "dev share");
        assertEq(DEV.balance, DEV_OF_ONE, "dev paid in ETH");
        assertEq(address(splitter).balance, 0, "no ETH left");
        assertEq(token.balanceOf(address(splitter)), 0, "no token left");
        assertEq(usdg.balanceOf(address(splitter)), 0, "no USDG left");
    }

    function test_creditShare_reachesTargetAsUsdg() public {
        fundSplitter(1 ether);
        (,, uint256 credited,) = distribute(0, 700e6);
        assertEq(usdgBuyer.calls(), 1, "one swap");
        assertEq(usdgBuyer.lastEthIn(), CREDIT_OF_ONE, "the credit share in ETH");
        assertEq(usdgBuyer.lastMinOut(), 700e6, "the keeper's minimum passed on");
        assertEq(usdgBuyer.lastRecipient(), CREDIT, "straight to the credit target");
        assertEq(usdg.balanceOf(CREDIT), USDG_OF_ONE, "credit target paid in USDG");
        assertEq(credited, USDG_OF_ONE, "reported");
        assertEq(CREDIT.balance, 0, "no ETH to the credit target");
    }

    /// The splitter reports what reached the credit target, measured there, not what the route says.
    function test_creditIsMeasuredAtTheTarget() public {
        usdg.mint(CREDIT, 5e6); // the target already holds some
        usdgBuyer.setShortBy(1e6);
        fundSplitter(1 ether);
        (,, uint256 credited,) = distribute();
        assertEq(credited, USDG_OF_ONE - 1e6, "the measured gain");
        assertEq(usdg.balanceOf(CREDIT), 5e6 + USDG_OF_ONE - 1e6, "target balance");
    }

    function test_devShare_paidInEth() public {
        fundSplitter(3 ether);
        (,,, uint256 toDev) = distribute();
        assertEq(toDev, 3 * DEV_OF_ONE, "three times the share of one");
        assertEq(DEV.balance, 3 * DEV_OF_ONE, "paid in ETH");
        assertEq(usdg.balanceOf(DEV), 0, "no USDG to dev");
        assertEq(token.balanceOf(DEV), 0, "no token to dev");
    }

    function testFuzz_splitMaths(uint256 amount, uint256 b, uint256 c) public {
        amount = bound(amount, 1, 1e24);
        b = bound(b, 0, 10_000);
        c = bound(c, 0, 10_000 - b);
        uint256 d = 10_000 - b - c;
        setSplit(uint16(b), uint16(c), uint16(d));
        fundSplitter(amount);
        (uint256 ethIn, uint256 burned, uint256 credited, uint256 toDev) = distribute();

        uint256 burnEth = (amount * b) / 10_000;
        uint256 creditEth = (amount * c) / 10_000;
        assertEq(ethIn, amount, "eth in");
        assertEq(curve.buyCalls(), burnEth == 0 ? 0 : 1, "burn buy only when the share is not zero");
        assertEq(usdgBuyer.calls(), creditEth == 0 ? 0 : 1, "credit swap only when the share is not zero");
        assertEq(address(curve).balance, burnEth, "burn share");
        assertEq(address(usdgBuyer).balance, creditEth, "credit share");
        assertEq(burned, (burnEth * TOKEN_PER_ETH) / 1 ether, "tokens burned");
        assertEq(credited, (creditEth * USDG_PER_ETH) / 1 ether, "usdg credited");
        assertEq(toDev, amount - burnEth - creditEth, "dev takes the rest");
        assertEq(DEV.balance, toDev, "dev paid");
        assertEq(usdg.balanceOf(CREDIT), credited, "credit paid");
        assertEq(burnEth + creditEth + toDev, amount, "nothing lost");
        // The dev share is never less than its own rounded-down share, and gains at most two units of dust.
        assertTrue(toDev >= (amount * d) / 10_000 && toDev - (amount * d) / 10_000 <= 2, "dust bound");
        assertEq(address(splitter).balance, 0, "balance emptied");
    }

    function test_dustGoesToDev() public {
        fundSplitter(1 ether + 7);
        (,,, uint256 toDev) = distribute();
        assertEq(address(curve).balance, BURN_OF_ONE, "burn rounds down");
        assertEq(address(usdgBuyer).balance, CREDIT_OF_ONE + 1, "credit rounds down");
        // 6,667 bps of 7 wei is 4.67; dev gets the 2 wei the other shares round off.
        assertEq(toDev, DEV_OF_ONE + 6, "dev gets the dust");
    }

    function test_tinyAmountsSkipTheBuyWhoseShareRoundsToZero() public {
        fundSplitter(11);
        (,, uint256 credited, uint256 toDev) = distribute();
        assertEq(curve.buyCalls(), 0, "11 * 833 / 10000 rounds to 0: no burn buy");
        assertEq(address(usdgBuyer).balance, 2, "credit share");
        assertEq(credited, 0, "2 wei buys no USDG unit");
        assertEq(toDev, 9, "dev share");
    }

    // ---------------------------------------------------------------- access

    function test_onlyTheKeeperDistributes() public {
        fundSplitter(1 ether);
        vm.prank(STRANGER);
        vm.expectRevert(MothTaxSplitter.Unauthorized.selector);
        splitter.distribute(0, 0);
        vm.prank(OWNER);
        vm.expectRevert(MothTaxSplitter.Unauthorized.selector);
        splitter.distribute(0, 0);
        distribute();

        vm.prank(OWNER);
        splitter.setKeeper(address(0));
        fundSplitter(1 ether);
        vm.prank(KEEPER);
        vm.expectRevert(MothTaxSplitter.Unauthorized.selector);
        splitter.distribute(0, 0);
    }

    function test_settersAreOwnerOnly() public {
        address[2] memory callers = [STRANGER, KEEPER];
        for (uint256 i = 0; i < callers.length; i++) {
            vm.startPrank(callers[i]);
            vm.expectRevert(MothTaxSplitter.Unauthorized.selector);
            splitter.setSplit(10_000, 0, 0);
            vm.expectRevert(MothTaxSplitter.Unauthorized.selector);
            splitter.setDevWallet(STRANGER);
            vm.expectRevert(MothTaxSplitter.Unauthorized.selector);
            splitter.setCreditTarget(STRANGER);
            vm.expectRevert(MothTaxSplitter.Unauthorized.selector);
            splitter.setKeeper(STRANGER);
            vm.expectRevert(MothTaxSplitter.Unauthorized.selector);
            splitter.setToken(STRANGER);
            vm.expectRevert(MothTaxSplitter.Unauthorized.selector);
            splitter.setUsdgBuyer(STRANGER);
            vm.expectRevert(MothTaxSplitter.Unauthorized.selector);
            splitter.transferOwnership(callers[i]);
            vm.stopPrank();
        }
        assertEq(splitter.devWallet(), DEV, "unchanged");
        assertEq(splitter.keeper(), KEEPER, "unchanged");
    }

    function test_settersRejectZeroRecipients() public {
        vm.startPrank(OWNER);
        vm.expectRevert(MothTaxSplitter.ZeroAddress.selector);
        splitter.setDevWallet(address(0));
        vm.expectRevert(MothTaxSplitter.ZeroAddress.selector);
        splitter.setCreditTarget(address(0));
        vm.stopPrank();
    }

    function test_setUsdgBuyer_ownerOnly_andEmits() public {
        MockSwapper next = new MockSwapper(usdg, USDG_PER_ETH);
        vm.prank(STRANGER);
        vm.expectRevert(MothTaxSplitter.Unauthorized.selector);
        splitter.setUsdgBuyer(address(next));
        vm.prank(KEEPER);
        vm.expectRevert(MothTaxSplitter.Unauthorized.selector);
        splitter.setUsdgBuyer(address(next));
        assertEq(address(splitter.usdgBuyer()), address(usdgBuyer), "unchanged");

        vm.prank(OWNER);
        vm.expectEmit(true, true, true, true, address(splitter));
        emit MothTaxSplitter.UsdgBuyerChanged(address(next));
        splitter.setUsdgBuyer(address(next));
        assertEq(address(splitter.usdgBuyer()), address(next), "changed");

        // The next distribute swaps through the new route.
        fundSplitter(1 ether);
        distribute();
        assertEq(next.calls(), 1, "new route used");
        assertEq(usdgBuyer.calls(), 0, "old route not used");

        // Zero is allowed: it unsets the route.
        vm.prank(OWNER);
        vm.expectEmit(true, true, true, true, address(splitter));
        emit MothTaxSplitter.UsdgBuyerChanged(address(0));
        splitter.setUsdgBuyer(address(0));
        assertEq(address(splitter.usdgBuyer()), address(0), "unset");
    }

    // ---------------------------------------------------------------- the split

    function test_splitMustSumTo10000() public {
        vm.startPrank(OWNER);
        vm.expectRevert(MothTaxSplitter.InvalidSplit.selector);
        splitter.setSplit(833, 2_500, 6_666);
        vm.expectRevert(MothTaxSplitter.InvalidSplit.selector);
        splitter.setSplit(10_000, 0, 1);
        vm.expectRevert(MothTaxSplitter.InvalidSplit.selector);
        splitter.setSplit(0, 0, 0);
        vm.expectRevert(MothTaxSplitter.InvalidSplit.selector);
        splitter.setSplit(type(uint16).max, type(uint16).max, 10_000);
        splitter.setSplit(10_000, 0, 0);
        splitter.setSplit(0, 10_000, 0);
        splitter.setSplit(0, 0, 10_000);
        splitter.setSplit(1, 2, 9_997);
        vm.stopPrank();
        assertEq(splitter.burnBps(), 1, "burn");
        assertEq(splitter.creditBps(), 2, "credit");
        assertEq(splitter.devBps(), 9_997, "dev");
    }

    function testFuzz_splitSumRule(uint16 b, uint16 c, uint16 d) public {
        vm.prank(OWNER);
        if (uint256(b) + c + d != 10_000) vm.expectRevert(MothTaxSplitter.InvalidSplit.selector);
        splitter.setSplit(b, c, d);
    }

    function test_allBurnBuysWithEverythingAndPaysNoOne() public {
        setSplit(10_000, 0, 0);
        fundSplitter(2 ether);
        (, uint256 burned, uint256 credited, uint256 toDev) = distribute(2_000_000e18, 0);
        assertEq(address(curve).balance, 2 ether, "all of it buys the token");
        assertEq(burned, 2_000_000e18, "all burned");
        assertEq(credited, 0, "nothing credited");
        assertEq(toDev, 0, "nothing to dev");
        assertEq(usdgBuyer.calls(), 0, "no swap");
        assertEq(DEV.balance, 0, "dev unpaid");
        assertEq(usdg.balanceOf(CREDIT), 0, "credit unpaid");
    }

    function test_allCreditMakesNoBuy() public {
        setSplit(0, 10_000, 0);
        fundSplitter(1 ether);
        (, uint256 burned, uint256 credited, uint256 toDev) = distribute();
        assertEq(curve.buyCalls(), 0, "no burn buy");
        assertEq(burned, 0, "nothing burned");
        assertEq(credited, 3_000e6, "all of it to credit");
        assertEq(usdg.balanceOf(CREDIT), 3_000e6, "credit target paid");
        assertEq(toDev, 0, "nothing to dev");
        assertEq(DEV.balance, 0, "dev unpaid");
    }

    function test_allDevNeedsNoPonsCallAndNoRoute() public {
        setSplit(0, 0, 10_000);
        // A factory that always fails proves the split makes no Pons call when the burn share is zero. The
        // fee sweep still reads it, and reports the failure without stopping anything.
        vm.etch(address(factory), hex"fe");
        vm.prank(OWNER);
        splitter.setUsdgBuyer(address(0));
        fundSplitter(1 ether);
        distribute();
        assertEq(DEV.balance, 1 ether, "all to dev");
    }

    function test_splitChangesTakeEffectOnTheNextDistribute() public {
        fundSplitter(1 ether);
        distribute();
        assertEq(DEV.balance, DEV_OF_ONE, "default split first");
        setSplit(5_000, 5_000, 0);
        fundSplitter(1 ether);
        distribute();
        assertEq(DEV.balance, DEV_OF_ONE, "no dev share the second time");
        assertEq(address(curve).balance, BURN_OF_ONE + 0.5 ether, "half bought the token");
        assertEq(usdg.balanceOf(CREDIT), USDG_OF_ONE + 1_500e6, "half credited");
    }

    function test_recipientChangesTakeEffectOnTheNextDistribute() public {
        fundSplitter(1 ether);
        distribute();
        vm.startPrank(OWNER);
        splitter.setDevWallet(DEV2);
        splitter.setCreditTarget(CREDIT2);
        vm.stopPrank();
        fundSplitter(1 ether);
        distribute();
        assertEq(DEV.balance, DEV_OF_ONE, "old dev wallet paid once");
        assertEq(DEV2.balance, DEV_OF_ONE, "new dev wallet paid");
        assertEq(usdg.balanceOf(CREDIT), USDG_OF_ONE, "old credit target paid once");
        assertEq(usdg.balanceOf(CREDIT2), USDG_OF_ONE, "new credit target paid");
    }

    // ---------------------------------------------------------------- minimum output

    /// The minimum goes to the curve, which prices the buy and reverts below it (the mock does, as Pons does).
    function test_minTokenOutIsEnforcedOnTheBuy() public {
        fundSplitter(1 ether);
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "slippage"));
        splitter.distribute(TOKENS_OF_ONE + 1, 0);
        distribute(TOKENS_OF_ONE, 0);
        assertEq(token.balanceOf(DEAD), TOKENS_OF_ONE, "burned at the exact minimum");
    }

    function test_zeroBurn_needsZeroTokenMinimum() public {
        setSplit(0, 2_500, 7_500);
        fundSplitter(1 ether);
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(MothTaxSplitter.InsufficientOutput.selector, address(token), 0, 1));
        splitter.distribute(1, 0);
        (, uint256 burned,,) = distribute();
        assertEq(burned, 0, "nothing burned");
        assertEq(curve.buyCalls(), 0, "no buy");
        assertEq(DEV.balance, 0.75 ether, "dev paid");
    }

    function test_zeroCredit_needsZeroUsdgMinimum() public {
        setSplit(833, 0, 9_167);
        fundSplitter(1 ether);
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(MothTaxSplitter.InsufficientOutput.selector, address(usdg), 0, 1));
        splitter.distribute(0, 1);
        (,, uint256 credited,) = distribute();
        assertEq(credited, 0, "nothing credited");
        assertEq(usdgBuyer.calls(), 0, "no swap");
        assertEq(DEV.balance, 0.9167 ether, "dev paid");
    }

    /// The splitter checks the USDG that reached the credit target itself; the mock route does not check at all.
    function test_usdgMinimum_enforced() public {
        fundSplitter(1 ether);
        vm.prank(KEEPER);
        vm.expectRevert(
            abi.encodeWithSelector(
                MothTaxSplitter.InsufficientOutput.selector, address(usdg), USDG_OF_ONE, USDG_OF_ONE + 1
            )
        );
        splitter.distribute(0, USDG_OF_ONE + 1);
        assertEq(address(splitter).balance, 1 ether, "nothing moved");

        // A route that pays short is caught the same way.
        usdgBuyer.setShortBy(1);
        vm.prank(KEEPER);
        vm.expectRevert(
            abi.encodeWithSelector(
                MothTaxSplitter.InsufficientOutput.selector, address(usdg), USDG_OF_ONE - 1, USDG_OF_ONE
            )
        );
        splitter.distribute(0, USDG_OF_ONE);

        usdgBuyer.setShortBy(0);
        (,, uint256 credited,) = distribute(0, USDG_OF_ONE);
        assertEq(credited, USDG_OF_ONE, "paid at the exact minimum");
    }

    function test_creditWithoutRoute_reverts() public {
        vm.prank(OWNER);
        splitter.setUsdgBuyer(address(0));
        creditEscrow(0.5 ether);
        fundSplitter(1 ether);
        vm.prank(KEEPER);
        vm.expectRevert(MothTaxSplitter.RouteNotSet.selector);
        splitter.distribute(0, 0);
        assertEq(address(splitter).balance, 1 ether, "splitter ETH unchanged");
        assertEq(escrow.balanceOf(address(splitter)), 0.5 ether, "escrow balance unchanged");
        assertEq(token.balanceOf(DEAD), 0, "nothing burned");
        assertEq(curve.buyCalls(), 0, "no buy kept");
        assertEq(DEV.balance, 0, "dev unpaid");
        assertEq(usdg.balanceOf(CREDIT), 0, "credit unpaid");

        // With no credit share the missing route does not matter.
        setSplit(833, 0, 9_167);
        (uint256 ethIn,,,) = distribute();
        assertEq(ethIn, 1.5 ether, "split without a route");
    }

    // ---------------------------------------------------------------- ETH that comes back

    /// The last curve buy spends only part of its input, and the USDG route may hand some ETH back. Both refunds stay
    /// in the splitter for the next distribute, never with the keeper, and never added to this call's dev share.
    function test_refundedEth_staysForNextSplit() public {
        curve.setFillBps(4_000); // the curve takes 40% of what it is offered
        usdgBuyer.setRefundBps(5_000); // the route hands half back
        fundSplitter(1 ether);
        uint256 keeperBefore = KEEPER.balance;
        (uint256 ethIn, uint256 burned, uint256 credited, uint256 toDev) = distribute();
        assertEq(ethIn, 1 ether, "eth in");
        assertEq(address(curve).balance, 0.03332 ether, "the curve took 40% of the 0.0833 ETH offered");
        assertEq(burned, 33_320e18, "tokens for the part that was spent");
        assertEq(credited, USDG_OF_ONE, "credit paid for the whole share");
        assertEq(toDev, DEV_OF_ONE, "dev share unchanged by the refunds");
        assertEq(DEV.balance, DEV_OF_ONE, "dev paid its share only");
        assertEq(KEEPER.balance, keeperBefore, "nothing leaked to the keeper");
        assertEq(address(splitter).balance, 0.04998 ether + 0.125 ether, "both refunds stay here");

        // The next distribute splits the leftover by the full split.
        curve.setFillBps(10_000);
        usdgBuyer.setRefundBps(0);
        (uint256 ethIn2,,,) = distribute();
        assertEq(ethIn2, 0.17498 ether, "the leftover is split again");
        assertEq(address(splitter).balance, 0, "emptied");
        assertEq(KEEPER.balance, keeperBefore, "still nothing with the keeper");
    }

    // ---------------------------------------------------------------- a wallet that refuses ETH

    function test_devWalletRejectingEth_revertsWhole() public {
        RejectingReceiver rejecting = new RejectingReceiver();
        vm.prank(OWNER);
        splitter.setDevWallet(address(rejecting));
        creditEscrow(0.5 ether);
        fundSplitter(1 ether);
        vm.prank(KEEPER);
        vm.expectRevert(PonsRoute.EthTransferFailed.selector);
        splitter.distribute(0, 0);
        assertEq(address(splitter).balance, 1 ether, "splitter ETH unchanged");
        assertEq(escrow.balanceOf(address(splitter)), 0.5 ether, "the claim was undone");
        assertEq(token.balanceOf(DEAD), 0, "no burn kept");
        assertEq(address(curve).balance, 0, "no buy kept");
        assertEq(usdg.balanceOf(CREDIT), 0, "no credit kept");
        assertEq(address(usdgBuyer).balance, 0, "no swap kept");

        // The owner points the dev share at a wallet that takes ETH, and the same balance splits.
        vm.prank(OWNER);
        splitter.setDevWallet(DEV2);
        (uint256 ethIn,,, uint256 toDev) = distribute();
        assertEq(ethIn, 1.5 ether, "claim plus balance");
        assertEq(DEV2.balance, toDev, "new dev wallet paid");
        assertEq(toDev, 1.5 ether - (1.5 ether * 833) / 10_000 - (1.5 ether * 2_500) / 10_000, "dev share");
    }

    // ---------------------------------------------------------------- the burn and strays

    function test_burnReachesTheDeadAddressWithAnyStrayTokens() public {
        token.mint(address(splitter), 5e18); // sent here by someone
        fundSplitter(1 ether);
        (, uint256 burned,,) = distribute();
        assertEq(burned, TOKENS_OF_ONE + 5e18, "stray tokens burned too");
        assertEq(token.balanceOf(DEAD), TOKENS_OF_ONE + 5e18, "at the dead address");
        assertEq(token.balanceOf(address(splitter)), 0, "none left");
    }

    function test_strayEthIsSplitLikeAnyOther() public {
        vm.deal(STRANGER, 0.3 ether);
        vm.prank(STRANGER);
        (bool ok,) = address(splitter).call{value: 0.3 ether}("");
        assertTrue(ok, "sent");
        fundSplitter(0.7 ether);
        (uint256 ethIn,,,) = distribute();
        assertEq(ethIn, 1 ether, "stray ETH joins the split");
    }

    function test_tokensThatReturnNothingStillMove() public {
        token.setReturnsNothing(true);
        fundSplitter(1 ether);
        distribute();
        assertEq(token.balanceOf(DEAD), TOKENS_OF_ONE, "burned");
    }

    // ---------------------------------------------------------------- Pons phases

    function test_aSweptLaunchHaltsTheBurnBuyAndMovesNothing() public {
        factory.setLaunch(address(token), address(curve), GraduationPhase.Swept, 3_000, 60);
        fundSplitter(1 ether);
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(PonsRoute.RouteUnavailable.selector, uint8(GraduationPhase.Swept)));
        splitter.distribute(0, 0);
        assertEq(address(splitter).balance, 1 ether, "nothing moved");
    }

    function test_aTokenPairedWithUsdgReverts() public {
        factory.setPairToken(address(usdg));
        fundSplitter(1 ether);
        vm.prank(KEEPER);
        vm.expectRevert(PonsRoute.WrongPair.selector);
        splitter.distribute(0, 0);
    }

    /// The factory answers an unknown token with an empty record, whose pair is zero like a native launch.
    function test_anUnknownTokenRevertsTheBurn() public {
        factory.clearLaunch();
        fundSplitter(1 ether);
        vm.prank(KEEPER);
        vm.expectRevert(PonsRoute.WrongPair.selector);
        splitter.distribute(0, 0);
    }

    // ---------------------------------------------------------------- the pool callback

    function test_onlyThePoolManagerCanCallUnlockCallback() public {
        vm.prank(STRANGER);
        vm.expectRevert(V4ExactIn.NotPoolManager.selector);
        splitter.unlockCallback("");
    }

    // ---------------------------------------------------------------- events

    /// The same topic is asserted in cortex/test/holder-credit.test.ts, so the API decodes this event.
    function test_theDistributedTopicMatchesTheApi() public pure {
        assertEq(
            MothTaxSplitter.Distributed.selector,
            0xf7576d8c2653e9d07af5ef229acf59b339e327d4e0eaddb4a96615534cf148f8,
            "Distributed(uint256,uint256,uint256,uint256)"
        );
    }

    function test_distributeEmitsOneDistributedEvent() public {
        fundSplitter(1 ether);
        vm.expectEmit(true, true, true, true, address(splitter));
        emit MothTaxSplitter.Distributed(1 ether, TOKENS_OF_ONE, USDG_OF_ONE, DEV_OF_ONE);
        distribute();
    }

    function test_everyChangeEmitsAnEvent() public {
        vm.startPrank(OWNER);
        vm.expectEmit(true, true, true, true, address(splitter));
        emit MothTaxSplitter.SplitChanged(10_000, 0, 0);
        splitter.setSplit(10_000, 0, 0);
        vm.expectEmit(true, true, true, true, address(splitter));
        emit MothTaxSplitter.DevWalletChanged(DEV2);
        splitter.setDevWallet(DEV2);
        vm.expectEmit(true, true, true, true, address(splitter));
        emit MothTaxSplitter.CreditTargetChanged(CREDIT2);
        splitter.setCreditTarget(CREDIT2);
        vm.expectEmit(true, true, true, true, address(splitter));
        emit MothTaxSplitter.KeeperChanged(STRANGER);
        splitter.setKeeper(STRANGER);
        vm.expectEmit(true, true, true, true, address(splitter));
        emit MothTaxSplitter.UsdgBuyerChanged(STRANGER);
        splitter.setUsdgBuyer(STRANGER);
        vm.stopPrank();
    }

    function test_constructorEmitsTheStartingState() public {
        vm.expectEmit(true, true, true, true);
        emit MothTaxSplitter.UsdgBuyerChanged(address(usdgBuyer));
        vm.expectEmit(true, true, true, true);
        emit MothTaxSplitter.SplitChanged(833, 2_500, 6_667);
        deploy(address(token), address(escrow));
    }

    // ---------------------------------------------------------------- ownership

    function test_ownershipMovesInTwoSteps() public {
        vm.prank(OWNER);
        vm.expectEmit(true, true, true, true, address(splitter));
        emit MothTaxSplitter.OwnershipTransferStarted(OWNER, NEW_OWNER);
        splitter.transferOwnership(NEW_OWNER);
        assertEq(splitter.owner(), OWNER, "still the owner until accepted");
        assertEq(splitter.pendingOwner(), NEW_OWNER, "pending");

        vm.prank(STRANGER);
        vm.expectRevert(MothTaxSplitter.Unauthorized.selector);
        splitter.acceptOwnership();

        vm.prank(NEW_OWNER);
        vm.expectEmit(true, true, true, true, address(splitter));
        emit MothTaxSplitter.OwnershipTransferred(OWNER, NEW_OWNER);
        splitter.acceptOwnership();
        assertEq(splitter.owner(), NEW_OWNER, "new owner");
        assertEq(splitter.pendingOwner(), address(0), "pending cleared");

        vm.prank(OWNER);
        vm.expectRevert(MothTaxSplitter.Unauthorized.selector);
        splitter.setSplit(10_000, 0, 0);
        vm.prank(NEW_OWNER);
        splitter.setSplit(10_000, 0, 0);
    }

    function test_aPendingTransferCanBeCancelled() public {
        vm.startPrank(OWNER);
        splitter.transferOwnership(NEW_OWNER);
        splitter.transferOwnership(address(0));
        vm.stopPrank();
        vm.prank(NEW_OWNER);
        vm.expectRevert(MothTaxSplitter.Unauthorized.selector);
        splitter.acceptOwnership();
        assertEq(splitter.owner(), OWNER, "unchanged");
    }

    // ---------------------------------------------------------------- reentrancy

    function test_theCurveCannotReenterDistribute() public {
        curve.setReenter(splitter);
        vm.prank(OWNER);
        splitter.setKeeper(address(curve));
        fundSplitter(1 ether);
        vm.prank(address(curve));
        vm.expectRevert(MothTaxSplitter.Reentrancy.selector);
        splitter.distribute(0, 0);
    }

    /// The escrow, the USDG route and the dev wallet each get control during a distribute (the escrow pays with a
    /// plain call, the route is called with ETH, the dev wallet is paid with a plain call). Each is made the keeper
    /// here, so only the lock can stop its distribute and sweep, and each attempt is refused.
    function test_reentryThroughReceive_refused() public {
        MockERC20 other = new MockERC20(18);
        bytes32 guard = keccak256(abi.encodeWithSelector(MothTaxSplitter.Reentrancy.selector));

        // The escrow.
        ReentrantEscrow badEscrow = new ReentrantEscrow();
        splitter = deploy(address(token), address(badEscrow));
        other.mint(address(splitter), 1e18);
        badEscrow.setTargets(splitter, address(other));
        vm.deal(address(badEscrow), 1 ether);
        vm.prank(OWNER);
        splitter.setKeeper(address(badEscrow));
        vm.expectEmit(true, true, true, true, address(splitter));
        emit MothTaxSplitter.EscrowClaimed(1 ether);
        vm.prank(address(badEscrow));
        splitter.distribute(0, 0);
        assertEq(badEscrow.attempts(), 1, "escrow called back once");
        assertEq(keccak256(badEscrow.distributeError()), guard, "escrow: distribute blocked");
        assertEq(keccak256(badEscrow.sweepError()), guard, "escrow: sweep blocked");
        assertEq(DEV.balance, DEV_OF_ONE, "split once");

        // The USDG route.
        ReentrantSwapper badRoute = new ReentrantSwapper(usdg, USDG_PER_ETH);
        badRoute.setTargets(splitter, address(other));
        vm.startPrank(OWNER);
        splitter.setUsdgBuyer(address(badRoute));
        splitter.setKeeper(address(badRoute));
        vm.stopPrank();
        vm.deal(address(badEscrow), 1 ether);
        vm.prank(address(badRoute));
        splitter.distribute(0, 0);
        assertEq(badRoute.attempts(), 1, "route called back once");
        assertEq(keccak256(badRoute.distributeError()), guard, "route: distribute blocked");
        assertEq(keccak256(badRoute.sweepError()), guard, "route: sweep blocked");
        assertEq(DEV.balance, 2 * DEV_OF_ONE, "split once more");

        // The dev wallet.
        ReentrantReceiver badDev = new ReentrantReceiver();
        badDev.setTargets(splitter, address(other));
        vm.startPrank(OWNER);
        splitter.setDevWallet(address(badDev));
        splitter.setKeeper(address(badDev));
        vm.stopPrank();
        vm.deal(address(badEscrow), 1 ether);
        vm.prank(address(badDev));
        splitter.distribute(0, 0);
        assertEq(badDev.attempts(), 1, "dev wallet called back once");
        assertEq(badDev.received(), DEV_OF_ONE, "paid once");
        assertEq(keccak256(badDev.distributeError()), guard, "dev: distribute blocked");
        assertEq(keccak256(badDev.sweepError()), guard, "dev: sweep blocked");

        assertEq(other.balanceOf(address(splitter)), 1e18, "nothing swept by any of them");
    }

    // ---------------------------------------------------------------- escrow claim

    function test_distributeClaimsEthFromTheEscrowFirst() public {
        creditEscrow(2 ether);
        fundSplitter(1 ether);
        vm.expectEmit(true, true, true, true, address(splitter));
        emit MothTaxSplitter.EscrowClaimed(2 ether);
        (uint256 ethIn,,,) = distribute();
        assertEq(ethIn, 3 ether, "claim plus the balance already here");
        assertEq(escrow.balanceOf(address(splitter)), 0, "escrow emptied");
        assertEq(escrow.calls(), 1, "one claim");
    }

    function test_aZeroEscrowSkipsTheClaimAndTheSweep() public {
        splitter = deploy(address(token), address(0));
        fundSplitter(1 ether);
        vm.recordLogs();
        distribute();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(splitter)) continue;
            assertTrue(logs[i].topics[0] != MothTaxSplitter.EscrowClaimed.selector, "no claim");
            assertTrue(logs[i].topics[0] != MothTaxSplitter.EscrowClaimFailed.selector, "no claim attempt");
            assertTrue(logs[i].topics[0] != MothTaxSplitter.SweepFailed.selector, "no sweep attempt");
        }
        assertEq(curve.sweepCalls(), 0, "no sweep");
        assertEq(escrow.calls(), 0, "no claim");
        assertEq(DEV.balance, DEV_OF_ONE, "still distributed");
    }

    function test_aFailedClaimIsReportedAndDoesNotBlockTheSplit() public {
        escrow.setReverts(true);
        fundSplitter(1 ether);
        vm.expectEmit(true, true, true, true, address(splitter));
        emit MothTaxSplitter.EscrowClaimFailed(abi.encodeWithSignature("Error(string)", "claim reverts"));
        distribute();
        assertEq(DEV.balance, DEV_OF_ONE, "distributed");
    }

    function test_nothingToClaimIsReportedLikeAnyFailedClaim() public {
        fundSplitter(1 ether);
        vm.expectEmit(true, true, true, true, address(splitter));
        emit MothTaxSplitter.EscrowClaimFailed(abi.encodeWithSignature("Error(string)", "nothing to claim"));
        distribute();
    }

    function test_nothingToDistributeReverts() public {
        vm.prank(KEEPER);
        vm.expectRevert(MothTaxSplitter.NothingToDistribute.selector);
        splitter.distribute(0, 0);
    }

    function test_distributeNeedsTheTokenSet() public {
        splitter = deploy(address(0), address(escrow));
        fundSplitter(1 ether);
        vm.prank(KEEPER);
        vm.expectRevert(MothTaxSplitter.TokenNotSet.selector);
        splitter.distribute(0, 0);
    }

    // ---------------------------------------------------------------- the fee sweep before the claim

    function test_onTheCurveDistributeSweepsFeesIntoTheEscrowThenClaimsThem() public {
        vm.deal(address(curve), 0.4 ether);
        curve.setSweepCredit(escrow, address(splitter), 0.4 ether);
        (uint256 ethIn,,,) = distribute();
        assertEq(curve.sweepCalls(), 1, "curve swept");
        assertEq(curve.lastSweepMin(), 0, "no buyback minimum");
        assertEq(hook.sweepCalls(), 0, "not the pool");
        assertEq(ethIn, 0.4 ether, "the swept fees were claimed and split");
    }

    function test_afterGraduationDistributeSweepsThePoolWithItsId() public {
        factory.setLaunch(address(token), address(curve), GraduationPhase.PoolCreated, 3_000, 60);
        vm.deal(address(hook), 0.4 ether);
        hook.setSweepCredit(escrow, address(splitter), 0.4 ether);
        setSplit(0, 2_500, 7_500); // no burn, so the test needs no pool
        (uint256 ethIn,,,) = distribute();
        assertEq(hook.sweepCalls(), 1, "hook swept");
        assertEq(curve.sweepCalls(), 0, "not the curve");
        assertEq(hook.lastMinConversion(), 0, "no conversion minimum");
        assertEq(hook.lastMinBuyback(), 0, "no buyback minimum");
        // ETH, the zero address, is always currency0.
        bytes32 id = keccak256(abi.encode(address(0), address(token), uint24(3_000), int24(60), address(hook)));
        assertEq(hook.lastPoolId(), id, "pool id from ETH, the token, fee, spacing and hook");
        assertEq(ethIn, 0.4 ether, "the swept fees were claimed and split");
    }

    function test_noSweepInTheWindowBetweenSweptAndPoolCreated() public {
        factory.setLaunch(address(token), address(curve), GraduationPhase.Swept, 3_000, 60);
        setSplit(0, 2_500, 7_500);
        creditEscrow(1 ether);
        distribute();
        assertEq(curve.sweepCalls(), 0, "curve not swept");
        assertEq(hook.sweepCalls(), 0, "hook not swept");
        assertEq(DEV.balance, 0.75 ether, "the escrow balance is still claimed and split");
    }

    function test_aFailedCurveSweepIsReportedAndTheRestStillRuns() public {
        curve.setSweepReverts(true);
        creditEscrow(1 ether);
        vm.expectEmit(true, true, true, true, address(splitter));
        emit MothTaxSplitter.SweepFailed(abi.encodeWithSignature("Error(string)", "sweep reverts"));
        (uint256 ethIn,,,) = distribute();
        assertEq(ethIn, 1 ether, "claimed and split anyway");
        assertEq(DEV.balance, DEV_OF_ONE, "dev paid");
    }

    function test_aFailedPoolSweepIsReportedAndTheRestStillRuns() public {
        factory.setLaunch(address(token), address(curve), GraduationPhase.PoolCreated, 3_000, 60);
        hook.setSweepReverts(true);
        setSplit(0, 2_500, 7_500);
        creditEscrow(1 ether);
        vm.expectEmit(true, true, true, true, address(splitter));
        emit MothTaxSplitter.SweepFailed(abi.encodeWithSignature("Error(string)", "pool sweep reverts"));
        (uint256 ethIn,,,) = distribute();
        assertEq(ethIn, 1 ether, "claimed and split anyway");
        assertEq(usdg.balanceOf(CREDIT), USDG_OF_ONE, "credit paid");
    }

    function test_aFactoryThatRevertsIsReportedAndTheRestStillRuns() public {
        vm.etch(address(factory), hex"fe"); // every call to it fails
        setSplit(0, 2_500, 7_500);
        creditEscrow(1 ether);
        vm.recordLogs();
        distribute();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 failures;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(splitter) && logs[i].topics[0] == MothTaxSplitter.SweepFailed.selector) {
                failures++;
            }
        }
        assertEq(failures, 1, "one SweepFailed");
        assertEq(DEV.balance, 0.75 ether, "still split");
    }

    // ---------------------------------------------------------------- an unknown launch or a dead factory

    /// The real factory answers an unknown token with an empty record, not a revert. Its pair is the zero address,
    /// like a native launch, so `exists` is what keeps the sweep away from it.
    function test_anEmptyLaunchRecordSkipsTheSweepAndTheSplitStillPays() public {
        factory.clearLaunch();
        setSplit(0, 2_500, 7_500);
        creditEscrow(1 ether);
        vm.recordLogs();
        distribute();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(splitter)) {
                assertTrue(logs[i].topics[0] != MothTaxSplitter.SweepFailed.selector, "skipped, not failed");
            }
        }
        assertEq(curve.sweepCalls(), 0, "no sweep");
        assertEq(hook.sweepCalls(), 0, "no pool sweep");
        assertEq(usdg.balanceOf(CREDIT), USDG_OF_ONE, "credit paid");
        assertEq(DEV.balance, 0.75 ether, "dev paid");
    }

    function test_aLaunchPairedWithAnotherAssetSkipsTheSweep() public {
        factory.setPairToken(address(usdg));
        setSplit(0, 2_500, 7_500);
        creditEscrow(1 ether);
        distribute();
        assertEq(curve.sweepCalls(), 0, "no sweep");
        assertEq(DEV.balance, 0.75 ether, "dev paid");
    }

    function test_aCurveWithNoCodeCannotRevertDistribute() public {
        factory.setLaunch(address(token), address(0xC0DE), GraduationPhase.NotGraduated, 3_000, 60);
        setSplit(0, 2_500, 7_500);
        creditEscrow(1 ether);
        distribute();
        assertEq(DEV.balance, 0.75 ether, "dev paid");
    }

    function test_aHookWithNoCodeCannotRevertDistribute() public {
        factory.setLaunch(address(token), address(curve), GraduationPhase.PoolCreated, 3_000, 60);
        factory.setHook(address(0xC0DE));
        setSplit(0, 2_500, 7_500);
        creditEscrow(1 ether);
        distribute();
        assertEq(DEV.balance, 0.75 ether, "dev paid");
    }

    function test_aFactoryWithNoCodeCannotRevertDistribute() public {
        vm.etch(address(factory), "");
        setSplit(0, 2_500, 7_500);
        creditEscrow(1 ether);
        vm.expectEmit(true, true, true, true, address(splitter));
        emit MothTaxSplitter.SweepFailed("");
        distribute();
        assertEq(usdg.balanceOf(CREDIT), USDG_OF_ONE, "credit paid");
        assertEq(DEV.balance, 0.75 ether, "dev paid");
    }

    function test_aFactoryAnswerOfTheWrongShapeCannotRevertDistribute() public {
        vm.etch(address(factory), hex"600160005260206000f3"); // returns one word for every call
        setSplit(0, 2_500, 7_500);
        creditEscrow(1 ether);
        distribute();
        assertEq(DEV.balance, 0.75 ether, "dev paid");
    }

    // ---------------------------------------------------------------- handing the fee stream over

    function test_theOwnerCanHandTheCreatorFeesOver() public {
        vm.prank(OWNER);
        vm.expectEmit(true, true, true, true, address(splitter));
        emit MothTaxSplitter.CreatorFeesHandedOver(STRANGER);
        splitter.handOverCreatorFees(STRANGER);
        assertEq(factory.handOverCalls(), 1, "one call");
        assertEq(factory.lastHandOverToken(), address(token), "for $MOTH");
        assertEq(factory.lastHandOverRecipient(), STRANGER, "to the new recipient");
        assertEq(factory.lastHandOverCaller(), address(splitter), "from the splitter");
    }

    function test_handOverIsOwnerOnlyAndNeedsARecipientAndAToken() public {
        vm.prank(KEEPER);
        vm.expectRevert(MothTaxSplitter.Unauthorized.selector);
        splitter.handOverCreatorFees(STRANGER);
        vm.prank(STRANGER);
        vm.expectRevert(MothTaxSplitter.Unauthorized.selector);
        splitter.handOverCreatorFees(STRANGER);
        vm.prank(OWNER);
        vm.expectRevert(MothTaxSplitter.ZeroAddress.selector);
        splitter.handOverCreatorFees(address(0));
        splitter = deploy(address(0), address(escrow));
        vm.prank(OWNER);
        vm.expectRevert(MothTaxSplitter.TokenNotSet.selector);
        splitter.handOverCreatorFees(STRANGER);
        assertEq(factory.handOverCalls(), 0, "no call made");
    }

    function test_creditedFeesCanStillBeClaimedAfterAHandOver() public {
        creditEscrow(1 ether);
        vm.prank(OWNER);
        splitter.handOverCreatorFees(STRANGER);
        (uint256 ethIn,,,) = distribute();
        assertEq(ethIn, 1 ether, "fees already in the escrow are still claimed");
    }

    // ---------------------------------------------------------------- sweeps

    function test_sweepSendsUnrelatedTokensToTheDevWallet() public {
        MockERC20 other = new MockERC20(18);
        other.mint(address(splitter), 7e18);
        vm.prank(OWNER);
        vm.expectEmit(true, true, true, true, address(splitter));
        emit MothTaxSplitter.Swept(address(other), 7e18);
        assertEq(splitter.sweep(address(other)), 7e18, "swept");
        assertEq(other.balanceOf(DEV), 7e18, "to the dev wallet");

        other.setReturnsNothing(true);
        other.mint(address(splitter), 1e18);
        vm.prank(KEEPER);
        splitter.sweep(address(other));
        assertEq(other.balanceOf(DEV), 8e18, "the keeper can sweep too");

        vm.prank(KEEPER);
        assertEq(splitter.sweep(address(other)), 0, "nothing left");
    }

    /// USDG is not part of the ETH flow (it goes straight from the route to the credit target), so any that lands
    /// here can be swept like an unrelated token. $MOTH and the zero address never can.
    function test_usdgIsSweepable_mothIsNot() public {
        token.mint(address(splitter), 1e18);
        usdg.mint(address(splitter), 5e6);
        vm.startPrank(OWNER);
        vm.expectEmit(true, true, true, true, address(splitter));
        emit MothTaxSplitter.Swept(address(usdg), 5e6);
        assertEq(splitter.sweep(address(usdg)), 5e6, "usdg swept");
        vm.expectRevert(abi.encodeWithSelector(MothTaxSplitter.NotSweepable.selector, address(token)));
        splitter.sweep(address(token));
        vm.expectRevert(abi.encodeWithSelector(MothTaxSplitter.NotSweepable.selector, address(0)));
        splitter.sweep(address(0));
        vm.stopPrank();
        assertEq(usdg.balanceOf(DEV), 5e6, "usdg to the dev wallet");
        assertEq(token.balanceOf(address(splitter)), 1e18, "token stays");
    }

    function test_onlyTheOwnerOrKeeperSweeps() public {
        MockERC20 other = new MockERC20(18);
        other.mint(address(splitter), 1e18);
        vm.prank(STRANGER);
        vm.expectRevert(MothTaxSplitter.Unauthorized.selector);
        splitter.sweep(address(other));
        assertEq(other.balanceOf(address(splitter)), 1e18, "unchanged");
    }

    function test_nothingCanBeSweptBeforeTheTokenIsSet() public {
        splitter = deploy(address(0), address(escrow));
        MockERC20 other = new MockERC20(18);
        other.mint(address(splitter), 1e18);
        vm.prank(OWNER);
        vm.expectRevert(MothTaxSplitter.TokenNotSet.selector);
        splitter.sweep(address(other));
    }

    // ---------------------------------------------------------------- token, constructor checks

    /// The token can be set, changed or unset at any time, for a relaunch or anything else (founder, 2026-10-26).
    function test_theTokenCanBeSetChangedOrUnsetAnyTime() public {
        splitter = deploy(address(0), address(escrow));
        fundSplitter(1 ether);
        vm.prank(KEEPER);
        vm.expectRevert(MothTaxSplitter.TokenNotSet.selector);
        splitter.distribute(0, 0);

        vm.startPrank(OWNER);
        vm.expectRevert(MothTaxSplitter.InvalidToken.selector);
        splitter.setToken(address(usdg));
        vm.expectEmit(true, true, true, true, address(splitter));
        emit MothTaxSplitter.TokenSet(address(token));
        splitter.setToken(address(token));
        vm.stopPrank();

        distribute();
        assertEq(token.balanceOf(DEAD), TOKENS_OF_ONE, "burned once the token is set");

        MockERC20 relaunched = new MockERC20(18);
        vm.startPrank(OWNER);
        vm.expectEmit(true, true, true, true, address(splitter));
        emit MothTaxSplitter.TokenSet(address(relaunched));
        splitter.setToken(address(relaunched));
        assertEq(address(splitter.token()), address(relaunched), "changed after it was set");
        vm.expectEmit(true, true, true, true, address(splitter));
        emit MothTaxSplitter.TokenSet(address(0));
        splitter.setToken(address(0));
        assertEq(address(splitter.token()), address(0), "unset");
        vm.stopPrank();

        fundSplitter(1 ether);
        vm.prank(KEEPER);
        vm.expectRevert(MothTaxSplitter.TokenNotSet.selector);
        splitter.distribute(0, 0);
    }

    /// After a relaunch the old token can leave the only way an unrelated token can, swept to the dev wallet; the
    /// new one still never can.
    function test_aRelaunchLetsTheOldTokenBeSwept() public {
        token.mint(address(splitter), 5e18);
        MockERC20 relaunched = new MockERC20(18);
        vm.prank(OWNER);
        splitter.setToken(address(relaunched));
        relaunched.mint(address(splitter), 1e18);

        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(MothTaxSplitter.NotSweepable.selector, address(relaunched)));
        splitter.sweep(address(relaunched));
        vm.prank(KEEPER);
        assertEq(splitter.sweep(address(token)), 5e18, "the old token is swept");
        assertEq(token.balanceOf(DEV), 5e18, "to the dev wallet");
        assertEq(relaunched.balanceOf(address(splitter)), 1e18, "the new token stays");
    }

    function test_constructorRejectsMissingAddresses() public {
        address f = address(factory);
        address u = address(usdg);
        address t = address(token);
        address b = address(usdgBuyer);
        vm.expectRevert(MothTaxSplitter.ZeroAddress.selector);
        new MothTaxSplitter(t, address(0), POOL_MANAGER, f, address(0), KEEPER, DEV, CREDIT, b);
        vm.expectRevert(MothTaxSplitter.ZeroAddress.selector);
        new MothTaxSplitter(t, u, address(0), f, address(0), KEEPER, DEV, CREDIT, b);
        vm.expectRevert(MothTaxSplitter.ZeroAddress.selector);
        new MothTaxSplitter(t, u, POOL_MANAGER, address(0), address(0), KEEPER, DEV, CREDIT, b);
        vm.expectRevert(MothTaxSplitter.ZeroAddress.selector);
        new MothTaxSplitter(t, u, POOL_MANAGER, f, address(0), KEEPER, address(0), CREDIT, b);
        vm.expectRevert(MothTaxSplitter.ZeroAddress.selector);
        new MothTaxSplitter(t, u, POOL_MANAGER, f, address(0), KEEPER, DEV, address(0), b);
        vm.expectRevert(MothTaxSplitter.InvalidToken.selector);
        new MothTaxSplitter(u, u, POOL_MANAGER, f, address(0), KEEPER, DEV, CREDIT, b);
        // A zero USDG route is allowed: it can be set later with setUsdgBuyer.
        MothTaxSplitter s = new MothTaxSplitter(t, u, POOL_MANAGER, f, address(0), KEEPER, DEV, CREDIT, address(0));
        assertEq(address(s.usdgBuyer()), address(0), "no route yet");
    }

    function test_constructorRequiresCodeAtTheEscrowFactoryAndPoolManager() public {
        address nowhere = address(0xDEAD0);
        address f = address(factory);
        address u = address(usdg);
        address t = address(token);
        address b = address(usdgBuyer);
        vm.expectRevert(abi.encodeWithSelector(MothTaxSplitter.NotAContract.selector, nowhere));
        new MothTaxSplitter(t, u, POOL_MANAGER, f, nowhere, KEEPER, DEV, CREDIT, b);
        vm.expectRevert(abi.encodeWithSelector(MothTaxSplitter.NotAContract.selector, nowhere));
        new MothTaxSplitter(t, u, POOL_MANAGER, nowhere, address(escrow), KEEPER, DEV, CREDIT, b);
        vm.expectRevert(abi.encodeWithSelector(MothTaxSplitter.NotAContract.selector, nowhere));
        new MothTaxSplitter(t, u, nowhere, f, address(escrow), KEEPER, DEV, CREDIT, b);
        // A zero escrow is still allowed: the sweep and claim are skipped.
        new MothTaxSplitter(t, u, POOL_MANAGER, f, address(0), KEEPER, DEV, CREDIT, b);
    }

    // ---------------------------------------------------------------- an escrow that answers wrongly

    function runWithBadEscrow(bytes memory code) internal {
        address bad = address(0xE5C0);
        vm.etch(bad, code);
        splitter = deploy(address(token), bad);
        setSplit(0, 2_500, 7_500);
        fundSplitter(1 ether);
        vm.recordLogs();
        distribute();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 failures;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(splitter) && logs[i].topics[0] == MothTaxSplitter.EscrowClaimFailed.selector)
            {
                failures++;
            }
        }
        assertEq(failures, 1, "EscrowClaimFailed emitted once");
        assertEq(usdg.balanceOf(CREDIT), USDG_OF_ONE, "credit paid");
        assertEq(DEV.balance, 0.75 ether, "dev paid");
    }

    function test_anEscrowThatReturnsNothingCannotBrickDistribute() public {
        runWithBadEscrow(hex"00");
    }

    function test_anEscrowThatRevertsCannotBrickDistribute() public {
        runWithBadEscrow(hex"60006000fd");
    }

    function test_anEscrowThatReturnsAShortAnswerCannotBrickDistribute() public {
        runWithBadEscrow(hex"601f6000f3");
    }

    function test_receiveTakesA2300GasTransfer() public {
        (bool ok,) = address(splitter).call{value: 1 ether, gas: 2_300}(""); // what transfer() forwards
        assertTrue(ok, "accepted");
        assertEq(address(splitter).balance, 1 ether, "received");
    }
}
