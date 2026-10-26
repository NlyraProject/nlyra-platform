// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import { TestHelperOz5 } from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";
import { EndpointV2Mock } from "@layerzerolabs/test-devtools-evm-foundry/contracts/mocks/EndpointV2Mock.sol";
import { PacketV1Codec } from "@layerzerolabs/lz-evm-protocol-v2/contracts/messagelib/libs/PacketV1Codec.sol";
import { Origin } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import { SendParam, MessagingFee, OFTReceipt } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { OAppReceiver } from "@layerzerolabs/oapp-evm/contracts/oapp/OAppReceiver.sol";
import { EnforcedOptionParam } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppOptionsType3.sol";
import { RateLimiter } from "@layerzerolabs/oapp-evm/contracts/oapp/utils/RateLimiter.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import { NlyraOFTAdapter } from "../src/NlyraOFTAdapter.sol";
import { NlyraOFT } from "../src/NlyraOFT.sol";
import { NlyraBridgePlan as P } from "../script/NlyraBridgePlan.sol";

/// Stand-in for the existing NLYRA ERC-20 (plain ERC-20, 18 decimals, 1,000,000,000 supply, no owner).
contract NlyraMock is ERC20 {
    constructor(address holder) ERC20("Neron Lyra", "NLYRA") {
        _mint(holder, 1_000_000_000 ether);
    }
}

