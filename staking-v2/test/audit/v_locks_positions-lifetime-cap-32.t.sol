// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ForkBase} from "../ForkBase.sol";
import {RealYieldStaking} from "../../src/RealYieldStaking.sol";

/// REGRESION hallazgo 4 (antes: el tope de 32 era de por vida; tras 32 renovaciones mensuales la wallet
/// no podia volver a lockear nunca, aunque no tuviera ningun lock abierto). Ahora el tope es de locks
/// ABIERTOS: los slots se liberan al retirar y se reusan, y los ids de los abiertos no cambian.
contract VLocksLifetimeCap32 is ForkBase {
    /// 32 locks, todos liberados -> se puede volver a abrir 32 mas, en los mismos slots.
    function test_v_allReleased_canLockAgain() public {
        for (uint256 i; i < 32; ++i) _stake(alice, 1e18, 1);
        vm.warp(st.positionsOf(alice)[31].unlockTime);
        vm.startPrank(alice);
        for (uint256 i; i < 32; ++i) st.withdrawLocked(i);
        vm.stopPrank();
        (RealYieldStaking.Account memory acc,,, uint256 pc) = st.userInfo(alice);
        assertEq(acc.locked, 0);
        assertEq(pc, 0, "ningun lock abierto");
        for (uint256 i; i < 32; ++i) _stake(alice, 1e18, 2);
        (,,, pc) = st.userInfo(alice);
        assertEq(pc, 32);
        assertEq(st.positionsOf(alice).length, 32, "el array no crece");
        _checkSolvency(_users(), true);
    }

    /// Renovar cada mes retirando y volviendo a lockear: 40 ciclos (~3,5 anos) sin trabarse.
    function test_v_monthlyWithdrawAndRelock_40cycles() public {
        _giveNlyra(alice, 100e18);
        vm.startPrank(alice);
        NLYRA.approve(address(st), type(uint256).max);
        st.stakeLocked(100e18, 2);
        for (uint256 m; m < 40; ++m) {
            vm.warp(st.positionsOf(alice)[0].unlockTime);
            st.withdrawLocked(0);
            vm.warp(vm.getBlockTimestamp() + 2 days);
            st.withdraw();
            st.stakeLocked(100e18, 2);
        }
        vm.stopPrank();
        assertEq(st.positionsOf(alice).length, 1, "siempre el slot 0");
        assertEq(st.stakeOf(alice), 100e18);
        assertEq(st.boostedBalanceOf(alice), 150e18);
    }

    /// Renovar cada mes con extendLock (sin mover tokens): 45 ciclos, el boost nunca se cae.
    function test_v_monthlyExtend_45cycles() public {
        _stake(alice, 100e18, 2);
        _stake(bob, 100e18, 0);
        for (uint256 m; m < 45; ++m) {
            vm.warp(uint256(st.positionsOf(alice)[0].unlockTime) - 1 hours);
            assertEq(st.boostedBalanceOf(alice), 150e18, "boost activo antes de vencer");
            vm.prank(alice);
            st.extendLock(0, 2);
        }
        assertEq(st.positionsOf(alice).length, 1);
        assertEq(st.stakeOf(alice), 100e18);
        assertEq(NLYRA.balanceOf(alice), 0, "sin mover tokens");
        _checkSolvency(_users(), true);
    }
}
