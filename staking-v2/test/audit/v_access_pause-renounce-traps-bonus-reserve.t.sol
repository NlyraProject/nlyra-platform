// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RealYieldStaking} from "../../src/RealYieldStaking.sol";
import {ForkBase} from "../ForkBase.sol";

/// REGRESION hallazgo 5 (antes: pausa + renounceOwnership dejaba 10M NLYRA de reserva atrapados para
/// siempre, y fundBonusReserve aceptaba 5M mas en plena pausa). Ahora: renounce deshabilitado, la
/// reserva no acepta fondos en pausa, y la pausa vence sola a los 30 dias (clave perdida = no traba nada).
contract VAccessPauseRenounceTrapsBonusReserve is ForkBase {
    function test_v_pauseRenounce_cannotTrapReserve() public {
        _stake(alice, 1e24, 0);
        _stake(bob, 1e24, 1);
        _tradeAndHarvest();
        _fund(dave, 5_000_000e18);

        vm.startPrank(owner);
        st.pause();
        vm.expectRevert(RealYieldStaking.RenounceDisabled.selector);
        st.renounceOwnership();
        vm.stopPrank();
        assertEq(st.owner(), owner, "sigue habiendo owner");

        // no se acepta plata en la reserva durante la pausa
        _giveNlyra(dave, 5_000_000e18);
        vm.startPrank(dave);
        NLYRA.approve(address(st), type(uint256).max);
        vm.expectRevert(RealYieldStaking.EnforcedPause.selector);
        st.fundBonusReserve(5_000_000e18);
        vm.stopPrank();
        assertEq(st.bonusReserve(), 5_000_000e18);

        // el owner "pierde la clave": nadie despausa, pero la pausa vence sola
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.prank(alice);
        vm.expectRevert(RealYieldStaking.EnforcedPause.selector);
        st.compound(0, 3, type(uint256).max);
        vm.warp(vm.getBlockTimestamp() + 27 days);
        assertFalse(st.paused());
        uint256 r0 = st.bonusReserve();
        vm.prank(alice);
        st.compound(0, 3, type(uint256).max);
        assertLt(st.bonusReserve(), r0, "la reserva vuelve a salir como bonus");
        _checkSolvency(_users(), true);
    }

    /// Control: una pausa con owner activo se levanta y el bonus sale.
    function test_v_pauseOnly_isRecoverable() public {
        _stake(alice, 1e24, 0);
        _tradeAndHarvest();
        _fund(dave, 1_000_000e18);
        vm.prank(owner);
        st.pause();
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.prank(alice);
        vm.expectRevert(RealYieldStaking.EnforcedPause.selector);
        st.compound(0, 3, type(uint256).max);
        vm.prank(owner);
        st.unpause();
        uint256 r0 = st.bonusReserve();
        vm.prank(alice);
        st.compound(0, 3, type(uint256).max);
        assertLt(st.bonusReserve(), r0, "bonus pagado al despausar");
    }
}
