// ArchitectShadow fork test (anvil :8903, fork of Robinhood Chain mainnet). Same harness as Infinity V4:
// wallets limpias (las del mnemonic tienen delegate 7702 en mainnet), tx impersonadas por eth_sendTransaction
// crudo con espera de recibo acotada, NonceManager reseteado antes de cada op (un revert deja hueco de nonce).
const fs = require('fs'), path = require('path'), { ethers } = require('ethers');
const DIR = __dirname;
const A = JSON.parse(fs.readFileSync((process.env.DESK_ADDRESSES || require('path').join(__dirname, '../../deployments/desk-addresses.json')), 'utf8'));
const p = new ethers.JsonRpcProvider('http://127.0.0.1:8903', 4663, { staticNetwork: true, batchMaxCount: 1 });
const _est = p.estimateGas.bind(p); p.estimateGas = async (t) => ((await _est(t)) * 3n) / 2n;
const WETH = A.weth || A.WETH, ROUTER = A.feeRouterV2, KEEPER = A.keeper;
const ROUTER_OWNER = '0xa6CD59b326F8bc5Cf68EcD2377Eee13AfBbb1657';
const TOKEN = '0xb9d3824149ad8ac984153ceec91d5a2405d1fb95', POOL = '0x483c24d1e36df01b650f1e9beeb2a1c31c005c39';
const POOL_FEE = 10000, FEE_BPS = 100, E = 10n ** 18n, BPS = 10_000n;
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
const LTX = (n) => ethers.zeroPadValue(ethers.toBeHex(n), 32);
const NONCE = {};
async function nonceOf(addr) { if (NONCE[addr] === undefined) NONCE[addr] = await p.getTransactionCount(addr, 'latest'); return NONCE[addr]; }
/** manda contract[fn](...args) con nonce llevado a mano; solo avanza el nonce si la tx entro */
const errData = (e) => { for (const d of [e && e.data, e && e.info && e.info.error && e.info.error.data, e && e.error && e.error.data, e && e.revert && e.revert.data]) if (typeof d === 'string' && d.length >= 10) return d; return null; };
async function tx(c, fn, args, ov, label) {
  const addr = c.runner.address; const n = await nonceOf(addr);
  // propina 0: tx.gasprice == basefee, igual que en la cadena real (y que en el eth_call, que corre con gasprice 0 -> basefee)
  const bf = BigInt((await p.getBlock('latest')).baseFeePerGas || 1n);
  const t = await c[fn](...args, { maxFeePerGas: bf * 4n, maxPriorityFeePerGas: 0n, ...(ov || {}), nonce: n });
  const rc = await t.wait(); NONCE[addr] = n + 1;
  log('    tx', label, 'gas', rc.gasUsed.toString()); return rc;
}
const ROUTER_IF = new ethers.Interface(['error Slippage(uint256,uint256)', 'error NotCaller()', 'error PairNotAllowed()']);
async function expectRevert(name, fn, errName, ifaces) {
  try { await fn(); ok('NEG ' + name + ' -> ' + errName, false, 'NO revirtio'); }
  catch (e) { const d = e.data || (e.info && e.info.error && e.info.error.data) || ''; let got = e.shortMessage || e.message; for (const i of ifaces.concat([ROUTER_IF])) { try { const pe = i.parseError(d); if (pe) { got = pe.name + '(' + pe.args.join(',') + ')'; break; } } catch (_) { } } ok('NEG ' + name + ' -> ' + errName, String(got).includes(errName), 'got=' + String(got).slice(0, 90)); }
}
const evOf = (rc, iface, n) => { for (const l of rc.logs) { try { const e = iface.parseLog({ topics: l.topics, data: l.data }); if (e && e.name === n) return e.args; } catch (_) { } } return null; };
const evsOf = (rc, iface, n) => { const out = []; for (const l of rc.logs) { try { const e = iface.parseLog({ topics: l.topics, data: l.data }); if (e && e.name === n) out.push(e.args); } catch (_) { } } return out; };

