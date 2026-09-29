// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ForkBase} from "../ForkBase.sol";
import "forge-std/console.sol";

/// REGRESION hallazgo 3 (antes: con un harvest de 1 wei por dia Alice cobraba el 66,00% a los 7 dias y
/// Carol, que entro despues, se llevaba el 32,65% de un ingreso anterior a su llegada). Ahora cada notify
/// es un tramo con su propio fin: los harvests extra no estiran nada.
contract VAcctRolloverRestream is ForkBase {
    uint256 t;

    function _lump() internal returns (uint256 lump) {
        _stake(alice, 1_000_000e18, 0);
        t = block.timestamp;
        deal(address(WETH), address(sp), 10 ether);
        (uint256 w0,) = _rewardBal();
        sp.harvest();
        (uint256 w1,) = _rewardBal();
        lump = w1 - w0;
    }

    function _day(bool grief) internal {
        t += 1 days;
        vm.warp(t);
        if (grief) {
            vm.deal(dave, 1);
            vm.prank(dave);
            (bool ok,) = address(sp).call{value: 1}("");
            require(ok);
            vm.prank(dave);
            sp.harvest();
        }
    }

    function _run(bool grief) internal returns (uint256 lump, uint256 aliceGot, uint256 carolGot) {
        lump = _lump();
        for (uint256 d; d < 7; ++d) _day(grief);
        (aliceGot,) = st.earned(alice);
        vm.prank(alice);
        st.requestUnstake(1_000_000e18);
        _stake(carol, 1_000_000e18, 0);
        for (uint256 d; d < 21; ++d) _day(grief);
        (carolGot,) = st.earned(carol);
    }

    function test_v_dailyDustHarvestsDoNotStretch() public {
        uint256 snap = vm.snapshotState();
        (uint256 l0, uint256 a0, uint256 c0) = _run(false);
        vm.revertToState(snap);
        (uint256 l1, uint256 a1, uint256 c1) = _run(true);
        console.log("alice bps honest / grief", a0 * 10_000 / l0, a1 * 10_000 / l1);
        console.log("carol wei honest / grief", c0, c1);
        assertApproxEqAbs(a0, l0, 7 days, "sin harvests extra: 100% en 7 dias");
        assertApproxEqAbs(a1, l1, 7 days, "con 1 wei diario: TAMBIEN 100% en 7 dias");
        assertLe(c1, 7 days, "el que llega despues no se lleva nada del ingreso anterior");
    }

    /// Harvests diarios con fees reales: el primer ingreso termina de pagarse a los 7 dias igual.
    function test_v_dailyRealHarvests_firstLumpPaidIn7Days() public {
        uint256 lump = _lump();
        uint256 later;
        for (uint256 d = 1; d <= 7; ++d) {
            _trade(1 ether, 1);
            _resetOracle();
            vm.warp(t + d * 1 days);
            (uint256 w0,) = _rewardBal();
            sp.harvest();
            (uint256 w1,) = _rewardBal();
            // lo que entro el dia d solo lleva 7-d dias (el del dia 7 recien empieza)
            later += ((w1 - w0) * (7 - d)) / 7;
        }
        (uint256 aw,) = st.earned(alice);
        console.log("lump", lump, "alice a los 7 dias", aw);
        assertApproxEqAbs(aw, lump + later, 8 * 7 days, "el primer ingreso pagado al 100%");
        _checkSolvency(_users(), true);
    }
}
