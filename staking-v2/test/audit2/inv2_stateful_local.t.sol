// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// Round-2 audit: stateful invariant fuzz, LOCAL (no fork). Mock tokens + mock locker + mock v3 pools
// etched at the CREATE2 addresses the constructor validates. Many actors, all external functions, an
// independent reference model of per-user rewards (exact, piecewise over tranche ends and midnights),
// including the bonus-eligible part (what came from the splitter).
// Ronda 2 (arreglos): tiers 7d/14d/30d, compound(minOut, tier, positionId) (lock nuevo o existente),
// bonus 5% solo a 30d y solo sobre lo elegible, sweepDonations, pausa acotada, eligibleBalance por dias.
// Ronda 3: transferPosition (offer/accept, con tercero que intenta aceptar y cancelaciones). El modelo mueve
// el lock al primer slot libre del que recibe y lo marca como aporte nuevo; el modelo de premios por peso
// verifica que el que entrega se queda lo devengado y el que recibe gana desde ahi. marketSale hace lo mismo
// por el PositionMarket (oferta al mercado, publicacion, compra con ETH exacto, fee 50 bps al splitter).

import {Test, console2} from "forge-std/Test.sol";
import {Math} from "oz/utils/math/Math.sol";
import {RealYieldStaking} from "../../src/RealYieldStaking.sol";
import {NlyraFeeSplitter} from "../../src/NlyraFeeSplitter.sol";
import {PositionMarket} from "../../src/PositionMarket.sol";

contract MToken {
    string public name;
    uint8 public decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    constructor(string memory n, uint8 d) {
        name = n;
        decimals = d;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
        totalSupply += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        uint256 al = allowance[f][msg.sender];
        if (al != type(uint256).max) allowance[f][msg.sender] = al - a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }

    // WETH
    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
        totalSupply += msg.value;
    }
}

interface ICb {
    function uniswapV3SwapCallback(int256, int256, bytes calldata) external;
}

/// v3-like pool with a fixed price; exact-input only; pays out first, then calls back, then checks it was paid.
contract MPool {
    address public token0;
    address public token1;
    uint24 public fee;
    uint256 public px; // token1 per token0 * 1e18

    function init(address t0, address t1, uint24 f, uint256 p) external {
        token0 = t0;
        token1 = t1;
        fee = f;
        px = p;
    }

    function factory() external pure returns (address) {
        return 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    }

    function swap(address r, bool z, int256 amt, uint160, bytes calldata d) external returns (int256 a0, int256 a1) {
        require(amt > 0, "exact in only");
        uint256 inA = uint256(amt);
        uint256 out = z ? (inA * px) / 1e18 : (inA * 1e18) / px;
        address tin = z ? token0 : token1;
        address tout = z ? token1 : token0;
        if (out != 0) MToken(tout).transfer(r, out);
        uint256 b0 = MToken(tin).balanceOf(address(this));
        (a0, a1) = z ? (int256(inA), -int256(out)) : (-int256(out), int256(inA));
        ICb(msg.sender).uniswapV3SwapCallback(a0, a1, d);
        require(MToken(tin).balanceOf(address(this)) >= b0 + inA, "IIA");
    }
}

contract MLocker {
    error NotAuthorized();
    error NoFeesToCollect();
    error Other();

    mapping(address => address) public feeRedirects;
    uint8 public mode; // 0 no fees, 1 pay, 2 not authorized, 3 other error
    MToken public w;
    MToken public n;

    constructor(MToken w_, MToken n_) {
        w = w_;
        n = n_;
    }

    function setMode(uint8 m) external {
        mode = m;
    }

    function setFeeRedirect(address t, address to) external {
        feeRedirects[t] = to;
    }

    function collectFees(address t) external returns (uint256, uint256) {
        if (mode == 0) revert NoFeesToCollect();
        if (mode == 2) revert NotAuthorized();
        if (mode == 3) revert Other();
        address to = feeRedirects[t];
        uint256 a = w.balanceOf(address(this));
        uint256 b = n.balanceOf(address(this));
        if (a == 0 && b == 0) revert NoFeesToCollect();
        w.transfer(to, a);
        n.transfer(to, b);
        return (a, b);
    }
}

