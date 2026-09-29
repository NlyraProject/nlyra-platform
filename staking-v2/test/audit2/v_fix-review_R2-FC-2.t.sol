// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RealYieldStaking} from "../../src/RealYieldStaking.sol";
import {ForkBase} from "../ForkBase.sol";
import "forge-std/console.sol";

/// REGRESION R2-FC-2 / hallazgo A. Antes: con ~98% del peso, auto-donarse 50M y componer a lock dejaba
/// +3,92M netos (bonus de la reserva). Ahora lo donado no es elegible: bonus 0 y el atacante pierde.
contract VFixReviewR2FC2 is ForkBase {
    /// devuelve (ganancia neta firmada del atacante, bonus tomado)
    function _run(uint256 attackerStake, uint8 attackerTier, uint256 otherStake, uint256 D)
        internal
        returns (int256 net, uint256 bonus)
    {
        _fund(carol, 10_000_000e18);
        _stake(bob, otherStake, 0);
        _stake(alice, attackerStake, attackerTier);
        _giveNlyra(alice, D);
        vm.prank(alice);
        NLYRA.transfer(address(st), D);
        st.sweepDonations(); // la pone a streamear cualquiera
        vm.warp(vm.getBlockTimestamp() + 7 days);
        uint256 r0 = st.bonusReserve();
        vm.prank(alice);
        uint256 added = st.compound(0, 3, type(uint256).max);
        bonus = r0 - st.bonusReserve();
        vm.warp(vm.getBlockTimestamp() + 31 days);
        uint256 pid = st.positionsOf(alice).length - 1;
        vm.startPrank(alice);
        st.withdrawLocked(pid);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        st.withdraw();
        vm.stopPrank();
        assertEq(NLYRA.balanceOf(alice), added);
        net = int256(added) - int256(D);
        _checkSolvency(_users());
    }

    /// share = 200/205 = 97,6% -> antes ganaba; ahora pierde y no toca la reserva
    function test_dominant_noLongerProfits() public {
        (int256 net, uint256 bonus) = _run(100_000_000e18, 3, 5_000_000e18, 50_000_000e18);
        console.log("bonus", bonus / 1e18);
        console.logInt(net / 1e18);
        assertEq(bonus, 0);
        assertLt(net, 0);
    }

    /// share = 200/300 = 67% -> pierde (como antes)
    function test_nonDominant_loses() public {
        (int256 net,) = _run(100_000_000e18, 3, 100_000_000e18, 50_000_000e18);
        console.logInt(net / 1e18);
        assertLt(net, 0);
    }
}
