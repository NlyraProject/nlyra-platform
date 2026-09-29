// ArchitectSniper fork test (anvil :8905, fork of Robinhood Chain mainnet). Same harness as Shadow:
// wallets limpias (las del mnemonic tienen delegate 7702 en mainnet), tx impersonadas por eth_sendTransaction
// crudo con espera de recibo acotada, nonce llevado a mano (un revert deja hueco de nonce).
// Curva: se elige EN VIVO un lanzamiento de Pons reciente que todavia acepte compras en el bloque del fork.
const fs = require('fs'), path = require('path'), { ethers } = require('ethers');
const DIR = __dirname;
const A = JSON.parse(fs.readFileSync((process.env.DESK_ADDRESSES || require('path').join(__dirname, '../../deployments/desk-addresses.json')), 'utf8'));
const p = new ethers.JsonRpcProvider('http://127.0.0.1:8905', 4663, { staticNetwork: true, batchMaxCount: 1 });
const _est = p.estimateGas.bind(p); p.estimateGas = async (t) => ((await _est(t)) * 3n) / 2n;
const WETH = A.weth || A.WETH, ROUTER = A.feeRouterV2, KEEPER = A.keeper;
const ROUTER_OWNER = '0xa6CD59b326F8bc5Cf68EcD2377Eee13AfBbb1657';
const PONS_LAUNCHER = '0xe33E9E479dF8802cb0866d5d05258bEc4cF62948', PONS_FACTORY = '0x7ed598bcef8bd9edd8c97a195c6d13f40801ec7e';
const T_LAUNCH = '0xdcacba5e347ae7abd91cb519eb877af8fa7774e347b85dd3ddcd24a2ba8cdf37', T_BUY = '0xec36bf571f136799e8dc0b0b8bea4b04d8bd3d43de838aab0d5fc21d4cbfc455';
const SEL_BUY = '0x59a87bc1', SEL_SELL = '0xd04c6983';
// pool V3 real (NLYRA/WETH) para la ruta por router
const PTOKEN = '0xb9d3824149ad8ac984153ceec91d5a2405d1fb95', POOL = '0x483c24d1e36df01b650f1e9beeb2a1c31c005c39';
const POOL_FEE = 10000, FEE_BPS = 100, E = 10n ** 18n, BPS = 10_000n;
const AC = ethers.AbiCoder.defaultAbiCoder();
const ROUTE = AC.encode(['uint8', 'bytes'], [0, AC.encode(['uint24'], [POOL_FEE])]);
const NOROUTE = '0x';
const W = (x) => ethers.formatEther(x) + ' ETH';
const log = (...a) => console.log(...a);
const R = [];
const ok = (s, c, e) => { R.push({ s, c: !!c }); log(c ? ' OK  ' : ' XXX ', s, e === undefined ? '' : '| ' + e); };
const erc20 = ['function balanceOf(address) view returns (uint256)', 'function approve(address,uint256) returns (bool)'];
const rpc = (m, ...a) => p.send(m, a);
const expiry = (s) => BigInt(Math.floor(Date.now() / 1000) + (s || 86400));
const pct = (x, n, d) => (x * BigInt(n)) / BigInt(d);
const NONCE = {};
async function nonceOf(addr) { if (NONCE[addr] === undefined) NONCE[addr] = await p.getTransactionCount(addr, 'latest'); return NONCE[addr]; }
async function tx(c, fn, args, ov, label) {
  const addr = c.runner.address; const n = await nonceOf(addr);
  const t = await c[fn](...args, { ...(ov || {}), nonce: n });
  const rc = await t.wait(); NONCE[addr] = n + 1;
  log('    tx', label, 'gas', rc.gasUsed.toString()); return rc;
}
const ROUTER_IF = new ethers.Interface(['error Slippage(uint256,uint256)', 'error NotCaller()', 'error PairNotAllowed()']);
async function expectRevert(name, fn, errName, ifaces) {
  try { await fn(); ok('NEG ' + name + ' -> ' + errName, false, 'NO revirtio'); }
  catch (e) {
    const d = e.data || (e.info && e.info.error && e.info.error.data) || ''; let got = e.shortMessage || e.message;
    for (const i of ifaces.concat([ROUTER_IF])) { try { const pe = i.parseError(d); if (pe) { got = pe.name; break; } } catch (_) { } }
    if (typeof d === 'string' && /InsufficientOutput|reverted/.test(got) && d.length >= 10) { for (const i of ifaces) { try { const pe = i.parseError(d.slice(0, 10) + d.slice(10)); if (pe) got = pe.name; } catch (_) { } } }
    ok('NEG ' + name + ' -> ' + errName, got === errName || (got || '').includes(errName), got);
  }
}
const evOf = (rc, iface, n) => { for (const l of rc.logs) { try { const e = iface.parseLog({ topics: l.topics, data: l.data }); if (e && e.name === n) return e.args; } catch (_) { } } return null; };

