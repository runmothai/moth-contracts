// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IV4PoolManager, IV4UnlockCallback, PoolKey, SwapParams} from "../interfaces/IV4PoolManager.sol";

/// @notice One exact-input swap on a Uniswap v4 pool, for routes to build on. The route holds the input
/// (native ETH in its balance, or an ERC-20 it already owns), and the output goes straight to the recipient.
/// @dev `address(0)` is native ETH. If the pool stops at the price limit before using all of the input, only
/// the part the pool took is paid, and the rest stays in this contract. `_swapExactIn` returns how much the
/// pool took, so the route can hand the difference back to its caller.
abstract contract V4ExactIn is IV4UnlockCallback {
    uint160 internal constant MIN_SQRT_PRICE = 4295128739;
    uint160 internal constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;

    IV4PoolManager public immutable poolManager;

    error NotPoolManager();
    error AmountTooLarge();
    error TransferFailed();

    constructor(address poolManager_) {
        poolManager = IV4PoolManager(poolManager_);
    }

    /// @dev Swaps `amountIn` of the input currency (`currency0` when `zeroForOne`, else `currency1`) and
    /// sends the output to `recipient`. Returns the output amount the pool paid out and the input amount the
    /// pool took, which is less than `amountIn` when the swap stops at the price limit.
    function _swapExactIn(PoolKey memory key, bool zeroForOne, uint256 amountIn, address recipient)
        internal
        returns (uint256 amountOut, uint256 amountUsed)
    {
        if (amountIn > uint256(uint128(type(int128).max))) revert AmountTooLarge();
        bytes memory result = poolManager.unlock(abi.encode(key, zeroForOne, amountIn, recipient));
        (amountOut, amountUsed) = abi.decode(result, (uint256, uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, bool zeroForOne, uint256 amountIn, address recipient) =
            abi.decode(data, (PoolKey, bool, uint256, address));

        int256 delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE + 1 : MAX_SQRT_PRICE - 1
            }),
            ""
        );

        // The delta packs amount0 in the high 128 bits and amount1 in the low 128 bits, both signed.
        int256 amount0 = int128(delta >> 128);
        int256 amount1 = int128(delta);
        (int256 inDelta, int256 outDelta) = zeroForOne ? (amount0, amount1) : (amount1, amount0);
        address currencyIn = zeroForOne ? key.currency0 : key.currency1;
        address currencyOut = zeroForOne ? key.currency1 : key.currency0;

        // The input is owed to the pool (negative); the output is owed to this contract (positive).
        uint256 owed = uint256(-inDelta);
        if (currencyIn == address(0)) {
            poolManager.settle{value: owed}();
        } else {
            poolManager.sync(currencyIn);
            _transfer(currencyIn, address(poolManager), owed);
            poolManager.settle();
        }

        uint256 amountOut = uint256(outDelta);
        poolManager.take(currencyOut, recipient, amountOut);
        return abi.encode(amountOut, owed);
    }

    /// @dev A low-level transfer, so tokens that return nothing are handled too.
    function _transfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }
}
