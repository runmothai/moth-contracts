// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {DepositFactory} from "../src/DepositFactory.sol";
import {DepositForwarder} from "../src/DepositForwarder.sol";

/// The two cheatcodes these tests use, declared here so no library has to be downloaded.
interface Vm {
    function deal(address who, uint256 amount) external;
    function expectRevert() external;
}

/// A minimal ERC-20 that can be paused, and can be told to return nothing from transfer (like USDT).
contract MockToken {
    mapping(address => uint256) public balanceOf;
    bool public paused;
    bool public returnsNothing;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function setPaused(bool p) external {
        paused = p;
    }

    function setReturnsNothing(bool r) external {
        returnsNothing = r;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(!paused, "paused");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        if (returnsNothing) assembly { return(0, 0) }
        return true;
    }
}

contract DepositFactoryTest {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address constant TREASURY = address(0x7EA5);
    DepositFactory factory;
    MockToken token;

    function setUp() public {
        factory = new DepositFactory(TREASURY);
        token = new MockToken();
    }

    function eq(address a, address b, string memory why) internal pure {
        require(a == b, why);
    }

    function eq(uint256 a, uint256 b, string memory why) internal pure {
        require(a == b, why);
    }

    /// The same vector is asserted in cortex/test/deposits.test.ts, so the API and the contract agree.
    function test_computeAddressMatchesTheTypeScriptVector() public view {
        eq(address(factory), 0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f, "factory address");
        eq(factory.implementation(), 0x104fBc016F4bb334D775a19E8A6510109AC63E00, "implementation address");
        eq(factory.computeAddress(keccak256("acct_vector")), 0x4A639Ac3146d09037a176B3De40767C512E56a14, "forwarder address");
    }

    function test_depositBeforeDeploymentIsSweptToTheTreasury() public {
        bytes32 salt = keccak256("acct_1");
        address forwarder = factory.computeAddress(salt);
        require(forwarder.code.length == 0, "not deployed yet");
        token.mint(forwarder, 1_000_000);
        bytes32[] memory salts = new bytes32[](1);
        salts[0] = salt;
        factory.sweep(salts, address(token));
        require(forwarder.code.length > 0, "deployed at sweep");
        eq(token.balanceOf(TREASURY), 1_000_000, "treasury paid");
        eq(token.balanceOf(forwarder), 0, "forwarder empty");
        // A second sweep redeploys nothing and moves nothing.
        factory.sweep(salts, address(token));
        eq(token.balanceOf(TREASURY), 1_000_000, "no double move");
    }

    function test_flushByAnyoneOnlyPaysTheTreasury() public {
        address forwarder = factory.deploy(keccak256("acct_2"));
        eq(forwarder, factory.computeAddress(keccak256("acct_2")), "deploy returns the computed address");
        token.mint(forwarder, 5);
        DepositForwarder(payable(forwarder)).flush(address(token));
        eq(token.balanceOf(TREASURY), 5, "treasury paid");
        eq(DepositForwarder(payable(forwarder)).treasury(), TREASURY, "clone reads the treasury");
    }

    function test_tokensThatReturnNothingStillFlush() public {
        token.setReturnsNothing(true);
        address forwarder = factory.deploy(keccak256("acct_3"));
        token.mint(forwarder, 7);
        DepositForwarder(payable(forwarder)).flush(address(token));
        eq(token.balanceOf(TREASURY), 7, "treasury paid");
    }

    function test_aPausedTokenLeavesFundsInPlaceAndTheRestStillSweep() public {
        MockToken other = new MockToken();
        bytes32[] memory salts = new bytes32[](2);
        salts[0] = keccak256("acct_4");
        salts[1] = keccak256("acct_5");
        token.mint(factory.computeAddress(salts[0]), 3);
        token.setPaused(true);
        factory.sweep(salts, address(token));
        eq(token.balanceOf(factory.computeAddress(salts[0])), 3, "funds stay");
        other.mint(factory.computeAddress(salts[1]), 4);
        factory.sweep(salts, address(other));
        eq(other.balanceOf(TREASURY), 4, "other token swept");
    }

    function test_strayEthGoesToTheTreasury() public {
        address forwarder = factory.computeAddress(keccak256("acct_6"));
        vm.deal(forwarder, 1 ether);
        factory.deploy(keccak256("acct_6"));
        DepositForwarder(payable(forwarder)).flushNative();
        eq(TREASURY.balance, 1 ether, "eth to treasury");
    }

    function test_theFactoryRefusesAZeroTreasury() public {
        vm.expectRevert();
        new DepositFactory(address(0));
    }
}
