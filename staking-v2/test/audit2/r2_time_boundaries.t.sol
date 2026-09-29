// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/console.sol";
import {ForkBase} from "../ForkBase.sol";
import {RealYieldStaking} from "../../src/RealYieldStaking.sol";

contract R2TimeBoundaries is ForkBase {
    function _notifyWeth(uint256 amt) internal {
        deal(address(WETH), address(st), WETH.balanceOf(address(st)) + amt);
        vm.prank(address(sp));
        st.notifyRewards(amt, 0);
    }

    function _nextMidnight(uint256 t) internal pure returns (uint256) {
        return (t / 1 days + 1) * 1 days;
    }

    // lock created at 23:59:59 and at 00:00:00 exactly
    function test_unlock_edges() public {
        uint256 m = _nextMidnight(vm.getBlockTimestamp());
        uint8[3] memory tiers = [1, 2, 3];
        uint256[3] memory durs = [uint256(7 days), 14 days, 30 days];
        for (uint256 k; k < 3; ++k) {
            uint256 snap = vm.snapshotState();
            vm.warp(m - 1);
            _stake(alice, 1e18, tiers[k]);
            vm.warp(m);
            _stake(bob, 1e18, tiers[k]);
            uint64 ua = st.positionsOf(alice)[0].unlockTime;
            uint64 ub = st.positionsOf(bob)[0].unlockTime;
            console.log("23:59:59 lock dur (s)", ua - (m - 1));
            console.log("00:00:00 lock dur (s)", ub - m);
            assertEq(ub - m, durs[k]);
            assertEq(ua - (m - 1), durs[k] + 1);
            vm.revertToState(snap);
        }
    }

    // rewards must be identical whether alice acts at u-1, u, u+1 or never
    function _scenario(uint256 mode) internal returns (uint256 aw, uint256 bw) {
        _stake(alice, 1_000e18, 1);
        _stake(bob, 1_000e18, 0);
        uint64 u = st.positionsOf(alice)[0].unlockTime;
        vm.warp(u - 3 days);
        _notifyWeth(7 ether);
        if (mode == 1) { vm.warp(u - 1); vm.prank(alice); st.kick(alice, 0); }
        if (mode == 2) { vm.warp(u); vm.prank(dave); st.kick(alice, 0); }
        if (mode == 3) { vm.warp(u + 1); vm.prank(dave); st.kick(alice, 0); }
        if (mode == 4) { vm.warp(u); _stake(carol, 1, 0); } // global update exactly at u
        if (mode == 5) { vm.warp(u - 1); _stake(carol, 1, 0); vm.warp(u); _stake(carol, 1, 0); }
        vm.warp(u + 10 days);
        (aw,) = st.earned(alice);
        (bw,) = st.earned(bob);
        vm.prank(alice);
        st.claim(RealYieldStaking.OutMode.AS_IS, 0);
        assertEq(WETH.balanceOf(alice), aw, "view != claim");
    }

    function test_boundary_consistency() public {
        uint256 snap = vm.snapshotState();
        uint256[6] memory a;
        uint256[6] memory b;
        for (uint256 mode; mode < 6; ++mode) {
            vm.revertToState(snap);
            if (mode == 1) {
                // kick before expiry reverts; use a flex top-up instead to force a user update at u-1
                continue;
            }
            (a[mode], b[mode]) = _scenario(mode);
            console.log("mode", mode, a[mode], b[mode]);
        }
        // theoretical: 3 days at 1250/2250 then 4 days at 1000/2000 of 1 ether/day
        uint256 expA = (uint256(3 ether) * 1250) / 2250 + (uint256(4 ether) * 1000) / 2000;
        console.log("expected alice", expA);
        for (uint256 mode; mode < 6; ++mode) {
            if (mode == 1) continue;
            assertApproxEqAbs(a[mode], expA, 1e6, "alice");
            assertApproxEqAbs(a[mode], a[0], 10, "path dependence");
        }
    }

    // user action (flex top-up) at u-1 then nothing: the lock must still drop exactly at u
    function test_userActionAt_uMinus1() public {
        _stake(alice, 1_000e18, 1);
        _stake(bob, 1_000e18, 0);
        uint64 u = st.positionsOf(alice)[0].unlockTime;
        vm.warp(u - 3 days);
        _notifyWeth(7 ether);
        vm.warp(u - 1);
        _stake(alice, 1, 0);
        vm.warp(u + 10 days);
        (uint256 aw,) = st.earned(alice);
        uint256 expA = (uint256(3 ether) * 1250) / 2250 + (uint256(4 ether) * 1000) / 2000;
        assertApproxEqAbs(aw, expA, 1e6);
        vm.prank(alice);
        st.claim(RealYieldStaking.OutMode.AS_IS, 0);
        assertEq(WETH.balanceOf(alice), aw);
        _checkSolvency(_users(), true);
    }

    // extendLock at the exact expiry second and one second before
    function test_extend_at_exact_expiry() public {
        _stake(alice, 1_000e18, 1);
        _stake(bob, 1_000e18, 1);
        uint64 u = st.positionsOf(alice)[0].unlockTime;
        vm.warp(u - 3 days);
        _notifyWeth(7 ether);
        vm.warp(u - 1);
        vm.prank(alice);
        st.extendLock(0, 1);
        vm.warp(u);
        vm.prank(bob);
        st.extendLock(0, 1); // expired this second -> 1x then re-boost
        vm.warp(u + 10 days);
        (uint256 aw,) = st.earned(alice);
        (uint256 bw,) = st.earned(bob);
        console.log("alice/bob", aw, bw);
        assertApproxEqAbs(aw, bw, 1e6, "same boost path");
        _checkSolvency(_users(), true);
    }

    // gas after long inactivity with 90 locks (31 drop midnights pending at most) + years of midnights
    function test_gas_longInactivity() public {
        address[3] memory us = [alice, bob, carol];
        uint256 t0 = _nextMidnight(vm.getBlockTimestamp()) + 1 hours;
        vm.warp(t0);
        for (uint256 d; d < 90; ++d) {
            vm.warp(t0 + d * 1 days);
            _stake(us[d % 3], 1e18, 3);
        }
        _notifyWeth(1 ether);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        _notifyWeth(1 ether);
        uint256 snap = vm.snapshotState();
        uint256[4] memory yrs = [uint256(1), 5, 20, 50];
        for (uint256 k; k < 4; ++k) {
            vm.revertToState(snap);
            vm.warp(vm.getBlockTimestamp() + yrs[k] * 365 days);
            uint256 g0 = gasleft();
            (uint256 ew,) = st.earned(alice);
            uint256 gv = g0 - gasleft();
            _giveNlyra(dave, 1e18);
            vm.startPrank(dave);
            NLYRA.approve(address(st), 1e18);
            g0 = gasleft();
            st.stake(1e18);
            uint256 gs = g0 - gasleft();
            vm.stopPrank();
            console.log("years", yrs[k]);
            console.log("  view earned(alice, 30 expired locks) gas", gv, ew);
            console.log("  first stake gas", gs);
            g0 = gasleft();
            vm.prank(alice);
            st.claim(RealYieldStaking.OutMode.AS_IS, 0);
            console.log("  alice claim after (30 demotes) gas", g0 - gasleft());
        }
    }

    // harvests exactly every 1 day never exceed 7 tranches
    function test_trancheCount_exactDailyHarvest() public {
        _stake(alice, 1e24, 0);
        uint256 maxc;
        for (uint256 i; i < 20; ++i) {
            deal(address(WETH), address(sp), 1 ether);
            sp.harvest();
            uint256 c = st.tranches().length;
            if (c > maxc) maxc = c;
            vm.warp(vm.getBlockTimestamp() + 1 days);
        }
        console.log("max tranches", maxc);
        assertLe(maxc, 7);
    }

    // splitter diario + sweepDonations diario: nunca mas de 14 tramos
    function test_trancheCount_dailyHarvestAndSweep() public {
        _stake(alice, 1e24, 0);
        uint256 maxc;
        for (uint256 i; i < 20; ++i) {
            deal(address(WETH), address(sp), 1 ether);
            sp.harvest();
            vm.warp(vm.getBlockTimestamp() + 12 hours);
            deal(address(WETH), address(st), WETH.balanceOf(address(st)) + 1 ether);
            st.sweepDonations();
            uint256 c = st.tranches().length;
            if (c > maxc) maxc = c;
            vm.warp(vm.getBlockTimestamp() + 12 hours);
        }
        console.log("max tranches", maxc);
        assertEq(maxc, 14);
    }

    function test_edges_pause_cooldown_eligible() public {
        _stake(alice, 1_000e18, 0);
        uint256 t = vm.getBlockTimestamp();
        vm.warp(t + 24 hours - 1);
        assertEq(st.eligibleBalance(alice), 0);
        vm.warp((t / 1 days + 2) * 1 days - 1);
        assertEq(st.eligibleBalance(alice), 0);
        vm.warp((t / 1 days + 2) * 1 days);
        assertEq(st.eligibleBalance(alice), 1_000e18);
        vm.prank(alice);
        st.requestUnstake(100e18);
        uint256 ce = vm.getBlockTimestamp() + 2 days;
        vm.warp(ce - 1);
        vm.prank(alice);
        vm.expectRevert();
        st.withdraw();
        vm.warp(ce);
        vm.prank(alice);
        st.requestUnstake(1e18); // pays matured 100
        assertEq(NLYRA.balanceOf(alice), 100e18);
        vm.prank(owner);
        st.pause();
        uint256 pu = vm.getBlockTimestamp() + 30 days;
        vm.warp(pu - 1);
        assertTrue(st.paused());
        vm.warp(pu);
        assertFalse(st.paused());
        // el proximo pause recien a los 30 dias del fin
        vm.warp(pu + 30 days - 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RealYieldStaking.PauseCooldown.selector, pu + 30 days));
        st.pause();
        vm.warp(pu + 30 days);
        vm.prank(owner);
        st.pause();
    }
}

contract R2TimeGasCold is ForkBase {
    function test_gas_cold_stake_after_inactivity() public {
        address[3] memory us = [alice, bob, carol];
        uint256 t0 = (vm.getBlockTimestamp() / 1 days + 1) * 1 days + 1 hours;
        for (uint256 d; d < 90; ++d) {
            vm.warp(t0 + d * 1 days);
            _stake(us[d % 3], 1e18, 3);
        }
        deal(address(WETH), address(st), 1 ether);
        vm.prank(address(sp));
        st.notifyRewards(1 ether, 0);
        _giveNlyra(dave, 1e18);
        vm.prank(dave);
        NLYRA.approve(address(st), 1e18);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        vm.cool(address(st));
        vm.prank(dave);
        uint256 g0 = gasleft();
        st.stake(1e18);
        console.log("cold stake after 1y with 90 pending drops", g0 - gasleft());
    }
}
