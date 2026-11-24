// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @notice Where a launch is in its life, as the verified Pons V2 `ILaunchpadV2.sol` defines it. The curve
/// trades in `NotGraduated`, the v4 pool trades in `PoolCreated`, and nothing trades in between or after a rescue.
enum GraduationPhase {
    NotGraduated,
    Swept,
    PoolCreated,
    Rescued
}

/// @notice The slice of the Pons V2 launch factory a route reads, from its verified source on Sourcify for
/// Robinhood Chain (4663), factory 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e.
interface IPonsV2Factory {
    struct LaunchedToken {
        address token;
        address curve;
        address deployer;
        address creatorFeeRecipient;
        address pairToken;
        uint256 graduationThreshold;
        uint24 poolFee;
        int24 tickSpacing;
        uint16 creatorTaxBps;
        bool buybackEnabled;
        GraduationPhase phase;
        uint256 sweptQuote;
        uint256 sweptTokens;
        uint256 sweptAt;
        bool exists;
    }

    function getLaunchedToken(address token) external view returns (LaunchedToken memory);

    /// @dev Callable only by the launch's current creator fee recipient. Moves future creator fees to
    /// `newRecipient`, on the curve and in the graduated pool. Fees already credited in the escrow stay with the
    /// old recipient.
    function transferCreatorFeeRecipient(address token, address newRecipient) external;

    /// @dev The hook every graduated pool of this factory uses.
    function memeHook() external view returns (address);
}

/// @notice The slice of a Pons V2 bonding curve a route calls. For a launch paired with native ETH, `buy` takes the
/// quote as the call's value (which must equal `quoteIn`) and refunds the ETH it did not spend to the caller with a
/// plain call; `sell` pulls `tokensIn` from the caller and pays the ETH to `recipient` with a plain call.
interface IPonsV2Curve {
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256 tokensOut);
    function sell(uint256 tokensIn, uint256 minQuoteOut, address recipient) external returns (uint256 quoteOut);
    function getReserves() external view returns (uint256 quoteReserve, uint256 tokenReserve);

    /// @dev Moves the curve's pending fees into the fee escrow. Callable by Pons's fee sweep operator or by the
    /// curve's `deployer` (which the factory keeps equal to the creator fee recipient), and it reverts once the
    /// launch has graduated.
    function sweepFees(uint256 minBuybackTokensOut) external;
}

/// @notice The slice of the Pons V2 meme hook the splitter calls after graduation. `poolId` is the v4 pool id,
/// `keccak256(abi.encode(currency0, currency1, fee, tickSpacing, hooks))`.
interface IPonsV2Hook {
    /// @dev Callable by Pons's fee sweep operator or by the launch's creator fee recipient. It reverts with
    /// `InternalSwapRequiresOperator` while fees denominated in the launch token are pending, because converting
    /// them is an internal swap only the operator may run.
    function sweepPoolFees(bytes32 poolId, uint256 minConversionQuoteOut, uint256 minBuybackTokensOut) external;
}
