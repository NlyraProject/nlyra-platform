// SPDX-License-Identifier: MIT
pragma solidity 0.8.22;

import { Script } from "forge-std/Script.sol";
import { NlyraBridgePlan as P } from "./NlyraBridgePlan.sol";

/// Dumps every calldata of the deploy plan, encoded by Solidity (abi.encodeCall on the real interfaces), into
/// plan-src/calldata.json. Addresses/fees unknown before deployment are encoded with sentinels:
///   $ADAPTER = address(uint160(uint256(keccak256("$ADAPTER"))))
///   $OFT     = address(uint160(uint256(keccak256("$OFT"))))
///   $FEE     = uint256(keccak256("$FEE"))
/// tools/make-plan.mjs turns this into out-public/deploy-plan.json and tools/verify-plan.mjs re-derives all of it.
/// No RPC, no broadcast: run with `forge script script/BuildPlan.s.sol` (no --rpc-url, no --broadcast).
contract BuildPlan is Script {
    address internal constant ADAPTER = address(uint160(uint256(keccak256("$ADAPTER"))));
    address internal constant OFT = address(uint160(uint256(keccak256("$OFT"))));
    uint256 internal constant FEE = uint256(keccak256("$FEE"));

    string internal constant K = "calldata";
    string internal json;

    function _put(string memory id, bytes memory data) internal {
        json = vm.serializeBytes(K, id, data);
    }

    function run() external {
        bytes memory adapterInit = abi.encodePacked(
            vm.getCode("NlyraOFTAdapter.sol:NlyraOFTAdapter"),
            abi.encode(P.NLYRA, P.RH_ENDPOINT, P.TREASURY)
        );
        bytes memory oftInit = abi.encodePacked(vm.getCode("NlyraOFT.sol:NlyraOFT"), abi.encode(P.ARB_ENDPOINT, P.TREASURY));

        address[] memory rhDvns = P.rhDvns();
        address[] memory arbDvns = P.arbDvns();

        _put("01-deploy-adapter", adapterInit);
        _put("02-deploy-oft", oftInit);
        _put("03-adapter-setPeer", P.setPeer(P.EID_ARB, OFT));
        _put("04-oft-setPeer", P.setPeer(P.EID_RH, ADAPTER));
        _put("05-adapter-setEnforcedOptions", P.setEnforcedOptions(P.EID_ARB));
        _put("06-oft-setEnforcedOptions", P.setEnforcedOptions(P.EID_RH));
        _put("07-rh-setSendLibrary", P.setSendLibrary(ADAPTER, P.EID_ARB, P.RH_SEND_ULN));
        _put("08-rh-setReceiveLibrary", P.setReceiveLibrary(ADAPTER, P.EID_ARB, P.RH_RECV_ULN));
        _put("09-arb-setSendLibrary", P.setSendLibrary(OFT, P.EID_RH, P.ARB_SEND_ULN));
        _put("10-arb-setReceiveLibrary", P.setReceiveLibrary(OFT, P.EID_RH, P.ARB_RECV_ULN));
        _put(
            "11-rh-setConfig-send",
            P.setSendConfig(ADAPTER, P.RH_SEND_ULN, P.EID_ARB, P.RH_EXECUTOR, P.CONFIRMATIONS_RH_TO_ARB, rhDvns)
        );
        _put("12-rh-setConfig-receive", P.setReceiveConfig(ADAPTER, P.RH_RECV_ULN, P.EID_ARB, P.CONFIRMATIONS_ARB_TO_RH, rhDvns));
        _put(
            "13-arb-setConfig-send",
            P.setSendConfig(OFT, P.ARB_SEND_ULN, P.EID_RH, P.ARB_EXECUTOR, P.CONFIRMATIONS_ARB_TO_RH, arbDvns)
        );
        _put("14-arb-setConfig-receive", P.setReceiveConfig(OFT, P.ARB_RECV_ULN, P.EID_RH, P.CONFIRMATIONS_RH_TO_ARB, arbDvns));
        _put("15-adapter-setRateLimits", P.setRateLimits(P.EID_ARB));
        _put("16-oft-setRateLimits", P.setRateLimits(P.EID_RH));
        _put("17-test-approve", P.approve(ADAPTER, P.TEST_AMOUNT));
        _put("18-test-send-rh-to-arb", P.send(P.EID_ARB, P.TREASURY, P.TEST_AMOUNT, FEE));
        _put("19-test-send-arb-to-rh", P.send(P.EID_RH, P.TREASURY, P.TEST_AMOUNT, FEE));

        // values the verifier needs to check against (read back on-chain after each step)
        _put("x-enforcedOptions", P.enforcedSendOptions());
        _put("x-ulnConfig-rh-send", abi.encode(P.ulnConfig(P.CONFIRMATIONS_RH_TO_ARB, rhDvns)));
        _put("x-ulnConfig-rh-receive", abi.encode(P.ulnConfig(P.CONFIRMATIONS_ARB_TO_RH, rhDvns)));
        _put("x-ulnConfig-arb-send", abi.encode(P.ulnConfig(P.CONFIRMATIONS_ARB_TO_RH, arbDvns)));
        _put("x-ulnConfig-arb-receive", abi.encode(P.ulnConfig(P.CONFIRMATIONS_RH_TO_ARB, arbDvns)));
        json = vm.serializeAddress(K, "sentinel-adapter", ADAPTER);
        json = vm.serializeAddress(K, "sentinel-oft", OFT);
        json = vm.serializeBytes32(K, "sentinel-fee", bytes32(FEE));
        vm.writeJson(json, "./plan-src/calldata.json");
    }
}
