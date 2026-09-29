// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RealYieldStaking} from "../../src/RealYieldStaking.sol";
import {ForkBase} from "../ForkBase.sol";
import "forge-std/console.sol";

/// REGRESION R2-FC-1 / hallazgo D. Antes: compound diario a lock -> 31 compounds y despues
/// TooManyPositions. Ahora el bot compone siempre dentro del mismo lock.
contract V_FixReview_R2_FC_1 is ForkBase {
    function setUp() public override {
        super.setUp();
        _stake(bob, 100_000_000e18, 0);
        _fund(carol, 50_000_000e18);
    }

    function _donateAndSweep(uint256 amt) internal {
        _giveNlyra(address(st), amt);
        st.sweepDonations();
    }

    /// 1) compound diario a 30d dentro del lock 0 durante 60 dias: nunca revierte, un solo slot.
    function test_daily30_intoSameLock_noCap() public {
        _stake(alice, 100_000_000e18, 3);
        uint256 ok;
        for (uint256 d; d < 60; ++d) {
            if (d % 7 == 0) _donateAndSweep(7_000_000e18);
            vm.warp(vm.getBlockTimestamp() + 1 days);
            vm.prank(alice);
            st.compound(0, 3, 0);
            ++ok;
        }
        console.log("compounds diarios a 30d en el mismo lock:", ok);
        assertEq(ok, 60);
        assertEq(st.positionsOf(alice).length, 1);
        // el lock sigue vigente (cada compound lo re-lockea 30 dias desde ese momento)
        assertGe(st.positionsOf(alice)[0].unlockTime, block.timestamp + 29 days);
        // FLEX sigue funcionando (sin bonus)
        _donateAndSweep(1_000_000e18);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(alice);
        st.compound(0, 0, type(uint256).max);
        _checkSolvency(_users(), true);
    }

    /// 2) Tambien a lock nuevo cada 3 dias, liberando los vencidos: nunca se llega al tope.
    function test_every3days_newLock_neverCaps() public {
        _stake(alice, 100_000_000e18, 3);
        uint256 maxOpen;
        for (uint256 d; d < 120; d += 3) {
            if (d % 7 < 3) _donateAndSweep(3_000_000e18);
            vm.warp(vm.getBlockTimestamp() + 3 days);
            RealYieldStaking.Position[] memory ps = st.positionsOf(alice);
            for (uint256 i; i < ps.length; ++i) {
                if (ps[i].amount != 0 && block.timestamp >= ps[i].unlockTime) {
                    vm.prank(alice);
                    st.withdrawLocked(i);
                }
            }
            vm.prank(alice);
            st.compound(0, 3, type(uint256).max);
            ps = st.positionsOf(alice);
            uint256 open;
            for (uint256 i; i < ps.length; ++i) if (ps[i].amount != 0) ++open;
            if (open > maxOpen) maxOpen = open;
        }
        console.log("max locks abiertos compound c/3 dias:", maxOpen);
        assertLe(maxOpen, 32);
    }
}
