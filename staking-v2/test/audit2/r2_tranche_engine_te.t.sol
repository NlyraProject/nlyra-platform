// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";
import {IERC20} from "oz/token/ERC20/IERC20.sol";
import {RealYieldStaking} from "../../src/RealYieldStaking.sol";

contract TeTok {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { balanceOf[msg.sender] -= a; balanceOf[to] += a; return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
}

contract TePool {
    function token0() external view returns (address a) { assembly { a := sload(0) } }
    function token1() external view returns (address a) { assembly { a := sload(1) } }
    function fee() external view returns (uint24 f) { assembly { f := sload(2) } }
    function factory() external pure returns (address) { return 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA; }
    function swap(address, bool, int256, uint160, bytes calldata) external pure returns (int256, int256) { revert("x"); }
}

/// Round 2 - motor de tramos SIN fork (pools/tokens etcheados en sus direcciones reales).
contract R2TrancheEngineTE is Test {
    address constant NL = 0xB9d3824149aD8ac984153CeEc91D5a2405d1FB95;
    address constant WE = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant US = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant PN = 0x483C24d1e36Df01b650F1E9BEEB2a1c31C005C39;
    address constant PU = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca;
    RealYieldStaking st;
    address sp;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function _pool(address p, address a, address b, uint24 f) internal {
        vm.etch(p, address(new TePool()).code);
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        vm.store(p, bytes32(uint256(0)), bytes32(uint256(uint160(t0))));
        vm.store(p, bytes32(uint256(1)), bytes32(uint256(uint160(t1))));
        vm.store(p, bytes32(uint256(2)), bytes32(uint256(f)));
    }

    function setUp() public {
        vm.warp(1_790_000_000);
        bytes memory c = address(new TeTok()).code;
        vm.etch(NL, c);
        vm.etch(WE, c);
        vm.etch(US, c);
        _pool(PN, WE, NL, 10000);
        _pool(PU, WE, US, 100);
        vm.etch(address(0xdead), hex"00"); // el splitter exige que el locker tenga codigo
        st = new RealYieldStaking(address(this), NL, WE, US, PN, PU, address(0xdead), address(0xbeef), 5000, 1 days);
        sp = st.feeSplitter();
    }

    function _stake(address u, uint256 amt, uint8 tier) internal {
        TeTok(NL).mint(u, amt);
        vm.startPrank(u);
        IERC20(NL).approve(address(st), amt);
        if (tier == 0) st.stake(amt);
        else st.stakeLocked(amt, tier);
        vm.stopPrank();
    }

    function _notifyW(uint256 w) internal {
        TeTok(WE).mint(address(st), w);
        vm.prank(sp);
        st.notifyRewards(w, 0);
    }

    function _notifyN(uint256 n) internal {
        TeTok(NL).mint(address(st), n);
        vm.prank(sp);
        st.notifyRewards(0, n);
    }

    function _solvent() internal view {
        (uint256 cw, uint256 cn) = st.committedRewards();
        (,,,, uint256 ts, uint256 tc, uint256 br) = st.rewardInfo();
        assertGe(IERC20(WE).balanceOf(address(st)), cw, "weth");
        assertGe(IERC20(NL).balanceOf(address(st)), ts + tc + br + cn, "nlyra");
    }

    /// Referencia a mano: lock 14d (1.5x) vs flexible, dos tramos, el segundo cruza el vencimiento.
    function test_te_exactVsReference() public {
        uint256 M0 = (vm.getBlockTimestamp() / 1 days + 1) * 1 days;
        uint256 t0 = M0 + 10 hours;
        vm.warp(t0);
        _stake(alice, 100e18, 2);
        _stake(bob, 100e18, 0);
        uint256 U = M0 + 15 days;
        assertEq(st.positionsOf(alice)[0].unlockTime, U);
        _notifyW(7 ether);
        _notifyN(0); // no-op? (same free) -> should be skipped
        assertEq(st.tranches().length, 1, "second notify w/o new funds skipped");
        uint256 r1 = st.tranches()[0].rateWeth;
        uint256 t1 = U - 3 days + 5 hours;
        vm.warp(t1);
        _notifyW(3 ether);
        RealYieldStaking.Tranche[] memory tr = st.tranches();
        assertEq(tr.length, 1);
        uint256 r2 = tr[0].rateWeth;
        uint256 e2 = tr[0].end;
        vm.warp(U + 10 days);
        (uint256 aw,) = st.earned(alice);
        (uint256 bw,) = st.earned(bob);
        uint256 pre = U - t1;
        uint256 post = e2 - U;
        uint256 expA = r1 * 7 days * 150 / 250 + r2 * pre * 150 / 250 + r2 * post / 2;
        uint256 expB = r1 * 7 days * 100 / 250 + r2 * pre * 100 / 250 + r2 * post / 2;
        console.log("alice got/exp", aw, expA);
        console.log("bob   got/exp", bw, expB);
        assertApproxEqAbs(aw, expA, 10);
        assertApproxEqAbs(bw, expB, 10);
        vm.prank(alice);
        st.claim(RealYieldStaking.OutMode.AS_IS, 0);
        vm.prank(bob);
        st.claim(RealYieldStaking.OutMode.AS_IS, 0);
        (uint256 cw,) = st.committedRewards();
        console.log("WETH left", IERC20(WE).balanceOf(address(st)), "committed", cw);
        _solvent();
    }

    function test_te_zeroSupplyRecycles() public {
        _notifyW(7 ether);
        uint256 r = st.tranches()[0].rateWeth;
        vm.warp(vm.getBlockTimestamp() + 3 days);
        _stake(alice, 1e18, 0);
        vm.warp(vm.getBlockTimestamp() + 5 days);
        (uint256 aw,) = st.earned(alice);
        assertApproxEqAbs(aw, r * 4 days, 5, "alice only the 4 remaining days");
        _notifyN(0);
        RealYieldStaking.Tranche[] memory tr = st.tranches();
        assertEq(tr.length, 1);
        assertApproxEqAbs(uint256(tr[0].rateWeth) * 7 days, 7 ether - r * 4 days, 7 days + 10);
        _solvent();
    }

    /// Antes (8 tramos) la cola llena fusionaba en el mas nuevo y lo re-estiraba. Ahora (16) lo salta:
    /// ningun tramo se mueve y el saldo queda libre para el proximo.
    function test_te_fullQueueSkips_noStretch() public {
        _stake(alice, 1e18, 0);
        for (uint256 i; i < 16; ++i) {
            _notifyW(1 ether);
            vm.warp(vm.getBlockTimestamp() + 1 hours);
        }
        RealYieldStaking.Tranche[] memory tr = st.tranches();
        assertEq(tr.length, 16);
        uint256 oldEnd = tr[15].end;
        uint256 oldRate = tr[15].rateWeth;
        _notifyW(1 ether);
        tr = st.tranches();
        assertEq(tr.length, 16);
        assertEq(tr[15].end, oldEnd, "newest end not moved");
        assertEq(tr[15].rateWeth, oldRate, "newest rate not moved");
        _solvent();
    }
}

contract R2TrancheGasTE is R2TrancheEngineTE {
    /// costo de ponerse al dia tras N dias sin ninguna accion (con 90 medianoches con baja de boost)
    function test_te_catchUpGas() public {
        _stake(alice, 1e18, 0);
        _notifyW(7 ether);
        for (uint256 d; d < 90; ++d) {
            _stake(bob, 1e18, 3); // un lock que vence en una medianoche distinta cada dia
            vm.warp(vm.getBlockTimestamp() + 1 days);
            if (d % 25 == 24) {
                vm.startPrank(bob);
                vm.stopPrank();
            }
            if (d == 30) break; // 31 slots max per wallet -> use carol after
        }
        for (uint256 d; d < 31; ++d) {
            _stake(carol, 1e18, 3);
            vm.warp(vm.getBlockTimestamp() + 1 days);
        }
        // now idle for 3 years
        vm.warp(vm.getBlockTimestamp() + 3 * 365 days);
        uint256 g0 = gasleft();
        vm.prank(alice);
        st.requestUnstake(1e18);
        console.log("gas requestUnstake after 3y idle (~62 drop midnights)", g0 - gasleft());
    }
}

contract R2TrancheFuzzTE is R2TrancheEngineTE {
    /// Secuencia aleatoria: notifies (>= 1 dia o directos), stakes/locks/extend/unstake/claim, saltos
    /// que cruzan medianoches y fines de tramo. Al final, todo emitido con stakers se paga salvo polvo.
    function testFuzz_te_allPaidOut(uint256 seed) public {
        address[3] memory us = [alice, bob, carol];
        _stake(alice, 1e18, 0);
        uint256 funded;
        for (uint256 k; k < 40; ++k) {
            uint256 r = uint256(keccak256(abi.encode(seed, k)));
            address u = us[r % 3];
            uint256 op = (r >> 8) % 8;
            if (op == 0) { uint256 w = ((r >> 16) % 100 ether) + 1e12; _notifyW(w); funded += w; }
            else if (op == 1) _stake(u, ((r >> 16) % 1000e18) + 1, 0);
            else if (op == 2) _stake(u, ((r >> 16) % 1000e18) + 3, uint8(1 + (r >> 80) % 3));
            else if (op == 3) {
                (RealYieldStaking.Account memory a,,,) = st.userInfo(u);
                if (a.flexible > 1) { vm.prank(u); st.requestUnstake(a.flexible / 2); }
            } else if (op == 4) {
                (uint256 ew, uint256 en) = st.earned(u);
                if (ew + en > 0) { vm.prank(u); st.claim(RealYieldStaking.OutMode.AS_IS, 0); }
            } else if (op == 5) {
                RealYieldStaking.Position[] memory ps = st.positionsOf(u);
                for (uint256 i; i < ps.length; ++i) {
                    if (ps[i].amount != 0 && ps[i].unlockTime <= block.timestamp) { vm.prank(u); st.withdrawLocked(i); break; }
                    if (ps[i].amount != 0 && ps[i].tier <= 2 && ps[i].unlockTime > block.timestamp) { vm.prank(u); st.extendLock(i, 3); break; }
                }
            }
            vm.warp(vm.getBlockTimestamp() + ((r >> 120) % 20 days));
            _solvent();
        }
        vm.warp(vm.getBlockTimestamp() + 100 days);
        uint256 got;
        for (uint256 i; i < 3; ++i) {
            (uint256 ew, uint256 en) = st.earned(us[i]);
            if (ew + en > 0) { vm.prank(us[i]); st.claim(RealYieldStaking.OutMode.AS_IS, 0); }
            got += IERC20(WE).balanceOf(us[i]);
        }
        (uint256 cw,) = st.committedRewards();
        uint256 left = IERC20(WE).balanceOf(address(st));
        assertEq(got + left, funded);
        assertLe(cw, 200, "stuck dust bounded");
        // tb was always > 0 (alice keeps >= 1 wei flex? not guaranteed) -> left = recycled, not lost
        assertGe(left, cw);
    }
}
