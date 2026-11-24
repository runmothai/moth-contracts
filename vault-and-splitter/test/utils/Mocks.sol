// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ISwapper} from "../../src/interfaces/ISwapper.sol";
import {MothTaxSplitter} from "../../src/MothTaxSplitter.sol";
import {IPonsV2Factory, GraduationPhase} from "../../src/interfaces/IPonsV2.sol";

/// A minimal ERC-20 that anyone can mint, and that can be told to return nothing from transfer (like USDT).
contract MockERC20 {
    event Transfer(address indexed from, address indexed to, uint256 value);

    uint8 public immutable decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public returnsNothing;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function setReturnsNothing(bool r) external {
        returnsNothing = r;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        if (returnsNothing) assembly { return(0, 0) }
        return true;
    }
}

/// A minimal ERC-721 that anyone can mint. A safe transfer to a contract asks it to accept the NFT, as the
/// standard does, so one that does not accept it makes the transfer revert.
contract MockERC721 {
    mapping(uint256 => address) public ownerOf;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function transferFrom(address from, address to, uint256 id) public {
        require(ownerOf[id] == from && msg.sender == from, "not the owner");
        ownerOf[id] = to;
    }

    function safeTransferFrom(address from, address to, uint256 id) external {
        transferFrom(from, to, id);
        if (to.code.length != 0) {
            bytes4 ok = IERC721Receiver(to).onERC721Received(msg.sender, from, id, "");
            require(ok == IERC721Receiver.onERC721Received.selector, "not accepted");
        }
    }
}

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 id, bytes calldata data) external returns (bytes4);
}

/// Mints `rate` output units per whole ETH. It does not check minOut itself, so the splitter's own check
/// is what the tests exercise. It can short the output and refund part of the ETH.
contract MockSwapper is ISwapper {
    MockERC20 public immutable out;
    uint256 public immutable rate;
    uint256 public shortBy;
    uint256 public refundBps;
    uint256 public calls;
    uint256 public lastEthIn;
    uint256 public lastMinOut;
    address public lastRecipient;

    constructor(MockERC20 out_, uint256 rate_) {
        out = out_;
        rate = rate_;
    }

    function setShortBy(uint256 s) external {
        shortBy = s;
    }

    function setRefundBps(uint256 r) external {
        refundBps = r;
    }

    function quote(uint256 ethIn) public view returns (uint256) {
        return (ethIn * rate) / 1 ether;
    }

    function swapEthFor(address tokenOut, uint256 minOut, address recipient) external payable returns (uint256 amountOut) {
        require(tokenOut == address(out), "wrong token");
        calls++;
        lastEthIn = msg.value;
        lastMinOut = minOut;
        lastRecipient = recipient;
        uint256 q = quote(msg.value);
        amountOut = q > shortBy ? q - shortBy : 0;
        out.mint(recipient, amountOut);
        uint256 refund = (msg.value * refundBps) / 10_000;
        if (refund != 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            require(ok, "refund");
        }
    }
}

/// Holds ETH credited to fee recipients and pays it out on claim(), as the Pons Fee Escrow does for a native
/// launch: `credit(recipient)` takes the ETH with the call, and `claim()` pays the caller's whole balance with a
/// plain call. Like the real one it reverts when nothing is owed.
contract MockEscrow {
    mapping(address => uint256) public balanceOf;
    bool public reverts;
    uint256 public calls;

    function credit(address recipient) external payable {
        balanceOf[recipient] += msg.value;
    }

    function setReverts(bool r) external {
        reverts = r;
    }

    function claim() external returns (uint256 amount) {
        calls++;
        require(!reverts, "claim reverts");
        amount = balanceOf[msg.sender];
        require(amount != 0, "nothing to claim");
        balanceOf[msg.sender] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "claim payout");
    }
}

/// A Pons factory that answers every launch query with one configured launch. A launch is paired with native ETH
/// (a zero `pairToken`) unless `setPairToken` says otherwise.
contract MockPonsFactory {
    IPonsV2Factory.LaunchedToken private launch;
    address public memeHook;

    function setHook(address hook) external {
        memeHook = hook;
    }

    function setLaunch(address token, address curve, GraduationPhase phase, uint24 poolFee, int24 tickSpacing)
        external
    {
        launch.token = token;
        launch.curve = curve;
        launch.pairToken = address(0);
        launch.phase = phase;
        launch.poolFee = poolFee;
        launch.tickSpacing = tickSpacing;
        launch.creatorTaxBps = 300;
        launch.exists = true;
    }

    function setPairToken(address pairToken) external {
        launch.pairToken = pairToken;
    }

    function clearLaunch() external {
        delete launch;
    }

    uint256 public handOverCalls;
    address public lastHandOverToken;
    address public lastHandOverRecipient;
    address public lastHandOverCaller;

    function transferCreatorFeeRecipient(address token, address newRecipient) external {
        handOverCalls++;
        lastHandOverToken = token;
        lastHandOverRecipient = newRecipient;
        lastHandOverCaller = msg.sender;
    }

    function getLaunchedToken(address) external view returns (IPonsV2Factory.LaunchedToken memory) {
        return launch;
    }
}

