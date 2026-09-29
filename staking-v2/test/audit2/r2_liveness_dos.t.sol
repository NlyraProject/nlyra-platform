// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ForkBase} from "../ForkBase.sol";
import {RealYieldStaking} from "../../src/RealYieldStaking.sol";
import {NlyraFeeSplitter} from "../../src/NlyraFeeSplitter.sol";

/// Ronda 2 - liveness / DoS. Mide gas en estados extremos y verifica salidas en pausa.
contract R2LivenessDos is ForkBase {
    function _g(string memory l, uint256 g0) internal {
        emit log_named_uint(l, g0 - gasleft());
    }

    /// 4 wallets x 32 locks de 2 wei (extra = 1 o 2 wei) => bajas de boost en medianoches seguidas,
    /// despues nadie toca nada por `gap` dias. Mide la primera accion.
    function _dustDrops() internal {
        address[4] memory us = [alice, bob, carol, dave];
        for (uint256 u; u < 4; ++u) {
            _giveNlyra(us[u], 1_000e18);
            vm.prank(us[u]);
            NLYRA.approve(address(st), type(uint256).max);
        }
        _stake(owner, 1_000e18, 0);
        _tradeAndHarvest();
        for (uint256 d; d < 128; ++d) {
            vm.prank(us[d % 4]);
            st.stakeLocked(2, uint8(2 + (d / 4) % 2)); // 14d (extra 1 wei) / 30d (extra 2 wei)
            vm.warp(vm.getBlockTimestamp() + 1 days);
        }
    }

    function test_r2_gas_dustDropsThenGap1y() public {
        _dustDrops();
        vm.warp(vm.getBlockTimestamp() + 365 days);
        vm.prank(owner);
        uint256 g = gasleft();
        st.requestUnstake(1e18);
        _g("requestUnstake tras 1 anio + 128 bajas", g);
    }

    function test_r2_gas_gap10y() public {
        _stake(owner, 1_000e18, 0);
        _tradeAndHarvest();
        vm.warp(vm.getBlockTimestamp() + 3650 days);
        vm.prank(owner);
        uint256 g = gasleft();
        st.requestUnstake(1e18);
        _g("requestUnstake tras 10 anios", g);
    }

    /// 32 locks que vencen en 32 medianoches distintas, demote de todos juntos.
    function test_r2_gas_32expiredDistinctMidnights() public {
        _stake(owner, 1_000e18, 0);
        _giveNlyra(alice, 1_000e18);
        vm.prank(alice);
        NLYRA.approve(address(st), type(uint256).max);
        _tradeAndHarvest();
        for (uint256 d; d < 32; ++d) {
            vm.prank(alice);
            st.stakeLocked(1e18, 3);
            vm.warp(vm.getBlockTimestamp() + 1 days);
        }
        vm.warp(vm.getBlockTimestamp() + 200 days);
        vm.prank(alice);
        uint256 g = gasleft();
        st.withdrawLocked(0); // demote de los 32
        _g("withdrawLocked con 32 vencidos (demote)", g);
        vm.startPrank(alice);
        for (uint256 i = 1; i < 32; ++i) st.withdrawLocked(i);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        st.withdraw();
        st.claim(RealYieldStaking.OutMode.AS_IS, 0);
        vm.stopPrank();
        assertEq(NLYRA.balanceOf(alice) >= 1_000e18, true, "principal completo");
        address[] memory u = new address[](2);
        u[0] = alice;
        u[1] = owner;
        _checkSolvency(u, true);
    }

    /// En pausa se puede salir de todo: flexible, lock vencido, cooldown y premios. Y la pausa ya no se
    /// puede renovar (hallazgo B).
    function test_r2_pause_everyExitWorks() public {
        _stake(alice, 100e18, 0);
        _stake(bob, 100e18, 1);
        _tradeAndHarvest();
        vm.warp(vm.getBlockTimestamp() + 31 days);
        vm.prank(owner);
        st.pause();
        vm.prank(alice);
        st.requestUnstake(100e18);
        vm.prank(bob);
        st.withdrawLocked(0);
        vm.prank(alice);
        st.claim(RealYieldStaking.OutMode.AS_IS, 0);
        vm.prank(bob);
        st.claim(RealYieldStaking.OutMode.AS_IS, 0);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(owner);
        vm.expectRevert(); // PauseCooldown: no se renueva
        st.pause();
        vm.prank(alice);
        st.withdraw();
        vm.prank(bob);
        st.withdraw();
        assertGe(NLYRA.balanceOf(alice), 100e18);
        assertGe(NLYRA.balanceOf(bob), 100e18);
        assertEq(st.totalStaked(), 0);
        assertEq(st.totalCooling(), 0);
    }

    /// Harvest con saldo de polvo en el splitter: no revierte ni traba el staking (ahora tampoco revierte
    /// con el splitter vacio).
    function test_r2_harvest_dustOnly() public {
        _stake(alice, 100e18, 0);
        _tradeAndHarvest();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _giveNlyra(address(sp), 1);
        sp.harvest();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _trade(1 ether, 1);
        sp.harvest();
        vm.prank(alice);
        st.requestUnstake(100e18);
    }
}
