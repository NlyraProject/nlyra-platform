// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ForkBase} from "../ForkBase.sol";

/// REGRESION R2-ECON-2 / hallazgo E. Antes: 100M + 1M cada 23 h durante 62 dias dejaban 162M en stake y
/// solo 100M elegibles; solo una pausa de 24 h maduraba todo. Ahora solo quedan afuera los aportes del
/// dia UTC actual y del anterior.
contract V_R2_ECON_2 is ForkBase {
    function test_recent_matures_underDCA() public {
        address u = alice;
        _stake(u, 100_000_000e18, 0);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        assertEq(st.eligibleBalance(u), 100_000_000e18);
        for (uint256 i; i < 62; ++i) {
            _stake(u, 1_000_000e18, 0);
            vm.warp(vm.getBlockTimestamp() + 23 hours);
        }
        emit log_named_uint("stakeOf", st.stakeOf(u) / 1e18);
        emit log_named_uint("eligible", st.eligibleBalance(u) / 1e18);
        assertEq(st.stakeOf(u), 162_000_000e18);
        // antes: 100M. Ahora solo faltan los <= 3 aportes de las ultimas ~48 h
        assertGe(st.eligibleBalance(u), 159_000_000e18);
    }
}
