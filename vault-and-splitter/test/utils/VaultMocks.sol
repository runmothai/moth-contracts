// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ISellSwapper} from "../../src/interfaces/ISellSwapper.sol";
import {MothVault} from "../../src/MothVault.sol";
import {MockERC20} from "./Mocks.sol";

/// Pays `weiPerUnit` wei for every `unit` of the input token pushed to it, out of ETH the test deals it. It
/// does not check minEthOut itself, so the vault's own check is what the tests exercise. It can short the
/// output and hand part of the input back.
contract MockSellSwapper is ISellSwapper {
    MockERC20 public immutable input;
    uint256 public immutable weiPerUnit;
    uint256 public immutable unit;
    uint256 public shortBy;
    uint256 public keepBackBps;
    uint256 public calls;
    uint256 public lastAmountIn;
    uint256 public lastMinOut;
    address public lastRecipient;

    constructor(MockERC20 input_, uint256 weiPerUnit_, uint256 unit_) {
        input = input_;
        weiPerUnit = weiPerUnit_;
        unit = unit_;
    }

    function setShortBy(uint256 s) external {
        shortBy = s;
    }

    function setKeepBackBps(uint256 k) external {
        keepBackBps = k;
    }

    function quote(uint256 amountIn) public view returns (uint256) {
        return (amountIn * weiPerUnit) / unit;
    }

    function swapForEth(address tokenIn, uint256 amountIn, uint256 minEthOut, address recipient)
        external
        returns (uint256 ethOut)
    {
        require(tokenIn == address(input), "wrong token");
        require(input.balanceOf(address(this)) >= amountIn, "not pushed");
        calls++;
        lastAmountIn = amountIn;
        lastMinOut = minEthOut;
        lastRecipient = recipient;
        uint256 back = (amountIn * keepBackBps) / 10_000;
        uint256 used = amountIn - back;
        uint256 q = quote(used);
        ethOut = q > shortBy ? q - shortBy : 0;
        if (back != 0) _move(msg.sender, back);
        _move(address(0xB1AC4), input.balanceOf(address(this))); // the venue keeps what it bought
        (bool ok,) = recipient.call{value: ethOut}("");
        require(ok, "pay");
    }

    /// Low-level, so an input token that returns nothing from transfer works too.
    function _move(address to, uint256 amount) private {
        (bool ok,) = address(input).call(abi.encodeCall(MockERC20.transfer, (to, amount)));
        require(ok, "move");
    }

    receive() external payable {}
}

/// A sell route that is also the keeper and calls processToken again in the middle of a sale.
contract ReentrantSeller is ISellSwapper {
    MothVault public vault;

    function setVault(MothVault v) external {
        vault = v;
    }

    function swapForEth(address, uint256, uint256, address) external returns (uint256) {
        vault.processToken(0, 0);
        return 0;
    }
}

/// A keeper wallet that tries fuelKeeper again while it is being paid, and records how that failed.
contract ReentrantKeeper {
    MothVault public vault;
    bytes public fuelError;
    uint256 public received;

    function setVault(MothVault v) external {
        vault = v;
    }

    receive() external payable {
        received += msg.value;
        try vault.fuelKeeper() {}
        catch (bytes memory e) {
            fuelError = e;
        }
    }
}
