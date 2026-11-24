// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @notice One swap route from one ERC-20 to ETH, used by the vault to sell $MOTH and to buy gas with USDG.
/// The caller pushes `amountIn` of `tokenIn` to the adapter first, then calls `swapForEth`, so no approval is
/// ever given. The vault measures the ETH that arrives and never trusts the return value. Every adapter must:
/// - spend at most `amountIn` and send any `tokenIn` it does not use back to `msg.sender`;
/// - send the ETH to `recipient` and revert if less than `minEthOut` would arrive;
/// - hold nothing between calls, and have no owner, no upgrade path and no other entry point that moves funds.
interface ISellSwapper {
    function swapForEth(address tokenIn, uint256 amountIn, uint256 minEthOut, address recipient)
        external
        returns (uint256 ethOut);
}
