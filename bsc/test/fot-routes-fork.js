#!/usr/bin/env node
'use strict';
// 26/10/2026 · ¿Por que ruta puede VENDER el contrato un token con impuesto (fee-on-transfer)? Sobre un fork de BNB Chain y
// contra los contratos DEPLOYADOS (router 0x0e86…, Infinity 0xE878…): abre un Infinity Grid de verdad con cada token por
// la ruta 1 (PancakeRouter, swapExactTokensForTokensSupportingFeeOnTransferTokens) y por la ruta 3 (pair directo), y
// despues cierra vendiendo todo (stop sellAll: el mismo _sell que usan fillUp, stopLoss y takeProfit). Tambien vende como
// una persona desde una EOA por el PancakeRouter, de control. No toca la red real. Lo corre run/probar-fot.sh.
const { ethers } = require('ethers');
const fs = require('fs'), path = require('path');
const ROOT = path.join(__dirname, '..');
const PORT = Number(process.env.ANVIL_PORT || 8959), URL = 'http://127.0.0.1:' + PORT;
const p = new ethers.JsonRpcProvider(URL, ethers.Network.from(56), { staticNetwork: true, pollingInterval: 300 });
const A = JSON.parse(fs.readFileSync(path.join(ROOT, 'deployments', 'bsc-addresses.json'), 'utf8')), O = A.ourContracts;
const WBNB = A.WBNB.toLowerCase(), INF = O.infinityGridV4, V2_FACTORY = A.V2_FACTORY, V2_ROUTER = A.V2_ROUTER;
const AC = ethers.AbiCoder.defaultAbiCoder();
const ROUTE = { v2: (path_) => AC.encode(['uint8', 'bytes'], [1, AC.encode(['address[]'], [path_])]), v2d: (pair) => AC.encode(['uint8', 'bytes'], [3, AC.encode(['address', 'uint256'], [pair, 9975])]) };
const II = new ethers.Interface(JSON.parse(fs.readFileSync(path.join(ROOT, 'artifacts', 'ArchitectInfinityGridV4BSC.abi.json'), 'utf8')));
const RI = new ethers.Interface(JSON.parse(fs.readFileSync(path.join(ROOT, 'artifacts', 'ArchitectFeeRouterBSC.abi.json'), 'utf8')));
const ERC = new ethers.Interface(['function balanceOf(address) view returns (uint256)', 'function approve(address,uint256) returns (bool)', 'function symbol() view returns (string)', 'function decimals() view returns (uint8)']);
const FACT = new ethers.Interface(['function getPair(address,address) view returns (address)']);
const PR = new ethers.Interface(['function getAmountsOut(uint256,address[]) view returns (uint256[])', 'function swapExactETHForTokensSupportingFeeOnTransferTokens(uint256,address[],address,uint256) payable', 'function swapExactTokensForETHSupportingFeeOnTransferTokens(uint256,uint256,address[],address,uint256)']);
const TOKENS = [
  ['FLOKI', '0xfb5b838b6cfeedc2873ab27866079ac55363d37e'],
  ['PIT', '0xa57ac35ce91ee92caefaa8dc04140c8e232c2e50'],
  ['CAKE', A.CAKE],
];
const rpc = (m, params) => p.send(m, params);
const call = (to, data, from, value) => rpc('eth_call', [Object.assign({ to, data }, from ? { from } : {}, value ? { value: ethers.toBeHex(value) } : {}), 'latest']);
async function read(iface, to, fn, args = []) { return iface.decodeFunctionResult(fn, await call(to, iface.encodeFunctionData(fn, args))); }
function why(e) {
  const d = e && e.data && (typeof e.data === 'string' ? e.data : e.data.data) || (e && e.info && e.info.error && e.info.error.data);
  if (d && d.length >= 10) {
    for (const I of [II, RI]) { try { const q = I.parseError(d); if (q) return q.name + '(' + q.args.map(String).join(',') + ')'; } catch (_) {} }
    try { return 'Error(' + AC.decode(['string'], '0x' + d.slice(10))[0] + ')'; } catch (_) {}
    return 'raw ' + d.slice(0, 80);
  }
  return String((e && (e.shortMessage || e.message)) || e).slice(0, 160);
}
async function send(from, to, data, value, gas) {
  const h = await rpc('eth_sendTransaction', [{ from, to, data, value: ethers.toBeHex(value || 0n), gas: ethers.toBeHex(gas || 1_500_000) }]);
  for (let i = 0; i < 50; i++) { const rc = await rpc('eth_getTransactionReceipt', [h]); if (rc) return rc; await new Promise((r) => setTimeout(r, 200)); }
  throw new Error('sin recibo');
}
const fund = (a, bnb) => rpc('anvil_setBalance', [a, ethers.toBeHex(ethers.parseEther(String(bnb)))]);
const fmt = (w) => Number(ethers.formatEther(w)).toFixed(6);
const out = [];
const say = (...a) => { console.log(...a); out.push(a.join(' ')); };

