// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ForkBase} from "../ForkBase.sol";
import {IERC20} from "oz/token/ERC20/IERC20.sol";
import {RealYieldStaking} from "../../src/RealYieldStaking.sol";

/// Hallazgo G (regresion): WETH (aeWETH, proxy) y USDG (Paxos, UUPS, pausable) son actualizables por
/// terceros. Si WETH se rompe (toda transfer y balanceOf revierten) los premios quedan trabados (atomico,
/// sin perdida) pero el PRINCIPAL sale igual: requestUnstake, withdrawLocked y withdraw nunca llaman a
/// WETH ni a USDG.
contract VTokensTok1Test is ForkBase {
    function test_wethBroken_rewardsTrapped_principalExits() public {
        _stake(alice, 1_000_000e18, 0);
        _stake(bob, 1_000_000e18, 1);
        _tradeAndHarvest();
        vm.warp(vm.getBlockTimestamp() + 7 days);
        (uint256 ew, uint256 en) = st.earned(alice);
        assertGt(ew, 0);
        assertGt(en, 0);

        // WETH "roto": toda transfer y balanceOf revierten (simula upgrade/pausa del admin del proxy)
        vm.mockCallRevert(address(WETH), abi.encodeWithSelector(IERC20.transfer.selector), "WETH_BROKEN");
        vm.mockCallRevert(address(WETH), abi.encodeWithSelector(IERC20.balanceOf.selector), "WETH_BROKEN");

        RealYieldStaking.OutMode[4] memory modes = [
            RealYieldStaking.OutMode.AS_IS,
            RealYieldStaking.OutMode.ALL_ETH,
            RealYieldStaking.OutMode.ALL_NLYRA,
            RealYieldStaking.OutMode.ALL_USDG
        ];
        for (uint256 i; i < 4; ++i) {
            vm.prank(alice);
            vm.expectRevert();
            st.claim(modes[i], 0);
        }
        vm.prank(alice);
        vm.expectRevert();
        st.compound(0, 0, type(uint256).max);
        // harvest y sweepDonations tambien revierten (WETH.balanceOf)
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.expectRevert();
        sp.harvest();
        vm.expectRevert();
        st.sweepDonations();

        // premios intactos (atomico) pero sin salida NLYRA-only
        (uint256 ew2, uint256 en2) = st.earned(alice);
        assertGe(ew2, ew);
        assertGe(en2, en);

        // principal flexible sale igual
        vm.prank(alice);
        st.requestUnstake(1_000_000e18);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        uint256 b0 = NLYRA.balanceOf(alice);
        vm.prank(alice);
        st.withdraw();
        assertEq(NLYRA.balanceOf(alice) - b0, 1_000_000e18, "principal completo");

        // un lock vencido tambien sale (withdrawLocked -> cooldown -> withdraw)
        vm.warp(st.positionsOf(bob)[0].unlockTime);
        vm.prank(bob);
        st.withdrawLocked(0);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        uint256 bb0 = NLYRA.balanceOf(bob);
        vm.prank(bob);
        st.withdraw();
        assertEq(NLYRA.balanceOf(bob) - bb0, 1_000_000e18, "lock completo");

        // si WETH se arregla, todo vuelve
        vm.clearMockedCalls();
        vm.prank(alice);
        st.claim(RealYieldStaking.OutMode.AS_IS, 0);
        (ew2, en2) = st.earned(alice);
        assertEq(ew2 + en2, 0);
        _checkSolvency(_users(), true);
    }

    /// USDG roto (pausado/congelado, o con un upgrade que revierte todo): el principal ni lo toca.
    function test_usdgBroken_principalExits() public {
        _stake(alice, 1_000_000e18, 0);
        vm.mockCallRevert(address(USDG), bytes(""), "USDG_BROKEN");
        vm.prank(alice);
        st.requestUnstake(1_000_000e18);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(alice);
        st.withdraw();
        assertEq(NLYRA.balanceOf(alice), 1_000_000e18);
    }
}