contract Handler is Test {
    RealYieldStaking public st;
    NlyraFeeSplitter public sp;
    MToken public N;
    MToken public W;
    MLocker public L;
    address public owner;
    address[] public actors;

    uint256 constant PX = 10_000_000e18; // 1 WETH = 1e7 NLYRA (token-order handled in pool)
    uint256 constant NEW = type(uint256).max;

    // ------------------------------------------------ mirror model
    struct Pos {
        uint128 amount;
        uint64 unlock;
        uint8 tier; // 1 / 2 / 3 ; boosted while unlock > t
        bool open;
    }

    struct Tr {
        uint256 rw;
        uint256 rn;
        uint256 end;
        uint256 erw; // bonus-eligible part
        uint256 ern;
    }

    mapping(address => uint256) public mFlex;
    mapping(address => uint256) public mCool;
    mapping(address => uint256) public mCoolEnd;
    mapping(address => Pos[]) internal mPos;
    Tr[] internal mTr;
    uint256 public refLast;
    mapping(address => uint256[4]) public refCumX; // exact reward (W, N, W elig, N elig), scaled 1e18
    mapping(address => uint256[4]) public claimed; // what the contract paid/compounded (reward units)
    // eligibleBalance model: increases in time order
    mapping(address => uint256[]) internal incT;
    mapping(address => uint256[]) internal incA;

    // ------------------------------------------------ ghosts
    uint256[2] public inflow; // reward tokens that entered staking (splitter + donations)
    uint256[2] public notified; // sum of tranche amounts (rate * 7d) created
    uint256 public deposited; // principal in (stake, locks, compound total+bonus)
    uint256 public withdrawnP; // principal out
    uint256 public funded;
    uint256 public bonusOut;
    uint256 public maxTranches;
    string public failure; // first unexpected behaviour
    PositionMarket public mk; // ronda 3
    uint256 public salesPaid; // ETH pagado por compradores
    uint256 public salesFees; // ETH de comision al splitter
    mapping(string => uint256) public calls;

    constructor(RealYieldStaking st_, MToken n_, MToken w_, MLocker l_, address owner_, uint256 nActors) {
        st = st_;
        sp = NlyraFeeSplitter(payable(st_.feeSplitter()));
        N = n_;
        W = w_;
        L = l_;
        owner = owner_;
        for (uint256 i; i < nActors; ++i) {
            address a = makeAddr(string.concat("actor", vm.toString(i)));
            actors.push(a);
            vm.prank(a);
            N.approve(address(st), type(uint256).max);
        }
        refLast = block.timestamp;
    }

    function nActors() external view returns (uint256) {
        return actors.length;
    }

    function _fail(string memory s) internal {
        if (bytes(failure).length == 0) failure = s;
    }

    function _paused() internal view returns (bool) {
        return st.paused();
    }

    // ------------------------------------------------ reference model
    function _boosted(uint256 amt, uint256 tier) internal pure returns (uint256) {
        return (amt * (tier == 1 ? 12_500 : tier == 2 ? 15_000 : tier == 3 ? 20_000 : 10_000)) / 10_000;
    }

    function _wOf(address u, uint256 t) internal view returns (uint256 w) {
        w = mFlex[u];
        Pos[] storage ps = mPos[u];
        for (uint256 i; i < ps.length; ++i) {
            if (!ps[i].open) continue;
            w += ps[i].unlock > t ? _boosted(ps[i].amount, ps[i].tier) : ps[i].amount;
        }
    }

    function _sync() internal {
        uint256 to = block.timestamp;
        while (refLast < to) {
            uint256 next = (refLast / 1 days + 1) * 1 days;
            if (next > to) next = to;
            uint256[4] memory r;
            for (uint256 k; k < mTr.length; ++k) {
                if (mTr[k].end > refLast) {
                    if (mTr[k].end < next) next = mTr[k].end;
                    r[0] += mTr[k].rw;
                    r[1] += mTr[k].rn;
                    r[2] += mTr[k].erw;
                    r[3] += mTr[k].ern;
                }
            }
            uint256 dt = next - refLast;
            uint256 tot;
            uint256 na = actors.length;
            uint256[] memory ws = new uint256[](na);
            for (uint256 i; i < na; ++i) {
                ws[i] = _wOf(actors[i], refLast);
                tot += ws[i];
            }
            if (tot != 0 && (r[0] != 0 || r[1] != 0)) {
                for (uint256 i; i < na; ++i) {
                    if (ws[i] == 0) continue;
                    for (uint256 j; j < 4; ++j) {
                        if (r[j] != 0) refCumX[actors[i]][j] += Math.mulDiv(r[j] * dt, ws[i] * 1e18, tot);
                    }
                }
            }
            refLast = next;
        }
    }

    function _mark(address u, uint256 amt) internal {
        incT[u].push(block.timestamp);
        incA[u].push(amt);
    }

    /// stake added within the last `window` seconds
    function recentOf(address u, uint256 window) public view returns (uint256 r) {
        uint256[] storage t = incT[u];
        for (uint256 i; i < t.length; ++i) {
            if (t[i] + window > block.timestamp) r += incA[u][i];
        }
    }

    function mirrorStake(address u) public view returns (uint256 s) {
        s = mFlex[u];
        Pos[] storage ps = mPos[u];
        for (uint256 i; i < ps.length; ++i) if (ps[i].open) s += ps[i].amount;
    }

    function mirrorWeight(address u) external view returns (uint256) {
        return _wOf(u, block.timestamp);
    }

    function mirrorPositions(address u) external view returns (Pos[] memory) {
        return mPos[u];
    }

    function _unlockFor(uint256 tier) internal view returns (uint64) {
        uint256 t = block.timestamp + (tier == 1 ? 7 days : tier == 2 ? 14 days : 30 days);
        return uint64(Math.ceilDiv(t, 1 days) * 1 days);
    }

    function _openMirror(address u, uint256 amt, uint8 tier) internal returns (bool ok) {
        Pos[] storage ps = mPos[u];
        uint256 id;
        uint256 openN;
        for (uint256 i; i < ps.length; ++i) if (ps[i].open) ++openN;
        if (openN >= 32) return false;
        while (id < ps.length && ps[id].open) ++id;
        Pos memory p = Pos(uint128(amt), _unlockFor(tier), tier, true);
        if (id == ps.length) ps.push(p);
        else ps[id] = p;
        return true;
    }

    function _freeSlot(address u) internal view returns (bool) {
        Pos[] storage ps = mPos[u];
        uint256 openN;
        for (uint256 i; i < ps.length; ++i) if (ps[i].open) ++openN;
        return openN < 32;
    }

    /// extend rules for an open position: expired -> any lock tier; active -> same or longer, never earlier
    function _extendOk(address u, uint256 id, uint8 tier) internal view returns (bool) {
        Pos[] storage ps = mPos[u];
        if (id >= ps.length || !ps[id].open || tier == 0 || tier > 3) return false;
        Pos storage p = ps[id];
        if (p.unlock <= block.timestamp) return true;
        return tier >= p.tier && _unlockFor(tier) >= p.unlock;
    }

    function _earned4(address u) internal view returns (uint256[4] memory e) {
        (e[0], e[1]) = st.earned(u);
        (e[2], e[3]) = st.earnedBonusEligible(u);
    }

    function _pick(address u, uint256 id) internal view returns (uint256) {
        Pos[] storage ps = mPos[u];
        if (id % 10 < 8) {
            uint256 m = ps.length;
            for (uint256 k; k < m; ++k) {
                uint256 j = (id / 10 + k) % m;
                if (ps[j].open) return j;
            }
        }
        return id % (ps.length + 1);
    }

    /// records the tranche just opened (if any) in the reference model
    function _recordNew(uint256 before) internal returns (RealYieldStaking.Tranche memory t, bool opened) {
        RealYieldStaking.Tranche[] memory trs = st.tranches();
        if (trs.length > maxTranches) maxTranches = trs.length;
        if (trs.length == before + 1) {
            t = trs[trs.length - 1];
            if (t.end != block.timestamp + 7 days) _fail("new tranche end");
            if (t.eligWeth > t.rateWeth || t.eligNlyra > t.rateNlyra) _fail("elig > rate");
            notified[0] += uint256(t.rateWeth) * 7 days;
            notified[1] += uint256(t.rateNlyra) * 7 days;
            mTr.push(Tr(t.rateWeth, t.rateNlyra, t.end, t.eligWeth, t.eligNlyra));
            opened = true;
        } else if (trs.length != before) {
            _fail("tranche count jumped");
        }
    }

    // ------------------------------------------------ time
    function warp(uint256 mode, uint256 x) external {
        mode = bound(mode, 0, 7);
        uint256 t = block.timestamp;
        uint256 to;
        if (mode == 0) to = t + bound(x, 1, 6 hours);
        else if (mode == 1) to = t + bound(x, 1 hours, 3 days);
        else if (mode == 2) to = (t / 1 days + 1) * 1 days; // exact midnight
        else if (mode == 3) to = (t / 1 days + 1) * 1 days - 1; // 1s before
        else if (mode == 4) to = t + bound(x, 5 days, 20 days);
        else if (mode == 5) to = t + bound(x, 25 days, 45 days);
        else if (mode == 6) {
            // exact end of a random tranche
            if (mTr.length == 0) return;
            uint256 e = mTr[x % mTr.length].end;
            if (e <= t) return;
            to = e;
        } else {
            // exact unlock of a random open position
            address u = actors[x % actors.length];
            Pos[] storage ps = mPos[u];
            if (ps.length == 0) return;
            Pos storage p = ps[(x / 7) % ps.length];
            if (!p.open || p.unlock <= t) return;
            to = p.unlock;
        }
        vm.warp(to);
        calls["warp"]++;
    }

    // ------------------------------------------------ user actions
    function stake(uint256 ai, uint256 amt) external {
        _sync();
        address u = actors[ai % actors.length];
        amt = bound(amt, 1, 50_000_000e18);
        N.mint(u, amt);
        vm.prank(u);
        try st.stake(amt) {
            if (_paused()) _fail("stake ok while paused");
            mFlex[u] += amt;
            deposited += amt;
            _mark(u, amt);
            calls["stake"]++;
        } catch {
            if (!_paused()) _fail("stake reverted");
        }
    }

    function stakeLocked(uint256 ai, uint256 amt, uint8 tier) external {
        _sync();
        address u = actors[ai % actors.length];
        amt = bound(amt, 1, 50_000_000e18);
        tier = uint8(bound(tier, 1, 3));
        N.mint(u, amt);
        bool expectOk = !_paused() && _freeSlot(u);
        vm.prank(u);
        try st.stakeLocked(amt, tier) {
            if (!expectOk) _fail("stakeLocked ok unexpectedly");
            _openMirror(u, amt, tier);
            deposited += amt;
            _mark(u, amt);
            calls["stakeLocked"]++;
        } catch {
            if (expectOk) _fail("stakeLocked reverted");
        }
    }

    function extendLock(uint256 ai, uint256 id, uint8 tier) external {
        _sync();
        address u = actors[ai % actors.length];
        Pos[] storage ps = mPos[u];
        if (ps.length == 0) return;
        id = _pick(u, id);
        tier = tier % 16 == 0 ? 4 : uint8(bound(tier, 1, 3)); // sometimes invalid
        bool expectOk = !_paused() && _extendOk(u, id, tier);
        uint64 nu = _unlockFor(tier);
        vm.prank(u);
        try st.extendLock(id, tier) {
            if (!expectOk) _fail("extendLock ok unexpectedly");
            ps[id].unlock = nu;
            ps[id].tier = tier;
            calls["extendLock"]++;
        } catch {
            if (expectOk) _fail("extendLock reverted");
        }
    }

    function withdrawLocked(uint256 ai, uint256 id) external {
        _sync();
        address u = actors[ai % actors.length];
        Pos[] storage ps = mPos[u];
        if (ps.length == 0) return;
        id = _pick(u, id);
        bool expectOk = id < ps.length && ps[id].open && ps[id].unlock <= block.timestamp;
        uint256 b0 = N.balanceOf(u);
        vm.prank(u);
        try st.withdrawLocked(id) {
            if (!expectOk) _fail("withdrawLocked ok unexpectedly");
            uint256 amt = ps[id].amount;
            ps[id].open = false;
            ps[id].amount = 0;
            _cool(u, amt, N.balanceOf(u) - b0);
            calls["withdrawLocked"]++;
        } catch {
            if (expectOk) _fail("withdrawLocked reverted");
        }
    }

    function _cool(address u, uint256 amt, uint256 got) internal {
        uint256 matured;
        if (mCool[u] != 0 && block.timestamp >= mCoolEnd[u]) {
            matured = mCool[u];
            mCool[u] = 0;
        }
        if (got != matured) _fail("matured payout mismatch");
        withdrawnP += got;
        mCool[u] += amt;
        mCoolEnd[u] = block.timestamp + 2 days;
    }

    function requestUnstake(uint256 ai, uint256 amt) external {
        _sync();
        address u = actors[ai % actors.length];
        uint256 f = mFlex[u];
        amt = bound(amt, 0, f + 1);
        bool expectOk = amt != 0 && amt <= f;
        uint256 b0 = N.balanceOf(u);
        vm.prank(u);
        try st.requestUnstake(amt) {
            if (!expectOk) _fail("requestUnstake ok unexpectedly");
            mFlex[u] -= amt;
            _cool(u, amt, N.balanceOf(u) - b0);
            calls["requestUnstake"]++;
        } catch {
            if (expectOk) _fail("requestUnstake reverted");
        }
    }

    function cancelUnstake(uint256 ai) external {
        _sync();
        address u = actors[ai % actors.length];
        bool expectOk = mCool[u] != 0 && !_paused();
        vm.prank(u);
        try st.cancelUnstake() {
            if (!expectOk) _fail("cancel ok unexpectedly");
            _mark(u, mCool[u]);
            mFlex[u] += mCool[u];
            mCool[u] = 0;
            mCoolEnd[u] = 0;
            calls["cancel"]++;
        } catch {
            if (expectOk) _fail("cancel reverted");
        }
    }

    function withdraw(uint256 ai) external {
        _sync();
        address u = actors[ai % actors.length];
        bool expectOk = mCool[u] != 0 && block.timestamp >= mCoolEnd[u];
        uint256 b0 = N.balanceOf(u);
        vm.prank(u);
        try st.withdraw() {
            if (!expectOk) _fail("withdraw ok unexpectedly");
            if (N.balanceOf(u) - b0 != mCool[u]) _fail("withdraw amount");
            withdrawnP += mCool[u];
            mCool[u] = 0;
            calls["withdraw"]++;
        } catch {
            if (expectOk) _fail("withdraw reverted");
        }
    }

    function claim(uint256 ai, uint8 mode, uint256 ri, bool useTo) external {
        _sync();
        address u = actors[ai % actors.length];
        mode = uint8(bound(mode, 0, 3));
        address to = u;
        if (useTo) {
            uint256 r = ri % 5;
            if (r == 0) to = address(st);
            else if (r == 1) to = address(sp);
            else if (r == 2) to = address(0);
            else to = actors[ri % actors.length];
        }
        uint256[4] memory e = _earned4(u);
        bool badTo = useTo && (to == address(st) || to == address(sp) || to == address(0));
        bool expectOk = !badTo && (e[0] != 0 || e[1] != 0);
        uint256[2] memory p0 = [st.rewardState(0).paid, st.rewardState(1).paid];
        vm.prank(u);
        bool ok;
        if (useTo) {
            try st.claimTo(to, RealYieldStaking.OutMode(mode), 0) {
                ok = true;
            } catch {}
        } else {
            try st.claim(RealYieldStaking.OutMode(mode), 0) {
                ok = true;
            } catch {}
        }
        if (ok && !expectOk) _fail("claim ok unexpectedly");
        if (!ok && expectOk) _fail("claim reverted");
        if (ok) {
            if (st.rewardState(0).paid - p0[0] != e[0] || st.rewardState(1).paid - p0[1] != e[1]) {
                _fail("claim != earned view");
            }
            (uint256 aw, uint256 an) = st.earnedBonusEligible(u);
            if (aw + an != 0) _fail("claim left eligible");
            for (uint256 i; i < 4; ++i) claimed[u][i] += e[i];
            calls["claim"]++;
        }
    }

    struct Cmp {
        uint256 pid;
        uint256 bought;
        uint256 total;
        uint256 r0;
        uint64 nu;
        bool expectOk;
    }

    /// compound: tier 0..4 (4 invalid); pidSeed % 3 == 0 -> new lock, otherwise into a picked position
    function compound(uint256 ai, uint8 tier, uint256 pidSeed) external {
        _sync();
        address u = actors[ai % actors.length];
        tier = uint8(bound(tier, 0, 4));
        Cmp memory c;
        c.pid = NEW;
        if (pidSeed % 3 != 0 && mPos[u].length != 0) c.pid = _pick(u, pidSeed);
        if (tier == 0 && pidSeed % 7 != 0) c.pid = NEW; // flex: mostly the valid form
        uint256[4] memory e = _earned4(u);
        c.bought = (e[0] * PX) / 1e18;
        c.total = e[1] + c.bought;
        bool slotOk = tier == 0 ? c.pid == NEW : (c.pid == NEW ? _freeSlot(u) : _extendOk(u, c.pid, tier));
        c.expectOk = !_paused() && tier <= 3 && (e[0] != 0 || e[1] != 0) && c.total != 0 && slotOk;
        c.nu = _unlockFor(tier);
        c.r0 = st.bonusReserve();
        vm.prank(u);
        try st.compound(0, tier, c.pid) returns (uint256 added) {
            if (!c.expectOk) _fail("compound ok unexpectedly");
            _afterCompound(u, tier, c, e, added);
        } catch {
            if (c.expectOk) _fail("compound reverted");
        }
    }

    function _afterCompound(address u, uint8 tier, Cmp memory c, uint256[4] memory e, uint256 added) internal {
        uint256 bonus = c.r0 - st.bonusReserve();
        if (tier != 3 && bonus != 0) _fail("bonus outside 30d");
        if (tier == 3) {
            uint256 elig = e[3] + (e[0] == 0 ? 0 : Math.mulDiv(c.bought, e[2], e[0]));
            if (bonus != Math.min((elig * 500) / 10_000, c.r0)) _fail("bonus amount");
        }
        if (bonus > (c.total * 500) / 10_000) _fail("bonus > 5% of compounded");
        if (added != c.total + bonus) _fail("added mismatch");
        bonusOut += bonus;
        deposited += c.total;
        for (uint256 i; i < 4; ++i) claimed[u][i] += e[i];
        if (tier == 0) {
            mFlex[u] += added;
        } else if (c.pid == NEW) {
            _openMirror(u, added, tier);
        } else {
            Pos storage p = mPos[u][c.pid];
            p.amount += uint128(added);
            p.unlock = c.nu;
            p.tier = tier;
            calls["compoundInto"]++;
        }
        _mark(u, added);
        calls["compound"]++;
    }

    function kick(uint256 ci, uint256 ai, uint256 id) external {
        _sync();
        address c = actors[ci % actors.length];
        address u = actors[ai % actors.length];
        RealYieldStaking.Position[] memory ps = st.positionsOf(u);
        if (ps.length == 0) return;
        id = _pick(u, id);
        if (id >= ps.length) id = 0;
        bool expectOk = ps[id].amount != 0 && block.timestamp >= ps[id].unlockTime && ps[id].tier != 0;
        vm.prank(c);
        try st.kick(u, id) {
            if (!expectOk) _fail("kick ok unexpectedly");
            calls["kick"]++;
        } catch {
            if (expectOk) _fail("kick reverted");
        }
    }

    function fundReserve(uint256 ai, uint256 amt) external {
        _sync();
        address u = actors[ai % actors.length];
        amt = bound(amt, 1, 5_000_000e18);
        N.mint(u, amt);
        vm.prank(u);
        try st.fundBonusReserve(amt) {
            if (_paused()) _fail("fund ok while paused");
            funded += amt;
            calls["fund"]++;
        } catch {
            if (!_paused()) _fail("fund reverted");
        }
    }

    // ------------------------------------------------ rewards in
    function harvest(uint256 w, uint256 n, uint8 lmode, uint256 eth, uint256 dw, uint256 dn) external {
        _sync();
        lmode = uint8(bound(lmode, 0, 3));
        L.setMode(lmode);
        w = bound(w, 0, 3 ether);
        n = bound(n, 0, 30_000_000e18);
        if (w % 3 == 0) w = w % 1e13; // dust sometimes
        if (lmode == 1) {
            W.mint(address(L), w);
            N.mint(address(L), n);
        }
        eth = bound(eth, 0, 0.1 ether);
        if (eth % 2 == 0) eth = 0;
        vm.deal(address(sp), address(sp).balance + eth);
        dw = bound(dw, 0, 0.5 ether);
        if (dw % 2 == 0) dw = 0;
        dn = bound(dn, 0, 3_000_000e18);
        if (dn % 2 == 0) dn = 0;
        W.mint(address(sp), dw);
        N.mint(address(sp), dn);

        uint256 lh = sp.lastHarvest();
        if (lh != 0 && block.timestamp < lh + 1 days && dw % 3 != 0) {
            vm.warp(lh + 1 days + (dn % 3 == 0 ? 0 : dn % 20 hours));
            _sync();
        }
        // ronda 2 (C): el harvest ya no revierte por estar vacio; siempre avisa al staking
        bool expectOk = (lh == 0 || block.timestamp >= lh + 1 days) && lmode != 3;
        uint256 sw0 = W.balanceOf(address(st));
        uint256 sn0 = N.balanceOf(address(st));
        uint256 before = st.tranches().length;
        try sp.harvest() {
            if (!expectOk) _fail("harvest ok unexpectedly");
            uint256 inW = W.balanceOf(address(st)) - sw0;
            uint256 inN = N.balanceOf(address(st)) - sn0;
            inflow[0] += inW;
            inflow[1] += inN;
            (RealYieldStaking.Tranche memory t, bool opened) = _recordNew(before);
            if (opened) {
                // lo elegible nunca supera lo que mando el splitter en este harvest
                if (uint256(t.eligWeth) * 7 days > inW || uint256(t.eligNlyra) * 7 days > inN) _fail("elig > splitter in");
            }
            calls["harvest"]++;
        } catch {
            if (expectOk) _fail("harvest reverted");
        }
    }

    function donate(uint256 w, uint256 n) external {
        _sync();
        w = bound(w, 0, 0.3 ether);
        n = bound(n, 0, 2_000_000e18);
        W.mint(address(st), w);
        N.mint(address(st), n);
        inflow[0] += w;
        inflow[1] += n;
        calls["donate"]++;
    }

    function sweepDonations() external {
        _sync();
        bool expectOk = block.timestamp >= uint256(st.lastDonationSweep()) + 1 days;
        uint256 before = st.tranches().length;
        try st.sweepDonations() {
            if (!expectOk) _fail("sweep ok unexpectedly");
            (RealYieldStaking.Tranche memory t, bool opened) = _recordNew(before);
            if (opened) {
                if (t.eligWeth != 0 || t.eligNlyra != 0) _fail("donation tranche eligible");
                if (st.lastDonationSweep() != block.timestamp) _fail("sweep timer");
            }
            calls["sweep"]++;
        } catch {
            if (expectOk) _fail("sweep reverted");
        }
    }

    // ------------------------------------------------ ronda 3: transferencia de locks
    /// k decide variantes: un tercero intenta aceptar, el holder cancela, o se acepta por operador.
    function transferPosition(uint256 ai, uint256 bi, uint256 id, uint8 k) external {
        _sync();
        address u = actors[ai % actors.length];
        address v = actors[bi % actors.length];
        Pos[] storage ps = mPos[u];
        if (ps.length == 0) return;
        id = _pick(u, id);
        bool open = id < ps.length && ps[id].open;
        bool offerOk = open && !_paused() && u != v;
        vm.prank(u);
        try st.offerPosition(id, v) {
            if (!offerOk) _fail("offer ok unexpectedly");
        } catch {
            if (offerOk) _fail("offer reverted");
            return;
        }
        address x = actors[(bi % actors.length + 1) % actors.length];
        if (k % 5 == 0 && x != v) {
            vm.prank(x);
            try st.acceptPosition(u, id) {
                _fail("stranger accepted");
            } catch {}
        }
        if (k % 7 == 1) {
            vm.prank(u);
            st.cancelPositionOffer(id);
            vm.prank(v);
            try st.acceptPosition(u, id) {
                _fail("accepted cancelled offer");
            } catch {}
            return;
        }
        bool expectOk = _freeSlot(v);
        uint256[4] memory eu = _earned4(u);
        uint256[4] memory ev = _earned4(v);
        bool ok;
        uint256 nid;
        vm.prank(v);
        try st.acceptPosition(u, id) returns (uint256 r) {
            ok = true;
            nid = r;
        } catch {}
        if (ok != expectOk) _fail(ok ? "accept ok unexpectedly" : "accept reverted");
        if (!ok) {
            vm.prank(u);
            st.cancelPositionOffer(id);
            return;
        }
        _afterTransfer(u, v, id, nid, eu, ev);
    }

    function _afterTransfer(address u, address v, uint256 id, uint256 nid, uint256[4] memory eu, uint256[4] memory ev)
        internal
    {
        uint256[4] memory eu2 = _earned4(u);
        uint256[4] memory ev2 = _earned4(v);
        for (uint256 i; i < 4; ++i) {
            if (eu2[i] != eu[i]) _fail("sender rewards changed by transfer");
            if (ev2[i] != ev[i]) _fail("recipient rewards changed by transfer");
        }
        Pos[] storage ps = mPos[u];
        Pos memory p = ps[id];
        ps[id].open = false;
        ps[id].amount = 0;
        Pos[] storage qs = mPos[v];
        uint256 j;
        while (j < qs.length && qs[j].open) ++j;
        if (j == qs.length) qs.push(p);
        else qs[j] = p;
        if (j != nid) _fail("recipient id != first free slot");
        _mark(v, p.amount);
        calls["transfer"]++;
    }

    function setMarket(PositionMarket m) external {
        mk = m;
    }

    /// Venta por el PositionMarket: oferta al mercado, publicacion y compra con ETH (o revert esperado).
    function marketSale(uint256 ai, uint256 bi, uint256 id, uint256 price, uint8 k) external {
        _sync();
        address u = actors[ai % actors.length];
        address v = actors[bi % actors.length];
        Pos[] storage ps = mPos[u];
        if (ps.length == 0 || address(mk) == address(0)) return;
        id = _pick(u, id);
        bool open = id < ps.length && ps[id].open;
        bool offerOk = open && !_paused();
        vm.prank(u);
        try st.offerPosition(id, address(mk)) {
            if (!offerOk) _fail("market offer ok unexpectedly");
        } catch {
            if (offerOk) _fail("market offer reverted");
            return;
        }
        bool listOk = ps[id].unlock > block.timestamp;
        price = bound(price, 1, 100 ether);
        uint256 lid;
        vm.prank(u);
        try mk.list(id, price, uint64(block.timestamp + 1 + uint256(k) * 1 hours)) returns (uint256 r) {
            if (!listOk) _fail("list ok unexpectedly");
            lid = r;
        } catch {
            if (listOk) _fail("list reverted");
            vm.prank(u);
            st.cancelPositionOffer(id);
            return;
        }
        _buyListing(u, v, id, lid, price);
    }

    function _buyListing(address u, address v, uint256 id, uint256 lid, uint256 price) internal {
        bool expectOk = u != v && _freeSlot(v);
        vm.deal(v, v.balance + price);
        uint256[4] memory eu = _earned4(u);
        uint256[4] memory ev = _earned4(v);
        uint256 spb = address(sp).balance;
        bool ok;
        uint256 nid;
        vm.prank(v);
        try mk.buy{value: price}(lid, price) returns (uint256 r) {
            ok = true;
            nid = r;
        } catch {}
        if (ok != expectOk) _fail(ok ? "buy ok unexpectedly" : "buy reverted");
        if (!ok) {
            vm.startPrank(u);
            mk.cancel(lid);
            st.cancelPositionOffer(id);
            vm.stopPrank();
            return;
        }
        uint256 fee = (price * 50 + 9_999) / 10_000;
        if (address(sp).balance - spb != fee) _fail("market fee != 50 bps");
        salesPaid += price;
        salesFees += fee;
        if (address(mk).balance != mk.totalProceeds()) _fail("market ETH != proceeds");
        if (st.stakeOf(address(mk)) != 0) _fail("market holds stake");
        _afterTransfer(u, v, id, nid, eu, ev);
        calls["sale"]++;
    }

    // ------------------------------------------------ owner / attacks
    /// ronda 2 (B): pause solo si pasaron 30 dias desde el fin de la anterior; unpause solo en pausa
    function pauseToggle(uint8 p8) external {
        _sync();
        bool p = p8 % 4 == 0;
        uint256 pu = st.pausedUntil();
        bool expectOk = p ? block.timestamp >= pu + 30 days : block.timestamp < pu;
        vm.prank(owner);
        bool ok = true;
        if (p) {
            try st.pause() {} catch { ok = false; }
            if (ok && st.pausedUntil() != block.timestamp + 30 days) _fail("pause length");
        } else {
            try st.unpause() {} catch { ok = false; }
        }
        if (ok != expectOk) _fail(p ? "pause gate" : "unpause gate");
        if (ok) calls["pause"]++;
    }

    function attack(uint8 k, int256 a, int256 b) external {
        _sync();
        k = uint8(bound(k, 0, 3));
        bool ok = true;
        if (k == 0) {
            try st.notifyRewards(1e30, 1e30) {} catch { ok = false; }
        } else if (k == 1) {
            try st.uniswapV3SwapCallback(a, b, "") {} catch { ok = false; }
        } else if (k == 2) {
            vm.prank(st.POOL_NLYRA());
            try st.uniswapV3SwapCallback(a, b, "") {} catch { ok = false; }
        } else {
            vm.prank(owner);
            try st.renounceOwnership() {} catch { ok = false; }
        }
        if (ok) _fail("attack call succeeded");
        calls["attack"]++;
    }

    // ------------------------------------------------ views for invariants
    function refCum(address u, uint256 i) external view returns (uint256) {
        return refCumX[u][i] / 1e18;
    }

    function claimedOf(address u, uint256 i) external view returns (uint256) {
        return claimed[u][i];
    }

    function syncView() external {
        _sync();
    }
}

