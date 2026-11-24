// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {MothVault} from "../src/MothVault.sol";
import {PonsTokenSeller} from "../src/swappers/PonsTokenSeller.sol";
import {SellSwapperBase} from "../src/swappers/SellSwapperBase.sol";
import {MockERC20, MockERC721, MockSwapper, RejectingReceiver} from "./utils/Mocks.sol";
import {Test} from "./utils/Test.sol";
import {MockSellSwapper, ReentrantKeeper, ReentrantSeller} from "./utils/VaultMocks.sol";

contract MothVaultTest is Test {
    address constant OWNER = address(0x0E1);
    address constant NEW_OWNER = address(0x0E2);
    address constant KEEPER = address(0x4EE9);
    address constant STRANGER = address(0xBAD);
    address constant TREASURER = address(0x7EA5);
    address constant SUPPLIER = address(0x5E9911E5);
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    /// 1,000,000 $MOTH per ETH and 2,500 USDG per ETH, so $10 is 0.004 ETH and $50 is 0.02 ETH.
    uint256 constant TOKEN_PER_ETH = 1_000_000e18;
    uint256 constant USDG_PER_ETH = 2_500e6;

    uint256 constant GAS_FLOOR = 0.004 ether;
    uint256 constant GAS_TARGET = 0.02 ether;
    uint256 constant REFUEL_CAP = 50e6;
    uint256 constant KEEPER_FLOOR = 0.002 ether;
    uint256 constant KEEPER_TARGET = 0.005 ether;
    uint256 constant KEEPER_DAILY_CAP = 0.01 ether;

    MockERC20 token;
    MockERC20 usdg;
    MockSellSwapper tokenSeller;
    MockSwapper tokenBuyer;
    MockSwapper usdgBuyer;
    MockSellSwapper usdgSeller;
    MothVault vault;

    function setUp() public {
        token = new MockERC20(18);
        usdg = new MockERC20(6);
        tokenSeller = new MockSellSwapper(token, 1 ether, TOKEN_PER_ETH);
        usdgSeller = new MockSellSwapper(usdg, 1 ether, USDG_PER_ETH);
        usdgBuyer = new MockSwapper(usdg, USDG_PER_ETH);
        tokenBuyer = new MockSwapper(token, TOKEN_PER_ETH);
        vm.deal(address(tokenSeller), 1_000 ether);
        vm.deal(address(usdgSeller), 1_000 ether);
        vault = deploy(address(token));
        vm.warp(30 days);
    }

    function gas() internal pure returns (MothVault.GasConfig memory) {
        return MothVault.GasConfig(GAS_FLOOR, GAS_TARGET, REFUEL_CAP, KEEPER_FLOOR, KEEPER_TARGET, KEEPER_DAILY_CAP);
    }

    function routes() internal view returns (MothVault.Routes memory) {
        return MothVault.Routes(address(tokenSeller), address(tokenBuyer), address(usdgBuyer), address(usdgSeller));
    }

    function noRoutes() internal pure returns (MothVault.Routes memory) {
        return MothVault.Routes(address(0), address(0), address(0), address(0));
    }

    function deploy(address token_) internal returns (MothVault) {
        vm.prank(OWNER);
        return new MothVault(address(usdg), token_, KEEPER, gas(), routes());
    }

    function setRoutes(MothVault.Routes memory r) internal {
        vm.prank(OWNER);
        vault.setSwappers(r);
    }

    function process(uint256 minEthOut, uint256 minUsdgOut)
        internal
        returns (uint256 tokenIn, uint256 burned, uint256 sold, uint256 ethOut, uint256 ethToUsdg, uint256 usdgOut)
    {
        vm.prank(KEEPER);
        return vault.processToken(minEthOut, minUsdgOut);
    }

    function setBurn(uint16 bps) internal {
        vm.prank(OWNER);
        vault.setBurnBps(bps);
    }

    // ---------------------------------------------------------------- defaults

    function test_defaults() public view {
        assertEq(vault.owner(), OWNER, "owner is the deployer");
        assertEq(vault.pendingOwner(), address(0), "no pending owner");
        assertEq(vault.keeper(), KEEPER, "keeper");
        assertEq(address(vault.token()), address(token), "token");
        assertEq(address(vault.usdg()), address(usdg), "usdg");
        assertEq(address(vault.tokenSeller()), address(tokenSeller), "token seller");
        assertEq(address(vault.usdgBuyer()), address(usdgBuyer), "usdg buyer");
        assertEq(address(vault.usdgSeller()), address(usdgSeller), "usdg seller");
        assertEq(address(vault.tokenBuyer()), address(tokenBuyer), "token buyer");
        assertEq(vault.usdgBurnBps(), 0, "no USDG buy-back by default");
        assertEq(vault.supplierWallet(), address(0), "no supplier wallet yet");
        assertEq(vault.usdgSettled(), 0, "nothing settled");
        assertEq(vault.burnBps(), 2_000, "20% burned by default");
        assertEq(vault.DEAD(), DEAD, "dead address");
        assertTrue(!vault.paused(), "not paused");
        MothVault.GasConfig memory g = vault.gasConfig();
        assertEq(g.gasFloorWei, GAS_FLOOR, "gas floor");
        assertEq(g.gasTargetWei, GAS_TARGET, "gas target");
        assertEq(g.refuelUsdgCap, REFUEL_CAP, "refuel cap");
        assertEq(g.keeperFloorWei, KEEPER_FLOOR, "keeper floor");
        assertEq(g.keeperTargetWei, KEEPER_TARGET, "keeper target");
        assertEq(g.keeperDailyCapWei, KEEPER_DAILY_CAP, "keeper daily cap");
    }

    function test_constructorEmitsEverySetting() public {
        vm.recordLogs();
        deploy(address(token));
        assertEq(vm.getRecordedLogs().length, 7, "ownership, token, keeper, swappers, gas, both burn rates");
    }

    function test_constructorRejectsBadInput() public {
        vm.expectRevert(MothVault.ZeroAddress.selector);
        new MothVault(address(0), address(token), KEEPER, gas(), noRoutes());
        vm.expectRevert(MothVault.InvalidToken.selector);
        new MothVault(address(usdg), address(usdg), KEEPER, gas(), noRoutes());
        MothVault.GasConfig memory g = gas();
        g.gasFloorWei = g.gasTargetWei + 1;
        vm.expectRevert(MothVault.InvalidGasConfig.selector);
        new MothVault(address(usdg), address(token), KEEPER, g, noRoutes());
    }

    function test_acceptsEthFromATwoThousandThreeHundredGasTransfer() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(vault).call{value: 1 ether, gas: 2_300}("");
        assertTrue(ok, "a transfer() can fund the vault");
        assertEq(address(vault).balance, 1 ether, "funded");
    }

    // ---------------------------------------------------------------- processToken

    function test_processBurnsTwentyPercentAndSellsTheRest() public {
        vm.deal(address(vault), GAS_TARGET);
        token.mint(address(vault), 1_000_000e18);

        (uint256 tokenIn, uint256 burned, uint256 sold, uint256 ethOut, uint256 ethToUsdg, uint256 usdgOut) =
            process(0.8 ether, 2_000e6);

        assertEq(tokenIn, 1_000_000e18, "token in");
        assertEq(burned, 200_000e18, "20% burned");
        assertEq(sold, 800_000e18, "80% sold");
        assertEq(ethOut, 0.8 ether, "sale ETH");
        assertEq(ethToUsdg, 0.8 ether, "the reserve was full, so all the sale went to USDG");
        assertEq(usdgOut, 2_000e6, "usdg out");
        assertEq(token.balanceOf(DEAD), 200_000e18, "burned at the dead address");
        assertEq(token.balanceOf(address(vault)), 0, "no $MOTH left");
        assertEq(usdg.balanceOf(address(vault)), 2_000e6, "USDG stays in the vault");
        assertEq(address(vault).balance, GAS_TARGET, "reserve kept");
        assertEq(tokenSeller.lastAmountIn(), 800_000e18, "seller got the 80%");
        assertEq(tokenSeller.lastMinOut(), 0.8 ether, "seller got the minimum");
        assertEq(tokenSeller.lastRecipient(), address(vault), "ETH comes to the vault");
        assertEq(usdgBuyer.lastMinOut(), 2_000e6, "buyer got the minimum");
    }

    function test_processFillsAnEmptyReserveBeforeBuyingUsdg() public {
        token.mint(address(vault), 10_000e18); // sells 8,000 for 0.008 ETH, under the 0.02 target

        (,,, uint256 ethOut, uint256 ethToUsdg, uint256 usdgOut) = process(0, 0);

        assertEq(ethOut, 0.008 ether, "sale ETH");
        assertEq(ethToUsdg, 0, "all of it went to the reserve");
        assertEq(usdgOut, 0, "no USDG");
        assertEq(usdgBuyer.calls(), 0, "no USDG swap");
        assertEq(address(vault).balance, 0.008 ether, "reserve filled");
    }

    function test_processSplitsTheSaleBetweenReserveAndUsdg() public {
        vm.deal(address(vault), 0.015 ether);
        token.mint(address(vault), 10_000e18); // 0.008 ETH: 0.005 to the reserve, 0.003 to USDG

        (,,,, uint256 ethToUsdg, uint256 usdgOut) = process(0.008 ether, 7.5e6);

        assertEq(ethToUsdg, 0.003 ether, "the part above the target");
        assertEq(usdgOut, 7.5e6, "usdg out");
        assertEq(address(vault).balance, GAS_TARGET, "reserve exactly at the target");
    }

    function test_processNeverSpendsEthAlreadyHeld() public {
        vm.deal(address(vault), 1 ether);
        token.mint(address(vault), 10_000e18);

        (,,,, uint256 ethToUsdg,) = process(0, 0);

        assertEq(ethToUsdg, 0.008 ether, "only the sale's ETH");
        assertEq(address(vault).balance, 1 ether, "the ETH already held is untouched");
    }

    function test_processEmitsTheResult() public {
        vm.deal(address(vault), GAS_TARGET);
        token.mint(address(vault), 1_000_000e18);
        vm.expectEmit(false, false, false, true, address(vault));
        emit MothVault.TokenProcessed(1_000_000e18, 200_000e18, 800_000e18, 0.8 ether, 0.8 ether, 2_000e6);
        process(0, 0);
    }

    function test_processWithFullBurnSellsNothing() public {
        setBurn(10_000);
        token.mint(address(vault), 1_000e18);

        (, uint256 burned, uint256 sold, uint256 ethOut,,) = process(0, 0);

        assertEq(burned, 1_000e18, "all burned");
        assertEq(sold, 0, "nothing sold");
        assertEq(ethOut, 0, "no ETH");
        assertEq(tokenSeller.calls(), 0, "no sale");
    }

    function test_processWithFullBurnNeedsAZeroEthMinimum() public {
        setBurn(10_000);
        token.mint(address(vault), 1_000e18);
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(MothVault.InsufficientOutput.selector, address(0), 0, 1));
        vault.processToken(1, 0);
    }

    function test_processWithNoBurnSellsEverything() public {
        setBurn(0);
        token.mint(address(vault), 1_000e18);

        (, uint256 burned, uint256 sold,,,) = process(0, 0);

        assertEq(burned, 0, "nothing burned");
        assertEq(sold, 1_000e18, "all sold");
        assertEq(token.balanceOf(DEAD), 0, "nothing at the dead address");
    }

    function test_processUsesTheBurnRateInForce() public {
        token.mint(address(vault), 1_000e18);
        setBurn(5_000);
        (, uint256 burned,,,,) = process(0, 0);
        assertEq(burned, 500e18, "the new rate applies to the next run");
    }

    function testFuzz_processSplitsEveryAmount(uint256 amount, uint256 bps) public {
        amount = bound(amount, 1, 500 * TOKEN_PER_ETH); // the mock route holds 1,000 ETH
        bps = bound(bps, 0, 10_000);
        setBurn(uint16(bps));
        token.mint(address(vault), amount);

        (uint256 tokenIn, uint256 burned, uint256 sold,,,) = process(0, 0);

        assertEq(tokenIn, amount, "token in");
        assertEq(burned, (amount * bps) / 10_000, "burned share");
        assertEq(burned + sold, amount, "nothing lost");
        assertEq(token.balanceOf(DEAD), burned, "burned at the dead address");
        assertEq(token.balanceOf(address(vault)), 0, "nothing left");
    }

    function test_processKeepsTokensARouteHandsBack() public {
        tokenSeller.setKeepBackBps(1_000); // the route uses 90% and hands 10% back
        token.mint(address(vault), 1_000e18);

        (,, uint256 sold,,,) = process(0, 0);

        assertEq(sold, 720e18, "90% of the 800 sold");
        assertEq(token.balanceOf(address(vault)), 80e18, "the rest waits for the next run");
    }

    function test_processRevertsUnderTheEthMinimum() public {
        tokenSeller.setShortBy(1);
        token.mint(address(vault), 1_000_000e18);
        vm.prank(KEEPER);
        vm.expectRevert(
            abi.encodeWithSelector(MothVault.InsufficientOutput.selector, address(0), 0.8 ether - 1, 0.8 ether)
        );
        vault.processToken(0.8 ether, 0);
    }

    function test_processRevertsUnderTheUsdgMinimum() public {
        vm.deal(address(vault), GAS_TARGET);
        token.mint(address(vault), 1_000_000e18);
        vm.prank(KEEPER);
        vm.expectRevert(
            abi.encodeWithSelector(MothVault.InsufficientOutput.selector, address(usdg), 2_000e6, 2_000e6 + 1)
        );
        vault.processToken(0, 2_000e6 + 1);
    }

    function test_processRevertsOnAUsdgMinimumWhenNothingIsSwapped() public {
        token.mint(address(vault), 10_000e18); // all of the sale fills the reserve
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(MothVault.InsufficientOutput.selector, address(usdg), 0, 1));
        vault.processToken(0, 1);
    }

    function test_processRevertsWithNothingHeld() public {
        vm.prank(KEEPER);
        vm.expectRevert(MothVault.NothingToProcess.selector);
        vault.processToken(0, 0);
    }

    function test_processRevertsWithoutARoute() public {
        MothVault.Routes memory r = routes();
        r.tokenSeller = address(0);
        setRoutes(r);
        token.mint(address(vault), 1_000e18);
        vm.prank(KEEPER);
        vm.expectRevert(MothVault.SwapperNotSet.selector);
        vault.processToken(0, 0);

        r = routes();
        r.usdgBuyer = address(0);
        setRoutes(r);
        vm.deal(address(vault), GAS_TARGET);
        vm.prank(KEEPER);
        vm.expectRevert(MothVault.SwapperNotSet.selector);
        vault.processToken(0, 0);
    }

    function test_processHandlesATokenThatReturnsNothing() public {
        token.setReturnsNothing(true);
        token.mint(address(vault), 1_000e18);
        (, uint256 burned,,,,) = process(0, 0);
        assertEq(burned, 200e18, "burned");
    }

    // ---------------------------------------------------------------- token set later

    function test_processWaitsForTheToken() public {
        vault = deploy(address(0));
        vm.prank(KEEPER);
        vm.expectRevert(MothVault.TokenNotSet.selector);
        vault.processToken(0, 0);
    }

    /// The token can be set, changed or unset at any time, for a relaunch or anything else (founder, 2026-10-26).
    function test_setTokenAnyTime() public {
        vault = deploy(address(0));
        MockERC20 relaunched = new MockERC20(18);
        vm.startPrank(OWNER);
        vm.expectRevert(MothVault.InvalidToken.selector);
        vault.setToken(address(usdg));
        vm.expectEmit(true, false, false, false, address(vault));
        emit MothVault.TokenSet(address(token));
        vault.setToken(address(token));
        vm.expectEmit(true, false, false, false, address(vault));
        emit MothVault.TokenSet(address(relaunched));
        vault.setToken(address(relaunched));
        assertEq(address(vault.token()), address(relaunched), "changed after it was set");
        vault.setToken(address(0));
        assertEq(address(vault.token()), address(0), "unset");
        vm.stopPrank();

        vm.prank(STRANGER);
        vm.expectRevert(MothVault.Unauthorized.selector);
        vault.setToken(address(token));
        vm.prank(KEEPER);
        vm.expectRevert(MothVault.Unauthorized.selector);
        vault.setToken(address(token));
        vm.prank(KEEPER);
        vm.expectRevert(MothVault.TokenNotSet.selector);
        vault.processToken(0, 0);
    }

    /// After a relaunch the vault processes only the new token; the old one waits for the owner to take it out.
    function test_aRelaunchLeavesTheOldTokenForTheOwner() public {
        token.mint(address(vault), 1_000e18);
        MockERC20 relaunched = new MockERC20(18);
        MockSellSwapper relaunchedSeller = new MockSellSwapper(relaunched, 1 ether, TOKEN_PER_ETH);
        vm.deal(address(relaunchedSeller), 1_000 ether);
        vm.prank(OWNER);
        vault.setToken(address(relaunched));
        setRoutes(
            MothVault.Routes(address(relaunchedSeller), address(tokenBuyer), address(usdgBuyer), address(usdgSeller))
        );
        relaunched.mint(address(vault), 100e18);

        (uint256 tokenIn, uint256 burned,,,,) = process(0, 0);
        assertEq(tokenIn, 100e18, "only the new token is processed");
        assertEq(burned, 20e18, "20% of the new token burned");
        assertEq(relaunched.balanceOf(DEAD), 20e18, "at the dead address");
        assertEq(token.balanceOf(DEAD), 0, "the old token is not burned");
        assertEq(token.balanceOf(address(vault)), 1_000e18, "the old token waits");

        vm.prank(OWNER);
        vault.withdraw(address(token), TREASURER, type(uint256).max);
        assertEq(token.balanceOf(TREASURER), 1_000e18, "the owner takes the old token out");
    }

    // ---------------------------------------------------------------- refuel

    function test_refuelBuysGasWhenTheReserveIsLow() public {
        vm.deal(address(vault), 0.001 ether);
        usdg.mint(address(vault), 100e6);

        vm.expectEmit(false, false, false, true, address(vault));
        emit MothVault.Refuelled(25e6, 0.01 ether);
        vm.prank(KEEPER);
        uint256 ethOut = vault.refuel(25e6, 0.01 ether);

        assertEq(ethOut, 0.01 ether, "eth out");
        assertEq(address(vault).balance, 0.011 ether, "reserve refilled");
        assertEq(usdg.balanceOf(address(vault)), 75e6, "USDG spent");
        assertEq(usdgSeller.lastRecipient(), address(vault), "ETH comes to the vault");
    }

    function test_refuelOnlyUnderTheFloor() public {
        vm.deal(address(vault), GAS_FLOOR);
        usdg.mint(address(vault), 100e6);
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(MothVault.GasNotLow.selector, GAS_FLOOR, GAS_FLOOR));
        vault.refuel(25e6, 0);
    }

    function test_refuelIsCapped() public {
        usdg.mint(address(vault), 100e6);
        vm.startPrank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(MothVault.InvalidRefuelAmount.selector, REFUEL_CAP + 1, REFUEL_CAP));
        vault.refuel(REFUEL_CAP + 1, 0);
        vm.expectRevert(abi.encodeWithSelector(MothVault.InvalidRefuelAmount.selector, 0, REFUEL_CAP));
        vault.refuel(0, 0);
        vault.refuel(REFUEL_CAP, 0);
        vm.stopPrank();
        assertEq(usdg.balanceOf(address(vault)), 50e6, "the cap itself is allowed");
    }

    function test_refuelRevertsUnderTheMinimum() public {
        usdgSeller.setShortBy(1);
        usdg.mint(address(vault), 100e6);
        vm.prank(KEEPER);
        vm.expectRevert(
            abi.encodeWithSelector(MothVault.InsufficientOutput.selector, address(0), 0.01 ether - 1, 0.01 ether)
        );
        vault.refuel(25e6, 0.01 ether);
    }

    function test_refuelRevertsWithoutARoute() public {
        MothVault.Routes memory r = routes();
        r.usdgSeller = address(0);
        setRoutes(r);
        usdg.mint(address(vault), 100e6);
        vm.prank(KEEPER);
        vm.expectRevert(MothVault.SwapperNotSet.selector);
        vault.refuel(25e6, 0);
    }

    function test_refuelReportsOnlyTheUsdgSpent() public {
        usdgSeller.setKeepBackBps(2_000);
        usdg.mint(address(vault), 100e6);
        vm.expectEmit(false, false, false, true, address(vault));
        emit MothVault.Refuelled(20e6, 0.008 ether);
        vm.prank(KEEPER);
        vault.refuel(25e6, 0);
    }

    // ---------------------------------------------------------------- processUsdg

    function processUsdg(uint256 minEthOut, uint256 minTokenOut)
        internal
        returns (uint256 usdgIn, uint256 usdgSpent, uint256 ethOut, uint256 tokenBurned)
    {
        vm.prank(KEEPER);
        return vault.processUsdg(minEthOut, minTokenOut);
    }

    function setUsdgBurn(uint16 bps) internal {
        vm.prank(OWNER);
        vault.setUsdgBurnBps(bps);
    }

    function test_processUsdgAtTheDefaultShareOnlyMarksItSeen() public {
        usdg.mint(address(vault), 100e6);

        (uint256 usdgIn, uint256 usdgSpent,,) = processUsdg(0, 0);

        assertEq(usdgIn, 100e6, "seen");
        assertEq(usdgSpent, 0, "nothing spent at 0%");
        assertEq(usdg.balanceOf(address(vault)), 100e6, "all of it stays for inference");
        assertEq(vault.usdgSettled(), 100e6, "settled");
        assertEq(usdgSeller.calls() + tokenBuyer.calls(), 0, "no swaps");
        vm.prank(KEEPER);
        vm.expectRevert(MothVault.NothingToProcess.selector);
        vault.processUsdg(0, 0);
    }

    function test_processUsdgBuysBackAndBurnsItsShare() public {
        setUsdgBurn(2_000);
        usdg.mint(address(vault), 1_000e6); // 200 USDG is 0.08 ETH is 80,000 $MOTH

        vm.expectEmit(false, false, false, true, address(vault));
        emit MothVault.UsdgProcessed(1_000e6, 200e6, 0.08 ether, 80_000e18);
        (uint256 usdgIn, uint256 usdgSpent, uint256 ethOut, uint256 tokenBurned) = processUsdg(0.08 ether, 80_000e18);

        assertEq(usdgIn, 1_000e6, "usdg in");
        assertEq(usdgSpent, 200e6, "20% spent");
        assertEq(ethOut, 0.08 ether, "eth out");
        assertEq(tokenBurned, 80_000e18, "burned");
        assertEq(token.balanceOf(DEAD), 80_000e18, "at the dead address");
        assertEq(usdg.balanceOf(address(vault)), 800e6, "80% stays");
        assertEq(vault.usdgSettled(), 800e6, "the rest is settled");
        assertEq(address(vault).balance, 0, "none of the sale went to the reserve");
        assertEq(tokenBuyer.lastMinOut(), 80_000e18, "the buy got the minimum");
    }

    function test_processUsdgCountsOnlyNewArrivals() public {
        setUsdgBurn(2_000);
        usdg.mint(address(vault), 1_000e6);
        processUsdg(0, 0);
        usdg.mint(address(vault), 500e6);

        (uint256 usdgIn, uint256 usdgSpent,,) = processUsdg(0, 0);

        assertEq(usdgIn, 500e6, "only the new deposit");
        assertEq(usdgSpent, 100e6, "20% of it");
    }

    function test_processUsdgUsesTheShareInForce() public {
        usdg.mint(address(vault), 1_000e6);
        setUsdgBurn(10_000);
        (, uint256 usdgSpent,,) = processUsdg(0, 0);
        assertEq(usdgSpent, 1_000e6, "all of it at 100%");
        assertEq(usdg.balanceOf(address(vault)), 0, "nothing left");
    }

    function test_processUsdgLeavesPaidTokenAlone() public {
        setUsdgBurn(2_000);
        token.mint(address(vault), 1_000e18); // paid in, waiting for processToken
        usdg.mint(address(vault), 1_000e6);

        (,,, uint256 tokenBurned) = processUsdg(0, 0);

        assertEq(tokenBurned, 80_000e18, "only what it bought");
        assertEq(token.balanceOf(address(vault)), 1_000e18, "the paid $MOTH is untouched");
    }

    function test_usdgFromTokenSalesIsNeverBoughtBack() public {
        setUsdgBurn(2_000);
        vm.deal(address(vault), GAS_TARGET);
        token.mint(address(vault), 1_000_000e18);
        process(0, 0);
        assertEq(vault.usdgSettled(), 2_000e6, "the sale's USDG is settled at once");
        vm.prank(KEEPER);
        vm.expectRevert(MothVault.NothingToProcess.selector);
        vault.processUsdg(0, 0);
    }

    function test_processUsdgEnforcesBothMinimums() public {
        setUsdgBurn(2_000);
        usdg.mint(address(vault), 1_000e6);
        tokenBuyer.setShortBy(1);
        vm.prank(KEEPER);
        vm.expectRevert(
            abi.encodeWithSelector(MothVault.InsufficientOutput.selector, address(token), 80_000e18 - 1, 80_000e18)
        );
        vault.processUsdg(0, 80_000e18);

        usdgSeller.setShortBy(1);
        vm.prank(KEEPER);
        vm.expectRevert(
            abi.encodeWithSelector(MothVault.InsufficientOutput.selector, address(0), 0.08 ether - 1, 0.08 ether)
        );
        vault.processUsdg(0.08 ether, 0);
    }

    function test_processUsdgAtZeroShareRefusesMinimums() public {
        usdg.mint(address(vault), 1_000e6);
        vm.startPrank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(MothVault.InsufficientOutput.selector, address(0), 0, 1));
        vault.processUsdg(1, 0);
        vm.expectRevert(abi.encodeWithSelector(MothVault.InsufficientOutput.selector, address(token), 0, 1));
        vault.processUsdg(0, 1);
        vm.stopPrank();
    }

    function test_processUsdgNeedsTheTokenAndARoute() public {
        vault = deploy(address(0));
        setUsdgBurn(2_000);
        usdg.mint(address(vault), 1_000e6);
        vm.prank(KEEPER);
        vm.expectRevert(MothVault.TokenNotSet.selector);
        vault.processUsdg(0, 0);

        vm.prank(OWNER);
        vault.setToken(address(token));
        MothVault.Routes memory r = routes();
        r.tokenBuyer = address(0);
        setRoutes(r);
        vm.prank(KEEPER);
        vm.expectRevert(MothVault.SwapperNotSet.selector);
        vault.processUsdg(0, 0);
    }

    function test_everyUsdgOutflowLowersTheSettledMark() public {
        vm.prank(OWNER);
        vault.setSupplier(SUPPLIER, 1_000e6);
        usdg.mint(address(vault), 1_000e6);
        processUsdg(0, 0);
        assertEq(vault.usdgSettled(), 1_000e6, "settled");

        vm.prank(OWNER);
        vault.withdraw(address(usdg), TREASURER, 300e6);
        assertEq(vault.usdgSettled(), 700e6, "after a withdrawal");
        vm.prank(KEEPER);
        vault.paySupplier(200e6);
        assertEq(vault.usdgSettled(), 500e6, "after a supplier payout");
        vm.prank(KEEPER);
        vault.refuel(25e6, 0);
        assertEq(vault.usdgSettled(), 475e6, "after a refuel");

        usdg.mint(address(vault), 100e6);
        (uint256 usdgIn,,,) = processUsdg(0, 0);
        assertEq(usdgIn, 100e6, "only the new deposit, after every outflow");
    }

    function test_setUsdgBurnBps() public {
        vm.startPrank(OWNER);
        vm.expectRevert(MothVault.InvalidBps.selector);
        vault.setUsdgBurnBps(10_001);
        vm.expectEmit(false, false, false, true, address(vault));
        emit MothVault.UsdgBurnBpsChanged(2_000);
        vault.setUsdgBurnBps(2_000);
        vm.stopPrank();
        assertEq(vault.usdgBurnBps(), 2_000, "set");
    }

    // ---------------------------------------------------------------- paySupplier

    function test_paySupplierSendsUsdgToTheOwnersWalletWithinTheDailyCap() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit MothVault.SupplierChanged(SUPPLIER, 100e6);
        vm.prank(OWNER);
        vault.setSupplier(SUPPLIER, 100e6);
        usdg.mint(address(vault), 500e6);

        vm.startPrank(KEEPER);
        vm.expectEmit(true, false, false, true, address(vault));
        emit MothVault.SupplierPaid(SUPPLIER, 60e6);
        vault.paySupplier(60e6);
        vm.expectRevert(abi.encodeWithSelector(MothVault.SupplierCapReached.selector, 50e6, 40e6));
        vault.paySupplier(50e6);
        vault.paySupplier(40e6);
        vm.expectRevert(abi.encodeWithSelector(MothVault.SupplierCapReached.selector, 0, 0));
        vault.paySupplier(0);
        vm.warp(block.timestamp + 1 days);
        vault.paySupplier(100e6);
        vm.stopPrank();

        assertEq(usdg.balanceOf(SUPPLIER), 200e6, "paid");
        assertEq(vault.paidToday(), 100e6, "counter reset on the new day");
    }

    function test_paySupplierNeedsAWalletAndTheKeeper() public {
        usdg.mint(address(vault), 500e6);
        vm.prank(KEEPER);
        vm.expectRevert(MothVault.SupplierNotSet.selector);
        vault.paySupplier(1e6);

        vm.prank(OWNER);
        vault.setSupplier(SUPPLIER, 100e6);
        vm.prank(STRANGER);
        vm.expectRevert(MothVault.Unauthorized.selector);
        vault.paySupplier(1e6);

        vm.prank(OWNER);
        vault.setPaused(true);
        vm.prank(KEEPER);
        vm.expectRevert(MothVault.Paused.selector);
        vault.paySupplier(1e6);
        vm.prank(KEEPER);
        vm.expectRevert(MothVault.Paused.selector);
        vault.processUsdg(0, 0);
    }

    // ---------------------------------------------------------------- fuelKeeper

    function test_fuelKeeperTopsTheKeeperUpFromTheReserve() public {
        vm.deal(address(vault), GAS_TARGET);
        vm.deal(KEEPER, 0.001 ether);

        vm.expectEmit(true, false, false, true, address(vault));
        emit MothVault.KeeperFuelled(KEEPER, 0.004 ether);
        vm.prank(STRANGER); // anyone may call it
        uint256 amount = vault.fuelKeeper();

        assertEq(amount, 0.004 ether, "up to the target");
        assertEq(KEEPER.balance, KEEPER_TARGET, "keeper at the target");
        assertEq(address(vault).balance, GAS_TARGET - 0.004 ether, "paid from the reserve");
    }

    function test_fuelKeeperOnlyUnderTheFloor() public {
        vm.deal(address(vault), GAS_TARGET);
        vm.deal(KEEPER, KEEPER_FLOOR);
        vm.expectRevert(abi.encodeWithSelector(MothVault.KeeperNotLow.selector, KEEPER_FLOOR, KEEPER_FLOOR));
        vault.fuelKeeper();
    }

    function test_fuelKeeperStopsAtTheDailyCap() public {
        vm.deal(address(vault), 1 ether);

        vm.deal(KEEPER, 0);
        assertEq(vault.fuelKeeper(), 0.005 ether, "first fill");
        vm.deal(KEEPER, 0); // a leaked key spends it all
        assertEq(vault.fuelKeeper(), 0.005 ether, "second fill reaches the cap");
        vm.deal(KEEPER, 0);
        vm.expectRevert(MothVault.NothingToFuel.selector);
        vault.fuelKeeper();
        assertEq(vault.fuelledToday(), KEEPER_DAILY_CAP, "cap used");

        vm.warp(block.timestamp + 1 days);
        assertEq(vault.fuelKeeper(), 0.005 ether, "a new day, a new cap");
        assertEq(vault.fuelledToday(), 0.005 ether, "counter reset");
    }

    function test_fuelKeeperGivesWhatIsLeftOfTheCap() public {
        vm.deal(address(vault), 1 ether);
        vm.prank(OWNER);
        vault.setGasConfig(
            MothVault.GasConfig(GAS_FLOOR, GAS_TARGET, REFUEL_CAP, KEEPER_FLOOR, KEEPER_TARGET, 0.007 ether)
        );
        vm.deal(KEEPER, 0);
        vault.fuelKeeper();
        vm.deal(KEEPER, 0);
        assertEq(vault.fuelKeeper(), 0.002 ether, "only the cap's remainder");
    }

    function test_fuelKeeperNeverSendsMoreThanTheVaultHolds() public {
        vm.deal(address(vault), 0.001 ether);
        vm.deal(KEEPER, 0);
        assertEq(vault.fuelKeeper(), 0.001 ether, "all the vault has");
        vm.deal(KEEPER, 0);
        vm.expectRevert(MothVault.NothingToFuel.selector);
        vault.fuelKeeper();
    }

    function test_fuelKeeperNeedsAKeeper() public {
        vm.prank(OWNER);
        vault.setKeeper(address(0));
        vm.expectRevert(MothVault.KeeperNotSet.selector);
        vault.fuelKeeper();
    }

    function test_fuelKeeperCannotBeReentered() public {
        ReentrantKeeper k = new ReentrantKeeper();
        k.setVault(vault);
        vm.prank(OWNER);
        vault.setKeeper(address(k));
        vm.deal(address(vault), 1 ether);

        vault.fuelKeeper();

        assertEq(k.received(), KEEPER_TARGET, "paid once");
        assertEq(bytes32(k.fuelError()), bytes32(MothVault.Reentrancy.selector), "the inner call was refused");
    }

    // ---------------------------------------------------------------- pause

    function test_pauseStopsEveryKeeperStepButNotWithdrawals() public {
        vm.deal(address(vault), 0.001 ether);
        token.mint(address(vault), 1_000e18);
        usdg.mint(address(vault), 100e6);
        vm.expectEmit(false, false, false, true, address(vault));
        emit MothVault.PausedChanged(true);
        vm.prank(OWNER);
        vault.setPaused(true);

        vm.startPrank(KEEPER);
        vm.expectRevert(MothVault.Paused.selector);
        vault.processToken(0, 0);
        vm.expectRevert(MothVault.Paused.selector);
        vault.refuel(25e6, 0);
        vm.expectRevert(MothVault.Paused.selector);
        vault.fuelKeeper();
        vm.stopPrank();

        vm.prank(OWNER);
        vault.withdraw(address(usdg), TREASURER, type(uint256).max);
        assertEq(usdg.balanceOf(TREASURER), 100e6, "withdrawn while paused");

        vm.prank(OWNER);
        vault.setPaused(false);
        process(0, 0);
    }

    // ---------------------------------------------------------------- roles

    function test_onlyTheKeeperRunsTheSteps() public {
        token.mint(address(vault), 1_000e18);
        usdg.mint(address(vault), 100e6);
        address[2] memory others = [STRANGER, OWNER];
        for (uint256 i; i < others.length; i++) {
            vm.startPrank(others[i]);
            vm.expectRevert(MothVault.Unauthorized.selector);
            vault.processToken(0, 0);
            vm.expectRevert(MothVault.Unauthorized.selector);
            vault.refuel(25e6, 0);
            vm.stopPrank();
        }
    }

    function test_noKeeperMeansNoKeeperSteps() public {
        vm.prank(OWNER);
        vault.setKeeper(address(0));
        token.mint(address(vault), 1_000e18);
        vm.prank(address(0));
        vm.expectRevert(MothVault.Unauthorized.selector);
        vault.processToken(0, 0);
    }

    function test_theKeeperCannotWithdrawOrChangeAnything() public {
        vm.deal(address(vault), 1 ether);
        vm.startPrank(KEEPER);
        vm.expectRevert(MothVault.Unauthorized.selector);
        vault.withdraw(address(0), KEEPER, 1 ether);
        vm.expectRevert(MothVault.Unauthorized.selector);
        vault.setBurnBps(0);
        vm.expectRevert(MothVault.Unauthorized.selector);
        vault.setGasConfig(gas());
        vm.expectRevert(MothVault.Unauthorized.selector);
        vault.setKeeper(KEEPER);
        vm.expectRevert(MothVault.Unauthorized.selector);
        vault.setSwappers(noRoutes());
        vm.expectRevert(MothVault.Unauthorized.selector);
        vault.setUsdgBurnBps(2_000);
        vm.expectRevert(MothVault.Unauthorized.selector);
        vault.setSupplier(KEEPER, 1e12);
        vm.expectRevert(MothVault.Unauthorized.selector);
        vault.setToken(address(token));
        vm.expectRevert(MothVault.Unauthorized.selector);
        vault.setPaused(true);
        vm.expectRevert(MothVault.Unauthorized.selector);
        vault.transferOwnership(KEEPER);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- withdraw

    function test_ownerWithdrawsEth() public {
        vm.deal(address(vault), 1 ether);
        vm.expectEmit(true, true, false, true, address(vault));
        emit MothVault.Withdrawn(address(0), TREASURER, 0.4 ether);
        vm.prank(OWNER);
        assertEq(vault.withdraw(address(0), TREASURER, 0.4 ether), 0.4 ether, "sent");
        assertEq(TREASURER.balance, 0.4 ether, "part");

        vm.prank(OWNER);
        assertEq(vault.withdraw(address(0), TREASURER, type(uint256).max), 0.6 ether, "the rest");
        assertEq(address(vault).balance, 0, "empty");
    }

    function test_ownerWithdrawsAnyToken() public {
        MockERC20 other = new MockERC20(18);
        usdg.mint(address(vault), 500e6);
        token.mint(address(vault), 1_000e18);
        other.mint(address(vault), 7e18);
        vm.startPrank(OWNER);
        vault.withdraw(address(usdg), TREASURER, 200e6);
        vault.withdraw(address(usdg), TREASURER, type(uint256).max);
        vault.withdraw(address(token), TREASURER, type(uint256).max);
        vault.withdraw(address(other), TREASURER, type(uint256).max);
        vm.stopPrank();
        assertEq(usdg.balanceOf(TREASURER), 500e6, "usdg");
        assertEq(token.balanceOf(TREASURER), 1_000e18, "token");
        assertEq(other.balanceOf(TREASURER), 7e18, "any other token");
    }

    /// Any asset can come out (founder, 2026-10-26): an NFT that landed with a plain transfer too.
    function test_ownerWithdrawsAnNft() public {
        MockERC721 nft = new MockERC721();
        nft.mint(address(vault), 7);
        vm.prank(OWNER);
        vault.setPaused(true);
        vm.prank(OWNER);
        vm.expectEmit(true, true, true, false, address(vault));
        emit MothVault.NftWithdrawn(address(nft), TREASURER, 7);
        vault.withdrawNft(address(nft), 7, TREASURER);
        assertEq(nft.ownerOf(7), TREASURER, "the owner took the NFT out, even while paused");

        nft.mint(address(vault), 8);
        vm.prank(KEEPER);
        vm.expectRevert(MothVault.Unauthorized.selector);
        vault.withdrawNft(address(nft), 8, KEEPER);
        vm.prank(STRANGER);
        vm.expectRevert(MothVault.Unauthorized.selector);
        vault.withdrawNft(address(nft), 8, STRANGER);
        vm.prank(OWNER);
        vm.expectRevert(MothVault.ZeroAddress.selector);
        vault.withdrawNft(address(nft), 8, address(0));
        vm.prank(OWNER);
        vm.expectRevert(MothVault.TransferFailed.selector);
        vault.withdrawNft(address(nft), 9, TREASURER);
        assertEq(nft.ownerOf(8), address(vault), "still held");
    }

    /// The vault does not take NFTs sent with a safe transfer, so one sent by mistake stays with its sender.
    function test_safeNftTransfersBounce() public {
        MockERC721 nft = new MockERC721();
        nft.mint(STRANGER, 3);
        vm.prank(STRANGER);
        vm.expectRevert();
        nft.safeTransferFrom(STRANGER, address(vault), 3);
        assertEq(nft.ownerOf(3), STRANGER, "it stays with the sender");
    }

    function test_withdrawRejectsBadInput() public {
        vm.deal(address(vault), 1 ether);
        RejectingReceiver rejecter = new RejectingReceiver();
        vm.startPrank(OWNER);
        vm.expectRevert(MothVault.ZeroAddress.selector);
        vault.withdraw(address(0), address(0), 1);
        vm.expectRevert(MothVault.TransferFailed.selector);
        vault.withdraw(address(0), address(rejecter), 1);
        vm.expectRevert(MothVault.TransferFailed.selector);
        vault.withdraw(address(usdg), TREASURER, 1); // holds none
        vm.stopPrank();
        vm.prank(STRANGER);
        vm.expectRevert(MothVault.Unauthorized.selector);
        vault.withdraw(address(0), STRANGER, 1);
    }

    // ---------------------------------------------------------------- settings

    function test_setBurnBps() public {
        vm.startPrank(OWNER);
        vm.expectRevert(MothVault.InvalidBps.selector);
        vault.setBurnBps(10_001);
        vm.expectEmit(false, false, false, true, address(vault));
        emit MothVault.BurnBpsChanged(10_000);
        vault.setBurnBps(10_000);
        vm.stopPrank();
        assertEq(vault.burnBps(), 10_000, "set");
    }

    function test_setGasConfig() public {
        MothVault.GasConfig memory g = MothVault.GasConfig(1, 2, 3, 4, 5, 6);
        vm.startPrank(OWNER);
        vm.expectEmit(false, false, false, true, address(vault));
        emit MothVault.GasConfigChanged(1, 2, 3, 4, 5, 6);
        vault.setGasConfig(g);
        g.keeperFloorWei = 6;
        vm.expectRevert(MothVault.InvalidGasConfig.selector);
        vault.setGasConfig(g);
        vm.stopPrank();
        MothVault.GasConfig memory read = vault.gasConfig();
        assertEq(read.gasFloorWei, 1, "floor");
        assertEq(read.keeperDailyCapWei, 6, "daily cap");
    }

    function test_setKeeperAndSwappers() public {
        vm.startPrank(OWNER);
        vm.expectEmit(true, false, false, false, address(vault));
        emit MothVault.KeeperChanged(STRANGER);
        vault.setKeeper(STRANGER);
        vm.expectEmit(true, true, true, true, address(vault));
        emit MothVault.SwappersChanged(address(1), address(2), address(3), address(4));
        vault.setSwappers(MothVault.Routes(address(1), address(2), address(3), address(4)));
        vm.stopPrank();
        assertEq(vault.keeper(), STRANGER, "keeper");
        assertEq(address(vault.tokenSeller()), address(1), "token seller");
        assertEq(address(vault.tokenBuyer()), address(2), "token buyer");
        assertEq(address(vault.usdgBuyer()), address(3), "usdg buyer");
        assertEq(address(vault.usdgSeller()), address(4), "usdg seller");
    }

    function test_ownershipMovesInTwoSteps() public {
        vm.prank(OWNER);
        vault.transferOwnership(NEW_OWNER);
        assertEq(vault.owner(), OWNER, "not yet");
        vm.prank(STRANGER);
        vm.expectRevert(MothVault.Unauthorized.selector);
        vault.acceptOwnership();
        vm.prank(NEW_OWNER);
        vault.acceptOwnership();
        assertEq(vault.owner(), NEW_OWNER, "moved");
        assertEq(vault.pendingOwner(), address(0), "cleared");
        vm.prank(OWNER);
        vm.expectRevert(MothVault.Unauthorized.selector);
        vault.setBurnBps(0);
    }

    function test_transferToZeroCancels() public {
        vm.startPrank(OWNER);
        vault.transferOwnership(NEW_OWNER);
        vault.transferOwnership(address(0));
        vm.stopPrank();
        vm.prank(NEW_OWNER);
        vm.expectRevert(MothVault.Unauthorized.selector);
        vault.acceptOwnership();
    }

    // ---------------------------------------------------------------- reentrancy

    function test_processCannotBeReentered() public {
        ReentrantSeller seller = new ReentrantSeller();
        seller.setVault(vault);
        vm.startPrank(OWNER);
        vault.setKeeper(address(seller));
        vault.setSwappers(
            MothVault.Routes(address(seller), address(tokenBuyer), address(usdgBuyer), address(usdgSeller))
        );
        vm.stopPrank();
        token.mint(address(vault), 1_000e18);
        vm.prank(address(seller));
        vm.expectRevert(MothVault.Reentrancy.selector);
        vault.processToken(0, 0);
    }

    // ---------------------------------------------------------------- token seller checks

    function test_tokenSellerChecksInputBeforeSwapping() public {
        PonsTokenSeller pons = new PonsTokenSeller(address(token), address(0x1), address(0x2));
        token.mint(address(pons), 1e18);
        vm.expectRevert(SellSwapperBase.WrongToken.selector);
        pons.swapForEth(address(usdg), 1e6, 0, address(this));
        vm.expectRevert(abi.encodeWithSelector(SellSwapperBase.InputNotReceived.selector, 1e18, 2e18));
        pons.swapForEth(address(token), 2e18, 0, address(this));
    }
}
