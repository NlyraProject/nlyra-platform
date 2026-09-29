// Chequeo directo de stopLoss (gas soft + reserva devuelta) con bajada FINA hasta la ventana [SL-3%, SL] en ArchitectInfinityGridV4 (fork anvil :8902). Corto y sin fuzz:
// bombear primero, abrir con SL al 80 % del ancla, bajar de a poco hasta la ventana, ejecutar: GridStopped kind 3, StopLoss, gas soft, refund.
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
  const tok = new ethers.Contract(TOKEN, erc20, p);
  const beef = '0x000000000000000000000000000000000000bEEF';
  // 1) bombear ANTES de abrir: el ancla queda arriba y la bolsa de bEEF alcanza para bajar despues
  await rawTx(beef, ROUTER, RI.encodeFunctionData('swapETH', [TOKEN, 0, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE]), E * 3n, 'PUMP 3 ETH');
  const P = await Pnow();
  const V = E / 50n, RES = E / 25n;
  const seedMin = (((V * Q) / P) * 90n) / 100n;
  const slp = pct(P, 80, 100);
  const base = { V, P0: 0n, stepBps: 300, floorPrice: pct(P, 40, 100), tpPrice: 0n, slPrice: slp, expiry: expiry(), feeBps: FEE_BPS, referrer: ethers.ZeroAddress, compound: false };
  const rc1 = await tx(v4.openWithEth(TOKEN, ROUTE, base, seedMin, 12345n, { value: V + RES + 12345n }), 'openWithEth SL=80 %, reserva 12345 wei');
  const id = evOf(rc1, IF, 'GridOpened').id;
  let g = await v4.grid(id);
  ok('abrio con slPrice y 12345 wei de reserva', g.slPrice === slp && g.gasReserve === 12345n && g.baseHeld > 0n);
  await expectRevert('stopLoss con el precio por encima del SL', () => v4k.stopLoss.staticCall(id, ROUTE, 0), 'PriceNotReached', [IF]);
  // 2) bajar de a poco y preguntarle AL CONTRATO (staticCall de stopLoss) si ya esta en la ventana:
  //    PriceNotReached(got, want) = todavia arriba (got/want dice cuanto); Slippage = se paso por debajo del piso.
  let enVentana = false, pasos = 0, cerca = false, razon = '';
  for (let i = 0; i < 160; i++) {
    const bal = await tok.balanceOf(beef); if (bal === 0n) { razon = 'bolsa vacia'; break; }
    const c = bal / (cerca ? 80n : 20n) || bal;
    await rawTx(beef, TOKEN, RI.encodeFunctionData('approve', [ROUTER, c]), 0n, 'approve');
    await rawTx(beef, ROUTER, RI.encodeFunctionData('swapToETH', [TOKEN, c, 0, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE]), 0n, cerca ? 'dump 1/80' : 'dump 1/20');
    pasos++;
    try { await v4k.stopLoss.staticCall(id, ROUTE, 0); enVentana = true; log('    en ventana tras', pasos, 'pasos'); break; }
    catch (e) {
      const d = e.data || (e.info && e.info.error && e.info.error.data) || '';
      let pe = null; try { pe = IF.parseError(d); } catch (_) { try { pe = ROUTER_IF.parseError(d); } catch (__) { pe = null; } }
      if (pe && pe.name === 'PriceNotReached') { const got = BigInt(pe.args[0]), want = BigInt(pe.args[1]); cerca = got * 100n < want * 110n; if (pasos % 10 === 0) log('    paso', pasos, 'todavia arriba:', ((Number(got) / Number(want)) * 100).toFixed(1) + '% del SL'); continue; }
      razon = pe ? pe.name : String(e.shortMessage || e.message).slice(0, 80);
      log('    corte en el paso', pasos, ':', razon); break;
    }
  }
  if (!enVentana) { ok('SL: llegar a la ventana [0.97 SL, SL] bajando de a poco', false, 'no se llego en ' + pasos + ' pasos: ' + razon); }
  else {
    const kw0 = await weth.balanceOf(k.address), ge0 = await v4.gasEscrowed();
    const rcS = await tx(v4k.stopLoss(id, ROUTE, 0), 'keeper stopLoss con 12345 wei de reserva');
    const gs = evOf(rcS, IF, 'GridStopped'), gp = evOf(rcS, IF, 'GasPaid'), gr = evOf(rcS, IF, 'GasRefunded'), se = evOf(rcS, IF, 'StopLoss');
    g = await v4.grid(id);
    ok('SL: GridStopped kind 3 + evento StopLoss, toda la base vendida', gs && gs.kind === 3n && se && se.baseSold === gs.baseSold && gs.baseSold > 0n, gs ? W(gs.proceeds) : '-');
    ok('SL: proceeds entre 97 % y 100 % de base*sl (la venta prueba el precio)', gs && gs.proceeds * Q <= gs.baseSold * slp && gs.proceeds * Q >= (gs.baseSold * slp * 9700n) / 10000n);
    ok('SL: gas soft: cobro EXACTAMENTE la reserva (12345 wei), remaining 0, y lo recibio el keeper', gp && gp.owed === 12345n && gp.remaining === 0n && (await weth.balanceOf(k.address)) - kw0 === 12345n);
    ok('SL: sin GasRefunded (no sobro), gasReserve 0, gasEscrowed bajo 12345', !gr && g.gasReserve === 0n && (await v4.gasEscrowed()) === ge0 - 12345n);
    ok('SL: grid Stopped y sin escrow', g.status === 1n && g.baseHeld === 0n && g.quoteHeld === 0n);
    const bn = rcS.blockNumber;
    ok('SL: el maker cobro el ETH (directo o pendingEth)', (await p.getBalance(w.address, bn)) > (await p.getBalance(w.address, bn - 1)) || (await v4.pendingEth(w.address)) > 0n);
    await expectRevert('stopLoss de nuevo sobre el grid cerrado', () => v4k.stopLoss.staticCall(id, ROUTE, 0), 'NotOpen', [IF]);
  }
  const pass = R.filter((r) => r.c).length, fail = R.filter((r) => !r.c).length;
  log('\n==== ' + pass + ' OK · ' + fail + ' FALLAN ====');
  if (fail) process.exit(1);
})().catch((e) => { console.error('ERROR', e); process.exit(2); });
