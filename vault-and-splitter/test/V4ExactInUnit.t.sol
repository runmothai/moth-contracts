// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "./utils/Test.sol";
import {V4ExactIn} from "../src/swappers/V4ExactIn.sol";
import {PoolKey} from "../src/interfaces/IV4PoolManager.sol";

contract V4ExactInUnitHarness is V4ExactIn {
    constructor(address poolManager_) V4ExactIn(poolManager_) {}

    function swap(PoolKey memory key, bool zeroForOne, uint256 amountIn, address recipient)
        external
        returns (uint256, uint256)
    {
        return _swapExactIn(key, zeroForOne, amountIn, recipient);
    }
}

/// Offline checks of `_swapExactIn` that need no pool: an input too large to encode as a signed amount is refused first.
contract V4ExactInUnitTest is Test {
    V4ExactInUnitHarness internal harness;
    PoolKey internal key;

    function setUp() public {
        harness = new V4ExactInUnitHarness(address(0xBEEF));
        key = PoolKey({currency0: address(0), currency1: address(0x1234), fee: 500, tickSpacing: 10, hooks: address(0)});
    }

    function test_amountTooLarge_reverts() public {
        vm.expectRevert(V4ExactIn.AmountTooLarge.selector);
        harness.swap(key, true, uint256(type(int256).max) + 1, address(0xCAFE));
    }

    function test_amountTooLarge_revertsForMaxUint() public {
        vm.expectRevert(V4ExactIn.AmountTooLarge.selector);
        harness.swap(key, true, type(uint256).max, address(0xCAFE));
    }

    function test_amountTooLarge_revertsAboveInt128() public {
        vm.expectRevert(V4ExactIn.AmountTooLarge.selector);
        harness.swap(key, true, uint256(uint128(type(int128).max)) + 1, address(0xCAFE));
    }
}
