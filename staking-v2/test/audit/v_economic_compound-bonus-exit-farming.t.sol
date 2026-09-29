// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RealYieldStaking} from "../../src/RealYieldStaking.sol";
import {ForkBase} from "../ForkBase.sol";
import "forge-std/console.sol";

/// REGRESION hallazgo 1 (antes: compound -> requestUnstake -> withdraw rendia +9,9% sobre claim y una
/// wallet solo-lock se llevaba 40.607 NLYRA de bonus por semana). Ahora el bonus (5%) se paga SOLO si el
/// compound entra a un lock de 30 dias.
contract VEconCompoundBonusExitFarming is ForkBase {
    /// Mismo stake, mismos premios: claim(ALL_NLYRA) contra compound al flexible + salida a los 2 dias.
    function test_v_compoundThenExit_noLongerBeatsClaim() public {
        _stake(alice, 100_000_000e18, 0);
        _stake(bob, 100_000_000e18, 0);
        _fund(carol, 10_000_000e18);
        _tradeAndHarvest();
        vm.warp(vm.getBlockTimestamp() + 7 days);

        uint256 a0 = NLYRA.balanceOf(alice);
        vm.prank(alice);
        st.claim(RealYieldStaking.OutMode.ALL_NLYRA, 0);
        uint256 aliceGot = NLYRA.balanceOf(alice) - a0;

        uint256 r0 = st.bonusReserve();
        vm.prank(bob);
        uint256 added = st.compound(0, 0, type(uint256).max);
        assertEq(st.bonusReserve(), r0, "el flexible no cobra bonus");
        vm.prank(bob);
        st.requestUnstake(added);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        uint256 b0 = NLYRA.balanceOf(bob);
        vm.prank(bob);
        st.withdraw();
        uint256 bobGot = NLYRA.balanceOf(bob) - b0;
        console.log("alice claim ALL_NLYRA  ", aliceGot);
        console.log("bob compound+exit      ", bobGot);
        // antes: bobGot > aliceGot * 1.09. Ahora es lo mismo (bob compra despues de alice: un poco menos)
        assertLe(bobGot, (aliceGot * 1001) / 1000, "compound+salida ya no rinde mas que claim");
        (RealYieldStaking.Account memory acc,,,) = st.userInfo(bob);
        assertEq(acc.flexible, 100_000_000e18, "principal intacto");
    }

    /// Una wallet solo-lock: compound al flexible sin bonus; compound a lock con bonus pero trabado 30 dias.
    function test_v_lockOnlyStaker_bonusOnlyWithNewLock() public {
        _stake(alice, 100_000_000e18, 3);
        _fund(carol, 10_000_000e18);
        _tradeAndHarvest();
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 snap = vm.snapshotState();

        uint256 r0 = st.bonusReserve();
        vm.prank(alice);
        uint256 added = st.compound(0, 0, type(uint256).max);
        assertEq(st.bonusReserve(), r0, "sin bonus");
        vm.prank(alice);
        st.requestUnstake(added);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        uint256 b0 = NLYRA.balanceOf(alice);
        vm.prank(alice);
        st.withdraw();
        assertEq(NLYRA.balanceOf(alice) - b0, added, "sale solo el premio, sin bonus");
        vm.revertToState(snap);

        vm.prank(alice);
        uint256 addedL = st.compound(0, 3, type(uint256).max);
        uint256 bonus = r0 - st.bonusReserve();
        assertGt(bonus, 0);
        assertEq(bonus, ((addedL - bonus) * 500) / 10000, "bonus = 5% del compuesto");
        RealYieldStaking.Position memory p = st.positionsOf(alice)[1];
        assertEq(p.amount, addedL);
        // el bonus queda trabado en el lock: ni flexible ni retiro antes de vencer
        vm.prank(alice);
        vm.expectRevert(RealYieldStaking.InsufficientBalance.selector);
        st.requestUnstake(1);
        vm.warp(vm.getBlockTimestamp() + 29 days);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RealYieldStaking.StillLocked.selector, p.unlockTime));
        st.withdrawLocked(1);
        _checkSolvency(_users(), true);
    }
}
