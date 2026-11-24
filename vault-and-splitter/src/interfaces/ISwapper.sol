// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @notice One swap route, from ETH to one ERC-20. The splitter sends ETH and measures what arrives, so it
/// never trusts the return value. Every adapter must:
/// - spend at most `msg.value` and send any ETH it does not use back to `msg.sender`;
/// - send the output to `recipient` and revert if less than `minOut` would arrive;
/// - hold nothing between calls, and have no owner, no upgrade path and no other entry point that moves funds.
interface ISwapper {
    function swapEthFor(address tokenOut, uint256 minOut, address recipient) external payable returns (uint256 amountOut);
}
