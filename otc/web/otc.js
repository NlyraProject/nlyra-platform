/* OTC Desk — nlyra.xyz/otc. Self-contained: reads the contract through our own node's public RPC,
   token metadata + NERON verdicts through /api/desk/token, and signs with the injected wallet. */
(function () {
  'use strict';
  var d = document, q = function (s) { return d.querySelector(s); }, qa = function (s) { return Array.prototype.slice.call(d.querySelectorAll(s)); };
  var CHAIN_HEX = '0x1237', RPC_READ = 'https://nlyra.xyz/rpc', RPC_PUBLIC = 'https://rpc.mainnet.chain.robinhood.com', EXPLORER = 'https://robinhoodchain.blockscout.com';
  var ZERO = '0x0000000000000000000000000000000000000000';
  var NLYRA = '0xb9d3824149ad8ac984153ceec91d5a2405d1fb95', USDG = '0x5fc5360d0400a0fd4f2af552add042d716f1d168', WETH = '0x0bd7d308f8e1639fab988df18a8011f41eacad73';
  var PAYS = { USDG: { id: 'USDG', addr: USDG, dec: 6, sym: 'USDG' }, WETH: { id: 'WETH', addr: WETH, dec: 18, sym: 'WETH' }, NLYRA: { id: 'NLYRA', addr: NLYRA, dec: 18, sym: 'NLYRA' } };
  var MONEY = {}; MONEY[ZERO] = 1; MONEY[USDG] = 1; MONEY[WETH] = 1;
  var QUOTES = { ETH: { id: 'ETH', addr: ZERO, dec: 18, sym: 'ETH' }, USDG: { id: 'USDG', addr: USDG, dec: 6, sym: 'USDG' }, NLYRA: { id: 'NLYRA', addr: NLYRA, dec: 18, sym: 'NLYRA' } };
  var SEL = { create: '0x2f870960', fill: '0xf1a40ab3', cancel: '0x40e58ee5', getOffers: '0x97d6eb19', count: '0x06661abd', feeBps: '0x24a9d853', totalVolume: '0xe62b9e6c', totalFee: '0x7a4fda3d', totalNlyraBurned: '0x3e61ebac', totalEthToBurner: '0xfafe99ab', allowance: '0xdd62ed3e', approve: '0x095ea7b3', balanceOf: '0x70a08231', decimals: '0x313ce567', symbol: '0x95d89b41', paused: '0x5c975abb' };
  var CFG = { address: '', deployBlock: 0, feeBps: 50 };
  var S = { offers: [], meta: {}, ethUsd: 0, nlyraUsd: 0, feeBps: 50, tab: 'open', wallet: null, busy: false, form: { token: null, quote: 'ETH', lastEdited: 'price', mode: 'sell', pay: 'USDG' } };

  /* ── tiny helpers ─────────────────────────────────────────────────────── */
  var low = function (s) { return String(s || '').toLowerCase(); };
  var isAddr = function (s) { return /^0x[0-9a-fA-F]{40}$/.test(String(s || '')); };
  var short = function (a) { return a ? a.slice(0, 6) + '…' + a.slice(-4) : '—'; };
  var esc = function (s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); };
  var pad = function (h) { return String(h).replace(/^0x/, '').toLowerCase().padStart(64, '0'); };
  var encU = function (n) { return pad(BigInt(n).toString(16)); };
  var encA = function (a) { return pad(a); };
  var word = function (hex, i) { return '0x' + hex.slice(2 + i * 64, 2 + (i + 1) * 64); };
  var wU = function (hex, i) { return BigInt(word(hex, i)); };
  var wA = function (hex, i) { return '0x' + word(hex, i).slice(26); };
  function fmtUnits(n, dec, digits) {
    n = BigInt(n); dec = Number(dec) || 0;
    var neg = n < 0n; if (neg) n = -n;
    var s = n.toString().padStart(dec + 1, '0');
    var ip = s.slice(0, s.length - dec) || '0', fp = dec ? s.slice(s.length - dec) : '';
    var v = Number(ip + (fp ? '.' + fp : ''));
    return (neg ? '-' : '') + fmtNum(v, digits);
  }
  function fmtNum(v, digits) {
    if (!isFinite(v)) return '—';
    var a = Math.abs(v);
    if (a === 0) return '0';
    if (a >= 1e9) return (v / 1e9).toFixed(2) + 'B';
    if (a >= 1e6) return (v / 1e6).toFixed(2) + 'M';
    if (a >= 1e4) return Math.round(v).toLocaleString('en-US');
    if (a >= 1) return v.toLocaleString('en-US', { maximumFractionDigits: digits == null ? 4 : digits });
    if (a >= 0.0001) return v.toLocaleString('en-US', { maximumFractionDigits: 6 });
    var e = Math.floor(Math.log10(a)); var z = -e - 1;
    return (v < 0 ? '-' : '') + '0.0' + String(z).replace(/\d/g, function (c) { return '₀₁₂₃₄₅₆₇₈₉'[c]; }) + String(Math.round(a * Math.pow(10, -e + 3))).slice(0, 4);
  }
  var fmtUsd = function (v) { return !isFinite(v) ? '—' : v >= 1000 ? '$' + Math.round(v).toLocaleString('en-US') : v >= 1 ? '$' + v.toFixed(2) : '$' + fmtNum(v); };
  /** "1.000.000", "1,000,000", "1 000 000", "1,5" and "1.5" all become a plain "1000000" / "1.5" */
  function normNum(str) {
    var s = String(str || '').trim().replace(/[\s_']/g, ''); if (!s) return '';
    var dots = (s.match(/\./g) || []).length, commas = (s.match(/,/g) || []).length;
    if (dots && commas) { if (s.lastIndexOf('.') > s.lastIndexOf(',')) s = s.replace(/,/g, ''); else s = s.replace(/\./g, '').replace(',', '.'); }
    else if (dots > 1) s = s.replace(/\./g, '');
    else if (commas > 1) s = s.replace(/,/g, '');
    else if (commas === 1) { var after = s.split(',')[1]; s = after.length === 3 ? s.replace(',', '') : s.replace(',', '.'); }
    return s;
  }
  /** "1000000.5" -> "1,000,000.5" for the eye; parseUnits accepts it back */
  function groupNum(str) {
    var s = normNum(str); if (!/^\d*\.?\d*$/.test(s) || s === '' || s === '.') return null;
    var p = s.split('.'), ip = (p[0] || '0').replace(/^0+(?=\d)/, ''), fp = (p[1] || '').replace(/0+$/, '');
    return ip.replace(/\B(?=(\d{3})+(?!\d))/g, ',') + (fp ? '.' + fp : '');
  }
  function parseUnits(str, dec) {
    var s = normNum(str); if (!/^\d*\.?\d*$/.test(s) || s === '' || s === '.') return null;
    var p = s.split('.'), ip = p[0] || '0', fp = (p[1] || '').slice(0, dec).padEnd(dec, '0');
    try { return BigInt(ip + fp); } catch (_) { return null; }
  }
  var toNum = function (n, dec) { return Number(n) / Math.pow(10, dec); };
  var untilStr = function (ts) { var s = Number(ts) - Math.floor(Date.now() / 1000); if (s <= 0) return 'expired'; if (s < 3600) return Math.ceil(s / 60) + ' min'; if (s < 86400) return Math.floor(s / 3600) + ' h ' + Math.floor((s % 3600) / 60) + ' m'; return Math.floor(s / 86400) + ' d ' + Math.floor((s % 86400) / 3600) + ' h'; };

  /* ── rpc (reads through our own node) ─────────────────────────────────── */
  var rpcId = 1;
  function rpc(method, params) {
    return fetch(RPC_READ, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: rpcId++, method: method, params: params }) })
      .then(function (r) { return r.json(); }).then(function (j) { if (j.error) throw new Error(j.error.message || 'rpc'); return j.result; });
  }
  var call = function (to, data) { return rpc('eth_call', [{ to: to, data: data }, 'latest']); };
  var api = function (path, params) { var u = new URL(path, location.origin); Object.keys(params || {}).forEach(function (k) { if (params[k] != null && params[k] !== '') u.searchParams.set(k, params[k]); }); return fetch(u.toString(), { headers: { accept: 'application/json' } }).then(function (r) { return r.json(); }); };

  /* ── toasts ───────────────────────────────────────────────────────────── */
  function toast(text, kind, href) {
    var host = q('#oToasts'); if (!host) return;
    var el = d.createElement('div'); el.className = 'o-toast ' + (kind || '');
    el.innerHTML = esc(text) + (href ? '<a href="' + esc(href) + '" target="_blank" rel="noopener">view on the explorer →</a>' : '');
    host.appendChild(el); setTimeout(function () { if (el.parentNode) el.parentNode.removeChild(el); }, href ? 12000 : 6000);
  }
  function friendly(err) {
    var m = String((err && (err.message || (err.data && err.data.message))) || err || '').replace(/\s+/g, ' ');
    if (/user rejected|user denied|4001/i.test(m)) return 'Cancelled in the wallet';
    if (/insufficient funds/i.test(m)) return 'Not enough ETH for this plus gas';
    if (/BelowMinFill/i.test(m)) return 'Below the minimum partial fill the seller set';
    if (/TooMuch/i.test(m)) return 'That is more than what is left in the offer';
    if (/Expired/i.test(m)) return 'This offer has expired';
    if (/NotOpen/i.test(m)) return 'This offer is no longer open';
    if (/NotTaker/i.test(m)) return 'This offer is reserved for another wallet';
    if (/IsPaused/i.test(m)) return 'The OTC desk is paused right now';
    return m.length > 160 ? m.slice(0, 160) + '…' : m || 'Something went wrong';
  }

  /* ── wallet (self-contained, same shape as the bots page) ─────────────── */
  var W = { addr: null };
  var eth = function () { return window.ethereum || null; };
  async function ensureChain() {
    var p = eth(); if (!p) throw new Error('No wallet found. Open nlyra.xyz inside your wallet app, or install MetaMask / Rabby.');
    var cid = await p.request({ method: 'eth_chainId' }); if (cid === CHAIN_HEX) return;
    try { await p.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: CHAIN_HEX }] }); }
    catch (err) {
      if (err && (err.code === 4902 || /unrecognized|not added|4902/i.test(String(err.message || '')))) {
        await p.request({ method: 'wallet_addEthereumChain', params: [{ chainId: CHAIN_HEX, chainName: 'Robinhood Chain', nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 }, rpcUrls: [RPC_PUBLIC], blockExplorerUrls: [EXPLORER] }] });
      } else throw err;
    }
    cid = await p.request({ method: 'eth_chainId' }); if (cid !== CHAIN_HEX) throw new Error('Switch your wallet to Robinhood Chain');
  }
  async function connect(prompt) {
    var p = eth(); if (!p) { if (prompt) toast('No wallet found. Open nlyra.xyz inside your wallet app, or install MetaMask / Rabby.', 'err'); return null; }
    var accts = await p.request({ method: prompt ? 'eth_requestAccounts' : 'eth_accounts' }).catch(function () { return []; });
    if (!accts || !accts[0]) return null;
    W.addr = low(accts[0]);
    await ensureChain().catch(function (e) { if (prompt) toast(String(e.message || e), 'err'); });
    paintWallet(); render(); paintForm();
    return W.addr;
  }
  function paintWallet() {
    var b = q('#oWallet'); if (!b) return;
    if (!W.addr) { b.className = 'o-chip'; b.textContent = 'CONNECT'; return; }
    b.className = 'o-chip on'; b.innerHTML = '<span class="dot"></span>' + esc(short(W.addr));
  }
  async function sendTx(tx) {
    var p = eth(); if (!p) throw new Error('No wallet found');
    var params = { from: W.addr, to: tx.to, data: tx.data };
    if (tx.value && BigInt(tx.value) > 0n) params.value = '0x' + BigInt(tx.value).toString(16);
    return p.request({ method: 'eth_sendTransaction', params: [params] });
  }
  async function waitTx(h, ms) {
    var t0 = Date.now();
    while (Date.now() - t0 < (ms || 90000)) {
      var r = null; try { r = await rpc('eth_getTransactionReceipt', [h]); } catch (_) {}
      if (r) return r; await new Promise(function (s) { setTimeout(s, 700); });
    }
    return null;
  }
  async function allowance(token, owner, spender) { var r = await call(token, SEL.allowance + encA(owner) + encA(spender)); return BigInt(r === '0x' ? 0 : r); }
  async function balanceOf(token, owner) { var r = await call(token, SEL.balanceOf + encA(owner)); return BigInt(r === '0x' ? 0 : r); }

  /* ── token metadata: NERON first, chain as fallback ───────────────────── */
  async function meta(addr) {
    addr = low(addr); if (S.meta[addr]) return S.meta[addr];
    if (addr === ZERO) return (S.meta[addr] = { symbol: 'ETH', name: 'Ether', decimals: 18, priceUsd: S.ethUsd, verdict: 'bluechip', icon: '/desk2/meta/eth.png' });
    var m = { symbol: short(addr), name: '', decimals: 18, priceUsd: 0, verdict: 'unknown', icon: '' };
    try {
      var j = await api('/api/desk/token', { t: addr });
      if (j && j.ok) {
        var t = j.token || {}; m.symbol = t.symbol || m.symbol; m.name = t.name || ''; if (t.decimals != null) m.decimals = Number(t.decimals); m.icon = t.icon || '';
        m.verdict = j.verdict || (j.intel && j.intel.verdict) || 'unknown';
        var best = j.best || (j.pairs && j.pairs[0]) || null; m.priceUsd = best && best.priceUsd ? Number(best.priceUsd) : 0; m.liqUsd = best && best.liqUsd ? Number(best.liqUsd) : 0;
        var sc = j.intel && j.intel.scan; if (sc) { m.buyTax = sc.buyTax; m.sellTax = sc.sellTax; }
      }
    } catch (_) {}
    if (!m.name || m.symbol === short(addr)) {
      try { var dr = await call(addr, SEL.decimals); if (dr && dr !== '0x') m.decimals = Number(BigInt(dr)); } catch (_) {}
      try { var sr = await call(addr, SEL.symbol); if (sr && sr.length > 130) { var len = Number(wU(sr, 1)); var hx = sr.slice(2 + 128, 2 + 128 + len * 2); m.symbol = decodeURIComponent(hx.replace(/(..)/g, '%$1')); } } catch (_) {}
    }
    if (addr === USDG) { m.priceUsd = m.priceUsd || 1; m.verdict = 'bluechip'; m.decimals = 6; m.symbol = 'USDG'; m.name = m.name || 'Global Dollar'; }
    if (addr === WETH) { m.priceUsd = m.priceUsd || S.ethUsd; m.verdict = 'bluechip'; m.decimals = 18; m.symbol = 'WETH'; m.name = 'Wrapped Ether'; }
    return (S.meta[addr] = m);
  }
  var quoteUsd = function (qid) { return qid === 'ETH' ? S.ethUsd : qid === 'USDG' ? 1 : S.nlyraUsd; };
  var quoteOf = function (addr) { addr = low(addr); return addr === ZERO ? QUOTES.ETH : addr === USDG ? QUOTES.USDG : addr === low(NLYRA) ? QUOTES.NLYRA : addr === WETH ? PAYS.WETH : { id: short(addr), addr: addr, dec: 18, sym: short(addr) }; };
  /** a bid: money (USDG / WETH) sits in escrow and a token is asked for it */
  var isBid = function (o) { return !!MONEY[low(o.token)] && !MONEY[low(o.quote)]; };

  /* ── contract reads ───────────────────────────────────────────────────── */
  async function loadOffers() {
    if (!CFG.address) return;
    var cr = await call(CFG.address, SEL.count); var n = Number(BigInt(cr === '0x' ? 0 : cr));
    var out = [];
    var from = Math.max(1, n - 199), want = n - from + 1;
    if (n > 0) {
      var r = await call(CFG.address, SEL.getOffers + encU(from) + encU(want));
      var len = Number(wU(r, 1));
      for (var i = 0; i < len; i++) {
        var b = 2 + i * 11;
        out.push({ id: from + i, seller: wA(r, b), token: wA(r, b + 1), quote: wA(r, b + 2), taker: wA(r, b + 3), amount: wU(r, b + 4), want: wU(r, b + 5), amount0: wU(r, b + 6), want0: wU(r, b + 7), minFill: wU(r, b + 8), expiry: Number(wU(r, b + 9)), status: Number(wU(r, b + 10)) });
      }
    }
    S.offers = out.reverse();
    var toks = {}; out.forEach(function (o) { toks[o.token] = 1; if (o.quote !== ZERO) toks[o.quote] = 1; });
    await Promise.all(Object.keys(toks).map(meta));
  }
  async function loadStats() {
    if (!CFG.address) return;
    try {
      var rs = await Promise.all([call(CFG.address, SEL.feeBps), call(CFG.address, SEL.totalVolume + encA(ZERO)), call(CFG.address, SEL.totalVolume + encA(USDG)), call(CFG.address, SEL.totalVolume + encA(NLYRA)),
        call(CFG.address, SEL.totalFee + encA(ZERO)), call(CFG.address, SEL.totalFee + encA(USDG)), call(CFG.address, SEL.totalFee + encA(NLYRA)), call(CFG.address, SEL.totalNlyraBurned), call(CFG.address, SEL.totalEthToBurner)]);
      var big = function (x) { return BigInt(x === '0x' ? 0 : x); };
      S.feeBps = Number(big(rs[0])); q('#oFeePct').textContent = (S.feeBps / 100).toString();
      var volUsd = toNum(big(rs[1]), 18) * S.ethUsd + toNum(big(rs[2]), 6) + toNum(big(rs[3]), 18) * S.nlyraUsd;
      var feeUsd = toNum(big(rs[4]), 18) * S.ethUsd + toNum(big(rs[5]), 6) + toNum(big(rs[6]), 18) * S.nlyraUsd;
      q('#sVol').textContent = fmtUsd(volUsd);
      q('#sFees').innerHTML = esc(fmtUsd(feeUsd)) + '<small>' + esc(fmtUnits(big(rs[8]), 18, 4)) + ' ETH sent</small>';
      q('#sBurn').innerHTML = esc(fmtUnits(big(rs[7]), 18, 0)) + '<small>direct burns</small>';
    } catch (_) {}
  }
  async function refresh() {
    try { await loadOffers(); } catch (e) { console.warn('offers', e); }
    render(); loadStats();
  }

  /* ── render ───────────────────────────────────────────────────────────── */
  var isOpen = function (o) { return o.status === 0 && o.expiry > Math.floor(Date.now() / 1000) && o.amount > 0n; };
  function render() {
    var now = Math.floor(Date.now() / 1000), me = W.addr;
    var open = S.offers.filter(isOpen), mine = S.offers.filter(function (o) { return me && low(o.seller) === me; }), done = S.offers.filter(function (o) { return !isOpen(o); });
    q('#nOpen').textContent = open.length || ''; q('#nMine').textContent = mine.length || ''; q('#nDone').textContent = done.length || '';
    q('#sOpen').textContent = String(open.length);
    var list = S.tab === 'open' ? open : S.tab === 'mine' ? mine : done;
    var host = q('#oList'); host.innerHTML = list.map(card).join('');
    q('#oEmpty').hidden = list.length > 0;
    q('#oEmpty').textContent = S.tab === 'mine' && !me ? 'Connect a wallet to see your offers.' : S.tab === 'open' ? 'No open offers right now. Be the first: create one on the right.' : 'Nothing here yet.';
    qa('.o-card [data-fill]').forEach(function (b) { b.onclick = function () { fill(Number(b.getAttribute('data-fill'))); }; });
    qa('.o-card [data-cancel]').forEach(function (b) { b.onclick = function () { cancel(Number(b.getAttribute('data-cancel'))); }; });
    qa('.o-card [data-max]').forEach(function (b) { b.onclick = function () { var inp = q('#fi' + b.getAttribute('data-max')); var o = byId(Number(b.getAttribute('data-max'))); if (inp && o) inp.value = groupNum(fmtPlain(o.want, quoteOf(o.quote).dec)); }; });
  }
  var byId = function (id) { for (var i = 0; i < S.offers.length; i++) if (S.offers[i].id === id) return S.offers[i]; return null; };
  function fmtPlain(n, dec) { var s = BigInt(n).toString().padStart(dec + 1, '0'); var ip = s.slice(0, s.length - dec), fp = s.slice(s.length - dec).replace(/0+$/, ''); return ip + (fp ? '.' + fp : ''); }
  function card(o) {
    if (isBid(o)) return bidCard(o);
    var m = S.meta[low(o.token)] || { symbol: short(o.token), name: '', decimals: 18, priceUsd: 0, verdict: 'unknown', icon: '' };
    var Q = quoteOf(o.quote), qUsd = quoteUsd(Q.id);
    var amount = toNum(o.amount, m.decimals), want = toNum(o.want, Q.dec);
    var pxQ = amount > 0 ? want / amount : 0, pxUsd = pxQ * qUsd;
    var vs = m.priceUsd > 0 && pxUsd > 0 ? (pxUsd / m.priceUsd - 1) * 100 : null;
    var mine = W.addr && low(o.seller) === W.addr, open = isOpen(o);
    var filledPct = o.amount0 > 0n ? Number((o.amount0 - o.amount) * 1000n / o.amount0) / 10 : 0;
    var status = o.status === 1 ? 'Filled' : o.status === 2 ? 'Cancelled' : o.expiry <= Math.floor(Date.now() / 1000) ? 'Expired' : 'Open';
    var priv = o.taker !== ZERO;
    return '<div class="o-card' + (mine ? ' mine' : '') + '" data-id="' + o.id + '">' +
      '<div class="hd">' + (m.icon ? '<img class="ic" src="' + esc(m.icon) + '" alt="" loading="lazy" onerror="this.style.visibility=\'hidden\'">' : '<span class="ic"></span>') +
      '<div><div class="sym">' + esc(m.symbol) + ' <small style="font:500 11px var(--mono);color:var(--ink3)">for ' + esc(Q.sym) + '</small></div><div class="nm">' + esc(m.name || short(o.token)) + '</div></div><span class="sp"></span>' +
      (priv ? '<span class="o-badge private" title="Only ' + esc(short(o.taker)) + ' can fill">private</span> ' : '') +
      '<span class="o-badge ' + esc(m.verdict || 'unknown') + '" title="NERON verdict">' + esc(m.verdict || 'unknown') + '</span></div>' +
      '<div class="rows">' +
      '<div class="r"><div class="k">For sale</div><div class="v">' + esc(fmtUnits(o.amount, m.decimals, 2)) + ' <small>' + esc(m.symbol) + '</small></div></div>' +
      '<div class="r"><div class="k">Ask</div><div class="v">' + esc(fmtUnits(o.want, Q.dec, 4)) + ' <small>' + esc(Q.sym) + (qUsd ? ' · ' + esc(fmtUsd(want * qUsd)) : '') + '</small></div></div>' +
      '<div class="r"><div class="k">Price / token</div><div class="v">' + esc(fmtNum(pxQ)) + ' <small>' + esc(Q.sym) + (pxUsd ? ' · ' + esc(fmtUsd(pxUsd)) : '') + '</small></div></div>' +
      '<div class="r"><div class="k">vs pool</div><div class="v ' + (vs == null ? '' : vs <= 0 ? 'up' : 'down') + '">' + (vs == null ? '<small>no pool price</small>' : esc((vs > 0 ? '+' : '') + vs.toFixed(1) + '%') + ' <small>' + (vs <= 0 ? 'below' : 'above') + ' pool</small>') + '</div></div>' +
      '</div>' +
      '<div class="ft"><span class="meta">#' + o.id + ' · ' + esc(status) + (open ? ' · expires in ' + esc(untilStr(o.expiry)) : '') + (filledPct > 0 ? ' · ' + filledPct + '% filled' : '') + (o.minFill > 0n && open ? ' · min ' + esc(fmtUnits(o.minFill, Q.dec, 4)) + ' ' + esc(Q.sym) : '') + ' · seller ' + esc(short(o.seller)) + '</span><span class="sp"></span>' +
      (open && mine ? '<button type="button" class="o-btn danger" data-cancel="' + o.id + '">Cancel · tokens back</button>' : '') +
      (open && !mine && (!priv || low(o.taker) === W.addr) ? '<div class="o-fill"><input id="fi' + o.id + '" inputmode="decimal" placeholder="' + esc(Q.sym) + ' amount" value="' + esc(groupNum(fmtPlain(o.want, Q.dec))) + '"><button type="button" class="o-btn ghost" data-max="' + o.id + '" title="Fill the whole offer">all</button><button type="button" class="o-btn primary" data-fill="' + o.id + '">Buy</button></div>' : '') +
      '</div></div>';
  }

  /** a bid card: someone escrowed money and wants a token — the reader is the seller here */
  function bidCard(o) {
    var pm = S.meta[low(o.token)] || { symbol: short(o.token), decimals: 18, priceUsd: 0 };            // the money in escrow
    var Q = quoteOf(o.quote), qm = S.meta[low(o.quote)] || { symbol: Q.sym, name: '', decimals: Q.dec, priceUsd: 0, verdict: 'unknown', icon: '' };
    var payUsdRate = pm.priceUsd || (low(o.token) === USDG ? 1 : low(o.token) === WETH ? S.ethUsd : 0);
    var pays = toNum(o.amount, pm.decimals), wants = toNum(o.want, Q.dec);
    var pxPay = wants > 0 ? pays / wants : 0, pxUsd = pxPay * payUsdRate;
    var vs = qm.priceUsd > 0 && pxUsd > 0 ? (pxUsd / qm.priceUsd - 1) * 100 : null;
    var mine = W.addr && low(o.seller) === W.addr, open = isOpen(o);
    var filledPct = o.want0 > 0n ? Number((o.want0 - o.want) * 1000n / o.want0) / 10 : 0;
    var status = o.status === 1 ? 'Filled' : o.status === 2 ? 'Cancelled' : o.expiry <= Math.floor(Date.now() / 1000) ? 'Expired' : 'Open';
    var priv = o.taker !== ZERO;
    return '<div class="o-card bid' + (mine ? ' mine' : '') + '" data-id="' + o.id + '">' +
      '<div class="hd">' + (qm.icon ? '<img class="ic" src="' + esc(qm.icon) + '" alt="" loading="lazy" onerror="this.style.visibility=\'hidden\'">' : '<span class="ic"></span>') +
      '<div><div class="sym"><span class="o-badge bidtag">bid</span> ' + esc(qm.symbol || Q.sym) + ' <small style="font:500 11px var(--mono);color:var(--ink3)">wanted · pays ' + esc(pm.symbol) + '</small></div><div class="nm">' + esc(qm.name || short(o.quote)) + '</div></div><span class="sp"></span>' +
      (priv ? '<span class="o-badge private" title="Only ' + esc(short(o.taker)) + ' can fill">private</span> ' : '') +
      '<span class="o-badge ' + esc(qm.verdict || 'unknown') + '" title="NERON verdict for the wanted token">' + esc(qm.verdict || 'unknown') + '</span></div>' +
      '<div class="rows">' +
      '<div class="r"><div class="k">Wants</div><div class="v">' + esc(fmtUnits(o.want, Q.dec, 2)) + ' <small>' + esc(Q.sym) + '</small></div></div>' +
      '<div class="r"><div class="k">Pays</div><div class="v">' + esc(fmtUnits(o.amount, pm.decimals, 4)) + ' <small>' + esc(pm.symbol) + (payUsdRate ? ' · ' + esc(fmtUsd(pays * payUsdRate)) : '') + '</small></div></div>' +
      '<div class="r"><div class="k">Price / ' + esc(Q.sym) + '</div><div class="v">' + esc(fmtNum(pxPay)) + ' <small>' + esc(pm.symbol) + (pxUsd ? ' · ' + esc(fmtUsd(pxUsd)) : '') + '</small></div></div>' +
      '<div class="r"><div class="k">vs pool</div><div class="v ' + (vs == null ? '' : vs >= 0 ? 'up' : 'down') + '">' + (vs == null ? '<small>no pool price</small>' : esc((vs > 0 ? '+' : '') + vs.toFixed(1) + '%') + ' <small>' + (vs >= 0 ? 'above pool · good for sellers' : 'below pool · beats the pool for big sellers') + '</small>') + '</div></div>' +
      '</div>' +
      '<div class="ft"><span class="meta">#' + o.id + ' · ' + esc(status) + (open ? ' · expires in ' + esc(untilStr(o.expiry)) : '') + (filledPct > 0 ? ' · ' + filledPct + '% filled' : '') + (o.minFill > 0n && open ? ' · min ' + esc(fmtUnits(o.minFill, Q.dec, 2)) + ' ' + esc(Q.sym) : '') + ' · bidder ' + esc(short(o.seller)) + '</span><span class="sp"></span>' +
      (open && mine ? '<button type="button" class="o-btn danger" data-cancel="' + o.id + '">Cancel · ' + esc(pm.symbol) + ' back</button>' : '') +
      (open && !mine && (!priv || low(o.taker) === W.addr) ? '<div class="o-fill"><input id="fi' + o.id + '" inputmode="decimal" placeholder="' + esc(Q.sym) + ' to sell" value="' + esc(groupNum(fmtPlain(o.want, Q.dec))) + '"><button type="button" class="o-btn ghost" data-max="' + o.id + '" title="Sell the whole amount wanted">all</button><button type="button" class="o-btn primary" data-fill="' + o.id + '">Sell</button></div>' : '') +
      '</div></div>';
  }

  /* ── fill ─────────────────────────────────────────────────────────────── */
  async function fill(id) {
    var o = byId(id); if (!o || S.busy) return;
    if (!W.addr) { await connect(true); if (!W.addr) return; }
    var Q = quoteOf(o.quote); var inp = q('#fi' + id); var amt = parseUnits(inp ? inp.value : '', Q.dec);
    if (amt == null || amt <= 0n) { toast('Enter how much ' + Q.sym + ' you pay', 'err'); return; }
    if (amt > o.want) { toast('That is more than what is left (' + fmtUnits(o.want, Q.dec, 6) + ' ' + Q.sym + ')', 'err'); return; }
    if (amt < o.minFill && amt !== o.want) { toast('The seller only accepts ' + fmtUnits(o.minFill, Q.dec, 6) + ' ' + Q.sym + ' or more per fill', 'err'); return; }
    var m = S.meta[low(o.token)] || { decimals: 18, symbol: '' };
    var gets = o.amount * amt / o.want;
    S.busy = true;
    try {
      await ensureChain();
      if (Q.addr !== ZERO) {
        var bal = await balanceOf(Q.addr, W.addr); if (bal < amt) throw new Error('You hold ' + fmtUnits(bal, Q.dec, 6) + ' ' + Q.sym + ', the fill needs ' + fmtUnits(amt, Q.dec, 6));
        var al = await allowance(Q.addr, W.addr, CFG.address);
        if (al < amt) {
          toast('Step 1 of 2 — approve exactly ' + fmtUnits(amt, Q.dec, 6) + ' ' + Q.sym, '');
          var ah = await sendTx({ to: Q.addr, data: SEL.approve + encA(CFG.address) + encU(amt), value: '0x0' });
          var ar = await waitTx(ah); if (!ar || ar.status !== '0x1') throw new Error('The approval did not go through');
        }
        toast('Step 2 of 2 — buying ' + fmtUnits(gets, m.decimals, 2) + ' ' + m.symbol + ' for ' + fmtUnits(amt, Q.dec, 6) + ' ' + Q.sym, '');
      } else {
        toast('Buying ' + fmtUnits(gets, m.decimals, 2) + ' ' + m.symbol + ' for ' + fmtUnits(amt, 18, 6) + ' ETH', '');
      }
      var h = await sendTx({ to: CFG.address, data: SEL.fill + encU(id) + encU(Q.addr === ZERO ? 0 : amt), value: Q.addr === ZERO ? amt : 0n });
      toast('Sent · waiting for the block…', '');
      var rc = await waitTx(h);
      if (rc && rc.status === '0x1') toast((isBid(o) ? 'Sold · ' : 'Filled · ') + fmtUnits(gets, m.decimals, 2) + ' ' + m.symbol + ' are in your wallet', 'ok', EXPLORER + '/tx/' + h);
      else toast('The transaction reverted', 'err', EXPLORER + '/tx/' + h);
    } catch (err) { toast(friendly(err), 'err'); }
    S.busy = false; refresh();
  }
  async function cancel(id) {
    var o = byId(id); if (!o || S.busy) return;
    S.busy = true;
    try {
      await ensureChain();
      var h = await sendTx({ to: CFG.address, data: SEL.cancel + encU(id), value: '0x0' });
      toast('Cancelling · waiting for the block…', '');
      var rc = await waitTx(h);
      if (rc && rc.status === '0x1') toast('Cancelled · the tokens are back in your wallet', 'ok', EXPLORER + '/tx/' + h); else toast('The transaction reverted', 'err', EXPLORER + '/tx/' + h);
    } catch (err) { toast(friendly(err), 'err'); }
    S.busy = false; refresh();
  }

  /* ── create form ──────────────────────────────────────────────────────── */
  var F = S.form;
  var isBuy = function () { return F.mode === 'buy'; };
  function paintMode() {
    var buy = isBuy();
    qa('#fMode button').forEach(function (b) { b.setAttribute('aria-pressed', b.getAttribute('data-m') === F.mode ? 'true' : 'false'); });
    q('#fTokenRow').hidden = buy; q('#fPayRow').hidden = !buy; q('#fPriceRow').hidden = buy;
    q('#lQuotes').textContent = buy ? 'I want to buy' : 'Paid in';
    q('#lAmount').textContent = buy ? 'Total I pay (goes into escrow)' : 'Amount to sell';
    q('#lTotal').textContent = buy ? 'Amount I want' : 'Total ask';
    q('#st1t').textContent = buy ? 'Approve exactly what you pay — no blanket allowance' : 'Approve exactly the amount you sell — no blanket allowance';
    q('#st2t').textContent = buy ? 'Create the bid — your payment moves into escrow until someone sells to you' : 'Create the offer — the tokens move into escrow';
    if (buy && F.quote === 'ETH' && false) F.quote = 'NLYRA';
    // the pay asset can never be the wanted asset
    qa('#fPays button').forEach(function (b) { var p = b.getAttribute('data-p'); b.disabled = (p === F.quote); b.setAttribute('aria-pressed', p === F.pay ? 'true' : 'false'); });
    if (buy && F.pay === F.quote) { F.pay = F.quote === 'USDG' ? 'WETH' : 'USDG'; qa('#fPays button').forEach(function (b) { b.setAttribute('aria-pressed', b.getAttribute('data-p') === F.pay ? 'true' : 'false'); }); }
    var wrap = buy && F.pay === 'WETH';
    q('#fPayHint').textContent = buy ? (wrap ? 'You pay in plain ETH. The page wraps it into WETH for the escrow as the first step (1:1, no swap). If you cancel, you get WETH back; unwrap it on the DEX any time.' : '') : '';
    q('#st0').hidden = !wrap;
    q('#st1 .n').textContent = wrap ? '2' : '1'; q('#st2 .n').textContent = wrap ? '3' : '2';
  }
  async function onToken() {
    if (isBuy()) {
      var P = PAYS[F.pay]; var pm = await meta(P.addr); if (!isBuy()) return;
      F.token = { addr: low(P.addr), m: pm };
      q('#fTokBox').hidden = true;
      var wm = await meta(QUOTES[F.quote].addr); if (!isBuy()) return;
      q('#fAmountHint').textContent = W.addr ? '' : '';
      q('#fTotalHint').textContent = wm && wm.priceUsd ? 'pool price ' + fmtUsd(wm.priceUsd) + ' per ' + QUOTES[F.quote].sym : '';
      onAmount(); return;
    }
    var v = q('#fToken').value.trim(); var hint = q('#fTokenHint'), box = q('#fTokBox');
    F.token = null; box.hidden = true;
    if (!v) { hint.className = 'hint'; hint.textContent = 'Paste the contract. NERON checks it and shows the pool price.'; paintForm(); return; }
    if (!isAddr(v)) { hint.className = 'hint bad'; hint.textContent = 'That is not a contract address.'; paintForm(); return; }
    if (low(v) === low(QUOTES[F.quote].addr)) { hint.className = 'hint bad'; hint.textContent = 'You cannot sell the same asset you ask to be paid in.'; paintForm(); return; }
    hint.className = 'hint'; hint.textContent = 'Checking with NERON…';
    var m = await meta(v); if (q('#fToken').value.trim() !== v) return;
    F.token = { addr: low(v), m: m };
    box.hidden = false;
    box.innerHTML = (m.icon ? '<img src="' + esc(m.icon) + '" alt="" onerror="this.style.visibility=\'hidden\'">' : '<span style="width:28px;height:28px;border-radius:50%;background:var(--s3);display:inline-block"></span>') +
      '<div><div class="t1">' + esc(m.symbol) + ' <span class="o-badge ' + esc(m.verdict) + '">' + esc(m.verdict) + '</span></div><div class="t2">' + esc(m.name || short(v)) + ' · ' + (m.priceUsd ? 'pool ' + esc(fmtUsd(m.priceUsd)) : 'no pool price') + (m.liqUsd ? ' · liq ' + esc(fmtUsd(m.liqUsd)) : '') + '</div></div><span class="sp"></span>' +
      (W.addr ? '<button type="button" class="o-btn ghost" id="fMax" style="height:30px">max</button>' : '');
    hint.textContent = (m.buyTax || m.sellTax) ? 'This token charges a transfer tax (' + (m.buyTax || 0) + '% buy / ' + (m.sellTax || 0) + '% sell). The escrow keeps what actually arrives.' : 'Verified by NERON. The pool price is the reference buyers will see next to your ask.';
    if (W.addr) { var b = q('#fMax'); if (b) b.onclick = async function () { var bal = await balanceOf(F.token.addr, W.addr); q('#fAmount').value = fmtPlain(bal, m.decimals); onAmount(); }; }
    if (m.priceUsd && !q('#fPrice').value) { var qU = quoteUsd(F.quote); if (qU) { q('#fPrice').value = fmtPlain(BigInt(Math.round(m.priceUsd / qU * 1e12)), 12); F.lastEdited = 'price'; } }
    onAmount();
  }
  function onAmount() { sync(F.lastEdited); paintForm(); }
  function sync(which) {
    var m = F.token && F.token.m; var Q = QUOTES[F.quote];
    if (isBuy()) {
      var pay = Number(normNum(q('#fAmount').value)), want = Number(normNum(q('#fTotal').value));
      var wm = S.meta[low(Q.addr)] || {}; var payRate = F.pay === 'USDG' ? 1 : F.pay === 'WETH' ? S.ethUsd : S.nlyraUsd;
      var th = q('#fTotalHint'), ah = q('#fAmountHint');
      if (pay > 0 && want > 0) {
        var px = pay / want, pxUsd = px * payRate;
        var vs = wm.priceUsd > 0 && pxUsd > 0 ? (pxUsd / wm.priceUsd - 1) * 100 : null;
        th.className = 'hint ' + (vs == null ? '' : vs >= 0 ? 'good' : 'bad');
        th.textContent = '= ' + groupNum(want) + ' ' + Q.sym + ' · ' + fmtNum(px) + ' ' + PAYS[F.pay].sym + ' per ' + Q.sym + (pxUsd ? ' (' + fmtUsd(pxUsd) + ')' : '') + (vs == null ? '' : ' · ' + (vs > 0 ? '+' : '') + vs.toFixed(1) + '% vs pool' + (vs >= 0 ? ' — sellers will like it' : ' — below pool: worth it for sellers whose size would lose more in the pool'));
        ah.textContent = '= ' + groupNum(pay) + ' ' + PAYS[F.pay].sym + (payRate ? ' ≈ ' + fmtUsd(pay * payRate) + ' in escrow until filled or cancelled' : '');
      } else { th.className = 'hint'; th.textContent = wm.priceUsd ? 'pool price ' + fmtUsd(wm.priceUsd) + ' per ' + Q.sym : ''; ah.textContent = ''; }
      return;
    }
    var amt = Number(normNum(q('#fAmount').value));
    var ah0 = q('#fAmountHint'); ah0.textContent = m && amt > 0 ? '= ' + groupNum(amt) + ' ' + m.symbol + (m.priceUsd ? ' ≈ ' + fmtUsd(amt * m.priceUsd) + ' at pool price' : '') : '';
    if (which === 'price') { var px = Number(normNum(q('#fPrice').value)); if (isFinite(amt) && isFinite(px) && amt > 0 && px > 0) q('#fTotal').value = trimNum(amt * px, Q.dec); }
    else { var tot = Number(normNum(q('#fTotal').value)); if (isFinite(amt) && isFinite(tot) && amt > 0 && tot > 0) q('#fPrice').value = trimNum(tot / amt, 12); }
    var qU = quoteUsd(F.quote); var px2 = Number(normNum(q('#fPrice').value));
    var ph = q('#fPriceHint');
    if (m && m.priceUsd && px2 > 0 && qU) { var vs = (px2 * qU / m.priceUsd - 1) * 100; ph.className = 'hint ' + (vs <= 0 ? 'good' : 'bad'); ph.textContent = fmtUsd(px2 * qU) + ' per token · ' + (vs > 0 ? '+' : '') + vs.toFixed(1) + '% vs pool' + (vs > 0 ? ' (buyers will see this)' : ''); }
    else ph.className = 'hint', ph.textContent = px2 > 0 && qU ? fmtUsd(px2 * qU) + ' per token' : '';
    var tot2 = Number(normNum(q('#fTotal').value)); q('#fTotalHint').textContent = tot2 > 0 && qU ? '= ' + groupNum(tot2) + ' ' + Q.sym + ' ≈ ' + fmtUsd(tot2 * qU) + ' · you receive ' + (100 - S.feeBps / 100) + '% (' + fmtNum(tot2 * (1 - S.feeBps / 10000)) + ' ' + Q.sym + '), ' + (S.feeBps / 100) + '% buys and burns NLYRA' : '';
  }
  function trimNum(v, maxDec) { var s = v.toFixed(Math.min(maxDec, 12)); return s.indexOf('.') >= 0 ? s.replace(/0+$/, '').replace(/\.$/, '') : s; }
  function paintForm() {
    var go = q('#fGo'), sum = q('#fSum'), steps = q('#fSteps');
    if (!CFG.address) { go.disabled = true; go.textContent = 'Contract not live yet'; sum.hidden = true; steps.hidden = true; return; }
    if (!W.addr) { go.disabled = false; go.textContent = 'Connect a wallet'; sum.hidden = true; steps.hidden = true; return; }
    var m = F.token && F.token.m, Q = QUOTES[F.quote];
    var amt = m ? parseUnits(q('#fAmount').value, m.decimals) : null, tot = parseUnits(q('#fTotal').value, Q.dec);
    var okk = m && amt && amt > 0n && tot && tot > 0n && (amt < (1n << 128n)) && (tot < (1n << 128n));
    var taker = q('#fTaker').value.trim(); if (taker && !isAddr(taker)) okk = false;
    go.disabled = !okk || S.busy; go.textContent = S.busy ? 'Working…' : okk ? (isBuy() ? 'Bid ' + fmtUnits(amt, m.decimals, 4) + ' ' + m.symbol + ' for ' + fmtUnits(tot, Q.dec, 2) + ' ' + Q.sym : 'Escrow ' + fmtUnits(amt, m.decimals, 2) + ' ' + m.symbol + ' · ask ' + fmtUnits(tot, Q.dec, 6) + ' ' + Q.sym) : (isBuy() ? 'Fill in the bid' : 'Fill in the offer');
    sum.hidden = !okk; steps.hidden = !okk;
    if (okk) {
      var minPct = Number(q('#fMin').value), minFill = minPct >= 100 ? tot : tot * BigInt(minPct) / 100n;
      var exp = Number(q('#fExp').value);
      var feeBps = S.feeBps;
      sum.innerHTML = (isBuy()
        ? '<div><span>Price per ' + esc(Q.sym) + '</span><b>' + esc(fmtNum(toNum(amt, m.decimals) / toNum(tot, Q.dec))) + ' ' + esc(m.symbol) + '</b></div>' +
          '<div><span>You receive when filled</span><b>' + esc(fmtUnits(tot - tot * BigInt(feeBps) / 10000n, Q.dec, 2)) + ' ' + esc(Q.sym) + ' <small>(' + (feeBps / 100) + '% fee ' + (F.quote === 'NLYRA' ? 'burned' : 'to the burner') + ')</small></b></div>'
        : '<div><span>Price per ' + esc(m.symbol) + '</span><b>' + esc(fmtNum(toNum(tot, Q.dec) / toNum(amt, m.decimals))) + ' ' + esc(Q.sym) + '</b></div>') +
        '<div><span>Partial fills</span><b>' + (minPct >= 100 ? 'no — all or nothing' : minPct === 0 ? 'any size' : 'from ' + esc(fmtUnits(minFill, Q.dec, 6)) + ' ' + esc(Q.sym)) + '</b></div>' +
        '<div><span>Expires</span><b>' + esc(new Date(Date.now() + exp * 1000).toLocaleString('en-GB', { dateStyle: 'medium', timeStyle: 'short' })) + '</b></div>' +
        '<div><span>Buyer</span><b>' + (taker ? esc(short(taker)) + ' only' : 'anyone') + '</b></div>' +
        (isBuy() ? '<div><span>Fee</span><b>' + (S.feeBps / 100) + '% of the ' + esc(Q.sym) + ' you receive → ' + (F.quote === 'NLYRA' ? 'burned' : 'buys and burns NLYRA') + '</b></div>' : '<div><span>Fee (paid from the buyer\'s payment)</span><b>' + (S.feeBps / 100) + '% → burns NLYRA</b></div>');
    }
  }
  async function create(ev) {
    ev.preventDefault(); if (S.busy) return;
    if (!W.addr) { await connect(true); return; }
    var m = F.token && F.token.m, Q = QUOTES[F.quote]; if (!m) return;
    var amt = parseUnits(q('#fAmount').value, m.decimals), tot = parseUnits(q('#fTotal').value, Q.dec);
    if (!amt || amt <= 0n || !tot || tot <= 0n) return;
    var minPct = Number(q('#fMin').value), minFill = minPct >= 100 ? tot : tot * BigInt(minPct) / 100n;
    var expiry = BigInt(Math.floor(Date.now() / 1000) + Number(q('#fExp').value));
    var taker = q('#fTaker').value.trim() || ZERO;
    S.busy = true; paintForm();
    var st0 = q('#st0'), st1 = q('#st1'), st2 = q('#st2'); st0.className = 'o-step'; st1.className = 'o-step'; st2.className = 'o-step';
    var wrapping = isBuy() && F.pay === 'WETH';
    (wrapping ? st0 : st1).className = 'o-step now';
    var stepN = wrapping ? 3 : 2, stepI = 0;
    try {
      await ensureChain();
      var bal = await balanceOf(F.token.addr, W.addr);
      if (wrapping && bal < amt) {
        // wrap only what is missing: ETH -> WETH is a deposit, 1:1, reversible on the DEX
        var need = amt - bal;
        var ethBal = BigInt(await rpc('eth_getBalance', [W.addr, 'latest']));
        if (ethBal < need + 200000000000000n) throw new Error('You hold ' + fmtUnits(ethBal, 18, 5) + ' ETH; wrapping ' + fmtUnits(need, 18, 5) + ' plus gas does not fit');
        stepI++; toast('Step ' + stepI + ' of ' + stepN + ' — wrap ' + fmtUnits(need, 18, 5) + ' ETH into WETH (1:1)', '');
        var wh = await sendTx({ to: WETH, data: '0xd0e30db0', value: need });
        var wr = await waitTx(wh); if (!wr || wr.status !== '0x1') throw new Error('The wrap did not go through');
        st0.className = 'o-step done'; st1.className = 'o-step now';
        bal = await balanceOf(F.token.addr, W.addr);
      }
      if (bal < amt) throw new Error('You hold ' + fmtUnits(bal, m.decimals, 4) + ' ' + m.symbol + ', the ' + (isBuy() ? 'bid' : 'offer') + ' needs ' + fmtUnits(amt, m.decimals, 4));
      var al = await allowance(F.token.addr, W.addr, CFG.address);
      if (al < amt) {
        stepI++; toast('Step ' + stepI + ' of ' + stepN + ' — approve exactly ' + fmtUnits(amt, m.decimals, 4) + ' ' + m.symbol, '');
        var ah = await sendTx({ to: F.token.addr, data: SEL.approve + encA(CFG.address) + encU(amt), value: '0x0' });
        var ar = await waitTx(ah); if (!ar || ar.status !== '0x1') throw new Error('The approval did not go through');
      }
      st1.className = 'o-step done'; st2.className = 'o-step now';
      stepI = stepN; toast('Step ' + stepI + ' of ' + stepN + ' — ' + (isBuy() ? 'creating the bid (your payment moves into escrow)' : 'creating the offer (the tokens move into escrow)'), '');
      var data = SEL.create + encA(F.token.addr) + encU(amt) + encA(Q.addr) + encU(tot) + encU(minFill) + encU(expiry) + encA(taker);
      var h = await sendTx({ to: CFG.address, data: data, value: '0x0' });
      toast('Sent · waiting for the block…', '');
      var rc = await waitTx(h);
      if (rc && rc.status === '0x1') { st2.className = 'o-step done'; toast(isBuy() ? 'Bid is live · sellers see it now' : 'Offer is live · buyers see it now', 'ok', EXPLORER + '/tx/' + h); q('#fAmount').value = ''; q('#fTotal').value = ''; S.tab = 'mine'; qa('.o-tab').forEach(function (t) { t.setAttribute('aria-selected', t.getAttribute('data-tab') === 'mine' ? 'true' : 'false'); }); }
      else toast('The transaction reverted', 'err', EXPLORER + '/tx/' + h);
    } catch (err) { toast(friendly(err), 'err'); st0.className = 'o-step'; st1.className = 'o-step'; st2.className = 'o-step'; }
    S.busy = false; paintForm(); refresh();
  }

  /* ── boot ─────────────────────────────────────────────────────────────── */
  async function boot() {
    paintWallet();
    q('#oWallet').onclick = function () { connect(true); };
    qa('.o-tab').forEach(function (t) { t.onclick = function () { S.tab = t.getAttribute('data-tab'); qa('.o-tab').forEach(function (x) { x.setAttribute('aria-selected', x === t ? 'true' : 'false'); }); render(); }; });
    qa('#fQuotes button').forEach(function (b) { b.onclick = function () { F.quote = b.getAttribute('data-q'); qa('#fQuotes button').forEach(function (x) { x.setAttribute('aria-pressed', x === b ? 'true' : 'false'); }); q('#fPrice').value = ''; q('#fTotal').value = ''; paintMode(); onToken(); }; });
    qa('#fMode button').forEach(function (b) { b.onclick = function () { F.mode = b.getAttribute('data-m'); if (isBuy() && F.quote === 'ETH') { F.quote = 'NLYRA'; qa('#fQuotes button').forEach(function (x) { x.setAttribute('aria-pressed', x.getAttribute('data-q') === 'NLYRA' ? 'true' : 'false'); }); } F.token = null; q('#fAmount').value = ''; q('#fTotal').value = ''; q('#fPrice').value = ''; q('#fAmountHint').textContent = ''; q('#fTotalHint').textContent = ''; paintMode(); onToken(); }; });
    qa('#fPays button').forEach(function (b) { b.onclick = function () { if (b.disabled) return; F.pay = b.getAttribute('data-p'); paintMode(); onToken(); }; });
    paintMode();
    var tT = null; q('#fToken').addEventListener('input', function () { clearTimeout(tT); tT = setTimeout(onToken, 250); });
    q('#fAmount').addEventListener('input', onAmount);
    ['#fAmount', '#fTotal'].forEach(function (s) { q(s).addEventListener('blur', function () { var g = groupNum(q(s).value); if (g != null && q(s).value.trim() !== '') q(s).value = g; }); });
    q('#fPrice').addEventListener('input', function () { F.lastEdited = 'price'; onAmount(); });
    q('#fTotal').addEventListener('input', function () { F.lastEdited = 'total'; onAmount(); });
    ['#fMin', '#fExp', '#fTaker'].forEach(function (s) { q(s).addEventListener('input', paintForm); q(s).addEventListener('change', paintForm); });
    q('#oForm').addEventListener('submit', create);
    try { var c = await fetch('/otc/config.json?v=' + Date.now()).then(function (r) { return r.json(); }); if (c && isAddr(c.address)) CFG = c; } catch (_) {}
    q('#oNotLive').hidden = !!CFG.address;
    if (CFG.address) q('#oContractLink').innerHTML = 'Contract: <a href="' + EXPLORER + '/address/' + esc(CFG.address) + '?tab=contract" target="_blank" rel="noopener">' + esc(short(CFG.address)) + '</a> · verified';
    try { var st = await api('/api/desk/stats'); S.ethUsd = st && st.chain && st.chain.ethUsd ? Number(st.chain.ethUsd) : 0; } catch (_) {}
    try { var nm = await meta(NLYRA); S.nlyraUsd = nm.priceUsd || 0; } catch (_) {}
    paintForm();
    if (eth()) {
      connect(false);
      try { eth().on('accountsChanged', function (a) { W.addr = a && a[0] ? low(a[0]) : null; paintWallet(); render(); paintForm(); }); } catch (_) {}
    }
    await refresh();
    setInterval(refresh, 20000);
    setInterval(render, 30000);
  }
  if (d.readyState === 'loading') d.addEventListener('DOMContentLoaded', boot); else boot();
})();
