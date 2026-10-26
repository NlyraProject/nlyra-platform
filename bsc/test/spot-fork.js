#!/usr/bin/env node
'use strict';
// 26/10/2026 · SPOT GRID REAL: keeper + API de ../keeper-spot sobre un fork de BNB Chain, contra el ArchitectSpotGridV4BSC
// DEPLOYADO el 24/10 (0x8a67…37e1, keeper autorizado). Arranca el keeper con los tres contratos y la API con BSC_SPOT, y recorre:
// las validaciones de POST /tx type spotgrid; un bot CAKE/BNB con grids automaticos que nace con seed (las lineas sobre el
// precio), el keeper lo resuelve como spot, vende el nivel mas cercano cuando el precio sube y compra cuando baja, cobra su gas;
// la cabina lo muestra (type spotgridv4, niveles, next sell / next buy); /action: stop loss rechazado, add gas, compound, cerrar
// vendiendo; un bot con take profit que el keeper cierra arriba; uno con stop loss que cierra abajo; el leaderboard real lo
// lista con copy.type spotgrid. No toca la red real. Lo corre run/probar-spot.sh (anvil en 8965).
const { ethers } = require('ethers');
const fs = require('fs'), path = require('path'), os = require('os');
const { spawn } = require('child_process');

const ROOT = path.join(__dirname, '..'), KDIR_SRC = path.join(ROOT, '..', 'keeper-spot');
const PORT = Number(process.env.ANVIL_PORT || 8965), URL = 'http://127.0.0.1:' + PORT, KPORT = 8918, APORT = 8919, API = 'http://127.0.0.1:' + APORT + '/api/bsc/real';
const p = new ethers.JsonRpcProvider(URL, ethers.Network.from(56), { staticNetwork: true, pollingInterval: 500 });
const A = JSON.parse(fs.readFileSync(path.join(ROOT, 'deployments', 'bsc-addresses.json'), 'utf8')), O = A.ourContracts;
const WBNB = A.WBNB, CAKE = A.CAKE, ROUTER = O.feeRouter, KEEPER = O.keeper, SPOT = O.spotGridV4.toLowerCase(), INF41 = O.infinityGridV41.toLowerCase();
const POOL_CW = A.pools.CAKE_WBNB_V3_2500.toLowerCase();
const Q = 10n ** 18n, AC = ethers.AbiCoder.defaultAbiCoder(), E18 = (n) => ethers.parseEther(String(n));
const RT3 = (fee) => AC.encode(['uint8', 'bytes'], [0, AC.encode(['uint24'], [fee])]);
const IS = new ethers.Interface(JSON.parse(fs.readFileSync(path.join(ROOT, 'artifacts', 'ArchitectSpotGridV4BSC.abi.json'), 'utf8')));
const IR = new ethers.Interface(JSON.parse(fs.readFileSync(path.join(ROOT, 'artifacts', 'ArchitectFeeRouterBSC.abi.json'), 'utf8')));
const ERC = new ethers.Interface(['function balanceOf(address) view returns (uint256)', 'function approve(address,uint256) returns (bool)', 'function deposit() payable']);
const V3 = new ethers.Interface(['function slot0() view returns (uint160,int24,uint16,uint16,uint16,uint32,bool)', 'function token0() view returns (address)']);
const KDIR = fs.mkdtempSync(path.join(os.tmpdir(), 'bscspot-')), LOGF = path.join(ROOT, 'run', 'spot-fork.log');
const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let fails = 0, oks = 0;
const ok = (name, cond, extra) => { console.log((cond ? ' OK   ' : ' FALLA ') + name + (extra != null ? ' | ' + extra : '')); if (cond) oks++; else fails++; };
const rpc = (m, params) => p.send(m, params);
const call = (to, data, from) => rpc('eth_call', [from ? { from, to, data } : { to, data }, 'latest']);
const read = async (I, to, fn, args = []) => I.decodeFunctionResult(fn, await call(to, I.encodeFunctionData(fn, args)));
const bal = async (t, a) => BigInt(await call(t, ERC.encodeFunctionData('balanceOf', [a])));
const fund = (a, bnb) => rpc('anvil_setBalance', [a, ethers.toBeHex(E18(bnb))]);
const fresh = async (bnb) => { const w = ethers.Wallet.createRandom().connect(p); await fund(w.address, bnb); return w; };
async function credit(token, holder, amount) {
  for (let slot = 0; slot < 40; slot++) {
    const key = ethers.keccak256(AC.encode(['address', 'uint256'], [holder, slot]));
    const prev = await rpc('eth_getStorageAt', [token, key, 'latest']);
    await rpc('anvil_setStorageAt', [token, key, ethers.toBeHex(amount, 32)]);
    if ((await bal(token, holder)) === amount) return slot;
    await rpc('anvil_setStorageAt', [token, key, prev]);
  }
  throw new Error('slot');
}
async function waitFor(fn, ms) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (_) {} await sleep(1000); } return false; }
const kids = [];
function start(file, env) {
  const c = spawn(process.execPath, [path.join(KDIR_SRC, file)], { env: { ...process.env, NODE_PATH: path.join(ROOT, 'node_modules'), BSC_RPC: URL, BSC_KEEPER_TG: '0', ...env } });
  c.stdout.on('data', (d) => fs.appendFileSync(LOGF, file + ' ' + d)); c.stderr.on('data', (d) => fs.appendFileSync(LOGF, file + ' ERR ' + d));
  kids.push(c); return c;
}
const getJ = async (u) => (await fetch(API + u, { signal: AbortSignal.timeout(60000) })).json();
const postJ = async (u, b) => (await fetch(API + u, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(b), signal: AbortSignal.timeout(60000) })).json();
const kget = async (u) => (await fetch('http://127.0.0.1:' + KPORT + u)).json();
async function sign(w, tx) { const t = await w.sendTransaction({ to: tx.to, data: tx.data, value: BigInt(tx.value || 0), gasLimit: 6_000_000 }); const rc = await t.wait(); if (rc.status !== 1) throw new Error('la tx revirtio'); return rc; }
const idOf = (rc) => rc.logs.map((l) => { try { return IS.parseLog(l); } catch (_) { return null; } }).find((e) => e && e.name === 'GridOpened').args.id;
async function send(from, to, data, value) { const h = await rpc('eth_sendTransaction', [{ from, to, data, value: ethers.toBeHex(value || 0n), gas: '0x5b8d80' }]); for (let i = 0; i < 600; i++) { const rc = await rpc('eth_getTransactionReceipt', [h]); if (rc) return rc; await sleep(200); } throw new Error('sin recibo'); }
async function mid() { const s = await read(V3, POOL_CW, 'slot0'); const sq = BigInt(s[0]); const raw = (sq * sq * Q) >> 192n; const t0 = (await read(V3, POOL_CW, 'token0'))[0].toLowerCase(); return t0 === CAKE.toLowerCase() ? raw : (Q * Q) / raw; }
const WHALE = '0x00000000000000000000000000000000000b1a1e';
const DEADLINE = () => BigInt(Math.floor(Date.now() / 1000) + 30 * 86400);
/** the whale buys CAKE with WBNB until the pool price is at target (permil of the price now), or sells CAKE to push it down */
async function moveTo(permil, chunkIn) {
  const P0 = await mid(), target = (P0 * BigInt(permil)) / 1000n; let P = P0, n = 0;
  while ((permil > 1000 ? P < target : P > target) && n < 120) {
    await send(WHALE, ROUTER, IR.encodeFunctionData('swap', [permil > 1000 ? WBNB : CAKE, permil > 1000 ? CAKE : WBNB, chunkIn, 0n, 100, ethers.ZeroAddress, DEADLINE(), RT3(2500)]));
    P = await mid(); n++;
  }
  return [P0, P, n];
}
const spot = new ethers.Contract(SPOT, IS, p);
const lv = async (id) => (await spot.levels(id)).map((l) => ({ buy: l.buyPrice, sell: l.sellPrice, base: l.base, cost: l.cost, state: Number(l.state) }));

