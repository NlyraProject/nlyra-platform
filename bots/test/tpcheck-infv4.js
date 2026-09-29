// Chequeo directo de takeProfit en ArchitectInfinityGridV4 (fork anvil :8902). Corto y sin fuzz:
// abrir con TP, intentar antes de tiempo (revierte), bombear, ejecutar: GridStopped kind 4, gas soft, reserva devuelta.
const fs = require('fs'), path = require('path'), { ethers } = require('ethers');
const DIR = __dirname;
const A = JSON.parse(fs.readFileSync((process.env.DESK_ADDRESSES || require('path').join(__dirname, '../../deployments/desk-addresses.json')), 'utf8'));
const p = new ethers.JsonRpcProvider('http://127.0.0.1:8902', 4663, { staticNetwork: true, batchMaxCount: 1 });
const _est = p.estimateGas.bind(p); p.estimateGas = async (t) => ((await _est(t)) * 3n) / 2n;
const WETH = A.weth || A.WETH, ROUTER = A.feeRouterV2, KEEPER = A.keeper;
const ROUTER_OWNER = '0xa6CD59b326F8bc5Cf68EcD2377Eee13AfBbb1657';
const TOKEN = '0xb9d3824149ad8ac984153ceec91d5a2405d1fb95', POOL = '0x483c24d1e36df01b650f1e9beeb2a1c31c005c39';
const POOL_FEE = 10000, FEE_BPS = 100, Q = 10n ** 18n, E = 10n ** 18n;
const AC = ethers.AbiCoder.defaultAbiCoder();
const ROUTE = AC.encode(['uint8', 'bytes'], [0, AC.encode(['uint24'], [POOL_FEE])]);
const W = (x) => ethers.formatEther(x) + ' ETH';
const log = (...a) => console.log(...a);
const R = [];
const ok = (s, c, e) => { R.push({ s, c: !!c }); log(c ? ' OK  ' : ' XXX ', s, e === undefined ? '' : '| ' + e); };
const erc20 = ['function balanceOf(address) view returns (uint256)', 'function approve(address,uint256) returns (bool)'];
const rpc = (m, ...a) => p.send(m, a);
const expiry = (s) => BigInt(Math.floor(Date.now() / 1000) + (s || 86400));
const pct = (x, n, d) => (x * BigInt(n)) / BigInt(d);
async function asAcct(addr, fn) { await rpc('anvil_impersonateAccount', addr); await rpc('anvil_setBalance', addr, '0x56BC75E2D63100000'); try { return await fn(await p.getSigner(addr)); } finally { await rpc('anvil_stopImpersonatingAccount', addr); } }
async function tx(pr, label) { const t = await pr; const rc = await t.wait(); log('    tx', label, 'gas', rc.gasUsed.toString()); return rc; }
const ROUTER_IF = new ethers.Interface(['error Slippage(uint256,uint256)', 'error NotCaller()']);
async function expectRevert(name, fn, errName, ifaces) {
  try { await fn(); ok('NEG ' + name + ' -> ' + errName, false, 'NO revirtio'); }
  catch (e) { const d = e.data || (e.info && e.info.error && e.info.error.data) || ''; let got = e.shortMessage || e.message; for (const i of ifaces.concat([ROUTER_IF])) { try { const pe = i.parseError(d); if (pe) { got = pe.name + '(' + pe.args.join(',') + ')'; break; } } catch (_) { } } ok('NEG ' + name + ' -> ' + errName, String(got).includes(errName), 'got=' + String(got).slice(0, 90)); }
}
const evOf = (rc, iface, n) => { for (const l of rc.logs) { try { const e = iface.parseLog({ topics: l.topics, data: l.data }); if (e && e.name === n) return e.args; } catch (_) { } } return null; };

