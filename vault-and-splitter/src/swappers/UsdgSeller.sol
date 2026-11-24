// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {SellSwapperBase} from "./SellSwapperBase.sol";
import {V4ExactIn} from "./V4ExactIn.sol";
import {PoolKey} from "../interfaces/IV4PoolManager.sol";

/// @title UsdgSeller
/// @notice USDG (Paxos, 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168, 6 decimals) to ETH on Robinhood Chain,
/// the route the vault buys its gas reserve through. It swaps on one native ETH / USDG Uniswap v4 pool, and the
/// pool pays the ETH straight to the recipient.
/// @dev The pool is fixed at construction and must pair native ETH (`currency0`) with USDG. USDG is an
/// upgradeable token with a pause flag; if it is paused the swap reverts and nothing moves.
contract UsdgSeller is SellSwapperBase, V4ExactIn {
    PoolKey public pool;

    error WrongPool();

    constructor(address usdg_, address poolManager_, PoolKey memory ethUsdgPool)
        SellSwapperBase(usdg_)
        V4ExactIn(poolManager_)
    {
        if (ethUsdgPool.currency0 != address(0) || ethUsdgPool.currency1 != usdg_) revert WrongPool();
        pool = ethUsdgPool;
    }

    /// @dev USDG is `currency1`, so the swap goes one for zero. `SellSwapperBase` checks the ETH at the
    /// recipient and returns any USDG the pool did not take.
    function _swap(uint256 amountIn, uint256, address recipient) internal override {
        _swapExactIn(pool, false, amountIn, recipient);
    }
}
