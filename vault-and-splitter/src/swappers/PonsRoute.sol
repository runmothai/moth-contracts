// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {V4ExactIn} from "./V4ExactIn.sol";
import {PoolKey} from "../interfaces/IV4PoolManager.sol";
import {IPonsV2Factory, IPonsV2Curve, GraduationPhase} from "../interfaces/IPonsV2.sol";

interface IERC20Route {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice Buys and sells a Pons V2 launch token paired with native ETH, on whichever venue the launch is on now:
/// the bonding curve before graduation, the graduated v4 pool after it. The route already holds the input (ETH
/// that came with the call, or token the caller pushed first), the output goes straight to the recipient and is
/// measured there, and any input that was not used goes back to the address the route is told to refund.
/// @dev Between `Swept` and `PoolCreated` neither the curve nor the pool trades, and a rescued launch has no
/// route either, so those phases revert with `RouteUnavailable` and nothing moves. The curve refunds the unspent
/// part of a partial last buy to its caller with a plain call, so a contract that inherits this route must have
/// a `receive()` function. Holds nothing between calls, unless the inheriting contract refunds itself.
abstract contract PonsRoute is V4ExactIn {
    IPonsV2Factory public immutable ponsFactory;

    error RouteUnavailable(uint8 phase);
    error WrongPair();
    error RouteInsufficientOutput(uint256 received, uint256 minOut);
    error ApproveFailed();
    error EthTransferFailed();

    constructor(address poolManager_, address ponsFactory_) V4ExactIn(poolManager_) {
        ponsFactory = IPonsV2Factory(ponsFactory_);
    }

    /// @dev Spends `ethIn` of the ETH held here on `token`. On the curve the minimum is also passed to the curve,
    /// which prices a partial last buy by its rate, and the measured amount is then checked as a quantity. ETH that
    /// was not spent goes to `refundTo`; when that is this contract, it stays here.
    function _ponsBuy(address token, uint256 ethIn, uint256 minTokenOut, address recipient, address refundTo)
        internal
        returns (uint256 tokenOut)
    {
        IPonsV2Factory.LaunchedToken memory launch = _launch(token);
        uint256 before = IERC20Route(token).balanceOf(recipient);
        // This already includes `ethIn`, which the caller sent or pushed before the call.
        uint256 ethBefore = address(this).balance;
        if (launch.phase == GraduationPhase.NotGraduated) {
            // The curve takes exactly `msg.value` and sends back what it did not spend, returned below.
            IPonsV2Curve(launch.curve).buy{value: ethIn}(ethIn, minTokenOut, recipient);
        } else {
            // ETH is always currency0, so a buy is zero for one.
            _swapExactIn(_poolKey(launch, token), true, ethIn, recipient);
        }
        tokenOut = IERC20Route(token).balanceOf(recipient) - before;
        if (tokenOut < minTokenOut) revert RouteInsufficientOutput(tokenOut, minTokenOut);
        _refund(address(0), ethBefore, ethIn, refundTo);
    }

    /// @dev Sells `tokenIn` of `token` held here for ETH. Token that was not sold goes to `refundTo`; when that is
    /// this contract, it stays here.
    function _ponsSell(address token, uint256 tokenIn, uint256 minEthOut, address recipient, address refundTo)
        internal
        returns (uint256 ethOut)
    {
        IPonsV2Factory.LaunchedToken memory launch = _launch(token);
        uint256 before = recipient.balance;
        uint256 tokenBefore = IERC20Route(token).balanceOf(address(this));
        if (launch.phase == GraduationPhase.NotGraduated) {
            _approve(token, launch.curve, tokenIn);
            IPonsV2Curve(launch.curve).sell(tokenIn, minEthOut, recipient);
            _approve(token, launch.curve, 0);
        } else {
            _swapExactIn(_poolKey(launch, token), false, tokenIn, recipient);
        }
        ethOut = recipient.balance - before;
        if (ethOut < minEthOut) revert RouteInsufficientOutput(ethOut, minEthOut);
        _refund(token, tokenBefore, tokenIn, refundTo);
    }

    /// @dev Returns the part of `amountIn` that was not spent, measured as what this contract holds now against
    /// what it held before the call minus `amountIn`. `currency` is the token, or the zero address for ETH. This
    /// covers the curve's refund of a partial last buy and a pool swap that stopped at its price limit
    /// (`_swapExactIn` pays only what the pool took). A contract that keeps the leftover for itself (the splitter,
    /// whose caller is its keeper) passes its own address and nothing is sent.
    function _refund(address currency, uint256 heldBefore, uint256 amountIn, address refundTo) private {
        if (refundTo == address(this)) return;
        uint256 expected = heldBefore - amountIn;
        if (currency == address(0)) {
            uint256 held = address(this).balance;
            if (held > expected) _sendEth(refundTo, held - expected);
        } else {
            uint256 held = IERC20Route(currency).balanceOf(address(this));
            if (held > expected) _transfer(currency, refundTo, held - expected);
        }
    }

    /// @dev Sends ETH with a plain call and reverts if the receiver refuses it.
    function _sendEth(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }

    /// @dev Reads the launch and checks the pair and the phase before anything moves. The factory answers a token
    /// it never launched with an empty record, whose pair is the zero address like a native launch, so `exists`
    /// is checked as well.
    function _launch(address token) private view returns (IPonsV2Factory.LaunchedToken memory launch) {
        launch = ponsFactory.getLaunchedToken(token);
        if (!launch.exists || launch.pairToken != address(0)) revert WrongPair();
        if (launch.phase != GraduationPhase.NotGraduated && launch.phase != GraduationPhase.PoolCreated) {
            revert RouteUnavailable(uint8(launch.phase));
        }
    }

    /// @dev The graduated pool: ETH (the zero address) sorts first, then the token, with the launch's fee and
    /// spacing and the factory's hook.
    function _poolKey(IPonsV2Factory.LaunchedToken memory launch, address token) private view returns (PoolKey memory) {
        return PoolKey({
            currency0: address(0),
            currency1: token,
            fee: launch.poolFee,
            tickSpacing: launch.tickSpacing,
            hooks: ponsFactory.memeHook()
        });
    }

    function _approve(address token, address spender, uint256 amount) private {
        (bool ok, bytes memory ret) = token.call(abi.encodeCall(IERC20Route.approve, (spender, amount)));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert ApproveFailed();
    }
}
