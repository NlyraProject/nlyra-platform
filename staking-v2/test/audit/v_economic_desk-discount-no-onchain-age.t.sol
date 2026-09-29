// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ForkBase} from "../ForkBase.sol";

/// REGRESION hallazgo 7 (antes: stakeOf() no tenia edad; top-up en el bloque del trade o "estacionar" en
/// cooldown y cancelar antes del trade daban el tier completo). Ahora eligibleBalance(user) descuenta
/// todo lo que entro hoy o ayer (dia UTC) por stake, lock, compound o cancelUnstake: entre 24 y 48 h.
contract VEconDeskDiscountNoAge is ForkBase {
    uint256 constant TIER = 10_000_000e18;

    function _midnight() internal view returns (uint256) {
        return (vm.getBlockTimestamp() / 1 days + 1) * 1 days;
    }

    function test_v_a_topUpNotEligible() public {
        _stake(alice, 1e18, 0);
        vm.warp(_midnight() + 1 days); // pasado manana 00:00: madura
        assertEq(st.eligibleBalance(alice), 1e18);
        _stake(alice, TIER, 0); // mismo bloque del trade
        assertEq(st.stakeOf(alice), TIER + 1e18);
        assertEq(st.eligibleBalance(alice), 1e18, "el top-up no cuenta");
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        assertEq(st.eligibleBalance(alice), 1e18, "a las 24 h todavia no (dia siguiente)");
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        assertEq(st.eligibleBalance(alice), TIER + 1e18, "a las 48 h si");
    }

    function test_v_b_parkingNotEligible() public {
        _stake(alice, TIER, 0);
        vm.warp(vm.getBlockTimestamp() + 49 hours);
        assertEq(st.eligibleBalance(alice), TIER);
        vm.prank(alice);
        st.requestUnstake(TIER);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.prank(alice);
        st.cancelUnstake();
        assertEq(st.stakeOf(alice), TIER);
        assertEq(st.eligibleBalance(alice), 0, "cancelUnstake = stake nuevo");
        vm.prank(alice);
        st.requestUnstake(TIER);
        assertEq(st.eligibleBalance(alice), 0);
    }

    /// Flash-stake: 0 durante al menos 24 h, sea cual sea la hora del dia en que entra.
    function test_v_c_flashStakeNotEligible() public {
        uint256 m = _midnight();
        uint256[3] memory at = [m, m + 12 hours, m + 1 days - 1];
        for (uint256 k; k < 3; ++k) {
            uint256 snap = vm.snapshotState();
            vm.warp(at[k]);
            _stake(alice, TIER, 3);
            assertEq(st.eligibleBalance(alice), 0);
            vm.warp(at[k] + 24 hours - 1);
            assertEq(st.eligibleBalance(alice), 0, "< 24 h: nunca cuenta");
            vm.warp((at[k] / 1 days + 2) * 1 days); // dia D+2
            assertEq(st.eligibleBalance(alice), TIER, "desde el dia D+2 cuenta");
            vm.revertToState(snap);
        }
    }
}
