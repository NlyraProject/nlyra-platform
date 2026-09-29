// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ForkBase} from "../ForkBase.sol";
import {RealYieldStaking} from "../../src/RealYieldStaking.sol";

/// REGRESION CRIT-2 / hallazgo C. Antes: con el splitter vacio el harvest revertia (NothingToHarvest), con
/// 1 wei no notificaba y consumia el dia, y las fees mandadas directo al staking quedaban quietas. Ahora
/// el harvest siempre notifica y cualquiera puede llamar sweepDonations() (1 tramo por dia).
contract V_CRIT2 is ForkBase {
    function _trCount() internal view returns (uint256) {
        return st.tranches().length;
    }

    function test_directRoute_streamsWithoutPonsFees() public {
        _stake(alice, 1_000_000e18, 0);
        // drena los fees de Pons que haya en el bloque
        _trade(2 ether, 1);
        sp.harvest();
        uint256 c0 = _trCount();

        // fee directa del Desk al staking (README opcion 6)
        deal(address(WETH), address(st), WETH.balanceOf(address(st)) + 1 ether);

        // (a) al dia siguiente, sin trades y splitter vacio: el harvest NO revierte y abre el tramo
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        assertEq(WETH.balanceOf(address(sp)), 0);
        sp.harvest();
        assertEq(_trCount(), c0 + 1, "a: tramo con la fee directa");
        RealYieldStaking.Tranche[] memory t = st.tranches();
        assertGe(uint256(t[t.length - 1].rateWeth) * 7 days, 0.99 ether);
        assertEq(t[t.length - 1].eligWeth, 0, "fee directa: sin bonus");

        // (b) el grief de 1 wei ya no tapa nada: otra fee directa entra por sweepDonations el mismo dia
        deal(address(WETH), address(st), WETH.balanceOf(address(st)) + 1 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        deal(address(WETH), address(sp), 1);
        sp.harvest(); // (1 wei -> 0 a stakers) igual notifica: el 1 WETH directo entra aca
        assertEq(_trCount(), c0 + 2, "b: el harvest de 1 wei tambien abre tramo");
        deal(address(WETH), address(st), WETH.balanceOf(address(st)) + 1 ether);
        vm.prank(dave);
        st.sweepDonations();
        assertEq(_trCount(), c0 + 3, "b: sweepDonations, cualquiera, sin esperar al harvest");
        _checkSolvency(_users(), true);
    }
}
