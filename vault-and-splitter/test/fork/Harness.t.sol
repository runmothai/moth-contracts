// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {RobinhoodFork, IERC20Like, IPonsFactory} from "./RobinhoodFork.sol";

/// Checks the fork harness itself against the real Pons V2 factory. Each test returns early without FORK_URL.
contract HarnessTest is RobinhoodFork {
    function test_fund_setsUsdgBalance() public {
        if (!forked) return;
        address alice = address(0xA11CE);
        fund(USDG, alice, 1_000e6);
        assertEq(IERC20Like(USDG).balanceOf(alice), 1_000e6, "usdg balance");
    }

    function test_launch_isNotGraduatedAndPairedWithUsdg() public {
        if (!forked) return;
        (address token, address curve) = launchUsdgTestToken();
        IPonsFactory.LaunchedToken memory t = IPonsFactory(PONS_FACTORY).getLaunchedToken(token);
        assertEq(t.pairToken, USDG, "pair token");
        assertEq(t.curve, curve, "curve");
        assertEq(t.creatorFeeRecipient, creatorFeeRecipient(), "creator fee recipient");
        assertEq(uint256(t.phase), 0, "phase NotGraduated");
    }

    function test_launch_isNotGraduatedAndPairedWithEth() public {
        if (!forked) return;
        (address token, address curve) = launchTestToken();
        IPonsFactory.LaunchedToken memory t = IPonsFactory(PONS_FACTORY).getLaunchedToken(token);
        assertTrue(t.exists, "exists");
        assertEq(t.pairToken, address(0), "pair token is native ETH");
        assertEq(t.curve, curve, "curve");
        assertEq(t.creatorFeeRecipient, creatorFeeRecipient(), "creator fee recipient");
        assertEq(uint256(t.creatorTaxBps), 300, "creator tax");
        assertEq(uint256(t.phase), 0, "phase NotGraduated");
    }

    function test_ethGraduation_reachesPoolCreated() public {
        if (!forked) return;
        (address token,) = launchTestToken();
        buyToGraduation(token);
        assertEq(uint256(IPonsFactory(PONS_FACTORY).getLaunchedToken(token).phase), 1, "phase Swept");
        createPool(token);
        assertEq(uint256(IPonsFactory(PONS_FACTORY).getLaunchedToken(token).phase), 2, "phase PoolCreated");
    }
}
