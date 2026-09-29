// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ForkBase} from "../ForkBase.sol";
import {RealYieldStaking} from "../../src/RealYieldStaking.sol";

/// REGRESION hallazgo 8 (antes: un requestUnstake nuevo re-trababa 2 dias lo que ya estaba listo).
/// Ahora lo que ya maduro se paga en el acto y solo lo nuevo empieza su cooldown.
contract VerifyRequestUnstakeResetsCooldown is ForkBase {
    function test_v_maturedPaidOut_newAmountCoolsAlone() public {
        _stake(alice, 1_000_001e18, 0);
        vm.prank(alice);
        st.requestUnstake(1_000_000e18);
        vm.warp(vm.getBlockTimestamp() + 2 days + 1);
        vm.prank(alice);
        st.requestUnstake(1e18);
        assertEq(NLYRA.balanceOf(alice), 1_000_000e18, "lo maduro se pago");
        (RealYieldStaking.Account memory ac,,,) = st.userInfo(alice);
        assertEq(ac.cooling, 1e18, "solo lo nuevo en cooldown");
        assertEq(ac.cooldownEnd, block.timestamp + 2 days);
        assertEq(st.totalCooling(), 1e18);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(alice);
        st.withdraw();
        assertEq(NLYRA.balanceOf(alice), 1_000_001e18);
    }

    /// Lo mismo cuando el cooldown nuevo viene de liberar un lock vencido.
    function test_v_maturedPaidOut_onLockRelease() public {
        _stake(alice, 500e18, 0);
        _stake(alice, 700e18, 1);
        vm.prank(alice);
        st.requestUnstake(500e18);
        vm.warp(st.positionsOf(alice)[0].unlockTime);
        vm.prank(alice);
        st.withdrawLocked(0);
        assertEq(NLYRA.balanceOf(alice), 500e18);
        (RealYieldStaking.Account memory ac,,,) = st.userInfo(alice);
        assertEq(ac.cooling, 700e18);
    }

    /// Si lo anterior todavia no maduro, se suma y el reloj reinicia para todo (documentado).
    function test_v_unmaturedIsMerged() public {
        _stake(alice, 2e18, 0);
        vm.prank(alice);
        st.requestUnstake(1e18);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(alice);
        st.requestUnstake(1e18);
        (RealYieldStaking.Account memory ac,,,) = st.userInfo(alice);
        assertEq(ac.cooling, 2e18);
        assertEq(ac.cooldownEnd, block.timestamp + 2 days);
        assertEq(NLYRA.balanceOf(alice), 0);
    }
}
