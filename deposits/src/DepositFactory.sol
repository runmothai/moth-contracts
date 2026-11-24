// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {DepositForwarder} from "./DepositForwarder.sol";

/// @title DepositFactory
/// @notice Computes and, at sweep time, deploys each account's deposit forwarder as an ERC-1167 clone at
/// create2(this, salt, clone code), then flushes it to the treasury. Not upgradeable, no owner: the treasury
/// is fixed at deployment, so a sweep by anyone can only move funds to the treasury.
contract DepositFactory {
    address public immutable treasury;
    address public immutable implementation;

    event Swept(bytes32 indexed salt, address indexed forwarder, address indexed token, uint256 amount);
    /// @notice A flush that reverted (for example a paused token). The funds stay in the forwarder.
    event SweepFailed(bytes32 indexed salt, address indexed forwarder, address indexed token);

    error DeployFailed();

    constructor(address treasury_) {
        require(treasury_ != address(0), "treasury");
        treasury = treasury_;
        implementation = address(new DepositForwarder(treasury_));
    }

    /// @notice The deposit address for `salt` (keccak256 of the account id in the API), deployed or not.
    function computeAddress(bytes32 salt) public view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(_cloneCode()))))));
    }

    /// @notice Deploys the forwarder for `salt` if it is not deployed yet, and returns its address.
    function deploy(bytes32 salt) public returns (address forwarder) {
        forwarder = computeAddress(salt);
        if (forwarder.code.length > 0) return forwarder;
        bytes memory code = _cloneCode();
        address created;
        assembly ("memory-safe") {
            created := create2(0, add(code, 0x20), mload(code), salt)
        }
        if (created != forwarder) revert DeployFailed();
    }

    /// @notice Deploys any missing forwarders and flushes `token` from each to the treasury. A forwarder whose
    /// flush reverts is skipped with a SweepFailed event, so one paused or frozen balance never blocks the rest.
    function sweep(bytes32[] calldata salts, address token) external {
        for (uint256 i; i < salts.length; ++i) {
            address forwarder = deploy(salts[i]);
            try DepositForwarder(payable(forwarder)).flush(token) returns (uint256 amount) {
                emit Swept(salts[i], forwarder, token, amount);
            } catch {
                emit SweepFailed(salts[i], forwarder, token);
            }
        }
    }

    /// @dev The ERC-1167 minimal proxy creation code for `implementation`.
    function _cloneCode() internal view returns (bytes memory) {
        return abi.encodePacked(hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", implementation, hex"5af43d82803e903d91602b57fd5bf3");
    }
}
