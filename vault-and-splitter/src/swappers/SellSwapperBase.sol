// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20Minimal} from "../interfaces/IERC20Minimal.sol";
import {ISellSwapper} from "../interfaces/ISellSwapper.sol";

/// @notice The checks every sell route shares: one fixed input token, the input already pushed here, the
/// minimum ETH measured at the recipient, and any unused input returned to the caller. A route only writes
/// `_swap`.
/// @dev Adapters have no owner and hold nothing between calls.
abstract contract SellSwapperBase is ISellSwapper {
    address public immutable tokenIn;

    error WrongToken();
    error InputNotReceived(uint256 held, uint256 amountIn);
    error InsufficientOutput(uint256 received, uint256 minOut);
    error RefundFailed();
    error NotImplemented();

    constructor(address tokenIn_) {
        tokenIn = tokenIn_;
    }

    function swapForEth(address tokenIn_, uint256 amountIn, uint256 minEthOut, address recipient)
        external
        returns (uint256 ethOut)
    {
        if (tokenIn_ != tokenIn) revert WrongToken();
        uint256 held = IERC20Minimal(tokenIn_).balanceOf(address(this));
        if (held < amountIn) revert InputNotReceived(held, amountIn);
        uint256 before = recipient.balance;
        _swap(amountIn, minEthOut, recipient);
        ethOut = recipient.balance - before;
        if (ethOut < minEthOut) revert InsufficientOutput(ethOut, minEthOut);
        uint256 left = IERC20Minimal(tokenIn_).balanceOf(address(this));
        if (left != 0) {
            (bool ok, bytes memory data) = tokenIn_.call(abi.encodeCall(IERC20Minimal.transfer, (msg.sender, left)));
            if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert RefundFailed();
        }
    }

    /// @dev Swap `amountIn` of `tokenIn` for ETH, sending the ETH straight to `recipient`, and pass
    /// `minEthOut` to the venue so it reverts on the venue's side too.
    function _swap(uint256 amountIn, uint256 minEthOut, address recipient) internal virtual;

    /// @dev Venues that pay out WETH unwrapped may route the ETH through here first.
    receive() external payable {}
}
