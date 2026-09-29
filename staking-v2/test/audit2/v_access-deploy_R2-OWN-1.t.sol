// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// REGRESION R2-OWN-1 / hallazgo B (LOCAL, sin fork: mocks de inv2_stateful_local en las direcciones
// CREATE2 que valida el constructor). Antes: el owner renovaba la pausa 1 s despues y cada 29 dias,
// ~2 anos sin ventana de entrada y con la reserva congelada. Ahora: pause() revierte mientras esta activa
// y durante los 30 dias siguientes a su fin; unpause() la cierra y tambien arranca esos 30 dias.
import {Test} from "forge-std/Test.sol";
import {RealYieldStaking} from "../../src/RealYieldStaking.sol";
import {NlyraFeeSplitter} from "../../src/NlyraFeeSplitter.sol";
import {MToken, MPool, MLocker} from "./inv2_stateful_local.t.sol";

contract V_R2_OWN_1 is Test {
    RealYieldStaking st;
    NlyraFeeSplitter sp;
    MToken N;
    MToken W;
    MToken U;
    MLocker L;
    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address alice = makeAddr("alice");
    address carol = makeAddr("carol");
    address dave = makeAddr("dave");
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

    function _harvest() internal {
        W.mint(address(L), 1 ether);
        N.mint(address(L), 1_000_000e18);
        sp.harvest();
    }

    function test_pauseCannotBeRenewed_entryWindowsExist() public {
        N.mint(alice, 1e24);
        vm.startPrank(alice);
        N.approve(address(st), type(uint256).max);
        st.stakeLocked(1e24, 3); // insider locks 30d right before pausing
        vm.stopPrank();
        N.mint(dave, 1_000e18);
        vm.startPrank(dave);
        N.approve(address(st), type(uint256).max);
        st.fundBonusReserve(1_000e18);
        vm.stopPrank();
        N.mint(carol, 1e24);
        vm.prank(carol);
        N.approve(address(st), type(uint256).max);

        vm.prank(owner);
        st.pause();
        uint64 u0 = st.pausedUntil();
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(RealYieldStaking.PauseCooldown.selector, uint256(u0) + 30 days));
        st.pause();
        assertEq(st.pausedUntil(), u0, "not renewed while active");

        uint256 start = vm.getBlockTimestamp();
        uint256 entries;
        for (uint256 i; i < 26; ++i) {
            _harvest(); // fee inflow is not gated by the pause
            vm.warp(vm.getBlockTimestamp() + 29 days);
            // el owner intenta renovar antes de que venza (antes funcionaba)
            vm.prank(owner);
            try st.pause() {} catch {}
            if (!st.paused()) {
                vm.prank(carol);
                st.stake(1e18);
                ++entries;
            }
        }
        assertGe(vm.getBlockTimestamp() - start, 2 * 365 days - 30 days);
        emit log_named_uint("ventanas de entrada en ~2 anos (antes: 0)", entries);
        assertGe(entries, 8, "hay ventanas de entrada (1 de cada 3 chequeos cada 29 dias)");
        assertGt(st.stakeOf(carol), 0);
        // en una ventana abierta, compound a 30d saca bonus: la reserva no queda congelada
        while (st.paused()) vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(alice);
        st.compound(0, 3, 0);
        assertLt(st.bonusReserve(), 1_000e18, "reserve not frozen");
    }
}
