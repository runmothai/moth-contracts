// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {SwapperBase} from "./SwapperBase.sol";
import {PonsRoute} from "./PonsRoute.sol";

/// @title PonsTokenBuyer
/// @notice ETH to $MOTH, the route the vault buys $MOTH through. $MOTH is a Pons launch paired with native ETH, so
/// the buy is one Pons trade (the bonding curve before graduation, the graduated pool after it), and the token goes
/// straight to the recipient.
/// @dev The minimum is passed to the venue and checked again on the token at the recipient. A buy that completes the
/// curve's graduation is partial: the curve sends the unspent ETH back here, and `SwapperBase` returns it to the
/// caller, once, with any other ETH the venue did not take. Because the minimum is checked again on the tokens that
/// arrive, such a partial buy reverts when it delivers fewer tokens than the minimum asked for the whole amount.
/// The route holds nothing between calls.
contract PonsTokenBuyer is SwapperBase, PonsRoute {
    constructor(address token_, address poolManager_, address ponsFactory_)
        SwapperBase(token_)
        PonsRoute(poolManager_, ponsFactory_)
    {}

    /// @dev The ETH is held here already (`msg.value`). The route refunds itself, because the base already sends
    /// the caller all the ETH left here after this returns.
    function _swap(uint256 ethIn, uint256 minOut, address recipient) internal override {
        _ponsBuy(tokenOut, ethIn, minOut, recipient, address(this));
    }
}
