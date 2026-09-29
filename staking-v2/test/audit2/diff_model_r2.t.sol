// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ForkBase} from "../ForkBase.sol";
import {RealYieldStaking} from "../../src/RealYieldStaking.sol";
import {NlyraFeeSplitter} from "../../src/NlyraFeeSplitter.sol";
import {console2} from "forge-std/Test.sol";

contract MockTok {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;
    uint8 public constant decimals = 18;
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { balanceOf[msg.sender] -= a; balanceOf[to] += a; return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

contract MockPool {
    address public token0;
    address public token1;
    uint24 public fee;
    function init(address a, address b, uint24 f) external { token0 = a; token1 = b; fee = f; }
    function factory() external pure returns (address) { return 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA; }
    function swap(address, bool, int256, uint160, bytes calldata) external pure returns (int256, int256) { revert("no swaps"); }
}

/// Differential test (audit round 2): independent reference model of the reward split
/// (pro-rata by boosted weight over time, boost ends exactly at the lock's unlock midnight, each
/// tranche emits its own rate until its own end), cooldown and eligibleBalance.
/// Rewards are injected by deal + notify pranked as the splitter (no pool / locker touched).
contract DiffModelR2 is ForkBase {
    uint256 constant SCALE = 1e18;
    uint256 constant N = 4;

    struct MPos {
        uint256 amt;
        uint8 tier;
        uint256 unlock;
    }

    struct MTr {
        uint256 rw;
        uint256 rn;
        uint256 end;
        uint256 erw;
        uint256 ern;
    }

    struct Hist {
        uint256 t;
        uint256 active;
    }

    // model state
    address[N] us;
    uint256[N] mFlex;
    uint256[N] mCool;
    uint256[N] mCoolEnd;
    MPos[32][N] mPos;
    uint256[4][N] mEarned; // scaled by SCALE (W, N, W elegible, N elegible)
    uint256[4][N] got; // what the contract actually handed out (claims + compound)
    MTr[] mTr;
    uint256 mLast;
    Hist[][N] hist;
    bool wethRewards;
    uint256 rng;
    uint256 steps;
    uint256 maxUnder;
    uint256 maxOver;
    uint256 maxEligGap;
    uint256[14] opCount;
    uint256 compoundsInto;
    uint256 sweeps;
    uint256[2] injected;
    uint256 mReserve;
    uint256 burstNotify;
    bool burstMode;

    /// No fork: mock tokens/pools are etched at the REAL addresses, so the constructor's
    /// CREATE2(factory, token0, token1, fee) + fee tier check passes unchanged.
    function setUp() public override {
        vm.warp(1790000000 + 12345);
        MockTok t = new MockTok();
        vm.etch(address(NLYRA), address(t).code);
        vm.etch(address(WETH), address(t).code);
        vm.etch(address(USDG), address(t).code);
        MockPool mp = new MockPool();
        vm.etch(POOL_NLYRA, address(mp).code);
        vm.etch(POOL_USDG, address(mp).code);
        MockPool(POOL_NLYRA).init(address(WETH), address(NLYRA), 10000);
        MockPool(POOL_USDG).init(address(WETH), address(USDG), 100);
        vm.etch(address(LOCKER), hex"00"); // el splitter exige que el locker tenga codigo
        owner = _fresh("owner");
        alice = _fresh("alice");
        bob = _fresh("bob");
        carol = _fresh("carol");
        dave = _fresh("dave");
        st = new RealYieldStaking(
            owner, address(NLYRA), address(WETH), address(USDG), POOL_NLYRA, POOL_USDG, address(LOCKER), TREASURY,
            5_000, 1 days
        );
        sp = NlyraFeeSplitter(payable(st.feeSplitter()));
    }

    function _r() internal returns (uint256) {
        rng = uint256(keccak256(abi.encode(rng)));
        return rng;
    }

    function _boost(uint256 amt, uint8 tier) internal pure returns (uint256) {
        return (amt * (tier == 1 ? 12_500 : tier == 2 ? 15_000 : tier == 3 ? 20_000 : 10_000)) / 10_000;
    }

    function _unlock(uint8 tier) internal view returns (uint256) {
        uint256 d = tier == 1 ? 7 days : tier == 2 ? 14 days : 30 days;
        return ((block.timestamp + d + 1 days - 1) / 1 days) * 1 days;
    }

    function _wAt(uint256 k, uint256 t) internal view returns (uint256 w) {
        w = mFlex[k];
        for (uint256 i; i < 32; ++i) {
            MPos storage p = mPos[k][i];
            if (p.amt == 0) continue;
            w += (p.tier != 0 && t < p.unlock) ? _boost(p.amt, p.tier) : p.amt;
        }
    }

    /// advance the model from mLast to `to`, splitting at every tranche end and every lock unlock.
    function _mAdvance(uint256 to) internal {
        while (mLast < to) {
            uint256 next = to;
            for (uint256 j; j < mTr.length; ++j) {
                if (mTr[j].end > mLast && mTr[j].end < next) next = mTr[j].end;
            }
            for (uint256 k; k < N; ++k) {
                for (uint256 i; i < 32; ++i) {
                    MPos storage p = mPos[k][i];
                    if (p.amt != 0 && p.tier != 0 && p.unlock > mLast && p.unlock < next) next = p.unlock;
                }
            }
            uint256 dt = next - mLast;
            uint256[4] memory r;
            for (uint256 j; j < mTr.length; ++j) {
                if (mTr[j].end > mLast) {
                    r[0] += mTr[j].rw;
                    r[1] += mTr[j].rn;
                    r[2] += mTr[j].erw;
                    r[3] += mTr[j].ern;
                }
            }
            uint256[N] memory w;
            uint256 W;
            for (uint256 k; k < N; ++k) {
                w[k] = _wAt(k, mLast);
                W += w[k];
            }
            if (W != 0) {
                for (uint256 k; k < N; ++k) {
                    for (uint256 i; i < 4; ++i) mEarned[k][i] += (r[i] * dt * SCALE * w[k]) / W;
                }
            }
            mLast = next;
        }
    }

    function _active(uint256 k) internal view returns (uint256 a) {
        a = mFlex[k];
        for (uint256 i; i < 32; ++i) {
            a += mPos[k][i].amt;
        }
    }

    function _rec(uint256 k) internal {
        hist[k].push(Hist(block.timestamp, _active(k)));
    }

    /// true "aged" stake: min of active over [now-24h, now]
    function _eligModel(uint256 k) internal view returns (uint256 m) {
        Hist[] storage h = hist[k];
        uint256 from = block.timestamp >= 24 hours ? block.timestamp - 24 hours : 0;
        m = type(uint256).max;
        bool before;
        for (uint256 i = h.length; i > 0; --i) {
            Hist storage e = h[i - 1];
            if (e.t <= from) {
                if (e.active < m) m = e.active;
                before = true;
                break;
            }
            if (e.active < m) m = e.active;
        }
        if (!before) m = 0;
    }

    // ---------------------------------------------------------------- ops

    function _opStake(uint256 k, uint8 tier) internal {
        address u = us[k];
        uint256 amt = (_r() % 5_000_000 + 1) * 1e18 + (_r() % 1e18);
        if (tier != 0) {
            uint256 free = 32;
            for (uint256 i; i < 32; ++i) {
                if (mPos[k][i].amt == 0) {
                    free = i;
                    break;
                }
            }
            if (free == 32) return;
            _stake(u, amt, tier);
            RealYieldStaking.Position[] memory ps = st.positionsOf(u);
            assertEq(ps[free].amount, amt, "slot reuse id");
            uint256 unlock = _unlock(tier);
            assertEq(ps[free].unlockTime, unlock, "unlock");
            mPos[k][free] = MPos(amt, tier, unlock);
        } else {
            _stake(u, amt, 0);
            mFlex[k] += amt;
        }
        _rec(k);
    }

    function _startCool(uint256 k, uint256 amt) internal returns (uint256 matured) {
        if (mCool[k] != 0 && block.timestamp >= mCoolEnd[k]) {
            matured = mCool[k];
            mCool[k] = 0;
        }
        mCool[k] += amt;
        mCoolEnd[k] = block.timestamp + 2 days;
    }

    function _opUnstake(uint256 k) internal {
        if (mFlex[k] == 0) return;
        uint256 amt = _r() % mFlex[k] + 1;
        uint256 b0 = NLYRA.balanceOf(us[k]);
        vm.prank(us[k]);
        st.requestUnstake(amt);
        mFlex[k] -= amt;
        uint256 matured = _startCool(k, amt);
        assertEq(NLYRA.balanceOf(us[k]) - b0, matured, "matured paid");
        _rec(k);
    }

    function _opWithdraw(uint256 k) internal {
        if (mCool[k] == 0 || block.timestamp < mCoolEnd[k]) {
            vm.prank(us[k]);
            vm.expectRevert();
            st.withdraw();
            return;
        }
        uint256 b0 = NLYRA.balanceOf(us[k]);
        vm.prank(us[k]);
        st.withdraw();
        assertEq(NLYRA.balanceOf(us[k]) - b0, mCool[k], "withdraw amt");
        mCool[k] = 0;
    }

    function _opCancel(uint256 k) internal {
        if (mCool[k] == 0) return;
        vm.prank(us[k]);
        st.cancelUnstake();
        mFlex[k] += mCool[k];
        mCool[k] = 0;
        _rec(k);
    }

    function _pickOpen(uint256 k) internal returns (uint256 id, bool ok) {
        uint256 s = _r() % 32;
        for (uint256 j; j < 32; ++j) {
            uint256 i = (s + j) % 32;
            if (mPos[k][i].amt != 0) return (i, true);
        }
    }

    function _opWithdrawLocked(uint256 k) internal {
        (uint256 id, bool ok) = _pickOpen(k);
        if (!ok) return;
        MPos storage p = mPos[k][id];
        if (block.timestamp < p.unlock) {
            vm.prank(us[k]);
            vm.expectRevert();
            st.withdrawLocked(id);
            return;
        }
        uint256 amt = p.amt;
        uint256 b0 = NLYRA.balanceOf(us[k]);
        vm.prank(us[k]);
        st.withdrawLocked(id);
        delete mPos[k][id];
        uint256 matured = _startCool(k, amt);
        assertEq(NLYRA.balanceOf(us[k]) - b0, matured, "matured paid (lock)");
        _rec(k);
    }

    function _opExtend(uint256 k) internal {
        (uint256 id, bool ok) = _pickOpen(k);
        if (!ok) return;
        MPos storage p = mPos[k][id];
        uint8 tier = uint8(_r() % 3 + 1);
        uint256 unlock = _unlock(tier);
        bool expired = block.timestamp >= p.unlock;
        bool should = expired || (tier >= p.tier && unlock >= p.unlock);
        vm.prank(us[k]);
        if (!should) {
            vm.expectRevert();
            st.extendLock(id, tier);
            return;
        }
        st.extendLock(id, tier);
        p.tier = tier;
        p.unlock = unlock;
    }

    function _opClaim(uint256 k) internal {
        (uint256 ew, uint256 en) = st.earned(us[k]);
        if (ew == 0 && en == 0) return;
        (uint256 bw, uint256 bn) = st.earnedBonusEligible(us[k]);
        got[k][2] += bw;
        got[k][3] += bn;
        uint256 w0 = WETH.balanceOf(us[k]);
        uint256 n0 = NLYRA.balanceOf(us[k]);
        vm.prank(us[k]);
        st.claim(RealYieldStaking.OutMode.AS_IS, 0);
        uint256 dw = WETH.balanceOf(us[k]) - w0;
        uint256 dn = NLYRA.balanceOf(us[k]) - n0;
        assertEq(dw, ew, "claim == earned view (w)");
        assertEq(dn, en, "claim == earned view (n)");
        got[k][0] += dw;
        got[k][1] += dn;
    }

    function _opCompound(uint256 k) internal {
        if (wethRewards) return;
        (, uint256 en) = st.earned(us[k]);
        if (en == 0) return;
        (uint256 bw, uint256 bn) = st.earnedBonusEligible(us[k]);
        uint8 tier = uint8(_r() % 4);
        uint256 free = 32;
        for (uint256 i; i < 32; ++i) {
            if (mPos[k][i].amt == 0) {
                free = i;
                break;
            }
        }
        // a veces dentro de un lock abierto (compound a lock existente, ronda 2 hallazgo D)
        uint256 into = 32;
        if (tier != 0 && _r() % 2 == 0) {
            (uint256 id, bool ok) = _pickOpen(k);
            if (ok) {
                MPos storage q = mPos[k][id];
                bool expired = block.timestamp >= q.unlock;
                if (expired || (tier >= q.tier && _unlock(tier) >= q.unlock)) into = id;
            }
        }
        if (tier != 0 && into == 32 && free == 32) return;
        vm.prank(us[k]);
        st.compound(0, tier, into == 32 ? type(uint256).max : into);
        got[k][1] += en;
        got[k][0] += 0;
        got[k][2] += bw;
        got[k][3] += bn;
        if (tier == 0) {
            mFlex[k] += en;
        } else {
            uint256 bonus;
            if (tier == 3) {
                bonus = (bn * 500) / 10_000;
                if (bonus > mReserve) bonus = mReserve;
            }
            mReserve -= bonus;
            uint256 unlock = _unlock(tier);
            if (into == 32) {
                mPos[k][free] = MPos(en + bonus, tier, unlock);
                assertEq(st.positionsOf(us[k])[free].amount, en + bonus, "compound lock amt");
            } else {
                MPos storage q = mPos[k][into];
                q.amt += en + bonus;
                q.tier = tier;
                q.unlock = unlock;
                assertEq(st.positionsOf(us[k])[into].amount, q.amt, "compound into lock amt");
                compoundsInto++;
            }
        }
        _rec(k);
    }

    function _opKick(uint256 k) internal {
        (uint256 id, bool ok) = _pickOpen(k);
        if (!ok) return;
        RealYieldStaking.Position memory p = st.positionsOf(us[k])[id];
        if (block.timestamp < p.unlockTime || p.tier == 0) return;
        st.kick(us[k], id);
    }

    /// Mete premios: la mitad de las veces "como el splitter" (notify con esos montos elegibles para el
    /// bonus), la otra mitad como donacion + sweepDonations (nada elegible; si el timer no deja, el saldo
    /// queda libre y lo toma el proximo tramo).
    function _opNotify() internal {
        uint256 w = wethRewards ? (_r() % 50 ether) : 0;
        uint256 n = (_r() % 2_000_000) * 1e18 + (_r() % 1e18);
        bool viaSplitter = _r() % 2 == 0;
        if (w != 0) deal(address(WETH), address(st), WETH.balanceOf(address(st)) + w);
        deal(address(NLYRA), address(st), NLYRA.balanceOf(address(st)) + n);
        injected[0] += w;
        injected[1] += n;
        RealYieldStaking.Tranche[] memory before = st.tranches();
        uint256[2] memory expFree = _expectedFree();
        uint256[2] memory eligIn;
        if (viaSplitter) {
            eligIn = [w, n];
            vm.prank(address(sp));
            st.notifyRewards(w, n);
        } else if (block.timestamp >= uint256(st.lastDonationSweep()) + 1 days) {
            st.sweepDonations();
            sweeps++;
        } else {
            return; // queda libre para el proximo tramo
        }
        RealYieldStaking.Tranche[] memory aft = st.tranches();
        for (uint256 j; j < before.length; ++j) {
            assertEq(aft[j].end, before[j].end, "old tranche end touched");
            assertEq(aft[j].rateWeth, before[j].rateWeth, "old tranche rate touched");
            assertEq(aft[j].rateNlyra, before[j].rateNlyra, "old tranche rate touched");
            assertEq(aft[j].eligWeth, before[j].eligWeth, "old tranche elig touched");
            assertEq(aft[j].eligNlyra, before[j].eligNlyra, "old tranche elig touched");
        }
        if (aft.length == before.length + 1) {
            RealYieldStaking.Tranche memory nt = aft[aft.length - 1];
            assertApproxEqAbs(uint256(nt.rateWeth), expFree[0] / 7 days, 3, "new tranche WETH != free");
            assertApproxEqAbs(uint256(nt.rateNlyra), expFree[1] / 7 days, 3, "new tranche NLYRA != free");
            uint256 ew = eligIn[0] < expFree[0] ? eligIn[0] : expFree[0];
            uint256 en = eligIn[1] < expFree[1] ? eligIn[1] : expFree[1];
            assertApproxEqAbs(uint256(nt.eligWeth), ew / 7 days, 3, "elig WETH");
            assertApproxEqAbs(uint256(nt.eligNlyra), en / 7 days, 3, "elig NLYRA");
            assertLe(nt.eligWeth, nt.rateWeth);
            assertLe(nt.eligNlyra, nt.rateNlyra);
        } else {
            assertEq(aft.length, before.length, "tranche count");
            // saltado: polvo o cola llena (16), nunca con saldo libre real y lugar en la cola
            if (before.length < 16) {
                assertTrue(expFree[0] < 2e12 && expFree[1] < 2e18, "skipped notify with real free balance");
            } else {
                burstNotify++;
            }
        }
        delete mTr;
        for (uint256 j; j < aft.length; ++j) {
            mTr.push(MTr(aft[j].rateWeth, aft[j].rateNlyra, aft[j].end, aft[j].eligWeth, aft[j].eligNlyra));
        }
    }

    /// free = injected - handed out - model accrued (unclaimed) - model pending emission
    function _expectedFree() internal view returns (uint256[2] memory f) {
        for (uint256 i; i < 2; ++i) {
            uint256 used;
            for (uint256 k; k < N; ++k) used += mEarned[k][i] / SCALE; // cumulative (claimed + unclaimed)
            for (uint256 j; j < mTr.length; ++j) {
                if (mTr[j].end > block.timestamp) used += (i == 0 ? mTr[j].rw : mTr[j].rn) * (mTr[j].end - block.timestamp);
            }
            f[i] = injected[i] > used ? injected[i] - used : 0;
        }
    }

    function _opFund() internal {
        uint256 a = (_r() % 100_000 + 1) * 1e18;
        _fund(owner, a);
        mReserve += a;
    }

    function _warp() internal {
        uint256 c = _r() % 6;
        if (rng & 1 == 1 && burstMode) c = _r() % 2; // many actions within a few hours
        uint256 t = block.timestamp;
        uint256 nt;
        if (c == 0) nt = t;
        else if (c == 1) nt = t + _r() % 3600;
        else if (c == 2) nt = t + _r() % 3 days;
        else if (c == 3) nt = t + _r() % 20 days;
        else if (c == 4) nt = (t / 1 days + 1) * 1 days; // exact midnight
        else nt = (t / 1 days + 1) * 1 days - 1;
        vm.warp(nt);
    }

    function _compare(bool fin) internal {
        _mAdvance(block.timestamp);
        for (uint256 k; k < N; ++k) {
            (uint256 ew, uint256 en) = st.earned(us[k]);
            (uint256 bw, uint256 bn) = st.earnedBonusEligible(us[k]);
            assertLe(bw, ew, "elig > earned (w)");
            assertLe(bn, en, "elig > earned (n)");
            uint256[4] memory c = [got[k][0] + ew, got[k][1] + en, got[k][2] + bw, got[k][3] + bn];
            for (uint256 i; i < 4; ++i) {
                uint256 m = mEarned[k][i] / SCALE;
                // rounding: at most ~1 wei per user settlement + per accrual step; allow 1e-12 relative + 1e6 wei
                uint256 tol = m / 1e12 + 1e6;
                if (c[i] > m) {
                    if (c[i] - m > maxOver) maxOver = c[i] - m;
                    assertLe(c[i], m + tol, "OVERPAID vs model");
                } else {
                    if (m - c[i] > maxUnder) maxUnder = m - c[i];
                    assertGe(c[i] + tol, m, "UNDERPAID vs model");
                }
            }
            // eligible balance never above the true 24h-aged stake
            uint256 el = st.eligibleBalance(us[k]);
            uint256 em = _eligModel(k);
            assertLe(el, em, "eligibleBalance > aged stake");
            if (em - el > maxEligGap) maxEligGap = em - el;
            // model mirrors positions, weights
            assertEq(st.boostedBalanceOf(us[k]), _wAt(k, block.timestamp), "weight");
            assertEq(st.stakeOf(us[k]), _active(k), "active");
        }
        if (fin) {
            _checkSolvency(_users(), true);
            assertEq(st.bonusReserve(), mReserve, "reserve");
        }
    }

    function _run(uint256 seed, bool withWeth, uint256 nSteps) internal {
        rng = seed;
        wethRewards = withWeth;
        us[0] = alice;
        us[1] = bob;
        us[2] = carol;
        us[3] = dave;
        mLast = block.timestamp;
        for (uint256 s; s < nSteps; ++s) {
            uint256 k = _r() % N;
            uint256 op = _r() % 14;
            if (op == 0) _opStake(k, 0);
            else if (op == 1 || op == 13) _opStake(k, uint8(_r() % 3 + 1));
            else if (op == 2) _opUnstake(k);
            else if (op == 3) _opWithdraw(k);
            else if (op == 4) _opCancel(k);
            else if (op == 5) _opWithdrawLocked(k);
            else if (op == 6) _opExtend(k);
            else if (op == 7) _opClaim(k);
            else if (op == 8 || op == 11) _opNotify();
            else if (op == 9) _opKick(k);
            else if (op == 12) _opFund();
            else _opCompound(k);
            _compare(false);
            opCount[op]++;
            steps++;
            _mAdvance(block.timestamp);
            _warp();
            _mAdvance(block.timestamp);
        }
        _compare(true);
        console2.log("max under / over (wei)", maxUnder, maxOver);
        console2.log("max eligible conservative gap", maxEligGap);
        for (uint256 i; i < 14; ++i) console2.log("op", i, opCount[i]);
        console2.log("full-queue skipped notifies", burstNotify);
        console2.log("compounds into existing lock", compoundsInto);
        console2.log("sweepDonations", sweeps);
        (uint256 tw, uint256 tn) = (got[0][0] + got[1][0] + got[2][0] + got[3][0], got[0][1] + got[1][1] + got[2][1] + got[3][1]);
        console2.log("total handed out w/n", tw, tn);
    }

    function testFuzz_diff_nlyraOnly(uint256 seed) public {
        _run(seed, false, 150);
    }

    function testFuzz_diff_both(uint256 seed) public {
        _run(seed, true, 150);
    }

    function testFuzz_diff_burst(uint256 seed) public {
        burstMode = true;
        _run(seed, true, 150);
    }

    function test_diff_fixedSeed() public {
        _run(0xabc, true, 200);
    }

    /// cola llena (16 tramos, notify directo cada hora) + vencimientos de locks, contra el modelo
    function test_diff_fullQueue() public {
        rng = 7;
        wethRewards = true;
        us[0] = alice; us[1] = bob; us[2] = carol; us[3] = dave;
        mLast = block.timestamp;
        _opStake(0, 3);
        _opStake(1, 0);
        _opStake(2, 1);
        for (uint256 i; i < 40; ++i) {
            _opNotify();
            _compare(false);
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            _mAdvance(block.timestamp);
        }
        vm.warp(vm.getBlockTimestamp() + 35 days);
        _mAdvance(block.timestamp);
        _compare(true);
        console2.log("full-queue skipped notifies", burstNotify);
        console2.log("max under / over (wei)", maxUnder, maxOver);
    }
}
