// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {SellSwapperBase} from "./SellSwapperBase.sol";
import {PonsRoute} from "./PonsRoute.sol";

/// @title PonsTokenSeller
/// @notice $MOTH to ETH, the route the vault sells paid $MOTH through. $MOTH is a Pons launch paired with native
/// ETH, so the sale is one Pons trade (the bonding curve before graduation, the graduated pool after it), and the
/// ETH goes straight to the recipient.
/// @dev The minimum is passed to the venue and checked again on the ETH at the recipient. Any $MOTH the venue did
/// not take stays here for the moment and `SellSwapperBase` returns it to the caller, once, so the route holds
/// nothing between calls.
contract PonsTokenSeller is SellSwapperBase, PonsRoute {
    constructor(address token_, address poolManager_, address ponsFactory_)
        SellSwapperBase(token_)
        PonsRoute(poolManager_, ponsFactory_)
    {}

    /// @dev The route refunds itself, because the base already sends the caller every $MOTH left here after this
    /// returns, so the refund happens in one place.
    function _swap(uint256 amountIn, uint256 minEthOut, address recipient) internal override {
        _ponsSell(tokenIn, amountIn, minEthOut, recipient, address(this));
    }
}
