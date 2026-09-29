// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RealYieldStaking} from "../../src/RealYieldStaking.sol";
import {NlyraFeeSplitter} from "../../src/NlyraFeeSplitter.sol";
import {PositionMarket} from "../../src/PositionMarket.sol";
import {Inv2Base} from "../audit2/inv2_stateful_local.t.sol";

/// vendedor-contrato que al recibir ETH intenta re-entrar al mercado
contract ReenteringSeller {
    PositionMarket public m;
    RealYieldStaking public st;
    uint8 public mode; // 1 = withdrawProceeds, 2 = buy, 3 = cancel
    uint256 public arg;

    constructor(PositionMarket m_, RealYieldStaking st_) {
        m = m_;
        st = st_;
    }

    function setMode(uint8 k, uint256 a) external {
        mode = k;
        arg = a;
    }

    function lockAndList(uint256 amt, uint256 price) external returns (uint256 lid) {
        st.NLYRA().approve(address(st), amt);
        st.stakeLocked(amt, 3);
        st.offerPosition(0, address(m));
        lid = m.list(0, price, uint64(block.timestamp + 10 days));
    }

    function withdraw(address to) external {
        m.withdrawProceeds(to);
    }

    receive() external payable {
        if (mode == 1) m.withdrawProceeds(address(this));
        else if (mode == 2) m.buy{value: msg.value}(arg, msg.value);
        else if (mode == 3) m.cancel(arg);
    }
}

/// vendedor que rechaza ETH: igual puede vender (pull-payment) y retirar a otra direccion
contract EthRejecter {
    function run(RealYieldStaking st, PositionMarket m, uint256 amt, uint256 price) external returns (uint256 lid) {
        st.NLYRA().approve(address(st), amt);
        st.stakeLocked(amt, 2);
        st.offerPosition(0, address(m));
        lid = m.list(0, price, uint64(block.timestamp + 10 days));
    }

    function withdraw(PositionMarket m, address to) external {
        m.withdrawProceeds(to);
    }
}

contract ForceSend {
    constructor(address payable to) payable {
        selfdestruct(to);
    }
}

