// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RealYieldStaking} from "../../src/RealYieldStaking.sol";
import {ForkBase} from "../ForkBase.sol";
import "forge-std/console.sol";

/// Verificacion: stake fino antes de que lleguen los grandes se lleva el stream (comportamiento pro-rata normal).
contract VEconThinStakeStream is ForkBase {
    // 1 wei solo en el pool durante un stream completo -> cobra ~100%
    function test_v_thinStakeAloneTakesFullStream() public {
        _stake(dave, 1, 0);
        (uint256 w, uint256 n) = _tradeAndHarvest();
        vm.warp(vm.getBlockTimestamp() + 7 days);
        (uint256 dw, uint256 dn) = st.earned(dave);
        console.log("stream WETH", w, "dave earned", dw);
        console.log("stream NLYRA", n, "dave earned", dn);
        assertApproxEqRel(dw, w, 1e15);
        assertApproxEqRel(dn, n, 1e15);
        uint256 b = WETH.balanceOf(dave);
        vm.prank(dave);
        st.claim(RealYieldStaking.OutMode.AS_IS, 0);
        console.log("dave claimed WETH", WETH.balanceOf(dave) - b);
        _checkSolvency(_users());
    }

    // whale que entra a mitad del stream: desde ese momento el reparto es pro-rata; solo lo ya emitido fue del temprano
    function test_v_lateWhaleIsProRataFromEntry() public {
        _stake(dave, 1, 0);
        (uint256 w,) = _tradeAndHarvest();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        (uint256 d1,) = st.earned(dave);
        _stake(alice, 100_000_000e18, 0);
        vm.warp(vm.getBlockTimestamp() + 6 days);
        (uint256 d2,) = st.earned(dave);
        (uint256 aw,) = st.earned(alice);
        console.log("stream WETH", w);
        console.log("dave day1", d1, "dave day7", d2);
        console.log("alice (late whale) WETH", aw);
        assertApproxEqRel(d1, w / 7, 1e16);
        assertApproxEqRel(aw, (w * 6) / 7, 1e16);
        assertLe(d2 - d1, 1);
    }

    // mitigacion: seed stake antes del redirect -> 1 wei cobra polvo
    function test_v_seedStakeMitigates() public {
        _stake(alice, 100_000_000e18, 0);
        _stake(dave, 1, 0);
        _tradeAndHarvest();
        vm.warp(vm.getBlockTimestamp() + 7 days);
        (uint256 dw,) = st.earned(dave);
        console.log("seeded: dave WETH", dw);
        assertLe(dw, 1);
    }
}
