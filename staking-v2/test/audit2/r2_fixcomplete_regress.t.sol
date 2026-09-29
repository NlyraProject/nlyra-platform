// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RealYieldStaking} from "../../src/RealYieldStaking.sol";
import {ForkBase} from "../ForkBase.sol";
import "forge-std/console.sol";

/// Ronda 2 (angulo: completitud de los arreglos y regresiones). F1/F2 eran PoC; ahora el ataque falla.
contract R2FixCompleteRegress is ForkBase {
    uint256 constant NEW = type(uint256).max;

    /// NLYRA-only rewards NO elegibles: dona `amt` al staking y lo pone a streamear (sweepDonations).
    function _donateAndSweep(uint256 amt) internal {
        _giveNlyra(address(st), amt);
        st.sweepDonations();
    }

    /// F1 (hallazgo D): compound diario a 30d DENTRO del mismo lock: 40 dias sin tocar el tope de 32, y
    ///     stakeLocked sigue disponible.
    function test_r2_dailyCompoundTo30d_intoSameLock_noSlotCap() public {
        _stake(alice, 100_000_000e18, 3);
        _stake(bob, 100_000_000e18, 0);
        _fund(carol, 50_000_000e18);
        for (uint256 d; d < 40; ++d) {
            if (d % 7 == 0) _donateAndSweep(7_000_000e18);
            vm.warp(vm.getBlockTimestamp() + 1 days);
            vm.prank(alice);
            st.compound(0, 3, 0);
        }
        assertEq(st.positionsOf(alice).length, 1);
        (,,, uint256 pc) = st.userInfo(alice);
        assertEq(pc, 1);
        _stake(alice, 1e18, 1); // stakeLocked sigue andando
        _checkSolvency(_users(), true);
    }

    /// F2 (hallazgo A): el bonus ya NO se paga sobre premios auto-donados. Con peso dominante, donar D al
    ///     staking y componer a 30d devuelve menos que D (la parte de bob se pierde, sin bonus).
    function test_r2_selfDonation_noBonus_netLoss() public {
        _fund(carol, 10_000_000e18); // la reserva
        _stake(bob, 5_000_000e18, 0); // otro staker chico
        _stake(alice, 100_000_000e18, 3); // atacante: 200M de peso vs 5M
        uint256 D = 50_000_000e18;
        _giveNlyra(alice, D);
        vm.prank(alice);
        NLYRA.transfer(address(st), D); // "donacion"
        st.sweepDonations();
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 r0 = st.bonusReserve();
        vm.prank(alice);
        uint256 added = st.compound(0, 3, NEW);
        uint256 bonus = r0 - st.bonusReserve();
        console.log("donado      ", D / 1e18);
        console.log("compuesto   ", added / 1e18);
        console.log("bonus       ", bonus / 1e18);
        assertEq(bonus, 0, "sin bonus sobre lo donado");
        assertLt(added, D, "no recupera lo donado");
        // sale todo a los 30d + 2d
        vm.warp(vm.getBlockTimestamp() + 31 days);
        uint256 pid = st.positionsOf(alice).length - 1;
        vm.startPrank(alice);
        st.withdrawLocked(pid);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        st.withdraw();
        vm.stopPrank();
        assertEq(NLYRA.balanceOf(alice), added, "neto = donacion - fuga a bob");
        _checkSolvency(_users());
    }

    /// Chequeo de regresion: extendLock sobre lock vencido NO devuelve boost retroactivo.
    function test_r2_extendExpired_noRetroBoost() public {
        _stake(alice, 100_000_000e18, 2);
        _stake(bob, 100_000_000e18, 0);
        _donateAndSweep(70_000_000e18);
        vm.warp(vm.getBlockTimestamp() + 20 days);
        for (uint256 k; k < 6; ++k) {
            _donateAndSweep(70_000_000e18);
            vm.warp(vm.getBlockTimestamp() + 1 days);
        }
        (uint256 wa0, uint256 na0) = st.earned(alice);
        vm.prank(alice);
        st.extendLock(0, 2);
        (uint256 wa1, uint256 na1) = st.earned(alice);
        assertEq(wa1, wa0);
        assertEq(na1, na0, "extend no cambia lo devengado");
        _checkSolvency(_users(), true);
    }

    /// Bordes: todo cae en la MISMA medianoche M (vencimiento de dos locks, fin de un tramo, notify nuevo,
    /// extendLock y withdrawLocked en el mismo timestamp). Solvencia exacta y reparto 1x despues de M.
    function test_r2_everythingAtSameMidnight() public {
        _stake(alice, 100_000_000e18, 2); // 14d 1.5x
        _stake(bob, 100_000_000e18, 2);
        _stake(carol, 100_000_000e18, 0);
        uint64 M = st.positionsOf(alice)[0].unlockTime;
        // tramo que termina EXACTO en M
        vm.warp(M - 7 days);
        _donateAndSweep(70_000_000e18);
        vm.warp(M);
        _donateAndSweep(70_000_000e18);
        vm.prank(alice);
        st.extendLock(0, 3); // vencido en este segundo -> 2x desde ahora
        vm.prank(bob);
        st.withdrawLocked(0);
        _checkSolvency(_users(), true);
        (, uint256 a0) = st.earned(alice);
        (, uint256 c0) = st.earned(carol);
        vm.warp(M + 7 days);
        (, uint256 a1) = st.earned(alice);
        (, uint256 c1) = st.earned(carol);
        // despues de M: alice 2x vs carol 1x (bob en cooldown)
        assertApproxEqRel((a1 - a0) * 10, (c1 - c0) * 20, 1e12);
        _checkSolvency(_users(), true);
        // antes de M: alice y bob 1.5x, carol 1x -> alice/carol = 1.5
        assertApproxEqRel(a0 * 10, c0 * 15, 1e15);
    }
}
