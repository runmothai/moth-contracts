// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

interface IERC20Balance {
    function balanceOf(address account) external view returns (uint256);
}

/// @title DepositForwarder
/// @notice One account's deposit address. It is deployed as an ERC-1167 clone of this contract, at a CREATE2
/// address the API computes before anything is deployed, and it can only send what it holds to the treasury.
/// It has no owner, no upgrade path and no other way out for funds.
contract DepositForwarder {
    /// @notice Where every flush goes. Clones read this from the implementation's code.
    address public immutable treasury;

    error TransferFailed();

    constructor(address treasury_) {
        treasury = treasury_;
    }

    /// @notice Sends this address's whole balance of `token` to the treasury. Anyone may call it.
    /// Handles tokens that return no value from transfer.
    function flush(address token) external returns (uint256 amount) {
        amount = IERC20Balance(token).balanceOf(address(this));
        if (amount == 0) return 0;
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(0xa9059cbb, treasury, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    /// @notice Sends any ETH sent here by mistake to the treasury.
    function flushNative() external returns (uint256 amount) {
        amount = address(this).balance;
        if (amount == 0) return 0;
        (bool ok,) = treasury.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    receive() external payable {}
}