/// Deploy local comun (mocks en las direcciones CREATE2 que valida el constructor).
abstract contract Inv2Base is Test {
    RealYieldStaking st;
    NlyraFeeSplitter sp;
    MToken N;
    MToken W;
    MToken U;
    MLocker L;
    Handler h;
    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address constant FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    bytes32 constant HASH = 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54;

    function _mkPool(address a, address b, uint24 fee, uint256 bPerA) internal returns (address pool) {
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        uint256 px = a == t0 ? bPerA : (1e36 / bPerA); // token1 per token0 *1e18
        bytes32 salt = keccak256(abi.encode(t0, t1, fee));
        pool = address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", FACTORY, salt, HASH)))));
        vm.etch(pool, type(MPool).runtimeCode);
        MPool(pool).init(t0, t1, fee, px);
        MToken(t0).mint(pool, 1e40);
        MToken(t1).mint(pool, 1e40);
    }

    function _deploy(uint256 nAct) internal {
        vm.warp(1_790_000_000 + 12345); // arbitrary non-midnight
        N = new MToken("NLYRA", 18);
        W = new MToken("WETH", 18);
        U = new MToken("USDG", 6);
        L = new MLocker(W, N);
        // WETH->NLYRA price 1e7 NLYRA per WETH ; WETH->USDG 4000e6 per 1e18 => 4000e-12 *1e18
        address pn = _mkPool(address(W), address(N), 10_000, 10_000_000e18);
        address pu = _mkPool(address(W), address(U), 100, 4000e6);
        st = new RealYieldStaking(owner, address(N), address(W), address(U), pn, pu, address(L), treasury, 5_000, 1 days);
        sp = NlyraFeeSplitter(payable(st.feeSplitter()));
        L.setFeeRedirect(address(N), address(sp));
        h = new Handler(st, N, W, L, owner, nAct);
        h.setMarket(new PositionMarket(address(st)));
    }
}

