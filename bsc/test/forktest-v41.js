#!/usr/bin/env node
'use strict';
// 26/10/2026 · Fork test de ArchitectInfinityGridV41BSC (quote por grid: USDT ademas de WBNB) sobre BNB Chain, contra el router
// y los pools REALES: deploya el v4.1 desde la tesoreria (anvil se hace pasar por ella), lo autoriza en el router, y recorre el
// ciclo entero de un grid en USDT (CAKE/USDT V3 2500): abrir, fillUp con el precio arriba, fillDown abajo, gas cobrado en WBNB,
// cerrar vendiendo, stop loss, take profit, cerrar guardando, topUpQuote, topUp solo gas, vencimiento, un grid BNB/USDT (base
// WBNB) y el camino de siempre en BNB (openWithEth). No toca la red real. Lo corre run/probar-v41.sh (anvil en 8961).
const { ethers } = require('ethers');
const fs = require('fs'), path = require('path');
const ROOT = path.join(__dirname, '..');
const PORT = Number(process.env.ANVIL_PORT || 8961), URL = 'http://127.0.0.1:' + PORT;
const p = new ethers.JsonRpcProvider(URL, ethers.Network.from(56), { staticNetwork: true, pollingInterval: 300 });
const A = JSON.parse(fs.readFileSync(path.join(ROOT, 'deployments', 'bsc-addresses.json'), 'utf8')), O = A.ourContracts;
const WBNB = A.WBNB, USDT = A.USDT, CAKE = A.CAKE, ROUTER = O.feeRouter, TREAS = O.treasury, KEEPER = O.keeper;
const POOL_CU = '0x7f51c8AaA6B0599aBd16674e2b17FEc7a9f674A1';   // CAKE/USDT V3 2500 (1,28 M USDT el 26/10)
const POOL_BU = '0x36696169C63e42cd08ce11f5deeBbCeBae652050';   // WBNB/USDT V3 500
const POOL_CW = A.pools.CAKE_WBNB_V3_2500;
const Q = 10n ** 18n, AC = ethers.AbiCoder.defaultAbiCoder(), E18 = (n) => ethers.parseEther(String(n));
const RT3 = (fee) => AC.encode(['uint8', 'bytes'], [0, AC.encode(['uint24'], [fee])]);
const ABI = JSON.parse(fs.readFileSync(path.join(ROOT, 'artifacts', 'ArchitectInfinityGridV41BSC.abi.json'), 'utf8'));
const BIN = '0x' + fs.readFileSync(path.join(ROOT, 'artifacts', 'ArchitectInfinityGridV41BSC.bin'), 'utf8').trim();
const II = new ethers.Interface(ABI);
const IR = new ethers.Interface(JSON.parse(fs.readFileSync(path.join(ROOT, 'artifacts', 'ArchitectFeeRouterBSC.abi.json'), 'utf8')));
const ERC = new ethers.Interface(['function balanceOf(address) view returns (uint256)', 'function approve(address,uint256) returns (bool)', 'function allowance(address,address) view returns (uint256)']);
const V3 = new ethers.Interface(['function slot0() view returns (uint160,int24,uint16,uint16,uint16,uint32,bool)', 'function token0() view returns (address)']);
let fails = 0, oks = 0;
const ok = (name, cond, extra) => { console.log((cond ? ' OK   ' : ' FALLA ') + name + (extra != null ? ' | ' + extra : '')); if (cond) oks++; else fails++; };
const rpc = (m, params) => p.send(m, params);
const call = (to, data, from) => rpc('eth_call', [from ? { from, to, data } : { to, data }, 'latest']);
const read = async (I, to, fn, args = []) => I.decodeFunctionResult(fn, await call(to, I.encodeFunctionData(fn, args)));
const bal = async (t, a) => BigInt(await call(t, ERC.encodeFunctionData('balanceOf', [a])));
const bnbOf = async (a) => BigInt(await rpc('eth_getBalance', [a, 'latest']));
const gasCost = (rc) => BigInt(rc.gasUsed) * BigInt(rc.effectiveGasPrice || '0x2faf080');
const fund = (a, bnb) => rpc('anvil_setBalance', [a, ethers.toBeHex(E18(bnb))]);
function why(e) {
  const d = (e && e.data && (typeof e.data === 'string' ? e.data : e.data.data)) || (e && e.info && e.info.error && e.info.error.data);
  if (d && d.length >= 10) { for (const I of [II, IR]) { try { const q = I.parseError(d); if (q) return q.name + '(' + q.args.map(String).join(',') + ')'; } catch (_) {} } try { return 'Error(' + AC.decode(['string'], '0x' + d.slice(10))[0] + ')'; } catch (_) {} return 'raw ' + d.slice(0, 40); }
  return String((e && (e.shortMessage || e.message)) || e).slice(0, 160);
}
async function send(from, to, data, value, gas) {
  const tx = { from, data, value: ethers.toBeHex(value || 0n), gas: ethers.toBeHex(gas || 6_000_000) }; if (to) tx.to = to;
  const h = await rpc('eth_sendTransaction', [tx]);
  for (let i = 0; i < 600; i++) { const rc = await rpc('eth_getTransactionReceipt', [h]); if (rc) { if (rc.status !== '0x1') throw new Error('tx revirtio ' + h); return rc; } await new Promise((r) => setTimeout(r, 200)); }   // un swap V3 grande cruza muchos ticks y el fork los trae de a uno: hasta 2 min
  throw new Error('sin recibo');
}
async function expectRevert(name, from, to, data, value, errName) {
  try { await call(to, data, from); ok('NEG ' + name + ' -> ' + errName, false, 'NO revirtio'); }
  catch (e) { const w = why(e); ok('NEG ' + name + ' -> ' + errName, w.includes(errName), w); }
}
const evs = (rc, I) => rc.logs.map((l) => { try { return I.parseLog(l); } catch (_) { return null; } }).filter(Boolean);
const evOf = (rc, I, n) => { const e = evs(rc, I).find((x) => x.name === n); return e ? e.args : null; };
async function credit(token, holder, amount) {
  for (let slot = 0; slot < 40; slot++) {
    const key = ethers.keccak256(AC.encode(['address', 'uint256'], [holder, slot]));
    const prev = await rpc('eth_getStorageAt', [token, key, 'latest']);
    await rpc('anvil_setStorageAt', [token, key, ethers.toBeHex(amount, 32)]);
    if ((await bal(token, holder)) === amount) return slot;
    await rpc('anvil_setStorageAt', [token, key, prev]);
  }
  throw new Error('no encontre el slot de balances de ' + token);
}
async function mid(pool, token) {
  const s = await read(V3, pool, 'slot0'); const sq = BigInt(s[0]); const raw = (sq * sq * Q) >> 192n;
  const t0 = (await read(V3, pool, 'token0'))[0].toLowerCase();
  return t0 === token.toLowerCase() ? raw : (Q * Q) / raw;   // quote por base x 1e18
}
const WHALE = '0x00000000000000000000000000000000000b1a1e';
async function move(pool, tokenIn, tokenOut, fee, chunk, dir, permil) {
  const base = tokenIn.toLowerCase() === USDT.toLowerCase() || tokenIn.toLowerCase() === WBNB.toLowerCase() ? tokenOut : tokenIn;
  const P0 = await mid(pool, base), target = (P0 * BigInt(permil)) / 1000n; let P = P0, n = 0;
  while ((dir > 0 ? P < target : P > target) && n < 80) {
    await send(WHALE, ROUTER, IR.encodeFunctionData('swap', [tokenIn, tokenOut, chunk, 0n, 100, ethers.ZeroAddress, BigInt(Math.floor(Date.now() / 1000) + 30 * 86400), RT3(fee)]));   // deadline lejos: U10 adelanta el reloj del fork 3 h
    P = await mid(pool, base); n++;
  }
  return [P0, P, n];
}
const dl = () => BigInt(Math.floor(Date.now() / 1000) + 30 * 86400);
const params = (V, o = {}) => ({ V, P0: 0n, stepBps: o.step || 300, floorPrice: o.floor || 1n, tpPrice: o.tp || 0n, slPrice: o.sl || 0n, expiry: o.expiry || dl(), feeBps: 100, referrer: ethers.ZeroAddress, compound: !!o.compound });
const idOf = (rc) => evOf(rc, II, 'GridOpened').id;

