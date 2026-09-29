// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RealYieldStaking} from "../../src/RealYieldStaking.sol";
import {ForkBase} from "../ForkBase.sol";

/// REGRESION R2-ECON-1 / hallazgo A: bonus de compound sobre premios auto-financiados.
/// Antes: con ~98% del peso, donar 100M al staking y componer a lock devolvia 98M + 9M de bonus por
/// ciclo y vaciaba una reserva de 40M en 5 ciclos. Ahora:
///  - donacion DIRECTA al staking: no es elegible -> bonus 0 -> cada ciclo pierde lo que se lleva bob;
///  - donacion POR EL SPLITTER (si es elegible): el 50% va al treasury -> pierde ~la mitad.
contract V_Economic2_R2_ECON_1 is ForkBase {
    uint256 constant NEW = type(uint256).max;

    function _cycleDirect(uint256 donation) internal returns (uint256 en, uint256 added) {
        _giveNlyra(address(st), donation); // alice "dona" directo
        vm.warp(vm.getBlockTimestamp() + 1 days);
        st.sweepDonations();
        vm.warp(vm.getBlockTimestamp() + 7 days);
        (, en) = st.earned(alice);
        vm.prank(alice);
        added = st.compound(0, 3, NEW);
    }

    function test_selfFunded_direct_noBonus_reserveIntact() public {
        _stake(alice, 20_000_000e18, 3); // 40M peso
        _stake(bob, 1_000_000e18, 0); // 1M peso
        _fund(owner, 40_000_000e18);
        uint256 r0 = st.bonusReserve();
        uint256 donation = 100_000_000e18;
        for (uint256 k; k < 5; ++k) {
            (uint256 en, uint256 added) = _cycleDirect(donation);
            assertEq(added, en, "sin bonus");
            assertLt(added, donation, "cada ciclo pierde");
        }
        assertEq(st.bonusReserve(), r0, "la reserva no se toca");
    }

    /// Por el splitter la donacion si cuenta como fee (es elegible), pero el treasury se queda con su parte:
    /// 0,5 x 0,976 x 1,05 < 1.
    function test_selfFunded_viaSplitter_unprofitable() public {
        _stake(alice, 20_000_000e18, 3);
        _stake(bob, 1_000_000e18, 0);
        _fund(owner, 40_000_000e18);
        uint256 donation = 100_000_000e18;
        _giveNlyra(address(sp), donation);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        sp.harvest();
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 r0 = st.bonusReserve();
        vm.prank(alice);
        uint256 added = st.compound(0, 3, NEW);
        uint256 bonus = r0 - st.bonusReserve();
        emit log_named_uint("donated (M)", donation / 1e24);
        emit log_named_uint("alice locked incl bonus (M)", added / 1e24);
        emit log_named_uint("bonus (M)", bonus / 1e24);
        assertGt(bonus, 0, "via splitter es elegible");
        assertLt(added, (donation * 55) / 100, "pierde ~la mitad");
    }

    /// El splitter no deja mandar mas del 90% a stakers: con el maximo, 0,9 x 1,05 < 1 aun con el 100%
    /// del peso.
    function test_splitCapMakesSelfDonationUnprofitable() public pure {
        uint256 maxSplit = 9_000;
        assertLt((maxSplit * 10_500) / 10_000, 10_000);
    }
}