/// Ronda 3 · PositionMarket (local, sin fork). Cada proteccion pedida tiene su test adversarial.
contract R3MarketLocal is Inv2Base {
    PositionMarket mk;
    address alice = makeAddr("alice"); // vendedora
    address bob = makeAddr("bob"); // comprador
    address carol = makeAddr("carol");
    address mallory = makeAddr("mallory");

    event Sold(
        uint256 indexed listingId,
        address indexed seller,
        address indexed buyer,
        uint256 positionId,
        uint256 buyerPositionId,
        uint256 price,
        uint256 fee
    );

    function setUp() public {
        _deploy(1);
        mk = new PositionMarket(address(st));
        vm.deal(bob, 1_000 ether);
        vm.deal(carol, 1_000 ether);
        vm.deal(mallory, 1_000 ether);
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
        RealYieldStaking.Position[] memory ps = st.positionsOf(u);
        for (uint256 i = ps.length; i > 0; --i) {
            if (ps[i - 1].amount == amt && ps[i - 1].unlockTime > _now()) return i - 1;
        }
        revert("lock no encontrado");
    }

    function _list(address u, uint256 id, uint256 price) internal returns (uint256 lid) {
        vm.startPrank(u);
        st.offerPosition(id, address(mk));
        lid = mk.list(id, price, uint64(_now() + 7 days));
        vm.stopPrank();
    }

    function _harvest(uint256 n) internal {
        uint256 lh = sp.lastHarvest();
        if (lh != 0 && _now() < lh + 1 days) vm.warp(lh + 1 days);
        N.mint(address(sp), n);
        sp.harvest();
    }

    function _fee(uint256 price) internal pure returns (uint256) {
        return (price * 50 + 9_999) / 10_000;
    }

    // ------------------------------------------------------------------ camino feliz + comision
    function test_market_happyPath_atomicSale_feeToSplitter_sellerPulls() public {
        uint256 id = _lock(alice, 1_000e18, 3);
        RealYieldStaking.Position memory p0 = st.positionOf(alice, id);
        uint256 lid = _list(alice, id, 2 ether);
        assertTrue(mk.isBuyable(lid));
        uint256 sp0 = address(sp).balance;
        vm.expectEmit(address(mk));
        emit Sold(lid, alice, bob, id, 0, 2 ether, 0.01 ether);
        vm.prank(bob);
        uint256 nid = mk.buy{value: 2 ether}(lid, 2 ether);
        // el lock llego entero al comprador, en el mismo acto
        RealYieldStaking.Position memory p1 = st.positionOf(bob, nid);
        assertEq(p1.amount, p0.amount);
        assertEq(p1.unlockTime, p0.unlockTime);
        assertEq(p1.tier, p0.tier);
        assertEq(st.stakeOf(alice), 0);
        assertEq(st.stakeOf(address(mk)), 0, "el mercado nunca tiene locks");
        // 0,5% al splitter, el resto para la vendedora (pull)
        assertEq(address(sp).balance - sp0, 0.01 ether, "fee 50 bps");
        assertEq(mk.proceeds(alice), 1.99 ether);
        assertEq(mk.totalProceeds(), 1.99 ether);
        assertEq(address(mk).balance, 1.99 ether);
        vm.prank(alice);
        mk.withdrawProceeds(alice);
        assertEq(alice.balance, 1.99 ether);
        assertEq(address(mk).balance, 0, "sin ETH trabado");
        assertEq(mk.totalProceeds(), 0);
        vm.prank(alice);
        vm.expectRevert(PositionMarket.NothingToWithdraw.selector);
        mk.withdrawProceeds(alice);
        // la publicacion ya no existe
        assertFalse(mk.isBuyable(lid));
        vm.prank(carol);
        vm.expectRevert(PositionMarket.NotListed.selector);
        mk.buy{value: 2 ether}(lid, 2 ether);
    }

    /// Camino completo de la comision: el ETH del fee llega al splitter, el harvest lo envuelve a WETH y
    /// lo reparte 50/50 staking/treasury; el staking lo streamea a los stakers en un tramo de 7 dias.
    function test_market_feePath_splitterWrapsAndSplits5050_toStakers() public {
        _lock(carol, 5_000e18, 1); // hay stakers que cobran
        uint256 id = _lock(alice, 1_000e18, 3);
        uint256 lid = _list(alice, id, 40 ether);
        vm.prank(bob);
        mk.buy{value: 40 ether}(lid, 40 ether);
        uint256 fee = 0.2 ether;
        assertEq(address(sp).balance, fee);
        uint256 stW0 = W.balanceOf(address(st));
        uint256 trW0 = W.balanceOf(treasury);
        uint256 nTr = st.tranches().length;
        sp.harvest();
        assertEq(address(sp).balance, 0, "el splitter envolvio todo");
        assertEq(W.balanceOf(address(st)) - stW0, fee / 2, "50% a stakers");
        assertEq(W.balanceOf(treasury) - trW0, fee / 2, "50% al treasury");
        assertEq(st.tranches().length, nTr + 1, "abre tramo");
        RealYieldStaking.Tranche[] memory trs = st.tranches();
        assertEq(uint256(trs[trs.length - 1].rateWeth), (fee / 2) / 7 days);
        _warp(7 days);
        (uint256 cw,) = st.earned(carol);
        (uint256 bw,) = st.earned(bob);
        assertApproxEqAbs(cw + bw, fee / 2, 1e6, "los stakers cobran la mitad del fee");
    }

    // ------------------------------------------------------------------ aprobacion por lock
    function test_market_requiresPerPositionOffer_noBlanketApproval() public {
        uint256 id0 = _lock(alice, 100e18, 3);
        uint256 id1 = _lock(alice, 200e18, 3);
        vm.startPrank(alice);
        vm.expectRevert(PositionMarket.NotOfferedToMarket.selector);
        mk.list(id0, 1 ether, uint64(_now() + 1 days));
        st.offerPosition(id0, bob); // ofrecido a otro
        vm.expectRevert(PositionMarket.NotOfferedToMarket.selector);
        mk.list(id0, 1 ether, uint64(_now() + 1 days));
        st.offerPosition(id0, address(mk));
        mk.list(id0, 1 ether, uint64(_now() + 1 days));
        // ofrecer id0 no habilita id1
        vm.expectRevert(PositionMarket.NotOfferedToMarket.selector);
        mk.list(id1, 1 ether, uint64(_now() + 1 days));
        // no se puede publicar un lock ajeno
        vm.stopPrank();
        vm.prank(mallory);
        vm.expectRevert(PositionMarket.NotLocked.selector);
        mk.list(id0, 1 ether, uint64(_now() + 1 days));
        // y el mercado no puede mover nada que no se le haya ofrecido: nadie mas que el mercado acepta
        vm.prank(mallory);
        vm.expectRevert(RealYieldStaking.NotOffered.selector);
        st.acceptPositionTo(alice, id1, mallory);
    }

    function test_market_listParamsValidated() public {
        uint256 id = _lock(alice, 100e18, 3);
        vm.startPrank(alice);
        st.offerPosition(id, address(mk));
        vm.expectRevert(PositionMarket.BadPrice.selector);
        mk.list(id, 0, uint64(_now() + 1 days));
        vm.expectRevert(PositionMarket.BadPrice.selector);
        mk.list(id, uint256(type(uint128).max) + 1, uint64(_now() + 1 days));
        vm.expectRevert(PositionMarket.BadExpiry.selector);
        mk.list(id, 1 ether, uint64(_now()));
        vm.expectRevert(PositionMarket.NotLocked.selector);
        mk.list(id + 7, 1 ether, uint64(_now() + 1 days));
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ locks vencidos
    function test_market_expiredLocks_notListable_andListingDiesAtUnlock() public {
        uint256 id = _lock(alice, 100e18, 3);
        RealYieldStaking.Position memory p = st.positionOf(alice, id);
        vm.startPrank(alice);
        st.offerPosition(id, address(mk));
        uint256 lid = mk.list(id, 1 ether, uint64(_now() + 90 days)); // la publicacion dura mas que el lock
        vm.stopPrank();
        vm.warp(p.unlockTime - 1);
        assertTrue(mk.isBuyable(lid));
        vm.warp(p.unlockTime); // vence
        assertFalse(mk.isBuyable(lid));
        vm.prank(bob);
        vm.expectRevert(PositionMarket.NotLocked.selector);
        mk.buy{value: 1 ether}(lid, 1 ether);
        vm.prank(alice);
        vm.expectRevert(PositionMarket.NotLocked.selector);
        mk.list(id, 1 ether, uint64(_now() + 1 days));
        // tampoco uno ya liquidado a 1x (tier 0)
        vm.prank(alice);
        st.kick(alice, id);
        vm.prank(alice);
        vm.expectRevert(PositionMarket.NotLocked.selector);
        mk.list(id, 1 ether, uint64(_now() + 1 days));
    }

    // ------------------------------------------------------------------ front-running del precio
    function test_market_priceFrontRun_protected() public {
        uint256 id = _lock(alice, 100e18, 3);
        uint256 lid = _list(alice, id, 1 ether);
        // la vendedora "sube el precio" justo antes del comprador: re-publica (id nuevo)
        vm.prank(alice);
        uint256 lid2 = mk.list(id, 5 ether, uint64(_now() + 1 days));
        assertTrue(lid2 != lid);
        vm.prank(bob);
        vm.expectRevert(PositionMarket.NotListed.selector);
        mk.buy{value: 1 ether}(lid, 1 ether);
        // el precio esperado no coincide
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PositionMarket.PriceMismatch.selector, 5 ether));
        mk.buy{value: 5 ether}(lid2, 1 ether);
        // el pago tiene que ser exacto (ni de mas ni de menos: nada queda trabado)
        vm.prank(bob);
        vm.expectRevert(PositionMarket.BadPayment.selector);
        mk.buy{value: 6 ether}(lid2, 5 ether);
        vm.prank(bob);
        vm.expectRevert(PositionMarket.BadPayment.selector);
        mk.buy{value: 4 ether}(lid2, 5 ether);
        vm.prank(bob);
        mk.buy{value: 5 ether}(lid2, 5 ether);
        assertEq(bob.balance, 995 ether);
    }

    // ------------------------------------------------------------------ el vendedor mueve el lock
    function test_market_sellerExtends_listingInvalid_evenIfReoffered() public {
        uint256 id = _lock(alice, 100e18, 1);
        uint256 lid = _list(alice, id, 1 ether);
        vm.prank(alice);
        st.extendLock(id, 3); // alarga el lock (el comprador compraria algo distinto)
        assertFalse(mk.isBuyable(lid));
        vm.prank(bob);
        vm.expectRevert(PositionMarket.PositionChanged.selector);
        mk.buy{value: 1 ether}(lid, 1 ether);
        vm.prank(alice);
        st.offerPosition(id, address(mk)); // aunque lo vuelva a ofrecer, la foto no coincide
        vm.prank(bob);
        vm.expectRevert(PositionMarket.PositionChanged.selector);
        mk.buy{value: 1 ether}(lid, 1 ether);
    }

    function test_market_sellerCompoundsInto_listingInvalid() public {
        _lock(carol, 1_000e18, 1);
        uint256 id = _lock(alice, 100e18, 3);
        uint256 lid = _list(alice, id, 1 ether);
        _harvest(1_000_000e18);
        _warp(1 days);
        vm.prank(alice);
        st.compound(0, 3, id);
        vm.prank(alice);
        st.offerPosition(id, address(mk));
        vm.prank(bob);
        vm.expectRevert(PositionMarket.PositionChanged.selector);
        mk.buy{value: 1 ether}(lid, 1 ether);
    }

    function test_market_sellerTransfersAway_listingInvalid() public {
        uint256 id = _lock(alice, 100e18, 3);
        uint256 lid = _list(alice, id, 1 ether);
        vm.prank(alice);
        st.offerPosition(id, carol); // reemplaza la oferta al mercado
        vm.prank(bob);
        vm.expectRevert(RealYieldStaking.NotOffered.selector);
        mk.buy{value: 1 ether}(lid, 1 ether);
        vm.prank(carol);
        st.acceptPosition(alice, id);
        vm.prank(bob);
        vm.expectRevert(PositionMarket.PositionChanged.selector);
        mk.buy{value: 1 ether}(lid, 1 ether);
        // carol lo publica ella: publicacion nueva, con su foto
        uint256 lid2 = _list(carol, 0, 2 ether);
        vm.prank(bob);
        mk.buy{value: 2 ether}(lid2, 2 ether);
        assertEq(st.stakeOf(bob), 100e18);
    }

    function test_market_sellerWithdrawsOffer_listingInvalid() public {
        uint256 id = _lock(alice, 100e18, 3);
        uint256 lid = _list(alice, id, 1 ether);
        vm.prank(alice);
        st.cancelPositionOffer(id);
        assertFalse(mk.isBuyable(lid));
        vm.prank(bob);
        vm.expectRevert(RealYieldStaking.NotOffered.selector);
        mk.buy{value: 1 ether}(lid, 1 ether);
        assertEq(bob.balance, 1_000 ether, "el comprador no pierde nada");
    }

    /// El vendedor retira el lock (solo posible vencido: tampoco se puede comprar) y reusa el slot con un
    /// lock nuevo y lo vuelve a ofrecer: la publicacion vieja no le vende el lock nuevo.
    function test_market_sellerUnstakes_andReusesSlot_oldListingDead() public {
        uint256 id = _lock(alice, 100e18, 1);
        uint256 lid = _list(alice, id, 1 ether);
        _warp(9 days);
        vm.prank(alice);
        st.withdrawLocked(id);
        uint256 id2 = _lock(alice, 100e18, 1);
        assertEq(id2, id);
        vm.prank(alice);
        st.offerPosition(id2, address(mk));
        vm.prank(bob);
        vm.expectRevert(PositionMarket.ListingExpired.selector); // la publicacion vencio (7 dias)
        mk.buy{value: 1 ether}(lid, 1 ether);
        // con una publicacion larga: la foto (vencimiento) no coincide
        uint256 id3 = _lock(alice, 55e18, 3);
        vm.startPrank(alice);
        st.offerPosition(id3, address(mk));
        uint256 lid3 = mk.list(id3, 1 ether, uint64(_now() + 60 days));
        vm.stopPrank();
        _warp(32 days);
        vm.prank(alice);
        st.withdrawLocked(id3);
        _lock(alice, 55e18, 3);
        vm.prank(alice);
        st.offerPosition(id3, address(mk));
        vm.prank(bob);
        vm.expectRevert(PositionMarket.PositionChanged.selector);
        mk.buy{value: 1 ether}(lid3, 1 ether);
    }

    // ------------------------------------------------------------------ vencimiento y cancelacion
    function test_market_listingExpiryAndCancel() public {
        uint256 id = _lock(alice, 100e18, 3);
        uint256 lid = _list(alice, id, 1 ether);
        vm.prank(mallory);
        vm.expectRevert(PositionMarket.NotSeller.selector);
        mk.cancel(lid);
        _warp(7 days);
        vm.prank(bob);
        vm.expectRevert(PositionMarket.ListingExpired.selector);
        mk.buy{value: 1 ether}(lid, 1 ether);
        vm.prank(alice);
        mk.cancel(lid);
        assertEq(mk.activeListing(alice, id), 0);
        vm.prank(bob);
        vm.expectRevert(PositionMarket.NotListed.selector);
        mk.buy{value: 1 ether}(lid, 1 ether);
        vm.prank(alice);
        vm.expectRevert(PositionMarket.NotListed.selector);
        mk.cancel(lid);
    }

    // ------------------------------------------------------------------ reentrada
    function test_market_reentrancy_withdrawProceeds_blocked() public {
        ReenteringSeller rs = new ReenteringSeller(mk, st);
        N.mint(address(rs), 100e18);
        uint256 lid = rs.lockAndList(100e18, 1 ether);
        vm.prank(bob);
        mk.buy{value: 1 ether}(lid, 1 ether);
        uint256 net = 1 ether - _fee(1 ether);
        assertEq(mk.proceeds(address(rs)), net);
        // al recibir, intenta retirar de nuevo: la re-entrada revierte y el retiro entero tambien
        rs.setMode(1, 0);
        vm.expectRevert(PositionMarket.EthTransferFailed.selector);
        rs.withdraw(address(rs));
        assertEq(mk.proceeds(address(rs)), net, "sin doble retiro");
        assertEq(address(mk).balance, net);
        // intenta comprar dentro del callback: tambien bloqueado
        uint256 id = _lock(carol, 10e18, 3);
        uint256 lid2 = _list(carol, id, 0.1 ether);
        vm.deal(address(rs), 0);
        rs.setMode(2, lid2);
        vm.expectRevert(PositionMarket.EthTransferFailed.selector);
        rs.withdraw(address(rs));
        assertTrue(mk.isBuyable(lid2));
        // retira normal a una EOA
        rs.withdraw(mallory);
        assertEq(mallory.balance, 1_000 ether + net);
        assertEq(address(mk).balance, 0);
    }

    /// Un vendedor que no puede recibir ETH no bloquea la venta (pull-payment) y retira a otra direccion.
    function test_market_sellerRejectingEth_doesNotBlockSale() public {
        EthRejecter er = new EthRejecter();
        N.mint(address(er), 100e18);
        uint256 lid = er.run(st, mk, 100e18, 3 ether);
        vm.prank(bob);
        mk.buy{value: 3 ether}(lid, 3 ether);
        vm.expectRevert(PositionMarket.EthTransferFailed.selector);
        er.withdraw(mk, address(er));
        er.withdraw(mk, carol);
        assertEq(carol.balance, 1_000 ether + 3 ether - _fee(3 ether));
        vm.expectRevert(PositionMarket.ZeroAddress.selector);
        er.withdraw(mk, address(0));
    }

    // ------------------------------------------------------------------ ETH trabado
    function test_market_noStuckEth() public {
        // ETH directo: revierte (no hay receive)
        vm.prank(bob);
        (bool ok,) = address(mk).call{value: 1 ether}("");
        assertFalse(ok);
        vm.expectRevert(PositionMarket.NothingToWithdraw.selector);
        mk.sweepExcess();
        // ETH forzado (selfdestruct) + una venta pendiente de retiro: solo el excedente va al splitter
        uint256 id = _lock(alice, 100e18, 3);
        uint256 lid = _list(alice, id, 1 ether);
        vm.prank(bob);
        mk.buy{value: 1 ether}(lid, 1 ether);
        new ForceSend{value: 0.3 ether}(payable(address(mk)));
        uint256 sp0 = address(sp).balance;
        vm.prank(mallory);
        mk.sweepExcess();
        assertEq(address(sp).balance - sp0, 0.3 ether);
        assertEq(address(mk).balance, mk.totalProceeds(), "lo de los vendedores intacto");
        vm.prank(alice);
        mk.withdrawProceeds(alice);
        assertEq(address(mk).balance, 0);
    }

    // ------------------------------------------------------------------ owner, pausa, cupo
    /// El owner del staking no puede llevarse un lock publicado: no hay funcion para eso; solo puede pausar
    /// (como mucho 30 dias), lo que frena las compras, y el lock sigue siendo de la vendedora.
    function test_market_stakingOwnerCannotTakeListedPosition() public {
        uint256 id = _lock(alice, 100e18, 3);
        uint256 lid = _list(alice, id, 1 ether);
        vm.startPrank(owner);
        vm.expectRevert(RealYieldStaking.NotOffered.selector);
        st.acceptPosition(alice, id);
        vm.expectRevert(RealYieldStaking.NotOffered.selector);
        st.acceptPositionTo(alice, id, owner);
        st.pause();
        vm.stopPrank();
        assertFalse(mk.isBuyable(lid));
        vm.prank(bob);
        vm.expectRevert(RealYieldStaking.EnforcedPause.selector);
        mk.buy{value: 1 ether}(lid, 1 ether);
        assertEq(st.stakeOf(alice), 100e18);
        vm.prank(owner);
        st.unpause();
        vm.prank(bob);
        mk.buy{value: 1 ether}(lid, 1 ether);
        assertEq(st.stakeOf(bob), 100e18);
        assertEq(st.stakeOf(owner), 0);
    }

    function test_market_buyerAtCap_reverts_listingIntact() public {
        for (uint256 i; i < 32; ++i) _lock(bob, 1e18, 1);
        uint256 id = _lock(alice, 100e18, 3);
        uint256 lid = _list(alice, id, 1 ether);
        vm.prank(bob);
        vm.expectRevert(RealYieldStaking.TooManyPositions.selector);
        mk.buy{value: 1 ether}(lid, 1 ether);
        assertTrue(mk.isBuyable(lid));
        assertEq(bob.balance, 1_000 ether);
    }

    function test_market_sellerCannotBuyOwnListing() public {
        uint256 id = _lock(alice, 100e18, 3);
        uint256 lid = _list(alice, id, 1 ether);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(RealYieldStaking.BadRecipient.selector);
        mk.buy{value: 1 ether}(lid, 1 ether);
    }

    /// Premios: lo devengado hasta la venta es de la vendedora; el comprador gana desde la compra.
    function test_market_rewardsSplitAtSale() public {
        uint256 id = _lock(alice, 1_000e18, 3);
        _lock(carol, 1_000e18, 3);
        _harvest(1_400_000e18);
        _warp(2 days);
        (, uint256 a0) = st.earned(alice);
        uint256 lid = _list(alice, id, 1 ether);
        vm.prank(bob);
        mk.buy{value: 1 ether}(lid, 1 ether);
        _warp(5 days);
        (, uint256 a1) = st.earned(alice);
        (, uint256 b1) = st.earned(bob);
        (, uint256 c1) = st.earned(carol);
        assertEq(a1, a0, "la vendedora conserva lo suyo y no gana mas");
        assertApproxEqAbs(a1 + b1, c1, 10);
    }

    function test_market_constructorChecks() public {
        vm.expectRevert(PositionMarket.ZeroAddress.selector);
        new PositionMarket(address(0));
        vm.expectRevert(PositionMarket.BadStaking.selector);
        new PositionMarket(makeAddr("eoa"));
        assertEq(address(mk.STAKING()), address(st));
        assertEq(mk.FEE_RECIPIENT(), address(sp));
        assertEq(mk.FEE_BPS(), 50);
    }

    // ------------------------------------------------------------------ fuzz
    function testFuzz_market_feeMath(uint256 price) public view {
        price = bound(price, 1, type(uint128).max);
        (uint256 fee, uint256 net) = mk.quote(price);
        assertEq(fee + net, price);
        assertEq(fee, _fee(price));
        assertGe(fee * 10_000, price * 50, "nunca menos de 0,5%");
        assertLt(fee, (price * 50) / 10_000 + 1 + 1, "como mucho 0,5% + 1 wei");
    }

    /// Ventas encadenadas al azar entre 3 wallets a precios al azar: el principal se conserva, el ETH cuadra
    /// al wei (pagado = fees al splitter + retirado por vendedores) y el mercado termina sin ETH ni locks.
    function testFuzz_market_salesConserve(uint256 seed) public {
        address[3] memory us = [alice, bob, carol];
        uint256 locked;
        for (uint256 i; i < 3; ++i) {
            vm.deal(us[i], 1_000 ether);
            _lock(us[i], 1e18 + uint256(keccak256(abi.encode(seed, i))) % 1_000_000e18, uint8(1 + i));
        }
        (, uint256 ts0,) = _tot();
        locked = ts0;
        uint256 paid;
        uint256 fees;
        uint256 sp0 = address(sp).balance;
        for (uint256 s; s < 12; ++s) {
            uint256 r = uint256(keccak256(abi.encode(seed, "s", s)));
            address seller = us[r % 3];
            address buyer = us[(r >> 8) % 3];
            RealYieldStaking.Position[] memory ps = st.positionsOf(seller);
            uint256 id = type(uint256).max;
            for (uint256 j; j < ps.length; ++j) {
                if (ps[j].amount != 0 && ps[j].unlockTime > _now()) {
                    id = j;
                    break;
                }
            }
            if (id == type(uint256).max || seller == buyer) {
                _warp(1 + (r >> 16) % 2 days);
                continue;
            }
            uint256 price = 1 + (r >> 32) % 50 ether;
            uint256 lid = _list(seller, id, price);
            vm.prank(buyer);
            mk.buy{value: price}(lid, price);
            paid += price;
            fees += _fee(price);
            (, uint256 ts,) = _tot();
            assertEq(ts, locked, "principal conservado");
            assertEq(st.stakeOf(address(mk)), 0);
            assertEq(address(mk).balance, mk.totalProceeds(), "ETH del mercado == deuda con vendedores");
            _warp((r >> 64) % 1 days);
        }
        uint256 out;
        for (uint256 i; i < 3; ++i) {
            uint256 pr = mk.proceeds(us[i]);
            if (pr == 0) continue;
            uint256 b0 = us[i].balance;
            vm.prank(us[i]);
            mk.withdrawProceeds(us[i]);
            out += us[i].balance - b0;
        }
        assertEq(address(sp).balance - sp0, fees, "fees al splitter");
        assertEq(out + fees, paid, "cada wei pagado va a vendedor o splitter");
        assertEq(address(mk).balance, 0);
        uint256 sum;
        for (uint256 i; i < 3; ++i) sum += st.stakeOf(us[i]);
        assertEq(sum, locked);
    }

    function _tot() internal view returns (uint256 tb, uint256 ts, uint256 tc) {
        (,,, tb, ts, tc,) = st.rewardInfo();
    }
}
