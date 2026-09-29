// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/console.sol";
import {RealYieldStaking} from "../../src/RealYieldStaking.sol";
import {R2TrancheEngineTE} from "./r2_tranche_engine_te.t.sol";

/// Verificacion TE-1: costo de catch-up de _updateGlobal. Peor caso de medianoches con baja pendientes =
/// 31 (lock 30d redondeado a la medianoche siguiente; antes 91 con el lock de 90d), sembrado por un
/// atacante con locks de 2 wei.
contract VTranchesTE1 is R2TrancheEngineTE {
    function _seedWorst() internal {
        _stake(alice, 1e18, 0);
        _notifyW(7 ether);
        // 91 medianoches distintas con baja de boost, todas en el futuro: un lock 90d de 2 wei hoy
        // + locks sembrados dia a dia durante 90 dias no aumentan el max de pendientes (horizonte 90d),
        // asi que el peor caso realista: sembrar 1 lock/dia durante 90 dias y luego silencio total.
        address[4] memory w = [makeAddr("a1"), makeAddr("a2"), makeAddr("a3"), makeAddr("a4")];
        for (uint256 d; d < 91; ++d) {
            _stake(w[d / 31], 2, 3); // TIER_30, drop = 4-2 = 2 wei
            _stake(w[3], 2, 2);      // TIER_14 tambien (drop = 3-2 = 1 wei)
            if (d % 30 == 29) { /* w[3] slots: keep <=31 by withdrawing expired */ }
            vm.warp(vm.getBlockTimestamp() + 1 days);
            if (d >= 29) {
                RealYieldStaking.Position[] memory ps = st.positionsOf(w[3]);
                for (uint256 i; i < ps.length; ++i) if (ps[i].amount != 0 && ps[i].unlockTime <= block.timestamp) { vm.prank(w[3]); st.withdrawLocked(i); break; }
            }
        }
    }

    function _measure(uint256 idle) internal returns (uint256 used) {
        vm.warp(vm.getBlockTimestamp() + idle);
        uint256 g0 = gasleft();
        vm.prank(alice);
        st.requestUnstake(1e18);
        used = g0 - gasleft();
    }

    function test_TE1_worst_10y() public {
        _seedWorst();
        uint256 u = _measure(10 * 365 days);
        console.log("requestUnstake after 10y idle, <=31 pending drop days:", u);
        assertLt(u, 32_000_000);
    }

    function test_TE1_worst_25y() public {
        _seedWorst();
        uint256 u = _measure(25 * 365 days);
        console.log("requestUnstake after 25y idle, <=31 pending drop days:", u);
    }

    function test_TE1_plain_1y_no_drops() public {
        _stake(alice, 1e18, 0);
        _notifyW(7 ether);
        uint256 u = _measure(365 days);
        console.log("requestUnstake after 1y idle, no drops:", u);
    }

    /// withdraw() (cooldown ya cumplido) no depende de _updateGlobal
    function test_TE1_withdrawIndependent() public {
        _stake(alice, 1e18, 0);
        vm.prank(alice); st.requestUnstake(1e18);
        vm.warp(vm.getBlockTimestamp() + 40 * 365 days);
        uint256 g0 = gasleft();
        vm.prank(alice); st.withdraw();
        console.log("withdraw after 40y:", g0 - gasleft());
    }
}
