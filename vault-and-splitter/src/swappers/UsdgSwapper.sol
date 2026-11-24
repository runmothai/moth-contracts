// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {SwapperBase} from "./SwapperBase.sol";
import {V4ExactIn} from "./V4ExactIn.sol";
import {PoolKey} from "../interfaces/IV4PoolManager.sol";

/// @title UsdgSwapper
/// @notice ETH to USDG (Paxos, 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168, 6 decimals) on Robinhood Chain,
/// the route for the Holder Credit share. It swaps on one native ETH / USDG Uniswap v4 pool, and the pool pays
/// the USDG straight to the recipient.
/// @dev The pool is fixed at construction and must pair native ETH (`currency0`) with USDG. USDG is an
/// upgradeable token with a pause flag; if it is paused the swap reverts and nothing moves.
contract UsdgSwapper is SwapperBase, V4ExactIn {
    PoolKey public pool;

    error WrongPool();

    constructor(address usdg_, address poolManager_, PoolKey memory ethUsdgPool)
        SwapperBase(usdg_)
        V4ExactIn(poolManager_)
    {
        if (ethUsdgPool.currency0 != address(0) || ethUsdgPool.currency1 != usdg_) revert WrongPool();
        pool = ethUsdgPool;
    }

    /// @dev The ETH is held here already (`msg.value`), so the swap goes zero for one. `SwapperBase` checks the
    /// USDG at the recipient and returns any ETH the pool did not take.
    function _swap(uint256 ethIn, uint256, address recipient) internal override {
        _swapExactIn(pool, true, ethIn, recipient);
    }
}