/// forge-config: dev.invariant.runs = 200
/// forge-config: dev.invariant.depth = 150
/// forge-config: dev.invariant.fail-on-revert = false
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 100
/// forge-config: default.invariant.fail-on-revert = false
contract Inv2StatefulLocal is Inv2Base {
    function setUp() public virtual {
        _deploy(8);
        targetContract(address(h));
        bytes4[] memory sel = new bytes4[](19);
        sel[0] = Handler.warp.selector;
        sel[1] = Handler.stake.selector;
        sel[2] = Handler.stakeLocked.selector;
        sel[3] = Handler.extendLock.selector;
        sel[4] = Handler.withdrawLocked.selector;
        sel[5] = Handler.requestUnstake.selector;
        sel[6] = Handler.cancelUnstake.selector;
        sel[7] = Handler.withdraw.selector;
        sel[8] = Handler.claim.selector;
        sel[9] = Handler.compound.selector;
        sel[10] = Handler.kick.selector;
        sel[11] = Handler.fundReserve.selector;
        sel[12] = Handler.harvest.selector;
        sel[13] = Handler.donate.selector;
        sel[14] = Handler.pauseToggle.selector;
        sel[15] = Handler.attack.selector;
        sel[16] = Handler.sweepDonations.selector;
        sel[17] = Handler.transferPosition.selector;
        sel[18] = Handler.marketSale.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: sel}));
    }

    function _pendingNow() internal view returns (uint256 w, uint256 n) {
        RealYieldStaking.Tranche[] memory trs = st.tranches();
        for (uint256 k; k < trs.length; ++k) {
            if (trs[k].end > block.timestamp) {
                w += uint256(trs[k].rateWeth) * (trs[k].end - block.timestamp);
                n += uint256(trs[k].rateNlyra) * (trs[k].end - block.timestamp);
            }
        }
    }

    function _checkUser(address u) internal view returns (uint256[5] memory r) {
        (RealYieldStaking.Account memory ac, uint256 ew, uint256 en,) = st.userInfo(u);
        r[0] = ew;
        r[1] = en;
        r[2] = uint256(ac.flexible) + ac.locked;
        r[3] = ac.cooling;
        r[4] = st.boostedBalanceOf(u);
        assertEq(r[2], h.mirrorStake(u), "user stake != mirror");
        assertEq(r[3], h.mCool(u), "user cooling != mirror");
        assertEq(r[4], h.mirrorWeight(u), "user weight != mirror");
        (uint256 bw, uint256 bn) = st.earnedBonusEligible(u);
        assertLe(bw, ew, "eligible WETH > earned");
        assertLe(bn, en, "eligible NLYRA > earned");
        // eligibleBalance: nunca cuenta lo de < 24 h, y siempre cuenta lo de > 48 h
        uint256 el = st.eligibleBalance(u);
        uint256 act = st.stakeOf(u);
        assertLe(el, act, "eligible > active");
        uint256 rec24 = h.recentOf(u, 24 hours);
        uint256 rec48 = h.recentOf(u, 48 hours);
        assertLe(el, act > rec24 ? act - rec24 : 0, "eligible counts <24h stake");
        assertGe(el, act > rec48 ? act - rec48 : 0, "eligible misses >48h stake");
        RealYieldStaking.Position[] memory ps = st.positionsOf(u);
        Handler.Pos[] memory mp = h.mirrorPositions(u);
        assertEq(ps.length, mp.length, "positions length");
        for (uint256 j; j < ps.length; ++j) {
            assertEq(ps[j].amount, mp[j].open ? mp[j].amount : 0, "pos amount");
            if (mp[j].open) assertEq(ps[j].unlockTime, mp[j].unlock, "pos unlock");
        }
    }

    function _checkUsers(uint256 cw, uint256 cn, uint256 tb, uint256 ts, uint256 tc) internal view {
        (uint256 pw, uint256 pn) = _pendingNow();
        uint256[5] memory sum;
        uint256 n = h.nActors();
        for (uint256 k; k < n; ++k) {
            uint256[5] memory r = _checkUser(h.actors(k));
            for (uint256 j; j < 5; ++j) sum[j] += r[j];
        }
        assertEq(sum[2], ts, "sum principal != totalStaked");
        assertEq(sum[3], tc, "sum cooling != totalCooling");
        assertEq(sum[4], tb, "sum weight != totalBoosted");
        assertLe(sum[0], cw - pw, "users WETH > accrued");
        assertLe(sum[1], cn - pn, "users NLYRA > accrued");
    }

    function invariant_noUnexpected() public view {
        assertEq(h.failure(), "", h.failure());
    }

    function invariant_solvency() public view {
        (uint256 cw, uint256 cn) = st.committedRewards();
        (,,, uint256 tb, uint256 ts, uint256 tc, uint256 br) = st.rewardInfo();
        assertGe(W.balanceOf(address(st)), cw, "WETH insolvent");
        assertGe(N.balanceOf(address(st)), ts + tc + br + cn, "NLYRA insolvent");
        // principal conservation
        assertEq(ts + tc, h.deposited() + h.bonusOut() - h.withdrawnP(), "principal conservation");
        assertEq(br, h.funded() - h.bonusOut(), "reserve conservation");
        // tranche bookkeeping bounded by what came in
        for (uint256 i; i < 2; ++i) {
            RealYieldStaking.RewardState memory r = st.rewardState(i);
            assertLe(r.paid, r.distributed, "paid > distributed");
            assertLe(r.distributed, h.inflow(i), "distributed > inflow");
            assertLe(r.paid, h.inflow(i), "paid > inflow");
        }
        _checkUsers(cw, cn, tb, ts, tc);
        assertLe(st.tranches().length, 14, "tranches > 14 (7 splitter + 7 sweep)");
        assertLe(h.maxTranches(), 14, "tranches ever > 14");
    }

    /// peso extra vigente == suma de las bajas de boost agendadas a futuro
    function invariant_boostDrops() public view {
        (,,, uint256 tb, uint256 ts,,) = st.rewardInfo();
        uint256 m = (block.timestamp / 1 days + 1) * 1 days;
        uint256 sum;
        for (uint256 d; d <= 31; ++d) sum += st.boostDrop(m + d * 1 days);
        assertEq(sum, tb - ts, "future boostDrops != extra weight");
    }

    /// ronda 3: el mercado solo guarda lo que les debe a los vendedores; el resto de lo pagado fue fee
    function invariant_marketEth() public view {
        PositionMarket m = h.mk();
        assertEq(address(m).balance, m.totalProceeds(), "market ETH != proceeds");
        assertEq(m.totalProceeds() + h.salesFees(), h.salesPaid(), "paid != proceeds + fees");
        assertEq(st.stakeOf(address(m)), 0, "market holds stake");
    }

    /// pausa acotada: nunca dura mas de 30 dias desde ahora
    function invariant_pauseBounded() public view {
        assertLe(st.pausedUntil(), block.timestamp + 30 days, "pause > 30d");
    }

    /// per-user reward (total and bonus-eligible part) vs exact reference (after syncing it to now)
    function invariant_rewardsMatchReference() public {
        h.syncView();
        uint256 n = h.nActors();
        for (uint256 k; k < n; ++k) {
            address u = h.actors(k);
            (uint256 ew, uint256 en) = st.earned(u);
            (uint256 bw, uint256 bn) = st.earnedBonusEligible(u);
            uint256[4] memory got =
                [h.claimedOf(u, 0) + ew, h.claimedOf(u, 1) + en, h.claimedOf(u, 2) + bw, h.claimedOf(u, 3) + bn];
            for (uint256 i; i < 4; ++i) {
                uint256 ref = h.refCum(u, i);
                uint256 tol = 1e6 + ref / 1e12;
                if (got[i] > ref + tol) {
                    console2.log("user", k, "flow", i);
                    console2.log("got", got[i], "ref", ref);
                    assertTrue(false, "user OVER-paid vs reference");
                }
                if (got[i] + tol < ref) {
                    console2.log("user", k, "flow", i);
                    console2.log("got", got[i], "ref", ref);
                    assertTrue(false, "user UNDER-paid vs reference");
                }
            }
        }
    }

    /// everyone can always leave with principal + rewards; nothing owed is left unpaid
    function invariant_everyoneCanExit() public {
        uint256 snap = vm.snapshotState();
        if (st.paused()) {
            vm.prank(owner);
            st.unpause();
        }
        vm.warp(vm.getBlockTimestamp() + 40 days);
        uint256 n = h.nActors();
        for (uint256 k; k < n; ++k) {
            address u = h.actors(k);
            RealYieldStaking.Position[] memory ps = st.positionsOf(u);
            vm.startPrank(u);
            for (uint256 j; j < ps.length; ++j) if (ps[j].amount != 0) st.withdrawLocked(j);
            (RealYieldStaking.Account memory ac,,,) = st.userInfo(u);
            if (ac.flexible != 0) st.requestUnstake(ac.flexible);
            vm.stopPrank();
        }
        vm.warp(vm.getBlockTimestamp() + 2 days);
        for (uint256 k; k < n; ++k) {
            address u = h.actors(k);
            vm.startPrank(u);
            (RealYieldStaking.Account memory ac, uint256 ew, uint256 en,) = st.userInfo(u);
            if (ac.cooling != 0) st.withdraw();
            if (ew + en != 0) st.claim(RealYieldStaking.OutMode.AS_IS, 0);
            vm.stopPrank();
        }
        (,,, uint256 tb, uint256 ts, uint256 tc, uint256 br) = st.rewardInfo();
        assertEq(ts + tc + tb, 0, "leftover stake");
        assertGe(N.balanceOf(address(st)), br, "reserve not backed");
        vm.revertToState(snap);
    }

    function afterInvariant() external view {
        string[20] memory k = [
            "warp", "stake", "stakeLocked", "extendLock", "withdrawLocked", "requestUnstake", "cancel", "withdraw",
            "claim", "compound", "compoundInto", "kick", "fund", "harvest", "donate", "sweep", "pause", "attack",
            "transfer", "sale"
        ];
        for (uint256 i; i < 20; ++i) console2.log(k[i], h.calls(k[i]));
        console2.log("max tranches", h.maxTranches());
    }
}

