/* NLYRA Real Yield Staking v2 · app
   Talks straight to the verified contracts; this page never holds keys or funds. */
(function () {
  'use strict';
  var E = window.ethers;
  var CHAIN_ID = 4663, CHAIN_HEX = '0x1237';
  var ST = '0x5CB0Cb16cA019bcff4E494b32575848E4CdB5aF8';
  var SP = '0x8300Ef5cC02cAb1D141dBE1c0B33d8Ac115F2D48';
  var SP_BLOCK = 75661721;
  var NLYRA = '0xB9d3824149aD8ac984153CeEc91D5a2405d1FB95';
  var WETH = '0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73';
  var BS = 'https://robinhoodchain.blockscout.com/tx/';
  var BOOST = [1, 1.25, 1.5, 2];
  var TIER_NAME = ['Flexible', '7 days', '14 days', '30 days'];
  var TIER_DAYS = [0, 7, 14, 30];
  var MODE_NAME = { 0: 'WETH + NLYRA', 1: 'ETH', 2: 'NLYRA', 3: 'USDG' };
  var MAXU = E.MaxUint256;
  // Coinsult RYSM1: anyone can push a lock into any wallet, and a wallet holds at most 32 open
  // locks. Locks under TINY are shown apart as probable junk, with a way to clear them.
  var MAX_POS = 32, TINY = E.parseUnits('1000', 18);

  var ST_ABI = [
    'function rewardInfo() view returns (uint256 wethRate,uint256 nlyraRate,uint256 finish,uint256 totalBoosted,uint256 totalStaked,uint256 totalCooling,uint256 bonusReserve)',
    'function userInfo(address) view returns (tuple(uint128 flexible,uint128 locked,uint128 boosted,uint128 cooling,uint64 cooldownEnd,uint64 nextExpiry,uint64 recentDay,uint32 usedMask,uint128 recentCur,uint128 recentPrev) account,uint256 earnedWeth,uint256 earnedNlyra,uint256 positionCount)',
    'function positionsOf(address) view returns (tuple(uint128 amount,uint64 unlockTime,uint8 tier)[])',
    'function positionOffer(address,uint256) view returns (address)',
    'function boostedBalanceOf(address) view returns (uint256)',
    'function paused() view returns (bool)',
    'function committedRewards() view returns (uint256 weth,uint256 nlyra)',
    'function tranches() view returns (tuple(uint96 rateWeth,uint96 rateNlyra,uint64 end,uint96 eligWeth,uint96 eligNlyra)[])',
    'function stake(uint256)', 'function stakeLocked(uint256,uint8)', 'function extendLock(uint256,uint8)',
    'function requestUnstake(uint256)', 'function withdrawLocked(uint256)', 'function cancelUnstake()', 'function withdraw()',
    'function offerPosition(uint256,address)', 'function cancelPositionOffer(uint256)', 'function acceptPosition(address,uint256) returns (uint256)',
    'function claim(uint8,uint256) returns (uint256)', 'function claimTo(address,uint8,uint256) returns (uint256)',
    'function compound(uint256,uint8,uint256) returns (uint256)',
    'function POOL_NLYRA() view returns (address)', 'function POOL_USDG() view returns (address)',
  ];
  var ERC = ['function balanceOf(address) view returns (uint256)', 'function allowance(address,address) view returns (uint256)', 'function approve(address,uint256) returns (bool)'];
  var HARVESTED = 'event Harvested(address indexed caller,bool collected,uint256 wethToStaking,uint256 nlyraToStaking,uint256 wethToTreasury,uint256 nlyraToTreasury)';

  var SP_ABI = ['function harvestableIn() view returns (uint256)', 'function harvest()'];
  var LOCKER = '0x736D76699C26D0d966744cAe304C000d471f7F35';
  var LK_ABI = ['function collectFees(address) returns (uint256,uint256)'];
  var POOL_ABI = ['function slot0() view returns (uint160 sqrtPriceX96,int24,uint16,uint16,uint16,uint8,bool)', 'function token0() view returns (address)'];
  // On nlyra.xyz the page reads through the NLYRA gateway (/rpc) and takes prices from the Desk API.
  // Anywhere else (GitHub Pages, a local copy) it runs on its own: the public Robinhood Chain RPC, and
  // prices read straight from the Uniswap v3 pools the contract itself swaps in. Nothing here needs us.
  var ONSITE = /(^|\.)nlyra\.xyz$/i.test(location.hostname);
  var roPub = new E.JsonRpcProvider('https://rpc.mainnet.chain.robinhood.com', CHAIN_ID, { staticNetwork: true });
  var ro = ONSITE ? new E.JsonRpcProvider(location.origin + '/rpc', CHAIN_ID, { staticNetwork: true }) : roPub;
  var LOGO = (document.querySelector('link[rel="icon"]') || {}).href || 'dual-core.svg';
  var stR = new E.Contract(ST, ST_ABI, ro), nlR = new E.Contract(NLYRA, ERC, ro), spR = new E.Contract(SP, SP_ABI, ro), lkR = new E.Contract(LOCKER, LK_ABI, ro);
  var eip = null, signer = null, me = null;
  var G = {}, U = {}, px = { nlyra: 0, eth: 0 }, H = [];
  var mode = 1, stTier = 3, busy = false, tick = { base: 0, rate: 0, at: 0 };

  function $(id) { return document.getElementById(id); }
  function f18(x) { return Number(E.formatUnits(x, 18)); }
  function num(n, d) { return Number(n).toLocaleString('en-US', { maximumFractionDigits: d == null ? 2 : d, minimumFractionDigits: 0 }); }
  function tok(x, d) { return num(f18(x), d == null ? 0 : d); }
  function kfmt(n) { return n >= 1e9 ? num(n / 1e9, 2) + 'B' : n >= 1e6 ? num(n / 1e6, 2) + 'M' : n >= 1e3 ? num(n / 1e3, 1) + 'K' : num(n, 0); }
  function usd(n) { if (!isFinite(n)) return '—'; if (n === 0) return '$0.00'; return n >= 1000 ? '$' + num(n, 0) : n >= 1 ? '$' + n.toFixed(2) : '$' + n.toFixed(n >= .01 ? 3 : 4); }
  function pct(n) { return !n ? '—' : (n >= 1000 ? num(n, 0) : n >= 100 ? num(n, 0) : num(n, 1)) + '%'; }
  function short(a) { return a.slice(0, 6) + '…' + a.slice(-4); }
  function dstr(ts) { return new Date(Number(ts) * 1000).toLocaleDateString('en-US', { month: 'short', day: 'numeric', timeZone: 'UTC' }); }
  function left(ts) { var s = Number(ts) - Date.now() / 1000; if (s <= 0) return 'now'; var d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600); return d ? d + 'd ' + h + 'h' : h + 'h ' + Math.floor((s % 3600) / 60) + 'm'; }
  function esc(s) { return String(s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }
  function parseAmt(v) { v = String(v || '').replace(/,/g, '').trim(); if (!v || isNaN(Number(v))) return 0n; try { return E.parseUnits(v, 18); } catch (e) { return 0n; } }
  function log(html) { var l = $('log'); if (l.querySelector('.muted')) l.innerHTML = ''; var d = document.createElement('div'); d.innerHTML = html; l.prepend(d); }
  var toastT;
  function toast(html) { var t = document.querySelector('.toast'); if (!t) { t = document.createElement('div'); t.className = 'toast'; document.body.appendChild(t); } t.innerHTML = html; clearTimeout(toastT); toastT = setTimeout(function () { t.remove(); }, 5000); }
  function errMsg(e) {
    var m = (e && (e.shortMessage || e.reason || (e.info && e.info.error && e.info.error.message) || e.message)) || String(e);
    if (/user rejected|denied|4001/i.test(m)) return 'cancelled in wallet';
    return m.slice(0, 160);
  }
  function dailyUsd() { return (f18(G.wr || 0n) * px.eth + f18(G.nr || 0n) * px.nlyra) * 86400; }
  // APR at the REAL fee pace. Each payout streams over 7 days, so the live stream (dailyUsd) only
  // shows 1/7 of a payout per day during the first week. The pace = last payout to stakers + the fees
  // already accrued for the next one, over the hours they cover (previous collection -> now).
  var FIRST_START = 1790632884; // 28 Sep 22:01:24 UTC: the collection before the first payout
  function paceUsd() {
    // Preferred source: the contract's own tranches (each active daily payout, its size and start).
    // No event history needed, so it can't silently fall back to the 1/7 stream.
    // Fee part only (eligWeth/eligNlyra = what came from the fee splitter): a treasury boost tranche
    // must never read as a jump in fees. It is shown apart (boostInfo).
    var tr = (G.tr || []).map(function (t) {
      return { usd: (f18(t[3]) * px.eth + f18(t[4]) * px.nlyra) * 7 * 86400, start: Number(t[2]) - 7 * 86400 };
    }).filter(function (x) { return x.usd > 0; }).sort(function (a, b) { return a.start - b.start; });
    if (tr.length) {
      var newest = tr[tr.length - 1];
      var prev = tr.length > 1 ? tr[tr.length - 2].start : (newest.start < FIRST_START + 8 * 86400 ? FIRST_START : newest.start - 86400);
      var span = Date.now() / 1000 - prev;
      if (span > 3600) return (newest.usd + (G.pendUsd || 0)) / span * 86400;
    }
    if (!H.length) return dailyUsd();
    var last = H[H.length - 1], start = H.length > 1 ? H[H.length - 2].ts : FIRST_START;
    var got = f18(last.w) * px.eth + f18(last.n) * px.nlyra + (G.pendUsd || 0);
    var secs = Date.now() / 1000 - start;
    return secs > 3600 ? got / secs * 86400 : dailyUsd();
  }
  // TREASURY BOOST: the treasury can top the stream up by sending WETH/NLYRA straight to the staking
  // contract; sweepDonations (or the next harvest) opens a 7-day tranche with it. Each tranche keeps
  // its fee part apart (elig*), so whatever is above it is the boost: shown on its own, with its end date.
  function boostInfo() {
    var now = Date.now() / 1000, day = 0, end = 0;
    (G.tr || []).forEach(function (t) {
      var e = Number(t[2]); if (e <= now) return;
      var bw = t[0] > t[3] ? t[0] - t[3] : 0n, bn = t[1] > t[4] ? t[1] - t[4] : 0n;
      if (bw < 1000000n && bn < 1000000000000n) return; // per-second rounding of the fee part, not a boost
      day += (f18(bw) * px.eth + f18(bn) * px.nlyra) * 86400; end = Math.max(end, e);
    });
    return { day: day, end: end };
  }
  function paintBoost() {
    var on = (G.boostApr || 0) >= 0.05, hb = $('h-boost');
    if (hb) {
      hb.hidden = !on;
      if (on) { $('h-boost-apr').textContent = '+' + pct(G.boostApr * 2); $('h-boost-t').textContent = 'until ' + dstr(G.boostEnd) + ' · paid by the NLYRA treasury, not by fees'; }
    }
    document.querySelectorAll('.plan').forEach(function (el) {
      var pb = el.querySelector('.pb');
      if (!pb) { pb = document.createElement('span'); pb.className = 'pb'; el.insertBefore(pb, el.querySelector('.mult')); }
      pb.hidden = !on;
      if (on) pb.textContent = '+' + pct(G.boostApr * BOOST[+el.dataset.t]) + ' treasury boost';
    });
    if (on && G.boostDay) $('g-dailytok').textContent += ' · incl. ' + usd(G.boostDay) + ' boost';
  }
  // unlock dates shown on plan cards (locks end at the next 00:00 UTC after N days)
  document.querySelectorAll('.unl').forEach(function (el) { var t = Math.ceil((Date.now() / 1000 + Number(el.dataset.d) * 86400) / 86400) * 86400; el.textContent = 'until ' + dstr(t); });


  // ---------- motion ----------
  var reduce = window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches;
  var shown = {};
  function roll(id, value, fmt) {
    var el = $(id); if (!el) return;
    if (!isFinite(value)) { el.textContent = '—'; return; }
    var from = shown[id] == null ? 0 : shown[id]; shown[id] = value;
    if (reduce || from === value) { el.textContent = fmt(value); return; }
    var t0 = performance.now(), dur = 1100;
    if (from !== 0 && Math.abs(from - value) / (Math.abs(value) || 1) > 0.002) { el.classList.remove('bump'); void el.offsetWidth; el.classList.add('bump'); }
    (function step(t) { var k = Math.min(1, Math.max(0, (t - t0) / dur)), e = 1 - Math.pow(1 - k, 3); el.textContent = fmt(from + (value - from) * e); if (k < 1) requestAnimationFrame(step); })(t0);
  }
  (function particles() {
    var c = $('fx'); if (!c || reduce) return;
    var x = c.getContext('2d'), P = [], W, Hh, dpr = Math.min(2, window.devicePixelRatio || 1);
    function size() { W = c.width = innerWidth * dpr; Hh = c.height = innerHeight * dpr; c.style.width = innerWidth + 'px'; c.style.height = innerHeight + 'px'; }
    size(); addEventListener('resize', size);
    var n = innerWidth < 700 ? 28 : 60;
    for (var i = 0; i < n; i++) P.push({ x: Math.random() * W, y: Math.random() * Hh, r: (Math.random() * 1.8 + .6) * dpr, vx: (Math.random() - .5) * .15 * dpr, vy: -(Math.random() * .35 + .08) * dpr, c: Math.random() < .5 ? '139,124,246' : '232,79,224', a: Math.random() * .5 + .15 });
    (function loop() {
      x.clearRect(0, 0, W, Hh);
      for (var i = 0; i < P.length; i++) {
        var p = P[i]; p.x += p.vx; p.y += p.vy; if (p.y < -10) { p.y = Hh + 10; p.x = Math.random() * W; }
        x.beginPath(); x.arc(p.x, p.y, p.r, 0, 6.283); x.fillStyle = 'rgba(' + p.c + ',' + p.a + ')'; x.shadowBlur = 8 * dpr; x.shadowColor = 'rgba(' + p.c + ',.8)'; x.fill();
      }
      x.shadowBlur = 0;
      for (var a = 0; a < P.length; a++) for (var b = a + 1; b < P.length; b++) {
        var dx = P[a].x - P[b].x, dy = P[a].y - P[b].y, d = dx * dx + dy * dy, lim = 110 * dpr;
        if (d < lim * lim) { x.beginPath(); x.moveTo(P[a].x, P[a].y); x.lineTo(P[b].x, P[b].y); x.strokeStyle = 'rgba(139,124,246,' + (0.12 * (1 - Math.sqrt(d) / lim)) + ')'; x.lineWidth = dpr; x.stroke(); }
      }
      if (document.visibilityState === 'visible') requestAnimationFrame(loop); else setTimeout(function () { requestAnimationFrame(loop); }, 500);
    })();
  })();
  function confetti() {
    if (reduce) return;
    var c = document.createElement('canvas'); c.className = 'confetti'; document.body.appendChild(c);
    var x = c.getContext('2d'); c.width = innerWidth; c.height = innerHeight;
    var cols = ['#8B7CF6', '#E84FE0', '#B466EE', '#4ADE80', '#ffffff'], P = [];
    for (var i = 0; i < 160; i++) P.push({ x: innerWidth / 2, y: innerHeight * .35, vx: (Math.random() - .5) * 16, vy: Math.random() * -14 - 4, s: Math.random() * 6 + 3, c: cols[i % cols.length], r: Math.random() * 6, vr: (Math.random() - .5) * .3 });
    var t0 = performance.now();
    (function loop(t) {
      x.clearRect(0, 0, c.width, c.height);
      P.forEach(function (p) { p.vy += .45; p.vx *= .99; p.x += p.vx; p.y += p.vy; p.r += p.vr; x.save(); x.translate(p.x, p.y); x.rotate(p.r); x.fillStyle = p.c; x.fillRect(-p.s / 2, -p.s / 4, p.s, p.s / 2); x.restore(); });
      if (t - t0 < 2600) requestAnimationFrame(loop); else c.remove();
    })(t0);
  }

  // ---------- data ----------
  async function prices() {
    if (ONSITE) {
      try {
        var r = await Promise.all([NLYRA, WETH].map(function (t) { return fetch('/api/desk/token?t=' + t.toLowerCase()).then(function (x) { return x.json(); }); }));
        px.nlyra = Number(r[0].priceUsd) || px.nlyra; px.eth = Number(r[1].priceUsd) || px.eth;
        px.vol = Number((r[0].best && r[0].best.vol24) || (r[0].onchain && r[0].onchain.vol24Usd)) || px.vol || 0;
      } catch (e) {}
      if (px.nlyra && px.eth) return;
    }
    try { await poolPrices(); } catch (e) {}
  }
  // ETH in USD from the WETH/USDG pool and NLYRA in ETH from the WETH/NLYRA pool. Their addresses are
  // immutables of the staking contract (checked against the Uniswap factory when it was deployed).
  var POOLC = null, POOLT0 = null;
  async function poolPrices() {
    if (!POOLC) {
      var a = await Promise.all([stR.POOL_USDG(), stR.POOL_NLYRA()]);
      POOLC = a.map(function (x) { return new E.Contract(x, POOL_ABI, ro); });
      POOLT0 = await Promise.all(POOLC.map(function (c) { return c.token0(); }));
    }
    var s = await Promise.all(POOLC.map(function (c) { return c.slot0(); }));
    function ratio(i) { var q = Number(s[i][0]) / 2 ** 96; return q * q; } // token1 per token0, raw units
    function wethFirst(i) { return POOLT0[i].toLowerCase() === WETH.toLowerCase(); }
    var ethUsd = wethFirst(0) ? ratio(0) * 1e12 : 1 / (ratio(0) * 1e-12); // WETH 18 decimals, USDG 6
    var nlyEth = wethFirst(1) ? 1 / ratio(1) : ratio(1);
    if (isFinite(ethUsd) && ethUsd > 0) px.eth = ethUsd;
    if (isFinite(nlyEth) && nlyEth > 0 && px.eth) px.nlyra = nlyEth * px.eth;
  }
  async function loadHistory() {
    var iface = new E.Interface([HARVESTED]), topic = iface.getEvent('Harvested').topicHash;
    var provs = [ro, roPub];
    for (var k = 0; k < provs.length; k++) {
      try {
        var pv = provs[k];
        var logs = await pv.getLogs({ address: SP, topics: [topic], fromBlock: SP_BLOCK, toBlock: 'latest' });
        var blocks = {}, out = [];
        for (var i = 0; i < logs.length; i++) {
          var ev = iface.parseLog(logs[i]);
          if (!blocks[logs[i].blockNumber]) blocks[logs[i].blockNumber] = await pv.getBlock(logs[i].blockNumber);
          out.push({ ts: blocks[logs[i].blockNumber].timestamp, w: ev.args.wethToStaking, n: ev.args.nlyraToStaking });
        }
        H = out;
        return;
      } catch (e) { /* try the next RPC */ }
    }
  }

  async function loadPool() {
    var r = await stR.rewardInfo();
    G = { wr: r[0], nr: r[1], finish: r[2], tb: r[3], ts: r[4], tc: r[5], bonus: r[6] };
    try { G.paused = await stR.paused(); } catch (e) {}
    G.pw = 0; G.pn = 0;
    try { var q0 = await lkR.collectFees.staticCall(NLYRA, { from: SP }); G.pw = f18(q0[0]); G.pn = f18(q0[1]); } catch (e) { /* NoFeesToCollect */ }
    G.pendUsd = (G.pw * px.eth + G.pn * px.nlyra) * 0.35;
    try { G.tr = await stR.tranches(); } catch (e) { G.tr = G.tr || []; }
    var d = dailyUsd(), tbUsd = f18(G.tb) * px.nlyra;
    G.pace = paceUsd();
    G.baseApr = tbUsd > 0 ? G.pace * 365 / tbUsd * 100 : 0;
    roll('g-staked', f18(G.ts), function (v) { return kfmt(v) + ' NLYRA'; });
    $('g-stakedusd').textContent = px.nlyra ? '≈ ' + usd(f18(G.ts) * px.nlyra) : ' ';
    if (d > 0) roll('g-daily', d, usd); else $('g-daily').textContent = '—';
    $('g-dailytok').textContent = d > 0 ? num(f18(G.wr) * 86400, 5) + ' WETH + ' + kfmt(f18(G.nr) * 86400) + ' NLYRA' : 'starts with the first harvest';
    var pw = 0, pn = 0; H.forEach(function (h) { pw += f18(h.w); pn += f18(h.n); });
    if (H.length) roll('g-paid', pw * px.eth + pn * px.nlyra, usd); else $('g-paid').textContent = '—';
    $('g-paidn').textContent = H.length ? H.length + (H.length === 1 ? ' daily payout' : ' daily payouts') + ' so far' : 'first payout pending';
    if (G.baseApr) roll('h-apr', G.baseApr * 2, pct); else $('h-apr').textContent = '—';
    await loadVault(d);
    var live = $('live');
    live.classList.toggle('on', d > 0 && !G.paused);
    live.querySelector('span').textContent = G.paused ? 'Paused' : d > 0 ? 'Live · rewards streaming' : 'Live · waiting for first payout';
    document.querySelectorAll('.plan').forEach(function (el) { var a = el.querySelector('.apr'); if (!a.id) a.id = 'plan-apr-' + el.dataset.t; if (G.baseApr) roll(a.id, G.baseApr * BOOST[+el.dataset.t], pct); else a.textContent = '—'; });
    var bi = boostInfo();
    G.boostDay = bi.day; G.boostEnd = bi.end;
    G.boostApr = tbUsd > 0 && bi.day > 0 ? bi.day * 365 / tbUsd * 100 : 0;
    paintBoost();
    drawHistory();
    estimate();
  }

  async function loadVault(d) {
    try {
      var c = await stR.committedRewards(), wait = Number(await spR.harvestableIn());
      var vw = f18(c[0]), vn = f18(c[1]), vu = vw * px.eth + vn * px.nlyra;
      roll('v-usd', vu, function (v) { return '$' + v.toFixed(2); });
      $('v-weth').textContent = num(vw, 6); $('v-nlyra').textContent = num(vn, 0);
      var fin = Number(G.finish), now = Date.now() / 1000;
      var pctLeft = Math.min(100, Math.max(0, fin - now) / (7 * 86400) * 100);
      drawTank();
      $('v-streamed').textContent = vu > 0 ? 'Each layer is one daily payout, draining evenly over 7 days' : 'Nothing waiting right now';
      $('v-end').textContent = fin > now ? 'fully paid out in ' + left(fin) : '';
      G.nextAt = Date.now() + wait * 1000;
      // fees already earned by the NLYRA position since the last collection (read-only simulation of the collect)
      var pw = G.pw || 0, pn = G.pn || 0;
      var gross = pw * px.eth + pn * px.nlyra, toStakers = gross * 0.7 * 0.5;
      roll('v-est', toStakers, usd);
      $('v-est-s').textContent = num(pw * .35, 6) + ' WETH + ' + num(pn * .35, 0) + ' NLYRA so far';
      roll('v-vol', gross * 0.7, usd);
      $('v-vol-s').textContent = gross ? usd(gross) + ' accrued on Pons − 30% Pons protocol fee · split 50/50 stakers/treasury' : 'split 50% stakers · 50% treasury';
    } catch (e) {}
  }
  setInterval(function () {
    if (!G.nextAt) return;
    var s = Math.max(0, (G.nextAt - Date.now()) / 1000), h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = Math.floor(s % 60);
    var t = s <= 0 ? 'due now' : (h ? h + 'h ' : '') + String(m).padStart(2, '0') + 'm ' + String(sec).padStart(2, '0') + 's';
    $('v-next').textContent = t; $('next-t').textContent = t;
    // the daily collection is permissionless: when it is due, anyone can trigger it from here
    var due = s <= 0, hb = $('b-harvest');
    if (hb && hb.hidden === due) { hb.hidden = !due; $('v-next-s').textContent = due ? 'anyone can trigger it · you only pay the gas' : 'collected every 24 h · anyone can trigger it'; }
    var ring = $('next-ring'); if (ring) ring.style.strokeDashoffset = (94.25 * Math.min(1, s / 86400)).toFixed(2);
  }, 1000);

  async function loadUser() {
    if (!me) { renderLocks(); return; }
    var r = await Promise.all([stR.userInfo(me), stR.positionsOf(me), nlR.balanceOf(me), nlR.allowance(me, ST), stR.boostedBalanceOf(me)]);
    var a = r[0].account;
    U = { flex: a.flexible, locked: a.locked, cooling: a.cooling, coolEnd: a.cooldownEnd, ew: r[0].earnedWeth, en: r[0].earnedNlyra, pos: r[1], bal: r[2], allow: r[3], boosted: r[4] };
    var staked = U.flex + U.locked;
    $('me-bal').textContent = tok(U.bal) + ' NLYRA';
    $('me-staked').textContent = tok(staked) + ' NLYRA';
    $('me-weight').textContent = tok(U.boosted);
    var share = G.tb > 0n ? f18(U.boosted) / f18(G.tb) : 0;
    roll('me-share', share * 100, function (v) { return num(v, v >= 10 ? 1 : 2) + '%'; });
    drawDonut(share);
    var myApr = staked > 0n && G.baseApr ? G.baseApr * f18(U.boosted) / f18(staked) : 0;
    if (myApr) roll('me-apr', myApr, pct); else $('me-apr').textContent = '—';
    var myBoost = staked > 0n && G.boostApr ? G.boostApr * f18(U.boosted) / f18(staked) : 0;
    $('me-boost-k').hidden = $('me-boost').hidden = !(myBoost >= 0.05);
    if (myBoost >= 0.05) $('me-boost').textContent = '+' + pct(myBoost) + ' until ' + dstr(G.boostEnd);
    var myDay = dailyUsd() * share;
    $('me-rate').textContent = myDay ? usd(myDay) + ' / day' : '—';
    // live ticker: start from on-chain earned, grow at my share of the stream
    tick.base = f18(U.ew) * px.eth + f18(U.en) * px.nlyra; tick.rate = myDay / 86400; tick.at = Date.now();
    $('rw-weth').textContent = num(f18(U.ew), 6);
    $('rw-nlyra').textContent = num(f18(U.en), 0);
    var has = U.ew > 0n || U.en > 0n;
    $('b-claim').disabled = !has; $('b-compound').disabled = !has || G.paused;
    var badge = $('tab-earn-badge'); badge.hidden = !(tick.base >= 0.01); badge.textContent = usd(tick.base);
    // flexible / cooldown
    var coolReady = U.cooling > 0n && Number(U.coolEnd) * 1000 <= Date.now();
    $('flex-line').textContent = tok(U.flex) + ' NLYRA staked flexible' + (U.cooling > 0n ? ' · ' + tok(U.cooling) + ' in cooldown ' + (coolReady ? '(ready to withdraw)' : '(ready in ' + left(U.coolEnd) + ')') : '');
    $('b-unstake').disabled = U.flex === 0n;
    $('b-withdraw').hidden = !coolReady;
    $('b-cancelcool').hidden = U.cooling === 0n;
    // pending withdrawal on top, with the exact time it unlocks in the viewer's own clock (1/10)
    var cb = $('cool-banner');
    cb.hidden = U.cooling === 0n;
    if (U.cooling > 0n) {
      var cEnd = Number(U.coolEnd) * 1000, cPct = Math.max(0, Math.min(100, (Date.now() - (cEnd - 2 * 86400e3)) / (2 * 86400e3) * 100));
      cb.classList.toggle('ready', coolReady);
      $('cb-k').textContent = coolReady ? 'Ready to withdraw' : 'Withdrawal in progress';
      $('cb-amt').textContent = tok(U.cooling);
      $('cb-t').textContent = coolReady
        ? 'The 2-day cooldown is over. Withdraw sends it back to this wallet.'
        : 'Ready in ' + left(U.coolEnd) + ' · ' + new Date(cEnd).toLocaleString('en-US', { weekday: 'short', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' }) + ' (your time)';
      $('cb-bar').style.width = (coolReady ? 100 : cPct).toFixed(1) + '%';
      $('cb-withdraw').hidden = !coolReady;
    }
    renderLocks();
    quoteClaim();
    estimate();
  }

  // ---------- charts ----------
  function svgEl(tag, attrs, text) { var e = document.createElementNS('http://www.w3.org/2000/svg', tag); for (var k in attrs) e.setAttribute(k, attrs[k]); if (text != null) e.textContent = text; return e; }
  function drawDonut(share) {
    var s = $('donut'); s.innerHTML = '';
    var R = 50, C = 2 * Math.PI * R;
    s.appendChild(svgEl('circle', { cx: 60, cy: 60, r: R, fill: 'none', stroke: 'rgba(154,167,189,.14)', 'stroke-width': 14 }));
    if (!document.getElementById('dg')) {
      var defs = svgEl('defs', {}), lg = svgEl('linearGradient', { id: 'dg', x1: 0, x2: 1 });
      lg.appendChild(svgEl('stop', { offset: 0, 'stop-color': '#8B7CF6' })); lg.appendChild(svgEl('stop', { offset: 1, 'stop-color': '#E84FE0' }));
      defs.appendChild(lg); s.appendChild(defs);
    }
    var v = Math.max(share > 0 ? 0.012 : 0, Math.min(1, share));
    s.appendChild(svgEl('circle', { cx: 60, cy: 60, r: R, fill: 'none', stroke: 'url(#dg)', 'stroke-width': 14, 'stroke-linecap': 'round', 'stroke-dasharray': (C * v) + ' ' + C }));
  }
  function drawPlans(amountN) {
    var s = $('chart-plans'); s.innerHTML = '';
    var W = 320, Hh = 170, top = 22, bottom = 26, bw = 46, gap = (W - bw * 4) / 5;
    var d = G.pace || dailyUsd(), vals = BOOST.map(function (b) {
      if (!amountN || !d) return 0; var w = amountN * b; return d * w / (f18(G.tb) + w) * 30;
    });
    var mx = Math.max.apply(null, vals) || 1;
    s.appendChild(svgEl('line', { x1: 0, x2: W, y1: Hh - bottom, y2: Hh - bottom, stroke: 'rgba(154,167,189,.2)' }));
    vals.forEach(function (v, i) {
      var h = v ? Math.max(4, (Hh - top - bottom) * v / mx) : 4, x = gap + i * (bw + gap), y = Hh - bottom - h;
      s.appendChild(svgEl('rect', { x: x, y: y, width: bw, height: h, rx: 6, fill: i === stTier ? (i === 3 ? '#E84FE0' : '#8B7CF6') : 'rgba(139,124,246,.28)' }));
      s.appendChild(svgEl('text', { x: x + bw / 2, y: Hh - 8, 'text-anchor': 'middle' }, ['Flex', '7d', '14d', '30d'][i]));
      if (v) s.appendChild(svgEl('text', { x: x + bw / 2, y: y - 6, 'text-anchor': 'middle', class: 'val' }, usd(v)));
    });
    if (!amountN || !d) s.appendChild(svgEl('text', { x: W / 2, y: 60, 'text-anchor': 'middle' }, d ? 'Enter an amount to compare plans' : 'Waiting for the first payout'));
  }
  // ---------- fee tank: one layer per daily payout, draining to stakers over 7 days ----------
  function drawTank() {
    var s = $('tank'); if (!s) return; s.innerHTML = '';
    var now = Date.now() / 1000, W = 360, X = 14, Y = 10, TW = 136, TH = 168, R = 16;
    var layers = (G.tr || []).map(function (t) {
      var left = Math.max(0, Number(t[2]) - now), u = (f18(t[0]) * px.eth + f18(t[1]) * px.nlyra) * left;
      return { usd: u, end: Number(t[2]), start: Number(t[2]) - 7 * 86400 };
    }).filter(function (l) { return l.usd > 0.005; });
    var pend = G.pendUsd || 0, tot = layers.reduce(function (a, l) { return a + l.usd; }, 0) + pend;
    var defs = svgEl('defs', {}), cp = svgEl('clipPath', { id: 'tclip' });
    cp.appendChild(svgEl('rect', { x: X, y: Y, width: TW, height: TH, rx: R })); defs.appendChild(cp);
    var lg = svgEl('linearGradient', { id: 'tg', x1: 0, x2: 0, y1: 1, y2: 0 });
    lg.appendChild(svgEl('stop', { offset: 0, 'stop-color': '#8B7CF6' })); lg.appendChild(svgEl('stop', { offset: 1, 'stop-color': '#E84FE0' }));
    defs.appendChild(lg); s.appendChild(defs);
    s.appendChild(svgEl('rect', { x: X, y: Y, width: TW, height: TH, rx: R, class: 'shell' }));
    if (!tot) {
      s.appendChild(svgEl('text', { x: X + TW + 18, y: Y + TH / 2, class: 'dim' }, 'Nothing waiting right now'));
      return;
    }
    var g = svgEl('g', { 'clip-path': 'url(#tclip)' }); s.appendChild(g);
    var fillH = TH * 0.86, minH = 12, n = layers.length + (pend > 0 ? 1 : 0);
    var hs = layers.map(function (l) { return l.usd / tot * fillH; }).concat(pend > 0 ? [pend / tot * fillH] : []);
    var extra = hs.reduce(function (a, h) { return a + Math.max(0, minH - h); }, 0), big = hs.filter(function (h) { return h > minH; }).reduce(function (a, h) { return a + h; }, 0) || 1;
    hs = hs.map(function (h) { return h < minH ? minH : h - extra * (h / big); });
    var y = Y + TH, labels = [];
    layers.forEach(function (l, i) {
      var h = hs[i]; y -= h;
      var k = layers.length > 1 ? i / (layers.length - 1) : 1;
      g.appendChild(svgEl('rect', { x: X, y: y, width: TW, height: h, fill: 'url(#tg)', opacity: (0.45 + 0.5 * k).toFixed(2) }));
      g.appendChild(svgEl('line', { x1: X, x2: X + TW, y1: y, y2: y, stroke: 'rgba(7,11,24,.55)', 'stroke-width': 1.5 }));
      labels.push({ y: y + h / 2, a: dstr(l.start) + ' payout', b: usd(l.usd) + ' left', c: 'ends ' + dstr(l.end) });
    });
    if (pend > 0) {
      var h = hs[hs.length - 1]; y -= h;
      g.appendChild(svgEl('rect', { x: X + 1, y: y, width: TW - 2, height: h, class: 'ghost' }));
      labels.push({ y: y + h / 2, a: 'Next payout', b: usd(pend) + ' so far', c: 'collecting now', ghost: true });
    }
    // surface wave on the liquid
    var wv = svgEl('path', { d: 'M' + (X - 60) + ' ' + y + ' q 15 -5 30 0 t 30 0 t 30 0 t 30 0 t 30 0 t 30 0 t 30 0 t 30 0 t 30 0 V ' + (y + 6) + ' H ' + (X - 60) + ' Z', fill: 'rgba(233,238,248,.18)' });
    wv.appendChild(svgEl('animateTransform', { attributeName: 'transform', type: 'translate', from: '0 0', to: '60 0', dur: '3.2s', repeatCount: 'indefinite' }));
    g.appendChild(wv);
    // spout and drops flowing to stakers
    s.appendChild(svgEl('rect', { x: X + TW / 2 - 7, y: Y + TH, width: 14, height: 8, rx: 3, fill: 'rgba(154,167,189,.35)' }));
    var dp = svgEl('path', { id: 'dpath', d: 'M' + (X + TW / 2) + ' ' + (Y + TH + 8) + ' C ' + (X + TW / 2) + ' ' + (Y + TH + 26) + ' ' + (X + TW + 30) + ' ' + (Y + TH + 28) + ' ' + (X + TW + 44) + ' ' + (Y + TH + 28), fill: 'none', stroke: 'rgba(232,79,224,.25)', 'stroke-dasharray': '3 5' });
    s.appendChild(dp);
    [0, .8, 1.6].forEach(function (b) {
      var c = svgEl('circle', { r: 3, class: 'drop' }), am = svgEl('animateMotion', { dur: '2.4s', begin: b + 's', repeatCount: 'indefinite' });
      var mp = svgEl('mpath', {}); mp.setAttributeNS('http://www.w3.org/1999/xlink', 'href', '#dpath'); mp.setAttribute('href', '#dpath');
      am.appendChild(mp); c.appendChild(am); s.appendChild(c);
    });
    s.appendChild(svgEl('text', { x: X + TW + 50, y: Y + TH + 32, class: 'v' }, usd(dailyUsd()) + ' / day to stakers'));
    // labels on the right, spread so they never overlap
    var LX = X + TW + 18, gap = 30, top = Y + 12, bot = Y + TH - 6;
    labels.sort(function (p, q) { return p.y - q.y; });
    for (var i = 0; i < labels.length; i++) labels[i].ly = Math.max(labels[i].y, i ? labels[i - 1].ly + gap : top);
    var over = labels.length ? labels[labels.length - 1].ly - bot : 0;
    if (over > 0) for (var j = labels.length - 1; j >= 0; j--) labels[j].ly = Math.min(labels[j].ly - over, j < labels.length - 1 ? labels[j + 1].ly - gap : bot);
    labels.slice(-6).forEach(function (L) {
      s.appendChild(svgEl('line', { x1: X + TW + 2, x2: LX - 4, y1: L.y, y2: L.ly - 4, class: 'lead' }));
      s.appendChild(svgEl('text', { x: LX, y: L.ly - 6, class: L.ghost ? 'v' : '' }, L.a));
      s.appendChild(svgEl('text', { x: LX, y: L.ly + 9, class: 'v' }, L.b));
      var t2 = s.lastChild, w = 0; try { w = t2.getComputedTextLength(); } catch (e) { w = 90; }
      s.appendChild(svgEl('text', { x: LX + w + 7, y: L.ly + 9, class: 'dim' }, '· ' + L.c));
    });
  }

  // ---------- share card (1200x630) ----------
  var logoImg = null;
  function loadLogo() {
    return new Promise(function (res) {
      if (logoImg) return res(logoImg);
      var im = new Image(); im.onload = function () { logoImg = im; res(im); }; im.onerror = function () { res(null); };
      im.src = LOGO;
    });
  }
  async function openShare(amountN, tier) {
    var cv = $('share-cv'), x = cv.getContext('2d'), W = 1200, Hh = 630;
    try { await Promise.all([document.fonts.load('700 96px "Space Grotesk"'), document.fonts.load('500 30px Inter')]); } catch (e) {}
    var logo = await loadLogo();
    x.fillStyle = '#070B18'; x.fillRect(0, 0, W, Hh);
    var g1 = x.createRadialGradient(1010, 120, 10, 1010, 120, 520); g1.addColorStop(0, 'rgba(139,124,246,.42)'); g1.addColorStop(1, 'rgba(139,124,246,0)');
    x.fillStyle = g1; x.fillRect(0, 0, W, Hh);
    var g2 = x.createRadialGradient(140, 600, 10, 140, 600, 520); g2.addColorStop(0, 'rgba(232,79,224,.30)'); g2.addColorStop(1, 'rgba(232,79,224,0)');
    x.fillStyle = g2; x.fillRect(0, 0, W, Hh);
    x.strokeStyle = 'rgba(154,167,189,.18)'; x.lineWidth = 2; x.strokeRect(24, 24, W - 48, Hh - 48);
    if (logo) { x.save(); x.shadowColor = 'rgba(139,124,246,.6)'; x.shadowBlur = 50; x.drawImage(logo, 840, 150, 290, 290); x.restore(); }
    if (logo) x.drawImage(logo, 72, 64, 56, 56);
    x.fillStyle = '#E9EEF8'; x.font = '700 30px "Space Grotesk", sans-serif'; x.fillText('NLYRA', 140, 103);
    x.fillStyle = '#E84FE0'; x.fillText('Real Yield', 140 + x.measureText('NLYRA ').width, 103);
    x.fillStyle = '#9AA7BD'; x.font = '500 30px Inter, sans-serif'; x.fillText("I'm staking", 72, 220);
    var big = num(amountN, 0), fs = 104;
    x.font = '700 ' + fs + 'px "Space Grotesk", sans-serif';
    while (x.measureText(big + ' NLYRA').width > 740 && fs > 56) { fs -= 4; x.font = '700 ' + fs + 'px "Space Grotesk", sans-serif'; }
    var gg = x.createLinearGradient(72, 0, 800, 0); gg.addColorStop(0, '#8B7CF6'); gg.addColorStop(1, '#E84FE0');
    x.fillStyle = gg; x.fillText(big, 72, 330);
    x.fillStyle = '#E9EEF8'; x.fillText(' NLYRA', 72 + x.measureText(big).width, 330);
    var plan = tier ? TIER_DAYS[tier] + '-day lock · ' + BOOST[tier] + '× weight' : 'Flexible · 1× weight';
    x.font = '600 28px Inter, sans-serif'; var pw = x.measureText(plan).width + 44;
    x.fillStyle = 'rgba(232,79,224,.12)'; x.strokeStyle = 'rgba(232,79,224,.55)'; x.lineWidth = 2;
    x.beginPath(); if (x.roundRect) x.roundRect(72, 370, pw, 54, 27); else x.rect(72, 370, pw, 54); x.fill(); x.stroke();
    x.fillStyle = '#E84FE0'; x.fillText(plan, 94, 407);
    x.fillStyle = '#E9EEF8'; x.font = '600 34px Inter, sans-serif'; x.fillText('Earning real ETH from every NLYRA trade', 72, 490);
    var apr = G.baseApr ? G.baseApr * BOOST[tier || 0] : 0;
    x.fillStyle = '#9AA7BD'; x.font = '500 26px Inter, sans-serif';
    var url = ONSITE ? location.origin + '/newstake/app/' : location.href.split(/[?#]/)[0];
    x.fillText((apr ? pct(apr) + ' APR at today\'s fee pace · ' : '') + url.replace(/^https?:\/\//, '').replace(/\/$/, ''), 72, 540);
    var txt = "I'm staking " + kfmt(amountN) + ' $NLYRA on NLYRA Real Yield (' + (tier ? TIER_DAYS[tier] + '-day lock' : 'flexible') + '). Real ETH from every trade, nothing printed.';
    try { $('share-dl').href = cv.toDataURL('image/png'); } catch (e) {}
    $('share-xpost').href = 'https://twitter.com/intent/tweet?text=' + encodeURIComponent(txt) + '&url=' + encodeURIComponent(url);
    $('share-tg').href = 'https://t.me/share/url?url=' + encodeURIComponent(url) + '&text=' + encodeURIComponent(txt);
    $('share').hidden = false;
  }
  window.__nlyraShare = openShare;
  $('share-close').onclick = function () { $('share').hidden = true; };
  $('share').onclick = function (e) { if (e.target === this) this.hidden = true; };
  document.addEventListener('keydown', function (e) { if (e.key === 'Escape') $('share').hidden = true; });
  if (window.matchMedia && matchMedia('(prefers-reduced-motion: reduce)').matches) {
    document.querySelectorAll('svg').forEach(function (v) { if (v.pauseAnimations) v.pauseAnimations(); });
  }

  function drawHistory() {
    var s = $('chart-hist'); s.innerHTML = '';
    var W = 320, Hh = 140, top = 20, bottom = 24;
    s.appendChild(svgEl('line', { x1: 0, x2: W, y1: Hh - bottom, y2: Hh - bottom, stroke: 'rgba(154,167,189,.2)' }));
    if (!H.length) { s.appendChild(svgEl('text', { x: W / 2, y: 60, 'text-anchor': 'middle' }, 'First daily payout pending')); return; }
    var list = H.slice(-14), vals = list.map(function (h) { return f18(h.w) * px.eth + f18(h.n) * px.nlyra; });
    var mx = Math.max.apply(null, vals) || 1, n = Math.max(list.length, 7), slot = W / n, bw = Math.min(34, slot * .62);
    list.forEach(function (h, i) {
      var v = vals[i], ht = Math.max(4, (Hh - top - bottom) * v / mx), x = i * slot + (slot - bw) / 2, y = Hh - bottom - ht;
      s.appendChild(svgEl('rect', { x: x, y: y, width: bw, height: ht, rx: 5, fill: i === list.length - 1 ? '#E84FE0' : '#8B7CF6' }));
      s.appendChild(svgEl('text', { x: x + bw / 2, y: Hh - 8, 'text-anchor': 'middle' }, dstr(h.ts)));
      if (list.length <= 7 || i === list.length - 1) s.appendChild(svgEl('text', { x: x + bw / 2, y: y - 6, 'text-anchor': 'middle', class: 'val' }, usd(v)));
    });
  }

  // ---------- stake estimate ----------
  function estimate() {
    var a = parseAmt($('st-amt').value), an = f18(a), d = G.pace || dailyUsd();
    // nothing typed: show a real example ($1,000 of NLYRA) instead of an empty box
    var ex = !an && px.nlyra > 0 && d > 0;
    $('est-ex').hidden = !ex;
    if (ex) an = 1000 / px.nlyra;
    var w = an * BOOST[stTier], share = an && G.tb != null ? w / (f18(G.tb) + w) : 0, day = d * share;
    var apr = an && px.nlyra ? day * 365 / (an * px.nlyra) * 100 : G.baseApr * BOOST[stTier];
    roll('est-day', day, usd); roll('est-week', day * 7, usd); roll('est-month', day * 30, usd);
    if (apr) roll('est-apr', apr, pct); else $('est-apr').textContent = '—';
    drawPlans(an);
    var b = $('b-stake');
    if (!me) { b.disabled = false; b.textContent = 'Connect wallet to stake'; return; }
    b.disabled = a === 0n || !U.bal || a > U.bal || G.paused;
    b.textContent = a === 0n ? 'Enter an amount' : a > (U.bal || 0n) ? 'Not enough NLYRA' : (U.allow < a ? 'Approve & stake ' : 'Stake ') + kfmt(an) + ' · ' + TIER_NAME[stTier];
  }

  // ---------- claim quote ----------
  var qSeq = 0;
  async function quoteClaim() {
    var el = $('rw-quote'), seq = ++qSeq;
    if (!me) { el.textContent = 'Connect your wallet'; return; }
    if (U.ew === 0n && U.en === 0n) { el.textContent = 'Nothing yet'; return; }
    if (mode === 0) { el.textContent = num(f18(U.ew), 6) + ' WETH + ' + num(f18(U.en), 0) + ' NLYRA'; return; }
    el.textContent = 'Quoting…';
    try {
      var out = await stR.claim.staticCall(mode, 0, { from: me });
      if (seq !== qSeq) return;
      var v = Number(E.formatUnits(out, mode === 3 ? 6 : 18));
      el.textContent = '≈ ' + num(v, mode === 2 ? 0 : mode === 3 ? 2 : 6) + ' ' + (mode === 1 ? 'WETH' : mode === 2 ? 'NLYRA' : 'USDG');
    } catch (e) { if (seq === qSeq) el.textContent = 'Quote unavailable'; }
  }

  // ---------- locks ----------
  function openLocks() { return (U.pos || []).map(function (p, i) { return { id: i, amount: p.amount, unlock: Number(p.unlockTime), tier: Number(p.tier) }; }).filter(function (p) { return p.amount > 0n; }); }
  function slotsFull() { return openLocks().length >= MAX_POS; }
  var FULL_MSG = 'All ' + MAX_POS + ' lock slots in this wallet are in use. Free one in <b>My locks</b> (remove tiny locks or release an unlocked one).';
  function fmtTiny(x) { return x < 1000000000000n ? x.toString() + ' wei' : num(f18(x), 6) + ' NLYRA'; }
  // withdrawLocked adds to the account cooldown and restarts its 2-day clock if it has not finished:
  // clearing junk must never delay a real withdrawal that is already waiting.
  function coolPending() { return U.cooling > TINY && Number(U.coolEnd) * 1000 > Date.now(); }
  function renderJunk(tiny, now) {
    var ready = tiny.filter(function (p) { return p.unlock <= now; }), wait = coolPending();
    return '<div class="junk"><div class="junk-h"><b>Tiny locks <small>(under 1,000 NLYRA)</small></b>' +
      (ready.length > 1 && !wait ? '<button class="btn btn-ghost btn-sm" data-act="junkall">Remove all ready (' + ready.length + ')</button>' : '') + '</div>' +
      '<p>Anyone can send a lock to any wallet, so if you didn\'t create these, someone sent them to you. They can\'t take anything from you: each one only uses a lock slot. Once a lock unlocks you can remove it (its dust goes to your cooldown), or move it to another wallet of yours right away.</p>' +
      (wait ? '<p class="junk-w">You have ' + tok(U.cooling) + ' NLYRA in cooldown until ' + dstr(U.coolEnd) + '. Removing a lock now would restart that 2-day countdown, so wait until it is ready and withdraw it first.</p>' : '') +
      tiny.map(function (p) {
        var open = p.unlock > now;
        return '<div class="junk-r"><span><b>' + fmtTiny(p.amount) + '</b> · lock #' + p.id + ' · ' + (open ? 'removable from ' + dstr(p.unlock) : 'unlocked') + '</span>' +
          (open ? '<span class="lock-mv"><input data-to="' + p.id + '" placeholder="Move to wallet 0x…" spellcheck="false"><button class="btn btn-ghost btn-sm" data-act="offer" data-id="' + p.id + '">Move</button></span>'
                : '<button class="btn btn-ghost btn-sm" data-act="junkrm" data-id="' + p.id + '"' + (wait ? ' disabled' : '') + '>Remove</button>') + '</div>';
      }).join('') + '</div>';
  }
  function renderLocks() {
    var box = $('locks'), now = Date.now() / 1000;
    if (!me) { box.innerHTML = '<p class="empty">Connect your wallet to see your locks.</p>'; $('tab-locks-badge').hidden = true; return; }
    var all = openLocks();
    var tiny = all.filter(function (p) { return p.amount < TINY; }), list = all.filter(function (p) { return p.amount >= TINY; });
    var bdg = $('tab-locks-badge'); bdg.hidden = !all.length; bdg.textContent = all.length;
    var head = all.length ? '<div class="slots' + (all.length >= MAX_POS - 4 ? ' near' : '') + '">Lock slots <b>' + all.length + ' / ' + MAX_POS + '</b>' +
      (all.length >= MAX_POS ? ' · full: new locks and purchases will fail until you free one' : '') +
      (coolPending() && list.some(function (p) { return p.unlock <= now; }) ? '<span>Releasing a lock while ' + tok(U.cooling) + ' NLYRA is in cooldown restarts that 2-day countdown.</span>' : '') + '</div>' : '';
    var junk = tiny.length ? renderJunk(tiny, now) : '';
    if (!list.length) { box.innerHTML = head + junk + (tiny.length ? '' : '<p class="empty">No locks yet. Pick a 7, 14 or 30-day plan in <b>Stake</b> to earn more.</p>'); return; }
    Promise.all(list.map(function (p) { return stR.positionOffer(me, p.id).catch(function () { return E.ZeroAddress; }); })).then(function (offers) {
      box.innerHTML = head + junk + list.map(function (p, k) {
        var open = p.unlock > now, off = offers[k] !== E.ZeroAddress ? offers[k] : null;
        var days = TIER_DAYS[p.tier] || 30, start = p.unlock - days * 86400, prog = open ? Math.min(100, Math.max(2, (now - start) / (p.unlock - start) * 100)) : 100;
        var chip = open && p.tier ? '<span class="chip' + (p.tier === 3 ? ' l30' : '') + '">' + TIER_NAME[p.tier] + ' · ' + BOOST[p.tier] + '×</span>' : '<span class="chip done">Unlocked</span>';
        var opts = [1, 2, 3].filter(function (t) { return !open || t >= p.tier; }).map(function (t) { return '<option value="' + t + '"' + (t === 3 ? ' selected' : '') + '>' + TIER_NAME[t] + '</option>'; }).join('');
        return '<div class="lock"><div class="lock-h"><b>' + tok(p.amount) + ' <small class="muted" style="font:500 13px var(--body)">NLYRA</small></b>' + chip + '</div>' +
          '<div class="bar"><i style="width:' + prog.toFixed(1) + '%"></i></div>' +
          '<div class="lock-m"><span>' + (open ? 'Unlocks ' + dstr(p.unlock) + ' · in ' + left(p.unlock) : 'Ready to release') + '</span><span>Lock #' + p.id + '</span></div>' +
          '<div class="lock-a">' + (open ? '' : '<button class="btn btn-ghost btn-sm" data-act="release" data-id="' + p.id + '">Release</button>') +
          '<select data-sel="' + p.id + '" aria-label="New lock length">' + opts + '</select><button class="btn btn-ghost btn-sm" data-act="extend" data-id="' + p.id + '">' + (open ? 'Extend' : 'Re-lock') + '</button>' +
          (open ? '<button class="btn btn-ghost btn-sm" data-act="share" data-id="' + p.id + '" data-amt="' + f18(p.amount) + '" data-tier="' + p.tier + '">Share</button>' : '') + '</div>' +
          (off ? '<div class="lock-a"><span class="offered">Offered to ' + short(off) + '</span><button class="btn btn-ghost btn-sm" data-act="unoffer" data-id="' + p.id + '">Cancel</button></div>'
               : '<div class="lock-mv"><input data-to="' + p.id + '" placeholder="Move to wallet 0x…" spellcheck="false"><button class="btn btn-ghost btn-sm" data-act="offer" data-id="' + p.id + '">Move</button></div>') +
          '</div>';
      }).join('');
    });
  }

  // ---------- wallet ----------
  var found = [];
  window.addEventListener('eip6963:announceProvider', function (e) { found.push(e.detail); });
  window.dispatchEvent(new Event('eip6963:requestProvider'));
  async function connect() {
    var d = found.filter(function (x) { return /metamask/i.test((x.info && x.info.name) || ''); })[0] || found[0];
    eip = d ? d.provider : window.ethereum;
    if (!eip) { toast('No wallet found. Open this page in a browser with MetaMask or Rabby.'); return; }
    try {
      var accs = await eip.request({ method: 'eth_requestAccounts' });
      await ensureChain();
      await setAccount(accs[0]);
      if (eip.on) {
        eip.on('accountsChanged', function (a) { setAccount(a[0]); });
        eip.on('chainChanged', function () { refresh(); });
      }
    } catch (e) { toast('Connect failed: ' + esc(errMsg(e))); }
  }
  async function setAccount(a) {
    me = a ? E.getAddress(a) : null;
    signer = me ? await new E.BrowserProvider(eip, 'any').getSigner(me) : null;
    $('connect-t').textContent = me ? short(me) : 'Connect wallet';
    $('connect').classList.toggle('on', !!me);
    U = {}; refresh();
  }
  async function ensureChain() {
    var c = await eip.request({ method: 'eth_chainId' });
    if (c === CHAIN_HEX) return;
    try { await eip.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: CHAIN_HEX }] }); }
    catch (e) {
      if (e && (e.code === 4902 || /unrecognized|not added/i.test(e.message || ''))) {
        await eip.request({ method: 'wallet_addEthereumChain', params: [{ chainId: CHAIN_HEX, chainName: 'Robinhood Chain', nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 }, rpcUrls: ['https://rpc.mainnet.chain.robinhood.com'], blockExplorerUrls: ['https://robinhoodchain.blockscout.com'] }] });
      } else throw e;
    }
  }

  // ---------- tx ----------
  async function tx(label, fn) {
    if (busy) return false; busy = true; var ok = false;
    try {
      await ensureChain();
      toast('Confirm <b>' + esc(label) + '</b> in your wallet…');
      var t = await fn();
      toast(esc(label) + ' sent · waiting for confirmation…');
      log('<span class="t-warn">' + esc(label) + '</span> sent · <a target="_blank" rel="noopener" href="' + BS + t.hash + '">view tx</a>');
      var rc = await t.wait(1);
      ok = rc.status === 1;
      log(ok ? '<span class="t-ok">' + esc(label) + ' confirmed ✓</span>' : '<span class="t-bad">' + esc(label) + ' reverted</span>');
      toast(ok ? '<span class="t-ok">✓</span> ' + esc(label) + ' confirmed' : '<span class="t-bad">' + esc(label) + ' failed</span>');
      if (ok && !/^Approve/.test(label)) confetti();
    } catch (e) { log('<span class="t-bad">' + esc(label) + ':</span> ' + esc(errMsg(e))); toast('<span class="t-bad">' + esc(label) + ':</span> ' + esc(errMsg(e))); }
    busy = false;
    await refresh();
    return ok;
  }
  function st() { return new E.Contract(ST, ST_ABI, signer); }
  function nl() { return new E.Contract(NLYRA, ERC, signer); }

  async function doStake() {
    if (!me) return connect();
    var a = parseAmt($('st-amt').value); if (a === 0n) return;
    if (stTier !== 0 && slotsFull()) { toast(FULL_MSG); return; }
    if (U.allow < a) { if (!(await tx('Approve NLYRA', function () { return nl().approve(ST, a); }))) return; }
    var ok = stTier === 0 ? await tx('Stake ' + kfmt(f18(a)) + ' flexible', function () { return st().stake(a); })
      : await tx('Stake ' + kfmt(f18(a)) + ' · ' + TIER_NAME[stTier], function () { return st().stakeLocked(a, stTier); });
    if (ok) { var sharedN = f18(a), sharedT = stTier; $('st-amt').value = ''; estimate(); openShare(sharedN, sharedT); }
  }
  async function doClaim() {
    var to = $('claim-to').value.trim();
    if (to && !E.isAddress(to)) { toast('<span class="t-bad">That "send to" address is not valid.</span>'); return; }
    var minOut = 0n;
    if (mode !== 0) {
      try { minOut = (await stR.claim.staticCall(mode, 0, { from: me })) * 98n / 100n; }
      catch (e) { toast('<span class="t-bad">Could not quote the claim:</span> ' + esc(errMsg(e))); return; }
    }
    if (to) await tx('Claim as ' + MODE_NAME[mode] + ' → ' + short(to), function () { return st().claimTo(E.getAddress(to), mode, minOut); });
    else await tx('Claim as ' + MODE_NAME[mode], function () { return st().claim(mode, minOut); });
  }
  async function doCompound() {
    if (slotsFull()) { toast(FULL_MSG); return; }
    var q;
    try { q = await stR.compound.staticCall(0, 3, MAXU, { from: me }); }
    catch (e) { toast('<span class="t-bad">Could not quote the compound:</span> ' + esc(errMsg(e))); return; }
    await tx('Compound to a 30-day lock', function () { return st().compound(q * 100n / 105n * 97n / 100n, 3, MAXU); });
  }

  // ---------- UI events ----------
  $('connect').onclick = function () { if (!me) connect(); };
  document.querySelector('.tabs').onclick = function (e) {
    var b = e.target.closest('button[data-tab]'); if (!b) return;
    document.querySelectorAll('.tabs button').forEach(function (x) { x.classList.toggle('on', x === b); x.setAttribute('aria-selected', x === b); });
    document.querySelectorAll('.pane').forEach(function (p) { p.classList.toggle('on', p.dataset.pane === b.dataset.tab); });
  };
  $('plans').onclick = function (e) {
    var b = e.target.closest('.plan'); if (!b) return;
    stTier = +b.dataset.t;
    this.querySelectorAll('.plan').forEach(function (x) { x.classList.toggle('on', x === b); });
    estimate();
  };
  document.querySelector('.pcts').onclick = function (e) {
    var b = e.target.closest('button'); if (!b || !U.bal) return;
    var v = U.bal * BigInt(b.dataset.p) / 100n; $('st-amt').value = E.formatUnits(v, 18).replace(/\.0$/, ''); estimate();
  };
  // amount fields: numbers only (typing, pasting or dropping anything else is cleaned out)
  document.querySelectorAll('img').forEach(function (i) { i.draggable = false; });
  function numOnly(el, cb) {
    el.addEventListener('drop', function (e) { e.preventDefault(); });
    el.addEventListener('input', function () {
      var v = el.value.replace(/,/g, '.').replace(/[^0-9.]/g, ''), k = v.indexOf('.');
      if (k >= 0) v = v.slice(0, k + 1) + v.slice(k + 1).replace(/\./g, '');
      if (v !== el.value) el.value = v;
      if (cb) cb();
    });
  }
  numOnly($('st-amt'), estimate);
  numOnly($('un-amt'));
  $('mode').onclick = function (e) {
    var b = e.target.closest('button'); if (!b) return;
    mode = +b.dataset.m; this.querySelectorAll('button').forEach(function (x) { x.classList.toggle('on', x === b); }); quoteClaim();
  };
  $('b-stake').onclick = doStake;
  $('b-claim').onclick = doClaim;
  $('b-compound').onclick = doCompound;
  $('un-max').onclick = function () { if (U.flex) $('un-amt').value = E.formatUnits(U.flex, 18).replace(/\.0$/, ''); };
  $('b-unstake').onclick = function () {
    var a = parseAmt($('un-amt').value);
    if (a === 0n || a > U.flex) { toast('Enter an amount up to your flexible stake.'); return; }
    tx('Unstake ' + kfmt(f18(a)) + ' (2-day cooldown)', function () { return st().requestUnstake(a); });
  };
  $('b-withdraw').onclick = function () { tx('Withdraw', function () { return st().withdraw(); }); };
  $('cb-withdraw').onclick = $('b-withdraw').onclick;
  $('b-harvest').onclick = async function () {
    if (!me) { await connect(); if (!me) return; }
    tx('Trigger the daily payout', function () { return new E.Contract(SP, SP_ABI, signer).harvest(); });
  };
  $('b-cancelcool').onclick = function () { tx('Re-stake cooldown', function () { return st().cancelUnstake(); }); };
  $('locks').onclick = function (e) {
    var b = e.target.closest('button[data-act]'); if (!b) return;
    var id = +b.dataset.id, act = b.dataset.act;
    if (act === 'share') { openShare(Number(b.dataset.amt), Number(b.dataset.tier)); return; }
    if ((act === 'junkrm' || act === 'junkall') && coolPending()) { toast('Wait until your cooldown is ready: removing a lock now would restart it.'); return; }
    if (act === 'junkrm') { tx('Remove tiny lock #' + id, function () { return st().withdrawLocked(id); }); return; }
    if (act === 'junkall') {
      var now = Date.now() / 1000;
      var ids = openLocks().filter(function (p) { return p.amount < TINY && p.unlock <= now; }).map(function (p) { return p.id; });
      (async function () {
        for (var i = 0; i < ids.length; i++) {
          var one = ids[i];
          var ok = await tx('Remove tiny lock #' + one + ' (' + (i + 1) + '/' + ids.length + ')', function () { return st().withdrawLocked(one); });
          if (!ok) break;
        }
      })();
      return;
    }
    if (act === 'release') tx('Release lock #' + id, function () { return st().withdrawLocked(id); });
    if (act === 'extend') { var t = +document.querySelector('[data-sel="' + id + '"]').value; tx('Lock #' + id + ' → ' + TIER_NAME[t], function () { return st().extendLock(id, t); }); }
    if (act === 'unoffer') tx('Cancel move of lock #' + id, function () { return st().cancelPositionOffer(id); });
    if (act === 'offer') {
      var to = document.querySelector('[data-to="' + id + '"]').value.trim();
      if (!E.isAddress(to)) { toast('Enter the wallet address to move lock #' + id + ' to.'); return; }
      tx('Offer lock #' + id + ' → ' + short(to), function () { return st().offerPosition(id, E.getAddress(to)); });
    }
  };
  $('b-find').onclick = async function () {
    var from = $('rc-from').value.trim(), box = $('rc-list');
    if (!E.isAddress(from)) { box.innerHTML = '<p class="muted">Enter wallet A\'s address.</p>'; return; }
    if (!me) { box.innerHTML = '<p class="muted">Connect wallet B (the one receiving the lock) first.</p>'; return; }
    box.innerHTML = '<p class="muted">Looking…</p>';
    try {
      var ps = await stR.positionsOf(from), rows = [];
      for (var i = 0; i < ps.length; i++) {
        if (ps[i].amount === 0n) continue;
        var o = await stR.positionOffer(from, i);
        if (o.toLowerCase() === me.toLowerCase()) rows.push('<div><span>Lock #' + i + ' · <b>' + tok(ps[i].amount) + ' NLYRA</b> · ' + (Number(ps[i].unlockTime) * 1000 > Date.now() ? 'unlocks ' + dstr(ps[i].unlockTime) : 'unlocked') + '</span><button class="btn btn-primary btn-sm" data-from="' + from + '" data-id="' + i + '">Accept</button></div>');
      }
      box.innerHTML = rows.length ? rows.join('') : '<p class="muted">No locks offered to ' + short(me) + ' from that wallet.</p>';
    } catch (e) { box.innerHTML = '<p class="t-bad">' + esc(errMsg(e)) + '</p>'; }
  };
  $('rc-list').onclick = function (e) {
    var b = e.target.closest('button[data-from]'); if (!b) return;
    if (slotsFull()) { toast(FULL_MSG); return; }
    tx('Accept lock #' + b.dataset.id, function () { return st().acceptPosition(E.getAddress(b.dataset.from), +b.dataset.id); }).then(function (ok) { if (ok) $('rc-list').innerHTML = ''; });
  };

  // live ticker
  setInterval(function () {
    if (!me || !tick.at) return;
    var v = tick.base + tick.rate * (Date.now() - tick.at) / 1000;
    $('rw-usd').textContent = '$' + v.toFixed(v >= 100 ? 4 : 6);
  }, 100);

  var first = true;
  async function refresh() {
    try {
      await prices();
      if (first) { first = false; await loadHistory(); }
      await loadPool(); await loadUser();
    } catch (e) { log('<span class="t-bad">Read error:</span> ' + esc(errMsg(e))); }
  }
  refresh();
  setInterval(function () { if (!busy && document.visibilityState === 'visible') refresh(); }, 20000);
  setInterval(function () { if (document.visibilityState === 'visible') loadHistory().then(drawHistory); }, 600000);
})();
