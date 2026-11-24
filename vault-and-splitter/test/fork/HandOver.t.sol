// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {RobinhoodFork, IERC20Like, IPonsFactory, IPonsCurve} from "./RobinhoodFork.sol";
import {MothTaxSplitter} from "../../src/MothTaxSplitter.sol";
import {IPonsV2Curve, IPonsV2Hook} from "../../src/interfaces/IPonsV2.sol";
import {PonsRoute} from "../../src/swappers/PonsRoute.sol";
import {UsdgSwapper} from "../../src/swappers/UsdgSwapper.sol";
import {Vm} from "../utils/Test.sol";

/// The state snapshot cheatcodes, which the shared Vm interface does not declare.
interface VmState {
    function snapshotState() external returns (uint256 snapshotId);
    function revertToState(uint256 snapshotId) external returns (bool success);
}

interface IHandOverFactory {
    function transferCreatorFeeRecipient(address token, address newRecipient) external;
    function memeHook() external view returns (address);
}

interface IHandOverEscrow {
    function balanceOf(address recipient) external view returns (uint256);
    function claim() external returns (uint256 amount);
}

interface IERC20Send {
    function transfer(address to, uint256 amount) external returns (bool);
}

/// Sells a native launch token into whichever venue it is on. In the graduated pool an exact-input sale leaves the
/// hook's fees in ETH (the output currency), which the creator may sweep without Pons's operator.
contract HandOverTrader is PonsRoute {
    constructor(address poolManager_, address ponsFactory_) PonsRoute(poolManager_, ponsFactory_) {}

    function sell(address token, uint256 tokenIn, address recipient) external returns (uint256) {
        return _ponsSell(token, tokenIn, 0, recipient, msg.sender);
    }

    receive() external payable {}
}

