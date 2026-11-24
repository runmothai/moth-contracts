// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {RobinhoodFork, IERC20Like, IPonsFactory, IPonsCurve} from "./RobinhoodFork.sol";
import {MothTaxSplitter} from "../../src/MothTaxSplitter.sol";
import {PonsRoute} from "../../src/swappers/PonsRoute.sol";
import {UsdgSwapper} from "../../src/swappers/UsdgSwapper.sol";
import {Vm} from "../utils/Test.sol";

interface IERC20Transfer {
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IFeeEscrow {
    function balanceOf(address recipient) external view returns (uint256);
}

/// Sells a native launch token on whichever venue it is on, to put token-denominated fees into the graduated pool.
contract PoolTrader is PonsRoute {
    constructor(address poolManager_, address ponsFactory_) PonsRoute(poolManager_, ponsFactory_) {}

    function sell(address token, uint256 tokenIn, address recipient) external returns (uint256) {
        return _ponsSell(token, tokenIn, 0, recipient, msg.sender);
    }

    receive() external payable {}
}

/// Fork tests of the tax splitter against the real Pons V2 factory, curve, hook and fee escrow, and the real ETH /
/// USDG pool. The test launch is paired with native ETH and names the splitter as its creator fee recipient, so
/// Pons pays its fees to the splitter's escrow balance in ETH; the splitter sweeps them into the escrow itself,
/// claims them and splits them. The credit share is swapped to USDG for the vault's address, through a fresh
/// `UsdgSwapper` built like the deployed one, or through the deployed one itself.
contract SplitterForkTest is RobinhoodFork {
    address internal constant KEEPER = address(0x4EE9);
    address internal constant DEV = address(0xDE5);
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    /// The USDG route deployed for the vault, which the splitter will be given on launch day.
    address internal constant DEPLOYED_USDG_SWAPPER = 0x095f4E391912153B73FeF7956F0eAb353b0612C8;

    MothTaxSplitter internal splitter;
    UsdgSwapper internal usdgSwapper;

    function setUp() public override {
        super.setUp();
        if (!forked) return;
        usdgSwapper = new UsdgSwapper(USDG, POOL_MANAGER, ethUsdgPool());
        // The token is unknown until the launch names the splitter as fee recipient, so it is set afterwards.
        splitter = new MothTaxSplitter(
            address(0), USDG, POOL_MANAGER, PONS_FACTORY, PONS_FEE_ESCROW, KEEPER, DEV, MOTH_VAULT, address(usdgSwapper)
        );
    }

    function creatorFeeRecipient() internal view override returns (address) {
        return address(splitter);
    }

    function bal(address token, address who) internal view returns (uint256) {
        return IERC20Like(token).balanceOf(who);
    }

    function owed() internal view returns (uint256) {
        return IFeeEscrow(PONS_FEE_ESCROW).balanceOf(address(splitter));
    }

    function launchForSplitter() internal returns (address token, address curve) {
        (token, curve) = launchTestToken();
        splitter.setToken(token);
    }

    /// A buy on the curve past the snipe window, so the 3% creator tax accrues as a pending fee. The size is a
    /// twentieth of a graduating buy, read from the chain, so the launch stays on the curve.
    function tradeOnCurve(address token, address curve) internal {
        vm.warp(block.timestamp + SNIPE_WINDOW);
        uint256 amount = graduationBuyEth(token) / 20;
        vm.deal(buyer, amount);
        vm.prank(buyer);
        IPonsCurve(curve).buy{value: amount}(amount, 0, buyer);
    }

    function countSweepFailed(Vm.Log[] memory logs) internal view returns (uint256 n) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(splitter) && logs[i].topics[0] == MothTaxSplitter.SweepFailed.selector) n++;
        }
    }

    struct Before {
        uint256 dead;
        uint256 vaultUsdg;
        uint256 devEth;
        uint256 keeperEth;
        uint256 managerEth;
    }

    struct Result {
        uint256 ethIn;
        uint256 burned;
        uint256 toCredit;
        uint256 toDev;
        uint256 sweepFailures;
    }

    function snapshot(address token) internal view returns (Before memory b) {
        b = Before({
            dead: bal(token, DEAD),
            vaultUsdg: bal(USDG, MOTH_VAULT),
            devEth: DEV.balance,
            keeperEth: KEEPER.balance,
            managerEth: POOL_MANAGER.balance
        });
    }

    function distribute(uint256 minTokenOut, uint256 minUsdgOut) internal returns (Result memory r) {
        vm.recordLogs();
        vm.prank(KEEPER);
        (r.ethIn, r.burned, r.toCredit, r.toDev) = splitter.distribute(minTokenOut, minUsdgOut);
        r.sweepFailures = countSweepFailed(vm.getRecordedLogs());
    }

    /// What every full split must show: $MOTH at the dead address, USDG at the vault's address and ETH at the dev
    /// wallet, each matching what distribute reported, the dev share exact to the wei at the default split, and
    /// nothing left behind in the splitter, the route or with the keeper.
    function assertSplit(address token, Before memory b, Result memory r) internal view {
        uint256 burnEth = (r.ethIn * 833) / 10_000;
        uint256 creditEth = (r.ethIn * 2_500) / 10_000;
        assertTrue(r.ethIn > 0, "fees were claimed");
        assertTrue(r.burned > 0, "tokens bought and burned");
        assertEq(bal(token, DEAD) - b.dead, r.burned, "the dead address gains $MOTH");
        assertTrue(r.toCredit > 0, "the credit share bought USDG");
        assertEq(bal(USDG, MOTH_VAULT) - b.vaultUsdg, r.toCredit, "the vault address gains the reported USDG");
        assertEq(r.toDev, r.ethIn - burnEth - creditEth, "dev share");
        assertEq(DEV.balance - b.devEth, r.toDev, "the dev wallet gains its share in ETH");
        assertEq(address(splitter).balance, 0, "no ETH left: the burn and credit shares were spent in full");
        assertEq(bal(token, address(splitter)), 0, "no $MOTH left");
        assertEq(bal(USDG, address(splitter)), 0, "no USDG left");
        assertEq(KEEPER.balance, b.keeperEth, "nothing with the keeper");
        address route = address(splitter.usdgBuyer());
        assertEq(route.balance, 0, "route holds no ETH");
        assertEq(bal(USDG, route), 0, "route holds no USDG");
    }

    function test_distribute_onTheCurve_burnsCreditsAndPays() public {
        if (!forked) return;
        (address token, address curve) = launchForSplitter();
        tradeOnCurve(token, curve);
        assertEq(address(splitter).balance, 0, "nothing held before the sweep");
        assertEq(owed(), 0, "nothing swept yet");

        Before memory b = snapshot(token);
        Result memory r = distribute(1, 1);

        assertEq(r.sweepFailures, 0, "the curve sweep worked");
        assertEq(owed(), 0, "the splitter swept its fees into the escrow and claimed them all");
        assertSplit(token, b, r);
        // On the curve only the credit swap touches the pool manager, so its ETH gain is exactly the credit share.
        assertEq(POOL_MANAGER.balance - b.managerEth, (r.ethIn * 2_500) / 10_000, "the credit share went to the pool");
    }

    function test_distribute_withTheDeployedUsdgRoute() public {
        if (!forked) return;
        assertTrue(DEPLOYED_USDG_SWAPPER.code.length > 0, "deployed route exists");
        splitter.setUsdgBuyer(DEPLOYED_USDG_SWAPPER);
        (address token, address curve) = launchForSplitter();
        tradeOnCurve(token, curve);

        Before memory b = snapshot(token);
        Result memory r = distribute(1, 1);

        assertEq(r.sweepFailures, 0, "the curve sweep worked");
        assertSplit(token, b, r);
        assertEq(POOL_MANAGER.balance - b.managerEth, (r.ethIn * 2_500) / 10_000, "the credit share went to the pool");
    }

    function test_distribute_afterGraduation_claimsTheGraduationFeesAndBuysOnThePool() public {
        if (!forked) return;
        (address token,) = launchForSplitter();
        buyToGraduation(token); // the graduation sweeps the curve's fees into the escrow
        createPool(token);
        assertTrue(owed() > 0, "graduation credited the escrow in ETH");

        Before memory b = snapshot(token);
        Result memory r = distribute(1, 1);

        assertEq(r.sweepFailures, 0, "no token-denominated fees were pending, so the pool sweep worked");
        assertSplit(token, b, r);
    }

    /// A sale into the graduated pool leaves fees in the launch token. Converting them is an internal swap only
    /// Pons's operator may run, so the creator's sweep can revert; the splitter must report it and still claim and
    /// split what the escrow holds.
    function test_distribute_afterGraduation_withTokenFeesPending_neverStopsTheSplit() public {
        if (!forked) return;
        (address token,) = launchForSplitter();
        buyToGraduation(token);
        createPool(token);

        PoolTrader trader = new PoolTrader(POOL_MANAGER, PONS_FACTORY);
        uint256 tokens = bal(token, buyer) / 2;
        vm.prank(buyer);
        IERC20Transfer(token).transfer(address(trader), tokens);
        trader.sell(token, tokens, buyer);

        Before memory b = snapshot(token);
        // Whether the sweep reverted or not is Pons's call; either way the rest ran, which is asserted below.
        Result memory r = distribute(1, 1);
        assertSplit(token, b, r);
    }

    /// Between the curve selling out and the pool being created neither venue trades. A burn share above zero
    /// waits; with the burn share at zero the credit and dev shares still pay.
    function test_sweptPhase_distributeWaits() public {
        if (!forked) return;
        (address token,) = launchForSplitter();
        buyToGraduation(token);
        assertEq(uint256(IPonsFactory(PONS_FACTORY).getLaunchedToken(token).phase), 1, "Swept");
        uint256 owedBefore = owed();
        assertTrue(owedBefore > 0, "graduation credited the escrow");

        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(PonsRoute.RouteUnavailable.selector, uint8(1)));
        splitter.distribute(0, 0);
        assertEq(owed(), owedBefore, "nothing claimed");

        splitter.setSplit(0, 2_500, 7_500);
        Before memory b = snapshot(token);
        Result memory r = distribute(0, 1);
        assertEq(r.ethIn, owedBefore, "the escrow balance was claimed");
        assertEq(r.burned, 0, "nothing burned");
        assertEq(bal(token, DEAD), b.dead, "the dead address unchanged");
        assertTrue(r.toCredit > 0, "credit paid");
        assertEq(bal(USDG, MOTH_VAULT) - b.vaultUsdg, r.toCredit, "the vault address gains USDG");
        assertEq(r.toDev, r.ethIn - (r.ethIn * 2_500) / 10_000, "dev share");
        assertEq(DEV.balance - b.devEth, r.toDev, "dev paid in ETH");
        assertEq(address(splitter).balance, 0, "no ETH left");
    }

    /// The last curve buy is partial. When the splitter's own burn buy completes the curve, the curve refunds the
    /// unspent ETH to the splitter, where it stays for the next split. The burn share is twice what the curve still
    /// lacks, read from the chain.
    function test_partialBuyOnTheRealCurveLeavesTheRestInTheSplitter() public {
        if (!forked) return;
        (address token,) = launchForSplitter();
        vm.warp(block.timestamp + SNIPE_WINDOW);
        uint256 burnShare = graduationBuyEth(token);
        splitter.setSplit(1_000, 0, 9_000);
        vm.deal(address(splitter), burnShare * 10);
        uint256 keeperBefore = KEEPER.balance;
        uint256 devBefore = DEV.balance;

        Result memory r = distribute(1, 0);

        assertEq(r.ethIn, burnShare * 10, "eth in");
        assertTrue(r.burned > 0, "bought what the curve could sell");
        assertEq(
            uint256(IPonsFactory(PONS_FACTORY).getLaunchedToken(token).phase), 1, "the splitter's buy graduated it"
        );
        assertEq(r.toDev, r.ethIn - burnShare, "dev share");
        assertEq(DEV.balance - devBefore, r.toDev, "dev paid its share only");
        assertEq(KEEPER.balance, keeperBefore, "nothing leaked to the keeper");
        uint256 kept = address(splitter).balance;
        assertTrue(kept > 0, "the unspent burn share stays in the splitter");
        assertTrue(kept < burnShare, "part of the burn share was spent");
    }

    /// The launch names the splitter as fee recipient; the owner moves the stream to a fresh address.
    function test_handOverCreatorFees_movesTheStreamOnTheRealFactory() public {
        if (!forked) return;
        (address token, address curve) = launchForSplitter();
        assertEq(IPonsFactory(PONS_FACTORY).getLaunchedToken(token).creatorFeeRecipient, address(splitter), "before");
        tradeOnCurve(token, curve);

        address next = address(0xBEEF);
        splitter.handOverCreatorFees(next);
        assertEq(IPonsFactory(PONS_FACTORY).getLaunchedToken(token).creatorFeeRecipient, next, "after");

        // Only the owner may call it, and a stranger cannot move the stream.
        vm.prank(address(0xBAD));
        vm.expectRevert(MothTaxSplitter.Unauthorized.selector);
        splitter.handOverCreatorFees(address(0xBAD));
    }
}
