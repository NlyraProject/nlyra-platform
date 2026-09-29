// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RealYieldStaking} from "../../src/RealYieldStaking.sol";
import {ForkBase} from "../ForkBase.sol";

/// Ronda 2, REGRESIONES (antes eran PoC):
///  (a) hallazgo E: con aumentos cada < 24 h `recent` se acumulaba sin limite y nunca maduraba. Ahora
///      cada aporte queda afuera de eligibleBalance solo su dia UTC y el siguiente.
///  (b) hallazgo D: compound a lock abria SIEMPRE una posicion nueva y a los 32 se trababa. Ahora se
///      compone dentro de un lock abierto.
///  (c) hallazgo A: auto-donarse premios y componer a lock drenaba la reserva de bonus. Ahora lo donado
///      no es elegible para el bonus.
contract R2_EconRecentWindowAndSlots is ForkBase {
    uint256 constant NEW = type(uint256).max;

    /// DCA: 100M iniciales + 1M cada 23 h durante ~60 dias. Solo quedan afuera los aportes de hoy y ayer.
    function test_recent_matures_underDCA() public {
        _stake(alice, 100_000_000e18, 0);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        assertEq(st.eligibleBalance(alice), 100_000_000e18);
        for (uint256 i; i < 62; ++i) {
            vm.warp(vm.getBlockTimestamp() + 23 hours);
            _stake(alice, 1_000_000e18, 0);
        }
        uint256 stake_ = st.stakeOf(alice);
        uint256 elig = st.eligibleBalance(alice);
        emit log_named_uint("stakeOf (M)", stake_ / 1e24);
        emit log_named_uint("eligibleBalance (M)", elig / 1e24);
        // en 48 h entran como mucho 3 aportes de 1M (cada 23 h)
        assertGe(elig, stake_ - 3_000_000e18, "lo de mas de 48 h cuenta");
        assertLe(elig, stake_ - 1_000_000e18, "el ultimo aporte no cuenta");
    }

    /// compound semanal a lock de 30 dias, siempre dentro del mismo lock: 40 semanas sin TooManyPositions
    function test_compound_intoSameLock_neverHitsSlotCap() public {
        _stake(alice, 100_000_000e18, 3);
        _stake(bob, 268_000_000e18, 0);
        _fund(owner, 40_000_000e18);
        uint256 n;
        for (uint256 i; i < 40; ++i) {
            _giveNlyra(address(sp), 2_000_000e18);
            vm.warp(vm.getBlockTimestamp() + 7 days);
            sp.harvest();
            vm.warp(vm.getBlockTimestamp() + 1 days);
            vm.prank(alice);
            st.compound(0, 3, 0);
            ++n;
        }
        assertEq(n, 40);
        assertEq(st.positionsOf(alice).length, 1, "siempre el lock 0");
        assertLt(st.bonusReserve(), 40_000_000e18, "cobro bonus");
        _checkSolvency(_users(), true);
    }

    /// (c) con casi todo el peso: donar NLYRA al staking, esperar el tramo y componer a 30d ya no cobra
    ///     bonus (lo donado no vino del splitter) -> el ciclo pierde (bob se lleva su parte).
    function test_selfFunded_rewards_noBonus() public {
        _stake(alice, 20_000_000e18, 3); // 2x -> 40M de peso
        _stake(bob, 1_000_000e18, 0); // unico otro staker
        _fund(owner, 40_000_000e18);
        uint256 donation = 100_000_000e18;
        _giveNlyra(address(st), donation); // donacion directa
        vm.warp(vm.getBlockTimestamp() + 1 days);
        sp.harvest(); // el harvest la toma igual (splitter vacio), pero sin bonus
        vm.warp(vm.getBlockTimestamp() + 7 days);
        (, uint256 en) = st.earned(alice);
        (, uint256 eligN) = st.earnedBonusEligible(alice);
        uint256 r0 = st.bonusReserve();
        vm.prank(alice);
        uint256 added = st.compound(0, 3, NEW);
        emit log_named_uint("donated (M)", donation / 1e24);
        emit log_named_uint("got back as reward (M)", en / 1e24);
        emit log_named_uint("elegible (M)", eligN / 1e24);
        uint256 bonus = r0 - st.bonusReserve();
        // el bonus sale solo de la parte elegible (fees reales del splitter), nunca de lo donado
        assertLe(bonus, ((added - bonus - (en - eligN)) * 500) / 10_000 + 1, "bonus solo sobre lo elegible");
        assertGe(en - eligN, (donation * 90) / 100, "lo donado no es elegible");
        assertLt(added, donation, "el ciclo ya no rinde");
    }
}
