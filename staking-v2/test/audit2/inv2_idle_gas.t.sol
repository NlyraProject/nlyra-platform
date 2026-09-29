// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Inv2Base} from "./inv2_stateful_local.t.sol";
import {RealYieldStaking} from "../../src/RealYieldStaking.sol";
import {console2} from "forge-std/Test.sol";

/// Costo de la primera accion despues de 5 anos sin actividad (una iteracion por medianoche).
contract Inv2IdleGas is Inv2Base {
    function setUp() public {
        _deploy(8);
    }

    function test_idleYearsGas() public {
        h.stakeLocked(0, 1_000_000e18, 3);
        h.stake(1, 1_000_000e18);
        h.harvest(1 ether, 1_000_000e18, 1, 0, 0, 0);
        address u = h.actors(1);
        vm.warp(vm.getBlockTimestamp() + 5 * 365 days);
        (uint256 ew, uint256 en) = st.earned(u);
        vm.prank(u);
        uint256 g = gasleft();
        st.claim(RealYieldStaking.OutMode.AS_IS, 0);
        console2.log("claim gas after 5y idle", g - gasleft());
        assertGt(ew + en, 0);
        assertEq(h.failure(), "");
    }
}
