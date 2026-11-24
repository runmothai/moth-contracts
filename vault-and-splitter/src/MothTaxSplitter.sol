// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20Minimal} from "./interfaces/IERC20Minimal.sol";
import {IPonsFeeEscrow} from "./interfaces/IPonsFeeEscrow.sol";
import {ISwapper} from "./interfaces/ISwapper.sol";
import {IPonsV2Factory, IPonsV2Curve, IPonsV2Hook, GraduationPhase} from "./interfaces/IPonsV2.sol";
import {PonsRoute} from "./swappers/PonsRoute.sol";

/// @title MothTaxSplitter
/// @notice The creator fee recipient for the $MOTH launch on Pons. $MOTH is paired with native ETH, so Pons pays the
/// 3% creator tax on every swap, and the creator's share of its 1% base fee, in ETH through its fee escrow. Both
/// arrive here and split the same way, three ways:
/// - burn: bought as $MOTH on Pons (the bonding curve, then the graduated pool) and sent to the dead address,
///   which is fixed;
/// - credit: swapped to USDG through `usdgBuyer` and paid straight to the Holder Credit target, which funds the
///   platform credit the API pays holders each hour (as credit; withdrawing it as USDG, decided 2026-10-18, is not
///   built yet);
/// - dev: sent as ETH to the development wallet, which also takes the rounding dust.
/// @dev The owner (the wallet that creates the token on Pons, ideally a hardware wallet or a Safe) can change the
/// split, the dev wallet, the credit target, the USDG route, the keeper and the token, and every change emits an
/// event. Ownership moves in two steps. There is no upgrade path and no way to take ETH or $MOTH out except through
/// `distribute`. Any other ERC-20 that lands here, USDG included, can be swept to the dev wallet with `sweep`.
contract MothTaxSplitter is PonsRoute {
    /// @notice Where bought $MOTH goes. Fixed.
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant BPS = 10_000;
    /// @notice 0.25, 0.75 and 2 of the 3% creator tax, in basis points of each incoming amount.
    uint16 public constant DEFAULT_BURN_BPS = 833;
    uint16 public constant DEFAULT_CREDIT_BPS = 2_500;
    uint16 public constant DEFAULT_DEV_BPS = 6_667;

    /// @notice USDG, the currency the credit share is paid in. Fixed.
    address public immutable usdg;
    /// @notice Pons Fee Escrow, claimed from at the start of each distribute. Zero means no sweep and no claim.
    IPonsFeeEscrow public immutable feeEscrow;

    /// @notice $MOTH. Unset until the owner sets it, because the splitter must exist before the launch names it as
    /// fee recipient, and changeable at any time (see `setToken`).
    IERC20Minimal public token;
    /// @notice The route that turns the credit share into USDG at the credit target, in the vault's `ISwapper`
    /// shape. Zero until set; distribute then waits while the credit share is above zero.
    ISwapper public usdgBuyer;
    address public owner;
    address public pendingOwner;
    address public keeper;
    address public devWallet;
    address public creditTarget;
    uint16 public burnBps;
    uint16 public creditBps;
    uint16 public devBps;
    uint256 private _locked = 1;

    event Distributed(uint256 ethIn, uint256 burnedToken, uint256 usdgToCredit, uint256 ethToDev);
    event EscrowClaimed(uint256 ethClaimed);
    event EscrowClaimFailed(bytes reason);
    event SweepFailed(bytes reason);
    event SplitChanged(uint16 burnBps, uint16 creditBps, uint16 devBps);
    event DevWalletChanged(address indexed devWallet);
    event CreditTargetChanged(address indexed creditTarget);
    event UsdgBuyerChanged(address indexed usdgBuyer);
    event KeeperChanged(address indexed keeper);
    event TokenSet(address indexed token);
    event CreatorFeesHandedOver(address indexed newRecipient);
    event Swept(address indexed erc20, uint256 amount);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error Unauthorized();
    error Reentrancy();
    error ZeroAddress();
    error InvalidSplit();
    error InvalidToken();
    error TokenNotSet();
    error NothingToDistribute();
    error RouteNotSet();
    error InsufficientOutput(address tokenOut, uint256 received, uint256 minOut);
    error NotSweepable(address erc20);
    error NotAContract(address account);

    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    modifier nonReentrant() {
        _enter();
        _;
        _exit();
    }

    /// @param token_ $MOTH, or zero to set it with `setToken` after the launch.
    /// @param usdg_ USDG, the currency the credit share is bought in.
    /// @param poolManager_ The Uniswap v4 PoolManager, used when the burn buy runs on the graduated pool.
    /// @param ponsFactory_ The Pons V2 launch factory.
    /// @param feeEscrow_ Pons Fee Escrow, or zero to skip the sweep and the claim. Any other value must have code.
    /// @param usdgBuyer_ The ETH to USDG route for the credit share, or zero to set it with `setUsdgBuyer` later.
    constructor(
        address token_,
        address usdg_,
        address poolManager_,
        address ponsFactory_,
        address feeEscrow_,
        address keeper_,
        address devWallet_,
        address creditTarget_,
        address usdgBuyer_
    ) PonsRoute(poolManager_, ponsFactory_) {
        // PonsRoute has stored the pool manager and the factory; their zero checks come first.
        if (usdg_ == address(0) || poolManager_ == address(0) || ponsFactory_ == address(0)) revert ZeroAddress();
        if (devWallet_ == address(0) || creditTarget_ == address(0)) revert ZeroAddress();
        if (token_ == usdg_) revert InvalidToken();
        // All three are immutable, so a wrong address would be permanent.
        if (poolManager_.code.length == 0) revert NotAContract(poolManager_);
        if (ponsFactory_.code.length == 0) revert NotAContract(ponsFactory_);
        if (feeEscrow_ != address(0) && feeEscrow_.code.length == 0) revert NotAContract(feeEscrow_);
        usdg = usdg_;
        feeEscrow = IPonsFeeEscrow(feeEscrow_);
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
        if (token_ != address(0)) {
            token = IERC20Minimal(token_);
            emit TokenSet(token_);
        }
        keeper = keeper_;
        emit KeeperChanged(keeper_);
        devWallet = devWallet_;
        emit DevWalletChanged(devWallet_);
        creditTarget = creditTarget_;
        emit CreditTargetChanged(creditTarget_);
        usdgBuyer = ISwapper(usdgBuyer_);
        emit UsdgBuyerChanged(usdgBuyer_);
        _setSplit(DEFAULT_BURN_BPS, DEFAULT_CREDIT_BPS, DEFAULT_DEV_BPS);
    }

    /// @notice Accepts ETH from anyone. It does no work, so a 2,300-gas transfer can reach it. ETH is the currency of
    /// the split, and some of it arrives in the middle of `distribute`: the escrow's claim, the curve's refund of a
    /// partial buy and the USDG route's refund. Whatever is held when `distribute` runs is split.
    receive() external payable {}

    // ---------------------------------------------------------------- distribute

    /// @notice Sweeps the launch's pending fees into the Pons escrow and claims the ETH (when the escrow is set),
    /// splits the whole ETH balance by the split in force, buys and burns $MOTH with the burn share, swaps the credit
    /// share to USDG for the credit target and sends the rest to the dev wallet in ETH.
    /// @dev Keeper only, because the minimum outputs are the caller's choice and a public call could be sandwiched.
    /// A burn share of zero makes no buy and a credit share of zero makes no swap, and the matching minimum must then
    /// be zero. A credit share above zero needs `usdgBuyer` to be set. Any $MOTH already held here (sent by anyone)
    /// is burned with the bought amount, since it cannot leave any other way. The USDG credited is measured at the
    /// credit target, never taken from the route's answer. The dev share is fixed before any trade, so ETH that the
    /// curve refunds (the last buy before graduation is partial) or that the route hands back is not added to it: it
    /// stays here, and the next call splits it again by the full split together with whatever arrives then. Neither
    /// refund ever goes to the keeper. Between the curve selling out and the pool being created neither venue
    /// trades, so while the burn share is not zero `distribute` reverts with `RouteUnavailable` until the pool
    /// exists. Set the burn share to zero to pay the credit and dev shares during that window. A dev wallet that
    /// refuses ETH reverts the whole call, and the owner fixes it with `setDevWallet`.
    function distribute(uint256 minTokenOut, uint256 minUsdgOut)
        external
        nonReentrant
        returns (uint256 ethIn, uint256 burnedToken, uint256 usdgToCredit, uint256 ethToDev)
    {
        if (msg.sender != keeper) revert Unauthorized();
        IERC20Minimal token_ = token;
        if (address(token_) == address(0)) revert TokenNotSet();

        _claimFromEscrow(address(token_));
        ethIn = address(this).balance;
        if (ethIn == 0) revert NothingToDistribute();

        uint256 burnEth = (ethIn * burnBps) / BPS;
        uint256 creditEth = (ethIn * creditBps) / BPS;
        ethToDev = ethIn - burnEth - creditEth;

        burnedToken = _buyAndBurn(token_, burnEth, minTokenOut);
        usdgToCredit = _buyCredit(creditEth, minUsdgOut);
        if (ethToDev != 0) _sendEth(devWallet, ethToDev);
        emit Distributed(ethIn, burnedToken, usdgToCredit, ethToDev);
    }

    /// @notice Sends this contract's whole balance of an ERC-20 other than $MOTH to the dev wallet. USDG is not part
    /// of the flow (the route pays it straight to the credit target), so any that lands here can be swept like an
    /// unrelated token. $MOTH and ETH never can. Owner or keeper.
    function sweep(address erc20) external nonReentrant returns (uint256 amount) {
        if (msg.sender != owner && msg.sender != keeper) revert Unauthorized();
        if (address(token) == address(0)) revert TokenNotSet();
        if (erc20 == address(0) || erc20 == address(token)) revert NotSweepable(erc20);
        amount = IERC20Minimal(erc20).balanceOf(address(this));
        if (amount == 0) return 0;
        _transfer(erc20, devWallet, amount);
        emit Swept(erc20, amount);
    }

    // ---------------------------------------------------------------- owner

    /// @notice Sets the split in basis points. The three must sum to 10,000; any of them may be 0 or 10,000.
    /// The next distribute uses it.
    function setSplit(uint16 burnBps_, uint16 creditBps_, uint16 devBps_) external onlyOwner {
        _setSplit(burnBps_, creditBps_, devBps_);
    }

    function setDevWallet(address devWallet_) external onlyOwner {
        if (devWallet_ == address(0)) revert ZeroAddress();
        devWallet = devWallet_;
        emit DevWalletChanged(devWallet_);
    }

    function setCreditTarget(address creditTarget_) external onlyOwner {
        if (creditTarget_ == address(0)) revert ZeroAddress();
        creditTarget = creditTarget_;
        emit CreditTargetChanged(creditTarget_);
    }

    /// @notice Sets the ETH to USDG route for the credit share, in the vault's `ISwapper` shape. Zero is allowed and
    /// stops distribute while the credit share is above zero.
    function setUsdgBuyer(address usdgBuyer_) external onlyOwner {
        usdgBuyer = ISwapper(usdgBuyer_);
        emit UsdgBuyerChanged(usdgBuyer_);
    }

    /// @notice Zero is allowed and stops distribute until a keeper is set again.
    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
        emit KeeperChanged(keeper_);
    }

    /// @notice Sets, changes or unsets $MOTH at any time, for the launch, a relaunch or anything else (founder,
    /// 2026-10-26). Zero unsets it, and distribute then waits. A token left from before a change is no longer
    /// $MOTH here, so it can be swept to the dev wallet like any unrelated token.
    function setToken(address token_) external onlyOwner {
        if (token_ == usdg) revert InvalidToken();
        token = IERC20Minimal(token_);
        emit TokenSet(token_);
    }

    /// @notice Hands the launch's creator fee stream to a new recipient (another splitter, say) through the Pons
    /// factory, on the curve and in the graduated pool. Owner only. Without this the stream could never move once
    /// the launch names this contract. It acts on the current `token`, so after a `setToken` to something else the
    /// token must be set back first. Fees already credited to this contract in the escrow stay here and can
    /// still be claimed by a later `distribute`.
    function handOverCreatorFees(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        if (address(token) == address(0)) revert TokenNotSet();
        ponsFactory.transferCreatorFeeRecipient(address(token), newRecipient);
        emit CreatorFeesHandedOver(newRecipient);
    }

    /// @notice Starts a two-step transfer. The new owner must call `acceptOwnership`; zero cancels.
    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert Unauthorized();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    // ---------------------------------------------------------------- internal

    function _checkOwner() private view {
        if (msg.sender != owner) revert Unauthorized();
    }

    function _enter() private {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
    }

    function _exit() private {
        _locked = 1;
    }

    function _setSplit(uint16 burnBps_, uint16 creditBps_, uint16 devBps_) private {
        if (uint256(burnBps_) + creditBps_ + devBps_ != BPS) revert InvalidSplit();
        (burnBps, creditBps, devBps) = (burnBps_, creditBps_, devBps_);
        emit SplitChanged(burnBps_, creditBps_, devBps_);
    }

    /// @dev Buys $MOTH with `burnEth` (nothing when it is zero), then sends everything held of it to the dead
    /// address. The route keeps unspent ETH in this contract, never sending it to the keeper that called distribute.
    function _buyAndBurn(IERC20Minimal token_, uint256 burnEth, uint256 minTokenOut) private returns (uint256 burned) {
        uint256 bought =
            burnEth == 0 ? 0 : _ponsBuy(address(token_), burnEth, minTokenOut, address(this), address(this));
        if (bought < minTokenOut) revert InsufficientOutput(address(token_), bought, minTokenOut);
        burned = token_.balanceOf(address(this));
        if (burned != 0) _transfer(address(token_), DEAD, burned);
    }

    /// @dev Swaps `creditEth` (nothing when it is zero) to USDG through `usdgBuyer`, paid straight to the credit
    /// target, and returns what the target gained, measured there. The route checks the minimum too, but the
    /// splitter checks the measured amount itself. The route sends back any ETH it did not use, and it stays here.
    function _buyCredit(uint256 creditEth, uint256 minUsdgOut) private returns (uint256 credited) {
        if (creditEth != 0) {
            ISwapper buyer = usdgBuyer;
            if (address(buyer) == address(0)) revert RouteNotSet();
            address target = creditTarget;
            uint256 before = IERC20Minimal(usdg).balanceOf(target);
            buyer.swapEthFor{value: creditEth}(usdg, minUsdgOut, target);
            credited = IERC20Minimal(usdg).balanceOf(target) - before;
        }
        if (credited < minUsdgOut) revert InsufficientOutput(usdg, credited, minUsdgOut);
    }

    /// @dev Moves the launch's pending fees into the escrow, then claims the ETH. Pons credits the escrow only when
    /// someone sweeps: on the curve the curve's deployer (which Pons keeps equal to the fee recipient) may call
    /// `sweepFees`, and on the graduated pool the launch's creator may call the hook's `sweepPoolFees`. The escrow
    /// pays the claim to `receive()` with a plain call. A failed sweep or claim (nothing to sweep, nothing owed, a
    /// sweep that needs Pons's operator, or an escrow that reverts or answers in the wrong shape) is reported and
    /// does not revert `distribute`, so the ETH already here is distributed. The one exception is in the factory
    /// reads of `_sweepLaunchFees`, described there. The claim is a low-level call whose result is checked for that
    /// reason, and the amount reported is the balance change, not the answer.
    function _claimFromEscrow(address token_) private {
        if (address(feeEscrow) == address(0)) return;
        _sweepLaunchFees(token_);
        uint256 before = address(this).balance;
        (bool ok, bytes memory data) = address(feeEscrow).call(abi.encodeCall(IPonsFeeEscrow.claim, ()));
        // A failed call, an escrow with no code and a wrong-shaped or empty answer are all reported the same way.
        if (ok && data.length == 32) {
            emit EscrowClaimed(address(this).balance - before);
        } else {
            emit EscrowClaimFailed(data);
        }
    }

    /// @dev Between `Swept` and `PoolCreated` nothing can be swept (the curve is closed and the pool does not
    /// exist yet), and a rescued launch has no fees to sweep, so those phases do nothing. The factory answers an
    /// unknown token with an empty record rather than a revert, and that record's pair is the zero address like a
    /// native launch's, so the sweep runs only for a launch that exists, is paired with native ETH and has code at
    /// the contract to call. Every read is a low-level call whose result is checked, so a failed call, an address
    /// with no code and an answer of the wrong length are reported with `SweepFailed` and do not revert
    /// `distribute`. An answer of the right length is still decoded with `abi.decode`, which reverts on a value out
    /// of its type's range (a phase beyond the enum, a bool other than 0 or 1, an address with high bits set), and
    /// that revert does revert `distribute`. Pons's factory answers within range, so this needs a broken or replaced
    /// factory.
    function _sweepLaunchFees(address token_) private {
        (bool ok, bytes memory data) =
            address(ponsFactory).staticcall(abi.encodeCall(IPonsV2Factory.getLaunchedToken, (token_)));
        // The record is 15 static words. A call to an address with no code succeeds with no data.
        if (!ok || data.length != 15 * 32) {
            emit SweepFailed(data);
            return;
        }
        IPonsV2Factory.LaunchedToken memory launch = abi.decode(data, (IPonsV2Factory.LaunchedToken));
        if (!launch.exists || launch.pairToken != address(0)) return;
        if (launch.phase == GraduationPhase.NotGraduated) {
            if (launch.curve.code.length == 0) return;
            try IPonsV2Curve(launch.curve).sweepFees(0) {}
            catch (bytes memory reason) {
                emit SweepFailed(reason);
            }
        } else if (launch.phase == GraduationPhase.PoolCreated) {
            address hooks = _memeHook();
            if (hooks == address(0) || hooks.code.length == 0) return;
            bytes32 poolId = _poolId(token_, launch.poolFee, launch.tickSpacing, hooks);
            try IPonsV2Hook(hooks).sweepPoolFees(poolId, 0, 0) {}
            catch (bytes memory reason) {
                emit SweepFailed(reason);
            }
        }
    }

    /// @dev The factory's hook, or zero (reported) when the read fails or answers in the wrong shape.
    function _memeHook() private returns (address hooks) {
        (bool ok, bytes memory data) = address(ponsFactory).staticcall(abi.encodeCall(IPonsV2Factory.memeHook, ()));
        if (!ok || data.length != 32) {
            emit SweepFailed(data);
            return address(0);
        }
        hooks = abi.decode(data, (address));
    }

    /// @dev The v4 pool id of the graduated pool: the hash of its key, where ETH (the zero address) is always
    /// currency0 and the token currency1.
    function _poolId(address token_, uint24 fee, int24 tickSpacing, address hooks) private pure returns (bytes32) {
        return keccak256(abi.encode(address(0), token_, fee, tickSpacing, hooks));
    }
}