/// The launch-day order (final review I2), against the real Pons V2 factory, curve, hook and fee escrow. The launch
/// names the owner wallet as creator fee recipient; trades happen; the owner calls the factory's
/// `transferCreatorFeeRecipient(token, splitter)`; more trades happen; then the keeper's `distribute` sweeps, claims
/// and splits. What Pons's source says about fees from before the hand-over is asserted: fees already swept into the
/// escrow stay the owner's (the owner claims them with `claim()`), and fees still pending at the hand-over go to the
/// splitter at its next sweep, because the curve and the hook pay whoever is the recipient when the sweep runs. Every
/// threshold and trade size is read from the chain.
contract HandOverForkTest is RobinhoodFork {
    address internal constant KEEPER = address(0x4EE9);
    address internal constant DEV = address(0xDE5);
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    /// The founder's wallet in this test: the launch's first creator fee recipient. It has no code, as on launch day.
    address internal constant OWNER_WALLET = address(0x0A11CE);

    VmState internal constant vmState = VmState(address(vm));

    MothTaxSplitter internal splitter;

    function setUp() public override {
        super.setUp();
        if (!forked) return;
        UsdgSwapper usdgSwapper = new UsdgSwapper(USDG, POOL_MANAGER, ethUsdgPool());
        splitter = new MothTaxSplitter(
            address(0), USDG, POOL_MANAGER, PONS_FACTORY, PONS_FEE_ESCROW, KEEPER, DEV, MOTH_VAULT, address(usdgSwapper)
        );
    }

    /// The owner wallet, not the splitter, is named at launch.
    function creatorFeeRecipient() internal pure override returns (address) {
        return OWNER_WALLET;
    }

    function owed(address who) internal view returns (uint256) {
        return IHandOverEscrow(PONS_FEE_ESCROW).balanceOf(who);
    }

    function recipientOf(address token) internal view returns (address) {
        return IPonsFactory(PONS_FACTORY).getLaunchedToken(token).creatorFeeRecipient;
    }

    /// A buy on the curve past the snipe window: a twentieth of a graduating buy, read from the chain.
    function tradeOnCurve(address token, address curve) internal {
        vm.warp(block.timestamp + SNIPE_WINDOW);
        uint256 amount = graduationBuyEth(token) / 20;
        vm.deal(buyer, amount);
        vm.prank(buyer);
        IPonsCurve(curve).buy{value: amount}(amount, 0, buyer);
    }

    /// A sale of a tenth of the buyer's tokens into the graduated pool, which leaves the hook's fees in ETH.
    function sellInPool(address token, HandOverTrader trader) internal {
        uint256 tokens = IERC20Like(token).balanceOf(buyer) / 10;
        require(tokens > 0, "sellInPool: the buyer holds no tokens");
        vm.prank(buyer);
        IERC20Send(token).transfer(address(trader), tokens);
        trader.sell(token, tokens, buyer);
    }

    function poolId(address token) internal view returns (bytes32) {
        IPonsFactory.LaunchedToken memory launch = IPonsFactory(PONS_FACTORY).getLaunchedToken(token);
        address hook = IHandOverFactory(PONS_FACTORY).memeHook();
        return keccak256(abi.encode(address(0), token, launch.poolFee, launch.tickSpacing, hook));
    }

    /// What the owner wallet's own sweep would credit it now, measured in a snapshot that is then undone.
    function pendingForOwner(address token, bool onCurve) internal returns (uint256 pending) {
        // The targets are read first: a read between the prank and the sweep would take the prank.
        address curve = IPonsFactory(PONS_FACTORY).getLaunchedToken(token).curve;
        IPonsV2Hook hook = IPonsV2Hook(IHandOverFactory(PONS_FACTORY).memeHook());
        bytes32 id = poolId(token);
        uint256 snap = vmState.snapshotState();
        uint256 before = owed(OWNER_WALLET);
        vm.prank(OWNER_WALLET);
        if (onCurve) {
            IPonsV2Curve(curve).sweepFees(0);
        } else {
            hook.sweepPoolFees(id, 0, 0);
        }
        pending = owed(OWNER_WALLET) - before;
        vmState.revertToState(snap);
    }

    function handOver(address token) internal {
        assertEq(recipientOf(token), OWNER_WALLET, "the launch named the owner wallet");
        vm.prank(OWNER_WALLET);
        IHandOverFactory(PONS_FACTORY).transferCreatorFeeRecipient(token, address(splitter));
        assertEq(recipientOf(token), address(splitter), "the splitter is the recipient after the hand-over");
    }

    struct Result {
        uint256 ethIn;
        uint256 burned;
        uint256 toCredit;
        uint256 toDev;
        uint256 sweepFailures;
    }

    function distribute() internal returns (Result memory r) {
        vm.recordLogs();
        vm.prank(KEEPER);
        (r.ethIn, r.burned, r.toCredit, r.toDev) = splitter.distribute(1, 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(splitter) && logs[i].topics[0] == MothTaxSplitter.SweepFailed.selector) {
                r.sweepFailures++;
            }
        }
    }

    /// The three shares at the default split, each where it should be, and nothing left behind.
    function assertThreeShares(
        address token,
        Result memory r,
        uint256 deadBefore,
        uint256 vaultUsdgBefore,
        uint256 devBefore
    ) internal view {
        assertTrue(r.ethIn > 0, "fees were claimed");
        assertTrue(r.burned > 0, "the burn share bought $MOTH");
        assertEq(IERC20Like(token).balanceOf(DEAD) - deadBefore, r.burned, "the dead address gains the $MOTH");
        assertTrue(r.toCredit > 0, "the credit share bought USDG");
        assertEq(IERC20Like(USDG).balanceOf(MOTH_VAULT) - vaultUsdgBefore, r.toCredit, "the vault gains the USDG");
        assertEq(r.toDev, r.ethIn - (r.ethIn * 833) / 10_000 - (r.ethIn * 2_500) / 10_000, "dev share");
        assertEq(DEV.balance - devBefore, r.toDev, "the dev wallet gains its share in ETH");
        assertEq(address(splitter).balance, 0, "no ETH left in the splitter");
        assertEq(IERC20Like(token).balanceOf(address(splitter)), 0, "no $MOTH left in the splitter");
    }

    /// The owner wallet's swept fees stay its own after the hand-over, and it claims them from the escrow.
    function assertOwnerKeepsSwept(uint256 swept) internal {
        assertEq(owed(OWNER_WALLET), swept, "fees swept before the hand-over stay the owner's");
        uint256 before = OWNER_WALLET.balance;
        vm.prank(OWNER_WALLET);
        uint256 claimed = IHandOverEscrow(PONS_FEE_ESCROW).claim();
        assertEq(claimed, swept, "the owner claims them");
        assertEq(OWNER_WALLET.balance - before, swept, "the owner wallet receives them in ETH");
        assertEq(owed(OWNER_WALLET), 0, "nothing left for the owner");
    }

    function test_launchDayOrder_onTheCurve() public {
        if (!forked) return;
        (address token, address curve) = launchTestToken();
        splitter.setToken(token);

        // Trades before the hand-over: the owner sweeps the first into the escrow; the second stays pending.
        tradeOnCurve(token, curve);
        vm.prank(OWNER_WALLET);
        IPonsV2Curve(curve).sweepFees(0);
        uint256 swept = owed(OWNER_WALLET);
        assertTrue(swept > 0, "the owner's sweep credited the escrow");
        tradeOnCurve(token, curve);
        uint256 pendingAtHandOver = pendingForOwner(token, true);
        assertTrue(pendingAtHandOver > 0, "fees are pending on the curve at the hand-over");

        // What the trade after the hand-over adds, measured in a snapshot with the owner sweeping, then undone.
        uint256 snap = vmState.snapshotState();
        vm.prank(OWNER_WALLET);
        IPonsV2Curve(curve).sweepFees(0);
        uint256 mid = owed(OWNER_WALLET);
        tradeOnCurve(token, curve);
        vm.prank(OWNER_WALLET);
        IPonsV2Curve(curve).sweepFees(0);
        uint256 later = owed(OWNER_WALLET) - mid;
        vmState.revertToState(snap);

        handOver(token);
        tradeOnCurve(token, curve);

        uint256 deadBefore = IERC20Like(token).balanceOf(DEAD);
        uint256 vaultUsdgBefore = IERC20Like(USDG).balanceOf(MOTH_VAULT);
        uint256 devBefore = DEV.balance;
        Result memory r = distribute();

        assertEq(r.sweepFailures, 0, "the splitter's curve sweep worked");
        assertEq(r.ethIn, pendingAtHandOver + later, "the fees pending at the hand-over and those after it went to the splitter");
        assertEq(owed(address(splitter)), 0, "the splitter claimed all it was owed");
        assertThreeShares(token, r, deadBefore, vaultUsdgBefore, devBefore);
        assertOwnerKeepsSwept(swept);
    }

    function test_launchDayOrder_handOverAfterGraduation() public {
        if (!forked) return;
        (address token, address curve) = launchTestToken();
        splitter.setToken(token);
        tradeOnCurve(token, curve);

        // Graduation sweeps the curve's fees into the escrow for the recipient of the moment: the owner wallet.
        buyToGraduation(token);
        createPool(token);
        uint256 swept = owed(OWNER_WALLET);
        assertTrue(swept > 0, "graduation credited the owner's escrow balance");

        HandOverTrader trader = new HandOverTrader(POOL_MANAGER, PONS_FACTORY);
        sellInPool(token, trader);
        uint256 pendingAtHandOver = pendingForOwner(token, false);
        assertTrue(pendingAtHandOver > 0, "ETH fees are pending in the hook at the hand-over");

        // What the sale after the hand-over adds, measured in a snapshot with the owner sweeping, then undone.
        IPonsV2Hook hook = IPonsV2Hook(IHandOverFactory(PONS_FACTORY).memeHook());
        bytes32 id = poolId(token);
        uint256 snap = vmState.snapshotState();
        vm.prank(OWNER_WALLET);
        hook.sweepPoolFees(id, 0, 0);
        uint256 mid = owed(OWNER_WALLET);
        sellInPool(token, trader);
        vm.prank(OWNER_WALLET);
        hook.sweepPoolFees(id, 0, 0);
        uint256 later = owed(OWNER_WALLET) - mid;
        vmState.revertToState(snap);

        handOver(token);
        sellInPool(token, trader);

        // Only the recipient of the moment may sweep the pool: the owner wallet no longer can, the splitter can.
        vm.prank(OWNER_WALLET);
        vm.expectRevert();
        hook.sweepPoolFees(id, 0, 0);

        uint256 deadBefore = IERC20Like(token).balanceOf(DEAD);
        uint256 vaultUsdgBefore = IERC20Like(USDG).balanceOf(MOTH_VAULT);
        uint256 devBefore = DEV.balance;
        Result memory r = distribute();

        assertEq(r.sweepFailures, 0, "the hook accepted the splitter's sweep");
        assertEq(r.ethIn, pendingAtHandOver + later, "the fees pending at the hand-over and those after it went to the splitter");
        assertEq(owed(address(splitter)), 0, "the splitter claimed all it was owed");
        assertThreeShares(token, r, deadBefore, vaultUsdgBefore, devBefore);
        assertOwnerKeepsSwept(swept);
    }
}
