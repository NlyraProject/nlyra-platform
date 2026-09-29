// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ForkBase} from "../ForkBase.sol";
import {RealYieldStaking} from "../../src/RealYieldStaking.sol";
import {console2} from "forge-std/Test.sol";

/// REGRESION hallazgo 2 (antes: sin kick, un lock vencido de 90d seguia cobrando 2,5x -> Alice 7,14 WETH
/// contra 2,86 de Bob; el kick tardio no devolvia nada; y el lock vencido salia sin cooldown).
/// Ahora el boost se apaga solo a la medianoche de vencimiento (para el total y para el usuario), el
/// kick es opcional y salir de un lock vencido pasa por el cooldown de 2 dias.
contract VLocksExpiredLockBoost is ForkBase {
    function _setupExpired() internal returns (uint64 unlock) {
        _stake(alice, 10_000_000 ether, 3); // 30d 2x
        _stake(bob, 10_000_000 ether, 0);
        assertEq(st.boostedBalanceOf(alice), 20_000_000 ether);
        unlock = st.positionsOf(alice)[0].unlockTime;
    }

    /// Stream que empieza con el lock ya vencido: con o sin kick, 50/50.
    function test_v_expiredLockNoBoostWithoutKick() public {
        uint64 unlock = _setupExpired();
        vm.warp(uint256(unlock) + 1 days);
        deal(address(WETH), address(sp), 20 ether);
        sp.harvest();
        (uint256 a0,) = st.earned(alice);
        (uint256 b0,) = st.earned(bob);
        uint256 snap = vm.snapshotState();

        // A) nadie kickea en 7 dias
        vm.warp(vm.getBlockTimestamp() + 7 days);
        (uint256 aA,) = st.earned(alice);
        (uint256 bA,) = st.earned(bob);
        uint256 alNo = aA - a0;
        uint256 bobNo = bA - b0;
        // B) kick apenas empieza
        vm.revertToState(snap);
        st.kick(alice, 0);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        (uint256 aB,) = st.earned(alice);
        (uint256 bB,) = st.earned(bob);
        uint256 alK = aB - a0;
        uint256 bobK = bB - b0;
        console2.log("NO KICK  alice / bob WETH", alNo, bobNo);
        console2.log("KICKED   alice / bob WETH", alK, bobK);
        assertApproxEqRel(alNo * 1e18 / (alNo + bobNo), 0.5e18, 1e12, "sin kick: 50%");
        assertApproxEqAbs(alNo, alK, 10, "kick no cambia nada");
        assertApproxEqAbs(bobNo, bobK, 10);
        _checkSolvency(_users(), true);
    }

    /// Stream que cruza el vencimiento: el boost vale EXACTO hasta la medianoche de vencimiento.
    function test_v_boostEndsExactlyAtExpiry_noKeeper() public {
        uint64 unlock = _setupExpired();
        vm.warp(uint256(unlock) - 3.5 days);
        deal(address(WETH), address(sp), 20 ether);
        (uint256 w0,) = _rewardBal();
        sp.harvest();
        (uint256 w1,) = _rewardBal();
        uint256 total = w1 - w0;
        vm.warp(vm.getBlockTimestamp() + 7 days); // nadie toca nada
        (uint256 aw,) = st.earned(alice);
        (uint256 bw,) = st.earned(bob);
        // 3,5 dias a 20:10 y 3,5 dias a 10:10
        uint256 expA = (total * 20) / 30 / 2 + total / 4;
        console2.log("alice", aw, "esperado", expA);
        assertApproxEqRel(aw, expA, 1e12);
        assertApproxEqRel(aw + bw, total, 1e12);
        // y al liquidar (cualquier accion de alice) cobra exactamente eso
        vm.prank(alice);
        st.claim(RealYieldStaking.OutMode.AS_IS, 0);
        assertEq(WETH.balanceOf(alice), aw);
        assertEq(st.boostedBalanceOf(alice), 10_000_000 ether);
        _checkSolvency(_users(), true);
    }

    /// Salir de un lock vencido: 2 dias de cooldown sin ganar, igual que el flexible.
    function test_v_expiredLockExitsThroughCooldown() public {
        uint64 unlock = _setupExpired();
        vm.warp(unlock);
        deal(address(WETH), address(sp), 10 ether);
        sp.harvest();
        vm.prank(alice);
        st.withdrawLocked(0);
        assertEq(NLYRA.balanceOf(alice), 0, "no sale en el acto");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RealYieldStaking.CooldownActive.selector, uint64(block.timestamp + 2 days)));
        st.withdraw();
        (uint256 e0,) = st.earned(alice);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        (uint256 e1,) = st.earned(alice);
        assertEq(e1, e0, "en cooldown no gana");
        vm.prank(alice);
        st.withdraw();
        assertEq(NLYRA.balanceOf(alice), 10_000_000 ether);
    }

    function test_v_kickBeforeExpiryReverts() public {
        uint64 unlock = _setupExpired();
        vm.warp(uint256(unlock) - 1);
        vm.expectRevert(abi.encodeWithSelector(RealYieldStaking.StillLocked.selector, unlock));
        st.kick(alice, 0);
        vm.warp(unlock);
        vm.prank(bob);
        uint256 g = gasleft();
        st.kick(alice, 0);
        console2.log("kick gas", g - gasleft());
        assertEq(st.boostedBalanceOf(alice), 10_000_000 ether);
    }
}
