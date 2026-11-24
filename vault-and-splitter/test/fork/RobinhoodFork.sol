// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test} from "../utils/Test.sol";
import {PoolKey} from "../../src/interfaces/IV4PoolManager.sol";

interface IERC20Like {
    function balanceOf(address who) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

/// The slice of the Pons V2 factory the tests call.
interface IPonsFactory {
    struct Socials {
        string twitter;
        string telegram;
        string discord;
        string website;
        string farcaster;
    }

    struct TokenParams {
        string name;
        string symbol;
        string logo;
        string description;
        Socials socials;
        address creatorFeeRecipient;
        uint16 creatorTaxBps;
        bool buybackEnabled;
        bytes32 expectedEconomics;
        bytes32 salt;
    }

    struct LaunchedToken {
        address token;
        address curve;
        address deployer;
        address creatorFeeRecipient;
        address pairToken;
        uint256 graduationThreshold;
        uint24 poolFee;
        int24 tickSpacing;
        uint16 creatorTaxBps;
        bool buybackEnabled;
        uint8 phase;
        uint256 sweptQuote;
        uint256 sweptTokens;
        uint256 sweptAt;
        bool exists;
    }

    function launchFee() external view returns (uint256);
    function previewLaunchEconomics(uint256 launchConfigId, address pairToken) external view returns (bytes32);
    function launchToken(TokenParams calldata params, uint256 launchConfigId, address pairToken)
        external
        payable
        returns (address token, address curve);
    function getLaunchedToken(address token) external view returns (LaunchedToken memory);
    function graduate(address token) external;
    function createGraduatedPool(address token) external returns (uint256 positionId);
}

interface IPonsCurve {
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256);
    function readyToGraduate() external view returns (bool);
    function realQuoteReserve() external view returns (uint256);
}