/// A native bonding curve. A buy must bring exactly `quoteIn` as ETH; it spends only `fillBps` of it (to mimic the
/// last, partial buy), mints the token at `rate` per whole ETH and refunds the rest to the caller with a plain call,
/// as Pons does. A sale pays ETH from the curve's balance. When swept it credits an escrow from its own balance,
/// and it can call distribute again.
contract MockPonsCurve {
    MockERC20 public immutable token;
    uint256 public immutable rate;
    uint256 public fillBps = 10_000;
    uint256 public buyCalls;
    uint256 public sweepCalls;
    uint256 public lastSweepMin;
    bool public sweepReverts;
    MockEscrow public escrow;
    address public escrowRecipient;
    uint256 public sweepCredit;
    MothTaxSplitter public reenter;

    constructor(MockERC20 token_, uint256 rate_) {
        token = token_;
        rate = rate_;
    }

    receive() external payable {}

    function setFillBps(uint256 f) external {
        fillBps = f;
    }

    function setSweepReverts(bool r) external {
        sweepReverts = r;
    }

    function setSweepCredit(MockEscrow escrow_, address recipient, uint256 amount) external {
        escrow = escrow_;
        escrowRecipient = recipient;
        sweepCredit = amount;
    }

    function setReenter(MothTaxSplitter s) external {
        reenter = s;
    }

    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256 out) {
        require(msg.value == quoteIn, "value");
        buyCalls++;
        if (address(reenter) != address(0)) reenter.distribute(0, 0);
        uint256 spent = (quoteIn * fillBps) / 10_000;
        out = (spent * rate) / 1 ether;
        require(out >= minTokensOut, "slippage");
        token.mint(recipient, out);
        if (quoteIn > spent) {
            (bool ok,) = msg.sender.call{value: quoteIn - spent}("");
            require(ok, "refund");
        }
    }

    function sell(uint256 tokensIn, uint256 minQuoteOut, address recipient) external returns (uint256 out) {
        token.transferFrom(msg.sender, address(this), tokensIn);
        out = (tokensIn * 1 ether) / rate;
        require(out >= minQuoteOut, "slippage");
        (bool ok,) = recipient.call{value: out}("");
        require(ok, "payout");
    }

    function sweepFees(uint256 minBuybackTokensOut) external {
        sweepCalls++;
        lastSweepMin = minBuybackTokensOut;
        require(!sweepReverts, "sweep reverts");
        if (sweepCredit != 0) escrow.credit{value: sweepCredit}(escrowRecipient);
    }
}

/// A Pons hook that records the pool it was asked to sweep and can credit an escrow from its own balance or revert.
contract MockPonsHook {
    uint256 public sweepCalls;
    bytes32 public lastPoolId;
    uint256 public lastMinConversion;
    uint256 public lastMinBuyback;
    bool public sweepReverts;
    MockEscrow public escrow;
    address public escrowRecipient;
    uint256 public sweepCredit;

    function setSweepReverts(bool r) external {
        sweepReverts = r;
    }

    function setSweepCredit(MockEscrow escrow_, address recipient, uint256 amount) external {
        escrow = escrow_;
        escrowRecipient = recipient;
        sweepCredit = amount;
    }

    function sweepPoolFees(bytes32 poolId, uint256 minConversionQuoteOut, uint256 minBuybackTokensOut) external {
        sweepCalls++;
        lastPoolId = poolId;
        lastMinConversion = minConversionQuoteOut;
        lastMinBuyback = minBuybackTokensOut;
        require(!sweepReverts, "pool sweep reverts");
        if (sweepCredit != 0) escrow.credit{value: sweepCredit}(escrowRecipient);
    }
}

/// Tries distribute and sweep on the splitter it is pointed at, and records how each failed. The three re-entrant
/// mocks below call it from the moment the splitter hands them control.
abstract contract Reentrant {
    MothTaxSplitter public splitter;
    address public sweepToken;
    bytes public distributeError;
    bytes public sweepError;
    uint256 public attempts;

    function setTargets(MothTaxSplitter s, address erc20) external {
        splitter = s;
        sweepToken = erc20;
    }

    function _reenter() internal {
        attempts++;
        try splitter.distribute(0, 0) {} catch (bytes memory e) {
            distributeError = e;
        }
        try splitter.sweep(sweepToken) {} catch (bytes memory e) {
            sweepError = e;
        }
    }
}

/// An escrow whose claim() calls back into the splitter before it pays the ETH it holds for it.
contract ReentrantEscrow is Reentrant {
    function claim() external returns (uint256 amount) {
        _reenter();
        amount = address(this).balance;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "claim payout");
    }

    receive() external payable {}
}

/// A USDG route that calls back into the splitter, then pays USDG at `rate` per whole ETH.
contract ReentrantSwapper is ISwapper, Reentrant {
    MockERC20 public immutable out;
    uint256 public immutable rate;

    constructor(MockERC20 out_, uint256 rate_) {
        out = out_;
        rate = rate_;
    }

    function swapEthFor(address, uint256, address recipient) external payable returns (uint256 amountOut) {
        _reenter();
        amountOut = (msg.value * rate) / 1 ether;
        out.mint(recipient, amountOut);
    }
}

/// A dev wallet that calls back into the splitter while it is being paid.
contract ReentrantReceiver is Reentrant {
    uint256 public received;

    receive() external payable {
        received += msg.value;
        _reenter();
    }
}

/// Refuses ETH.
contract RejectingReceiver {
    receive() external payable {
        revert("no ETH");
    }
}
