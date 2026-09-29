// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RealYieldStaking} from "../../src/RealYieldStaking.sol";
import {Inv2Base, MToken} from "../audit2/inv2_stateful_local.t.sol";

/// Ronda 3 · transferencia de locks en dos pasos (offerPosition -> acceptPosition / acceptPositionTo).
/// Local (sin fork): contratos reales con mocks en las direcciones CREATE2 que valida el constructor.
/// Cada test cubre una regla del diseno: lock entero tal cual, premios liquidados al que entrega, el que
/// recibe gana desde la transferencia, tope de 32, cooldown, eligibleBalance, bonus, pausa y accesos.
contract R3TransferLocal is Inv2Base {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address mallory = makeAddr("mallory");

    event PositionOffered(address indexed from, uint256 indexed positionId, address indexed to);
    event PositionOfferCancelled(address indexed from, uint256 indexed positionId);
    event PositionTransferred(
        address indexed from,
        uint256 fromId,
        address indexed to,
        uint256 toId,
        uint256 amount,
        uint64 unlockTime,
        uint8 tier,
        address indexed operator
    );

    function setUp() public {
        _deploy(1);
    }

    // ------------------------------------------------------------------ helpers
    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _warp(uint256 dt) internal {
        vm.warp(_now() + dt);
    }

    function _lock(address u, uint256 amt, uint8 tier) internal returns (uint256 id) {
        N.mint(u, amt);
        vm.startPrank(u);
        N.approve(address(st), amt);
        st.stakeLocked(amt, tier);
        vm.stopPrank();
        (, , , uint256 cnt) = st.userInfo(u);
        RealYieldStaking.Position[] memory ps = st.positionsOf(u);
        // el id del lock recien abierto: el ultimo slot ocupado con ese monto y vencimiento futuro
        for (uint256 i = ps.length; i > 0; --i) {
            if (ps[i - 1].amount == amt && ps[i - 1].unlockTime > _now()) return i - 1;
        }
        revert(string.concat("lock no encontrado ", vm.toString(cnt)));
    }

    function _flex(address u, uint256 amt) internal {
        N.mint(u, amt);
        vm.startPrank(u);
        N.approve(address(st), amt);
        st.stake(amt);
        vm.stopPrank();
    }

    /// premio "del splitter" (elegible para bonus): harvest con NLYRA y WETH en el splitter
    function _harvest(uint256 n, uint256 w) internal {
        uint256 lh = sp.lastHarvest();
        if (lh != 0 && _now() < lh + 1 days) vm.warp(lh + 1 days);
        N.mint(address(sp), n);
        W.mint(address(sp), w);
        sp.harvest();
    }

    function _move(address from, uint256 id, address to) internal returns (uint256 nid) {
        vm.prank(from);
        st.offerPosition(id, to);
        vm.prank(to);
        nid = st.acceptPosition(from, id);
    }

    function _totals() internal view returns (uint256 tb, uint256 ts, uint256 tc) {
        (,,, tb, ts, tc,) = st.rewardInfo();
    }

    function _acct(address u) internal view returns (RealYieldStaking.Account memory a) {
        (a,,,) = st.userInfo(u);
    }

    // ------------------------------------------------------------------ lo basico
    function test_transfer_movesWholeLock_totalsUnchanged() public {
        uint256 id = _lock(alice, 1_000e18, 3);
        RealYieldStaking.Position memory p0 = st.positionOf(alice, id);
        (uint256 tb0, uint256 ts0, uint256 tc0) = _totals();
        uint256 drop0 = st.boostDrop(p0.unlockTime);

        vm.expectEmit(address(st));
        emit PositionOffered(alice, id, bob);
        vm.prank(alice);
        st.offerPosition(id, bob);
        assertEq(st.positionOffer(alice, id), bob);

        vm.expectEmit(address(st));
        emit PositionTransferred(alice, id, bob, 0, 1_000e18, p0.unlockTime, 3, bob);
        vm.prank(bob);
        uint256 nid = st.acceptPosition(alice, id);

        assertEq(nid, 0);
        RealYieldStaking.Position memory p1 = st.positionOf(bob, nid);
        assertEq(p1.amount, p0.amount, "monto");
        assertEq(p1.unlockTime, p0.unlockTime, "vencimiento");
        assertEq(p1.tier, p0.tier, "tier");
        assertEq(st.positionOf(alice, id).amount, 0, "slot del que entrega libre");
        assertEq(st.positionOffer(alice, id), address(0), "oferta consumida");
        assertEq(st.stakeOf(alice), 0);
        assertEq(st.stakeOf(bob), 1_000e18);
        assertEq(st.boostedBalanceOf(alice), 0);
        assertEq(st.boostedBalanceOf(bob), 2_000e18, "2x viaja con el lock");
        (uint256 tb1, uint256 ts1, uint256 tc1) = _totals();
        assertEq(tb1, tb0, "peso total igual");
        assertEq(ts1, ts0, "stake total igual");
        assertEq(tc1, tc0, "cooling igual");
        assertEq(st.boostDrop(p0.unlockTime), drop0, "la baja de boost sigue agendada igual");
        (, , , uint256 ca) = st.userInfo(alice);
        (, , , uint256 cb) = st.userInfo(bob);
        assertEq(ca, 0);
        assertEq(cb, 1);
        // la oferta ya no existe: aceptar de nuevo falla
        vm.prank(bob);
        vm.expectRevert(RealYieldStaking.NotOffered.selector);
        st.acceptPosition(alice, id);
    }

    /// Premios: lo devengado hasta la transferencia queda del que entrega (y no cambia despues); el que
    /// recibe gana desde ahi. alice + bob == carol (mismo lock, mismo tiempo) salvo polvo.
    function test_transfer_rewardsSettledToSender_recipientEarnsFromThenOn() public {
        uint256 id = _lock(alice, 1_000e18, 3);
        _lock(carol, 1_000e18, 3);
        _harvest(1_400_000e18, 2 ether);
        _warp(3 days);
        (uint256 aw0, uint256 an0) = st.earned(alice);
        assertGt(aw0, 0);
        _move(alice, id, bob);
        (uint256 aw1, uint256 an1) = st.earned(alice);
        assertEq(aw1, aw0, "WETH del que entrega intacto");
        assertEq(an1, an0, "NLYRA del que entrega intacto");
        (uint256 bw0, uint256 bn0) = st.earned(bob);
        assertEq(bw0 + bn0, 0, "el que recibe no hereda nada");
        _warp(5 days);
        (uint256 aw2, uint256 an2) = st.earned(alice);
        assertEq(aw2, aw0, "el que entrega no gana mas");
        assertEq(an2, an0);
        (uint256 bw, uint256 bn) = st.earned(bob);
        (uint256 cw, uint256 cn) = st.earned(carol);
        assertApproxEqAbs(aw2 + bw, cw, 10, "alice+bob == carol WETH");
        assertApproxEqAbs(an2 + bn, cn, 10, "alice+bob == carol NLYRA");
        assertGt(bw, 0);
        // los dos cobran lo suyo
        vm.prank(alice);
        st.claim(RealYieldStaking.OutMode.AS_IS, 0);
        vm.prank(bob);
        st.claim(RealYieldStaking.OutMode.AS_IS, 0);
        assertEq(W.balanceOf(alice), aw0);
        assertEq(W.balanceOf(bob), bw);
    }

    /// Lock transferido antes de vencer: el boost se apaga exacto al vencimiento en la wallet nueva (igual
    /// que el lock gemelo de carol que nunca se movio), sin keeper.
    function test_transfer_boostEndsExactlyAtUnlock_forRecipient() public {
        uint256 id = _lock(alice, 1_000e18, 1); // 7d, 1.25x
        _lock(carol, 1_000e18, 1);
        _flex(dave(), 1_000e18);
        _harvest(1_400_000e18, 2 ether);
        _warp(2 days);
        _move(alice, id, bob);
        _warp(12 days); // pasa el vencimiento (7-8 dias) y sigue ganando en 1x
        _harvest(700_000e18, 1 ether);
        _warp(3 days);
        (uint256 aw, uint256 an) = st.earned(alice);
        (uint256 bw, uint256 bn) = st.earned(bob);
        (uint256 cw, uint256 cn) = st.earned(carol);
        assertApproxEqAbs(aw + bw, cw, 10);
        assertApproxEqAbs(an + bn, cn, 10);
        assertEq(st.boostedBalanceOf(bob), 1_000e18, "vencido => 1x");
        // kick en la wallet nueva
        vm.prank(mallory);
        st.kick(bob, 0);
        assertEq(st.positionOf(bob, 0).tier, 0);
        vm.expectRevert(RealYieldStaking.BadPosition.selector);
        st.kick(alice, id);
    }

    function dave() internal returns (address) {
        return makeAddr("dave");
    }

    /// "Stakear desde una wallet y retirar desde otra": un lock vencido se transfiere (llega en 1x) y el que
    /// lo recibe lo retira por el cooldown normal.
    function test_transfer_expiredLock_withdrawFromOtherWallet() public {
        uint256 id = _lock(alice, 500e18, 2);
        _warp(16 days);
        _move(alice, id, bob);
        RealYieldStaking.Position memory p = st.positionOf(bob, 0);
        assertEq(p.tier, 0, "llega liquidado a 1x");
        assertEq(st.boostedBalanceOf(bob), 500e18);
        vm.prank(bob);
        st.withdrawLocked(0);
        _warp(2 days);
        vm.prank(bob);
        st.withdraw();
        assertEq(N.balanceOf(bob), 500e18, "bob retira el principal");
        assertEq(N.balanceOf(alice), 0);
        (uint256 tb, uint256 ts, uint256 tc) = _totals();
        assertEq(tb + ts + tc, 0);
    }

    function test_transfer_chain_AtoBtoC_thenExitCleanly() public {
        uint256 id = _lock(alice, 777e18, 3);
        uint256 b = _move(alice, id, bob);
        uint256 c = _move(bob, b, carol);
        assertEq(st.stakeOf(bob), 0);
        assertEq(st.stakeOf(carol), 777e18);
        _warp(31 days);
        vm.prank(carol);
        st.withdrawLocked(c);
        _warp(2 days);
        vm.prank(carol);
        st.withdraw();
        assertEq(N.balanceOf(carol), 777e18);
        (uint256 tb, uint256 ts, uint256 tc) = _totals();
        assertEq(tb + ts + tc, 0, "no queda nada");
    }

    // ------------------------------------------------------------------ slots y tope
    function test_transfer_recipientCapAndSlotReuse() public {
        for (uint256 i; i < 32; ++i) _lock(bob, 1e18, 1);
        uint256 id = _lock(alice, 10e18, 3);
        vm.prank(alice);
        st.offerPosition(id, bob);
        vm.prank(bob);
        vm.expectRevert(RealYieldStaking.TooManyPositions.selector);
        st.acceptPosition(alice, id);
        // bob libera el slot 5 (vencido) y el lock entra justo ahi
        _warp(8 days);
        vm.prank(bob);
        st.withdrawLocked(5);
        vm.prank(bob);
        uint256 nid = st.acceptPosition(alice, id);
        assertEq(nid, 5, "reusa el primer slot libre");
        assertEq(st.positionOf(bob, 5).amount, 10e18);
        assertEq(st.positionsOf(bob).length, 32);
        // el slot de alice queda libre y su proximo lock lo reusa
        uint256 id2 = _lock(alice, 3e18, 1);
        assertEq(id2, id);
    }

    // ------------------------------------------------------------------ cooldown / retiro pedido
    /// El cooldown es de la cuenta: withdrawLocked libera el slot, asi que un lock con retiro pedido ya no
    /// existe; su oferta muere y no se puede ofrecer. El cooling nunca viaja.
    function test_transfer_pendingUnstake_notTransferable_andOfferDies() public {
        uint256 id = _lock(alice, 100e18, 1);
        vm.prank(alice);
        st.offerPosition(id, bob);
        _warp(8 days);
        vm.prank(alice);
        st.withdrawLocked(id);
        assertEq(st.positionOffer(alice, id), address(0), "la oferta muere con el slot");
        vm.prank(bob);
        vm.expectRevert(RealYieldStaking.NotOffered.selector);
        st.acceptPosition(alice, id);
        vm.prank(alice);
        vm.expectRevert(RealYieldStaking.BadPosition.selector);
        st.offerPosition(id, bob);
        // el mismo slot reusado por un lock NUEVO no hereda la oferta vieja
        uint256 id2 = _lock(alice, 100e18, 1);
        assertEq(id2, id);
        vm.prank(bob);
        vm.expectRevert(RealYieldStaking.NotOffered.selector);
        st.acceptPosition(alice, id2);
        // el cooling de alice sigue siendo de alice
        assertEq(_acct(alice).cooling, 100e18);
        assertEq(_acct(bob).cooling, 0);
        // y un flexible en cooldown no es un lock: no hay nada que ofrecer
        _flex(carol, 5e18);
        vm.prank(carol);
        st.requestUnstake(5e18);
        vm.prank(carol);
        vm.expectRevert(RealYieldStaking.BadPosition.selector);
        st.offerPosition(0, bob);
    }

    /// Cualquier cambio del lock borra la oferta: extendLock y compound dentro del lock.
    function test_transfer_offerVoidedByExtendAndCompound() public {
        uint256 id = _lock(alice, 100e18, 1);
        vm.prank(alice);
        st.offerPosition(id, bob);
        vm.prank(alice);
        st.extendLock(id, 3);
        assertEq(st.positionOffer(alice, id), address(0), "extendLock borra la oferta");
        vm.prank(bob);
        vm.expectRevert(RealYieldStaking.NotOffered.selector);
        st.acceptPosition(alice, id);

        vm.prank(alice);
        st.offerPosition(id, bob);
        _harvest(1_000_000e18, 0);
        _warp(1 days);
        vm.prank(alice);
        st.compound(0, 3, id);
        assertEq(st.positionOffer(alice, id), address(0), "compound al lock borra la oferta");
        vm.prank(bob);
        vm.expectRevert(RealYieldStaking.NotOffered.selector);
        st.acceptPosition(alice, id);
    }

    function test_transfer_offerReplacedAndCancelled() public {
        uint256 id = _lock(alice, 100e18, 2);
        vm.prank(alice);
        st.offerPosition(id, bob);
        vm.prank(alice);
        st.offerPosition(id, carol); // reemplaza
        vm.prank(bob);
        vm.expectRevert(RealYieldStaking.NotOffered.selector);
        st.acceptPosition(alice, id);
        vm.expectEmit(address(st));
        emit PositionOfferCancelled(alice, id);
        vm.prank(alice);
        st.cancelPositionOffer(id);
        vm.prank(carol);
        vm.expectRevert(RealYieldStaking.NotOffered.selector);
        st.acceptPosition(alice, id);
        vm.prank(alice);
        vm.expectRevert(RealYieldStaking.NotOffered.selector);
        st.cancelPositionOffer(id);
    }

    // ------------------------------------------------------------------ eligibleBalance (Desk)
    /// Un lock recibido NO cuenta como maduro: queda afuera 24-48 h como cualquier aporte nuevo. Al que lo
    /// entrega le baja en el acto. Un "flash-transfer" para el descuento da 0.
    function test_transfer_eligibleBalance_notMatureForRecipient() public {
        uint256 id = _lock(alice, 1_000e18, 3);
        _warp(3 days);
        assertEq(st.eligibleBalance(alice), 1_000e18, "maduro en alice");
        // bob ya tenia stake maduro propio
        _flex(bob, 50e18);
        _warp(3 days);
        assertEq(st.eligibleBalance(bob), 50e18);
        _move(alice, id, bob);
        assertEq(st.eligibleBalance(alice), 0, "baja en el acto");
        assertEq(st.stakeOf(bob), 1_050e18);
        assertEq(st.eligibleBalance(bob), 50e18, "lo recibido no cuenta");
        uint256 day = _now() / 1 days;
        vm.warp((day + 1) * 1 days + 23 hours); // dia siguiente: sigue afuera
        assertEq(st.eligibleBalance(bob), 50e18);
        vm.warp((day + 2) * 1 days); // pasado manana: cuenta
        assertEq(st.eligibleBalance(bob), 1_050e18);
    }

    /// ida y vuelta en el mismo bloque: tampoco sirve (vuelve como aporte nuevo de alice)
    function test_transfer_flashRoundTrip_givesZeroDiscount() public {
        uint256 id = _lock(alice, 1_000e18, 3);
        _warp(3 days);
        uint256 b = _move(alice, id, bob);
        _move(bob, b, alice);
        assertEq(st.stakeOf(alice), 1_000e18);
        assertEq(st.eligibleBalance(alice), 0);
        assertEq(st.eligibleBalance(bob), 0);
    }

    // ------------------------------------------------------------------ bonus de compound
    /// La parte elegible para bonus es de quien la devengo: no viaja con el lock. El que recibe compone a
    /// 30 dias con bonus solo sobre lo que gano el mismo.
    function test_transfer_bonusEligibility_staysWithSender() public {
        vm.prank(carol);
        N.approve(address(st), type(uint256).max);
        N.mint(carol, 1_000_000e18);
        vm.prank(carol);
        st.fundBonusReserve(1_000_000e18);
        uint256 id = _lock(alice, 1_000e18, 3);
        _harvest(1_400_000e18, 0);
        _warp(3 days);
        (, uint256 ae0) = st.earnedBonusEligible(alice);
        assertGt(ae0, 0);
        _move(alice, id, bob);
        (, uint256 be0) = st.earnedBonusEligible(bob);
        assertEq(be0, 0, "bob no hereda elegibilidad");
        (, uint256 ae1) = st.earnedBonusEligible(alice);
        assertEq(ae1, ae0, "alice la conserva");
        // bob compone sin premios propios: revierte (nada que componer)
        vm.prank(bob);
        vm.expectRevert(RealYieldStaking.ZeroAmount.selector);
        st.compound(0, 3, 0);
        _warp(2 days);
        (, uint256 bn) = st.earned(bob);
        (, uint256 be) = st.earnedBonusEligible(bob);
        uint256 r0 = st.bonusReserve();
        vm.prank(bob);
        st.compound(0, 3, 0);
        assertEq(r0 - st.bonusReserve(), (be * 500) / 10_000, "bonus solo sobre lo de bob");
        assertEq(st.positionOf(bob, 0).amount, 1_000e18 + bn + (be * 500) / 10_000);
        // alice (sin lock) cobra lo suyo; su elegible no se pierde, sale con el claim
        vm.prank(alice);
        st.claim(RealYieldStaking.OutMode.AS_IS, 0);
        assertGt(N.balanceOf(alice), 0);
    }

    // ------------------------------------------------------------------ pausa
    function test_transfer_pauseBlocksOfferAndAccept_cancelStillWorks() public {
        uint256 id = _lock(alice, 100e18, 3);
        vm.prank(alice);
        st.offerPosition(id, bob);
        vm.prank(owner);
        st.pause();
        vm.prank(bob);
        vm.expectRevert(RealYieldStaking.EnforcedPause.selector);
        st.acceptPosition(alice, id);
        vm.prank(bob);
        vm.expectRevert(RealYieldStaking.EnforcedPause.selector);
        st.acceptPositionTo(alice, id, bob);
        vm.prank(alice);
        vm.expectRevert(RealYieldStaking.EnforcedPause.selector);
        st.offerPosition(id, carol);
        vm.prank(alice);
        st.cancelPositionOffer(id); // cancelar anda en pausa
        vm.prank(owner);
        st.unpause();
        vm.prank(alice);
        st.offerPosition(id, bob);
        vm.prank(bob);
        st.acceptPosition(alice, id);
        assertEq(st.stakeOf(bob), 100e18);
    }

    // ------------------------------------------------------------------ accesos
    function test_transfer_accessControl() public {
        uint256 id = _lock(alice, 100e18, 3);
        // sin oferta: nadie acepta (ni el owner del staking)
        vm.prank(owner);
        vm.expectRevert(RealYieldStaking.NotOffered.selector);
        st.acceptPosition(alice, id);
        vm.prank(owner);
        vm.expectRevert(RealYieldStaking.NotOffered.selector);
        st.acceptPositionTo(alice, id, owner);
        // destinos invalidos
        vm.startPrank(alice);
        vm.expectRevert(RealYieldStaking.ZeroAddress.selector);
        st.offerPosition(id, address(0));
        vm.expectRevert(RealYieldStaking.BadRecipient.selector);
        st.offerPosition(id, alice);
        vm.expectRevert(RealYieldStaking.BadRecipient.selector);
        st.offerPosition(id, address(st));
        vm.expectRevert(RealYieldStaking.BadRecipient.selector);
        st.offerPosition(id, address(sp));
        vm.expectRevert(RealYieldStaking.BadPosition.selector);
        st.offerPosition(id + 1, bob);
        st.offerPosition(id, bob);
        vm.stopPrank();
        // un tercero no puede aceptar la oferta de bob
        vm.prank(mallory);
        vm.expectRevert(RealYieldStaking.NotOffered.selector);
        st.acceptPosition(alice, id);
        vm.prank(mallory);
        vm.expectRevert(RealYieldStaking.NotOffered.selector);
        st.acceptPositionTo(alice, id, mallory);
        // bob como operador: destinos invalidos
        vm.startPrank(bob);
        vm.expectRevert(RealYieldStaking.BadRecipient.selector);
        st.acceptPositionTo(alice, id, alice);
        vm.expectRevert(RealYieldStaking.ZeroAddress.selector);
        st.acceptPositionTo(alice, id, address(0));
        vm.expectRevert(RealYieldStaking.BadRecipient.selector);
        st.acceptPositionTo(alice, id, address(st));
        vm.expectRevert(RealYieldStaking.BadRecipient.selector);
        st.acceptPositionTo(alice, id, address(sp));
        // bob entrega a carol: el lock es de carol, no de bob
        uint256 nid = st.acceptPositionTo(alice, id, carol);
        vm.stopPrank();
        assertEq(st.stakeOf(bob), 0);
        assertEq(st.stakeOf(carol), 100e18);
        assertEq(st.positionOf(carol, nid).amount, 100e18);
        // el owner no tiene ninguna funcion para mover locks ni su principal
        vm.prank(owner);
        vm.expectRevert(RealYieldStaking.NotRecoverable.selector);
        st.recoverERC20(address(N), owner, 1);
    }

    function test_transfer_flexibleIsNotAPosition() public {
        _flex(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(RealYieldStaking.BadPosition.selector);
        st.offerPosition(0, bob);
    }

    // ------------------------------------------------------------------ fuzz: conservacion
    /// Secuencias al azar de locks, transferencias, harvests y tiempo entre 3 wallets: el principal se
    /// conserva en cada paso (suma por usuario == totales) y al final todos salen con exactamente lo que
    /// entro; los premios nunca superan lo que entro al staking.
    function testFuzz_transfer_conservation(uint256 seed) public {
        address[3] memory us = [alice, bob, carol];
        uint256 deposited;
        for (uint256 s; s < 24; ++s) {
            uint256 r = uint256(keccak256(abi.encode(seed, s)));
            uint256 k = r % 5;
            address u = us[(r >> 8) % 3];
            address v = us[(r >> 16) % 3];
            if (k == 0) {
                uint256 amt = 1e18 + (r >> 24) % 1_000_000e18;
                _lock(u, amt, uint8(1 + (r >> 100) % 3));
                deposited += amt;
            } else if (k == 1 && u != v) {
                RealYieldStaking.Position[] memory ps = st.positionsOf(u);
                for (uint256 j; j < ps.length; ++j) {
                    if (ps[j].amount == 0) continue;
                    (uint256 w0, uint256 n0) = st.earned(u);
                    _move(u, j, v);
                    (uint256 w1, uint256 n1) = st.earned(u);
                    assertEq(w1, w0, "premios del que entrega");
                    assertEq(n1, n0);
                    break;
                }
            } else if (k == 2) {
                _harvest((r >> 24) % 2_000_000e18, (r >> 120) % 3 ether);
            } else if (k == 3) {
                _warp(1 + (r >> 24) % 9 days);
            } else {
                _flex(u, 1e18);
                deposited += 1e18;
            }
            _checkSums(us);
        }
        // todos salen
        _warp(40 days);
        for (uint256 i; i < 3; ++i) {
            RealYieldStaking.Position[] memory ps = st.positionsOf(us[i]);
            vm.startPrank(us[i]);
            for (uint256 j; j < ps.length; ++j) if (ps[j].amount != 0) st.withdrawLocked(j);
            RealYieldStaking.Account memory a = _acct(us[i]);
            if (a.flexible != 0) st.requestUnstake(a.flexible);
            vm.stopPrank();
        }
        _warp(2 days);
        uint256 out;
        for (uint256 i; i < 3; ++i) {
            uint256 b0 = N.balanceOf(us[i]);
            bool cooling = _acct(us[i]).cooling != 0;
            vm.prank(us[i]);
            if (cooling) st.withdraw();
            out += N.balanceOf(us[i]) - b0;
        }
        assertEq(out, deposited, "principal conservado");
        (uint256 tb, uint256 ts, uint256 tc) = _totals();
        assertEq(tb + ts + tc, 0);
        (uint256 cw, uint256 cn) = st.committedRewards();
        assertGe(W.balanceOf(address(st)), cw);
        assertGe(N.balanceOf(address(st)), cn);
    }

    function _checkSums(address[3] memory us) internal view {
        (uint256 tb, uint256 ts,) = _totals();
        uint256 s;
        uint256 w;
        for (uint256 i; i < 3; ++i) {
            s += st.stakeOf(us[i]);
            w += st.boostedBalanceOf(us[i]);
        }
        assertEq(s, ts, "suma stake != totalStaked");
        assertEq(w, tb, "suma peso != totalBoosted");
        uint256 m = (vm.getBlockTimestamp() / 1 days + 1) * 1 days;
        uint256 drops;
        for (uint256 d; d <= 31; ++d) drops += st.boostDrop(m + d * 1 days);
        assertEq(drops, tb - ts, "bajas de boost futuras != peso extra");
        (uint256 cw, uint256 cn) = st.committedRewards();
        (,,,,, uint256 tc, uint256 br) = st.rewardInfo();
        assertGe(W.balanceOf(address(st)), cw, "WETH insolvente");
        assertGe(N.balanceOf(address(st)), ts + tc + br + cn, "NLYRA insolvente");
    }
}