(async () => {
  const M = 'test test test test test test test test test test test junk';
  const cand = []; for (let i = 0; i < 10; i++) { const hw = ethers.HDNodeWallet.fromPhrase(M, undefined, "m/44'/60'/0'/0/" + i); const nm = new ethers.NonceManager(new ethers.Wallet(hw.privateKey, p)); nm.address = hw.address; cand.push(nm); }
  // siempre wallets nuevas: las del mnemonic existen en mainnet y el fork cachea su nonce viejo (nonce too low)
  // Wallet pelada, sin NonceManager: pide el nonce a la cadena en cada tx (las ops son secuenciales)
  const limpia = async () => ethers.Wallet.createRandom().connect(p);
  const w = await limpia(), k = await limpia(), o = await limpia();
  for (const x of [w, k, o]) await rpc('anvil_setBalance', x.address, '0x56BC75E2D63100000');
  const reset = () => {};
  const abi = JSON.parse(fs.readFileSync(path.join(DIR, 'artifacts', 'ArchitectShadow.abi.json'), 'utf8'));
  const bin = '0x' + fs.readFileSync(path.join(DIR, 'artifacts', 'ArchitectShadow.bin'), 'utf8');
  const sh = await (await new ethers.ContractFactory(abi, bin, w).deploy(ROUTER, WETH, KEEPER, { nonce: await nonceOf(w.address) })).waitForDeployment(); NONCE[w.address] += 1;
  const SH = await sh.getAddress(), IF = new ethers.Interface(abi), shk = sh.connect(k), sho = sh.connect(o);
  const RI = new ethers.Interface(['function swapETH(address,uint256,uint16,address,uint256,bytes) payable returns (uint256)', 'function swapToETH(address,uint256,uint256,uint16,address,uint256,bytes) returns (uint256)', 'function approve(address,uint256) returns (bool)']);
  async function rawTx(from, to, data, value, label) {
    await rpc('anvil_impersonateAccount', from); await rpc('anvil_setBalance', from, '0x56BC75E2D63100000');
    try {
      const req = { from, to, data, gas: '0x2dc6c0' }; if (value) req.value = ethers.toBeHex(value);
      const h = await rpc('eth_sendTransaction', req);
      for (let i = 0; i < 120; i++) { const rc = await p.getTransactionReceipt(h); if (rc) { log('    tx', label, 'gas', rc.gasUsed.toString(), rc.status === 1 ? '' : '(REVIRTIO)'); if (rc.status !== 1) throw new Error(label + ' revirtio'); return rc; } await new Promise((r) => setTimeout(r, 500)); }
      throw new Error('sin recibo: ' + label);
    } finally { await rpc('anvil_stopImpersonatingAccount', from).catch(() => {}); }
  }
  await rawTx(ROUTER_OWNER, ROUTER, new ethers.Interface(['function setCaller(address,bool)']).encodeFunctionData('setCaller', [SH, true]), 0n, 'router.setCaller');
  await tx(sh, 'setKeeper', [k.address, true], null, 'setKeeper'); reset();
  const weth = new ethers.Contract(WETH, erc20, p), tok = new ethers.Contract(TOKEN, erc20, p);
  const Pnow = async () => { const s = await new ethers.Contract(POOL, ['function slot0() view returns (uint160,int24,uint16,uint16,uint16,uint8,bool)'], p).slot0(); const q2 = BigInt(s[0]); return (E << 192n) / (q2 * q2); };
  const quoteBuy = async (amountIn) => { const P0 = await Pnow(); return (amountIn * E) / P0; };   // token esperado (bruto)
  const LEADER = '0x2fff3766f5339d86a61197b2b2c6b2886e9cc1c6';

  // invariantes de escrow
  const openIds = [];
  async function invariants(tag) {
    let q = 0n, g = 0n, base = 0n;
    for (const id of openIds) { const S = await sh.shadow(id); q += S.quoteHeld; g += S.gasReserve; const pos = await sh.position(id, TOKEN); base += pos.base; }
    const ew = await sh.escrowed(WETH), et = await sh.escrowed(TOKEN), ge = await sh.gasEscrowed();
    ok('I1 ' + tag + ': escrowed[WETH] == Σ quoteHeld + Σ gasReserve', ew === q + g, W(ew) + ' vs ' + W(q + g));
    ok('I2 ' + tag + ': gasEscrowed == Σ gasReserve <= escrowed[WETH]', ge === g && ge <= ew);
    ok('I3 ' + tag + ': escrowed[TOKEN] == Σ base', et === base, et + ' vs ' + base);
    ok('I4 ' + tag + ': balances >= escrowed', (await weth.balanceOf(SH)) >= ew && (await tok.balanceOf(SH)) >= et);
  }

  // ── SL fino: bajar el precio de a poco hasta la ventana [cap*0.95, cap] ──
  const V = E / 20n, GAS = E / 200n, PER = E / 100n;
  const base = { perTrade: PER, maxPerToken: PER * 2n, maxPositions: 1, slBps: 2000, tpBps: 0, expiry: expiry(), feeBps: FEE_BPS, referrer: ethers.ZeroAddress };
  const rc1 = await tx(sh, 'openWithEth', [LEADER, base, GAS], { value: V + GAS }, 'open'); const id = evOf(rc1, IF, 'ShadowOpened').id; openIds.push(id);
  const WH = '0x000000000000000000000000000000000000bEEF';
  await rawTx(WH, ROUTER, RI.encodeFunctionData('swapETH', [TOKEN, 0, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE]), E * 2n, 'whale compra 2 ETH (antes que el shadow)');
  let bag = await tok.balanceOf(WH);
  await rawTx(WH, TOKEN, RI.encodeFunctionData('approve', [ROUTER, bag]), 0n, 'whale approve');
  const exp1 = await quoteBuy(PER);
  await tx(shk, 'mirrorBuy', [id, TOKEN, ROUTE, PER, pct(exp1, 90, 100), LTX(1)], null, 'mirrorBuy');
  const pos = await sh.position(id, TOKEN); const cap = (pos.cost * (BPS - 2000n)) / BPS, floor = await sh.stopLossFloor(id, TOKEN);
  log('    cost', W(pos.cost), 'cap', W(cap), 'floor', W(floor));
  // el whale vende su bolsa de a partes chicas hasta que el SL entre en ventana
  const PARTS = 80n, MAXD = 200;
  let done = false, dumps = 0; const bag0 = bag;
  for (let i = 0; i < MAXD && !done; i++) {
    // ¿ya esta en ventana? (staticCall del keeper con minOut = floor)
    let got = null;
    try { got = await shk.stopLoss.staticCall(id, TOKEN, ROUTE, floor); } catch (e) { got = null; }
    if (got !== null) { done = true; break; }
    const part = bag0 / PARTS; if (part === 0n || (await tok.balanceOf(WH)) < part) break;
    await rawTx(WH, ROUTER, RI.encodeFunctionData('swapToETH', [TOKEN, part, 0, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE]), 0n, 'dump 1/' + PARTS); dumps++;
  }
  ok('SL en ventana tras ' + dumps + ' bajadas finas', done);
  const kw0 = await weth.balanceOf(k.address);
  const rc2 = await tx(shk, 'stopLoss', [id, TOKEN, ROUTE, floor], null, 'keeper stopLoss');
  const pc = evOf(rc2, IF, 'PositionClosed'), gp = evOf(rc2, IF, 'GasPaid'); const S = await sh.shadow(id);
  ok('SL: PositionClosed kind 3, proceeds en [floor, cap]', pc && pc.kind === 3n && pc.proceeds >= floor && pc.proceeds <= cap, pc ? W(pc.proceeds) + ' cap ' + W(cap) : '-');
  ok('SL: loss registrada = cost - proceeds', pc && S.loss === pc.cost - pc.proceeds);
  ok('SL: gas cobrado (soft) al keeper', gp && gp.owed > 0n && (await weth.balanceOf(k.address)) - kw0 === gp.owed, gp ? W(gp.owed) : '-');
  ok('SL: shadow sigue abierto con el ETH de la venta', S.status === 0n && S.nOpen === 0n && S.quoteHeld > V - PER);
  await invariants('post-sl');
  // SL soft con reserva vacia: abrir sin gas, comprar no se puede (NoGas)... se carga gas minimo para UNA compra y despues el SL cobra lo que hay
  const rc3 = await tx(sh, 'openWithEth', [LEADER, base, 0n], { value: V }, 'open sin gas'); const id2 = evOf(rc3, IF, 'ShadowOpened').id; openIds.push(id2);
  const one = (await shk.mirrorBuy.staticCall(id2, TOKEN, ROUTE, PER, 1n, LTX(2)).then(() => 0n, (e) => { const d = errData(e); const pe = d ? IF.parseError(d) : null; if (!pe) log('    sin data de revert:', (e && e.shortMessage) || String(e).slice(0, 200)); return pe && pe.name === 'NoGas' ? pe.args[0] : 0n; }));
  ok('sin gas: NoGas informa lo que costaria', one > 0n, W(one));
  const oneX = (one * 15n) / 10n; await tx(sh, 'topUp', [id2, oneX], { value: oneX }, 'topUp gas justo para una compra (x1.5)');
  await rawTx(WH, ROUTER, RI.encodeFunctionData('swapETH', [TOKEN, 0, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE]), E * 2n, 'whale recompra 2 ETH (antes que el shadow 2)');
  bag = await tok.balanceOf(WH); await rawTx(WH, TOKEN, RI.encodeFunctionData('approve', [ROUTER, bag]), 0n, 'whale approve 2');
  const exp2 = await quoteBuy(PER);
  await tx(shk, 'mirrorBuy', [id2, TOKEN, ROUTE, PER, pct(exp2, 80, 100), LTX(3)], null, 'mirrorBuy con gas justo');
  const S2 = await sh.shadow(id2); log('    reserva tras la compra', W(S2.gasReserve));
  const pos2 = await sh.position(id2, TOKEN); const cap2 = (pos2.cost * (BPS - 2000n)) / BPS, floor2 = await sh.stopLossFloor(id2, TOKEN);
  let done2 = false;
  const bagB = bag; for (let i = 0; i < MAXD && !done2; i++) { try { await shk.stopLoss.staticCall(id2, TOKEN, ROUTE, floor2); done2 = true; break; } catch (_) {} const part = bagB / PARTS; if (part === 0n || (await tok.balanceOf(WH)) < part) break; await rawTx(WH, ROUTER, RI.encodeFunctionData('swapToETH', [TOKEN, part, 0, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE]), 0n, 'dump'); bag = await tok.balanceOf(WH); }
  ok('SL soft: en ventana aunque la reserva este casi vacia', done2);
  if (!done2) { ok('SL soft: no llego a la ventana (bolsa chica)', false); await invariants('final'); const pass = R.filter((r) => r.c).length, fail = R.filter((r) => !r.c).length; log('==== ' + pass + ' OK · ' + fail + ' FALLAN ===='); process.exit(1); }
  // anvil baja el basefee 12,5 % por bloque vacio, asi que la reserva que sobro alcanza para el SL. Para forzar el camino soft
  // (reserva < costo) subimos el basefee del proximo bloque a 1 gwei: el SL cuesta ~0.0003 ETH >> reserva.
  await rpc('anvil_setNextBlockBaseFeePerGas', ethers.toBeHex(1000000000n));
  const rc4 = await tx(shk, 'stopLoss', [id2, TOKEN, ROUTE, floor2], { maxFeePerGas: 4000000000n }, 'stopLoss soft (basefee 1 gwei)');
  log('    GasPaid soft', (evOf(rc4, IF, 'GasPaid') || {}).owed, 'reserva antes', S2.gasReserve);
  const gp4 = evOf(rc4, IF, 'GasPaid'); const S3 = await sh.shadow(id2);
  ok('SL soft: cobro solo lo que habia (o nada) y NO revirtio; reserva 0', (!gp4 || gp4.owed <= S2.gasReserve) && S3.gasReserve === 0n && S3.nOpen === 0n);
  await invariants('final');
  const pass = R.filter((r) => r.c).length, fail = R.filter((r) => !r.c).length;
  log('\n==== ' + pass + ' OK · ' + fail + ' FALLAN ====');
  if (fail) process.exit(1);
})().catch((e) => { console.error('ERROR', e); process.exit(2); });