async function openAndSell(name, token, route, label) {
  const maker = ethers.Wallet.createRandom().address;
  await fund(maker, 1);
  const dep = ethers.parseEther('0.05'), V = dep / 2n, gas = ethers.parseEther('0.003');
  const params = { V, P0: 0n, stepBps: 500, floorPrice: 1n, tpPrice: 0n, slPrice: 0n, expiry: BigInt(Math.floor(Date.now() / 1000) + 86400), feeBps: 100, referrer: ethers.ZeroAddress, compound: false };
  const data = II.encodeFunctionData('openWithEth', [token, route, params, 1n, gas]);
  let id;
  try { await call(INF, data, maker, dep + gas); } catch (e) { say(' ', name, label, 'ABRIR revierte:', why(e)); return; }
  const rc = await send(maker, INF, data, dep + gas);
  if (rc.status !== '0x1') { say(' ', name, label, 'ABRIR revirtio en la tx'); return; }
  const lg = rc.logs.map((l) => { try { return II.parseLog(l); } catch (_) { return null; } }).filter(Boolean).find((e) => e.name === 'GridOpened');
  id = lg.args.id;
  const G = (await read(II, INF, 'grid', [id]))[0];
  const dec = Number((await read(ERC, token, 'decimals'))[0]);
  say(' ', name, label, 'abierto · seed', fmt(V), 'BNB → baseHeld', ethers.formatUnits(G.baseHeld, dec), name, '· P0', ethers.formatUnits(G.P0, 18));
  // venta de todo: stop(sellAll) con minOut 1, desde el maker (mismo _sell que fillUp / stopLoss / takeProfit)
  const sd = II.encodeFunctionData('stop', [id, route, 1n, true]);
  try { await call(INF, sd, maker); } catch (e) { say(' ', name, label, 'VENDER revierte:', why(e)); return; }
  const b0 = BigInt(await rpc('eth_getBalance', [maker, 'latest']));
  const rc2 = await send(maker, INF, sd, 0n);
  const b1 = BigInt(await rpc('eth_getBalance', [maker, 'latest']));
  const st = rc2.logs.map((l) => { try { return II.parseLog(l); } catch (_) { return null; } }).filter(Boolean).find((e) => e.name === 'GridStopped');
  say(' ', name, label, rc2.status === '0x1' ? 'VENDIDO' : 'VENTA REVIRTIO', '· proceeds', st ? fmt(st.args.proceeds) : '?', 'BNB · al maker volvieron', fmt(b1 - b0), 'BNB (de', fmt(dep), 'puestos; gas', fmt(gas) + ')');
}

(async () => {
  say('fork en bloque', Number(BigInt(await rpc('eth_blockNumber', []))));
  for (const [name, token] of TOKENS) {
    const [pair] = await read(FACT, V2_FACTORY, 'getPair', [token, WBNB]);
    const pairBal = BigInt(await call(WBNB, ERC.encodeFunctionData('balanceOf', [pair])));
    say('\n==', name, token, '· pair V2', pair, '· WBNB en el pair', fmt(pairBal));
    // control: una persona compra y vende por el PancakeRouter (FoT)
    const w = ethers.Wallet.createRandom().address; await fund(w, 1);
    try {
      const amt = ethers.parseEther('0.02');
      const q = await read(PR, V2_ROUTER, 'getAmountsOut', [amt, [WBNB, token]]);
      await send(w, V2_ROUTER, PR.encodeFunctionData('swapExactETHForTokensSupportingFeeOnTransferTokens', [0n, [WBNB, token], w, Math.floor(Date.now() / 1000) + 600]), amt);
      const got = BigInt(await call(token, ERC.encodeFunctionData('balanceOf', [w])));
      const tax = Number((q[0][1] - got) * 10000n / q[0][1]) / 100;
      await send(w, token, ERC.encodeFunctionData('approve', [V2_ROUTER, got]));
      const sd = PR.encodeFunctionData('swapExactTokensForETHSupportingFeeOnTransferTokens', [got, 0n, [token, WBNB], w, Math.floor(Date.now() / 1000) + 600]);
      let ok = true; try { await call(V2_ROUTER, sd, w); } catch (e) { ok = false; say('  EOA por PancakeRouter: la venta revierte:', why(e)); }
      if (ok) { const b0 = BigInt(await rpc('eth_getBalance', [w, 'latest'])); const rc = await send(w, V2_ROUTER, sd); const b1 = BigInt(await rpc('eth_getBalance', [w, 'latest'])); say('  EOA por PancakeRouter: compra con tax ~' + tax + '% · venta', rc.status === '0x1' ? 'OK' : 'REVIRTIO', '· volvieron', fmt(b1 - b0), 'BNB de', fmt(amt)); }
    } catch (e) { say('  EOA control fallo:', why(e)); }
    await openAndSell(name, token, ROUTE.v2([WBNB, token]), 'ruta 1 (PancakeRouter FoT)');
    await openAndSell(name, token, ROUTE.v2d(pair), 'ruta 3 (pair directo)');
  }
  fs.writeFileSync(path.join(ROOT, 'run', 'fot-routes.log'), out.join('\n') + '\n');
  console.log('\nescrito run/fot-routes.log');
})().catch((e) => { console.error('FALLA', why(e)); process.exit(1); });
