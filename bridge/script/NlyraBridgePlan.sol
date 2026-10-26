// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import { SetConfigParam, IMessageLibManager } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/IMessageLibManager.sol";
import { UlnConfig } from "@layerzerolabs/lz-evm-messagelib-v2/contracts/uln/UlnBase.sol";
import { ExecutorConfig } from "@layerzerolabs/lz-evm-messagelib-v2/contracts/SendLibBase.sol";
import { EnforcedOptionParam, IOAppOptionsType3 } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppOptionsType3.sol";
import { IOAppCore } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppCore.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { RateLimiter } from "@layerzerolabs/oapp-evm/contracts/oapp/utils/RateLimiter.sol";
import { IOFT, SendParam, MessagingFee } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IRateLimited {
    function setRateLimits(RateLimiter.RateLimitConfig[] calldata _rateLimitConfigs) external;
}

/// @notice Single source of truth for every production parameter and every calldata in deploy-plan.json.
///         Used by the fork tests (which execute these calldatas against the real endpoints) and by
///         script/BuildPlan.s.sol (which dumps them so tools/verify-plan.mjs can diff them).
library NlyraBridgePlan {
    using OptionsBuilder for bytes;

    // ---- chains ----
    uint256 internal constant CHAIN_RH = 4663;
    uint256 internal constant CHAIN_ARB = 42161;
    uint32 internal constant EID_RH = 30416;
    uint32 internal constant EID_ARB = 30110;

    // ---- token / owner ----
    address internal constant NLYRA = 0xB9d3824149aD8ac984153CeEc91D5a2405d1FB95;
    address internal constant TREASURY = 0xe30647793192D15BFA6E53aE8651368d332fe04C;

    // ---- LayerZero V2, Robinhood Chain ----
    address internal constant RH_ENDPOINT = 0x6F475642a6e85809B1c36Fa62763669b1b48DD5B;
    address internal constant RH_SEND_ULN = 0xC39161c743D0307EB9BCc9FEF03eeb9Dc4802de7;
    address internal constant RH_RECV_ULN = 0xe1844c5D63a9543023008D332Bd3d2e6f1FE1043;
    address internal constant RH_EXECUTOR = 0x4208D6E27538189bB48E603D6123A94b8Abe0A0b;
    address internal constant RH_DVN_LZ = 0xd01ae6905d48315f7bE10C7330aeCF8360Ef5b12;
    address internal constant RH_DVN_NETHERMIND = 0x0Ffe02DF012299A370D5dd69298A5826EAcaFdF8;

    // ---- LayerZero V2, ARB ----
    address internal constant ARB_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
    address internal constant ARB_SEND_ULN = 0x975bcD720be66659e3EB3C0e4F1866a3020E493A;
    address internal constant ARB_RECV_ULN = 0x7B9E184e07a6EE1aC23eAe0fe8D6Be2f663f05e6;
    address internal constant ARB_EXECUTOR = 0x31CAe3B7fB82d847621859fb1585353c5720660D;
    address internal constant ARB_DVN_LZ = 0x2f55C492897526677C5B68fb199ea31E2c126416;
    address internal constant ARB_DVN_NETHERMIND = 0xa7b5189bcA84Cd304D8553977c7C614329750d99;

    // ---- security / delivery parameters ----
    /// Block confirmations a DVN waits on the SOURCE chain. Same value on the send side and the receive side.
    uint64 internal constant CONFIRMATIONS_RH_TO_ARB = 20; // RH ~0.1 s blocks -> ~2 s; LZ default is 5
    uint64 internal constant CONFIRMATIONS_ARB_TO_RH = 20; // Arbitrum ~0.25 s blocks -> ~5 s; LZ default is 20
    uint32 internal constant MAX_MESSAGE_SIZE = 10_000; // LZ default executor config on both pathways
    /// Gas the executor gives lzReceive on the destination (OFT SEND, msgType 1). See README for the measurement.
    uint128 internal constant LZ_RECEIVE_GAS = 150_000;
    uint16 internal constant MSG_TYPE_SEND = 1;

    // ---- rate limits ----
    uint192 internal constant RATE_LIMIT = 20_000_000 ether; // 20,000,000 NLYRA (18 decimals)
    uint64 internal constant RATE_WINDOW = 86_400; // 24 h

    // ---- round-trip test ----
    uint256 internal constant TEST_AMOUNT = 1_000 ether; // 1,000 NLYRA

    // ================= values =================

    function enforcedSendOptions() internal pure returns (bytes memory) {
        return OptionsBuilder.newOptions().addExecutorLzReceiveOption(LZ_RECEIVE_GAS, 0);
    }

    function sortedDvns(address a, address b) internal pure returns (address[] memory d) {
        d = new address[](2);
        (d[0], d[1]) = a < b ? (a, b) : (b, a);
    }

    function ulnConfig(uint64 confirmations, address[] memory requiredDvns) internal pure returns (UlnConfig memory) {
        return
            UlnConfig({
                confirmations: confirmations,
                requiredDVNCount: uint8(requiredDvns.length),
                optionalDVNCount: 0,
                optionalDVNThreshold: 0,
                requiredDVNs: requiredDvns,
                optionalDVNs: new address[](0)
            });
    }

    function rhDvns() internal pure returns (address[] memory) {
        return sortedDvns(RH_DVN_LZ, RH_DVN_NETHERMIND);
    }

    function arbDvns() internal pure returns (address[] memory) {
        return sortedDvns(ARB_DVN_LZ, ARB_DVN_NETHERMIND);
    }

    // ================= calldata =================

    function setPeer(uint32 eid, address peer) internal pure returns (bytes memory) {
        return abi.encodeCall(IOAppCore.setPeer, (eid, bytes32(uint256(uint160(peer)))));
    }

    function setEnforcedOptions(uint32 dstEid) internal pure returns (bytes memory) {
        EnforcedOptionParam[] memory p = new EnforcedOptionParam[](1);
        p[0] = EnforcedOptionParam({ eid: dstEid, msgType: MSG_TYPE_SEND, options: enforcedSendOptions() });
        return abi.encodeCall(IOAppOptionsType3.setEnforcedOptions, (p));
    }

    function setSendLibrary(address oapp, uint32 dstEid, address lib) internal pure returns (bytes memory) {
        return abi.encodeCall(IMessageLibManager.setSendLibrary, (oapp, dstEid, lib));
    }

    function setReceiveLibrary(address oapp, uint32 srcEid, address lib) internal pure returns (bytes memory) {
        return abi.encodeCall(IMessageLibManager.setReceiveLibrary, (oapp, srcEid, lib, 0));
    }

    /// SendUln302: executor config (type 1) + ULN config (type 2) for the destination.
    function setSendConfig(
        address oapp,
        address sendLib,
        uint32 dstEid,
        address executor,
        uint64 confirmations,
        address[] memory dvns
    ) internal pure returns (bytes memory) {
        SetConfigParam[] memory p = new SetConfigParam[](2);
        p[0] = SetConfigParam(dstEid, 1, abi.encode(ExecutorConfig(MAX_MESSAGE_SIZE, executor)));
        p[1] = SetConfigParam(dstEid, 2, abi.encode(ulnConfig(confirmations, dvns)));
        return abi.encodeCall(IMessageLibManager.setConfig, (oapp, sendLib, p));
    }

    /// ReceiveUln302: ULN config (type 2) for the source.
    function setReceiveConfig(
        address oapp,
        address recvLib,
        uint32 srcEid,
        uint64 confirmations,
        address[] memory dvns
    ) internal pure returns (bytes memory) {
        SetConfigParam[] memory p = new SetConfigParam[](1);
        p[0] = SetConfigParam(srcEid, 2, abi.encode(ulnConfig(confirmations, dvns)));
        return abi.encodeCall(IMessageLibManager.setConfig, (oapp, recvLib, p));
    }

    function setRateLimits(uint32 dstEid) internal pure returns (bytes memory) {
        RateLimiter.RateLimitConfig[] memory c = new RateLimiter.RateLimitConfig[](1);
        c[0] = RateLimiter.RateLimitConfig({ dstEid: dstEid, limit: RATE_LIMIT, window: RATE_WINDOW });
        return abi.encodeCall(IRateLimited.setRateLimits, (c));
    }

    function approve(address spender, uint256 amount) internal pure returns (bytes memory) {
        return abi.encodeCall(IERC20.approve, (spender, amount));
    }

    function sendParam(uint32 dstEid, address to, uint256 amount) internal pure returns (SendParam memory) {
        return SendParam(dstEid, bytes32(uint256(uint160(to))), amount, amount, "", "", "");
    }

    function send(uint32 dstEid, address to, uint256 amount, uint256 nativeFee) internal pure returns (bytes memory) {
        return abi.encodeCall(IOFT.send, (sendParam(dstEid, to, amount), MessagingFee(nativeFee, 0), to));
    }
}