contract NlyraBridgeTest is TestHelperOz5 {
    using PacketV1Codec for bytes;

    uint32 internal constant RH = 1; // mock eid standing in for Robinhood Chain
    uint32 internal constant ARB = 2; // mock eid standing in for ARB

    address internal owner = makeAddr("treasury");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    NlyraMock internal token;
    NlyraOFTAdapter internal adapter;
    NlyraOFT internal oft;

    function setUp() public virtual override {
        super.setUp();
        setUpEndpoints(2, LibraryType.UltraLightNode);

        token = new NlyraMock(alice);
        adapter = new NlyraOFTAdapter(address(token), endpoints[RH], owner);
        oft = new NlyraOFT(endpoints[ARB], owner);

        address[] memory oapps = new address[](2);
        oapps[0] = address(adapter);
        oapps[1] = address(oft);
        vm.startPrank(owner);
        wireOApps(oapps);
        // same calldata as the production plan, only the eid differs
        _ownerCall(address(adapter), P.setEnforcedOptions(ARB));
        _ownerCall(address(oft), P.setEnforcedOptions(RH));
        _ownerCall(address(adapter), P.setRateLimits(ARB));
        _ownerCall(address(oft), P.setRateLimits(RH));
        vm.stopPrank();

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    // ---------------- helpers ----------------

    function _ownerCall(address to, bytes memory data) internal {
        (bool ok, bytes memory ret) = to.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    function _param(uint32 dstEid, address to, uint256 amount) internal pure returns (SendParam memory) {
        return SendParam(dstEid, bytes32(uint256(uint160(to))), amount, amount, "", "", "");
    }

    function _sendFromRH(address from, address to, uint256 amount) internal returns (OFTReceipt memory r) {
        SendParam memory sp = _param(ARB, to, amount);
        sp.minAmountLD = (amount / 1e12) * 1e12;
        MessagingFee memory fee = adapter.quoteSend(sp, false);
        vm.startPrank(from);
        token.approve(address(adapter), amount);
        (, r) = adapter.send{ value: fee.nativeFee }(sp, fee, from);
        vm.stopPrank();
        verifyPackets(ARB, addressToBytes32(address(oft)));
    }

    function _sendFromARB(address from, address to, uint256 amount) internal returns (OFTReceipt memory r) {
        SendParam memory sp = _param(RH, to, amount);
        sp.minAmountLD = (amount / 1e12) * 1e12;
        MessagingFee memory fee = oft.quoteSend(sp, false);
        vm.prank(from);
        (, r) = oft.send{ value: fee.nativeFee }(sp, fee, from);
        verifyPackets(RH, addressToBytes32(address(adapter)));
    }

    function _assertInvariant() internal view {
        assertEq(token.balanceOf(address(adapter)), oft.totalSupply(), "locked on RH != supply on ARB");
    }

    // ---------------- deployment facts ----------------

    function test_constructorState() public view {
        assertEq(adapter.owner(), owner);
        assertEq(oft.owner(), owner);
        assertEq(EndpointV2Mock(endpoints[RH]).delegates(address(adapter)), owner);
        assertEq(EndpointV2Mock(endpoints[ARB]).delegates(address(oft)), owner);
        assertEq(adapter.token(), address(token));
        assertEq(oft.token(), address(oft));
        assertTrue(adapter.approvalRequired());
        assertFalse(oft.approvalRequired());
        assertEq(oft.name(), "NLYRA");
        assertEq(oft.symbol(), "NLYRA");
        assertEq(oft.decimals(), 18);
        assertEq(adapter.sharedDecimals(), 6);
        assertEq(oft.sharedDecimals(), 6);
        assertEq(adapter.decimalConversionRate(), 1e12);
        assertEq(oft.totalSupply(), 0);
        assertEq(adapter.enforcedOptions(ARB, 1), P.enforcedSendOptions());
        (, uint256 can) = adapter.getAmountCanBeSent(ARB);
        assertEq(can, 20_000_000 ether);
    }

    // ---------------- round trip + invariant ----------------

    function test_roundTrip_RH_ARB_RH() public {
        uint256 amount = 1_000 ether;
        uint256 a0 = token.balanceOf(alice);

        OFTReceipt memory r1 = _sendFromRH(alice, bob, amount);
        assertEq(r1.amountSentLD, amount);
        assertEq(r1.amountReceivedLD, amount);
        assertEq(token.balanceOf(alice), a0 - amount);
        assertEq(token.balanceOf(address(adapter)), amount);
        assertEq(oft.balanceOf(bob), amount);
        assertEq(oft.totalSupply(), amount);
        _assertInvariant();

        _sendFromARB(bob, alice, amount);
        assertEq(oft.balanceOf(bob), 0);
        assertEq(oft.totalSupply(), 0);
        assertEq(token.balanceOf(address(adapter)), 0);
        assertEq(token.balanceOf(alice), a0);
        _assertInvariant();
    }

    function testFuzz_supplyInvariant(uint96 out1, uint96 out2, uint96 back) public {
        uint256 o1 = bound(uint256(out1), 1e12, 5_000_000 ether);
        uint256 o2 = bound(uint256(out2), 1e12, 5_000_000 ether);
        _sendFromRH(alice, bob, o1);
        _assertInvariant();
        _sendFromRH(alice, alice, o2);
        _assertInvariant();
        uint256 b = bound(uint256(back), 1e12, oft.balanceOf(bob));
        _sendFromARB(bob, bob, b);
        _assertInvariant();
        // total NLYRA on RH is conserved: holders + adapter == 1B
        assertEq(token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(address(adapter)), 1_000_000_000 ether);
    }

    // ---------------- rate limit ----------------

    function test_rateLimit_hitAndReset() public {
        _sendFromRH(alice, bob, 20_000_000 ether); // exactly the cap
        (uint256 inFlight, uint256 can) = adapter.getAmountCanBeSent(ARB);
        assertEq(inFlight, 20_000_000 ether);
        assertEq(can, 0);

        SendParam memory sp = _param(ARB, bob, 1 ether);
        MessagingFee memory fee = adapter.quoteSend(sp, false);
        vm.startPrank(alice);
        token.approve(address(adapter), 1 ether);
        vm.expectRevert(RateLimiter.RateLimitExceeded.selector);
        adapter.send{ value: fee.nativeFee }(sp, fee, alice);
        vm.stopPrank();

        // linear decay: after 12 h half the window is free again
        vm.warp(block.timestamp + 43_200);
        (, can) = adapter.getAmountCanBeSent(ARB);
        assertEq(can, 10_000_000 ether);
        _sendFromRH(alice, bob, 10_000_000 ether);
        (, can) = adapter.getAmountCanBeSent(ARB);
        assertEq(can, 0);

        // after a full window everything is free again
        vm.warp(block.timestamp + 86_400);
        (inFlight, can) = adapter.getAmountCanBeSent(ARB);
        assertEq(inFlight, 0);
        assertEq(can, 20_000_000 ether);
        _assertInvariant();
    }

    function test_rateLimit_ARBside() public {
        _sendFromRH(alice, bob, 30_000_000 ether - 20_000_000 ether); // 10M out
        vm.warp(block.timestamp + 86_400);
        _sendFromRH(alice, bob, 20_000_000 ether); // bob now has 30M on ARB
        _sendFromARB(bob, alice, 20_000_000 ether);
        SendParam memory sp = _param(RH, alice, 1 ether);
        MessagingFee memory fee = oft.quoteSend(sp, false);
        vm.prank(bob);
        vm.expectRevert(RateLimiter.RateLimitExceeded.selector);
        oft.send{ value: fee.nativeFee }(sp, fee, bob);
        _assertInvariant();
    }

    function test_rateLimit_unconfiguredDestinationFailsClosed() public {
        SendParam memory sp = _param(99, bob, 1 ether);
        vm.startPrank(alice);
        token.approve(address(adapter), 1 ether);
        vm.expectRevert(RateLimiter.RateLimitExceeded.selector);
        adapter.send{ value: 1 ether }(sp, MessagingFee(1 ether, 0), alice);
        vm.stopPrank();
    }

    function test_rateLimit_ownerCanChange() public {
        RateLimiter.RateLimitConfig[] memory c = new RateLimiter.RateLimitConfig[](1);
        c[0] = RateLimiter.RateLimitConfig(ARB, 5_000 ether, 3_600);
        vm.prank(owner);
        adapter.setRateLimits(c);
        (, , uint192 limit, uint64 window) = adapter.rateLimits(ARB);
        assertEq(limit, 5_000 ether);
        assertEq(window, 3_600);
        (, uint256 can) = adapter.getAmountCanBeSent(ARB);
        assertEq(can, 5_000 ether);

        // pause = limit 0
        c[0].limit = 0;
        vm.prank(owner);
        adapter.setRateLimits(c);
        (, can) = adapter.getAmountCanBeSent(ARB);
        assertEq(can, 0);
    }

    // ---------------- access control ----------------

    function test_onlyOwner() public {
        address x = makeAddr("attacker");
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, x);
        RateLimiter.RateLimitConfig[] memory c = new RateLimiter.RateLimitConfig[](1);
        c[0] = RateLimiter.RateLimitConfig(ARB, type(uint192).max, 1);
        EnforcedOptionParam[] memory eo = new EnforcedOptionParam[](0);

        address[2] memory apps = [address(adapter), address(oft)];
        for (uint256 i; i < 2; i++) {
            NlyraOFT app = NlyraOFT(apps[i]); // same owner-facing surface on both
            vm.startPrank(x);
            vm.expectRevert(err);
            app.setRateLimits(c);
            vm.expectRevert(err);
            app.setPeer(ARB, bytes32(uint256(1)));
            vm.expectRevert(err);
            app.setEnforcedOptions(eo);
            vm.expectRevert(err);
            app.setDelegate(x);
            vm.expectRevert(err);
            app.setMsgInspector(x);
            vm.expectRevert(err);
            app.setPreCrime(x);
            vm.expectRevert(err);
            app.transferOwnership(x);
            vm.stopPrank();
        }

        // endpoint config is delegate-only
        vm.prank(x);
        vm.expectRevert();
        EndpointV2Mock(endpoints[RH]).setSendLibrary(address(adapter), ARB, address(0));
        // stranger cannot mint on ARB by calling lzReceive directly
        vm.prank(x);
        vm.expectRevert(abi.encodeWithSelector(OAppReceiver.OnlyEndpoint.selector, x));
        oft.lzReceive(Origin(RH, addressToBytes32(address(adapter)), 1), bytes32(0), "", x, "");
    }

    // ---------------- decimals / dust ----------------

    function test_dustStaysWithSender() public {
        uint256 amount = 1 ether + 123_456_789_012; // 1e12 granularity: 1.000000123456789012
        uint256 clean = (amount / 1e12) * 1e12; // 1.000000123456 (6 shared decimals)
        uint256 a0 = token.balanceOf(alice);
        OFTReceipt memory r = _sendFromRH(alice, bob, amount);
        assertEq(r.amountSentLD, clean);
        assertEq(r.amountReceivedLD, clean);
        assertEq(token.balanceOf(alice), a0 - clean, "dust must not leave the sender");
        assertEq(oft.balanceOf(bob), clean);
        _assertInvariant();
    }

    function test_belowOneSharedUnitSendsZero() public view {
        SendParam memory sp = _param(ARB, bob, 999_999_999_999);
        sp.minAmountLD = 0;
        (, , OFTReceipt memory r) = adapter.quoteOFT(sp);
        assertEq(r.amountSentLD, 0);
        assertEq(r.amountReceivedLD, 0);
    }

    function test_slippageRevertsWhenMinAboveDustFree() public {
        SendParam memory sp = _param(ARB, bob, 1 ether + 1); // min = amount, but 1 wei is dust
        vm.expectRevert(); // SlippageExceeded(1e18, 1e18+1)
        adapter.quoteSend(sp, false);
    }

    function test_maxSupplyFitsSharedDecimals() public view {
        // 1B * 1e6 = 1e15 < uint64 max (1.8e19): the whole supply can be represented
        (, , OFTReceipt memory r) = adapter.quoteOFT(_param(ARB, bob, 1_000_000_000 ether));
        assertEq(r.amountSentLD, 1_000_000_000 ether);
    }

    // ---------------- lzReceive gas (mock endpoint) ----------------

    /// Measures endpoint.lzReceive gas (what the executor's gas limit pays for) for a first-time recipient.
    function test_gas_lzReceive_measure() public {
        uint256 amount = 1_000 ether;
        // give bob ARB tokens first, then measure the return leg into a fresh RH address
        _sendFromRH(alice, bob, amount);
        uint256 gRH = _measure(false, makeAddr("freshRH"), amount);
        // measured packets stay in the helper queue, so each leg is measured last on its side
        uint256 gARB = _measure(true, makeAddr("freshARB"), amount);
        emit log_named_uint("mock lzReceive gas, ARB mint to fresh address", gARB);
        emit log_named_uint("mock lzReceive gas, RH unlock to fresh address", gRH);
        assertLt(gARB, P.LZ_RECEIVE_GAS);
        assertLt(gRH, P.LZ_RECEIVE_GAS);
    }

    function _measure(bool toBsc, address to, uint256 amount) internal returns (uint256 used) {
        SendParam memory sp = _param(toBsc ? ARB : RH, to, amount);
        address src = toBsc ? address(adapter) : address(oft);
        address dst = toBsc ? address(oft) : address(adapter);
        MessagingFee memory fee = NlyraOFT(src).quoteSend(sp, false);
        if (toBsc) {
            vm.startPrank(alice);
            token.approve(address(adapter), amount);
            adapter.send{ value: fee.nativeFee }(sp, fee, alice);
            vm.stopPrank();
        } else {
            vm.prank(bob);
            oft.send{ value: fee.nativeFee }(sp, fee, bob);
        }
        bytes memory packet = getNextInflightPacket(uint16(toBsc ? ARB : RH), addressToBytes32(dst));
        this.validatePacket(packet, "");
        used = this.execAndMeasure(packet);
        if (toBsc) assertEq(oft.balanceOf(to), amount);
        else assertEq(token.balanceOf(to), amount);
    }

    function execAndMeasure(bytes calldata packet) external returns (uint256 used) {
        EndpointV2Mock ep = EndpointV2Mock(endpoints[packet.dstEid()]);
        Origin memory origin = Origin(packet.srcEid(), packet.sender(), packet.nonce());
        address receiver = packet.receiverB20();
        bytes32 guid = packet.guid();
        bytes memory message = packet.message();
        // a real delivery is its own transaction: start from cold accounts/storage
        vm.cool(address(ep));
        vm.cool(receiver);
        vm.cool(address(token));
        uint256 g = gasleft();
        ep.lzReceive{ gas: P.LZ_RECEIVE_GAS }(origin, receiver, guid, message, "");
        used = g - gasleft();
    }

    function test_enforcedGasTooLowWouldFail() public {
        // sanity check that the gas limit matters: 20k gas is not enough for a mint
        vm.prank(owner);
        _ownerCall(address(adapter), _enforced(ARB, 20_000));
        uint256 amount = 1_000 ether;
        SendParam memory sp = _param(ARB, bob, amount);
        MessagingFee memory fee = adapter.quoteSend(sp, false);
        vm.startPrank(alice);
        token.approve(address(adapter), amount);
        adapter.send{ value: fee.nativeFee }(sp, fee, alice);
        vm.stopPrank();
        vm.expectRevert();
        this.verifyPackets(ARB, addressToBytes32(address(oft)));
    }

    function _enforced(uint32 eid, uint128 gas) internal pure returns (bytes memory) {
        EnforcedOptionParam[] memory p = new EnforcedOptionParam[](1);
        p[0] = EnforcedOptionParam(eid, 1, abi.encodePacked(uint16(3), uint8(1), uint16(17), uint8(1), gas));
        return abi.encodeWithSignature("setEnforcedOptions((uint32,uint16,bytes)[])", p);
    }
}
