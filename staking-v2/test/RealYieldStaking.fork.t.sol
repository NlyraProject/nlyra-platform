// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Vm} from "forge-std/Test.sol";
import {IERC20} from "oz/token/ERC20/IERC20.sol";
import {Ownable} from "oz/access/Ownable.sol";
import {RealYieldStaking} from "../src/RealYieldStaking.sol";
import {NlyraFeeSplitter} from "../src/NlyraFeeSplitter.sol";
import {IPonsLaunchLocker} from "../src/interfaces/External.sol";
import {ForkBase} from "./ForkBase.sol";

/// Suite principal. Todas las cuentas de prueba son makeAddr(...) (sin codigo): NUNCA las del mnemonic
/// de anvil, que en esta cadena tienen delegate EIP-7702 (ver anvil-cuentas-envenenadas).
/// Tiers: 0 = flexible 1x, 1 = lock 7d 1.25x, 2 = lock 14d 1.5x, 3 = lock 30d 2x.
contract RealYieldStakingForkTest is ForkBase {
    uint256 constant NEW = type(uint256).max;

    // ------------------------------------------------------------------ flujo completo

    function test_fullFlow_harvestSplitAndBoosts() public {
        _stake(alice, 1_000_000e18, 0); // 1x
        _stake(bob, 1_000_000e18, 2); // 14d 1.5x
        _stake(carol, 1_000_000e18, 3); // 30d 2x
        assertEq(st.totalBoosted(), 4_500_000e18);

        _trade(2 ether, 3);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 tw0 = WETH.balanceOf(TREASURY);
        uint256 tn0 = NLYRA.balanceOf(TREASURY);
        sp.harvest();
        uint256 sw = WETH.balanceOf(address(st));
        (,,,, uint256 ts,,) = st.rewardInfo();
        uint256 sn = NLYRA.balanceOf(address(st)) - ts;
        uint256 tw = WETH.balanceOf(TREASURY) - tw0;
        uint256 tn = NLYRA.balanceOf(TREASURY) - tn0;
        emit log_named_decimal_uint("WETH al staking", sw, 18);
        emit log_named_decimal_uint("NLYRA al staking", sn, 18);
        assertGt(sw, 0, "sin fees WETH");
        assertGt(sn, 0, "sin fees NLYRA");
        // 50/50 (el treasury se lleva el redondeo)
        assertApproxEqAbs(sw, tw, 1);
        assertApproxEqAbs(sn, tn, 1);
        assertLe(sw, tw);

        // stream: a los 3.5 dias, ~la mitad
        vm.warp(vm.getBlockTimestamp() + 3.5 days);
        (uint256 aw,) = st.earned(alice);
        (uint256 bw,) = st.earned(bob);
        (uint256 cw,) = st.earned(carol);
        uint256 half = sw / 2;
        assertApproxEqRel(aw + bw + cw, half, 1e14);
        // reparto por boost 1 : 1.5 : 2
        assertApproxEqRel(bw * 10, aw * 15, 1e12);
        assertApproxEqRel(cw * 10, aw * 20, 1e12);
        _checkSolvency(_users());

        // fin del stream: todos cobran, queda polvo
        vm.warp(vm.getBlockTimestamp() + 4 days);
        vm.prank(alice);
        st.claim(RealYieldStaking.OutMode.AS_IS, 0);
        vm.prank(bob);
        st.claim(RealYieldStaking.OutMode.AS_IS, 0);
        vm.prank(carol);
        st.claim(RealYieldStaking.OutMode.AS_IS, 0);
        uint256 paidW = WETH.balanceOf(alice) + WETH.balanceOf(bob) + WETH.balanceOf(carol);
        uint256 paidN = NLYRA.balanceOf(alice) + NLYRA.balanceOf(bob) + NLYRA.balanceOf(carol);
        assertLe(paidW, sw);
        assertLe(paidN, sn);
        emit log_named_uint("polvo WETH (wei)", sw - paidW);
        emit log_named_uint("polvo NLYRA (wei)", sn - paidN);
        assertLt(sw - paidW, REWARD_DUST(sw), "polvo WETH grande");
        assertLt(sn - paidN, REWARD_DUST(sn), "polvo NLYRA grande");
        _checkSolvency(_users());
    }

    /// polvo tolerado: lo que se pierde al dividir por 7 dias + redondeo por usuario
    function REWARD_DUST(uint256) internal pure returns (uint256) {
        return 7 days + 10;
    }

    function test_harvest_tooSoon_and_permissionless() public {
        _stake(alice, 1e24, 0);
        _tradeAndHarvest();
        _trade(1 ether, 1);
        vm.expectRevert();
        sp.harvest();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(dave); // cualquiera
        sp.harvest();
    }

    function test_notify_onlySplitter() public {
        vm.expectRevert(RealYieldStaking.OnlySplitter.selector);
        st.notifyRewards(0, 0);
        vm.prank(TREASURY);
        vm.expectRevert(RealYieldStaking.OnlySplitter.selector);
        st.notifyRewards(1, 1);
    }

    // ------------------------------------------------------------------ anti-snipe

    function test_snipe_stakeRightBeforeHarvest_getsAlmostNothing() public {
        _stake(alice, 1_000_000e18, 0);
        _trade(2 ether, 3);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        // el sniper entra en el MISMO bloque del harvest, con el mismo tamano que alice
        _stake(dave, 1_000_000e18, 0);
        (uint256 w0,) = _rewardBal();
        sp.harvest();
        (uint256 w1,) = _rewardBal();
        uint256 notified = w1 - w0;
        // y sale 1 minuto despues
        vm.warp(vm.getBlockTimestamp() + 60);
        vm.prank(dave);
        st.requestUnstake(1_000_000e18);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        (uint256 dw,) = st.earned(dave);
        (uint256 aw,) = st.earned(alice);
        emit log_named_uint("sniper WETH", dw);
        emit log_named_uint("notificado WETH", notified);
        // 60 s de 7 dias a mitad del peso = 0,005 % del stream
        assertLe(dw, (notified * 60) / (7 days) / 2 + 1);
        assertGt(aw, (notified * 99) / 100);
        // y el principal le vuelve solo despues del cooldown
        vm.prank(dave);
        st.withdraw();
        assertEq(NLYRA.balanceOf(dave), 1_000_000e18);
    }

    // ------------------------------------------------------------------ claim en cada modo

    function _setupRewards() internal returns (uint256 w, uint256 n) {
        _stake(alice, 1_000_000e18, 0);
        _stake(bob, 2_000_000e18, 3);
        (w, n) = _tradeAndHarvest();
        vm.warp(vm.getBlockTimestamp() + 7 days);
    }

    function _claimModeChecked(RealYieldStaking.OutMode mode, IERC20 tokenOut) internal {
        (uint256 ew, uint256 en) = st.earned(alice);
        assertGt(ew, 0);
        assertGt(en, 0);
        uint256 snap = vm.snapshotState();
        vm.prank(alice);
        uint256 out = st.claim(mode, 0);
        assertGt(out, 0);
        vm.revertToState(snap);
        // minOut por encima de lo posible -> revierte, y no se pierde nada
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RealYieldStaking.Slippage.selector, out, out + 1));
        st.claim(mode, out + 1);
        uint256 b0 = tokenOut.balanceOf(alice);
        vm.prank(alice);
        uint256 out2 = st.claim(mode, out);
        assertEq(out2, out);
        assertEq(tokenOut.balanceOf(alice) - b0, out);
        (uint256 aw, uint256 an) = st.earned(alice);
        assertEq(aw + an, 0);
        (uint256 ae, uint256 ane) = st.earnedBonusEligible(alice);
        assertEq(ae + ane, 0, "el claim tambien limpia la parte elegible");
        _checkSolvency(_users());
    }

    function test_claim_ALL_ETH() public {
        _setupRewards();
        (uint256 ew,) = st.earned(alice);
        _claimModeChecked(RealYieldStaking.OutMode.ALL_ETH, WETH);
        assertGt(WETH.balanceOf(alice), ew); // el NLYRA se vendio a WETH
    }

    function test_claim_ALL_NLYRA() public {
        _setupRewards();
        (, uint256 en) = st.earned(alice);
        _claimModeChecked(RealYieldStaking.OutMode.ALL_NLYRA, NLYRA);
        assertGt(NLYRA.balanceOf(alice), en);
    }

    function test_claim_ALL_USDG() public {
        _setupRewards();
        _claimModeChecked(RealYieldStaking.OutMode.ALL_USDG, USDG);
        emit log_named_decimal_uint("USDG cobrado", USDG.balanceOf(alice), 6);
    }

    function test_claim_AS_IS_and_claimTo() public {
        _setupRewards();
        (uint256 ew, uint256 en) = st.earned(alice);
        address escrow = _fresh("botEscrow");
        vm.prank(alice);
        st.claimTo(escrow, RealYieldStaking.OutMode.AS_IS, 0);
        assertEq(WETH.balanceOf(escrow), ew);
        assertEq(NLYRA.balanceOf(escrow), en);
        assertEq(WETH.balanceOf(alice), 0);
        vm.prank(alice);
        vm.expectRevert(RealYieldStaking.ZeroAmount.selector);
        st.claim(RealYieldStaking.OutMode.AS_IS, 0);
        vm.prank(bob);
        vm.expectRevert(RealYieldStaking.ZeroAddress.selector);
        st.claimTo(address(0), RealYieldStaking.OutMode.AS_IS, 0);
        _checkSolvency(_users());
    }

    function _g(string memory label, uint256 g0) internal {
        emit log_named_uint(label, g0 - gasleft());
    }

    /// Gas de cada accion (storage frio del fork: el real va a ser algo menor). La tabla del README sale
    /// de aca: harvest, stake, stakeLocked por tier, extendLock, claim (4 modos), compound (flex / 30d
    /// nuevo / 30d dentro de un lock existente), requestUnstake, withdraw, withdrawLocked, sweepDonations.
    function test_gas_report() public {
        _setupRewards();
        _fund(dave, 1_000_000e18);
        uint256 snap = vm.snapshotState();
        for (uint8 m; m < 4; ++m) {
            vm.revertToState(snap);
            vm.prank(alice);
            uint256 g = gasleft();
            st.claim(RealYieldStaking.OutMode(m), 0);
            _g(string.concat("gas claim modo ", vm.toString(m)), g);
        }
        vm.revertToState(snap);
        vm.prank(alice);
        uint256 g2 = gasleft();
        st.compound(0, 0, NEW);
        _g("gas compound flex", g2);
        vm.revertToState(snap);
        vm.prank(alice);
        g2 = gasleft();
        st.compound(0, 3, NEW);
        _g("gas compound 30d lock nuevo (con bonus)", g2);
        vm.revertToState(snap);
        // bob tiene un lock de 30d abierto (id 0): compound dentro de ese lock
        vm.prank(bob);
        g2 = gasleft();
        st.compound(0, 3, 0);
        _g("gas compound 30d dentro de lock existente (con bonus)", g2);
        vm.revertToState(snap);
        _trade(1 ether, 1);
        uint256 g3 = gasleft();
        sp.harvest();
        _g("gas harvest (con collectFees, 2 tramos)", g3);
        vm.revertToState(snap);
        deal(address(WETH), address(st), WETH.balanceOf(address(st)) + 1 ether);
        g3 = gasleft();
        st.sweepDonations();
        _g("gas sweepDonations (abre tramo)", g3);
        // stake / locks
        vm.revertToState(snap);
        _giveNlyra(carol, 6_000e18);
        vm.startPrank(carol);
        NLYRA.approve(address(st), type(uint256).max);
        g2 = gasleft();
        st.stake(1_000e18);
        _g("gas stake (primero)", g2);
        g2 = gasleft();
        st.stake(1_000e18);
        _g("gas stake (segundo)", g2);
        g2 = gasleft();
        st.stakeLocked(1_000e18, 1);
        _g("gas stakeLocked 7d", g2);
        g2 = gasleft();
        st.stakeLocked(1_000e18, 2);
        _g("gas stakeLocked 14d", g2);
        g2 = gasleft();
        st.stakeLocked(1_000e18, 3);
        _g("gas stakeLocked 30d", g2);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        g2 = gasleft();
        st.extendLock(0, 3);
        _g("gas extendLock 7d->30d (activo)", g2);
        g2 = gasleft();
        st.requestUnstake(500e18);
        _g("gas requestUnstake", g2);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        g2 = gasleft();
        st.withdraw();
        _g("gas withdraw", g2);
        vm.warp(vm.getBlockTimestamp() + 31 days);
        g2 = gasleft();
        st.extendLock(1, 2);
        _g("gas extendLock de lock vencido (liquida al vencimiento)", g2);
        g2 = gasleft();
        st.withdrawLocked(2);
        _g("gas withdrawLocked (a cooldown)", g2);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ compound

    function _compoundLog() internal returns (uint256 nr, uint256 bought, uint256 bonus) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == RealYieldStaking.Compounded.selector) {
                (, nr, bought, bonus,,) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint8, uint256));
            }
        }
    }

    function test_compound_noReserve_bonusZero() public {
        _setupRewards();
        (uint256 ew, uint256 en) = st.earned(alice);
        uint256 s0 = st.stakeOf(alice);
        vm.prank(alice);
        uint256 added = st.compound(en, 0, NEW); // piso = al menos el premio en NLYRA
        assertGt(added, en); // el WETH compro NLYRA
        assertEq(st.stakeOf(alice), s0 + added);
        assertEq(st.bonusReserve(), 0);
        assertEq(WETH.balanceOf(alice), 0);
        assertGt(ew, 0);
        _checkSolvency(_users(), true);
    }

    /// Con reserva: flexible, 7d y 14d NO cobran bonus; el lock de 30d cobra el 5% exacto de lo ganado
    /// con fees del splitter (aca, todo).
    function test_compound_withReserve_bonusOnlyInto30d() public {
        _setupRewards();
        _fund(dave, 10_000_000e18);
        (uint256 ew, uint256 en) = st.earned(alice);
        (uint256 bw, uint256 bn) = st.earnedBonusEligible(alice);
        assertEq(bw, ew, "todo vino del splitter (WETH)");
        assertEq(bn, en, "todo vino del splitter (NLYRA)");
        uint256 snap = vm.snapshotState();
        for (uint8 t; t < 3; ++t) {
            vm.revertToState(snap);
            vm.recordLogs();
            vm.prank(alice);
            uint256 addedNo = st.compound(0, t, NEW);
            (uint256 nr0, uint256 bought0, uint256 bonus0) = _compoundLog();
            assertEq(bonus0, 0, "sin bonus fuera de 30d");
            assertEq(addedNo, nr0 + bought0);
            assertEq(st.bonusReserve(), 10_000_000e18);
        }
        vm.revertToState(snap);

        vm.recordLogs();
        vm.prank(alice);
        uint256 added = st.compound(0, 3, NEW);
        (uint256 nr, uint256 bought, uint256 bonus) = _compoundLog();
        assertEq(bonus, ((nr + bought) * 500) / 10000, "5%");
        assertEq(added, nr + bought + bonus);
        assertEq(st.bonusReserve(), 10_000_000e18 - bonus);
        // entra como lock nuevo de 30 dias (2x) en el primer slot libre
        RealYieldStaking.Position[] memory ps = st.positionsOf(alice);
        assertEq(ps.length, 1);
        assertEq(ps[0].amount, added);
        assertEq(ps[0].tier, 3);
        assertGe(ps[0].unlockTime, block.timestamp + 30 days);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RealYieldStaking.StillLocked.selector, ps[0].unlockTime));
        st.withdrawLocked(0);
        _checkSolvency(_users(), true);
    }

    /// Hallazgo D: compound dentro de un lock abierto (sin gastar slots), reinicia su vencimiento.
    function test_compound_intoExistingLock() public {
        _setupRewards(); // bob: 2M en lock 30d (id 0)
        _fund(dave, 10_000_000e18);
        RealYieldStaking.Position memory p0 = st.positionsOf(bob)[0];
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 b0 = st.boostedBalanceOf(bob);
        vm.prank(bob);
        uint256 added = st.compound(0, 3, 0);
        RealYieldStaking.Position[] memory ps = st.positionsOf(bob);
        assertEq(ps.length, 1, "no abre posicion nueva");
        assertEq(ps[0].amount, p0.amount + added);
        assertEq(ps[0].tier, 3);
        assertGt(ps[0].unlockTime, p0.unlockTime, "vencimiento reiniciado");
        assertGe(ps[0].unlockTime, block.timestamp + 30 days);
        assertEq(st.boostedBalanceOf(bob), b0 + 2 * added);
        assertEq(st.boostDrop(p0.unlockTime), 0, "la baja vieja se saco");
        assertEq(st.boostDrop(ps[0].unlockTime), ps[0].amount);
        assertLt(st.bonusReserve(), 10_000_000e18, "con bonus");
        // reglas de extend: a un lock de 30d no se puede componer con tier menor; flex no toma posicion
        _tradeAndHarvest();
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.startPrank(bob);
        vm.expectRevert(RealYieldStaking.CannotShorten.selector);
        st.compound(0, 2, 0);
        vm.expectRevert(RealYieldStaking.BadPosition.selector);
        st.compound(0, 0, 0);
        vm.expectRevert(RealYieldStaking.BadPosition.selector);
        st.compound(0, 3, 1);
        vm.stopPrank();
        // 7d -> compound a 14d en el mismo lock sube el tier (sin bonus)
        _stake(carol, 1_000e18, 1);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(carol);
        uint256 addedC = st.compound(0, 2, 0);
        RealYieldStaking.Position memory pc = st.positionsOf(carol)[0];
        assertEq(pc.tier, 2);
        assertEq(pc.amount, 1_000e18 + addedC);
        _checkSolvency(_users(), true);
    }

    function test_compound_reserveSmallerThanBonus() public {
        _setupRewards();
        _fund(dave, 5);
        uint256 s0 = st.stakeOf(alice);
        (, uint256 en) = st.earned(alice);
        vm.prank(alice);
        uint256 added = st.compound(0, 3, NEW);
        assertEq(st.bonusReserve(), 0);
        assertEq(st.stakeOf(alice), s0 + added);
        assertGt(added, en + 5 - 1);
        _checkSolvency(_users(), true);
    }

    function test_compound_slippage_badTier_and_pause() public {
        _setupRewards();
        vm.prank(alice);
        vm.expectRevert();
        st.compound(type(uint256).max, 0, NEW);
        vm.prank(alice);
        vm.expectRevert(RealYieldStaking.BadTier.selector);
        st.compound(0, 4, NEW);
        vm.prank(owner);
        st.pause();
        vm.prank(alice);
        vm.expectRevert(RealYieldStaking.EnforcedPause.selector);
        st.compound(0, 0, NEW);
    }

    // ------------------------------------------------------------------ cooldown y locks

    function test_cooldown_flow() public {
        _stake(alice, 1_000e18, 0);
        _stake(bob, 1_000e18, 0);
        _tradeAndHarvest();
        vm.prank(alice);
        st.requestUnstake(1_000e18);
        assertEq(st.stakeOf(alice), 0);
        vm.prank(alice);
        vm.expectRevert(); // antes de 2 dias
        st.withdraw();
        // lo que esta en cooldown no gana
        (uint256 aw0,) = st.earned(alice);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        (uint256 aw1,) = st.earned(alice);
        assertEq(aw1, aw0);
        vm.prank(alice);
        st.withdraw();
        assertEq(NLYRA.balanceOf(alice), 1_000e18);
        vm.prank(alice);
        vm.expectRevert(RealYieldStaking.NothingCooling.selector);
        st.withdraw();
        // cancelar: vuelve a ganar
        vm.prank(bob);
        st.requestUnstake(400e18);
        vm.prank(bob);
        st.cancelUnstake();
        assertEq(st.stakeOf(bob), 1_000e18);
        assertEq(st.totalBoosted(), 1_000e18);
        // no se puede sacar mas que el flexible
        vm.prank(bob);
        vm.expectRevert(RealYieldStaking.InsufficientBalance.selector);
        st.requestUnstake(1_001e18);
        _checkSolvency(_users());
    }

    /// Los tres locks: vencen a medianoche UTC a los 7/14/30 dias, el boost (1.25x/1.5x/2x) se apaga solo
    /// al vencer (sin kick), y salir pasa por el cooldown de 2 dias como el flexible.
    function test_locks_threeTiers_expire_cooldown_and_kick() public {
        _stake(alice, 1_000e18, 1); // 7d
        _stake(bob, 1_000e18, 2); // 14d
        _stake(carol, 1_000e18, 3); // 30d
        assertEq(st.boostedBalanceOf(alice), 1_250e18);
        assertEq(st.boostedBalanceOf(bob), 1_500e18);
        assertEq(st.boostedBalanceOf(carol), 2_000e18);
        uint64 ua = st.positionsOf(alice)[0].unlockTime;
        uint64 ub = st.positionsOf(bob)[0].unlockTime;
        uint64 uc = st.positionsOf(carol)[0].unlockTime;
        assertEq(ua % 1 days, 0, "vence a medianoche");
        assertEq(ub % 1 days, 0, "vence a medianoche");
        assertEq(uc % 1 days, 0, "vence a medianoche");
        assertGe(ua, block.timestamp + 7 days);
        assertLt(ua, block.timestamp + 8 days);
        assertGe(ub, block.timestamp + 14 days);
        assertLt(ub, block.timestamp + 15 days);
        assertGe(uc, block.timestamp + 30 days);
        assertLt(uc, block.timestamp + 31 days);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RealYieldStaking.StillLocked.selector, ub));
        st.withdrawLocked(0);
        // lock no se puede pasar a cooldown (no es flexible)
        vm.prank(bob);
        vm.expectRevert(RealYieldStaking.InsufficientBalance.selector);
        st.requestUnstake(1);
        vm.expectRevert(abi.encodeWithSelector(RealYieldStaking.StillLocked.selector, uc));
        st.kick(carol, 0);

        vm.warp(ua);
        assertEq(st.boostedBalanceOf(alice), 1_000e18);
        (,,, uint256 tb,,,) = st.rewardInfo();
        assertEq(tb, 1_000e18 + 1_500e18 + 2_000e18);
        vm.warp(ub);
        // sin que nadie haga nada, el peso ya es 1x
        assertEq(st.boostedBalanceOf(bob), 1_000e18);
        (,,, tb,,,) = st.rewardInfo();
        assertEq(tb, 1_000e18 + 1_000e18 + 2_000e18);
        vm.prank(bob);
        st.withdrawLocked(0);
        (RealYieldStaking.Account memory ab,,, uint256 pcb) = st.userInfo(bob);
        assertEq(ab.cooling, 1_000e18, "pasa a cooldown");
        assertEq(ab.cooldownEnd, block.timestamp + 2 days);
        assertEq(pcb, 0, "slot liberado");
        assertEq(NLYRA.balanceOf(bob), 0);
        vm.prank(bob);
        vm.expectRevert(RealYieldStaking.BadPosition.selector);
        st.withdrawLocked(0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RealYieldStaking.CooldownActive.selector, uint64(block.timestamp + 2 days)));
        st.withdraw();
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(bob);
        st.withdraw();
        assertEq(NLYRA.balanceOf(bob), 1_000e18);

        vm.warp(uc + 5 days);
        assertEq(st.boostedBalanceOf(carol), 1_000e18);
        vm.prank(dave);
        st.kick(carol, 0); // cualquiera, opcional: solo pone el storage al dia
        assertEq(st.positionsOf(carol)[0].tier, 0);
        vm.expectRevert(RealYieldStaking.AlreadyKicked.selector);
        st.kick(carol, 0);
        vm.prank(carol);
        st.withdrawLocked(0);
        vm.prank(alice);
        st.withdrawLocked(0);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(carol);
        st.withdraw();
        vm.prank(alice);
        st.withdraw();
        assertEq(NLYRA.balanceOf(carol), 1_000e18);
        assertEq(NLYRA.balanceOf(alice), 1_000e18);
        assertEq(st.totalBoosted(), 0);
        assertEq(st.totalStaked(), 0);
        assertEq(st.totalCooling(), 0);
    }

    function test_extendLock_rules() public {
        _stake(alice, 1_000e18, 3); // 30d
        uint64 u0 = st.positionsOf(alice)[0].unlockTime;
        vm.startPrank(alice);
        // nunca acortar: 30d -> 14d / 7d revierte (tier menor)
        vm.expectRevert(RealYieldStaking.CannotShorten.selector);
        st.extendLock(0, 2);
        vm.expectRevert(RealYieldStaking.CannotShorten.selector);
        st.extendLock(0, 1);
        vm.expectRevert(RealYieldStaking.BadTier.selector);
        st.extendLock(0, 0);
        vm.expectRevert(RealYieldStaking.BadTier.selector);
        st.extendLock(0, 4);
        vm.expectRevert(RealYieldStaking.BadPosition.selector);
        st.extendLock(1, 3);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(RealYieldStaking.BadPosition.selector);
        st.extendLock(0, 3); // no es de bob
        // 30d -> 30d a los 10 dias: reinicia desde ahora, mismo boost
        vm.warp(vm.getBlockTimestamp() + 10 days);
        vm.prank(alice);
        st.extendLock(0, 3);
        uint64 u1 = st.positionsOf(alice)[0].unlockTime;
        assertGe(u1, block.timestamp + 30 days);
        assertGt(u1, u0);
        assertEq(st.boostedBalanceOf(alice), 2_000e18);
        // el vencimiento viejo ya no baja el boost
        assertEq(st.boostDrop(u0), 0);
        assertEq(st.boostDrop(u1), 1_000e18);
        vm.warp(u0 + 1);
        assertEq(st.boostedBalanceOf(alice), 2_000e18);
        // 7d -> 7d, 7d -> 14d y 14d -> 30d suben o mantienen; 14d -> 7d no
        _stake(bob, 1_000e18, 1);
        vm.startPrank(bob);
        st.extendLock(0, 1);
        assertEq(st.boostedBalanceOf(bob), 1_250e18);
        st.extendLock(0, 2);
        assertEq(st.boostedBalanceOf(bob), 1_500e18);
        vm.expectRevert(RealYieldStaking.CannotShorten.selector);
        st.extendLock(0, 1);
        st.extendLock(0, 3);
        vm.stopPrank();
        assertEq(st.boostedBalanceOf(bob), 2_000e18);
        (,,, uint256 tb,,,) = st.rewardInfo();
        assertEq(tb, 4_000e18);
        // un lock vencido (ya en 1x) acepta cualquier tier, incluso uno menor
        vm.warp(uint256(st.positionsOf(bob)[0].unlockTime) + 1);
        vm.prank(bob);
        st.extendLock(0, 1);
        assertEq(st.boostedBalanceOf(bob), 1_250e18);
        _checkSolvency(_users(), true);
    }

    function test_maxPositions_openLocks_and_badTier() public {
        for (uint256 i; i < 32; ++i) _stake(alice, 1e18, uint8(1 + (i % 3)));
        _giveNlyra(alice, 1e18);
        vm.startPrank(alice);
        NLYRA.approve(address(st), 1e18);
        vm.expectRevert(RealYieldStaking.TooManyPositions.selector);
        st.stakeLocked(1e18, 1);
        vm.expectRevert(RealYieldStaking.BadTier.selector);
        st.stakeLocked(1e18, 0);
        vm.expectRevert(RealYieldStaking.BadTier.selector);
        st.stakeLocked(1e18, 4);
        // al liberar un lock vencido, su slot se reusa (el id 6 es un 7d: vuelve a estar disponible)
        vm.warp(st.positionsOf(alice)[6].unlockTime);
        st.withdrawLocked(6);
        st.stakeLocked(1e18, 3);
        vm.stopPrank();
        RealYieldStaking.Position[] memory ps = st.positionsOf(alice);
        assertEq(ps.length, 32);
        assertEq(ps[6].tier, 3);
        (,,, uint256 pc) = st.userInfo(alice);
        assertEq(pc, 32);
    }

    // ------------------------------------------------------------------ periodos sin stakers

    function test_zeroSupply_rewardsRecycled() public {
        (uint256 w, uint256 n) = _tradeAndHarvest(); // nadie stakeado
        assertGt(w, 0);
        vm.warp(vm.getBlockTimestamp() + 3 days); // 3/7 del stream sin nadie
        _stake(alice, 1e18, 0); // 1 NLYRA (polvo de stake)
        vm.warp(vm.getBlockTimestamp() + 5 days); // stream terminado
        (uint256 aw, uint256 an) = st.earned(alice);
        assertApproxEqRel(aw, (w * 4) / 7, 1e15);
        // lo no asignado vuelve en el proximo tramo (sweepDonations, sin tocar el splitter)
        st.sweepDonations();
        vm.warp(vm.getBlockTimestamp() + 7 days);
        (aw, an) = st.earned(alice);
        assertApproxEqAbs(aw, w, 7 days + 10);
        assertApproxEqAbs(an, n, 7 days + 10);
        vm.prank(alice);
        st.claim(RealYieldStaking.OutMode.AS_IS, 0);
        _checkSolvency(_users());
    }

    // ------------------------------------------------------------------ redirect de vuelta / NoFees / donaciones

    function test_noFees_and_donations_and_revertRedirect() public {
        _stake(alice, 1e24, 0);
        _tradeAndHarvest();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        // sin trades ni donaciones: el locker revierte NoFeesToCollect (se tolera) y el harvest igual pasa
        // (hallazgo C: ya no revierte con NothingToHarvest); el staking no abre tramo (polvo)
        uint256 c0 = st.tranches().length;
        vm.expectEmit(address(sp));
        emit NlyraFeeSplitter.CollectSkipped(IPonsLaunchLocker.NoFeesToCollect.selector);
        sp.harvest();
        assertEq(st.tranches().length, c0);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        // donaciones al splitter (WETH, NLYRA y ETH nativo) se reparten igual
        deal(address(WETH), address(sp), 1 ether);
        _giveNlyra(address(sp), 1000e18);
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(sp).call{value: 1 ether}("");
        assertTrue(ok);
        (uint256 w0, uint256 n0) = _rewardBal();
        vm.expectEmit(address(sp));
        emit NlyraFeeSplitter.CollectSkipped(IPonsLaunchLocker.NoFeesToCollect.selector);
        sp.harvest();
        (uint256 w1, uint256 n1) = _rewardBal();
        assertEq(w1 - w0, 1 ether); // (1 WETH + 1 ETH) / 2
        assertEq(n1 - n0, 500e18);

        // el treasury revierte el redirect: el splitter ya no cobra, el treasury si
        vm.prank(TREASURY);
        LOCKER.setFeeRedirect(address(NLYRA), TREASURY);
        _trade(2 ether, 2);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.expectEmit(address(sp));
        emit NlyraFeeSplitter.CollectSkipped(IPonsLaunchLocker.NotAuthorized.selector);
        sp.harvest();
        uint256 tw = WETH.balanceOf(TREASURY);
        vm.prank(TREASURY);
        LOCKER.collectFees(address(NLYRA));
        assertGt(WETH.balanceOf(TREASURY), tw);
        // y el splitter sigue sirviendo para donaciones
        vm.warp(vm.getBlockTimestamp() + 1 days);
        deal(address(WETH), address(sp), 1e15);
        vm.expectEmit(address(sp));
        emit NlyraFeeSplitter.CollectSkipped(IPonsLaunchLocker.NotAuthorized.selector);
        sp.harvest();
        // los stakers siguen cobrando lo ya streameado
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(alice);
        st.claim(RealYieldStaking.OutMode.AS_IS, 0);
        _checkSolvency(_users());
    }

    /// Hallazgo C: fees mandadas directo al staking (Desk/OTC/bots) entran aunque el splitter este en 0:
    /// con el harvest diario (que siempre notifica) o con sweepDonations (cualquiera, 1 vez por dia).
    /// Ninguna de las dos cuenta para el bonus de compound.
    function test_directFees_sweepDonations() public {
        _stake(alice, 1_000_000e18, 0);
        _tradeAndHarvest();
        uint256 c0 = st.tranches().length;
        // polvo: no abre tramo ni consume el intervalo
        deal(address(WETH), address(st), WETH.balanceOf(address(st)) + 1e11);
        st.sweepDonations();
        assertEq(st.tranches().length, c0, "polvo no abre tramo");
        // fee directa de 1 WETH: cualquiera la pone a streamear
        deal(address(WETH), address(st), WETH.balanceOf(address(st)) + 1 ether);
        vm.prank(dave);
        st.sweepDonations();
        RealYieldStaking.Tranche[] memory t = st.tranches();
        assertEq(t.length, c0 + 1);
        assertGe(uint256(t[t.length - 1].rateWeth) * 7 days, 1 ether);
        assertEq(t[t.length - 1].eligWeth, 0, "donacion: no elegible para bonus");
        assertEq(t[t.length - 1].eligNlyra, 0);
        // una vez por dia
        deal(address(WETH), address(st), WETH.balanceOf(address(st)) + 1 ether);
        vm.expectRevert(abi.encodeWithSelector(RealYieldStaking.TooSoon.selector, block.timestamp + 1 days));
        st.sweepDonations();
        // ... pero el harvest del dia la toma igual aunque el splitter este en 0 (sin fees de Pons)
        vm.warp(vm.getBlockTimestamp() + 1 days);
        assertEq(WETH.balanceOf(address(sp)), 0);
        sp.harvest();
        t = st.tranches();
        assertEq(t.length, c0 + 2, "harvest con splitter vacio igual abre tramo");
        assertGe(uint256(t[t.length - 1].rateWeth) * 7 days, 1 ether - 7 days);
        _checkSolvency(_users(), true);
    }

    function test_sweep_foreignToken() public {
        deal(address(USDG), address(sp), 5e6);
        uint256 t0 = USDG.balanceOf(TREASURY);
        sp.sweep(address(USDG));
        assertEq(USDG.balanceOf(TREASURY) - t0, 5e6);
        vm.expectRevert(NlyraFeeSplitter.NotSweepable.selector);
        sp.sweep(address(WETH));
        vm.expectRevert(NlyraFeeSplitter.NotSweepable.selector);
        sp.sweep(address(NLYRA));
    }

    // ------------------------------------------------------------------ owner limitado / pausa

    function test_pause_blocksOnlyNewStakes_bounded() public {
        _stake(alice, 1e24, 0);
        _stake(bob, 1e24, 1);
        _tradeAndHarvest();
        vm.prank(dave);
        vm.expectRevert();
        st.pause();
        vm.prank(owner);
        st.pause();
        assertTrue(st.paused());
        _giveNlyra(carol, 2e18);
        vm.startPrank(carol);
        NLYRA.approve(address(st), 2e18);
        vm.expectRevert(RealYieldStaking.EnforcedPause.selector);
        st.stake(1e18);
        vm.expectRevert(RealYieldStaking.EnforcedPause.selector);
        st.stakeLocked(1e18, 3);
        vm.expectRevert(RealYieldStaking.EnforcedPause.selector);
        st.fundBonusReserve(1e18);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(RealYieldStaking.EnforcedPause.selector);
        st.extendLock(0, 3);
        // salir y cobrar sigue abierto
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.startPrank(alice);
        st.claim(RealYieldStaking.OutMode.ALL_ETH, 0);
        st.requestUnstake(1e24);
        vm.expectRevert(RealYieldStaking.EnforcedPause.selector);
        st.cancelUnstake();
        vm.warp(vm.getBlockTimestamp() + 2 days);
        st.withdraw();
        vm.stopPrank();
        assertEq(NLYRA.balanceOf(alice), 1e24);
        // hallazgo B: no se puede renovar estando activa
        vm.prank(owner);
        vm.expectRevert();
        st.pause();
        vm.prank(owner);
        st.unpause();
        vm.prank(carol);
        st.stake(1e18);
        // ni volver a pausar hasta 30 dias despues del fin (aca, el unpause)
        uint256 allowed = vm.getBlockTimestamp() + 30 days;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RealYieldStaking.PauseCooldown.selector, allowed));
        st.pause();
        vm.prank(owner);
        vm.expectRevert(RealYieldStaking.NotPaused.selector);
        st.unpause();
        vm.warp(allowed);
        vm.prank(owner);
        st.pause();
        // la pausa vence sola a los 30 dias (una clave perdida no traba nada para siempre)
        vm.warp(vm.getBlockTimestamp() + 30 days);
        assertFalse(st.paused());
        vm.prank(carol);
        st.stake(1e18);
    }

    function test_owner_cannotTouchPrincipalOrRewards_norRenounce() public {
        _stake(alice, 1e24, 0);
        _tradeAndHarvest();
        vm.startPrank(owner);
        vm.expectRevert(RealYieldStaking.NotRecoverable.selector);
        st.recoverERC20(address(NLYRA), owner, 1);
        vm.expectRevert(RealYieldStaking.NotRecoverable.selector);
        st.recoverERC20(address(WETH), owner, 1);
        vm.expectRevert(RealYieldStaking.RenounceDisabled.selector);
        st.renounceOwnership();
        vm.stopPrank();
        assertEq(st.owner(), owner);
        // un token ajeno si se rescata
        deal(address(USDG), address(st), 7e6);
        vm.prank(owner);
        st.recoverERC20(address(USDG), owner, 7e6);
        assertEq(USDG.balanceOf(owner), 7e6);
        // callback de swap no se puede llamar desde afuera
        vm.expectRevert(RealYieldStaking.BadCallback.selector);
        st.uniswapV3SwapCallback(1, 0, "");
        vm.prank(POOL_NLYRA);
        vm.expectRevert(RealYieldStaking.BadCallback.selector);
        st.uniswapV3SwapCallback(1e18, 0, "");
        // claimTo al propio staking o al splitter revierte (el premio quedaria suelto)
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.startPrank(alice);
        vm.expectRevert(RealYieldStaking.BadRecipient.selector);
        st.claimTo(address(st), RealYieldStaking.OutMode.AS_IS, 0);
        vm.expectRevert(RealYieldStaking.BadRecipient.selector);
        st.claimTo(address(sp), RealYieldStaking.OutMode.AS_IS, 0);
        vm.stopPrank();
    }

    function test_constructor_rejectsWrongPools_andZeroOwner() public {
        vm.expectRevert(RealYieldStaking.BadPool.selector);
        new RealYieldStaking(
            owner, address(NLYRA), address(WETH), address(USDG), POOL_USDG, POOL_USDG, address(LOCKER), TREASURY,
            5_000, 1 days
        );
        vm.expectRevert(RealYieldStaking.BadPool.selector);
        new RealYieldStaking(
            owner, address(NLYRA), address(WETH), address(USDG), POOL_NLYRA, POOL_NLYRA, address(LOCKER), TREASURY,
            5_000, 1 days
        );
        // hallazgo F: owner 0 rechazado (Ownable)
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new RealYieldStaking(
            address(0), address(NLYRA), address(WETH), address(USDG), POOL_NLYRA, POOL_USDG, address(LOCKER),
            TREASURY, 5_000, 1 days
        );
    }

    /// Los pools reales cumplen CREATE2(factory, token0, token1, fee) con el init code canonico y el
    /// fee tier esperado (1% y 0,01%).
    function test_constructor_realPoolsAreCanonical() public view {
        assertEq(st.POOL_NLYRA(), POOL_NLYRA);
        assertEq(st.POOL_USDG(), POOL_USDG);
        assertEq(st.UNI_V3_FACTORY(), 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA);
        assertEq(st.FEE_NLYRA_POOL(), 10_000);
        assertEq(st.FEE_USDG_POOL(), 100);
    }

    function test_splitter_boundsOnParams() public {
        vm.expectRevert(NlyraFeeSplitter.BadSplit.selector);
        new NlyraFeeSplitter(address(LOCKER), address(NLYRA), address(WETH), address(st), TREASURY, 999, 1 days);
        vm.expectRevert(NlyraFeeSplitter.BadSplit.selector);
        new NlyraFeeSplitter(address(LOCKER), address(NLYRA), address(WETH), address(st), TREASURY, 9_001, 1 days);
        vm.expectRevert(NlyraFeeSplitter.BadInterval.selector);
        new NlyraFeeSplitter(address(LOCKER), address(NLYRA), address(WETH), address(st), TREASURY, 5_000, 23 hours);
        vm.expectRevert(NlyraFeeSplitter.BadInterval.selector);
        new NlyraFeeSplitter(address(LOCKER), address(NLYRA), address(WETH), address(st), TREASURY, 5_000, 7 days + 1);
        vm.expectRevert(NlyraFeeSplitter.NotAContract.selector);
        new NlyraFeeSplitter(alice, address(NLYRA), address(WETH), address(st), TREASURY, 5_000, 1 days);
    }

    // ------------------------------------------------------------------ redondeo / polvo

    function test_dust_tinyAndHugeStakers() public {
        _stake(alice, 1, 0); // 1 wei
        _stake(bob, 300_000_000e18, 3); // ballena 30d
        _tradeAndHarvest();
        vm.warp(vm.getBlockTimestamp() + 7 days);
        (uint256 aw, uint256 an) = st.earned(alice);
        emit log_named_uint("1 wei gana WETH", aw);
        emit log_named_uint("1 wei gana NLYRA", an);
        vm.prank(bob);
        st.claim(RealYieldStaking.OutMode.AS_IS, 0);
        if (aw + an > 0) {
            vm.prank(alice);
            st.claim(RealYieldStaking.OutMode.AS_IS, 0);
        }
        vm.prank(alice);
        st.requestUnstake(1);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(alice);
        st.withdraw();
        assertEq(NLYRA.balanceOf(alice) >= 1, true);
        _checkSolvency(_users());
    }

    // ------------------------------------------------------------------ fuzz

    /// Proporcionalidad: dos stakers, montos y tiers al azar, entrada a mitad del stream.
    function testFuzz_shareProportional(uint96 a, uint96 b, uint8 tb, uint32 delay) public {
        a = uint96(bound(a, 1e15, 1e27));
        b = uint96(bound(b, 1e15, 1e27));
        tb = uint8(bound(tb, 0, 3));
        uint256 d = bound(delay, 0, 6 days);
        _stake(alice, a, 0);
        deal(address(WETH), address(sp), 10 ether);
        (uint256 w0,) = _rewardBal();
        sp.harvest(); // (tambien cobra los fees reales pendientes de la posicion)
        (uint256 w1,) = _rewardBal();
        uint256 total = w1 - w0;
        assertGe(total, 5 ether);
        vm.warp(vm.getBlockTimestamp() + d);
        _stake(bob, b, tb);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        (uint256 aw,) = st.earned(alice);
        (uint256 bw,) = st.earned(bob);
        assertLe(aw + bw, total);
        assertApproxEqAbs(aw + bw, total, 7 days + 10);
        _checkSolvency(_users());
        // tramo compartido: bob recibe (7d - d) con peso bB/(a+bB) (el lock mas corto dura >= 7 dias)
        uint256 boost = tb == 0 ? 10000 : tb == 1 ? 12500 : tb == 2 ? 15000 : 20000;
        uint256 bB = (uint256(b) * boost) / 10000;
        uint256 rate = total / 7 days;
        uint256 expB = (rate * (7 days - d) * bB) / (uint256(a) + bB);
        assertApproxEqAbs(bw, expB, expB / 1e9 + 1e6);
    }

    /// Secuencia al azar de 24 acciones de 4 usuarios (todas las entradas y salidas, tramos, locks que
    /// vencen, extend, compound con bonus a lock nuevo o existente, kick, donaciones + sweep); solvencia
    /// y cuadre exacto despues de cada paso.
    function testFuzz_randomOps_solvent(uint256 seed) public {
        address[] memory us = _users();
        deal(address(WETH), address(sp), 3 ether);
        _giveNlyra(address(sp), 1_000_000e18);
        sp.harvest();
        _fund(dave, 5_000_000e18);
        for (uint256 step; step < 24; ++step) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            _randomOp(us, seed);
            _resetOracle();
            vm.warp(vm.getBlockTimestamp() + bound(seed >> 100, 0, 20 days));
            _checkSolvency(us, true);
        }
    }

    function _randomOp(address[] memory us, uint256 seed) internal {
        address u = us[seed % 4];
        uint256 op = (seed >> 8) % 13;
        uint256 amt = bound(seed >> 16, 1, 5_000_000e18);
        uint8 lt = uint8(1 + ((seed >> 200) % 3));
        (RealYieldStaking.Account memory ac,,, uint256 pc) = st.userInfo(u);
        RealYieldStaking.Position[] memory ps = st.positionsOf(u);
        if (op == 0) {
            _stake(u, amt, 0);
        } else if (op == 1) {
            if (pc < 32) _stake(u, amt, lt);
        } else if (op == 2) {
            vm.prank(u);
            if (ac.flexible > 0) st.requestUnstake(bound(amt, 1, ac.flexible));
        } else if (op == 3) {
            vm.prank(u);
            if (ac.cooling > 0 && block.timestamp >= ac.cooldownEnd) st.withdraw();
        } else if (op == 4) {
            (uint256 ew, uint256 en) = st.earned(u);
            vm.prank(u);
            if (ew + en > 0) st.claim(RealYieldStaking.OutMode.AS_IS, 0);
        } else if (op == 5) {
            if (sp.harvestableIn() == 0) {
                deal(address(WETH), address(sp), bound(seed >> 40, 1, 2 ether));
                _giveNlyra(address(sp), bound(seed >> 60, 0, 3_000_000e18));
                sp.harvest();
            }
        } else if (op == 6 || op == 7 || op == 10) {
            for (uint256 k; k < ps.length; ++k) {
                if (ps[k].amount == 0) continue;
                bool expired = block.timestamp >= ps[k].unlockTime;
                if (op == 6 && expired) {
                    vm.prank(u);
                    st.withdrawLocked(k);
                    break;
                }
                if (op == 7 && (expired || lt >= ps[k].tier)) {
                    vm.prank(u);
                    st.extendLock(k, lt);
                    break;
                }
                if (op == 10 && expired && ps[k].tier != 0) {
                    st.kick(u, k);
                    break;
                }
            }
        } else if (op == 8) {
            vm.prank(u);
            if (ac.cooling > 0) st.cancelUnstake();
        } else if (op == 9) {
            (uint256 ew, uint256 en) = st.earned(u);
            if (ew + en == 0 || ew >= 0.05 ether) return; // compound chico (sin mover demasiado el pool)
            uint8 t = uint8((seed >> 200) % 4);
            uint256 pid = NEW;
            // a veces dentro de un lock abierto (si el tier lo permite)
            if (t != 0 && (seed >> 180) % 2 == 0) {
                for (uint256 k; k < ps.length; ++k) {
                    if (ps[k].amount != 0 && (block.timestamp >= ps[k].unlockTime || t >= ps[k].tier)) {
                        pid = k;
                        break;
                    }
                }
            }
            if (t != 0 && pid == NEW && pc == 32) return;
            vm.prank(u);
            st.compound(0, t, pid);
        } else if (op == 11) {
            deal(address(WETH), address(st), WETH.balanceOf(address(st)) + bound(seed >> 40, 0, 0.5 ether));
            _giveNlyra(address(st), bound(seed >> 60, 0, 2_000_000e18));
            if (block.timestamp >= uint256(st.lastDonationSweep()) + 1 days) st.sweepDonations();
        } else {
            _trade(0.2 ether, 1);
        }
    }

    // ------------------------------------------------------------------ tramos (hallazgo 3)

    /// Cada ingreso se paga completo en SUS 7 dias aunque haya harvests diarios en el medio.
    function test_tranches_eachNotifyPaysIn7Days() public {
        _stake(alice, 1_000_000e18, 0);
        uint256 t0 = vm.getBlockTimestamp(); // (con viaIR, block.timestamp en una local se relee despues de vm.warp)
        deal(address(WETH), address(sp), 14 ether); // 7 WETH (+ los fees reales pendientes) a stakers el dia 0
        (uint256 w0,) = _rewardBal();
        sp.harvest();
        (uint256 w1,) = _rewardBal();
        uint256 lump = w1 - w0;
        uint256 extra; // lo que corresponde de los tramos diarios siguientes a los 7 dias
        for (uint256 d = 1; d < 7; ++d) {
            vm.warp(t0 + d * 1 days);
            deal(address(WETH), address(sp), 0.7 ether); // 0.35 WETH a stakers por dia
            sp.harvest();
            extra += (0.35 ether * (7 - d)) / 7;
        }
        assertEq(st.tranches().length, 7, "7 tramos activos");
        vm.warp(t0 + 7 days);
        assertEq(st.tranches().length, 6, "el tramo del dia 0 termino");
        (uint256 aw,) = st.earned(alice);
        // el dia 0 pagado al 100% (menos polvo) + la parte proporcional de los tramos 1..6
        assertApproxEqAbs(aw, lump + extra, 7 * 7 days + 100);
        vm.warp(t0 + 13 days);
        (aw,) = st.earned(alice);
        assertApproxEqAbs(aw, lump + 6 * 0.35 ether, 7 * 7 days + 100, "todo pagado al dia 13");
        assertEq(st.tranches().length, 0);
        _checkSolvency(_users(), true);
    }

    /// Polvo: el staking ignora montos minimos (el splitter ahora siempre notifica).
    function test_tranches_dustIsIgnored() public {
        _stake(alice, 1_000_000e18, 0);
        deal(address(WETH), address(sp), 10 ether);
        sp.harvest();
        assertEq(st.tranches().length, 1);
        uint64 fin = st.periodFinish();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.deal(dave, 1);
        vm.prank(dave);
        (bool ok,) = address(sp).call{value: 1}("");
        assertTrue(ok);
        sp.harvest(); // 1 wei -> 0 a stakers -> notify sin saldo libre -> sin tramo
        assertEq(st.tranches().length, 1);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        deal(address(WETH), address(sp), 1e12); // 5e11 a stakers: < MIN_NOTIFY_WETH
        vm.expectEmit(false, false, false, false, address(st));
        emit RealYieldStaking.NotifySkipped(0, 0);
        sp.harvest();
        assertEq(st.tranches().length, 1);
        assertEq(st.periodFinish(), fin, "el fin no se mueve");
        _checkSolvency(_users(), true);
    }

    /// Cola llena (solo alcanzable llamando notify directo como el splitter, 1 por hora): con 16 tramos
    /// activos el notify NO fusiona ni estira nada, lo salta y el saldo queda libre para el siguiente.
    function test_tranches_fullQueueSkipsSafely() public {
        _stake(alice, 1_000_000e18, 0);
        for (uint256 i; i < 18; ++i) {
            deal(address(WETH), address(st), WETH.balanceOf(address(st)) + 1 ether);
            RealYieldStaking.Tranche[] memory before = st.tranches();
            vm.prank(address(sp));
            st.notifyRewards(1 ether, 0);
            RealYieldStaking.Tranche[] memory aft = st.tranches();
            for (uint256 j; j < before.length; ++j) assertEq(aft[j].end, before[j].end, "tramo viejo intacto");
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            _checkSolvency(_users(), true);
        }
        assertEq(st.tranches().length, 16);
        vm.warp(vm.getBlockTimestamp() + 8 days);
        (uint256 aw,) = st.earned(alice);
        assertApproxEqAbs(aw, 16 ether, 16 * 7 days + 100);
        // lo que quedo libre (2 WETH) entra en el proximo tramo
        st.sweepDonations();
        vm.warp(vm.getBlockTimestamp() + 7 days);
        (aw,) = st.earned(alice);
        assertApproxEqAbs(aw, 18 ether, 17 * 7 days + 100);
        vm.prank(alice);
        st.claim(RealYieldStaking.OutMode.AS_IS, 0);
        _checkSolvency(_users(), true);
    }

    // ------------------------------------------------------------------ eligibleBalance (hallazgos 7 y E)

    function test_eligibleBalance_twoDayBuckets() public {
        uint256 m = (vm.getBlockTimestamp() / 1 days + 1) * 1 days; // proxima medianoche UTC
        vm.warp(m + 10 hours); // dia D, 10:00
        _stake(alice, 1_000e18, 0);
        assertEq(st.eligibleBalance(alice), 0, "recien stakeado");
        vm.warp(m + 1 days + 9 hours); // D+1, 23 h despues: sigue afuera
        assertEq(st.eligibleBalance(alice), 0);
        vm.warp(m + 2 days); // D+2 00:00 (38 h): cuenta
        assertEq(st.eligibleBalance(alice), 1_000e18);
        _stake(alice, 500e18, 3);
        assertEq(st.eligibleBalance(alice), 1_000e18, "el top-up no cuenta");
        vm.prank(alice);
        st.requestUnstake(400e18);
        assertEq(st.eligibleBalance(alice), 600e18, "las bajas cuentan en el acto");
        vm.warp(m + 4 days);
        assertEq(st.eligibleBalance(alice), 1_100e18);
        vm.prank(alice);
        st.cancelUnstake();
        assertEq(st.eligibleBalance(alice), 1_100e18, "cancelUnstake cuenta como stake nuevo");
        vm.warp(m + 5 days + 23 hours);
        assertEq(st.eligibleBalance(alice), 1_100e18);
        vm.warp(m + 6 days);
        assertEq(st.eligibleBalance(alice), 1_500e18);
    }
}