(async () => {
  fs.writeFileSync(LOGF, '');
  await fund(KEEPER, 5); await fund(WHALE, 50_000_000);
  await send(WHALE, WBNB, ERC.encodeFunctionData('deposit', []), E18(20_000_000));
  await credit(CAKE, WHALE, E18(30_000_000));
  await send(WHALE, WBNB, ERC.encodeFunctionData('approve', [ROUTER, ethers.MaxUint256])); await send(WHALE, CAKE, ERC.encodeFunctionData('approve', [ROUTER, ethers.MaxUint256]));
  const FROM = (await p.getBlockNumber()) + 1;
  ok('el Spot Grid deployado acepta al keeper y esta autorizado en el router', (await spot.isKeeper(KEEPER)) && (await read(IR, ROUTER, 'isCaller', [SPOT]))[0] && !(await spot.paused()), SPOT);
  const maker = await fresh(50);
  start('bsc-keeper.js', { BSC_KEEPER_FORK: '1', BSC_KEEPER_MODE: 'live', BSC_KEEPER_DIR: KDIR, BSC_KEEPER_PORT: String(KPORT), BSC_KEEPER_TICK_MS: '1500', BSC_INFINITY_FROM: String(FROM), BSC_INFINITY41: INF41, BSC_INFINITY41_FROM: String(FROM), BSC_SPOT: SPOT, BSC_SPOT_FROM: String(FROM) });
  start('bsc-real-api.js', { BSC_REAL_PORT: String(APORT), BSC_KEEPER_API: 'http://127.0.0.1:' + KPORT, BSC_REAL_PUBLIC: '1', BSC_INFINITY41: INF41, BSC_SPOT: SPOT, BSC_REAL_LB_MIN_S: '1' });
  ok('API y keeper arriba', await waitFor(async () => (await getJ('/health')).ok, 40000));
  const h = await getJ('/health');
  ok('health: spot, sus rangos', h.spot === SPOT && Array.isArray(h.spotGrids) && h.spotGrids[1] === 60 && h.spotLower[1] === 60, JSON.stringify([h.spot, h.spotGrids, h.spotLower, h.spotUpper]));
  const kh = await kget('/health');
  ok('keeper: tres contratos, el tercero spot', Array.isArray(kh.contracts) && kh.contracts.length === 3 && kh.contracts[2].kind === 'spot' && kh.contracts[2].addr === SPOT);

  // ── validaciones de /tx
  const base = { type: 'spotgrid', maker: maker.address, pool: POOL_CW, quote: 'BNB', deposit: 0.3, lowerPct: 15, upperPct: 15, grids: 'auto', slPct: null, tpPct: null, gasReserveBnb: 0.005, compound: true };
  const err = async (over) => (await postJ('/tx', { ...base, ...over })).error || '';
  ok('tx: rango 2 % se rechaza', /range bottom between 5/.test(await err({ lowerPct: 2 })), await err({ lowerPct: 2 }));
  ok('tx: 100 grids se rechaza', /between 2 and 60 grids/.test(await err({ grids: 100 })));
  ok('tx: stop loss adentro del rango se rechaza', /stop loss under the range/.test(await err({ slPct: 10 })), await err({ slPct: 10 }));
  ok('tx: take profit adentro del rango se rechaza', /take profit over the range/.test(await err({ tpPct: 10 })), await err({ tpPct: 10 }));
  const tooMany = await postJ('/tx', { ...base, lowerPct: 5, upperPct: 5, grids: 20 });
  ok('tx: 20 grids en un rango de 10 %: menos de 2,5 % neto, dice el maximo', !tooMany.ok && /under the 2.5 % minimum/.test(tooMany.error) && tooMany.maxGrids >= 1 && tooMany.maxGrids < 20, tooMany.error + ' · max ' + tooMany.maxGrids);
  ok('tx: en USDT se rechaza (el spot es en BNB)', /runs in BNB/.test(await err({ quote: 'USDT' })));
  ok('tx: 0.01 BNB en 30 grids: el gas se come la ganancia (o el nivel es ridiculo)', /work for the keeper|per level/.test(await err({ deposit: 0.01, grids: 30, lowerPct: 60, upperPct: 200 })), await err({ deposit: 0.01, grids: 30, lowerPct: 60, upperPct: 200 }));

  // ── abrir: grids automaticos, con seed
  const r = await postJ('/tx', base);
  ok('tx: la API armo openWithEth en el spot (grids auto, net >= 2.5 %, seed = las lineas sobre el precio)', r.ok && r.contract === SPOT && r.type === 'spotgrid' && r.txs.length === 1 && r.preview.grids >= 2 && r.preview.auto && r.preview.netPct >= 2.5 && r.preview.nSeed > 0 && r.preview.nSeed < r.preview.grids && r.preview.lower < r.preview.price && r.preview.upper > r.preview.price,
    r.ok ? 'grids ' + r.preview.grids + ' · net ' + r.preview.netPct + ' % · gross ' + r.preview.grossPct + ' % · seed ' + r.preview.nSeed + ' · ' + r.preview.lower.toFixed(5) + ' < ' + r.preview.price.toFixed(5) + ' < ' + r.preview.upper.toFixed(5) + ' BNB' : r.error);
  if (!r.ok) throw new Error(r.error);
  const n = r.preview.grids, nSeed = r.preview.nSeed;
  const b0 = await p.getBalance(maker.address);
  const rcO = await sign(maker, r.tx);
  const id = idOf(rcO);
  const G = await spot.grid(id);
  const L0 = await lv(id);
  ok('abrir: grid en la cadena: nLevels, nSeed, gBps >= 250, baseHeld > 0, gasReserve 0.005, los nSeed niveles de arriba en BASE', Number(G.nLevels) === n && Number(G.nSeed) === nSeed && Number(G.gBps) >= 250 && G.baseHeld > 0n && G.gasReserve === E18(0.005) && L0.slice(n - nSeed).every((l) => l.state === 1 && l.base > 0n) && L0.slice(0, n - nSeed).every((l) => l.state === 0),
    'gBps ' + G.gBps + ' · perLevel ' + ethers.formatEther(G.perLevel) + ' · quoteHeld ' + ethers.formatEther(G.quoteHeld) + ' · base ' + ethers.formatEther(G.baseHeld));
  ok('abrir: msg.value == perLevel * n + gas (lo que salio de la wallet, mas el gas de la tx)', b0 - (await p.getBalance(maker.address)) - BigInt(r.tx.value) < E18(0.01), ethers.formatEther(b0 - (await p.getBalance(maker.address))));
  ok('keeper: resolvio el grid como spot (CAKE/BNB en el pool V3 2500)', await waitFor(async () => { const k = await kget('/grid?id=' + id); return k.ok && k.grid.status === 'open' && k.grid.kind === 'spot' && k.grid.c === SPOT && k.grid.pool === POOL_CW; }, 30000), JSON.stringify(((await kget('/grid?id=' + id)).grid || {}).status));
  ok('keeper: conto los niveles (lv: n, base, quote, next sell / next buy)', await waitFor(async () => { const k = await kget('/grid?id=' + id); return k.ok && k.grid.lv && k.grid.lv.n === n && k.grid.lv.base === nSeed && k.grid.lv.nextSell === n - nSeed && k.grid.lv.nextBuy === n - nSeed - 1; }, 20000), JSON.stringify(((await kget('/grid?id=' + id)).grid || {}).lv));
  const bot = (await getJ('/bot?id=' + id + '&fresh=1')).bot;
  ok('cabina: type spotgridv4, grids, niveles, next sell sobre el precio y next buy debajo, rango −15/+15 contra el precio de apertura, P&L', bot && bot.type === 'spotgridv4' && bot.params.grids === n && bot.state.levels.length === n && bot.state.nextSell > bot.pnl.priceBnb && bot.state.nextBuy < bot.pnl.priceBnb && bot.params.lower < bot.params.upper && bot.params.lowerPct === 15 && bot.params.upperPct === 15 && typeof bot.pnl.totalBnb === 'number' && bot.state.armed.sell === nSeed,
    bot && ('next sell ' + bot.state.nextSell.toFixed(5) + ' · now ' + bot.pnl.priceBnb.toFixed(5) + ' · next buy ' + bot.state.nextBuy.toFixed(5) + ' · total ' + bot.pnl.totalBnb.toFixed(5) + ' · step ' + bot.params.stepPct + ' % · rango −' + bot.params.lowerPct + '/+' + bot.params.upperPct));

  // ── el precio sube por encima de la primera venta: fillSell del nivel mas cercano
  const firstSell = bot.state.nextSell, px0 = bot.pnl.priceBnb;
  let [m0, m1, k] = await moveTo(Math.ceil((firstSell / px0) * 1000 * 1.012), E18(1500));
  log('CAKE/BNB', ethers.formatEther(m0), '->', ethers.formatEther(m1), '(' + k + ' compras)');
  ok('keeper: fillSell del nivel ' + (n - nSeed), await waitFor(async () => (await lv(id))[n - nSeed].state === 0, 40000), 'estado ' + (await lv(id))[n - nSeed].state);
  ok('keeper: indexo la venta (fill sell con ganancia, GasPaid)', await waitFor(async () => { const b = (await getJ('/bot?id=' + id + '&fresh=1')).bot; return b && b.fills.length >= 1 && b.fills[0].side === 'sell' && b.fills[0].profit > 0 && b.pnl.realizedBnb > 0; }, 20000));
  const bot2 = (await getJ('/bot?id=' + id + '&fresh=1')).bot;
  ok('cabina: la venta cobro al menos gBps neto del lote y el gas salio de la reserva', bot2 && bot2.fills[0].profit >= bot2.params.perLevelBnb * (bot2.params.gBps / 10000) * 0.999 && bot2.state.gasLeftBnb < 0.005 && bot2.pnl.gasBnb > 0, bot2 && ('profit ' + bot2.fills[0].profit.toFixed(6) + ' BNB · gas left ' + bot2.state.gasLeftBnb));

  // ── el precio baja por debajo de la compra mas cercana: fillBuy (con compound: perLevel + profitFree / n)
  const buyLine = bot2.state.nextBuy, pxNow = bot2.pnl.priceBnb;
  [m0, m1, k] = await moveTo(Math.floor((buyLine / pxNow) * 1000 * 0.988), E18(600_000));
  log('CAKE/BNB', ethers.formatEther(m0), '->', ethers.formatEther(m1), '(' + k + ' ventas)');
  const buyIdx = n - nSeed - 1;
  ok('keeper: fillBuy del nivel ' + buyIdx, await waitFor(async () => (await lv(id))[buyIdx].state === 1, 40000), 'estado ' + (await lv(id))[buyIdx].state);
  const Lb = await lv(id), Gb = await spot.grid(id);
  ok('compound: la compra fue perLevel + boost (Reinvested) y el lote escalo', Lb[buyIdx].cost > Gb.perLevel && (await getJ('/bot?id=' + id + '&fresh=1')).bot.fills.some((f) => f.side === 'buy' && f.boost > 0), 'cost ' + ethers.formatEther(Lb[buyIdx].cost) + ' vs perLevel ' + ethers.formatEther(Gb.perLevel));

  // ── acciones
  const aSl = await postJ('/action', { id, maker: maker.address, action: 'stoploss', value: '30' });
  ok('action stoploss en un spot: rechazado con explicacion', !aSl.ok && /sets its stop loss when it opens/.test(aSl.error), aSl.error);
  const aG = await postJ('/action', { id, maker: maker.address, action: 'addgas', value: '0.002' });
  ok('action addgas: tx al spot', aG.ok && aG.tx.to === SPOT, aG.error);
  if (aG.ok) { await sign(maker, aG.tx); ok('addgas: la reserva crecio', (await spot.grid(id)).gasReserve > Gb.gasReserve); }
  const aC = await postJ('/action', { id, maker: maker.address, action: 'compound', value: 'off' });
  ok('action compound off: tx', aC.ok, aC.error); if (aC.ok) { await sign(maker, aC.tx); ok('compound apagado', (await spot.grid(id)).compound === false); }
  const aX = await postJ('/action', { id, maker: maker.address, action: 'close', value: 'sell' });
  ok('action close (vender): tx al spot', aX.ok && aX.tx.to === SPOT, aX.error);
  const bb = await p.getBalance(maker.address);
  const rcX = await sign(maker, aX.tx);
  const st = rcX.logs.map((l) => { try { return IS.parseLog(l); } catch (_) { return null; } }).find((e) => e && e.name === 'GridStopped');
  ok('cerrar: GridStopped kind 0, BNB de vuelta (proceeds + quote + gas que sobro)', st && Number(st.args.kind) === 0 && st.args.proceeds > 0n && (await p.getBalance(maker.address)) - bb > st.args.proceeds + st.args.quoteReturned - E18(0.001), st && ethers.formatEther(st.args.proceeds + st.args.quoteReturned) + ' BNB');
  ok('cabina: cerrado por el maker, con su resultado', await waitFor(async () => { const b = (await getJ('/bot?id=' + id + '&fresh=1')).bot; return b && b.status === 'closed' && b.stopMode === 'maker' && typeof b.pnl.totalBnb === 'number' && b.closed && b.closed.proceedsBnb > 0; }, 20000));

  // ── take profit: el keeper cierra arriba
  const r2 = await postJ('/tx', { ...base, lowerPct: 10, upperPct: 10, grids: 4, tpPct: 14, compound: false });
  ok('tx: bot con take profit +14 % sobre un rango de +10 %', r2.ok && r2.preview.tpPx > r2.preview.upper, r2.error);
  const id2 = idOf(await sign(maker, r2.tx));
  await waitFor(async () => { const k = await kget('/grid?id=' + id2); return k.ok && k.grid.status === 'open'; }, 30000);
  [m0, m1, k] = await moveTo(1175, E18(2500));
  log('CAKE/BNB', ethers.formatEther(m0), '->', ethers.formatEther(m1), '(' + k + ' compras)');
  ok('keeper: take profit cerro el spot', await waitFor(async () => Number((await spot.grid(id2)).status) === 1, 90000), 'status ' + (await spot.grid(id2)).status);
  ok('cabina: cerrado por take profit, P&L positivo, fill tp', await waitFor(async () => { const b = (await getJ('/bot?id=' + id2 + '&fresh=1')).bot; return b && b.stopMode === 'tp' && b.closed.byTp && b.pnl.totalBnb > 0 && b.fills.some((f) => f.kind === 'tp'); }, 20000), JSON.stringify(((await getJ('/bot?id=' + id2 + '&fresh=1')).bot || {}).pnl || {}).slice(0, 120));

  // ── stop loss: el keeper cierra abajo (hasta 5 % bajo el stop)
  const r3 = await postJ('/tx', { ...base, lowerPct: 8, upperPct: 8, grids: 3, slPct: 12, compound: false });
  ok('tx: bot con stop loss −12 % bajo un rango de −8 %', r3.ok && r3.preview.slPx < r3.preview.lower, r3.error);
  const id3 = idOf(await sign(maker, r3.tx));
  await waitFor(async () => { const kk = await kget('/grid?id=' + id3); return kk.ok && kk.grid.status === 'open'; }, 30000);
  // el stop deja hasta 5 % por debajo: se baja de a poco (1-2 % por swap) hasta 13 % bajo el precio de apertura, no de un saque
  [m0, m1, k] = await moveTo(870, E18(25_000));
  log('CAKE/BNB', ethers.formatEther(m0), '->', ethers.formatEther(m1), '(' + k + ' ventas)');
  ok('keeper: stop loss cerro el spot', await waitFor(async () => Number((await spot.grid(id3)).status) === 1, 90000), 'status ' + (await spot.grid(id3)).status + ' · ' + JSON.stringify(((await kget('/grid?id=' + id3)).grid || {}).lastErr || ''));
  ok('cabina: cerrado por stop loss, fill sl', await waitFor(async () => { const b = (await getJ('/bot?id=' + id3 + '&fresh=1')).bot; return b && b.stopMode === 'sl' && b.closed.bySl && b.fills.some((f) => f.kind === 'sl'); }, 20000));

  // ── leaderboard real: el spot cerrado con ganancia aparece, con su copia
  const lbj = await waitFor(async () => { const j = await getJ('/leaderboard?window=7d&fresh=1'); return j.ok && j.rows.some((x) => x.id === id2 && x.type === 'spotgridv4' && x.copy && x.copy.type === 'spotgrid' && x.copy.grids === 4 && x.copy.tpPct === 14 && x.copy.lowerPct === 10 && x.copy.upperPct === 10); }, 20000);
  ok('leaderboard: el spot con take profit esta, copy.type spotgrid con rango −10/+10, 4 grids y tp 14', lbj, JSON.stringify(((await getJ('/leaderboard?window=7d')).rows || []).map((x) => [x.type, x.copy && x.copy.lowerPct, x.copy && x.copy.upperPct, x.copy && x.copy.grids, x.copy && x.copy.tpPct])));

  console.log('\n' + oks + ' OK · ' + fails + ' FALLAN');
  for (const c of kids) c.kill();
  process.exit(fails ? 1 : 0);
})().catch((e) => { console.error('FALLA', e.shortMessage || e.message); for (const c of kids) c.kill(); process.exit(1); });