/// A fork of Robinhood Chain at a fixed block, with helpers that launch and graduate a Pons V2 test token paired
/// with native ETH (`launchTestToken`, `buyToGraduation`), and one that launches a token paired with USDG
/// (`launchUsdgTestToken`) for the tests that check a native route refuses it.
/// Without FORK_URL every helper test returns early (`forked` is false), so offline runs stay green.
abstract contract RobinhoodFork is Test {
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant PONS_FACTORY = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;
    address internal constant PONS_HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    address internal constant PONS_FEE_ESCROW = 0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e;
    address internal constant MOTH_VAULT = 0xC35254c7Fd114a553E8f83336e569F7a11B4D39a;
    address internal constant VAULT_OWNER = 0xc61E16d3A1973B0C03c9D095EAD9c759900f21B6;
    address internal constant VAULT_KEEPER = 0x1ceBCC9bb617f6582D69B88f6175A0C5d1D6a1fB;

    /// The native ETH / USDG pool (id 0x387bf619da4d3fb62bb276482693dba1b9b3520f573cabdfe033384a24125982), no hook.
    function ethUsdgPool() internal pure returns (PoolKey memory) {
        return PoolKey({currency0: address(0), currency1: USDG, fee: 500, tickSpacing: 10, hooks: address(0)});
    }

    uint256 internal constant DEFAULT_FORK_BLOCK = 120520095;
    /// The curve charges a decaying tax on buys in a launch's opening seconds; this moves past it.
    uint256 internal constant SNIPE_WINDOW = 1 hours;

    address internal launcher = address(0x1AC4E5);
    address internal buyer = address(0xB0B);

    bool internal forked;
    /// Gives each native test launch in one test its own salt.
    uint256 private launchCount;

    function setUp() public virtual {
        string memory url = vm.envOr("FORK_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url, vm.envOr("FORK_BLOCK", DEFAULT_FORK_BLOCK));
        forked = true;
    }

    /// Who receives the creator tax of the test launch. Tests that need it elsewhere override this.
    function creatorFeeRecipient() internal view virtual returns (address) {
        return address(this);
    }

    /// Sets an ERC-20 balance. USDG is an upgradeable proxy with an unknown layout, so the balance slot
    /// is found by recording which slots `balanceOf(to)` reads, then trying each until the balance reads back as the amount.
    function fund(address token, address to, uint256 amount) internal {
        vm.record();
        IERC20Like(token).balanceOf(to);
        (bytes32[] memory reads,) = vm.accesses(token);
        for (uint256 i = 0; i < reads.length; i++) {
            bytes32 previous = vm.load(token, reads[i]);
            vm.store(token, reads[i], bytes32(amount));
            // A slot that is not the balance (a proxy's implementation slot, say) can break the call, so it is not trusted.
            (bool ok, bytes memory ret) = token.staticcall(abi.encodeCall(IERC20Like.balanceOf, (to)));
            if (ok && ret.length == 32 && abi.decode(ret, (uint256)) == amount) return;
            vm.store(token, reads[i], previous);
        }
        revert("fund: balance slot not found");
    }

    /// Launches a token paired with native ETH on the real factory from a funded wallet.
    function launchTestToken() internal returns (address token, address curve) {
        IPonsFactory factory = IPonsFactory(PONS_FACTORY);
        IPonsFactory.TokenParams memory params = IPonsFactory.TokenParams({
            name: "Harness Token",
            symbol: "HARN",
            logo: "",
            description: "A token launched by the fork test harness.",
            socials: IPonsFactory.Socials("", "", "", "", ""),
            creatorFeeRecipient: creatorFeeRecipient(),
            creatorTaxBps: 300,
            buybackEnabled: false,
            expectedEconomics: factory.previewLaunchEconomics(0, address(0)),
            salt: keccak256(abi.encode("moth-fork-harness-eth", launchCount++))
        });
        uint256 fee = factory.launchFee();
        vm.deal(launcher, fee);
        vm.prank(launcher);
        (token, curve) = factory.launchToken{value: fee}(params, 0, address(0));
    }

    /// An ETH amount that completes a native launch's curve in one buy, read from the chain: twice what the curve's
    /// real reserve still lacks of the launch's graduation threshold. Pons can change the threshold for new launches,
    /// so it is never hard-coded. The curve's fees take a few percent of a buy, so twice the gap always crosses it,
    /// and the last buy is partial and refunds the rest.
    function graduationBuyEth(address token) internal view returns (uint256) {
        IPonsFactory.LaunchedToken memory launch = IPonsFactory(PONS_FACTORY).getLaunchedToken(token);
        require(launch.exists && launch.pairToken == address(0) && launch.phase == 0, "graduationBuyEth: not a native curve");
        return 2 * (launch.graduationThreshold - IPonsCurve(launch.curve).realQuoteReserve());
    }

    /// Buys on the curve with dealt ETH until the launch is Swept. The last buy is partial and refunds the rest.
    function buyToGraduation(address token) internal {
        IPonsFactory factory = IPonsFactory(PONS_FACTORY);
        address curve = factory.getLaunchedToken(token).curve;
        vm.warp(block.timestamp + SNIPE_WINDOW);
        uint256 amount = graduationBuyEth(token);
        vm.deal(buyer, amount);
        vm.prank(buyer);
        IPonsCurve(curve).buy{value: amount}(amount, 0, buyer);
        // The buy that makes the curve ready calls graduate itself; if that was swallowed, call it here.
        if (factory.getLaunchedToken(token).phase == 0) factory.graduate(token);
        require(factory.getLaunchedToken(token).phase == 1, "buyToGraduation: not Swept");
    }

    /// Launches a USDG-paired token on the real factory from a funded wallet. Launching needs no USDG; the tests use
    /// it only to show that a native route refuses a launch with another pair.
    function launchUsdgTestToken() internal returns (address token, address curve) {
        IPonsFactory factory = IPonsFactory(PONS_FACTORY);
        IPonsFactory.TokenParams memory params = IPonsFactory.TokenParams({
            name: "Harness Token",
            symbol: "HARN",
            logo: "",
            description: "A token launched by the fork test harness.",
            socials: IPonsFactory.Socials("", "", "", "", ""),
            creatorFeeRecipient: creatorFeeRecipient(),
            creatorTaxBps: 300,
            buybackEnabled: false,
            expectedEconomics: factory.previewLaunchEconomics(0, USDG),
            salt: keccak256("moth-fork-harness")
        });
        uint256 fee = factory.launchFee();
        vm.deal(launcher, fee);
        vm.prank(launcher);
        (token, curve) = factory.launchToken{value: fee}(params, 0, USDG);
    }

    /// Moves a Swept launch to PoolCreated.
    function createPool(address token) internal {
        IPonsFactory(PONS_FACTORY).createGraduatedPool(token);
    }
}
