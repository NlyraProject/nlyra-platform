// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ForkBase} from "../ForkBase.sol";

/// REGRESION R2-FC-3 / hallazgo E. Antes: 91 aportes de 1M cada 23h50m -> eligibleBalance = 10 (todo el
/// DCA afuera durante 90 dias). Ahora cada aporte queda afuera solo su dia UTC y el siguiente.
contract V_FixReview_R2_FC_3 is ForkBase {
    function test_dca_matures() public {
        _stake(alice, 10e18, 0); // tiny aged base
        vm.warp(vm.getBlockTimestamp() + 2 days);
        assertEq(st.eligibleBalance(alice), 10e18);
        // 90 days, 1M every 23h50m (bot jitter)
        uint256 t0 = vm.getBlockTimestamp();
        uint256 n;
        while (vm.getBlockTimestamp() < t0 + 90 days) {
            vm.warp(vm.getBlockTimestamp() + 23 hours + 50 minutes);
            _stake(alice, 1_000_000e18, 0);
            ++n;
        }
        uint256 staked = st.stakeOf(alice);
        uint256 elig = st.eligibleBalance(alice);
        emit log_named_uint("deposits", n);
        emit log_named_uint("stakeOf", staked / 1e18);
        emit log_named_uint("eligible", elig / 1e18);
        assertEq(staked, 10e18 + n * 1_000_000e18);
        // solo los <= 3 aportes de hoy y ayer quedan afuera
        assertGe(elig, staked - 3_000_000e18);
        assertLe(elig, staked - 1_000_000e18);
    }

    /// lo mismo con locks (cada _openLock marca un aumento)
    function test_lock_increases_mature() public {
        _stake(alice, 100e18, 0);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        for (uint256 i; i < 20; ++i) {
            vm.warp(vm.getBlockTimestamp() + 23 hours);
            _stake(alice, 1_000e18, 1);
        }
        assertGe(st.eligibleBalance(alice), 100e18 + 17_000e18);
    }
}
