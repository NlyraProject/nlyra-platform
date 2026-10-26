#!/usr/bin/env node
'use strict';
// 26/10/2026 · TAKE PROFIT + tokens con IMPUESTO (FOT) en la API de bots reales y el keeper de BSC, sobre un fork de BNB Chain y
// contra los contratos DEPLOYADOS (keeper-tp/: los archivos parchados). Abre FLOKI (0,3 % de tax) por la tx que arma la API,
// mira que la ruta sea la 1 (PancakeRouter) y el pool el pair V2, sube el precio con una ballena y espera que el keeper dispare
// takeProfit (GridStopped kind 4) y que la cabina lo muestre como 'tp'; despues CAKE V3 con take profit: un fillUp primero y el
// take profit despues; PIT (4 %) abre y cierra vendiendo. No toca la red real. Lo corre run/probar-tp.sh (anvil en 8960).
const { ethers } = require('ethers');
const fs = require('fs'), path = require('path'), os = require('os');
const { spawn } = require('child_process');

const ROOT = path.join(__dirname, '..'), KDIR_SRC = path.join(ROOT, '..', 'keeper-tp');
const PORT = Number(process.env.ANVIL_PORT || 8960), URL = 'http://127.0.0.1:' + PORT, KPORT = 8914, APORT = 8915, API = 'http://127.0.0.1:' + APORT + '/api/bsc/real';
const p = new ethers.JsonRpcProvider(URL, ethers.Network.from(56), { staticNetwork: true, pollingInterval: 500 });
const A = JSON.parse(fs.readFileSync(path.join(ROOT, 'deployments', 'bsc-addresses.json'), 'utf8')), O = A.ourContracts;
const WBNB = A.WBNB.toLowerCase(), CAKE = A.CAKE, KEEPER = O.keeper, POOL_CAKE = A.pools.CAKE_WBNB_V3_2500;
const FLOKI = '0xfb5b838b6cfeedc2873ab27866079ac55363d37e', PAIR_FLOKI = '0x231d9e7181e8479a8b40930961e93e7ed798542c';
const PIT = '0xa57ac35ce91ee92caefaa8dc04140c8e232c2e50', PAIR_PIT = '0xfff58a50fdde55f5b5626bb66de476f63155e078';
const Q = 10n ** 18n, AC = ethers.AbiCoder.defaultAbiCoder();
const ROUTE_V3 = (fee) => AC.encode(['uint8', 'bytes'], [0, AC.encode(['uint24'], [fee])]);
const II = new ethers.Interface(JSON.parse(fs.readFileSync(path.join(ROOT, 'artifacts', 'ArchitectInfinityGridV4BSC.abi.json'), 'utf8')));
const PR = new ethers.Interface(['function swapExactETHForTokensSupportingFeeOnTransferTokens(uint256,address[],address,uint256) payable']);
const RT = new ethers.Interface(['function swapETH(address tokenOut, uint256 minAmountOut, uint16 feeBps, address referrer, uint256 deadline, bytes route) payable returns (uint256)']);
const V2 = new ethers.Interface(['function getReserves() view returns (uint112,uint112,uint32)', 'function token0() view returns (address)']);
const KDIR = fs.mkdtempSync(path.join(os.tmpdir(), 'bsctp-')), LOGF = path.join(ROOT, 'run', 'tp-fot-fork.log');
const log = (...a) => console.log(new Date().toISOString().slice(11, 19), ...a);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let fails = 0, oks = 0;
const ok = (name, cond, extra) => { console.log((cond ? ' OK   ' : ' FALLA ') + name + (extra != null ? ' | ' + extra : '')); if (cond) oks++; else fails++; };
const rpc = (m, params) => p.send(m, params);
const fund = (a, bnb) => rpc('anvil_setBalance', [a, ethers.toBeHex(ethers.parseEther(String(bnb)))]);
const fresh = async (bnb) => { const w = ethers.Wallet.createRandom().connect(p); await fund(w.address, bnb); return w; };
async function waitFor(fn, ms) { const t0 = Date.now(); while (Date.now() - t0 < ms) { try { if (await fn()) return true; } catch (_) {} await sleep(1000); } return false; }
const kids = [];
function start(file, env) {
  const c = spawn(process.execPath, [path.join(KDIR_SRC, file)], { env: { ...process.env, NODE_PATH: path.join(ROOT, 'node_modules'), BSC_RPC: URL, BSC_KEEPER_TG: '0', ...env } });
  c.stdout.on('data', (d) => fs.appendFileSync(LOGF, file + ' ' + d)); c.stderr.on('data', (d) => fs.appendFileSync(LOGF, file + ' ERR ' + d));
  kids.push(c); return c;
}
const getJ = async (u) => (await fetch(API + u, { signal: AbortSignal.timeout(40000) })).json();
const postJ = async (u, b) => (await fetch(API + u, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(b), signal: AbortSignal.timeout(40000) })).json();
const kget = async (u) => (await fetch('http://127.0.0.1:' + KPORT + u)).json();
async function sign(w, tx) { const t = await w.sendTransaction({ to: tx.to, data: tx.data, value: BigInt(tx.value), gasLimit: 3_000_000 }); const rc = await t.wait(); if (rc.status !== 1) throw new Error('la tx revirtio'); return rc; }
const idOf = (rc) => rc.logs.map((l) => { try { return II.parseLog(l); } catch (_) { return null; } }).find((e) => e && e.name === 'GridOpened').args.id;
async function send(from, to, data, value) { const h = await rpc('eth_sendTransaction', [{ from, to, data, value: ethers.toBeHex(value || 0n), gas: '0x2dc6c0' }]); await p.waitForTransaction(h); }
async function midV2(pair, token) {
  const [r0, r1] = V2.decodeFunctionResult('getReserves', await rpc('eth_call', [{ to: pair, data: V2.encodeFunctionData('getReserves') }, 'latest']));
  const t0 = V2.decodeFunctionResult('token0', await rpc('eth_call', [{ to: pair, data: V2.encodeFunctionData('token0') }, 'latest']))[0].toLowerCase();
  const rT = BigInt(t0 === token ? r0 : r1), rW = BigInt(t0 === token ? r1 : r0);
  return (rW * Q) / rT;
}
async function midV3() { const s = await p.call({ to: POOL_CAKE, data: '0x3850c7bd' }); const sq = BigInt('0x' + s.slice(2, 66)); return (sq * sq * Q) >> 192n; }
const WHALE = '0x00000000000000000000000000000000000b1a1e';
async function pumpV2(pair, token, pct) {
  const P0 = await midV2(pair, token), target = (P0 * BigInt(pct)) / 100n; let P = P0, n = 0;
  while (P < target && n < 60) { await send(WHALE, A.V2_ROUTER, PR.encodeFunctionData('swapExactETHForTokensSupportingFeeOnTransferTokens', [0n, [WBNB, token], WHALE, Math.floor(Date.now() / 1000) + 600]), ethers.parseEther('100')); P = await midV2(pair, token); n++; }
  return [P0, P, n];
}
async function pumpV3(permil) {
  const P0 = await midV3(), target = (P0 * BigInt(permil)) / 1000n; let P = P0, n = 0;
  while (P < target && n < 150) { await send(WHALE, O.feeRouter, RT.encodeFunctionData('swapETH', [CAKE, 0, 100, ethers.ZeroAddress, BigInt(Math.floor(Date.now() / 1000) + 3600), ROUTE_V3(2500)]), ethers.parseEther('20')); P = await midV3(); n++; }
  return [P0, P, n];
}
const inf = new ethers.Contract(O.infinityGridV4, II, p);
async function waitStopped(id, ms) { return waitFor(async () => Number((await inf.grid(id)).status) === 1, ms); }

