// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20Minimal} from "../interfaces/IERC20Minimal.sol";
import {ISwapper} from "../interfaces/ISwapper.sol";

/// @notice The checks every route shares: one fixed output token, the minimum measured at the recipient,
/// and any unused ETH returned to the caller. A route only writes `_swap`.
/// @dev Adapters have no owner and hold nothing between calls.
abstract contract SwapperBase is ISwapper {
    address public immutable tokenOut;

    error WrongToken();
    error InsufficientOutput(uint256 received, uint256 minOut);
    error RefundFailed();
    error NotImplemented();

    constructor(address tokenOut_) {
        tokenOut = tokenOut_;
    }

    function swapEthFor(address tokenOut_, uint256 minOut, address recipient) external payable returns (uint256 amountOut) {
        if (tokenOut_ != tokenOut) revert WrongToken();
        uint256 before = IERC20Minimal(tokenOut_).balanceOf(recipient);
        _swap(msg.value, minOut, recipient);
        amountOut = IERC20Minimal(tokenOut_).balanceOf(recipient) - before;
        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);
        uint256 left = address(this).balance;
        if (left != 0) {
            (bool ok,) = msg.sender.call{value: left}("");
            if (!ok) revert RefundFailed();
        }
    }

    /// @dev Swap `ethIn` wei for `tokenOut`, sending the output straight to `recipient`, and pass `minOut`
    /// to the venue so it reverts on the venue's side too.
    function _swap(uint256 ethIn, uint256 minOut, address recipient) internal virtual;

    /// @dev Venues may refund unused ETH.
    receive() external payable {}
}
