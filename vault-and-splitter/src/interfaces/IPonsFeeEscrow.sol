// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @notice Pons's Fee Escrow, reduced to what the splitter uses. The escrow credits each creator fee recipient in the
/// asset the launch trades against, so a launch paired with native ETH pays ETH: the curve and the hook credit it
/// with `credit{value: amount}(recipient)`, and the recipient pulls its whole balance with `claim()`, which pays the
/// caller with a plain call and returns the amount. Verified against the deployed escrow's source
/// (PonsV2FeeEscrow.sol, Robinhood Chain 4663). `claim()` reverts with `NoBalance` when nothing is owed.
interface IPonsFeeEscrow {
    function claim() external returns (uint256 amount);
    function balanceOf(address recipient) external view returns (uint256);
}
