// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Vm} from "../utils/Test.sol";
import {RobinhoodFork, IERC20Like, IPonsFactory} from "./RobinhoodFork.sol";
import {MothVault} from "../../src/MothVault.sol";
import {PonsTokenSeller} from "../../src/swappers/PonsTokenSeller.sol";
import {PonsTokenBuyer} from "../../src/swappers/PonsTokenBuyer.sol";
import {SellSwapperBase} from "../../src/swappers/SellSwapperBase.sol";
import {SwapperBase} from "../../src/swappers/SwapperBase.sol";
import {PonsRoute} from "../../src/swappers/PonsRoute.sol";
import {UsdgSeller} from "../../src/swappers/UsdgSeller.sol";
import {UsdgSwapper} from "../../src/swappers/UsdgSwapper.sol";
import {IV4PoolManager} from "../../src/interfaces/IV4PoolManager.sol";

/// The deployed MothVault driven end to end on the fork, through the four routes. The owner and the keeper
/// are impersonated. A Pons launch paired with native ETH stands in for $MOTH, so each $MOTH route is one Pons
/// trade. Each flow runs on the curve and again after graduation, and after each one every route must hold no
/// USDG, token or ETH.
contract VaultFlowTest is RobinhoodFork {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    bytes32 internal constant CURVE_BUY_TOPIC =
        keccak256("CurveBuy(address,address,uint256,uint256,uint256,uint256)");
    bytes32 internal constant CURVE_REFUND_TOPIC = keccak256("CurveBuyRefunded(address,uint256)");
    uint256 internal constant GAS_FLOOR = 0.0005 ether;
    uint256 internal constant GAS_TARGET = 0.001 ether;
    uint256 internal constant REFUEL_CAP = 50e6;

    /// A token minimum no buy can meet (supply is about 1e27). Not `type(uint256).max`: that makes the Pons curve
    /// itself panic on overflow while it prices a partial buy, which is still a revert but not a slippage error.
    uint256 internal constant TOO_MANY_TOKENS = 1e30;
    /// The Pons curve's own slippage error, for a buy and a sale alike. On the curve venue the $MOTH routes pass
    /// the minimum to the curve, which reverts before the route's own checks are reached.
    bytes4 internal constant CURVE_SLIPPAGE_SELECTOR = bytes4(keccak256("SlippageExceeded(uint256,uint256)"));

    MothVault internal vault = MothVault(payable(MOTH_VAULT));
    address internal token;
    address[4] internal routes; // tokenSeller, tokenBuyer, usdgBuyer, usdgSeller

    /// Calls the vault as the keeper and checks that it reverts with `selector`, and, for a two-argument error whose
    /// second argument is the minimum (the routes' `InsufficientOutput` and the curve's `SlippageExceeded`), that the
    /// minimum is `minArg`.
    function expectKeeperRevert(bytes memory callData, bytes4 selector, uint256 minArg) internal {
        vm.prank(VAULT_KEEPER);
        (bool ok, bytes memory ret) = address(vault).call(callData);
        assertTrue(!ok, "call should revert");
        assertEq(bytes32(bytes4(ret)), bytes32(selector), "wrong revert selector");
        if (
            selector != PonsRoute.RouteInsufficientOutput.selector
                && selector != SellSwapperBase.InsufficientOutput.selector && selector != CURVE_SLIPPAGE_SELECTOR
        ) return;
        uint256 minInError;
        assembly {
            minInError := mload(add(ret, 68))
        }
        assertEq(minInError, minArg, "minimum in error");
    }

    function bal(address asset, address who) internal view returns (uint256) {
        return IERC20Like(asset).balanceOf(who);
    }

    /// Launches the test token, deploys the four routes and points the vault at them.
    /// `phase` is the launch phase the fixture stops at: 0 on the curve, 1 Swept (no pool yet), 2 pool created.
    function configure(uint256 phase) internal {
        (token,) = launchTestToken();
        if (phase >= 1) {
            buyToGraduation(token);
            if (phase == 2) createPool(token);
        } else {
            vm.warp(block.timestamp + SNIPE_WINDOW);
        }
        assertEq(uint256(IPonsFactory(PONS_FACTORY).getLaunchedToken(token).phase), phase, "fixture phase");
        routes[0] = address(new PonsTokenSeller(token, POOL_MANAGER, PONS_FACTORY));
        routes[1] = address(new PonsTokenBuyer(token, POOL_MANAGER, PONS_FACTORY));
        routes[2] = address(new UsdgSwapper(USDG, POOL_MANAGER, ethUsdgPool()));
        routes[3] = address(new UsdgSeller(USDG, POOL_MANAGER, ethUsdgPool()));

        MothVault.GasConfig memory gas = vault.gasConfig();
        gas.gasFloorWei = GAS_FLOOR;
        gas.gasTargetWei = GAS_TARGET;
        gas.refuelUsdgCap = REFUEL_CAP;
        vm.startPrank(VAULT_OWNER);
        vault.setToken(token);
        vault.setSwappers(MothVault.Routes(routes[0], routes[1], routes[2], routes[3]));
        vault.setGasConfig(gas);
        vm.stopPrank();
    }

    function setBurn(uint16 burnBps, uint16 usdgBurnBps) internal {
        vm.startPrank(VAULT_OWNER);
        vault.setBurnBps(burnBps);
        vault.setUsdgBurnBps(usdgBurnBps);
        vm.stopPrank();
    }

    /// Buys `ethSpend` worth of the test token on the curve, straight to `to`, from a throwaway buyer.
    function giveToken(address to, uint256 ethSpend) internal {
        address who = address(0xB1D);
        vm.deal(who, ethSpend);
        IPonsFactory.LaunchedToken memory launch = IPonsFactory(PONS_FACTORY).getLaunchedToken(token);
        require(launch.phase == 0, "giveToken: curve only");
        vm.prank(who);
        IPonsCurveBuy(launch.curve).buy{value: ethSpend}(ethSpend, 1, to);
    }

    /// Hands the vault test tokens. After graduation the pool is the venue, so the tokens come from the buy of the
    /// graduation itself, which `buyToGraduation` leaves with `buyer`.
    function stockVault(uint256 phase, uint256 ethSpend) internal returns (uint256 held) {
        if (phase == 0) {
            giveToken(MOTH_VAULT, ethSpend);
        } else {
            uint256 give = bal(token, buyer) / 2;
            vm.prank(buyer);
            IERC20Transfer(token).transfer(MOTH_VAULT, give);
        }
        held = bal(token, MOTH_VAULT);
        assertTrue(held > 0, "vault holds token");
    }

    function assertRoutesEmpty() internal view {
        for (uint256 i = 0; i < 4; i++) {
            assertEq(bal(USDG, routes[i]), 0, "route usdg");
            assertEq(bal(token, routes[i]), 0, "route token");
            assertEq(routes[i].balance, 0, "route eth");
        }
    }

    // ------------------------------------------------------------ processToken

    function processTokenCase(bool graduated, uint16 burnBps) internal {
        configure(graduated ? 2 : 0);
        setBurn(burnBps, 0);
        vm.deal(MOTH_VAULT, 0);
        uint256 held = stockVault(graduated ? 2 : 0, 0.05 ether);
        uint256 usdgBefore = bal(USDG, MOTH_VAULT);
        uint256 settledBefore = vault.usdgSettled();
        uint256 deadBefore = bal(token, DEAD);

        vm.prank(VAULT_KEEPER);
        (uint256 tokenIn, uint256 burned, uint256 sold, uint256 ethOut, uint256 ethToUsdg, uint256 usdgOut) =
            vault.processToken(1, 1);

        assertEq(tokenIn, held, "tokenIn");
        assertEq(burned, (held * burnBps) / 10_000, "burned share");
        assertEq(bal(token, DEAD) - deadBefore, burned, "dead balance");
        assertEq(sold, held - burned, "sold the rest");
        assertEq(bal(token, MOTH_VAULT), 0, "vault token left");
        assertTrue(ethOut > GAS_TARGET, "sale larger than reserve");
        assertEq(ethToUsdg, ethOut - GAS_TARGET, "spare above the reserve");
        assertEq(MOTH_VAULT.balance, GAS_TARGET, "reserve topped up to target");
        assertTrue(usdgOut > 0, "usdg bought");
        assertEq(bal(USDG, MOTH_VAULT) - usdgBefore, usdgOut, "usdg arrived");
        assertEq(vault.usdgSettled() - settledBefore, usdgOut, "usdgSettled grew by usdgOut");
        assertRoutesEmpty();
    }

    function test_processToken_burnsSellsAndSettles_onCurve() public {
        if (!forked) return;
        processTokenCase(false, 2000);
    }

    function test_processToken_burnsSellsAndSettles_inPool() public {
        if (!forked) return;
        processTokenCase(true, 2000);
    }

    /// The founder's 2026-11-22 decision: the owner sets the burn share to zero, so nothing is burned.
    function test_processToken_zeroBurn_sellsEverything_onCurve() public {
        if (!forked) return;
        processTokenCase(false, 0);
    }

    function test_processToken_zeroBurn_sellsEverything_inPool() public {
        if (!forked) return;
        processTokenCase(true, 0);
    }

    /// A minimum the sale cannot meet reverts the whole step and moves nothing. On the curve the minimum reaches the
    /// curve, so its own slippage check refuses the sale.
    function test_processToken_tooHighMinimum_reverts() public {
        if (!forked) return;
        configure(0);
        setBurn(2000, 0);
        vm.deal(MOTH_VAULT, 0);
        uint256 held = stockVault(0, 0.05 ether);
        uint256 usdgBefore = bal(USDG, MOTH_VAULT);
        uint256 settledBefore = vault.usdgSettled();
        uint256 deadBefore = bal(token, DEAD);

        expectKeeperRevert(
            abi.encodeCall(vault.processToken, (type(uint256).max, 0)),
            CURVE_SLIPPAGE_SELECTOR,
            type(uint256).max
        );

        assertEq(bal(token, MOTH_VAULT), held, "vault token unchanged");
        assertEq(bal(token, DEAD), deadBefore, "nothing burned");
        assertEq(bal(USDG, MOTH_VAULT), usdgBefore, "usdg unchanged");
        assertEq(vault.usdgSettled(), settledBefore, "settled unchanged");
        assertEq(MOTH_VAULT.balance, 0, "eth unchanged");
        assertRoutesEmpty();
    }

    /// A second minimum, on the USDG leg, also reverts the whole step.
    function test_processToken_tooHighUsdgMinimum_reverts() public {
        if (!forked) return;
        configure(0);
        setBurn(0, 0);
        vm.deal(MOTH_VAULT, 0);
        uint256 held = stockVault(0, 0.05 ether);
        expectKeeperRevert(
            abi.encodeCall(vault.processToken, (1, type(uint256).max)),
            SwapperBase.InsufficientOutput.selector,
            type(uint256).max
        );
        assertEq(bal(token, MOTH_VAULT), held, "vault token unchanged");
        assertRoutesEmpty();
    }

    // ------------------------------------------------------------ processUsdg

    function processUsdgCase(bool graduated) internal {
        configure(graduated ? 2 : 0);
        setBurn(0, 2000);
        vm.deal(MOTH_VAULT, 0);
        uint256 arrived = 1_000e6;
        uint256 settled = vault.usdgSettled();
        uint256 total = settled + arrived;
        fund(USDG, MOTH_VAULT, total);
        uint256 deadBefore = bal(token, DEAD);

        vm.prank(VAULT_KEEPER);
        (uint256 usdgIn, uint256 usdgSpent, uint256 ethOut, uint256 tokenBurned) = vault.processUsdg(1, 1);

        assertEq(usdgIn, arrived, "usdgIn");
        assertEq(usdgSpent, (arrived * 2000) / 10_000, "spent the share");
        assertTrue(ethOut > 0, "eth out");
        assertTrue(tokenBurned > 0, "token bought");
        assertEq(bal(token, DEAD) - deadBefore, tokenBurned, "burned at dead");
        assertEq(bal(token, MOTH_VAULT), 0, "vault holds no token");
        assertEq(MOTH_VAULT.balance, 0, "no eth left in vault");
        assertEq(bal(USDG, MOTH_VAULT), total - usdgSpent, "vault usdg");
        assertEq(vault.usdgSettled(), bal(USDG, MOTH_VAULT), "settled equals balance");
        assertRoutesEmpty();
    }

    function test_processUsdg_buysBack_onCurve() public {
        if (!forked) return;
        processUsdgCase(false);
    }

    function test_processUsdg_buysBack_inPool() public {
        if (!forked) return;
        processUsdgCase(true);
    }

    function test_processUsdg_tooHighMinimum_reverts() public {
        if (!forked) return;
        configure(0);
        setBurn(0, 2000);
        vm.deal(MOTH_VAULT, 0);
        uint256 total = vault.usdgSettled() + 1_000e6;
        fund(USDG, MOTH_VAULT, total);
        uint256 settled = vault.usdgSettled();

        expectKeeperRevert(abi.encodeCall(vault.processUsdg, (1, TOO_MANY_TOKENS)), CURVE_SLIPPAGE_SELECTOR, TOO_MANY_TOKENS);

        assertEq(bal(USDG, MOTH_VAULT), total, "usdg unchanged");
        assertEq(vault.usdgSettled(), settled, "settled unchanged");
        assertEq(MOTH_VAULT.balance, 0, "eth unchanged");
        assertRoutesEmpty();
    }

    /// What `ethIn` wei sells for in the ETH / USDG pool at its current price, before the fee, from the pool's
    /// sqrt price in slot0 of its state (the PoolManager's pool mapping sits at slot 6).
    function usdgForEth(uint256 ethIn) internal view returns (uint256) {
        bytes32 poolId = keccak256(abi.encode(ethUsdgPool()));
        bytes32 slot0 = IV4PoolManager(POOL_MANAGER).extsload(keccak256(abi.encode(poolId, uint256(6))));
        uint256 sp = uint256(slot0) & ((1 << 160) - 1);
        // Dividing between the two multiplications keeps the product inside 256 bits; the precision lost is far
        // below a unit of USDG.
        // forge-lint: disable-next-line(divide-before-multiply)
        return (ethIn * sp / (1 << 96)) * sp / (1 << 96);
    }

    /// New USDG whose whole sale buys more ETH than the curve has left, sized from the chain: the launch's
    /// graduation gap (doubled by `graduationBuyEth`) at the pool's price.
    function crossingUsdg() internal view returns (uint256) {
        return usdgForEth(graduationBuyEth(token));
    }

    /// The buy-back is larger than what is left on the curve, so the buy crosses graduation. With a minimum of one
    /// the curve fills what it has and refunds the rest in ETH to the buy route, which passes it on to the vault,
    /// where it stays as ETH. The curve's own events give what it took and what it refunded; the two must add up
    /// to the sale's ETH, and the vault must hold exactly the refund, with nothing stranded in a route.
    function test_processUsdg_crossesGraduation() public {
        if (!forked) return;
        configure(0);
        setBurn(0, 10_000);
        vm.deal(MOTH_VAULT, 0);
        uint256 arrived = crossingUsdg();
        uint256 total = vault.usdgSettled() + arrived;
        fund(USDG, MOTH_VAULT, total);
        uint256 deadBefore = bal(token, DEAD);
        address curve = IPonsFactory(PONS_FACTORY).getLaunchedToken(token).curve;

        vm.recordLogs();
        vm.prank(VAULT_KEEPER);
        (uint256 usdgIn, uint256 usdgSpent, uint256 ethOut, uint256 tokenBurned) = vault.processUsdg(1, 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(usdgIn, arrived, "usdgIn");
        assertEq(usdgSpent, arrived, "all of it sold for ETH");
        assertTrue(ethOut > 0, "eth out");
        assertTrue(tokenBurned > 0, "token bought");
        assertEq(bal(token, DEAD) - deadBefore, tokenBurned, "burned equals dead balance change");

        uint256 curveTook;
        uint256 curveRefund;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != curve) continue;
            if (logs[i].topics[0] == CURVE_BUY_TOPIC) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), routes[1], "curve buyer is the buy route");
                (curveTook,,,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            }
            if (logs[i].topics[0] == CURVE_REFUND_TOPIC) curveRefund = abi.decode(logs[i].data, (uint256));
        }
        assertTrue(curveTook > 0, "curve took eth");
        assertTrue(curveRefund > 0, "curve refunded the rest");
        assertEq(curveTook + curveRefund, ethOut, "route offered the curve all the sale's eth");
        assertEq(MOTH_VAULT.balance, curveRefund, "the refund came back to the vault once");
        assertEq(uint256(IPonsFactory(PONS_FACTORY).getLaunchedToken(token).phase), 1, "curve crossed (Swept)");
        assertEq(bal(USDG, MOTH_VAULT), total - arrived, "vault usdg = before - sold");
        assertEq(vault.usdgSettled(), bal(USDG, MOTH_VAULT), "settled equals balance");
        assertEq(bal(token, MOTH_VAULT), 0, "vault holds no token");
        assertRoutesEmpty();
    }

    // ------------------------------------------------------------ refuel

    function refuelCase(bool graduated) internal {
        configure(graduated ? 2 : 0);
        vm.deal(MOTH_VAULT, 0);
        fund(USDG, MOTH_VAULT, 100e6);
        uint256 settledBefore = vault.usdgSettled();

        vm.prank(VAULT_KEEPER);
        uint256 ethOut = vault.refuel(REFUEL_CAP, 1);

        assertTrue(ethOut > 0, "eth out");
        assertEq(MOTH_VAULT.balance, ethOut, "eth arrived");
        assertEq(bal(USDG, MOTH_VAULT), 100e6 - REFUEL_CAP, "usdg sold");
        uint256 expectedSettled = settledBefore > REFUEL_CAP ? settledBefore - REFUEL_CAP : 0;
        assertEq(vault.usdgSettled(), expectedSettled, "settled lowered by the spend");
        assertRoutesEmpty();
    }

    function test_refuel_sellsUsdgForGas_onCurve() public {
        if (!forked) return;
        refuelCase(false);
    }

    function test_refuel_sellsUsdgForGas_inPool() public {
        if (!forked) return;
        refuelCase(true);
    }

    function test_refuel_tooHighMinimum_reverts() public {
        if (!forked) return;
        configure(0);
        vm.deal(MOTH_VAULT, 0);
        fund(USDG, MOTH_VAULT, 100e6);
        expectKeeperRevert(
            abi.encodeCall(vault.refuel, (REFUEL_CAP, type(uint256).max)),
            SellSwapperBase.InsufficientOutput.selector,
            type(uint256).max
        );
        assertEq(bal(USDG, MOTH_VAULT), 100e6, "usdg unchanged");
        assertEq(MOTH_VAULT.balance, 0, "eth unchanged");
        assertRoutesEmpty();
    }

    // ------------------------------------------------------------ gas top-up branches

    function setGas(uint256 floor, uint256 target) internal {
        MothVault.GasConfig memory gas = vault.gasConfig();
        gas.gasFloorWei = floor;
        gas.gasTargetWei = target;
        vm.prank(VAULT_OWNER);
        vault.setGasConfig(gas);
    }

    /// A sale smaller than the gas target: the whole sale stays as the reserve and no USDG is bought.
    function test_processToken_smallSale_allToReserve() public {
        if (!forked) return;
        configure(0);
        setBurn(0, 0);
        setGas(5 ether, 10 ether);
        vm.deal(MOTH_VAULT, 0);
        stockVault(0, 0.05 ether);
        uint256 usdgBefore = bal(USDG, MOTH_VAULT);
        uint256 settledBefore = vault.usdgSettled();

        vm.prank(VAULT_KEEPER);
        (,, uint256 sold, uint256 ethOut, uint256 ethToUsdg, uint256 usdgOut) = vault.processToken(1, 0);

        assertTrue(sold > 0 && ethOut > 0 && ethOut < 10 ether, "sale below target");
        assertEq(ethToUsdg, 0, "no eth swapped");
        assertEq(usdgOut, 0, "no usdg bought");
        assertEq(MOTH_VAULT.balance, ethOut, "whole sale kept as reserve");
        assertEq(bal(USDG, MOTH_VAULT), usdgBefore, "usdg unchanged");
        assertEq(vault.usdgSettled(), settledBefore, "settled unchanged");
        assertRoutesEmpty();
    }

    /// With no swap to make, a non-zero USDG minimum cannot be met and the step reverts.
    function test_processToken_smallSale_usdgMinimumReverts() public {
        if (!forked) return;
        configure(0);
        setBurn(0, 0);
        setGas(5 ether, 10 ether);
        vm.deal(MOTH_VAULT, 0);
        uint256 held = stockVault(0, 0.05 ether);
        vm.prank(VAULT_KEEPER);
        vm.expectRevert(abi.encodeWithSelector(MothVault.InsufficientOutput.selector, USDG, 0, 1));
        vault.processToken(1, 1);
        assertEq(bal(token, MOTH_VAULT), held, "vault token unchanged");
        assertEq(MOTH_VAULT.balance, 0, "eth unchanged");
    }

    /// The vault already holds some ETH under the target: only the sale's part above the target is swapped.
    function test_processToken_reserveUnderTarget_swapsOnlyAboveTarget() public {
        if (!forked) return;
        configure(0);
        setBurn(0, 0);
        vm.deal(MOTH_VAULT, 0.0004 ether);
        stockVault(0, 0.05 ether);
        vm.prank(VAULT_KEEPER);
        (,,, uint256 ethOut, uint256 ethToUsdg, uint256 usdgOut) = vault.processToken(1, 1);
        assertTrue(ethOut > GAS_TARGET, "sale larger than the gap");
        assertEq(ethToUsdg, ethOut - (GAS_TARGET - 0.0004 ether), "only the part above target");
        assertEq(MOTH_VAULT.balance, GAS_TARGET, "reserve exactly at target");
        assertTrue(usdgOut > 0, "usdg bought");
        assertRoutesEmpty();
    }

    /// The vault already holds more than the target: the whole sale goes to USDG and the old reserve is untouched.
    function test_processToken_reserveAboveTarget_swapsWholeSale() public {
        if (!forked) return;
        configure(0);
        setBurn(0, 0);
        vm.deal(MOTH_VAULT, 1 ether);
        stockVault(0, 0.05 ether);
        vm.prank(VAULT_KEEPER);
        (,,, uint256 ethOut, uint256 ethToUsdg, uint256 usdgOut) = vault.processToken(1, 1);
        assertEq(ethToUsdg, ethOut, "whole sale swapped");
        assertEq(MOTH_VAULT.balance, 1 ether, "old reserve untouched");
        assertTrue(usdgOut > 0, "usdg bought");
        assertRoutesEmpty();
    }

    // ------------------------------------------------------------ Swept window

    function expectUnavailable() internal {
        vm.expectRevert(abi.encodeWithSelector(PonsRoute.RouteUnavailable.selector, uint8(1)));
    }

    /// Between Swept and PoolCreated neither venue trades: the route reverts and the burn is rolled back.
    function test_processToken_swept_revertsAndMovesNothing() public {
        if (!forked) return;
        configure(1);
        setBurn(2000, 0);
        vm.deal(MOTH_VAULT, 0);
        uint256 held = stockVault(1, 0);
        uint256 usdgBefore = bal(USDG, MOTH_VAULT);
        uint256 settledBefore = vault.usdgSettled();
        uint256 deadBefore = bal(token, DEAD);

        vm.prank(VAULT_KEEPER);
        expectUnavailable();
        vault.processToken(0, 0);

        assertEq(bal(token, MOTH_VAULT), held, "vault token unchanged");
        assertEq(bal(token, DEAD), deadBefore, "burn rolled back");
        assertEq(bal(USDG, MOTH_VAULT), usdgBefore, "usdg unchanged");
        assertEq(MOTH_VAULT.balance, 0, "eth unchanged");
        assertEq(vault.usdgSettled(), settledBefore, "settled unchanged");
        assertRoutesEmpty();
    }

    function test_processUsdg_swept_revertsAndMovesNothing() public {
        if (!forked) return;
        configure(1);
        setBurn(0, 2000);
        vm.deal(MOTH_VAULT, 0);
        uint256 total = vault.usdgSettled() + 1_000e6;
        fund(USDG, MOTH_VAULT, total);
        uint256 settledBefore = vault.usdgSettled();
        uint256 deadBefore = bal(token, DEAD);

        vm.prank(VAULT_KEEPER);
        expectUnavailable();
        vault.processUsdg(1, 1);

        assertEq(bal(USDG, MOTH_VAULT), total, "usdg unchanged");
        assertEq(bal(token, MOTH_VAULT), 0, "token unchanged");
        assertEq(bal(token, DEAD), deadBefore, "dead unchanged");
        assertEq(MOTH_VAULT.balance, 0, "eth unchanged");
        assertEq(vault.usdgSettled(), settledBefore, "settled unchanged");
        assertRoutesEmpty();
    }

    /// After the crossing buy leaves the launch Swept, a further buy-back and a token sale both revert.
    function test_afterCrossingBuy_stepsRevertUntilPool() public {
        if (!forked) return;
        configure(0);
        setBurn(2000, 10_000);
        vm.deal(MOTH_VAULT, 0);
        fund(USDG, MOTH_VAULT, vault.usdgSettled() + crossingUsdg());
        vm.prank(VAULT_KEEPER);
        vault.processUsdg(1, 1);
        assertEq(uint256(IPonsFactory(PONS_FACTORY).getLaunchedToken(token).phase), 1, "Swept");

        // The crossing buy's refund stays in the vault as ETH, and the reverted step must not move it.
        uint256 ethBefore = MOTH_VAULT.balance;
        uint256 usdgBefore = bal(USDG, MOTH_VAULT);
        uint256 settledBefore = vault.usdgSettled();
        uint256 deadBefore = bal(token, DEAD);
        fund(USDG, MOTH_VAULT, usdgBefore + 500e6);
        vm.prank(VAULT_KEEPER);
        expectUnavailable();
        vault.processUsdg(1, 1);
        assertEq(bal(USDG, MOTH_VAULT), usdgBefore + 500e6, "usdg unchanged");
        assertEq(vault.usdgSettled(), settledBefore, "settled unchanged");
        assertEq(bal(token, DEAD), deadBefore, "dead unchanged");
        assertEq(MOTH_VAULT.balance, ethBefore, "eth unchanged");

        // Tokens for the sale step come from the graduation-style holder: the test contract buys none, so hand the
        // vault tokens the dead address does not hold by taking them from the launcher's creator side is not possible;
        // the sale step is covered by test_processToken_swept_revertsAndMovesNothing.
        assertRoutesEmpty();
    }

    // ------------------------------------------------------------ refuel guards

    /// Marks all the USDG the vault holds as seen, so `usdgSettled` equals the balance.
    function settleAll() internal {
        uint256 extra = 200e6;
        fund(USDG, MOTH_VAULT, bal(USDG, MOTH_VAULT) + extra);
        uint16 share = vault.usdgBurnBps();
        vm.prank(VAULT_OWNER);
        vault.setUsdgBurnBps(0);
        vm.prank(VAULT_KEEPER);
        vault.processUsdg(0, 0);
        vm.prank(VAULT_OWNER);
        vault.setUsdgBurnBps(share);
        assertEq(vault.usdgSettled(), bal(USDG, MOTH_VAULT), "all settled");
    }

    function test_refuel_overCap_reverts() public {
        if (!forked) return;
        configure(0);
        vm.deal(MOTH_VAULT, 0);
        fund(USDG, MOTH_VAULT, 100e6);
        vm.prank(VAULT_KEEPER);
        vm.expectRevert(abi.encodeWithSelector(MothVault.InvalidRefuelAmount.selector, REFUEL_CAP + 1, REFUEL_CAP));
        vault.refuel(REFUEL_CAP + 1, 1);
    }

    function test_refuel_atFloor_reverts() public {
        if (!forked) return;
        configure(0);
        vm.deal(MOTH_VAULT, GAS_FLOOR);
        fund(USDG, MOTH_VAULT, 100e6);
        vm.prank(VAULT_KEEPER);
        vm.expectRevert(abi.encodeWithSelector(MothVault.GasNotLow.selector, GAS_FLOOR, GAS_FLOOR));
        vault.refuel(10e6, 1);
    }

    function test_refuel_justUnderFloor_works() public {
        if (!forked) return;
        configure(0);
        settleAll();
        vm.deal(MOTH_VAULT, GAS_FLOOR - 1);
        uint256 usdgBefore = bal(USDG, MOTH_VAULT);
        uint256 settledBefore = vault.usdgSettled();
        vm.prank(VAULT_KEEPER);
        uint256 ethOut = vault.refuel(10e6, 1);
        assertTrue(ethOut > 0, "eth out");
        assertEq(MOTH_VAULT.balance, GAS_FLOOR - 1 + ethOut, "eth arrived");
        assertEq(usdgBefore - bal(USDG, MOTH_VAULT), 10e6, "usdg sold");
        assertEq(settledBefore - vault.usdgSettled(), 10e6, "settled dropped by exactly the spend");
        assertRoutesEmpty();
    }

    // ------------------------------------------------------------ keeper fuel and supplier pay

    function test_fuelKeeper_underNewConfig() public {
        if (!forked) return;
        configure(0);
        MothVault.GasConfig memory gas = vault.gasConfig();
        gas.keeperFloorWei = 0.002 ether;
        gas.keeperTargetWei = 0.005 ether;
        gas.keeperDailyCapWei = 0.01 ether;
        vm.prank(VAULT_OWNER);
        vault.setGasConfig(gas);
        vm.deal(VAULT_KEEPER, 0);
        vm.deal(MOTH_VAULT, 1 ether);
        uint256 left = vault.fuelDay() == block.timestamp / 1 days ? 0.01 ether - vault.fuelledToday() : 0.01 ether;
        uint256 expected = left < 0.005 ether ? left : 0.005 ether;
        assertTrue(expected > 0, "daily cap not used up on chain");

        uint256 amount = vault.fuelKeeper();
        assertEq(amount, expected, "amount");
        assertEq(VAULT_KEEPER.balance, expected, "keeper received");
        assertEq(MOTH_VAULT.balance, 1 ether - expected, "vault paid");
    }

    function test_paySupplier_underNewConfig() public {
        if (!forked) return;
        configure(0);
        settleAll();
        address wallet = address(0xFEED);
        vm.prank(VAULT_OWNER);
        vault.setSupplier(wallet, 100e6);
        uint256 vaultBefore = bal(USDG, MOTH_VAULT);
        uint256 settledBefore = vault.usdgSettled();
        vm.prank(VAULT_KEEPER);
        vault.paySupplier(10e6);
        assertEq(bal(USDG, wallet), 10e6, "supplier received");
        assertEq(vaultBefore - bal(USDG, MOTH_VAULT), 10e6, "vault paid");
        assertEq(settledBefore - vault.usdgSettled(), 10e6, "settled lowered");
    }

    receive() external payable {}
}

interface IPonsCurveBuy {
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256);
}

interface IERC20Transfer {
    function transfer(address to, uint256 amount) external returns (bool);
}
