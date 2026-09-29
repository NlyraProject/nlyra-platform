// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ForkBase} from "../ForkBase.sol";
import {IERC20} from "oz/token/ERC20/IERC20.sol";
import {RealYieldStaking} from "../../src/RealYieldStaking.sol";
import {NlyraFeeSplitter} from "../../src/NlyraFeeSplitter.sol";

interface IPonsToken {
    function restrictionEndBlock() external view returns (uint256);
}

/// Auditoria ronda 2 (angulo tokens): USDG pausado/congelado solo rompe ALL_USDG; sin approvals colgados.
contract TokErc20EdgesTest is ForkBase {
    bytes4 constant USDG_PAUSED = bytes4(keccak256("ContractPaused()"));
    bytes4 constant USDG_FROZEN = bytes4(keccak256("AddressFrozen()"));

    function _setup() internal {
        _stake(alice, 1_000_000e18, 0);
        _stake(bob, 2_000_000e18, 2);
        _stake(carol, 500_000e18, 1);
        _tradeAndHarvest();
        vm.warp(vm.getBlockTimestamp() + 7 days);
    }

    function test_usdgPausedOrFrozen_onlyAllUsdgBreaks() public {
        _setup();
        (uint256 ew, uint256 en) = st.earned(alice);
        assertGt(ew, 0);
        // USDG pausado / staking congelado: cualquier transfer de USDG revierte
        vm.mockCallRevert(address(USDG), abi.encodeWithSelector(IERC20.transfer.selector), abi.encodeWithSelector(USDG_PAUSED));
        vm.prank(alice);
        vm.expectRevert();
        st.claim(RealYieldStaking.OutMode.ALL_USDG, 0);
        (uint256 ew2, uint256 en2) = st.earned(alice);
        assertEq(ew2, ew, "premio intacto");
        assertEq(en2, en);
        // los demas modos siguen andando
        vm.prank(alice);
        st.claim(RealYieldStaking.OutMode.ALL_ETH, 0);
        vm.prank(bob);
        st.claim(RealYieldStaking.OutMode.AS_IS, 0);
        vm.prank(carol);
        st.compound(0, 3, type(uint256).max);
        // principal sale
        vm.prank(alice);
        st.requestUnstake(1_000_000e18);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(alice);
        st.withdraw();
        assertGe(NLYRA.balanceOf(alice), 1_000_000e18);
        _checkSolvency(_users(), true);
        vm.clearMockedCalls();
    }

    function test_frozenEscrow_claimToReverts_selfClaimWorks() public {
        _setup();
        address escrow = makeAddr("botEscrow");
        vm.mockCallRevert(
            address(USDG), abi.encodeWithSelector(IERC20.transfer.selector, escrow), abi.encodeWithSelector(USDG_FROZEN)
        );
        vm.prank(alice);
        vm.expectRevert();
        st.claimTo(escrow, RealYieldStaking.OutMode.ALL_USDG, 0);
        vm.prank(alice);
        uint256 out = st.claim(RealYieldStaking.OutMode.ALL_USDG, 0);
        assertGt(out, 0);
        assertEq(USDG.balanceOf(address(st)), 0, "sin USDG residual");
    }

    function test_noDanglingAllowances_allModes() public {
        _setup();
        vm.prank(alice);
        st.claim(RealYieldStaking.OutMode.ALL_USDG, 0);
        vm.prank(bob);
        st.claim(RealYieldStaking.OutMode.ALL_NLYRA, 0);
        vm.prank(carol);
        st.compound(0, 1, type(uint256).max);
        address[3] memory spenders = [POOL_NLYRA, POOL_USDG, address(sp)];
        for (uint256 i; i < 3; ++i) {
            assertEq(NLYRA.allowance(address(st), spenders[i]), 0);
            assertEq(WETH.allowance(address(st), spenders[i]), 0);
            assertEq(USDG.allowance(address(st), spenders[i]), 0);
            assertEq(NLYRA.allowance(address(sp), spenders[i]), 0);
            assertEq(WETH.allowance(address(sp), spenders[i]), 0);
        }
        assertEq(NLYRA.allowance(address(sp), address(st)), 0);
        assertEq(WETH.allowance(address(sp), address(st)), 0);
        assertEq(USDG.balanceOf(address(st)), 0);
    }

    function test_nlyraLaunchRestrictionOver() public view {
        assertLt(IPonsToken(address(NLYRA)).restrictionEndBlock(), block.number);
    }
}