(async () => {
  const limpia = async () => ethers.Wallet.createRandom().connect(p);
  const w = await limpia(), k = await limpia(), o = await limpia();
  for (const x of [w, k, o]) await rpc('anvil_setBalance', x.address, '0x56BC75E2D63100000');
  const abi = JSON.parse(fs.readFileSync(path.join(DIR, 'artifacts', 'ArchitectSniper.abi.json'), 'utf8'));
  const bin = '0x' + fs.readFileSync(path.join(DIR, 'artifacts', 'ArchitectSniper.bin'), 'utf8');
  const sn = await (await new ethers.ContractFactory(abi, bin, w).deploy(ROUTER, WETH, KEEPER, PONS_FACTORY, { nonce: await nonceOf(w.address) })).waitForDeployment(); NONCE[w.address] += 1;
  const SN = await sn.getAddress(), IF = new ethers.Interface(abi), snk = sn.connect(k), sno = sn.connect(o);
  const RI = new ethers.Interface(['function swapETH(address,uint256,uint16,address,uint256,bytes) payable returns (uint256)', 'function swapToETH(address,uint256,uint256,uint16,address,uint256,bytes) returns (uint256)', 'function approve(address,uint256) returns (bool)', 'function setCaller(address,bool)', 'function treasury() view returns (address)']);
  async function rawTx(from, to, data, value, label, allowRevert) {
    await rpc('anvil_impersonateAccount', from); await rpc('anvil_setBalance', from, '0x56BC75E2D63100000');
    try {
      const req = { from, to, data, gas: '0x2dc6c0' }; if (value) req.value = ethers.toBeHex(value);
      const h = await rpc('eth_sendTransaction', req);
      for (let i = 0; i < 120; i++) { const rc = await p.getTransactionReceipt(h); if (rc) { log('    tx', label, 'gas', rc.gasUsed.toString(), rc.status === 1 ? '' : '(REVIRTIO)'); if (rc.status !== 1 && !allowRevert) throw new Error('revirtio: ' + label); return rc; } await new Promise((r) => setTimeout(r, 250)); }
      throw new Error('sin recibo: ' + label);
    } finally { await rpc('anvil_stopImpersonatingAccount', from).catch(() => {}); }
  }
  await rawTx(ROUTER_OWNER, ROUTER, RI.encodeFunctionData('setCaller', [SN, true]), 0n, 'router.setCaller');
  await tx(sn, 'setKeeper', [k.address, true], null, 'setKeeper');
  const weth = new ethers.Contract(WETH, erc20, p);
  const FEE_TO = await new ethers.Contract(ROUTER, ['function treasury() view returns (address)'], p).treasury();
  ok('T0 feeTo == router.treasury()', (await sn.feeTo()).toLowerCase() === FEE_TO.toLowerCase(), FEE_TO);
  ok('T0 ponsFactory registrada', (await sn.ponsFactory()).toLowerCase() === PONS_FACTORY);

  // ── elegir una curva viva: lanzamiento reciente que todavia acepte una compra chica ──
  const head = await p.getBlockNumber();
  const launches = await p.getLogs({ address: PONS_LAUNCHER, fromBlock: head - 4000, toBlock: head, topics: [T_LAUNCH] });
  let CURVE = null, TOKEN = null;
  for (const l of launches.reverse()) {
    const curve = '0x' + l.topics[2].slice(26), token = '0x' + l.topics[1].slice(26);
    const buys = await p.getLogs({ address: curve, fromBlock: l.blockNumber, toBlock: head, topics: [T_BUY] });
    if (buys.length < 3) continue;
    try {
      const data = SEL_BUY + AC.encode(['uint256', 'uint256', 'address'], [E / 2000n, 0, o.address]).slice(2);
      const r = await p.call({ to: curve, from: o.address, data, value: E / 2000n });
      if (r && r.length > 2 && BigInt(r) > 0n) { CURVE = curve; TOKEN = token; log('curva elegida', curve, 'token', token, 'buys', buys.length, 'launch blk', l.blockNumber); break; }
    } catch (_) { }
  }
  if (!CURVE) { console.error('no hay curva viva en el fork'); process.exit(2); }
  const tok = new ethers.Contract(TOKEN, erc20, p);
  const simBuy = async (eth) => BigInt(await p.call({ to: CURVE, from: o.address, data: SEL_BUY + AC.encode(['uint256', 'uint256', 'address'], [eth, 0, o.address]).slice(2), value: eth }));   // desde una wallet con ETH: la curva cotiza igual para cualquiera
  const openIds = [];
  async function invariants(tag) {
    let q = 0n, g = 0n, baseC = 0n, baseP = 0n;
    for (const id of openIds) { const B = await sn.bot(id); q += B.quoteHeld; g += B.gasReserve; baseC += (await sn.position(id, TOKEN)).base; baseP += (await sn.position(id, PTOKEN)).base; }
    const ew = await sn.escrowed(WETH), et = await sn.escrowed(TOKEN), ep = await sn.escrowed(PTOKEN), ge = await sn.gasEscrowed();
    ok('I1 ' + tag + ': escrowed[WETH] == Σ quoteHeld + Σ gasReserve', ew === q + g, W(ew) + ' vs ' + W(q + g));
    ok('I2 ' + tag + ': gasEscrowed == Σ gasReserve <= escrowed[WETH]', ge === g && ge <= ew);
    ok('I3 ' + tag + ': escrowed[token] == Σ base (curva y pool)', et === baseC && ep === baseP);
    ok('I4 ' + tag + ': balances >= escrowed', (await weth.balanceOf(SN)) >= ew && (await tok.balanceOf(SN)) >= et);
    ok('I5 ' + tag + ': el contrato no acumula ETH suelto', (await p.getBalance(SN)) === 0n, W(await p.getBalance(SN)));
  }

  // ── T1 abrir ──
  const V = E / 20n, GAS = E / 200n, PER = E / 100n;   // 0.05 ETH, 0.005 gas, 0.01 por entrada
  const base = { perTrade: PER, maxPerToken: PER * 2n, maxPositions: 1, slBps: 2000, tpBps: 1500, expiry: expiry(), feeBps: FEE_BPS, sources: 3, referrer: ethers.ZeroAddress };
  const rc1 = await tx(sn, 'openWithEth', [base, GAS], { value: V + GAS }, 'openWithEth 0.05 + 0.005 gas');
  const op = evOf(rc1, IF, 'BotOpened'); const id = op.id; openIds.push(id);
  let B = await sn.bot(id);
  ok('T1 abrio: quoteHeld 0.05, gasReserve 0.005, limites, sources 3', B.quoteHeld === V && B.gasReserve === GAS && B.perTrade === PER && B.maxPositions === 1n && B.nOpen === 0n && B.sources === 3n);
  await expectRevert('open con value <= gas', () => sn.openWithEth.staticCall(base, GAS, { value: GAS }), 'BadValue', [IF]);
  await expectRevert('open con sources 0', () => sn.openWithEth.staticCall({ ...base, sources: 0 }, GAS, { value: V + GAS }), 'BadParams', [IF]);
  await expectRevert('open con sources 4', () => sn.openWithEth.staticCall({ ...base, sources: 4 }, GAS, { value: V + GAS }), 'BadParams', [IF]);
  await expectRevert('open con maxPositions 0', () => sn.openWithEth.staticCall({ ...base, maxPositions: 0 }, GAS, { value: V + GAS }), 'BadParams', [IF]);
  await invariants('post-open');

  // ── T2 enterCurve ──
  const kw0 = await weth.balanceOf(k.address), ft0 = await weth.balanceOf(FEE_TO);
  const exp1 = await simBuy(PER - PER / 100n); const min1 = pct(exp1, 90, 100);
  await expectRevert('enterCurve desde el maker (no keeper)', () => sn.enter.staticCall(id, TOKEN, CURVE, NOROUTE, PER, min1), 'NotKeeper', [IF]);
  await expectRevert('enterCurve > perTrade', () => snk.enter.staticCall(id, TOKEN, CURVE, NOROUTE, PER + 1n, min1), 'BadParams', [IF]);
  await expectRevert('enterCurve con minOut 0', () => snk.enter.staticCall(id, TOKEN, CURVE, NOROUTE, PER, 0), 'BadParams', [IF]);
  await expectRevert('enterCurve con curva falsa (el token no es curva)', () => snk.enter.staticCall(id, TOKEN, TOKEN, NOROUTE, PER, 1n), 'BadCurve', [IF]);
  await expectRevert('enterCurve con token que no es el de la curva', () => snk.enter.staticCall(id, PTOKEN, CURVE, NOROUTE, PER, 1n), 'BadCurve', [IF]);
  await expectRevert('enterCurve de WETH', () => snk.enter.staticCall(id, WETH, CURVE, NOROUTE, PER, 1n), 'BadCurve', [IF]);
  const rc2 = await tx(snk, 'enter', [id, TOKEN, CURVE, NOROUTE, PER, min1], null, 'keeper enterCurve 0.01');
  const e1 = evOf(rc2, IF, 'Entered'), gp1 = evOf(rc2, IF, 'GasPaid');
  let pos = await sn.position(id, TOKEN); B = await sn.bot(id);
  const fee1 = PER / 100n;
  ok('T2 Entered: kind 1, venue = curva, amountIn 0.01, fee 1 % en WETH, out >= minOut', e1 && e1.kind === 1n && e1.venue.toLowerCase() === CURVE && e1.amountIn === PER && e1.fee === fee1 && e1.amountOut >= min1, e1 ? e1.amountOut + ' tok' : '-');
  ok('T2 feeTo cobro 0.0001 WETH', (await weth.balanceOf(FEE_TO)) - ft0 === fee1);
  ok('T2 posicion: base == out, cost 0.01, kind 1, venue, nOpen 1', pos.base === e1.amountOut && pos.cost === PER && pos.kind === 1n && pos.venue.toLowerCase() === CURVE && B.nOpen === 1n && (await sn.tokensOf(id)).length === 1);
  ok('T2 quoteHeld bajo 0.01', B.quoteHeld === V - PER);
  ok('T2 GasPaid al keeper en WETH, reserva baja', gp1 && gp1.owed > 0n && (await weth.balanceOf(k.address)) - kw0 === gp1.owed && B.gasReserve === GAS - gp1.owed, gp1 ? W(gp1.owed) : '-');
  await invariants('post-enter');
  await expectRevert('enterPool de otro token con maxPositions 1', () => snk.enter.staticCall(id, PTOKEN, ethers.ZeroAddress, ROUTE, PER, 1n), 'TooManyPositions', [IF]);
  await expectRevert('enterPool del MISMO token (venue distinta)', () => snk.enter.staticCall(id, TOKEN, ethers.ZeroAddress, ROUTE, PER, 1n), 'WrongVenue', [IF]);
  const exp2 = await simBuy(PER - PER / 100n);
  await tx(snk, 'enter', [id, TOKEN, CURVE, NOROUTE, PER, pct(exp2, 90, 100)], null, 'keeper enterCurve #2 mismo token');
  pos = await sn.position(id, TOKEN);
  ok('T2 segunda compra acumula: cost 0.02, buys 2', pos.cost === PER * 2n && pos.buys === 2n);
  await expectRevert('tercera compra excede maxPerToken', () => snk.enter.staticCall(id, TOKEN, CURVE, NOROUTE, PER, 1n), 'TokenCapReached', [IF]);
  await invariants('post-enter2');

  // ── T3 exit parcial y total en curva ──
  const b0 = pos.base, c0 = pos.cost, ft1 = await weth.balanceOf(FEE_TO);
  await expectRevert('exit 0 bps', () => snk.close.staticCall(id, TOKEN, NOROUTE, 0, 1n, 0), 'BadParams', [IF]);
  await expectRevert('exit 10001 bps', () => snk.close.staticCall(id, TOKEN, NOROUTE, 10001, 1n, 0), 'BadParams', [IF]);
  await expectRevert('exit de token sin posicion', () => snk.close.staticCall(id, PTOKEN, NOROUTE, 5000, 1n, 0), 'NoPosition', [IF]);
  await expectRevert('exit con minOut 0', () => snk.close.staticCall(id, TOKEN, NOROUTE, 5000, 0, 0), 'BadParams', [IF]);
  await expectRevert('exit con minOut imposible', () => snk.close.staticCall(id, TOKEN, NOROUTE, 5000, E, 0), 'InsufficientOutput', [IF]);
  const rc3 = await tx(snk, 'close', [id, TOKEN, NOROUTE, 5000, 1n, 0], null, 'keeper close 50%');
  const x3 = evOf(rc3, IF, 'Exited'); pos = await sn.position(id, TOKEN); B = await sn.bot(id);
  ok('T3 vendio la mitad: base ~ b0/2, cost c0/2, sells 1, reason 0, pnl firmado, fee > 0', x3 && x3.reason === 0n && pos.base === b0 - b0 / 2n && pos.cost === c0 - c0 / 2n && pos.sells === 1n && x3.pnl !== 0n && x3.fee > 0n, x3 ? 'pnl ' + x3.pnl + ' fee ' + x3.fee : '-');
  ok('T3 feeTo cobro el 1 % de la venta', (await weth.balanceOf(FEE_TO)) - ft1 === x3.fee);
  ok('T3 quoteHeld subio lo vendido (neto de fee)', B.quoteHeld === V - 2n * PER + x3.proceeds);
  ok('T3 profit/loss registrado', (x3.pnl > 0n ? B.profit === x3.pnl : B.loss === -x3.pnl));
  const rc4 = await tx(snk, 'close', [id, TOKEN, NOROUTE, 10000, 1n, 0], null, 'keeper close 100%');
  const pc4 = evOf(rc4, IF, 'PositionClosed'); pos = await sn.position(id, TOKEN); B = await sn.bot(id);
  ok('T3 cierre total: PositionClosed reason 1, base 0, nOpen 0, tokensOf vacio', pc4 && pc4.reason === 1n && pos.base === 0n && pos.cost === 0n && B.nOpen === 0n && (await sn.tokensOf(id)).length === 0);
  await invariants('post-exit');

  // ── T4 takeProfit en curva (un whale compra en la curva) ──
  const exp4 = await simBuy(PER - PER / 100n);
  await tx(snk, 'enter', [id, TOKEN, CURVE, NOROUTE, PER, pct(exp4, 90, 100)], null, 'enterCurve para TP');
  pos = await sn.position(id, TOKEN);
  await expectRevert('takeProfit antes de que suba', () => snk.close.staticCall(id, TOKEN, NOROUTE, 10000, 1n, 4), 'InsufficientOutput', [IF]);
  await expectRevert('close con mode invalido', () => snk.close.staticCall(id, TOKEN, NOROUTE, 10000, 1n, 7), 'BadParams', [IF]);
  const WH = '0x000000000000000000000000000000000000bEEF';
  await rawTx(WH, CURVE, SEL_BUY + AC.encode(['uint256', 'uint256', 'address'], [E * 2n, 0, WH]).slice(2), E * 2n, 'PUMP whale compra 2 ETH en la curva');
  const rc5 = await tx(snk, 'close', [id, TOKEN, NOROUTE, 10000, 1n, 4], null, 'keeper takeProfit');
  const pc5 = evOf(rc5, IF, 'PositionClosed'); B = await sn.bot(id);
  ok('T4 TP: reason 4, proceeds >= cost*1.15, nOpen 0', pc5 && pc5.reason === 4n && pc5.proceeds >= (pc5.cost * (BPS + 1500n)) / BPS && B.nOpen === 0n, pc5 ? W(pc5.proceeds) + ' vs cost ' + W(pc5.cost) : '-');
  await invariants('post-tp');

  // ── T5 stopLoss en curva (el whale vende todo) ──
  const exp6 = await simBuy(PER - PER / 100n);
  await tx(snk, 'enter', [id, TOKEN, CURVE, NOROUTE, PER, pct(exp6, 90, 100)], null, 'enterCurve para SL');
  pos = await sn.position(id, TOKEN);
  await expectRevert('stopLoss sin caida', () => snk.close.staticCall(id, TOKEN, NOROUTE, 10000, 1n, 3), 'PriceNotReached', [IF]);
  const whBal = await tok.balanceOf(WH);
  await rawTx(WH, TOKEN, RI.encodeFunctionData('approve', [CURVE, whBal]), 0n, 'whale approve curva');
  await rawTx(WH, CURVE, SEL_SELL + AC.encode(['uint256', 'uint256', 'address'], [whBal, 0, WH]).slice(2), 0n, 'DUMP whale vende todo en la curva');
  const cap = (pos.cost * (BPS - 2000n)) / BPS;
  const floor = (cap * (BPS - 500n)) / BPS;
  let rc6 = null;
  try { rc6 = await tx(snk, 'close', [id, TOKEN, NOROUTE, 10000, 1n, 3], null, 'keeper stopLoss'); } catch (e) { log('    stopLoss fuera de ventana:', (e.shortMessage || e.message).slice(0, 80)); }
  if (rc6) { const pc6 = evOf(rc6, IF, 'PositionClosed'); ok('T5 SL: reason 3, proceeds <= cap y >= floor', pc6 && pc6.reason === 3n && pc6.proceeds <= cap && pc6.proceeds >= floor, pc6 ? W(pc6.proceeds) + ' cap ' + W(cap) : '-'); }
  else { const rcs = await tx(sn, 'sellPosition', [id, TOKEN, NOROUTE, 1n], null, 'maker sellPosition'); ok('T5 (alt) sellPosition del maker cerro (reason 2)', evOf(rcs, IF, 'PositionClosed').reason === 2n); }
  B = await sn.bot(id); ok('T5 sin posiciones abiertas', B.nOpen === 0n);
  await invariants('post-sl');

  // ── T6 enterPool / exit por router (V3 real) ──
  const Pnow = async () => { const s = await new ethers.Contract(POOL, ['function slot0() view returns (uint160,int24,uint16,uint16,uint16,uint8,bool)'], p).slot0(); const q2 = BigInt(s[0]); return (E * (2n ** 192n)) / (q2 * q2); };
  const quoteBuy = async (amountIn) => { const P0 = await Pnow(); return (amountIn * E) / P0; };
  const expP = await quoteBuy(PER);
  const rc7 = await tx(snk, 'enter', [id, PTOKEN, ethers.ZeroAddress, ROUTE, PER, pct(expP, 85, 100)], null, 'keeper enterPool NLYRA por router');
  const e7 = evOf(rc7, IF, 'Entered'); pos = await sn.position(id, PTOKEN);
  ok('T6 Entered pool: kind 0, venue 0, fee 0 (lo cobra el router), out >= minOut', e7 && e7.kind === 0n && e7.venue === ethers.ZeroAddress && e7.fee === 0n && pos.base === e7.amountOut && pos.kind === 0n);
  await expectRevert('enterCurve del MISMO token de pool (venue distinta)', () => snk.enter.staticCall(id, PTOKEN, CURVE, NOROUTE, PER, 1n), 'BadCurve', [IF]);
  const rc8 = await tx(snk, 'close', [id, PTOKEN, ROUTE, 10000, 1n, 0], null, 'keeper close pool 100%');
  ok('T6 exit pool cerro la posicion', evOf(rc8, IF, 'PositionClosed').reason === 1n && (await sn.bot(id)).nOpen === 0n);
  await invariants('post-pool');
  // bot solo-curva: enterPool -> SourceOff; bot solo-pool: enterCurve -> SourceOff
  const rcA = await tx(sn, 'openWithEth', [{ ...base, sources: 1 }, GAS], { value: V + GAS }, 'open solo curva'); const idA = evOf(rcA, IF, 'BotOpened').id; openIds.push(idA);
  await expectRevert('enterPool en bot solo-curva', () => snk.enter.staticCall(idA, PTOKEN, ethers.ZeroAddress, ROUTE, PER, 1n), 'SourceOff', [IF]);
  const rcB = await tx(sn, 'openWithEth', [{ ...base, sources: 2 }, GAS], { value: V + GAS }, 'open solo pool'); const idB = evOf(rcB, IF, 'BotOpened').id; openIds.push(idB);
  await expectRevert('enterCurve en bot solo-pool', () => snk.enter.staticCall(idB, TOKEN, CURVE, NOROUTE, PER, 1n), 'SourceOff', [IF]);
  // ETH suelto desde una cuenta cualquiera: rechazado
  await expectRevert('receive() desde una wallet cualquiera', () => o.sendTransaction({ to: SN, value: 1n }).then((t) => t.wait()), 'BadGrid', [IF]);

  // ── T7 topUp, setLimits, NoGas, stop, refundExpired, rescue ──
  await tx(sn, 'topUp', [id, E / 1000n], { value: E / 100n + E / 1000n }, 'maker topUp 0.01 + 0.001 gas');
  B = await sn.bot(id); ok('T7 topUp sumo capital y gas', B.quoteHeld > 0n && B.gasReserve > 0n);
  await tx(sn, 'setLimits', [id, PER * 2n, 0n, 3, 0, 0, 1], null, 'maker setLimits perTrade 0.02, 3 posiciones, sin SL/TP, solo curva');
  B = await sn.bot(id);
  ok('T7 setLimits aplicado', B.perTrade === PER * 2n && B.maxPerToken === PER * 2n && B.maxPositions === 3n && B.slBps === 0n && B.tpBps === 0n && B.sources === 1n);
  await expectRevert('setLimits desde otro', () => sno.setLimits.staticCall(id, PER, 0n, 1, 0, 0, 1), 'NotMaker', [IF]);
  await expectRevert('setLimits con sources 0', () => sn.setLimits.staticCall(id, PER, 0n, 1, 0, 0, 0), 'BadParams', [IF]);
  await expectRevert('stopLoss sin posicion (mode 3)', () => snk.close.staticCall(id, TOKEN, NOROUTE, 10000, 1n, 3), 'NoPosition', [IF]);
  const rc9 = await tx(sn, 'openWithEth', [base, 0n], { value: V }, 'openWithEth sin gas'); const id2 = evOf(rc9, IF, 'BotOpened').id; openIds.push(id2);
  const exp9 = await simBuy(PER - PER / 100n);
  await expectRevert('enterCurve sin reserva de gas', () => snk.enter.staticCall(id2, TOKEN, CURVE, NOROUTE, PER, pct(exp9, 80, 100)), 'NoGas', [IF]);
  const rc10 = await tx(sn, 'stop', [id], null, 'maker stop');
  const st10 = evOf(rc10, IF, 'BotStopped'); B = await sn.bot(id);
  ok('T7 stop: kind 0, status Stopped, quoteHeld 0, gasReserve 0, sin tokens', st10 && st10.kind === 0n && B.status === 1n && B.quoteHeld === 0n && B.gasReserve === 0n && st10.tokensReturned === 0n, st10 ? W(st10.quoteReturned) : '-');
  const bn = rc10.blockNumber;
  ok('T7 el maker cobro ETH (o quedo en pendingEth)', (await p.getBalance(w.address, bn)) > (await p.getBalance(w.address, bn - 1)) || (await sn.pendingEth(w.address)) > 0n);
  await expectRevert('stop dos veces', () => sn.stop.staticCall(id), 'NotOpen', [IF]);
  await expectRevert('enterCurve en bot cerrado', () => snk.enter.staticCall(id, TOKEN, CURVE, NOROUTE, PER, 1n), 'NotOpen', [IF]);
  openIds.splice(openIds.indexOf(id), 1);
  await invariants('post-stop');
  // stop con tokens adentro: devuelve el token sin vender
  await tx(sn, 'topUp', [id2, E / 500n], { value: E / 500n }, 'topUp solo gas al segundo');
  const exp11 = await simBuy(PER - PER / 100n);
  const rc11 = await tx(snk, 'enter', [id2, TOKEN, CURVE, NOROUTE, PER, pct(exp11, 80, 100)], null, 'enterCurve en el segundo');
  const bought = evOf(rc11, IF, 'Entered').amountOut;
  const tb0 = await tok.balanceOf(w.address);
  const rc12 = await tx(sn, 'stop', [id2], null, 'maker stop con token adentro');
  const st12 = evOf(rc12, IF, 'BotStopped');
  ok('T7 stop devolvio el token tal cual (tokensReturned 1, balance maker += base)', st12.tokensReturned === 1n && (await tok.balanceOf(w.address)) - tb0 === bought && (await sn.escrowed(TOKEN)) === 0n);
  openIds.splice(openIds.indexOf(id2), 1);
  const rc13 = await tx(sn, 'openWithEth', [{ ...base, expiry: expiry(700) }, 0n], { value: V }, 'open corto'); const id3 = evOf(rc13, IF, 'BotOpened').id;
  await expectRevert('stop por otro antes de vencer', () => sno.stop.staticCall(id3), 'NotExpired', [IF]);
  await rpc('evm_increaseTime', 800); await rpc('evm_mine');
  const rc14 = await tx(sno, 'stop', [id3], null, 'cualquiera stop (vencido)');
  ok('T7 refundExpired: kind 2, devolvio el ETH', evOf(rc14, IF, 'BotStopped').kind === 2n && (await sn.bot(id3)).status === 1n);
  for (const x of [idA, idB]) { await tx(sn, 'stop', [x], null, 'stop ' + x.slice(0, 10)); openIds.splice(openIds.indexOf(x), 1); }
  await invariants('final');
  ok('T7 rescue no puede sacar escrow (NothingToRefund)', await sn.rescue.staticCall(WETH, w.address).then(() => false, (e) => /NothingToRefund/.test(e.shortMessage || e.message) || (e.data && IF.parseError(e.data) && IF.parseError(e.data).name === 'NothingToRefund')));
  await expectRevert('setPonsFactory desde otro', () => sno.setPonsFactory.staticCall(ethers.ZeroAddress), 'NotOwner', [IF]);
  await tx(sn, 'setPonsFactory', [ethers.ZeroAddress], null, 'owner apaga curvas');
  const rc15 = await tx(sn, 'openWithEth', [base, GAS], { value: V + GAS }, 'open para probar curvas apagadas'); const id4 = evOf(rc15, IF, 'BotOpened').id;
  await expectRevert('enterCurve con curvas apagadas', () => snk.enter.staticCall(id4, TOKEN, CURVE, NOROUTE, PER, 1n), 'BadCurve', [IF]);
  await tx(sn, 'stop', [id4], null, 'stop');

  // ── T8 las correcciones de la revision de seguridad (20/9) ──
  function compileMini(src, name) { const solc = require('solc'); const out = JSON.parse(solc.compile(JSON.stringify({ language: 'Solidity', sources: { 'M.sol': { content: src } }, settings: { optimizer: { enabled: true, runs: 1 }, evmVersion: 'cancun', outputSelection: { '*': { '*': ['abi', 'evm.bytecode.object', 'evm.deployedBytecode.object'] } } } }))); const c = out.contracts['M.sol'][name]; return { abi: c.abi, bin: '0x' + c.evm.bytecode.object, deployed: '0x' + c.evm.deployedBytecode.object }; }
  await tx(sn, 'setPonsFactory', [PONS_FACTORY], null, 'owner re-enciende curvas');
  const rc20 = await tx(sn, 'openWithEth', [{ ...base, maxPositions: 3 }, GAS], { value: V + GAS }, 'open para T8'); const id8 = evOf(rc20, IF, 'BotOpened').id; openIds.push(id8);
  // F1: una curva falsa que "dice" token()/factory() no esta en el registro de la factory -> BadCurve antes de gastar
  const FK = compileMini('// SPDX-License-Identifier: MIT\npragma solidity 0.8.24;\ncontract FakeCurve { address public token; address public factory; constructor(address t, address f) { token = t; factory = f; } function buy(uint256, uint256, address) external payable returns (uint256) { return 0; } function graduated() external pure returns (bool) { return false; } receive() external payable {} }', 'FakeCurve');
  const fake = await (await new ethers.ContractFactory(FK.abi, FK.bin, o).deploy(TOKEN, PONS_FACTORY, { nonce: await nonceOf(o.address) })).waitForDeployment(); NONCE[o.address] += 1;
  const FAKE = await fake.getAddress();
  await expectRevert('F1 enter con curva FALSA (token()/factory() correctos, sin registro)', () => snk.enter.staticCall(id8, TOKEN, FAKE, NOROUTE, PER, 1n), 'BadCurve', [IF]);
  // F2: un token que deja de transferirse no traba el stop; queda reclamable
  const exp21 = await simBuy(PER - PER / 100n);
  const rc21 = await tx(snk, 'enter', [id8, TOKEN, CURVE, NOROUTE, PER, pct(exp21, 80, 100)], null, 'enter para F2'); const got21 = evOf(rc21, IF, 'Entered').amountOut;
  const origCode = await p.getCode(TOKEN);
  const BT = compileMini('// SPDX-License-Identifier: MIT\npragma solidity 0.8.24;\ncontract BadToken { function transfer(address, uint256) external pure returns (bool) { revert("nope"); } function balanceOf(address) external pure returns (uint256) { return 1e40; } function approve(address, uint256) external pure returns (bool) { return true; } }', 'BadToken');
  await rpc('anvil_setCode', TOKEN, BT.deployed);
  const wq0 = await p.getBalance(w.address);
  const rc22 = await tx(sn, 'stop', [id8], null, 'maker stop con token que revierte transfer');
  const st22 = evOf(rc22, IF, 'BotStopped'), stuck = evOf(rc22, IF, 'TokenStuck');
  ok('F2 stop no se traba: BotStopped, tokensReturned 0, TokenStuck(base), ETH devuelto', st22 && st22.tokensReturned === 0n && stuck && stuck.base === got21 && (await p.getBalance(w.address)) > wq0 - E / 100n, stuck ? 'stuck ' + stuck.base : 'sin TokenStuck');
  ok('F2 la posicion sigue escrowada (base intacta)', (await sn.position(id8, TOKEN)).base === got21 && (await sn.escrowed(TOKEN)) >= got21);
  await expectRevert('F2 claimToken mientras el token sigue roto', () => sn.claimToken.staticCall(id8, TOKEN), 'TransferFailed', [IF]);
  await expectRevert('F2 claimToken desde otro', () => sno.claimToken.staticCall(id8, TOKEN), 'NotMaker', [IF]);
  await rpc('anvil_setCode', TOKEN, origCode);
  const tb8 = await tok.balanceOf(w.address);
  await tx(sn, 'claimToken', [id8, TOKEN], null, 'maker claimToken con el token sano');
  ok('F2 claimToken entrego los tokens y limpio el escrow', (await tok.balanceOf(w.address)) - tb8 === got21 && (await sn.position(id8, TOKEN)).base === 0n);
  await expectRevert('F2 claimToken dos veces', () => sn.claimToken.staticCall(id8, TOKEN), 'NoPosition', [IF]);
  openIds.splice(openIds.indexOf(id8), 1);
  await invariants('post-F2');
  // F3: compra recortada por la capacidad de la curva -> el sobrante vuelve al presupuesto, fee sobre lo gastado, sin ETH suelto
  await rpc('anvil_setBalance', w.address, '0x' + (500n * E).toString(16));
  const BIG = 100n * E;
  const rc23 = await tx(sn, 'openWithEth', [{ ...base, perTrade: BIG, maxPerToken: BIG, maxPositions: 1 }, GAS], { value: BIG + GAS }, 'open 100 ETH para F3'); const id9 = evOf(rc23, IF, 'BotOpened').id; openIds.push(id9);
  const ft9 = await weth.balanceOf(FEE_TO);
  let rc24 = null; try { rc24 = await tx(snk, 'enter', [id9, TOKEN, CURVE, NOROUTE, BIG, 1n], null, 'enter 100 ETH (la curva recorta)'); } catch (e) { log('    enter 100 ETH revirtio:', (e.shortMessage || e.message).slice(0, 100)); }
  if (rc24) {
    const e9 = evOf(rc24, IF, 'Entered'); const B9 = await sn.bot(id9); const feeGot = (await weth.balanceOf(FEE_TO)) - ft9;
    ok('F3 la curva recorto: cost < 100 ETH y el sobrante volvio a quoteHeld', e9.amountIn < BIG && B9.quoteHeld === BIG - e9.amountIn, W(e9.amountIn) + ' gastados, quoteHeld ' + W(B9.quoteHeld));
    ok('F3 fee = 1 % del gasto efectivo (cost = spend + fee)', feeGot === e9.fee && e9.fee <= (e9.amountIn * 100n) / BPS + 1n && e9.fee >= (e9.amountIn * 100n) / BPS - 1n, 'fee ' + W(feeGot) + ' de ' + W(e9.amountIn));
    ok('F3 sin ETH suelto en el contrato', (await p.getBalance(SN)) === 0n);
    let grad = false; try { grad = BigInt(await p.call({ to: CURVE, data: '0xe7c2b772' })) !== 0n; } catch (_) {}
    log('    curva graduada tras la compra grande:', grad);
    if (grad) { await expectRevert('F4 enter en curva graduada', () => snk.enter.staticCall(id9, TOKEN, CURVE, NOROUTE, E / 100n, 1n), 'BadCurve', [IF]); }
    await tx(sn, 'stop', [id9], null, 'stop F3');
  }
  openIds.splice(openIds.indexOf(id9), 1);
  await invariants('post-F3');

  const pass = R.filter((r) => r.c).length, fail = R.filter((r) => !r.c).length;
  log('\n==== ' + pass + ' OK · ' + fail + ' FALLAN ====');
  if (fail) process.exit(1);
})().catch((e) => { console.error('ERROR', e); process.exit(2); });