(async () => {
  fs.writeFileSync(LOGF, '');
  const FROM = (await p.getBlockNumber()) + 1;
  const maker = await fresh(50);
  await fund(KEEPER, 1); await fund(WHALE, 5_000_000);
  start('bsc-keeper.js', { BSC_KEEPER_FORK: '1', BSC_KEEPER_MODE: 'live', BSC_KEEPER_DIR: KDIR, BSC_KEEPER_PORT: String(KPORT), BSC_KEEPER_TICK_MS: '1500', BSC_INFINITY_FROM: String(FROM) });
  start('bsc-real-api.js', { BSC_REAL_PORT: String(APORT), BSC_KEEPER_API: 'http://127.0.0.1:' + KPORT, BSC_REAL_PUBLIC: '1' });
  ok('API y keeper arriba', await waitFor(async () => (await getJ('/health')).ok, 40000));
  const h = await getJ('/health');
  ok('health anuncia el take profit y el tope de impuesto', Array.isArray(h.takeProfit) && h.taxMaxPct === 5, JSON.stringify(h.takeProfit) + ' tax ' + h.taxMaxPct);

  // ── security check de FLOKI: el impuesto es aviso, no bloqueo
  const sec = await getJ('/security?pool=' + PAIR_FLOKI);
  const taxRow = (sec.checks || []).find((c) => c.k === 'tax');
  ok('security FLOKI: la fila del impuesto es un aviso', sec.ok && taxRow && taxRow.s === 'warn', taxRow && taxRow.val);
  ok('security FLOKI: el veredicto no es fail', sec.verdict !== 'fail', sec.verdict + ' · ' + (sec.checks || []).filter((c) => c.s !== 'pass').map((c) => c.k + ':' + c.s).join(' '));
  ok('security FLOKI: marca taxed y el pool de operacion', sec.taxed === true && sec.tradePool === PAIR_FLOKI, sec.tradePool);

  // ── abrir FLOKI con take profit +10 %
  const base = { maker: maker.address, pool: PAIR_FLOKI, depositBnb: 0.2, stepBps: 300, floorPct: 50, slPct: null, tpPct: 10, gasReserveBnb: 0.005, compound: false };
  ok('tx: take profit fuera de rango se rechaza', /take profit between/.test((await postJ('/tx', { ...base, tpPct: 3 })).error || ''));
  const r = await postJ('/tx', base);
  ok('tx: la API armo la apertura de FLOKI', r.ok && r.preview && r.preview.taxed === true && r.preview.pool === PAIR_FLOKI && r.preview.tpPx > 0, r.ok ? 'tax ' + r.preview.taxPct + '% · tpPx ' + r.preview.tpPx + ' · P0 ' + r.preview.P0 : r.error);
  if (!r.ok) throw new Error('no abre: ' + r.error);
  const b0 = await p.getBalance(maker.address);
  const id = idOf(await sign(maker, r.tx));
  const G = await inf.grid(id);
  ok('abrir: el grid tiene tpPrice arriba de P0', G.tpPrice > G.P0 && G.slPrice === 0n, 'P0 ' + ethers.formatEther(G.P0) + ' tp ' + ethers.formatEther(G.tpPrice));
  ok('keeper: resolvio la ruta 1 y el pair V2', await waitFor(async () => { const k = await kget('/grid?id=' + id); return k.ok && k.grid.status === 'open' && k.grid.pool === PAIR_FLOKI && Number(AC.decode(['uint8', 'bytes'], k.grid.route)[0]) === 1; }, 30000));
  const kg = (await kget('/grid?id=' + id)).grid;
  ok('keeper: conoce el impuesto de FLOKI', kg.taxBps && kg.taxBps.sell > 0, JSON.stringify(kg.taxBps));
  const bot = (await getJ('/bot?id=' + id + '&fresh=1')).bot;
  ok('cabina: tpPct y tpPx', bot && bot.params.tpPct >= 9 && bot.params.tpPct <= 11 && bot.state.tpPx > bot.pnl.priceBnb, bot && ('tpPct ' + bot.params.tpPct + ' tpPx ' + bot.state.tpPx + ' now ' + bot.pnl.priceBnb));
  ok('cabina: el bot abrio sin fallos ni avisos', bot && bot.status === 'open' && !bot.lastError, bot && bot.lastError);

  // ── sube FLOKI 14 % y el keeper tiene que cerrar por take profit
  const [p0, p1, n] = await pumpV2(PAIR_FLOKI, FLOKI, 114);
  log('FLOKI', ethers.formatEther(p0), '->', ethers.formatEther(p1), '(' + n + ' compras de 100 BNB)');
  ok('keeper: cerro FLOKI por take profit', await waitStopped(id, 90000));
  ok('keeper: indexo el cierre', await waitFor(async () => !!(await getJ('/bot?id=' + id + '&fresh=1')).bot.stopMode, 20000));
  const bot2 = (await getJ('/bot?id=' + id + '&fresh=1')).bot;
  // (el precio sube de a saltos de 100 BNB: si un nivel queda cruzado antes de que el objetivo entre, la grilla vende esa rebanada y el take profit cierra en el tick siguiente)
  ok('cabina: cierre tp con su fill, el ultimo', bot2 && bot2.status === 'closed' && bot2.stopMode === 'tp' && bot2.closed && bot2.closed.byTp === true && bot2.fills[bot2.fills.length - 1].kind === 'tp' && bot2.fills.length <= 2, bot2 && (bot2.stopMode + ' fills ' + bot2.fills.map((f) => f.kind || f.side).join(',')));
  const b1 = await p.getBalance(maker.address);
  ok('maker: volvio mas BNB del que puso', b1 > b0, 'delta ' + ethers.formatEther(b1 - b0) + ' BNB (puso 0.2 + 0.005 gas)');
  ok('cabina: P&L positivo', bot2 && bot2.pnl.totalBnb > 0, bot2 && bot2.pnl.totalBnb);

  // ── CAKE V3 con take profit +5 %: primero un fillUp, despues el take profit
  const r2 = await postJ('/tx', { ...base, pool: POOL_CAKE, tpPct: 6, depositBnb: 0.5 });
  ok('tx: CAKE V3 con take profit', r2.ok && r2.preview.taxed === false && r2.preview.pool.toLowerCase() === POOL_CAKE.toLowerCase(), r2.ok ? 'tpPx ' + r2.preview.tpPx : r2.error);
  const id2 = idOf(await sign(maker, r2.tx));
  await waitFor(async () => (await kget('/grid?id=' + id2)).grid.status === 'open', 30000);
  // el nivel 1 (+3 % sobre P0, que ya lleva el 1,25 % de fees) llena con el pool ~6 % arriba; el take profit de +6 % pide ~7,3 %
  let [c0, c1, m] = await pumpV3(1065n);
  log('CAKE', ethers.formatEther(c0), '->', ethers.formatEther(c1), '(' + m + ' swaps)');
  ok('keeper: fillUp de CAKE antes del take profit', await waitFor(async () => Number((await inf.grid(id2)).lastK) === 1, 40000), 'lastK ' + (await inf.grid(id2)).lastK);
  [c0, c1, m] = await pumpV3(1120n);
  log('CAKE', ethers.formatEther(c0), '->', ethers.formatEther(c1), '(' + m + ' swaps)');
  ok('keeper: cerro CAKE por take profit', await waitStopped(id2, 90000));
  ok('keeper: indexo el cierre de CAKE', await waitFor(async () => !!(await getJ('/bot?id=' + id2 + '&fresh=1')).bot.stopMode, 20000));
  const bot3 = (await getJ('/bot?id=' + id2 + '&fresh=1')).bot;
  ok('cabina CAKE: un sell de grilla y el cierre tp', bot3 && bot3.stopMode === 'tp' && bot3.fills.filter((f) => f.side === 'sell' && !f.kind).length >= 1 && bot3.fills.some((f) => f.kind === 'tp'), bot3 && bot3.fills.map((f) => f.kind || f.side).join(','));
  ok('cabina CAKE: tpPct 6 y P&L positivo', bot3 && bot3.params.tpPct === 6 && bot3.pnl.totalBnb > 0, bot3 && ('tpPct ' + bot3.params.tpPct + ' total ' + bot3.pnl.totalBnb));

  // ── PIT (4 % de compra, 3,3 % de venta y 4 % por transferencia: ~11 % por vuelta): demasiado para una grilla, se rechaza
  const secP = await getJ('/security?pool=' + PAIR_PIT);
  const taxP = (secP.checks || []).find((c) => c.k === 'tax');
  ok('security PIT: el impuesto por vuelta pasa el tope y bloquea', secP.ok && secP.verdict === 'fail' && taxP && taxP.s === 'fail', taxP && taxP.val);
  const r3 = await postJ('/tx', { ...base, pool: PAIR_PIT, tpPct: null, depositBnb: 0.05 });
  ok('tx: PIT se rechaza por el security check', !r3.ok && /Security check failed/.test(r3.error || ''), r3.error);

  // ── cerrar vendiendo un token con impuesto: la cotizacion descuenta el impuesto y el minOut entra (FLOKI, nuevo bot sin take profit)
  const r4 = await postJ('/tx', { ...base, tpPct: null, depositBnb: 0.1 });
  ok('tx: FLOKI sin take profit abre', r4.ok, r4.error);
  if (r4.ok) {
    const id4 = idOf(await sign(maker, r4.tx));
    await waitFor(async () => (await kget('/grid?id=' + id4)).grid.status === 'open', 30000);
    const a = await postJ('/action', { id: id4, maker: maker.address, action: 'close', value: 'sell' });
    ok('cerrar FLOKI vendiendo: la API arma la tx', a.ok, a.error);
    if (a.ok) { const rc = await sign(maker, a.tx); const st = rc.logs.map((l) => { try { return II.parseLog(l); } catch (_) { return null; } }).find((e) => e && e.name === 'GridStopped'); ok('cerrar FLOKI vendiendo: vendido en la cadena', st && st.args.proceeds > 0n, st && ethers.formatEther(st.args.proceeds) + ' BNB'); }
  }

  console.log('\n' + oks + ' OK · ' + fails + ' FALLAN');
  for (const k of kids) k.kill();
  process.exit(fails ? 1 : 0);
})().catch((e) => { console.error('FALLA', e.shortMessage || e.message); for (const k of kids) k.kill(); process.exit(1); });
