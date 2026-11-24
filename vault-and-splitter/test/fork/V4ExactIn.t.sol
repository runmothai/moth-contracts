// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {RobinhoodFork, IERC20Like, IPonsFactory} from "./RobinhoodFork.sol";
import {V4ExactIn} from "../../src/swappers/V4ExactIn.sol";
import {PoolKey} from "../../src/interfaces/IV4PoolManager.sol";

/// A concrete holder that exposes the internal swap, funded directly by the tests.
contract V4ExactInHarness is V4ExactIn {
    constructor(address poolManager_) V4ExactIn(poolManager_) {}

    function swap(PoolKey memory key, bool zeroForOne, uint256 amountIn, address recipient)
        external
        returns (uint256, uint256)
    {
        return _swapExactIn(key, zeroForOne, amountIn, recipient);
    }

    receive() external payable {}
}

contract V4ExactInTest is RobinhoodFork {
    V4ExactInHarness internal harness;
    /// An address with no history is not guaranteed on a fork, so the tests compare against the balance before the swap.
    address internal recipient = address(0xCAFE);

    function setUp() public override {
        super.setUp();
        if (!forked) return;
        harness = new V4ExactInHarness(POOL_MANAGER);
    }

    function test_ethToUsdg_settlesNative() public {
        if (!forked) return;
        vm.deal(address(harness), 1 ether);
        uint256 before = IERC20Like(USDG).balanceOf(recipient);
        (uint256 out, uint256 used) = harness.swap(ethUsdgPool(), true, 1 ether, recipient);
        assertEq(used, 1 ether, "amount used");
        assertTrue(out > 0, "amount out");
        assertEq(IERC20Like(USDG).balanceOf(recipient) - before, out, "recipient usdg");
        assertEq(address(harness).balance, 0, "harness eth");
        assertEq(IERC20Like(USDG).balanceOf(address(harness)), 0, "harness usdg");
    }

    function test_usdgToEth_takesNative() public {
        if (!forked) return;
        fund(USDG, address(harness), 100e6);
        uint256 before = recipient.balance;
        (uint256 out, uint256 used) = harness.swap(ethUsdgPool(), false, 100e6, recipient);
        assertEq(used, 100e6, "amount used");
        assertTrue(out > 0, "amount out");
        assertEq(recipient.balance - before, out, "recipient eth");
        assertEq(IERC20Like(USDG).balanceOf(address(harness)), 0, "harness usdg");
        assertEq(address(harness).balance, 0, "harness eth");
    }

    function test_unlockCallback_rejectsOthers() public {
        if (!forked) return;
        vm.expectRevert(V4ExactIn.NotPoolManager.selector);
        harness.unlockCallback("");
    }

    /// The graduated Pons pool of a fresh native test token: ETH is always currency0, the token currency1.
    function graduatedNativePool() internal returns (address token, PoolKey memory key) {
        (token,) = launchTestToken();
        buyToGraduation(token);
        createPool(token);
        IPonsFactory.LaunchedToken memory t = IPonsFactory(PONS_FACTORY).getLaunchedToken(token);
        key = PoolKey({
            currency0: address(0), currency1: token, fee: t.poolFee, tickSpacing: t.tickSpacing, hooks: PONS_HOOK
        });
    }

    function test_ethToToken_settlesNative() public {
        if (!forked) return;
        (address token, PoolKey memory key) = graduatedNativePool();
        vm.deal(address(harness), 0.1 ether);
        uint256 before = IERC20Like(token).balanceOf(recipient);
        (uint256 out, uint256 used) = harness.swap(key, true, 0.1 ether, recipient);
        assertEq(used, 0.1 ether, "amount used");
        assertTrue(out > 0, "amount out");
        assertEq(IERC20Like(token).balanceOf(recipient) - before, out, "recipient token");
        assertEq(address(harness).balance, 0, "harness eth");
        assertEq(IERC20Like(token).balanceOf(address(harness)), 0, "harness token");
    }

    function test_tokenToEth_takesNative() public {
        if (!forked) return;
        (address token, PoolKey memory key) = graduatedNativePool();
        // Buy some token first, to the harness, then sell all of it back for ETH.
        vm.deal(address(harness), 0.1 ether);
        (uint256 held,) = harness.swap(key, true, 0.1 ether, address(harness));
        assertEq(IERC20Like(token).balanceOf(address(harness)), held, "harness token");
        uint256 before = recipient.balance;
        (uint256 out, uint256 used) = harness.swap(key, false, held, recipient);
        assertEq(used, held, "amount used");
        assertTrue(out > 0, "amount out");
        assertEq(recipient.balance - before, out, "recipient eth");
        assertEq(address(harness).balance, 0, "harness eth");
        assertEq(IERC20Like(token).balanceOf(address(harness)), 0, "harness token");
    }
}
