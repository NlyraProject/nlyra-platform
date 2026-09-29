// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ForkBase} from "../ForkBase.sol";
import {RealYieldStaking} from "../../src/RealYieldStaking.sol";

/// REGRESION hallazgo 4b (antes: no habia relock/extend; renovar = retirar + aprobar + lockear en un
/// slot nuevo). Ahora extendLock(id, tier) renueva en el mismo slot, sin mover tokens, nunca acorta.
contract VLocksNoLockExtensionRelockTest is ForkBase {
    function test_v_extendLock_renewsInPlace() public {
        _stake(alice, 100e18, 3);
        vm.warp(uint256(st.positionsOf(alice)[0].unlockTime) + 5 days); // vencido, sin tocar
        assertEq(st.boostedBalanceOf(alice), 100e18, "vencido = 1x aunque nadie haga kick");
        vm.prank(alice);
        st.extendLock(0, 3);
        RealYieldStaking.Position[] memory ps = st.positionsOf(alice);
        assertEq(ps.length, 1, "mismo slot");
        assertEq(ps[0].amount, 100e18);
        assertEq(ps[0].tier, 3);
        assertGe(ps[0].unlockTime, block.timestamp + 30 days);
        assertEq(st.boostedBalanceOf(alice), 200e18);
        assertEq(NLYRA.balanceOf(alice), 0, "los tokens no salieron");
        assertEq(st.stakeOf(alice), 100e18);
        // nunca acortar
        vm.prank(alice);
        vm.expectRevert(RealYieldStaking.CannotShorten.selector);
        st.extendLock(0, 1);
    }

    /// 32 renovaciones mensuales (~2,6 anos): la wallet sigue pudiendo lockear.
    function test_v_32Renewals_stillCanLock() public {
        for (uint256 i; i < 32; ++i) {
            _stake(alice, 1e18, 1);
            vm.warp(st.positionsOf(alice)[0].unlockTime);
            vm.prank(alice);
            st.withdrawLocked(0);
        }
        _stake(alice, 1e18, 1);
        (,,, uint256 pc) = st.userInfo(alice);
        assertEq(pc, 1);
        assertEq(st.positionsOf(alice).length, 1);
    }
}
