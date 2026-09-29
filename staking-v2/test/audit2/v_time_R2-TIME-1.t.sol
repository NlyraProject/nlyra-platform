// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// REGRESION R2-TIME-1 / hallazgo B (LOCAL mocks). Antes: pause() encadenado cada 29 dias dejaba el
// contrato pausado un ano (extendLock / compound / cancelUnstake / fundBonusReserve bloqueados). Ahora
// la cadena se corta: tras 30 dias vence y la siguiente pausa recien 30 dias despues. Las salidas del
// principal siguen abiertas siempre.
import {Test} from "forge-std/Test.sol";
import {RealYieldStaking} from "../../src/RealYieldStaking.sol";
import {NlyraFeeSplitter} from "../../src/NlyraFeeSplitter.sol";
import {MToken, MPool, MLocker} from "./inv2_stateful_local.t.sol";

contract V_Time_R2_TIME_1 is Test {
    RealYieldStaking st;
    NlyraFeeSplitter sp;
    MToken N;
    MToken W;
    MToken U;
    MLocker L;
    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address constant FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    bytes32 constant HASH = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;

    function _mkPool(address a, address b, uint24 fee, uint256 bPerA) internal returns (address pool) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        uint256 px = a == t0 ? bPerA : (1e36 / bPerA);
        bytes32 salt = keccak256(abi.encode(t0, t1, fee));
        pool = address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", FACTORY, salt, HASH)))));
        vm.etch(pool, type(MPool).runtimeCode);
        MPool(pool).init(t0, t1, fee, px);
        MToken(t0).mint(pool, 1e40);
        MToken(t1).mint(pool, 1e40);
    }

    function setUp() public {
        vm.warp(1_790_000_000 + 12345);
        N = new MToken("NLYRA", 18);
        W = new MToken("WETH", 18);
        U = new MToken("USDG", 6);
        L = new MLocker(W, N);
        address pn = _mkPool(address(W), address(N), 10_000, 10_000_000e18);
        address pu = _mkPool(address(W), address(U), 100, 4000e6);
        st = new RealYieldStaking(owner, address(N), address(W), address(U), pn, pu, address(L), treasury, 5_000, 1 days);
        sp = NlyraFeeSplitter(payable(st.feeSplitter()));
        L.setFeeRedirect(address(N), address(sp));
        L.setMode(1);
    }

    function _approve(address u, uint256 amt) internal {
        N.mint(u, amt);
        vm.prank(u);
        N.approve(address(st), type(uint256).max);
    }

    function test_chainedPauseIsCut() public {
        _approve(alice, 1_000e18);
        vm.prank(alice);
        st.stakeLocked(1_000e18, 3); // 30d lock
        _approve(bob, 1_000e18);
        vm.prank(bob);
        st.stake(1_000e18);
        _approve(carol, 500e18);
        vm.prank(carol);
        st.fundBonusReserve(500e18);
        uint256 reserve0 = st.bonusReserve();

        // rewards accrue so compound has something to do
        W.mint(address(L), 1 ether);
        N.mint(address(L), 1_000_000e18);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        sp.harvest();

        vm.prank(owner);
        st.pause();
        uint256 pausedDays;
        for (uint256 i; i < 13; i++) {
            vm.warp(vm.getBlockTimestamp() + 29 days);
            if (st.paused()) ++pausedDays;
            vm.prank(owner);
            try st.pause() {} catch {}
        }
        assertLt(pausedDays, 13, "la pausa no se sostiene sola");

        // durante la pausa: entradas frenadas, salidas abiertas
        while (!st.paused()) {
            vm.warp(vm.getBlockTimestamp() + 1 days);
            vm.prank(owner);
            try st.pause() {} catch {}
        }
        vm.prank(alice);
        vm.expectRevert(RealYieldStaking.EnforcedPause.selector);
        st.extendLock(0, 3);
        vm.prank(bob);
        st.requestUnstake(500e18);
        vm.prank(bob);
        vm.expectRevert(RealYieldStaking.EnforcedPause.selector);
        st.cancelUnstake();
        uint256 b0 = N.balanceOf(alice);
        vm.prank(alice);
        st.withdrawLocked(0);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(alice);
        st.withdraw();
        assertEq(N.balanceOf(alice) - b0, 1_000e18, "alice principal out");

        // y cuando vence, compound a 30d vuelve a sacar de la reserva
        vm.warp(st.pausedUntil());
        assertFalse(st.paused());
        vm.prank(bob);
        st.compound(0, 3, type(uint256).max);
        assertLt(st.bonusReserve(), reserve0, "reserve not frozen");
    }
}
