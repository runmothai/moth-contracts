// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20Minimal} from "./interfaces/IERC20Minimal.sol";
import {ISellSwapper} from "./interfaces/ISellSwapper.sol";
import {ISwapper} from "./interfaces/ISwapper.sol";

/// @title MothVault
/// @notice Holds what people pay Moth for credit. The deposit forwarders sweep USDG here, and $MOTH once the
/// token has launched. The API's keeper wallet runs it on a schedule, so nobody signs a batch:
/// - `processToken` burns `burnBps` of the $MOTH held (20% by default), sells the rest for ETH, keeps what
///   the gas reserve needs and swaps the remainder to USDG;
/// - `processUsdg` spends `usdgBurnBps` of the USDG that arrived since the last run (0% by default) on
///   buying $MOTH and burning it; the rest stays to pay for inference;
/// - `paySupplier` sends USDG to the supplier wallet the owner set, within a daily cap;
/// - `refuel` swaps a capped amount of USDG for ETH when the gas reserve falls under its floor;
/// - `fuelKeeper` sends the keeper ETH for gas when it runs low, within a daily cap. Anyone may call it,
///   since the ETH can only go to the keeper.
/// @dev The owner (a hardware wallet or a Safe) is sovereign. They can withdraw any asset at any time (ETH, any
/// ERC-20 and any ERC-721), even while the vault is paused, and set the token, both burn rates, the supplier
/// wallet and its cap, the gas levels, the keeper, the swap routes and the pause, and every change emits an event. The keeper can only start the steps above with minimum outputs
/// from a fresh quote; it cannot withdraw, change a setting or choose where anything goes. A contract cannot
/// start itself, so "automatic" means the keeper's scheduled call. Ownership moves in two steps. There is
/// no upgrade path.
contract MothVault {
    /// @notice Where burned $MOTH goes. Fixed.
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant BPS = 10_000;
    /// @notice 20% burned, 80% sold (founder, 2026-10-21).
    uint16 public constant DEFAULT_BURN_BPS = 2_000;
    /// @notice No USDG is spent on buy-back and burn until the owner sets a share (founder, 2026-10-21).
    uint16 public constant DEFAULT_USDG_BURN_BPS = 0;

    /// @notice The four swap routes. Zero turns a route off, and a step that needs it then reverts.
    struct Routes {
        address tokenSeller; // $MOTH to ETH
        address tokenBuyer; // ETH to $MOTH, for the USDG buy-back
        address usdgBuyer; // ETH to USDG
        address usdgSeller; // USDG to ETH
    }

    /// @notice The gas levels, all in wei except `refuelUsdgCap` (USDG units, 6 decimals).
    /// @param gasFloorWei `refuel` is allowed only while the vault holds less ETH than this (about $10).
    /// @param gasTargetWei `processToken` keeps the vault's ETH up to this before buying USDG (about $50).
    /// @param refuelUsdgCap The most USDG one `refuel` may sell, so a bad quote can cost little.
    /// @param keeperFloorWei `fuelKeeper` sends ETH only while the keeper holds less than this.
    /// @param keeperTargetWei `fuelKeeper` fills the keeper up to this.
    /// @param keeperDailyCapWei The most ETH `fuelKeeper` sends in one UTC day, whoever calls it.
    struct GasConfig {
        uint256 gasFloorWei;
        uint256 gasTargetWei;
        uint256 refuelUsdgCap;
        uint256 keeperFloorWei;
        uint256 keeperTargetWei;
        uint256 keeperDailyCapWei;
    }

    IERC20Minimal public immutable usdg;

    /// @notice $MOTH. Unset until the owner sets it, and changeable at any time (see `setToken`).
    IERC20Minimal public token;
    address public owner;
    address public pendingOwner;
    address public keeper;
    ISellSwapper public tokenSeller;
    ISwapper public tokenBuyer;
    ISwapper public usdgBuyer;
    ISellSwapper public usdgSeller;
    /// @notice The share of paid $MOTH that is burned; the rest is sold.
    uint16 public burnBps;
    /// @notice The share of newly arrived USDG spent on buying $MOTH and burning it; the rest stays.
    uint16 public usdgBurnBps;
    bool public paused;
    GasConfig private _gas;
    /// @notice The wallet that pays the inference supplier, and the most USDG `paySupplier` sends it in a UTC day.
    address public supplierWallet;
    uint256 public supplierDailyCapUsdg;
    /// @notice The USDG already seen by `processUsdg` (or produced by `processToken`), so each buy-back
    /// counts only what arrived since. Every USDG outflow lowers it.
    uint256 public usdgSettled;
    /// @notice The UTC day (`block.timestamp / 1 days`) the keeper was last fuelled, and how much it got that day.
    uint256 public fuelDay;
    uint256 public fuelledToday;
    /// @notice The same for supplier payouts.
    uint256 public payDay;
    uint256 public paidToday;
    uint256 private _locked = 1;

    event TokenProcessed(
        uint256 tokenIn, uint256 burned, uint256 sold, uint256 ethOut, uint256 ethToUsdg, uint256 usdgOut
    );
    event UsdgProcessed(uint256 usdgIn, uint256 usdgSpent, uint256 ethOut, uint256 tokenBurned);
    event SupplierPaid(address indexed wallet, uint256 amount);
    event Refuelled(uint256 usdgIn, uint256 ethOut);
    event KeeperFuelled(address indexed keeper, uint256 amount);
    event Withdrawn(address indexed asset, address indexed to, uint256 amount);
    event NftWithdrawn(address indexed nft, address indexed to, uint256 indexed id);
    event BurnBpsChanged(uint16 burnBps);
    event UsdgBurnBpsChanged(uint16 usdgBurnBps);
    event SupplierChanged(address indexed wallet, uint256 dailyCapUsdg);
    event GasConfigChanged(
        uint256 gasFloorWei,
        uint256 gasTargetWei,
        uint256 refuelUsdgCap,
        uint256 keeperFloorWei,
        uint256 keeperTargetWei,
        uint256 keeperDailyCapWei
    );
    event KeeperChanged(address indexed keeper);
    event SwappersChanged(
        address indexed tokenSeller, address indexed tokenBuyer, address indexed usdgBuyer, address usdgSeller
    );
    event TokenSet(address indexed token);
    event PausedChanged(bool paused);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error Unauthorized();
    error Reentrancy();
    error Paused();
    error ZeroAddress();
    error InvalidToken();
    error InvalidBps();
    error InvalidGasConfig();
    error TokenNotSet();
    error SwapperNotSet();
    error KeeperNotSet();
    error NothingToProcess();
    error GasNotLow(uint256 balance, uint256 floor);
    error InvalidRefuelAmount(uint256 usdgIn, uint256 cap);
    error KeeperNotLow(uint256 balance, uint256 floor);
    error NothingToFuel();
    error SupplierNotSet();
    error SupplierCapReached(uint256 amount, uint256 left);
    error InsufficientOutput(address tokenOut, uint256 received, uint256 minOut);
    error TransferFailed();

    modifier onlyOwner() {
        _checkOwner();
        _;
    }

    modifier onlyKeeper() {
        _checkKeeper();
        _;
    }

    modifier whenNotPaused() {
        _checkNotPaused();
        _;
    }

    modifier nonReentrant() {
        _enter();
        _;
        _exit();
    }

    /// @param token_ $MOTH, or zero to set it once with `setToken` after the launch.
    /// @param keeper_ The API's keeper wallet, or zero until it exists (keeper calls then revert).
    /// @param gas_ The gas levels; see `GasConfig`.
    /// @param routes_ The swap routes, any of them zero until it exists; see `Routes`.
    /// @dev The supplier wallet starts unset; the owner sets it with `setSupplier`.
    constructor(address usdg_, address token_, address keeper_, GasConfig memory gas_, Routes memory routes_) {
        if (usdg_ == address(0)) revert ZeroAddress();
        if (token_ == usdg_) revert InvalidToken();
        usdg = IERC20Minimal(usdg_);
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
        if (token_ != address(0)) {
            token = IERC20Minimal(token_);
            emit TokenSet(token_);
        }
        keeper = keeper_;
        emit KeeperChanged(keeper_);
        _setSwappers(routes_);
        _setGasConfig(gas_);
        burnBps = DEFAULT_BURN_BPS;
        emit BurnBpsChanged(DEFAULT_BURN_BPS);
        usdgBurnBps = DEFAULT_USDG_BURN_BPS;
        emit UsdgBurnBpsChanged(DEFAULT_USDG_BURN_BPS);
    }

    /// @notice Accepts ETH from the owner's gas funding, from a swap route or from anyone. It does no work, so
    /// a 2,300-gas transfer can reach it.
    receive() external payable {}

    // ---------------------------------------------------------------- keeper

    /// @notice Burns `burnBps` of all the $MOTH held, sells the rest for ETH, tops the gas reserve up to
    /// `gasTargetWei` from that sale and swaps the rest of the sale to USDG, which stays here.
    /// @dev Keeper only, because the minimums are the caller's choice and a public call could be sandwiched.
    /// When nothing is sold, or the whole sale goes to the reserve, no swap is made and the matching minimum
    /// must be zero. Only the sale's ETH is swapped to USDG, never the reserve already here. $MOTH a route
    /// hands back stays for the next run.
    function processToken(uint256 minEthOut, uint256 minUsdgOut)
        external
        onlyKeeper
        whenNotPaused
        nonReentrant
        returns (uint256 tokenIn, uint256 burned, uint256 sold, uint256 ethOut, uint256 ethToUsdg, uint256 usdgOut)
    {
        IERC20Minimal token_ = token;
        if (address(token_) == address(0)) revert TokenNotSet();
        tokenIn = token_.balanceOf(address(this));
        if (tokenIn == 0) revert NothingToProcess();

        burned = (tokenIn * burnBps) / BPS;
        uint256 toSell = tokenIn - burned;
        if (burned != 0) _transfer(token_, DEAD, burned);

        if (toSell != 0) {
            ethOut = _sellForEth(tokenSeller, token_, toSell, minEthOut);
            sold = toSell - token_.balanceOf(address(this));
        } else if (minEthOut != 0) {
            revert InsufficientOutput(address(0), 0, minEthOut);
        }

        ethToUsdg = _spareFromSale(ethOut);
        if (ethToUsdg != 0) usdgOut = _buyUsdg(ethToUsdg, minUsdgOut);
        if (usdgOut < minUsdgOut) revert InsufficientOutput(address(usdg), usdgOut, minUsdgOut);
        usdgSettled += usdgOut; // already paid for by $MOTH, so never bought back again

        emit TokenProcessed(tokenIn, burned, sold, ethOut, ethToUsdg, usdgOut);
    }

    /// @notice Spends `usdgBurnBps` of the USDG that arrived since the last run on buying $MOTH, and burns
    /// what it buys. The rest stays to pay for inference. With the share at zero it only marks the new USDG
    /// as seen.
    /// @dev Keeper only, for the same reason as `processToken`. The sale's ETH all goes to the buy-back, never
    /// to the gas reserve. When nothing is spent, both minimums must be zero.
    function processUsdg(uint256 minEthOut, uint256 minTokenOut)
        external
        onlyKeeper
        whenNotPaused
        nonReentrant
        returns (uint256 usdgIn, uint256 usdgSpent, uint256 ethOut, uint256 tokenBurned)
    {
        uint256 balance = usdg.balanceOf(address(this));
        uint256 settled = usdgSettled;
        if (balance <= settled) revert NothingToProcess();
        usdgIn = balance - settled;

        uint256 toSpend = (usdgIn * usdgBurnBps) / BPS;
        if (toSpend != 0) {
            IERC20Minimal token_ = token;
            if (address(token_) == address(0)) revert TokenNotSet();
            ethOut = _sellForEth(usdgSeller, usdg, toSpend, minEthOut);
            usdgSpent = balance - usdg.balanceOf(address(this));
            tokenBurned = _buyAndBurn(token_, ethOut, minTokenOut);
        } else if (minEthOut != 0) {
            revert InsufficientOutput(address(0), 0, minEthOut);
        } else if (minTokenOut != 0) {
            revert InsufficientOutput(address(token), 0, minTokenOut);
        }

        usdgSettled = usdg.balanceOf(address(this));
        emit UsdgProcessed(usdgIn, usdgSpent, ethOut, tokenBurned);
    }

    /// @notice Sends `amount` USDG to the supplier wallet the owner set, never more than
    /// `supplierDailyCapUsdg` in one UTC day. The API calls it when the supplier's prepaid balance runs low.
    function paySupplier(uint256 amount) external onlyKeeper whenNotPaused nonReentrant {
        address wallet = supplierWallet;
        if (wallet == address(0)) revert SupplierNotSet();
        uint256 day = block.timestamp / 1 days;
        if (day != payDay) {
            payDay = day;
            paidToday = 0;
        }
        uint256 left = supplierDailyCapUsdg - paidToday;
        if (amount == 0 || amount > left) revert SupplierCapReached(amount, left);
        paidToday += amount;
        _unsettle(amount);
        _transfer(usdg, wallet, amount);
        emit SupplierPaid(wallet, amount);
    }

    /// @notice Sells `usdgIn` USDG for ETH while the gas reserve is under `gasFloorWei`. `usdgIn` is capped by
    /// `refuelUsdgCap`, and the keeper picks it and `minEthOut` from a fresh quote.
    function refuel(uint256 usdgIn, uint256 minEthOut)
        external
        onlyKeeper
        whenNotPaused
        nonReentrant
        returns (uint256 ethOut)
    {
        uint256 balance = address(this).balance;
        uint256 floor = _gas.gasFloorWei;
        if (balance >= floor) revert GasNotLow(balance, floor);
        uint256 cap = _gas.refuelUsdgCap;
        if (usdgIn == 0 || usdgIn > cap) revert InvalidRefuelAmount(usdgIn, cap);
        uint256 usdgBefore = usdg.balanceOf(address(this));
        ethOut = _sellForEth(usdgSeller, usdg, usdgIn, minEthOut);
        uint256 spent = usdgBefore - usdg.balanceOf(address(this));
        _unsettle(spent);
        emit Refuelled(spent, ethOut);
    }

    /// @notice Sends the keeper ETH for gas while it holds less than `keeperFloorWei`, up to
    /// `keeperTargetWei`, never more than `keeperDailyCapWei` in one UTC day and never more than the vault
    /// holds. Anyone may call it, so a keeper that has run dry can be fuelled by the owner or a helper.
    function fuelKeeper() external whenNotPaused nonReentrant returns (uint256 amount) {
        address keeper_ = keeper;
        if (keeper_ == address(0)) revert KeeperNotSet();
        GasConfig memory g = _gas;
        uint256 held = keeper_.balance;
        if (held >= g.keeperFloorWei) revert KeeperNotLow(held, g.keeperFloorWei);

        uint256 day = block.timestamp / 1 days;
        if (day != fuelDay) {
            fuelDay = day;
            fuelledToday = 0;
        }
        amount = g.keeperTargetWei - held; // floor <= target, so this cannot underflow
        uint256 left = g.keeperDailyCapWei - fuelledToday;
        if (amount > left) amount = left;
        if (amount > address(this).balance) amount = address(this).balance;
        if (amount == 0) revert NothingToFuel();

        fuelledToday += amount;
        _sendEth(keeper_, amount);
        emit KeeperFuelled(keeper_, amount);
    }

    // ---------------------------------------------------------------- owner

    /// @notice Sends `amount` of `asset` to `to`. `asset` zero means ETH, and an `amount` of
    /// `type(uint256).max` sends the whole balance. Works while paused.
    function withdraw(address asset, address to, uint256 amount)
        external
        onlyOwner
        nonReentrant
        returns (uint256 sent)
    {
        if (to == address(0)) revert ZeroAddress();
        if (asset == address(0)) {
            sent = amount == type(uint256).max ? address(this).balance : amount;
            _sendEth(to, sent);
        } else {
            sent = amount == type(uint256).max ? IERC20Minimal(asset).balanceOf(address(this)) : amount;
            if (asset == address(usdg)) _unsettle(sent);
            _transfer(IERC20Minimal(asset), to, sent);
        }
        emit Withdrawn(asset, to, sent);
    }

    /// @notice Sends the ERC-721 NFT `id` of `nft` to `to`. Works while paused. The vault does not accept safe
    /// NFT transfers, so this is for one that arrived with a plain `transferFrom`.
    function withdrawNft(address nft, uint256 id, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        (bool ok,) = nft.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", address(this), to, id));
        if (!ok) revert TransferFailed();
        emit NftWithdrawn(nft, to, id);
    }

    /// @notice The share of each `processToken` run that is burned, in basis points, 0 to 10,000.
    function setBurnBps(uint16 burnBps_) external onlyOwner {
        if (burnBps_ > BPS) revert InvalidBps();
        burnBps = burnBps_;
        emit BurnBpsChanged(burnBps_);
    }

    /// @notice The share of newly arrived USDG spent on buy-back and burn, in basis points, 0 to 10,000.
    function setUsdgBurnBps(uint16 usdgBurnBps_) external onlyOwner {
        if (usdgBurnBps_ > BPS) revert InvalidBps();
        usdgBurnBps = usdgBurnBps_;
        emit UsdgBurnBpsChanged(usdgBurnBps_);
    }

    /// @notice The wallet `paySupplier` sends USDG to, and its daily cap. Zero stops supplier payouts.
    function setSupplier(address wallet, uint256 dailyCapUsdg) external onlyOwner {
        supplierWallet = wallet;
        supplierDailyCapUsdg = dailyCapUsdg;
        emit SupplierChanged(wallet, dailyCapUsdg);
    }

    function setGasConfig(GasConfig calldata gas_) external onlyOwner {
        _setGasConfig(gas_);
    }

    /// @notice Zero is allowed and stops every keeper call until a keeper is set again.
    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
        emit KeeperChanged(keeper_);
    }

    /// @notice Replaces the swap routes, for example from the Pons curve to the graduated pool, or to fix an
    /// adapter. Zero turns a route off.
    function setSwappers(Routes calldata routes_) external onlyOwner {
        _setSwappers(routes_);
    }

    /// @notice Sets, changes or unsets $MOTH at any time, for the launch, a relaunch or anything else (founder,
    /// 2026-10-26). Zero unsets it, and the $MOTH steps then wait. A token left from before a change stays here
    /// untouched until the owner takes it out with `withdraw`.
    function setToken(address token_) external onlyOwner {
        if (token_ == address(usdg)) revert InvalidToken();
        token = IERC20Minimal(token_);
        emit TokenSet(token_);
    }

    /// @notice Stops every keeper step and `fuelKeeper`. Withdrawals still work.
    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedChanged(paused_);
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

    // ---------------------------------------------------------------- views

    function gasConfig() external view returns (GasConfig memory) {
        return _gas;
    }

    // ---------------------------------------------------------------- internal

    function _checkOwner() private view {
        if (msg.sender != owner) revert Unauthorized();
    }

    function _checkKeeper() private view {
        if (msg.sender != keeper || msg.sender == address(0)) revert Unauthorized();
    }

    function _checkNotPaused() private view {
        if (paused) revert Paused();
    }

    function _enter() private {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
    }

    function _exit() private {
        _locked = 1;
    }

    function _setGasConfig(GasConfig memory g) private {
        if (g.gasFloorWei > g.gasTargetWei || g.keeperFloorWei > g.keeperTargetWei) revert InvalidGasConfig();
        _gas = g;
        emit GasConfigChanged(
            g.gasFloorWei, g.gasTargetWei, g.refuelUsdgCap, g.keeperFloorWei, g.keeperTargetWei, g.keeperDailyCapWei
        );
    }

    function _setSwappers(Routes memory r) private {
        tokenSeller = ISellSwapper(r.tokenSeller);
        tokenBuyer = ISwapper(r.tokenBuyer);
        usdgBuyer = ISwapper(r.usdgBuyer);
        usdgSeller = ISellSwapper(r.usdgSeller);
        emit SwappersChanged(r.tokenSeller, r.tokenBuyer, r.usdgBuyer, r.usdgSeller);
    }

    function _unsettle(uint256 amount) private {
        uint256 settled = usdgSettled;
        usdgSettled = settled > amount ? settled - amount : 0;
    }

    /// @dev Buys $MOTH with `ethIn` and burns exactly what was bought, so $MOTH paid in and waiting for
    /// `processToken` is never touched.
    function _buyAndBurn(IERC20Minimal token_, uint256 ethIn, uint256 minOut) private returns (uint256 bought) {
        ISwapper buyer = tokenBuyer;
        if (address(buyer) == address(0)) revert SwapperNotSet();
        uint256 before = token_.balanceOf(address(this));
        buyer.swapEthFor{value: ethIn}(address(token_), minOut, address(this));
        bought = token_.balanceOf(address(this)) - before;
        if (bought < minOut) revert InsufficientOutput(address(token_), bought, minOut);
        if (bought != 0) _transfer(token_, DEAD, bought);
    }

    /// @dev The part of a sale's ETH above the gas target. The reserve is filled first and never spent here.
    function _spareFromSale(uint256 ethOut) private view returns (uint256) {
        uint256 balance = address(this).balance;
        uint256 target = _gas.gasTargetWei;
        if (balance <= target) return 0;
        uint256 spare = balance - target;
        return ethOut < spare ? ethOut : spare;
    }

    /// @dev Measures the USDG that arrives here rather than trusting the route's return value.
    function _buyUsdg(uint256 ethIn, uint256 minOut) private returns (uint256 received) {
        ISwapper buyer = usdgBuyer;
        if (address(buyer) == address(0)) revert SwapperNotSet();
        uint256 before = usdg.balanceOf(address(this));
        buyer.swapEthFor{value: ethIn}(address(usdg), minOut, address(this));
        received = usdg.balanceOf(address(this)) - before;
    }

    /// @dev Pushes `amountIn` to the route, then measures the ETH that arrives here rather than trusting the
    /// route's return value.
    function _sellForEth(ISellSwapper seller, IERC20Minimal tokenIn, uint256 amountIn, uint256 minEthOut)
        private
        returns (uint256 ethOut)
    {
        if (address(seller) == address(0)) revert SwapperNotSet();
        _transfer(tokenIn, address(seller), amountIn);
        uint256 before = address(this).balance;
        seller.swapForEth(address(tokenIn), amountIn, minEthOut, address(this));
        ethOut = address(this).balance - before;
        if (ethOut < minEthOut) revert InsufficientOutput(address(0), ethOut, minEthOut);
    }

    function _transfer(IERC20Minimal erc20, address to, uint256 amount) private {
        (bool ok, bytes memory data) = address(erc20).call(abi.encodeCall(IERC20Minimal.transfer, (to, amount)));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _sendEth(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
