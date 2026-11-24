// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @notice The two ERC-20 calls the splitter makes. Transfers go through a low-level call so tokens that
/// return nothing from transfer are handled too.
interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}
