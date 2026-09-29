// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ForkBase} from "../ForkBase.sol";
import {RealYieldStaking} from "../../src/RealYieldStaking.sol";
import {PositionMarket} from "../../src/PositionMarket.sol";

/// Ronda 3 en el fork (bloque fijo, tokens, pool, locker y WETH reales): transferencia directa, venta por el
/// PositionMarket y el camino real de la comision (ETH -> splitter -> harvest lo envuelve en aeWETH -> 50/50
/// staking/treasury -> tramo de 7 dias a los stakers).
contract R3Fork is ForkBase {
    PositionMarket mk;
    uint256[4] snap; // earned de alice (w, n) al transferir y de bob (w, n) al vender

    function setUp() public override {
        super.setUp();
        vm.coinbase(address(this)); // the sequencer account was not served by the development RPC
        // the development RPC 403'd on accounts outside the cache: pre-touch the market address
        vm.deal(vm.computeCreateAddress(address(this), vm.getNonce(address(this))), 0);
        mk = new PositionMarket(address(st));
    }

    function _lockId(address u) internal view returns (uint256) {
        RealYieldStaking.Position[] memory ps = st.positionsOf(u);
        for (uint256 i; i < ps.length; ++i) if (ps[i].amount != 0) return i;
        revert("sin lock");
    }

    function test_fork_transferThenSale_rewardsFair_feeReachesStakersAndTreasury() public {
        _stake(alice, 1e24, 3); // alice -> bob (directo) -> dave (venta)
        _stake(carol, 1e24, 3); // gemelo que nunca se mueve
        _tradeAndHarvest();
        vm.warp(vm.getBlockTimestamp() + 2 days);

        // 1) transferencia directa alice -> bob
        uint256 id = _lockId(alice);
        (snap[0], snap[1]) = st.earned(alice);
        vm.prank(alice);
        st.offerPosition(id, bob);
        vm.prank(bob);
        uint256 bid = st.acceptPosition(alice, id);
        _checkSolvency(_users(), true);
        vm.warp(vm.getBlockTimestamp() + 2 days);

        // 2) bob lo vende por el mercado a dave
        vm.startPrank(bob);
        st.offerPosition(bid, address(mk));
        uint256 lid = mk.list(bid, 3 ether, uint64(vm.getBlockTimestamp() + 3 days));
        vm.stopPrank();
        assertTrue(mk.isBuyable(lid));
        vm.deal(dave, 3 ether);
        (snap[2], snap[3]) = st.earned(bob);
        vm.prank(dave);
        uint256 did = mk.buy{value: 3 ether}(lid, 3 ether);
        assertEq(st.stakeOf(dave), 1e24);
        assertEq(st.positionOf(dave, did).tier, 3);
        assertEq(address(sp).balance, 0.015 ether, "fee 0,5% en el splitter");
        assertEq(mk.proceeds(bob), 2.985 ether);
        _checkSolvency(_users(), true);

        // 3) harvest sin trades nuevos: el splitter solo tiene el ETH de la comision
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 tw0 = WETH.balanceOf(TREASURY);
        (uint256 rw0,) = _rewardBal();
        sp.harvest();
        assertEq(address(sp).balance, 0, "envuelto");
        assertEq(WETH.balanceOf(TREASURY) - tw0, 0.0075 ether, "50% al treasury");
        (uint256 rw1,) = _rewardBal();
        assertEq(rw1 - rw0, 0.0075 ether, "50% al staking");

        _rewardsAndExit(did);
    }

    function _rewardsAndExit(uint256 did) internal {
        // 4) premios: cada uno cobra su tramo; juntos == el gemelo
        vm.warp(vm.getBlockTimestamp() + 8 days);
        (uint256 aw, uint256 an) = st.earned(alice);
        (uint256 bw, uint256 bn) = st.earned(bob);
        (uint256 dw, uint256 dn) = st.earned(dave);
        (uint256 cw, uint256 cn) = st.earned(carol);
        assertEq(aw, snap[0]);
        assertEq(an, snap[1]);
        assertEq(bw, snap[2]);
        assertEq(bn, snap[3]);
        assertApproxEqAbs(aw + bw + dw, cw, 10, "WETH: alice+bob+dave == carol");
        assertApproxEqAbs(an + bn + dn, cn, 10, "NLYRA: alice+bob+dave == carol");
        for (uint256 i; i < 4; ++i) {
            address u = _users()[i];
            vm.prank(u);
            st.claim(RealYieldStaking.OutMode.AS_IS, 0);
        }
        vm.prank(bob);
        mk.withdrawProceeds(bob);
        assertEq(bob.balance, 2.985 ether);
        assertEq(address(mk).balance, 0);

        // 5) dave sale al vencer: el principal original, entero
        vm.warp(vm.getBlockTimestamp() + 25 days);
        vm.prank(dave);
        st.withdrawLocked(did);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        uint256 n0 = NLYRA.balanceOf(dave);
        vm.prank(dave);
        st.withdraw();
        assertEq(NLYRA.balanceOf(dave) - n0, 1e24);
        _checkSolvency(_users(), true);
    }

    /// En el fork: flash-transfer para el descuento del Desk no sirve, y la pausa frena la venta.
    function test_fork_flashTransfer_noDiscount_andPauseBlocksSale() public {
        _stake(alice, 1e24, 3);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        assertEq(st.eligibleBalance(alice), 1e24);
        uint256 id = _lockId(alice);
        vm.startPrank(alice);
        st.offerPosition(id, address(mk));
        uint256 lid = mk.list(id, 1 ether, uint64(vm.getBlockTimestamp() + 3 days));
        vm.stopPrank();
        vm.prank(owner);
        st.pause();
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(RealYieldStaking.EnforcedPause.selector);
        mk.buy{value: 1 ether}(lid, 1 ether);
        vm.prank(owner);
        st.unpause();
        vm.prank(bob);
        mk.buy{value: 1 ether}(lid, 1 ether);
        assertEq(st.eligibleBalance(alice), 0);
        assertEq(st.eligibleBalance(bob), 0, "lo comprado no cuenta para el descuento el mismo dia");
        vm.warp((vm.getBlockTimestamp() / 1 days + 2) * 1 days);
        assertEq(st.eligibleBalance(bob), 1e24, "a los 24-48 h cuenta");
    }

    /// Gas de las acciones nuevas (fork, storage frio; perfil default para las cifras del README).
    function test_gas_r3() public {
        _stake(alice, 1e24, 3);
        _stake(bob, 1e24, 1);
        _tradeAndHarvest();
        vm.warp(vm.getBlockTimestamp() + 1 days);
        uint256 id = _lockId(alice);
        vm.prank(alice);
        uint256 g = gasleft();
        st.offerPosition(id, carol);
        emit log_named_uint("offerPosition", g - gasleft());
        vm.prank(alice);
        g = gasleft();
        st.cancelPositionOffer(id);
        emit log_named_uint("cancelPositionOffer", g - gasleft());
        vm.prank(alice);
        st.offerPosition(id, carol);
        vm.prank(carol);
        g = gasleft();
        uint256 cid = st.acceptPosition(alice, id);
        emit log_named_uint("acceptPosition (wallet nueva)", g - gasleft());
        vm.prank(carol);
        st.offerPosition(cid, address(mk));
        vm.prank(carol);
        g = gasleft();
        uint256 lid = mk.list(cid, 1 ether, uint64(vm.getBlockTimestamp() + 1 days));
        emit log_named_uint("market.list", g - gasleft());
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        g = gasleft();
        mk.buy{value: 1 ether}(lid, 1 ether);
        emit log_named_uint("market.buy (comprador con locks)", g - gasleft());
        vm.prank(carol);
        g = gasleft();
        mk.withdrawProceeds(carol);
        emit log_named_uint("market.withdrawProceeds", g - gasleft());
    }
}
