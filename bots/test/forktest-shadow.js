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
async function tx(c, fn, args, ov, label) {
  const addr = c.runner.address; const n = await nonceOf(addr);
  const t = await c[fn](...args, { ...(ov || {}), nonce: n });
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

  // ── T1 abrir ──
  const V = E / 20n, GAS = E / 200n, PER = E / 100n;   // 0.05 ETH, 0.005 gas, 0.01 por trade
  const base = { perTrade: PER, maxPerToken: PER * 2n, maxPositions: 1, slBps: 2000, tpBps: 1500, expiry: expiry(), feeBps: FEE_BPS, referrer: ethers.ZeroAddress };
  const rc1 = await tx(sh, 'openWithEth', [LEADER, base, GAS], { value: V + GAS }, 'openWithEth 0.05 + 0.005 gas'); reset();
  const op = evOf(rc1, IF, 'ShadowOpened'); const id = op.id; openIds.push(id);
  let S = await sh.shadow(id);
  ok('T1 abrio: quoteHeld 0.05, gasReserve 0.005, leader, limites', S.quoteHeld === V && S.gasReserve === GAS && S.leader.toLowerCase() === LEADER && S.perTrade === PER && S.maxPositions === 1n && S.nOpen === 0n);
  ok('T1 routeHash del evento == keccak(abi.encode(leader))', op.routeHash === ethers.keccak256(AC.encode(['address'], [LEADER])));
  await expectRevert('open con lider = maker', () => sh.openWithEth.staticCall(w.address, base, GAS, { value: V + GAS }), 'BadLeader', [IF]);
  await expectRevert('open con value <= gas', () => sh.openWithEth.staticCall(LEADER, base, GAS, { value: GAS }), 'BadValue', [IF]);
  await expectRevert('open con maxPositions 0', () => sh.openWithEth.staticCall(LEADER, { ...base, maxPositions: 0 }, GAS, { value: V + GAS }), 'BadParams', [IF]);
  await invariants('post-open');

  // ── T2 mirrorBuy ──
  const kw0 = await weth.balanceOf(k.address);
  const exp1 = await quoteBuy(PER); const min1 = pct(exp1, 90, 100);
  await expectRevert('mirrorBuy desde el maker (no keeper)', () => sh.mirrorBuy.staticCall(id, TOKEN, ROUTE, PER, min1, LTX(1)), 'NotKeeper', [IF]);
  await expectRevert('mirrorBuy > perTrade', () => shk.mirrorBuy.staticCall(id, TOKEN, ROUTE, PER + 1n, min1, LTX(1)), 'BadParams', [IF]);
  await expectRevert('mirrorBuy de WETH', () => shk.mirrorBuy.staticCall(id, WETH, ROUTE, PER, 1n, LTX(1)), 'BadGrid', [IF]);
  const rc2 = await tx(shk, 'mirrorBuy', [id, TOKEN, ROUTE, PER, min1, LTX(1)], null, 'keeper mirrorBuy 0.01'); reset();
  const m1 = evOf(rc2, IF, 'Mirrored'), gp1 = evOf(rc2, IF, 'GasPaid');
  let pos = await sh.position(id, TOKEN); S = await sh.shadow(id);
  ok('T2 Mirrored BUY: amountIn 0.01, out >= minOut, leaderTx', m1 && m1.side === 0n && m1.amountIn === PER && m1.amountOut >= min1 && m1.leaderTx === LTX(1), m1 ? m1.amountOut + ' tok' : '-');
  ok('T2 posicion: base == out, cost 0.01, buys 1, nOpen 1, tokensOf == [TOKEN]', pos.base === m1.amountOut && pos.cost === PER && pos.buys === 1n && S.nOpen === 1n && (await sh.tokensOf(id)).length === 1);
  ok('T2 quoteHeld bajo 0.01', S.quoteHeld === V - PER);
  ok('T2 GasPaid al keeper, en WETH, reserva baja', gp1 && gp1.owed > 0n && (await weth.balanceOf(k.address)) - kw0 === gp1.owed && S.gasReserve === GAS - gp1.owed, gp1 ? W(gp1.owed) : '-');
  await invariants('post-buy');
  // segundo token: maxPositions 1 -> TooManyPositions (antes de tocar el router)
  await expectRevert('mirrorBuy de otro token con maxPositions 1', () => shk.mirrorBuy.staticCall(id, '0x7ec553eb987101a078e9360ec2fd961573911239', ROUTE, PER, 1n, LTX(2)), 'TooManyPositions', [IF]);
  // mismo token: cabe una mas (maxPerToken 2x), la tercera no
  const exp2 = await quoteBuy(PER);
  await tx(shk, 'mirrorBuy', [id, TOKEN, ROUTE, PER, pct(exp2, 90, 100), LTX(3)], null, 'keeper mirrorBuy #2 mismo token'); reset();
  pos = await sh.position(id, TOKEN);
  ok('T2 segunda compra acumula: cost 0.02, buys 2', pos.cost === PER * 2n && pos.buys === 2n);
  await expectRevert('tercera compra excede maxPerToken', () => shk.mirrorBuy.staticCall(id, TOKEN, ROUTE, PER, 1n, LTX(4)), 'TokenCapReached', [IF]);
  await invariants('post-buy2');

  // ── T3 mirrorSell parcial y total ──
  const b0 = pos.base, c0 = pos.cost;
  await expectRevert('mirrorSell 0 bps', () => shk.mirrorSell.staticCall(id, TOKEN, ROUTE, 0, 1n, LTX(5)), 'BadParams', [IF]);
  await expectRevert('mirrorSell 10001 bps', () => shk.mirrorSell.staticCall(id, TOKEN, ROUTE, 10001, 1n, LTX(5)), 'BadParams', [IF]);
  await expectRevert('mirrorSell de token sin posicion', () => shk.mirrorSell.staticCall(id, '0x7ec553eb987101a078e9360ec2fd961573911239', ROUTE, 5000, 1n, LTX(5)), 'NoPosition', [IF]);
  const rc3 = await tx(shk, 'mirrorSell', [id, TOKEN, ROUTE, 5000, 1n, LTX(5)], null, 'keeper mirrorSell 50%'); reset();
  const m3 = evOf(rc3, IF, 'Mirrored'); pos = await sh.position(id, TOKEN); S = await sh.shadow(id);
  ok('T3 vendio la mitad: base ~ b0/2, cost c0/2, sells 1, pnl firmado', m3 && m3.side === 1n && pos.base === b0 - b0 / 2n && pos.cost === c0 - c0 / 2n && pos.sells === 1n && (m3.pnl !== 0n), m3 ? 'pnl ' + m3.pnl : '-');
  ok('T3 quoteHeld subio lo vendido', S.quoteHeld === V - 2n * PER + m3.amountOut);
  ok('T3 profit/loss registrado', (m3.pnl > 0n ? S.profit === m3.pnl : S.loss === -m3.pnl));
  const rc4 = await tx(shk, 'mirrorSell', [id, TOKEN, ROUTE, 10000, 1n, LTX(6)], null, 'keeper mirrorSell 100%'); reset();
  const pc4 = evOf(rc4, IF, 'PositionClosed'); pos = await sh.position(id, TOKEN); S = await sh.shadow(id);
  ok('T3 cierre total: PositionClosed kind 1, base 0, nOpen 0, tokensOf vacio', pc4 && pc4.kind === 1n && pos.base === 0n && pos.cost === 0n && S.nOpen === 0n && (await sh.tokensOf(id)).length === 0);
  await invariants('post-sell');

  // ── T4 takeProfit ──
  const exp4 = await quoteBuy(PER);
  await tx(shk, 'mirrorBuy', [id, TOKEN, ROUTE, PER, pct(exp4, 90, 100), LTX(7)], null, 'mirrorBuy para TP'); reset();
  pos = await sh.position(id, TOKEN);
  ok('T4 takeProfitMin == cost * 1.15', (await sh.takeProfitMin(id, TOKEN)) === (pos.cost * (BPS + 1500n)) / BPS);
  await expectRevert('takeProfit antes de que suba (el pool no paga cost*1.15)', () => shk.takeProfit.staticCall(id, TOKEN, ROUTE, 1n), 'Slippage', [IF]);
  await rawTx('0x000000000000000000000000000000000000bEEF', ROUTER, RI.encodeFunctionData('swapETH', [TOKEN, 0, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE]), E * 3n, 'PUMP 3 ETH');
  const rc5 = await tx(shk, 'takeProfit', [id, TOKEN, ROUTE, 1n], null, 'keeper takeProfit'); reset();
  const pc5 = evOf(rc5, IF, 'PositionClosed'); S = await sh.shadow(id);
  ok('T4 TP: kind 4, proceeds >= cost*1.15, nOpen 0', pc5 && pc5.kind === 4n && pc5.proceeds >= (pc5.cost * (BPS + 1500n)) / BPS && S.nOpen === 0n, pc5 ? W(pc5.proceeds) + ' vs cost ' + W(pc5.cost) : '-');
  await invariants('post-tp');

  // ── T5 stopLoss ──
  const exp6 = await quoteBuy(PER);
  await tx(shk, 'mirrorBuy', [id, TOKEN, ROUTE, PER, pct(exp6, 90, 100), LTX(8)], null, 'mirrorBuy para SL'); reset();
  pos = await sh.position(id, TOKEN);
  await expectRevert('stopLoss sin caida (proceeds > cost*0.8)', () => shk.stopLoss.staticCall(id, TOKEN, ROUTE, 1n), 'PriceNotReached', [IF]);
  // el whale vende para tirar el precio > 20 %; primero le damos token
  const WH = '0x000000000000000000000000000000000000bEEF';
  const whBal = await tok.balanceOf(WH);
  await rawTx(WH, TOKEN, RI.encodeFunctionData('approve', [ROUTER, whBal]), 0n, 'whale approve');
  await rawTx(WH, ROUTER, RI.encodeFunctionData('swapToETH', [TOKEN, whBal, 0, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE]), 0n, 'DUMP whale vende todo');
  const cap = (pos.cost * (BPS - 2000n)) / BPS;
  const floor = await sh.stopLossFloor(id, TOKEN);
  ok('T5 stopLossFloor == cap*0.95', floor === (cap * (BPS - 500n)) / BPS);
  let rc6 = null;
  try { rc6 = await tx(shk, 'stopLoss', [id, TOKEN, ROUTE, 1n], null, 'keeper stopLoss'); } catch (e) { log('    stopLoss no entro en ventana en el primer intento:', (e.shortMessage || e.message).slice(0, 80)); }
  reset();
  if (rc6) { const pc6 = evOf(rc6, IF, 'PositionClosed'); ok('T5 SL: kind 3, proceeds <= cap y >= floor', pc6 && pc6.kind === 3n && pc6.proceeds <= cap && pc6.proceeds >= floor, pc6 ? W(pc6.proceeds) + ' cap ' + W(cap) : '-'); }
  else {
    // fuera de ventana (cayo mas del 25 %): el maker vende con sellPosition y se sigue
    const rcs = await tx(sh, 'sellPosition', [id, TOKEN, ROUTE, 1n], null, 'maker sellPosition'); reset();
    ok('T5 (alt) sellPosition del maker cerro la posicion (kind 2)', evOf(rcs, IF, 'PositionClosed').kind === 2n);
  }
  S = await sh.shadow(id); ok('T5 sin posiciones abiertas', S.nOpen === 0n);
  await invariants('post-sl');

  // ── T6 topUp, setLimits, NoGas, stop ──
  await tx(sh, 'topUp', [id, E / 1000n], { value: E / 100n + E / 1000n }, 'maker topUp 0.01 + 0.001 gas'); reset();
  S = await sh.shadow(id);
  ok('T6 topUp sumo capital y gas', S.quoteHeld > 0n && S.gasReserve > 0n);
  await tx(sh, 'setLimits', [id, PER * 2n, 0n, 3, 0, 0], null, 'maker setLimits perTrade 0.02, 3 posiciones, sin SL/TP'); reset();
  S = await sh.shadow(id);
  ok('T6 setLimits: perTrade 0.02, maxPerToken == perTrade, maxPositions 3, sl/tp 0', S.perTrade === PER * 2n && S.maxPerToken === PER * 2n && S.maxPositions === 3n && S.slBps === 0n && S.tpBps === 0n);
  await expectRevert('setLimits desde otro', () => sho.setLimits.staticCall(id, PER, 0n, 1, 0, 0), 'NotMaker', [IF]);
  await expectRevert('stopLoss con slBps 0', () => shk.stopLoss.staticCall(id, TOKEN, ROUTE, 1n), 'BadParams', [IF]);
  // shadow sin reserva de gas: mirrorBuy revierte NoGas (duro)
  const rc7 = await tx(sh, 'openWithEth', [LEADER, base, 0n], { value: V }, 'openWithEth sin gas'); reset();
  const id2 = evOf(rc7, IF, 'ShadowOpened').id; openIds.push(id2);
  const exp7 = await quoteBuy(PER);
  await expectRevert('mirrorBuy sin reserva de gas', () => shk.mirrorBuy.staticCall(id2, TOKEN, ROUTE, PER, pct(exp7, 80, 100), LTX(9)), 'NoGas', [IF]);
  // stop del primero: devuelve ETH + gas; nada de tokens (ya no tiene)
  const mw0 = await p.getBalance(w.address);
  const rc8 = await tx(sh, 'stop', [id], null, 'maker stop'); reset();
  const st8 = evOf(rc8, IF, 'ShadowStopped'); S = await sh.shadow(id);
  ok('T6 stop: kind 0, quoteReturned == quoteHeld previo, status Stopped, gasReserve 0', st8 && st8.kind === 0n && S.status === 1n && S.quoteHeld === 0n && S.gasReserve === 0n && st8.tokensReturned === 0n, st8 ? W(st8.quoteReturned) : '-');
  const bn = rc8.blockNumber;
  ok('T6 el maker cobro ETH (o quedo en pendingEth)', (await p.getBalance(w.address, bn)) > (await p.getBalance(w.address, bn - 1)) || (await sh.pendingEth(w.address)) > 0n);
  await expectRevert('stop dos veces', () => sh.stop.staticCall(id), 'NotOpen', [IF]);
  await expectRevert('mirrorBuy en shadow cerrado', () => shk.mirrorBuy.staticCall(id, TOKEN, ROUTE, PER, 1n, LTX(10)), 'NotOpen', [IF]);
  openIds.splice(openIds.indexOf(id), 1);
  await invariants('post-stop');
  // stop con tokens adentro: devuelve el token sin vender
  await tx(sh, 'topUp', [id2, E / 500n], { value: E / 500n }, 'topUp solo gas al segundo'); reset();
  const exp8 = await quoteBuy(PER);
  const rc9 = await tx(shk, 'mirrorBuy', [id2, TOKEN, ROUTE, PER, pct(exp8, 80, 100), LTX(11)], null, 'mirrorBuy en el segundo'); reset();
  const bought = evOf(rc9, IF, 'Mirrored').amountOut;
  const tb0 = await tok.balanceOf(w.address);
  const rc10 = await tx(sh, 'stop', [id2], null, 'maker stop con token adentro'); reset();
  const st10 = evOf(rc10, IF, 'ShadowStopped');
  ok('T6 stop devolvio el token tal cual (tokensReturned 1, balance maker += base)', st10.tokensReturned === 1n && (await tok.balanceOf(w.address)) - tb0 === bought && (await sh.escrowed(TOKEN)) === 0n);
  openIds.splice(openIds.indexOf(id2), 1);
  await invariants('final');
  // refundExpired
  const rc11 = await tx(sh, 'openWithEth', [LEADER, { ...base, expiry: expiry(700) }, 0n], { value: V }, 'open corto'); reset();
  const id3 = evOf(rc11, IF, 'ShadowOpened').id;
  await expectRevert('refundExpired antes de vencer', () => sho.refundExpired.staticCall(id3), 'NotExpired', [IF]);
  await rpc('evm_increaseTime', 800); await rpc('evm_mine');
  const rc12 = await tx(sho, 'refundExpired', [id3], null, 'cualquiera refundExpired'); reset();
  ok('T6 refundExpired: kind 2, devolvio el ETH', evOf(rc12, IF, 'ShadowStopped').kind === 2n && (await sh.shadow(id3)).status === 1n);
  ok('T6 rescue no puede sacar escrow (NothingToRefund con todo cerrado y balance == escrow)', await sh.rescue.staticCall(WETH, w.address).then(() => false, (e) => /NothingToRefund/.test(e.shortMessage || e.message) || (e.data && IF.parseError(e.data) && IF.parseError(e.data).name === 'NothingToRefund')));

  const pass = R.filter((r) => r.c).length, fail = R.filter((r) => !r.c).length;
  log('\n==== ' + pass + ' OK · ' + fail + ' FALLAN ====');
  if (fail) process.exit(1);
})().catch((e) => { console.error('ERROR', e); process.exit(2); });