/// Menos actores y sin pausa/ataques/donaciones: mas profundidad efectiva en locks, compound y harvest.
/// forge-config: dev.invariant.runs = 200
/// forge-config: dev.invariant.depth = 150
/// forge-config: dev.invariant.fail-on-revert = false
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 100
/// forge-config: default.invariant.fail-on-revert = false
contract Inv2StatefulFocused is Inv2StatefulLocal {
    function setUp() public override {
        _deploy(4);
        targetContract(address(h));
        bytes4[] memory sel = new bytes4[](15);
        sel[0] = Handler.warp.selector;
        sel[1] = Handler.stake.selector;
        sel[2] = Handler.stakeLocked.selector;
        sel[3] = Handler.extendLock.selector;
        sel[4] = Handler.withdrawLocked.selector;
        sel[5] = Handler.requestUnstake.selector;
        sel[6] = Handler.withdraw.selector;
        sel[7] = Handler.claim.selector;
        sel[8] = Handler.compound.selector;
        sel[9] = Handler.kick.selector;
        sel[10] = Handler.harvest.selector;
        sel[11] = Handler.fundReserve.selector;
        sel[12] = Handler.sweepDonations.selector;
        sel[13] = Handler.transferPosition.selector;
        sel[14] = Handler.marketSale.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: sel}));
    }
}