(async () => {
  const M = 'test test test test test test test test test test test junk';
  const cand = []; for (let i = 0; i < 10; i++) { const hw = ethers.HDNodeWallet.fromPhrase(M, undefined, "m/44'/60'/0'/0/" + i); const nm = new ethers.NonceManager(new ethers.Wallet(hw.privateKey, p)); nm.address = hw.address; cand.push(nm); }
  const limpia = async (cs) => { for (const c of cs) if ((await p.getCode(c.address)) === '0x') return c; const r = ethers.Wallet.createRandom().connect(p); const nm = new ethers.NonceManager(r); nm.address = r.address; return nm; };
  const w = await limpia(cand), k = await limpia(cand.filter((c) => c.address !== w.address));
  await rpc('anvil_setBalance', w.address, '0x56BC75E2D63100000'); await rpc('anvil_setBalance', k.address, '0x56BC75E2D63100000');
  const abi = JSON.parse(fs.readFileSync(path.join(DIR, 'artifacts', 'ArchitectInfinityGridV4.abi.json'), 'utf8'));
  const bin = '0x' + fs.readFileSync(path.join(DIR, 'artifacts', 'ArchitectInfinityGridV4.bin'), 'utf8');
  const v4 = await (await new ethers.ContractFactory(abi, bin, w).deploy(ROUTER, WETH, KEEPER)).waitForDeployment();
  const V4 = await v4.getAddress(), IF = new ethers.Interface(abi), v4k = v4.connect(k);
  // RAW-2026-09-12: las tx impersonadas (pump/dump) van por eth_sendTransaction crudo y se espera el recibo con
  // tope. El JsonRpcSigner de ethers v6 quedaba esperando para siempre un getTransaction que anvil no devolvia.
  const RI = new ethers.Interface(['function swapETH(address,uint256,uint16,address,uint256,bytes) payable returns (uint256)', 'function swapToETH(address,uint256,uint256,uint16,address,uint256,bytes) returns (uint256)', 'function approve(address,uint256) returns (bool)']);
  async function rawTx(from, to, data, value, label) {
    await rpc('anvil_impersonateAccount', from); await rpc('anvil_setBalance', from, '0x56BC75E2D63100000');
    try {
      const req = { from, to, data, gas: '0x2dc6c0' }; if (value) req.value = ethers.toBeHex(value);
      const h = await rpc('eth_sendTransaction', req);   // rpc() ya envuelve en la lista de params
      for (let i = 0; i < 120; i++) { const rc = await p.getTransactionReceipt(h); if (rc) { log('    tx', label, 'gas', rc.gasUsed.toString(), rc.status === 1 ? '' : '(REVIRTIO)'); if (rc.status !== 1) throw new Error(label + ' revirtio'); return rc; } await new Promise((r) => setTimeout(r, 500)); }
      throw new Error('sin recibo: ' + label);
    } finally { await rpc('anvil_stopImpersonatingAccount', from).catch(() => {}); }
  }
  await rawTx(ROUTER_OWNER, ROUTER, new ethers.Interface(['function setCaller(address,bool)']).encodeFunctionData('setCaller', [V4, true]), 0n, 'router.setCaller');
  await tx(v4.setKeeper(k.address, true), 'setKeeper');
  const weth = new ethers.Contract(WETH, erc20, p);
  const Pnow = async () => { const s = await new ethers.Contract(POOL, ['function slot0() view returns (uint160,int24,uint16,uint16,uint16,uint8,bool)'], p).slot0(); const q2 = BigInt(s[0]); return (Q << 192n) / (q2 * q2); };
  const P = await Pnow();
  const V = E / 50n, RES = E / 25n, GAS = E / 200n;
  const tp = pct(P, 115, 100);
  const base = { V, P0: 0n, stepBps: 300, floorPrice: pct(P, 50, 100), tpPrice: tp, slPrice: 0n, expiry: expiry(), feeBps: FEE_BPS, referrer: ethers.ZeroAddress, compound: true };
  const seedMin = (((V * Q) / P) * 90n) / 100n;
  const rc1 = await tx(v4.openWithEth(TOKEN, ROUTE, base, seedMin, GAS, { value: V + RES + GAS }), 'openWithEth con TP = 1.15 P');
  const id = evOf(rc1, IF, 'GridOpened').id;
  let g = await v4.grid(id);
  ok('abrio con tpPrice, base > 0, reserva 0.005', g.tpPrice === tp && g.baseHeld > 0n && g.gasReserve === GAS);
  await expectRevert('takeProfit antes de que el precio llegue (el pool no paga base * tp)', () => v4k.takeProfit.staticCall(id, ROUTE), 'Slippage', [IF]);
  await expectRevert('takeProfit desde el maker (no es keeper)', () => v4.takeProfit.staticCall(id, ROUTE), 'NotKeeper', [IF]);
  const rc0 = await tx(v4.openWithEth(TOKEN, ROUTE, { ...base, tpPrice: 0n }, seedMin, GAS, { value: V + RES + GAS }), 'openWithEth sin TP');
  await expectRevert('takeProfit sin tpPrice', () => v4k.takeProfit.staticCall(evOf(rc0, IF, 'GridOpened').id, ROUTE), 'BadParams', [IF]);
  await rawTx('0x000000000000000000000000000000000000bEEF', ROUTER, RI.encodeFunctionData('swapETH', [TOKEN, 0, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE]), E * 3n, 'PUMP 3 ETH');
  const P2 = await Pnow();
  ok('el pump dejo el precio por encima del TP', P2 > pct(tp, 105, 100), ethers.formatEther(P2) + ' vs tp ' + ethers.formatEther(tp));
  // el keeper primero haria fillUp; aca se prueba el TP directo (el contrato no exige que los escalones se hayan vendido)
  const kw0 = await weth.balanceOf(k.address), mw0 = await p.getBalance(w.address), ge0 = await v4.gasEscrowed();
  const t0 = Date.now();
  const rcT = await tx(v4k.takeProfit(id, ROUTE), 'keeper takeProfit');
  log('    takeProfit tardo', ((Date.now() - t0) / 1000).toFixed(1), 's');
  const gs = evOf(rcT, IF, 'GridStopped'), gp = evOf(rcT, IF, 'GasPaid'), gr = evOf(rcT, IF, 'GasRefunded');
  g = await v4.grid(id);
  ok('GridStopped kind 4 con toda la base vendida y proceeds >= base * tp', gs && gs.kind === 4n && gs.baseSold > 0n && gs.proceeds * Q >= gs.baseSold * tp, gs ? W(gs.proceeds) : '-');
  ok('GasPaid (soft) al keeper y lo cobro en WETH', gp && gp.owed > 0n && (await weth.balanceOf(k.address)) - kw0 === gp.owed, gp ? W(gp.owed) : '-');
  ok('GasRefunded == reserva - owed, al maker', gr && gr.amount === GAS - gp.owed && gr.maker === w.address, gr ? W(gr.amount) : '-');
  ok('grid Stopped, sin escrow ni reserva; gasEscrowed bajo la reserva entera', g.status === 1n && g.baseHeld === 0n && g.quoteHeld === 0n && g.gasReserve === 0n && (await v4.gasEscrowed()) === ge0 - GAS);
  const bn = rcT.blockNumber;
  ok('el maker cobro el ETH (venta + reserva de compra + gas sobrante), directo o en pendingEth', (await p.getBalance(w.address, bn)) > (await p.getBalance(w.address, bn - 1)) || (await v4.pendingEth(w.address)) > 0n, 'delta ' + W((await p.getBalance(w.address, bn)) - (await p.getBalance(w.address, bn - 1))));
  ok('invariante: escrowed[WETH] == quoteHeld+gas del grid que queda', (await v4.escrowed(WETH)) === (await v4.grid(evOf(rc0, IF, 'GridOpened').id)).quoteHeld + (await v4.grid(evOf(rc0, IF, 'GridOpened').id)).gasReserve);
  const pass = R.filter((r) => r.c).length, fail = R.filter((r) => !r.c).length;
  log('\n==== ' + pass + ' OK · ' + fail + ' FALLAN ====');
  if (fail) process.exit(1);
})().catch((e) => { console.error('ERROR', e); process.exit(2); });
