// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// The cheatcodes these tests use, declared here so no library has to be downloaded.
interface Vm {
    struct Log {
        bytes32[] topics;
        bytes data;
        address emitter;
    }

    function prank(address sender) external;
    function startPrank(address sender) external;
    function stopPrank() external;
    function deal(address who, uint256 amount) external;
    function etch(address target, bytes calldata code) external;
    function warp(uint256 timestamp) external;
    function expectRevert() external;
    function expectRevert(bytes4 selector) external;
    function expectRevert(bytes calldata revertData) external;
    function expectEmit(bool topic1, bool topic2, bool topic3, bool data) external;
    function expectEmit(bool topic1, bool topic2, bool topic3, bool data, address emitter) external;
    function recordLogs() external;
    function getRecordedLogs() external returns (Log[] memory);
    function setEnv(string calldata name, string calldata value) external;
    function chainId(uint256 newChainId) external;
    function toString(uint256 value) external pure returns (string memory);
    function toString(address value) external pure returns (string memory);
    function createSelectFork(string calldata urlOrAlias, uint256 blockNumber) external returns (uint256 forkId);
    function envOr(string calldata name, string calldata defaultValue) external returns (string memory value);
    function envOr(string calldata name, uint256 defaultValue) external returns (uint256 value);
    function record() external;
    function accesses(address target) external returns (bytes32[] memory reads, bytes32[] memory writes);
    function load(address target, bytes32 slot) external view returns (bytes32 data);
    function store(address target, bytes32 slot, bytes32 value) external;
    function assume(bool condition) external pure;
}

abstract contract Test {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function assertEq(uint256 a, uint256 b, string memory why) internal pure {
        if (a != b) revert(string.concat(why, ": ", vm.toString(a), " != ", vm.toString(b)));
    }

    function assertEq(address a, address b, string memory why) internal pure {
        if (a != b) revert(string.concat(why, ": ", vm.toString(a), " != ", vm.toString(b)));
    }

    function assertEq(bytes32 a, bytes32 b, string memory why) internal pure {
        if (a != b) revert(why);
    }

    function assertTrue(bool ok, string memory why) internal pure {
        if (!ok) revert(why);
    }

    /// Maps any fuzzed value into [lo, hi].
    function bound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        require(lo <= hi, "bound: lo > hi");
        uint256 size = hi - lo;
        if (size == type(uint256).max) return x;
        return lo + (x % (size + 1));
    }
}
