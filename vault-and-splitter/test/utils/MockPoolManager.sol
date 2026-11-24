// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IV4UnlockCallback, PoolKey, SwapParams} from "../../src/interfaces/IV4PoolManager.sol";

interface IBalanceOf {
    function balanceOf(address who) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

/// A stand-in for the Uniswap v4 PoolManager with the same unlock, swap, sync, settle and take flow. It fills
/// `fillBps` of the input (a swap that stopped at its price limit uses less than it was given) and pays
/// `used * rateNum / rateDen` of the other currency. Fund it with the output currency before a swap.
contract MockPoolManager {
    uint256 public fillBps = 10_000;
    uint256 public rateNum = 1;
    uint256 public rateDen = 1;
    address internal syncedCurrency;
    uint256 internal syncedBalance;

    receive() external payable {}

    function configure(uint256 fillBps_, uint256 rateNum_, uint256 rateDen_) external {
        fillBps = fillBps_;
        rateNum = rateNum_;
        rateDen = rateDen_;
    }

    function unlock(bytes calldata data) external returns (bytes memory) {
        return IV4UnlockCallback(msg.sender).unlockCallback(data);
    }

    function swap(PoolKey calldata, SwapParams calldata params, bytes calldata) external view returns (int256) {
        uint256 amountIn = uint256(-params.amountSpecified);
        uint256 used = amountIn * fillBps / 10_000;
        uint256 out = used * rateNum / rateDen;
        int256 inDelta = -int256(used);
        int256 outDelta = int256(out);
        (int256 amount0, int256 amount1) = params.zeroForOne ? (inDelta, outDelta) : (outDelta, inDelta);
        return (amount0 << 128) | int256(uint256(uint128(int128(amount1))));
    }

    function sync(address currency) external {
        syncedCurrency = currency;
        syncedBalance = IBalanceOf(currency).balanceOf(address(this));
    }

    function settle() external payable returns (uint256 paid) {
        if (msg.value != 0) return msg.value;
        paid = IBalanceOf(syncedCurrency).balanceOf(address(this)) - syncedBalance;
    }

    function take(address currency, address to, uint256 amount) external {
        if (currency == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            require(ok, "take: eth");
        } else {
            require(IBalanceOf(currency).transfer(to, amount), "take: token");
        }
    }
}