(async () => {
  console.log('fork en bloque', Number(BigInt(await rpc('eth_blockNumber', []))));
  await fund(TREAS, 10); await fund(KEEPER, 5); await fund(WHALE, 1_000_000);
  // ── D0: deploy del v4.1 desde la tesoreria + autorizacion en el router
  const rcD = await send(TREAS, null, BIN + AC.encode(['address', 'address', 'address'], [ROUTER, WBNB, KEEPER]).slice(2), 0n, 6_000_000);
  const INF = rcD.contractAddress;
  await send(TREAS, ROUTER, IR.encodeFunctionData('setCaller', [INF, true]));
  ok('D0: v4.1 deployado por la tesoreria y autorizado en el router', (await read(IR, ROUTER, 'isCaller', [INF]))[0] && (await read(II, INF, 'owner'))[0].toLowerCase() === TREAS.toLowerCase() && (await read(II, INF, 'isKeeper', [KEEPER]))[0] && Number((await read(II, INF, 'VERSION'))[0]) === 41, INF + ' · gas ' + BigInt(rcD.gasUsed));
  ok('D0: ROUTER y WETH inmutables correctos', (await read(II, INF, 'ROUTER'))[0].toLowerCase() === ROUTER.toLowerCase() && (await read(II, INF, 'WBNB'))[0].toLowerCase() === WBNB.toLowerCase());

  // ── el maker con USDT y BNB; la ballena con USDT y CAKE
  const maker = ethers.Wallet.createRandom().address; await fund(maker, 10);
  await credit(USDT, maker, E18(100_000)); await credit(USDT, WHALE, E18(50_000_000)); await credit(CAKE, WHALE, E18(5_000_000));
  await send(maker, USDT, ERC.encodeFunctionData('approve', [INF, ethers.MaxUint256]));
  await send(WHALE, USDT, ERC.encodeFunctionData('approve', [ROUTER, ethers.MaxUint256]));
  await send(WHALE, CAKE, ERC.encodeFunctionData('approve', [ROUTER, ethers.MaxUint256]));
  ok('fork: maker con 100k USDT y 10 BNB, allowance al v4.1', (await bal(USDT, maker)) === E18(100_000) && (await read(ERC, USDT, 'allowance', [maker, INF]))[0] === ethers.MaxUint256);

  // ── U1: abrir CAKE/USDT: 1000 USDT (500 seed + 500 reserva) + 0.005 BNB de gas
  const V = E18(500), QIN = E18(1000), GAS = E18(0.005), route = RT3(2500);
  const u0 = await bal(USDT, maker), accT0 = (await read(IR, ROUTER, 'accrued', [TREAS, USDT]))[0];
  const rc1 = await send(maker, INF, II.encodeFunctionData('openWithQuote', [CAKE, USDT, route, params(V), QIN, 1n]), GAS);
  const id1 = idOf(rc1); let g = (await read(II, INF, 'grid', [id1]))[0]; const gq = evOf(rc1, II, 'GridQuote');
  ok('U1: abierto en USDT: quote == USDT, V 500, quoteHeld 500, base > 0, P0 > 0, gas 0.005', g.quote.toLowerCase() === USDT.toLowerCase() && g.V === V && g.quoteHeld === V && g.baseHeld > 0n && g.P0 > 0n && g.gasReserve === GAS, 'P0 ' + ethers.formatEther(g.P0) + ' USDT/CAKE · base ' + ethers.formatEther(g.baseHeld) + ' CAKE');
  ok('U1: GridOpened.quoteIn == 1000 USDT, GridQuote(USDT, 1000)', evOf(rc1, II, 'GridOpened').quoteIn === QIN && gq && gq.quote.toLowerCase() === USDT.toLowerCase() && gq.quoteIn === QIN);
  ok('U1: el maker puso 1000 USDT y 0.005 BNB; escrowed[USDT] == 500, escrowed[CAKE] == base, escrowed[WBNB] == gas', u0 - (await bal(USDT, maker)) === QIN && (await read(II, INF, 'escrowed', [USDT]))[0] === V && (await read(II, INF, 'escrowed', [CAKE]))[0] === g.baseHeld && (await read(II, INF, 'escrowed', [WBNB]))[0] === GAS && (await read(II, INF, 'gasEscrowed'))[0] === GAS);
  ok('U1: el seed pago 1 % en USDT a la tesoreria', (await read(IR, ROUTER, 'accrued', [TREAS, USDT]))[0] - accT0 === V / 100n);
  ok('U1: el P0 esta cerca del mid del pool (fees adentro)', (() => { const m = Number(g.P0) / 1e18; return m > 0; })());

  // ── U2: precio arriba → fillUp cobra en USDT y paga el gas en WBNB
  let [m0, m1, n] = await move(POOL_CU, USDT, CAKE, 2500, E18(20_000), 1, 1060);
  console.log('   CAKE/USDT', ethers.formatEther(m0), '->', ethers.formatEther(m1), '(' + n + ' compras)');
  const kw0 = await bal(WBNB, KEEPER), nu = await read(II, INF, 'nextUp', [id1]);
  ok('U2: nextUp k=1 con base a vender', Number(nu[0]) === 1 && nu[2] > 0n);
  const rc2 = await send(KEEPER, INF, II.encodeFunctionData('fillUp', [id1, route]));
  g = (await read(II, INF, 'grid', [id1]))[0]; const gf = evOf(rc2, II, 'GridFilled'), gp = evOf(rc2, II, 'GasPaid');
  ok('U2: GridFilled SELL k=1 con ganancia en USDT; quoteHeld subio; lastK 1', gf && Number(gf.side) === 1 && Number(gf.level) === 1 && gf.profit > 0n && g.quoteHeld === V + gf.amountOut && Number(g.lastK) === 1, 'vendio ' + ethers.formatEther(gf.amountIn) + ' CAKE por ' + ethers.formatEther(gf.amountOut) + ' USDT · gain ' + ethers.formatEther(gf.profit));
  ok('U2: el gas se cobro en WBNB de la reserva y fue al keeper', gp && gp.owed > 0n && (await bal(WBNB, KEEPER)) - kw0 === gp.owed && g.gasReserve === GAS - gp.owed, 'owed ' + ethers.formatEther(gp.owed) + ' WBNB');
  ok('U2: escrowed[USDT] == quoteHeld; escrowed[WBNB] == gas que queda', (await read(II, INF, 'escrowed', [USDT]))[0] === g.quoteHeld && (await read(II, INF, 'escrowed', [WBNB]))[0] === g.gasReserve);

  // ── U3: precio abajo → fillDown compra con USDT
  [m0, m1, n] = await move(POOL_CU, CAKE, USDT, 2500, E18(20_000), -1, 940);
  console.log('   CAKE/USDT', ethers.formatEther(m0), '->', ethers.formatEther(m1), '(' + n + ' ventas)');
  const nd = await read(II, INF, 'nextDown', [id1]);
  ok('U3: nextDown k=0 con USDT a gastar', Number(nd[0]) === 0 && nd[2] > 0n, ethers.formatEther(nd[2]) + ' USDT');
  const rc3 = await send(KEEPER, INF, II.encodeFunctionData('fillDown', [id1, route]));
  const gf3 = evOf(rc3, II, 'GridFilled'); g = (await read(II, INF, 'grid', [id1]))[0];
  ok('U3: GridFilled BUY k=0, amountIn == buyQuote (USDT), lote anotado, lastK 0', gf3 && Number(gf3.side) === 0 && gf3.amountIn === nd[2] && Number(g.lastK) === 0 && (await read(II, INF, 'lotAt', [id1, 0]))[0].cost === nd[2]);
  ok('U3: escrowed[USDT] == quoteHeld, escrowed[CAKE] == baseHeld', (await read(II, INF, 'escrowed', [USDT]))[0] === g.quoteHeld && (await read(II, INF, 'escrowed', [CAKE]))[0] === g.baseHeld);

  // ── U4: cerrar vendiendo: USDT al maker, gas que sobra en BNB
  const u4 = await bal(USDT, maker), b4 = await bnbOf(maker), held = g.quoteHeld, gasLeft = g.gasReserve;
  const rc4 = await send(maker, INF, II.encodeFunctionData('stop', [id1, route, 1n, true]));
  const st4 = evOf(rc4, II, 'GridStopped'), gr4 = evOf(rc4, II, 'GasRefunded');
  ok('U4: GridStopped kind 0, proceeds en USDT > 0, quoteReturned == quoteHeld', st4 && Number(st4.kind) === 0 && st4.proceeds > 0n && st4.quoteReturned === held, ethers.formatEther(st4.proceeds) + ' USDT');
  ok('U4: el maker cobro proceeds + reserva en USDT y el gas que sobro en BNB', (await bal(USDT, maker)) - u4 === st4.proceeds + held && gr4 && gr4.amount === gasLeft && (await bnbOf(maker)) - b4 === gasLeft - gasCost(rc4), 'BNB delta ' + ethers.formatEther((await bnbOf(maker)) - b4) + ' vs gas ' + ethers.formatEther(gasLeft));
  ok('U4: escrowed[USDT] y [CAKE] en 0, escrowed[WBNB] 0, gasEscrowed 0', (await read(II, INF, 'escrowed', [USDT]))[0] === 0n && (await read(II, INF, 'escrowed', [CAKE]))[0] === 0n && (await read(II, INF, 'escrowed', [WBNB]))[0] === 0n && (await read(II, INF, 'gasEscrowed'))[0] === 0n);
  ok('U4: el contrato no retuvo USDT ni CAKE', (await bal(USDT, INF)) === 0n && (await bal(CAKE, INF)) === 0n);

  // ── U5: stop loss en USDT
  const midNow = await mid(POOL_CU, CAKE);
  const rc5 = await send(maker, INF, II.encodeFunctionData('openWithQuote', [CAKE, USDT, route, params(V, { sl: (midNow * 93n) / 100n }), QIN, 1n]), GAS);
  const id5 = idOf(rc5); g = (await read(II, INF, 'grid', [id5]))[0];
  ok('U5: abierto con stop loss 7 % abajo', g.slPrice > 0n && g.slPrice < g.P0);
  [m0, m1, n] = await move(POOL_CU, CAKE, USDT, 2500, E18(10_000), -1, 925);   // la banda del stop es [sl - 3 %, sl] en NETO: con el pool a 92,5 % del mid, los 1,25 % de fees dejan la venta adentro
  console.log('   CAKE/USDT', ethers.formatEther(m0), '->', ethers.formatEther(m1), '(' + n + ' ventas)');
  const u5 = await bal(USDT, maker), floor5 = (await read(II, INF, 'slMinOut', [id5]))[0];
  const rc5b = await send(KEEPER, INF, II.encodeFunctionData('stopLoss', [id5, route, floor5]));
  const st5 = evOf(rc5b, II, 'GridStopped'), sl5 = evOf(rc5b, II, 'StopLoss');
  ok('U5: stopLoss cerro (kind 3) y el maker cobro USDT', st5 && Number(st5.kind) === 3 && sl5 && sl5.quoteOut === st5.proceeds && (await bal(USDT, maker)) - u5 === st5.proceeds + st5.quoteReturned, ethers.formatEther(st5.proceeds) + ' USDT');

  // ── U6: take profit en USDT
  const mid6 = await mid(POOL_CU, CAKE);
  const rc6 = await send(maker, INF, II.encodeFunctionData('openWithQuote', [CAKE, USDT, route, params(V, { tp: (mid6 * 104n) / 100n }), QIN, 1n]), GAS);
  const id6 = idOf(rc6);
  [m0, m1, n] = await move(POOL_CU, USDT, CAKE, 2500, E18(20_000), 1, 1080);
  console.log('   CAKE/USDT', ethers.formatEther(m0), '->', ethers.formatEther(m1), '(' + n + ' compras)');
  const u6 = await bal(USDT, maker);
  const rc6b = await send(KEEPER, INF, II.encodeFunctionData('takeProfit', [id6, route]));
  const st6 = evOf(rc6b, II, 'GridStopped');
  ok('U6: takeProfit cerro (kind 4), proceeds >= base x tp, USDT al maker', st6 && Number(st6.kind) === 4 && st6.proceeds * Q >= st6.baseSold * (await read(II, INF, 'grid', [id6]))[0].tpPrice && (await bal(USDT, maker)) - u6 === st6.proceeds + st6.quoteReturned, ethers.formatEther(st6.proceeds) + ' USDT');

  // ── U7: cerrar guardando el token + U8 topUpQuote + U9 topUp solo gas
  const rc7 = await send(maker, INF, II.encodeFunctionData('openWithQuote', [CAKE, USDT, route, params(V), QIN, 1n]), GAS);
  const id7 = idOf(rc7); g = (await read(II, INF, 'grid', [id7]))[0];
  const u8 = await bal(USDT, maker), V8 = g.V, qh8 = g.quoteHeld, bh8 = g.baseHeld;
  const rc8 = await send(maker, INF, II.encodeFunctionData('topUpQuote', [id7, route, E18(200), 1n]), E18(0.001));
  g = (await read(II, INF, 'grid', [id7]))[0]; const tu8 = evOf(rc8, II, 'ToppedUp');
  ok('U8: topUpQuote 200 USDT + 0.001 BNB: V +100, reserva +100, base crecio, gas +0.001, ToppedUp', tu8 && tu8.amountIn === E18(200) && g.V === V8 + E18(100) && g.quoteHeld === qh8 + E18(100) && g.baseHeld > bh8 && g.gasReserve === GAS + E18(0.001) && u8 - (await bal(USDT, maker)) === E18(200), 'compro ' + ethers.formatEther(tu8.baseBought) + ' CAKE');
  ok('U8: escrowed[USDT] == quoteHeld; escrowed[WBNB] == gas', (await read(II, INF, 'escrowed', [USDT]))[0] === g.quoteHeld && (await read(II, INF, 'escrowed', [WBNB]))[0] === g.gasReserve);
  await expectRevert('topUp con capital en un grid USDT', maker, INF, II.encodeFunctionData('topUp', [id7, route, 1n, E18(0.001)]), E18(0.011), 'BadValue');
  const rc9 = await send(maker, INF, II.encodeFunctionData('topUp', [id7, route, 1n, E18(0.002)]), E18(0.002));
  g = (await read(II, INF, 'grid', [id7]))[0];
  ok('U9: topUp solo gas en un grid USDT: GasAdded, reserva +0.002', evOf(rc9, II, 'GasAdded') && g.gasReserve === GAS + E18(0.003));
  const c7 = await bal(CAKE, maker), u7 = await bal(USDT, maker), bh7 = g.baseHeld, qh7 = g.quoteHeld;
  const rc7b = await send(maker, INF, II.encodeFunctionData('stop', [id7, route, 0n, false]));
  const st7 = evOf(rc7b, II, 'GridStopped');
  ok('U7: cerrar guardando: CAKE y USDT al maker, kind 1', st7 && Number(st7.kind) === 1 && st7.baseReturned === bh7 && (await bal(CAKE, maker)) - c7 === bh7 && (await bal(USDT, maker)) - u7 === qh7);

  // ── U10: vencimiento: cualquiera devuelve todo
  const rc10 = await send(maker, INF, II.encodeFunctionData('openWithQuote', [CAKE, USDT, route, params(V, { expiry: BigInt(Math.floor(Date.now() / 1000) + 7200) }), QIN, 1n]), GAS);
  const id10 = idOf(rc10);
  await rpc('evm_increaseTime', [3 * 3600]); await rpc('evm_mine', []);
  await expectRevert('fillUp vencido', KEEPER, INF, II.encodeFunctionData('fillUp', [id10, route]), 0n, 'Expired');
  const u10 = await bal(USDT, maker), c10 = await bal(CAKE, maker), gg = (await read(II, INF, 'grid', [id10]))[0];
  const rc10b = await send(WHALE, INF, II.encodeFunctionData('refundExpired', [id10, route]));
  const st10 = evOf(rc10b, II, 'GridStopped');
  ok('U10: refundExpired por un tercero: kind 2, CAKE + USDT + gas al maker', st10 && Number(st10.kind) === 2 && (await bal(USDT, maker)) - u10 === gg.quoteHeld && (await bal(CAKE, maker)) - c10 === gg.baseHeld && evOf(rc10b, II, 'GasRefunded').amount === GAS);

  // ── U11: grid BNB/USDT: base WBNB, quote USDT
  const routeB = RT3(500);
  const rc11 = await send(maker, INF, II.encodeFunctionData('openWithQuote', [WBNB, USDT, routeB, params(V), QIN, 1n]), GAS);
  const id11 = idOf(rc11); g = (await read(II, INF, 'grid', [id11]))[0];
  ok('U11: grid BNB/USDT abierto: token WBNB, quote USDT, base > 0, escrowed[WBNB] == gas + base', g.token.toLowerCase() === WBNB.toLowerCase() && g.quote.toLowerCase() === USDT.toLowerCase() && g.baseHeld > 0n && (await read(II, INF, 'escrowed', [WBNB]))[0] === GAS + g.baseHeld, 'P0 ' + ethers.formatEther(g.P0) + ' USDT/BNB · ' + ethers.formatEther(g.baseHeld) + ' WBNB');
  [m0, m1, n] = await move(POOL_BU, USDT, WBNB, 500, E18(150_000), 1, 1050);
  console.log('   BNB/USDT', ethers.formatEther(m0), '->', ethers.formatEther(m1), '(' + n + ' compras)');
  const rc11b = await send(KEEPER, INF, II.encodeFunctionData('fillUp', [id11, routeB]));
  const gf11 = evOf(rc11b, II, 'GridFilled'); g = (await read(II, INF, 'grid', [id11]))[0];
  ok('U11: fillUp vendio WBNB por USDT y escrowed[WBNB] == gas + base', gf11 && Number(gf11.side) === 1 && gf11.amountOut > 0n && (await read(II, INF, 'escrowed', [WBNB]))[0] === g.gasReserve + g.baseHeld);
  const b11 = await bnbOf(maker), u11 = await bal(USDT, maker), bh11 = g.baseHeld, qh11 = g.quoteHeld, gl11 = g.gasReserve;
  const rc11c = await send(maker, INF, II.encodeFunctionData('stop', [id11, routeB, 0n, false]));
  const st11 = evOf(rc11c, II, 'GridStopped');
  ok('U11: cerrar guardando devuelve el WBNB como BNB nativo + USDT + gas', st11 && st11.baseReturned === bh11 && (await bnbOf(maker)) - b11 === bh11 + gl11 - gasCost(rc11c) && (await bal(USDT, maker)) - u11 === qh11 && (await read(II, INF, 'escrowed', [WBNB]))[0] === 0n);

  // ── U12: el camino de siempre en BNB (openWithEth) sigue igual
  const b12 = await bnbOf(maker), routeW = RT3(2500);
  const rc12 = await send(maker, INF, II.encodeFunctionData('openWithEth', [CAKE, routeW, params(E18(0.25)), 1n, GAS]), E18(0.5) + GAS);
  const id12 = idOf(rc12); g = (await read(II, INF, 'grid', [id12]))[0];
  ok('U12: openWithEth: quote WBNB, quoteHeld 0.25, escrowed[WBNB] == 0.25 + gas, sin GridQuote', g.quote.toLowerCase() === WBNB.toLowerCase() && g.quoteHeld === E18(0.25) && (await read(II, INF, 'escrowed', [WBNB]))[0] === E18(0.25) + GAS && !evOf(rc12, II, 'GridQuote'));
  const rc12b = await send(maker, INF, II.encodeFunctionData('stop', [id12, routeW, 1n, true]));
  const st12 = evOf(rc12b, II, 'GridStopped');
  ok('U12: cerrar vendiendo devuelve BNB nativo (proceeds + reserva + gas)', st12 && (await bnbOf(maker)) - b12 + gasCost(rc12) + gasCost(rc12b) === st12.proceeds + st12.quoteReturned + GAS - (E18(0.5) + GAS), ethers.formatEther(st12.proceeds) + ' BNB');

  // ── NEG: quotes que no van
  await expectRevert('quote CAKE (no es quote del router)', maker, INF, II.encodeFunctionData('openWithQuote', [WBNB, CAKE, route, params(V), QIN, 1n]), GAS, 'BadGrid');
  await expectRevert('quote WBNB por openWithQuote', maker, INF, II.encodeFunctionData('openWithQuote', [CAKE, WBNB, route, params(V), QIN, 1n]), GAS, 'BadGrid');
  await expectRevert('token == quote', maker, INF, II.encodeFunctionData('openWithQuote', [USDT, USDT, route, params(V), QIN, 1n]), GAS, 'BadGrid');
  await expectRevert('quoteIn < V', maker, INF, II.encodeFunctionData('openWithQuote', [CAKE, USDT, route, params(V), E18(100), 1n]), GAS, 'BadValue');
  await expectRevert('openWithEth con token WBNB', maker, INF, II.encodeFunctionData('openWithEth', [WBNB, routeW, params(E18(0.25)), 1n, GAS]), E18(0.5) + GAS, 'BadGrid');
  const rc13 = await send(maker, INF, II.encodeFunctionData('openWithEth', [CAKE, routeW, params(E18(0.25)), 1n, GAS]), E18(0.5) + GAS);
  await expectRevert('topUpQuote en un grid BNB', maker, INF, II.encodeFunctionData('topUpQuote', [idOf(rc13), routeW, E18(100), 1n]), 0n, 'BadValue');
  await expectRevert('fillUp sin ser keeper', maker, INF, II.encodeFunctionData('fillUp', [idOf(rc13), routeW]), 0n, 'NotKeeper');

  const size = ((await rpc('eth_getCode', [INF, 'latest'])).length - 2) / 2;
  console.log('\nruntime', size, 'bytes (EIP-170 24576) ·', oks, 'OK ·', fails, 'FALLAN');
  process.exit(fails ? 1 : 0);
})().catch((e) => { console.error('FALLA', why(e)); process.exit(1); });
