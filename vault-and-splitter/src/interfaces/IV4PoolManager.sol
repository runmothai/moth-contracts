// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @notice The part of the Uniswap v4 PoolManager a single exact-input swap needs, from its verified source on
/// Sourcify for Robinhood Chain (4663), PoolManager 0x8366a39cc670b4001a1121b8f6a443a643e40951, solc 0.8.26.
/// `Currency` is an address (zero for native ETH) and `BalanceDelta` packs amount0 in the high 128 bits and
/// amount1 in the low 128 bits, both signed: negative is owed to the pool, positive is owed to the caller.
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct SwapParams {
    bool zeroForOne;
    /// Negative for an exact input, positive for an exact output.
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IV4PoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey calldata key, SwapParams calldata params, bytes calldata hookData) external returns (int256 swapDelta);
    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
    function extsload(bytes32 slot) external view returns (bytes32);
}

interface IV4UnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}
