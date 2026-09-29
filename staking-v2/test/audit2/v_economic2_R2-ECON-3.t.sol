// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RealYieldStaking} from "../../src/RealYieldStaking.sol";
import {ForkBase} from "../ForkBase.sol";

/// REGRESION R2-ECON-3 / hallazgo D. Antes: con 32 slots ocupados, compound a lock revertia con
/// TooManyPositions y habia que liberar un slot a mano. Ahora se compone dentro de un lock abierto
/// (activo, si el tier es igual o mayor; vencido, con cualquier tier), sin slots libres.
contract V_Economic2_R2_ECON_3 is ForkBase {
    function _reward() internal {
        _giveNlyra(address(sp), 2_000_000e18);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        sp.harvest();
        vm.warp(vm.getBlockTimestamp() + 1 days);
    }

    function test_fullSlots_compoundIntoExisting() public {
        _stake(bob, 100_000_000e18, 0);
        _fund(owner, 40_000_000e18);
        // 32 locks de 30 dias: todos los slots ocupados
        for (uint256 i; i < 32; ++i) _stake(alice, 1_000_000e18, 3);
        _reward();
        vm.prank(alice);
        vm.expectRevert(RealYieldStaking.TooManyPositions.selector);
        st.compound(0, 3, type(uint256).max);
        // dentro del lock 5 (activo, mismo tier): anda y cobra bonus
        uint256 r0 = st.bonusReserve();
        vm.prank(alice);
        uint256 added = st.compound(0, 3, 5);
        assertGt(added, 0);
        assertLt(st.bonusReserve(), r0, "con bonus");
        assertEq(st.positionsOf(alice)[5].amount, 1_000_000e18 + added);
        // pasan 40 dias: todos vencidos; compound dentro de un vencido con cualquier tier
        vm.warp(vm.getBlockTimestamp() + 40 days);
        _reward();
        vm.prank(alice);
        st.compound(0, 1, 7);
        assertEq(st.positionsOf(alice)[7].tier, 1);
        (,,, uint256 pc) = st.userInfo(alice);
        assertEq(pc, 32);
        _checkSolvency(_users(), true);
    }
}
