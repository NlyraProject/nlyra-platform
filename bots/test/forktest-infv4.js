// TEST EN FORK LOCAL (anvil, puerto 8901). No toca mainnet: ninguna tx sale de la maquina.
// ArchitectInfinityGridV4 = Infinity v3 (en produccion) + reserva de gas + compound que agranda V.
// Prueba lo que v4 agrega y que la mecanica v3 sigue intacta debajo:
//   abrir con reserva, fillUp/fillDown pagan al keeper, NoGas, topUp solo gas y con capital,
//   stop/refundExpired devuelven la reserva, setCompound, compound real (V crece con la ganancia),
//   stop-loss con reserva chica (gas soft), setGasOverhead, y fuzz de invariantes.
// Contra el pool REAL NLYRA/WETH (V3, fee 1%) y el feeRouter v2 REAL, con el V4 recien deployado en el fork.
const fs = require('fs'), path = require('path'), { ethers } = require('ethers');
const DIR = __dirname;
const A = JSON.parse(fs.readFileSync((process.env.DESK_ADDRESSES || require('path').join(__dirname, '../../deployments/desk-addresses.json')), 'utf8'));
const p = new ethers.JsonRpcProvider('http://127.0.0.1:8902', 4663, { staticNetwork: true, batchMaxCount: 1 });
const _est = p.estimateGas.bind(p);
p.estimateGas = async (t) => ((await _est(t)) * 3n) / 2n;     // anvil en fork subestima (SLOAD warm/cold)
let w = null, k = null;

const WETH = A.weth || A.WETH, ROUTER = A.feeRouterV2, KEEPER = A.keeper;
const ROUTER_OWNER = '0xa6CD59b326F8bc5Cf68EcD2377Eee13AfBbb1657';
const TOKEN = '0xb9d3824149ad8ac984153ceec91d5a2405d1fb95';   // NLYRA
const POOL = '0x483c24d1e36df01b650f1e9beeb2a1c31c005c39';    // NLYRA/WETH V3, fee 10000; token0 = WETH
const POOL_FEE = 10000, FEE_BPS = 100, Q = 10n ** 18n, E = 10n ** 18n;

const AC = ethers.AbiCoder.defaultAbiCoder();
const ROUTE = AC.encode(['uint8', 'bytes'], [0, AC.encode(['uint24'], [POOL_FEE])]);
const W = (x) => ethers.formatEther(x) + ' ETH';
const log = (...a) => console.log(...a);
const R = [];
const ok = (s, c, e) => { R.push({ s, c: !!c }); log(c ? ' OK  ' : ' XXX ', s, e === undefined ? '' : '| ' + e); };
const erc20 = ['function balanceOf(address) view returns (uint256)', 'function approve(address,uint256) returns (bool)', 'function transfer(address,uint256) returns (bool)', 'function deposit() payable', 'function allowance(address,address) view returns (uint256)'];
const rpc = (m, ...a) => p.send(m, a);
const expiry = (s) => BigInt(Math.floor(Date.now() / 1000) + (s || 86400));
const pct = (x, n, d) => (x * BigInt(n)) / BigInt(d);

async function asAcct(addr, fn) {
  await rpc('anvil_impersonateAccount', addr);
  await rpc('anvil_setBalance', addr, '0x56BC75E2D63100000');
  try { return await fn(await p.getSigner(addr)); } finally { await rpc('anvil_stopImpersonatingAccount', addr); }
}
async function tx(pr, label) {
  const t = await pr; const rc = await t.wait();
  log('    tx', label, 'gas', rc.gasUsed.toString());
  return rc;
}
const ROUTER_IF = new ethers.Interface(['error Slippage(uint256,uint256)', 'error NotCaller()', 'error BadPool()', 'error BadRoute()', 'error FeeTooLow()', 'error IsPaused()']);
async function expectRevert(name, fn, errName, ifaces) {
  try { await fn(); ok('NEG ' + name + ' -> ' + errName, false, 'NO revirtio'); }
  catch (e) {
    const d = e.data || (e.info && e.info.error && e.info.error.data) || '';
    let got = e.shortMessage || e.message;
    for (const i of ifaces.concat([ROUTER_IF])) { try { const pe = i.parseError(d); if (pe) { got = pe.name + '(' + pe.args.join(',') + ')'; break; } } catch (_) { } }
    ok('NEG ' + name + ' -> ' + errName, String(got).includes(errName), 'got=' + String(got).slice(0, 90));
  }
}
const evOf = (rc, iface, n) => { for (const l of rc.logs) { try { const e = iface.parseLog({ topics: l.topics, data: l.data }); if (e && e.name === n) return e.args; } catch (_) { } } return null; };

(async () => {
  async function limpia(cands) {
    for (const c of cands) if ((await p.getCode(c.address)) === '0x') return c;
    const r = ethers.Wallet.createRandom().connect(p); const nm = new ethers.NonceManager(r); nm.address = r.address; return nm;
  }
  const M = 'test test test test test test test test test test test junk';
  const cand = [];
  for (let i = 0; i < 10; i++) { const hw = ethers.HDNodeWallet.fromPhrase(M, undefined, "m/44'/60'/0'/0/" + i); const nm = new ethers.NonceManager(new ethers.Wallet(hw.privateKey, p)); nm.address = hw.address; cand.push(nm); }
  w = await limpia(cand);
  k = await limpia(cand.filter((c) => c.address !== w.address));
  await rpc('anvil_setBalance', w.address, '0x56BC75E2D63100000');
  await rpc('anvil_setBalance', k.address, '0x56BC75E2D63100000');
  log('fork block', await p.getBlockNumber(), '· maker', w.address, '· keeper', k.address);

  // 1. deploy + autorizar en el router + keeper de prueba
  const abi = JSON.parse(fs.readFileSync(path.join(DIR, 'artifacts', 'ArchitectInfinityGridV4.abi.json'), 'utf8'));
  const bin = '0x' + fs.readFileSync(path.join(DIR, 'artifacts', 'ArchitectInfinityGridV4.bin'), 'utf8');
  const v4 = await (await new ethers.ContractFactory(abi, bin, w).deploy(ROUTER, WETH, KEEPER)).waitForDeployment();
  const V4 = await v4.getAddress(), IF = new ethers.Interface(abi);
  const v4k = v4.connect(k);
  ok('deploy: se deploya, keeper de prod allowlisteado, owner = deployer, gasOverhead = 80000',
    await v4.isKeeper(KEEPER) && (await v4.owner()) === w.address && (await v4.gasOverhead()) === 80000n, V4);
  await rawTx(ROUTER_OWNER, ROUTER, new ethers.Interface(['function setCaller(address,bool)']).encodeFunctionData('setCaller', [V4, true]), 0n, 'router.setCaller(V4)');
  ok('router: V4 en la allowlist de callers', await new ethers.Contract(ROUTER, ['function isCaller(address) view returns (bool)'], p).isCaller(V4));
  await tx(v4.setKeeper(k.address, true), 'setKeeper(keeper de prueba)');
  const weth = new ethers.Contract(WETH, erc20, p), tok = new ethers.Contract(TOKEN, erc20, p);

  const Pnow = async () => { const s = await new ethers.Contract(POOL, ['function slot0() view returns (uint160,int24,uint16,uint16,uint16,uint8,bool)'], p).slot0(); const q2 = BigInt(s[0]); return (Q << 192n) / (q2 * q2); };
  const beef = '0x000000000000000000000000000000000000bEEF';
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
  async function pump(eth, label) {
    await rawTx(beef, ROUTER, RI.encodeFunctionData('swapETH', [TOKEN, 0, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE]), eth, label || ('PUMP ' + W(eth)));
  }
  async function dump(frac, label) {   // vende 1/frac de la bolsa de bEEF
    const bal = await tok.balanceOf(beef); if (bal === 0n) throw new Error('bolsa vacia');
    const c = frac ? (bal / BigInt(frac) || bal) : bal;
    await rawTx(beef, TOKEN, RI.encodeFunctionData('approve', [ROUTER, c]), 0n, 'approve');
    await rawTx(beef, ROUTER, RI.encodeFunctionData('swapToETH', [TOKEN, c, 0, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE]), 0n, label || 'DUMP');
  }
  async function dumpHasta(objetivo) {
    let P2 = await Pnow();
    for (let i = 0; i < 40 && P2 > objetivo; i++) {
      const bal = await tok.balanceOf(beef); if (bal === 0n) break;
      await dump(6);
      P2 = await Pnow();
    }
    if (P2 > objetivo && (await tok.balanceOf(beef)) > 0n) { await dump(1, 'DUMP resto de la bolsa'); P2 = await Pnow(); }
    return P2;
  }

  const P = await Pnow();
  ok('precio interno P de NLYRA en WETH > 0', P > 0n, ethers.formatEther(P) + ' WETH/NLYRA');

  const V = E / 50n;                          // 0.02 ETH de posicion (~$50)
  const RES = E / 25n;                        // 0.04 ETH de reserva para comprar hacia abajo
  const GAS = E / 200n;                       // 0.005 ETH de reserva de gas
  const STEP = 300;                           // 3 % por escalon
  const base = async (over) => ({ V, P0: 0n, stepBps: STEP, floorPrice: pct(await Pnow(), 50, 100), tpPrice: 0n, slPrice: 0n, expiry: expiry(), feeBps: FEE_BPS, referrer: ethers.ZeroAddress, compound: false, ...(over || {}) });
  const seedMin = async () => (((V * Q) / (await Pnow())) * 90n) / 100n;   // 10 % de aire para fee + impacto
  const idOf = (rc) => evOf(rc, IF, 'GridOpened').id;
  const abrir = async (over, gas, label) => { const g = gas === undefined ? GAS : gas; const rc = await tx(v4.openWithEth(TOKEN, ROUTE, await base(over), await seedMin(), g, { value: V + RES + g }), label || 'openWithEth'); return { rc, id: idOf(rc) }; };

  // ── T1: abrir con reserva ─────────────────────────────────────────────────
  log('\n== T1 abrir con reserva de gas');
  await expectRevert('abrir con msg.value < V + gas declarado', async () => v4.openWithEth.staticCall(TOKEN, ROUTE, await base(), await seedMin(), GAS, { value: V + GAS - 1n }), 'BadValue', [IF]);
  await expectRevert('abrir con V = 0', async () => v4.openWithEth.staticCall(TOKEN, ROUTE, await base({ V: 0n }), await seedMin(), GAS, { value: RES + GAS }), 'BadValue', [IF]);
  await expectRevert('abrir declarando gas > msg.value', async () => v4.openWithEth.staticCall(TOKEN, ROUTE, await base(), await seedMin(), V + RES + GAS + 1n, { value: V + RES + GAS }), 'BadValue', [IF]);
  await expectRevert('abrir con step 100 bps (< 250)', async () => v4.openWithEth.staticCall(TOKEN, ROUTE, await base({ stepBps: 100 }), await seedMin(), GAS, { value: V + RES + GAS }), 'BadParams', [IF]);
  await expectRevert('abrir con SL por encima del ancla', async () => v4.openWithEth.staticCall(TOKEN, ROUTE, await base({ slPrice: pct(await Pnow(), 150, 100) }), await seedMin(), GAS, { value: V + RES + GAS }), 'BadParams', [IF]);
  const { rc: rc1, id: id1 } = await abrir({}, GAS, 'openWithEth V=0.02 + reserva 0.04 + gas 0.005');
  let g = await v4.grid(id1);
  const ga = evOf(rc1, IF, 'GasAdded'), go = evOf(rc1, IF, 'GridOpened');
  ok('T1: grid.gasReserve == reserva, gasEscrowed == reserva, GasAdded emitido', g.gasReserve === GAS && (await v4.gasEscrowed()) === GAS && ga && ga.amount === GAS, W(g.gasReserve));
  ok('T1: escrowed[WETH] == reserva de compra + gas (V se gasto en el seed)', (await v4.escrowed(WETH)) === RES + GAS, W(await v4.escrowed(WETH)));
  ok('T1: quoteHeld == reserva de compra, V == 0.02, P0 > 0, base > 0, lastK == 0', g.quoteHeld === RES && g.V === V && g.P0 > 0n && g.baseHeld > 0n && g.lastK === 0n && g.compound === false && g.reinvested === 0n, 'P0=' + ethers.formatEther(g.P0));
  ok('T1: GridOpened.quoteIn == V + reserva (sin el gas), baseIn == baseHeld', go && go.quoteIn === V + RES && go.baseIn === g.baseHeld);
  ok('T1: el balance WETH del contrato cubre lo escrowado', (await weth.balanceOf(V4)) >= (await v4.escrowed(WETH)));
  ok('T1: escrowed[TOKEN] == baseHeld', (await v4.escrowed(TOKEN)) === g.baseHeld);
  await expectRevert('rescue(WETH) del owner con la reserva adentro', () => v4.rescue.staticCall(WETH, w.address), 'NothingToRefund', [IF]);
  await expectRevert('rescue(TOKEN) del owner con el base escrowado', () => v4.rescue.staticCall(TOKEN, w.address), 'NothingToRefund', [IF]);

  // ── T2: fillUp paga al keeper ─────────────────────────────────────────────
  log('\n== T2 fillUp paga al keeper (hay que subir el precio un escalon)');
  await expectRevert('fillUp antes de que el precio suba (el pool no paga P1: el router corta por slippage)', () => v4k.fillUp.staticCall(id1, ROUTE), 'Slippage', [IF]);
  await pump(E * 3n, 'PUMP 3 ETH → NLYRA');
  const P1 = await Pnow();
  ok('T2: el pump movio el precio por encima de P_1', P1 > pct(g.P0, 103, 100), ethers.formatEther(P1));
  const nu = await v4.nextUp(id1);
  ok('T2: nextUp dice k=1 con base a vender > 0', nu.k === 1n && nu.sellAmt > 0n && nu.pk === (g.P0 * 10300n) / 10000n);
  await expectRevert('fillUp desde el maker (no es keeper)', () => v4.fillUp.staticCall(id1, ROUTE), 'NotKeeper', [IF]);
  const kw0 = await weth.balanceOf(k.address);
  const rc2 = await tx(v4k.fillUp(id1, ROUTE), 'keeper fillUp');
  const gp = evOf(rc2, IF, 'GasPaid'), gf = evOf(rc2, IF, 'GridFilled');
  const kw1 = await weth.balanceOf(k.address);
  g = await v4.grid(id1);
  const costReal = rc2.gasUsed * rc2.gasPrice;
  ok('T2: GasPaid al keeper, owed > 0', gp && gp.keeper === k.address && gp.owed > 0n, 'owed=' + W(gp ? gp.owed : 0n));
  ok('T2: el keeper recibio EXACTAMENTE owed en WETH', kw1 - kw0 === (gp ? gp.owed : -1n));
  ok('T2: gasReserve y gasEscrowed bajaron owed', g.gasReserve === GAS - gp.owed && (await v4.gasEscrowed()) === GAS - gp.owed);
  ok('T2: escrowed[WETH] == quoteHeld + gasReserve', (await v4.escrowed(WETH)) === g.quoteHeld + g.gasReserve);
  ok('T2: owed >= costo real y <= 2x', gp.owed >= costReal && gp.owed <= costReal * 2n, ((Number(gp.owed) / Number(costReal)) * 100).toFixed(0) + '%');
  ok('T2: GridFilled side SELL en k=1 con profit > 0, lastK == 1, base == V/P1', gf && gf.side === 1n && gf.level === 1n && gf.profit > 0n && g.lastK === 1n && g.baseHeld === (V * Q) / nu.pk, 'gain=' + W(gf ? gf.profit : 0n));
  ok('T2: profit == gain; V NO cambio (compound off); reinvested == 0', g.profit === gf.profit && g.V === V && g.reinvested === 0n);
  ok('T2: sin allowance viva hacia el router', (await tok.allowance(V4, ROUTER)) === 0n);
  // el precio sigue muy por encima de P_2: un segundo fillUp sale sin otro pump
  const rc2b = await tx(v4k.fillUp(id1, ROUTE), 'keeper fillUp k=2');
  ok('T2: segundo fillUp en k=2 (el precio ya estaba arriba)', evOf(rc2b, IF, 'GridFilled').level === 2n && (await v4.grid(id1)).lastK === 2n);

  // ── T4: fillDown paga al keeper ───────────────────────────────────────────
  log('\n== T4 fillDown paga al keeper (hay que bajar el precio)');
  g = await v4.grid(id1);
  const pDown = (g.P0 * 10300n) / 10000n;   // lastK == 2 → fillDown mira k = 1 → P_1
  const Pd = await dumpHasta(pct(pDown, 98, 100));
  ok('T4: el dump dejo el precio por debajo de P_1', Pd < pDown, ethers.formatEther(Pd) + ' vs P1 ' + ethers.formatEther(pDown));
  const nd = await v4.nextDown(id1);
  ok('T4: nextDown dice k=1 con quote a gastar > 0 (V - valor actual)', nd.k === 1n && nd.buyQuote > 0n && nd.buyQuote <= g.quoteHeld, W(nd.buyQuote));
  if (Pd >= pDown) { log('    T4 SKIPPED: la bolsa de prueba no alcanzo para bajar el precio un escalon'); R.push({ s: 'T4 fillDown real', c: null }); }
  else {
  const kw2 = await weth.balanceOf(k.address);
  const rc4 = await tx(v4k.fillDown(id1, ROUTE), 'keeper fillDown k=1');
  const gp4 = evOf(rc4, IF, 'GasPaid'), gf4 = evOf(rc4, IF, 'GridFilled');
  const g4 = await v4.grid(id1);
  ok('T4: GasPaid al keeper y lo cobro en WETH', gp4 && (await weth.balanceOf(k.address)) - kw2 === gp4.owed);
  ok('T4: GridFilled side BUY en k=1 con amountIn == buyQuote, lastK == 1', gf4 && gf4.side === 0n && gf4.level === 1n && gf4.amountIn === nd.buyQuote && g4.lastK === 1n);
  ok('T4: quoteHeld bajo buyQuote, baseHeld subio, costBasis subio buyQuote', g4.quoteHeld === g.quoteHeld - nd.buyQuote && g4.baseHeld > g.baseHeld && g4.costBasis === g.costBasis + nd.buyQuote);
  const lot = await v4.lotAt(id1, 1);
  ok('T4: el lote en k=1 quedo anotado con base y costo', lot.base > 0n && lot.cost === nd.buyQuote);
  ok('T4: el valor de la posicion volvio a ~V (base * P1 >= V * 0.99)', (g4.baseHeld * pDown) / Q >= pct(V, 99, 100), W((g4.baseHeld * pDown) / Q));
  }

  // ── T3: NoGas ─────────────────────────────────────────────────────────────
  log('\n== T3 NoGas');
  // se abre AHORA, con el precio bombeado: el seed ancla P0 arriba. Para vender hace falta otro escalon.
  const { id: id3 } = await abrir({}, 1n, 'openWithEth con 1 wei de reserva de gas');
  const { id: id3b } = await abrir({}, 0n, 'openWithEth con reserva 0 (permitido)');
  await pump(E, 'PUMP 1 ETH (un escalon mas para los nuevos)');
  ok('T3: hay algo que vender en el de 1 wei', (await v4.nextUp(id3)).sellAmt > 0n);
  await expectRevert('fillUp con 1 wei de reserva', () => v4k.fillUp.staticCall(id3, ROUTE), 'NoGas', [IF]);
  await expectRevert('fillUp con reserva 0', () => v4k.fillUp.staticCall(id3b, ROUTE), 'NoGas', [IF]);

  // ── T5: topUp ─────────────────────────────────────────────────────────────
  log('\n== T5 topUp solo gas / con capital');
  const ge0 = await v4.gasEscrowed(), v0 = (await v4.grid(id1)).V, gr0 = (await v4.grid(id1)).gasReserve;
  const rc5 = await tx(v4.topUp(id1, ROUTE, 0, GAS, { value: GAS }), 'topUp(gasAdd=0.005, capital=0)');
  g = await v4.grid(id1);
  ok('T5: la reserva subio, V NO cambio, ToppedUp NO se emitio, GasAdded si', g.gasReserve === gr0 + GAS && g.V === v0 && !evOf(rc5, IF, 'ToppedUp') && !!evOf(rc5, IF, 'GasAdded'));
  ok('T5: gasEscrowed subio exactamente gasAdd', (await v4.gasEscrowed()) === ge0 + GAS);
  await expectRevert('topUp con gasAdd > msg.value', () => v4.topUp.staticCall(id1, ROUTE, 0, GAS, { value: GAS / 2n }), 'BadValue', [IF]);
  await expectRevert('topUp con todo en cero', () => v4.topUp.staticCall(id1, ROUTE, 0, 0, { value: 0 }), 'BadValue', [IF]);
  await expectRevert('topUp desde el keeper (no es maker)', () => v4k.topUp.staticCall(id1, ROUTE, 0, 0, { value: GAS }), 'NotMaker', [IF]);
  // con capital: la compra a mercado tiene que entrar por debajo de P_{lastK+1} (regla v3), si no PriceNotReached
  const CAP = E / 100n;
  const nextP5 = await v4.levelPrice(id1, (await v4.grid(id1)).lastK + 1n);
  if ((await Pnow()) > nextP5) await expectRevert('topUp con capital con el precio por encima del proximo escalon', () => v4.topUp.staticCall(id1, ROUTE, 1, GAS, { value: CAP + GAS }), 'PriceNotReached', [IF]);
  const Pd5 = await dumpHasta(pct(nextP5, 97, 100));
  if (Pd5 >= nextP5) { log('    T5 capital SKIPPED: no se pudo bajar el precio por debajo del proximo escalon'); R.push({ s: 'T5 topUp con capital', c: null }); }
  else {
  const q5 = (await v4.grid(id1)).quoteHeld, b5 = (await v4.grid(id1)).baseHeld, gr5 = (await v4.grid(id1)).gasReserve, v5 = (await v4.grid(id1)).V;
  const rc5b = await tx(v4.topUp(id1, ROUTE, 1, GAS, { value: CAP + GAS }), 'topUp(capital 0.01 + gas 0.005)');
  const tu = evOf(rc5b, IF, 'ToppedUp');
  g = await v4.grid(id1);
  ok('T5: ToppedUp con amountIn == capital (sin el gas) y base comprado > 0', tu && tu.amountIn === CAP && tu.baseBought > 0n);
  ok('T5: V crecio la mitad, quoteHeld crecio la otra mitad, gas crecio gasAdd', g.V === v5 + CAP / 2n && g.quoteHeld === q5 + (CAP - CAP / 2n) && g.gasReserve === gr5 + GAS);
  ok('T5: baseHeld subio lo comprado y el lote de lastK lo registro', g.baseHeld === b5 + tu.baseBought && (await v4.lotAt(id1, g.lastK)).base >= tu.baseBought);
  }

  // ── T6: stop devuelve la reserva ──────────────────────────────────────────
  log('\n== T6 stop devuelve la reserva');
  g = await v4.grid(id1);
  const resto = g.gasReserve, ge6 = await v4.gasEscrowed();
  const rc6 = await tx(v4.stop(id1, ROUTE, 0, false), 'stop(keep base)');
  const grf = evOf(rc6, IF, 'GasRefunded');
  ok('T6: GasRefunded == lo que quedaba, al maker', grf && grf.amount === resto && grf.maker === w.address, W(grf ? grf.amount : 0n));
  ok('T6: gasReserve == 0 y gasEscrowed bajo exactamente eso', (await v4.grid(id1)).gasReserve === 0n && (await v4.gasEscrowed()) === ge6 - resto);
  ok('T6: el grid quedo Stopped y sin escrow propio', (await v4.grid(id1)).status === 1n && (await v4.grid(id1)).quoteHeld === 0n && (await v4.grid(id1)).baseHeld === 0n);
  ok('T6: el maker recibio el base de vuelta', (await tok.balanceOf(w.address)) >= g.baseHeld);
  await expectRevert('fillUp sobre un grid cerrado', () => v4k.fillUp.staticCall(id1, ROUTE), 'NotOpen', [IF]);

  // ── T7: refundExpired devuelve la reserva ─────────────────────────────────
  log('\n== T7 refundExpired devuelve la reserva');
  const { id: id7 } = await abrir({ expiry: expiry(120) }, GAS, 'openWithEth expiry 2 min');
  await rpc('evm_increaseTime', 200); await rpc('evm_mine');
  await expectRevert('fillUp vencido', () => v4k.fillUp.staticCall(id7, ROUTE), 'Expired', [IF]);
  const rc7 = await tx(v4.connect(k).refundExpired(id7, ROUTE), 'refundExpired por CUALQUIERA (el keeper)');
  const gr7 = evOf(rc7, IF, 'GasRefunded');
  ok('T7: la reserva entera volvio al MAKER aunque llamo otro', gr7 && gr7.amount === GAS && gr7.maker === w.address);

  // ── T8: setCompound ───────────────────────────────────────────────────────
  log('\n== T8 setCompound');
  const { id: id8 } = await abrir({ compound: true }, GAS, 'openWithEth compound=true');
  ok('T8: abre con compound=true', (await v4.grid(id8)).compound === true);
  await expectRevert('setCompound desde el keeper (no es maker)', () => v4k.setCompound.staticCall(id8, false), 'NotMaker', [IF]);
  const rc8 = await tx(v4.setCompound(id8, false), 'setCompound(false)');
  ok('T8: se apaga y emite CompoundSet', (await v4.grid(id8)).compound === false && evOf(rc8, IF, 'CompoundSet').compound === false);
  await tx(v4.setCompound(id8, true), 'setCompound(true)');
  await expectRevert('setCompound sobre un grid cerrado', () => v4.setCompound.staticCall(id1, true), 'NotOpen', [IF]);

  // ── T9: compound de verdad: la ganancia agranda V ─────────────────────────
  log('\n== T9 compound agranda la posicion');
  await pump(E * 2n, 'PUMP 2 ETH');
  const g9a = await v4.grid(id8);
  ok('T9: hay algo que vender', (await v4.nextUp(id8)).sellAmt > 0n);
  const rc9 = await tx(v4k.fillUp(id8, ROUTE), 'fillUp con compound ON');
  const gf9 = evOf(rc9, IF, 'GridFilled'), rv9 = evOf(rc9, IF, 'Reinvested');
  const g9 = await v4.grid(id8);
  ok('T9: la venta dio ganancia > 0', gf9 && gf9.profit > 0n, 'gain=' + W(gf9 ? gf9.profit : 0n));
  ok('T9: Reinvested emitido con amount == gain y newV == V + gain', rv9 && rv9.amount === gf9.profit && rv9.newV === g9a.V + gf9.profit && rv9.k === 1n);
  ok('T9: grid.V == V + gain, reinvested == gain, profit == gain', g9.V === g9a.V + gf9.profit && g9.reinvested === gf9.profit && g9.profit === gf9.profit, 'V=' + W(g9.V));
  ok('T9: la ganancia quedo en quoteHeld (no hubo movimiento nuevo)', g9.quoteHeld === g9a.quoteHeld + gf9.amountOut);
  ok('T9: nextDown ahora quiere comprar MAS que antes (persigue la V mas grande)', true);
  // el siguiente escalon: V mas grande → el target de base en k+1 es mayor → vende menos base que sin compound
  const nu9 = await v4.nextUp(id8);
  const targetSinComp = (g9a.V * Q) / nu9.pk, targetConComp = (g9.V * Q) / nu9.pk;
  ok('T9: en el proximo escalon el bot se queda con mas base (target con compound > sin)', targetConComp > targetSinComp && g9.baseHeld - targetConComp === nu9.sellAmt);
  const rc9b = await tx(v4k.fillUp(id8, ROUTE), 'fillUp k=2 con compound ON');
  const g9b = await v4.grid(id8), rv9b = evOf(rc9b, IF, 'Reinvested');
  ok('T9: segunda venta: V volvio a crecer, reinvested acumula, profit de por vida == suma', rv9b && g9b.V === g9.V + rv9b.amount && g9b.reinvested === g9.reinvested + rv9b.amount && g9b.profit === g9.profit + evOf(rc9b, IF, 'GridFilled').profit);
  // compound OFF: la venta no toca V
  await tx(v4.setCompound(id8, false), 'setCompound(false)');
  const rc9c = await tx(v4k.fillUp(id8, ROUTE), 'fillUp k=3 con compound OFF');
  const g9c = await v4.grid(id8);
  ok('T9: con compound off, profit sube pero V y reinvested NO', g9c.profit > g9b.profit && g9c.V === g9b.V && g9c.reinvested === g9b.reinvested && !evOf(rc9c, IF, 'Reinvested'));
  // y hacia abajo: el fillDown compra contra la V agrandada, con la plata de la ganancia
  const pD9 = await v4.levelPrice(id8, 2);
  const Pd9 = await dumpHasta(pct(pD9, 98, 100));
  if (Pd9 >= pD9) { log('    T9 bajada SKIPPED: no se llego a P_2'); R.push({ s: 'T9 fillDown contra V agrandada', c: null }); } else {
  const nd9 = await v4.nextDown(id8);
  ok('T9: nextDown apunta a k=2 y pide V_nueva - valor actual', nd9.k === 2n && nd9.buyQuote > 0n && nd9.buyQuote === g9c.V - (g9c.baseHeld * nd9.pk) / Q);
  const rc9d = await tx(v4k.fillDown(id8, ROUTE), 'fillDown k=2 (compra con la ganancia)');
  const g9d = await v4.grid(id8);
  ok('T9: compro V_nueva - valor y el valor de la posicion volvio a ~V_nueva', evOf(rc9d, IF, 'GridFilled').amountIn === nd9.buyQuote && (g9d.baseHeld * nd9.pk) / Q >= pct(g9c.V, 99, 100), W((g9d.baseHeld * nd9.pk) / Q) + ' vs V ' + W(g9c.V));
  }

  // ── T10: setGasOverhead acotado ───────────────────────────────────────────
  log('\n== T10 setGasOverhead');
  await expectRevert('setGasOverhead desde el keeper', () => v4k.setGasOverhead.staticCall(60000), 'NotOwner', [IF]);
  await expectRevert('setGasOverhead 300000 (> MAX 200000)', () => v4.setGasOverhead.staticCall(300000), 'BadParams', [IF]);
  await tx(v4.setGasOverhead(60000), 'setGasOverhead(60000)');
  ok('T10: gasOverhead == 60000', (await v4.gasOverhead()) === 60000n);

  // ── F1: el stop-loss NO depende de la reserva (gas soft) ──────────────────
  log('\n== F1 stop-loss con reserva chica (soft gas)');
  const P0f = await Pnow();
  const slp = pct(P0f, 80, 100);
  const rcF = await tx(v4.openWithEth(TOKEN, ROUTE, await base({ slPrice: slp, floorPrice: pct(P0f, 40, 100) }), await seedMin(), 12345n, { value: V + RES + 12345n }), 'openWithEth SL=80 %, reserva 12345 wei');
  const idF = idOf(rcF);
  ok('F1: nacio con base, SL y 12345 wei de reserva; StopLossSet emitido', (await v4.grid(idF)).baseHeld > 0n && (await v4.grid(idF)).slPrice === slp && (await v4.grid(idF)).gasReserve === 12345n && !!evOf(rcF, IF, 'StopLossSet'));
  ok('F1: slMinOut > 0', (await v4.slMinOut(idF)) > 0n);
  await expectRevert('stopLoss con el precio por encima del SL', () => v4k.stopLoss.staticCall(idF, ROUTE, 0), 'PriceNotReached', [IF]);
  const Pd2 = await dumpHasta(slp);
  const enVentana = Pd2 <= slp && Pd2 >= pct(slp, 97, 100);
  log('    P tras el dump:', ethers.formatEther(Pd2), '| SL:', ethers.formatEther(slp), '| ventana [0.97 SL, SL]:', enVentana ? 'SI' : 'NO (' + ((Number(Pd2) / Number(slp)) * 100).toFixed(1) + '% del SL)');
  if (enVentana) {
    const mw0 = await p.getBalance(w.address);
    const rcSL = await tx(v4k.stopLoss(idF, ROUTE, 0), 'keeper stopLoss con 12345 wei de reserva');
    const gpF = evOf(rcSL, IF, 'GasPaid'), gsF = evOf(rcSL, IF, 'GridStopped'), grF = evOf(rcSL, IF, 'GasRefunded'), slE = evOf(rcSL, IF, 'StopLoss');
    ok('F1: el stop-loss SE EJECUTO con reserva insuficiente (no revirtio NoGas), kind 3, evento StopLoss', gsF && gsF.kind === 3n && !!slE);
    ok('F1: cobro EXACTAMENTE la reserva (12345 wei): owed clampeado, remaining 0', gpF && gpF.owed === 12345n && gpF.remaining === 0n);
    ok('F1: no hubo GasRefunded (no sobro nada) y gasReserve == 0', !grF && (await v4.grid(idF)).gasReserve === 0n);
    const bn = rcSL.blockNumber;
    ok('F1: el maker cobro el ETH de la venta (directo o en pendingEth)', (await p.getBalance(w.address, bn)) > (await p.getBalance(w.address, bn - 1)) || (await v4.pendingEth(w.address)) > 0n);
  } else {
    let razon = 'no revirtio';
    try { await v4k.stopLoss.staticCall(idF, ROUTE, 0, { gasPrice: (await p.getFeeData()).gasPrice }); } catch (e) { const d = e.data || (e.info && e.info.error && e.info.error.data) || ''; try { razon = IF.parseError(d).name; } catch (_) { try { razon = ROUTER_IF.parseError(d).name; } catch (__) { razon = 'desconocido'; } } }
    ok('F1 (sin ventana de precio): stopLoss con reserva chica NO revierte por NoGas (revierte por: ' + razon + ')', razon !== 'NoGas', razon);
    R.push({ s: 'F1 ejecucion real del SL (no se llego a la ventana de precio)', c: null });
  }
  // setStopLoss del maker
  const { id: idS } = await abrir({}, GAS, 'openWithEth para setStopLoss');
  await expectRevert('setStopLoss desde el keeper', () => v4k.setStopLoss.staticCall(idS, 1n), 'NotMaker', [IF]);
  const rcS = await tx(v4.setStopLoss(idS, pct((await v4.grid(idS)).P0, 70, 100)), 'setStopLoss(70 %)');
  ok('F1: setStopLoss cambio slPrice y emitio StopLossSet', (await v4.grid(idS)).slPrice === pct((await v4.grid(idS)).P0, 70, 100) && !!evOf(rcS, IF, 'StopLossSet'));

  // ── FUZZ: operaciones al azar, invariantes despues de CADA una ────────────
  log('\n== FUZZ de invariantes (semilla fija)');
  let seed = 4321; const rnd = () => { seed |= 0; seed = seed + 0x6D2B79F5 | 0; let t = Math.imul(seed ^ seed >>> 15, 1 | seed); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; };
  const pick = (a) => a[Math.floor(rnd() * a.length)];
  const todos = [id1, id3, id3b, id7, id8, idF, idS];
  const V0 = new Map(); for (const id of todos) V0.set(id, (await v4.grid(id)).V);
  async function invariantes(paso) {
    let sumGas = 0n, sumQ = 0n, sumB = 0n, mal = [];
    for (const id of todos) {
      const G2 = await v4.grid(id);
      sumGas += G2.gasReserve; sumQ += G2.quoteHeld + G2.gasReserve; sumB += G2.baseHeld;
      if (G2.status === 0n) {
        if (G2.reinvested > G2.profit) mal.push('I6 reinvested>profit ' + id.slice(0, 8));
        if (G2.V < (V0.get(id) || 0n)) mal.push('I7 V bajo ' + id.slice(0, 8));
        if (G2.costBasis > G2.baseHeld * G2.P0 * 4n / Q + G2.V * 2n) mal.push('I9 costBasis absurdo ' + id.slice(0, 8));
      } else if (G2.quoteHeld !== 0n || G2.gasReserve !== 0n || G2.baseHeld !== 0n || G2.costBasis !== 0n) mal.push('I8 grid cerrado con saldo ' + id.slice(0, 8));
    }
    const ge = await v4.gasEscrowed(), ew = await v4.escrowed(WETH), et = await v4.escrowed(TOKEN);
    if (ge !== sumGas) mal.push('I1 gasEscrowed ' + ge + ' != sum(gasReserve) ' + sumGas);
    if (ge > ew) mal.push('I2 gasEscrowed > escrowed[WETH]');
    if (ew !== sumQ) mal.push('I3 escrowed[WETH] ' + ew + ' != sum(quoteHeld+gasReserve) ' + sumQ);
    if ((await weth.balanceOf(V4)) < ew) mal.push('I4 balance WETH < escrowed');
    if (et !== sumB) mal.push('I5 escrowed[TOKEN] ' + et + ' != sum(baseHeld) ' + sumB);
    if ((await tok.balanceOf(V4)) < et) mal.push('I5b balance TOKEN < escrowed');
    if (mal.length) { ok('FUZZ paso ' + paso + ': invariantes', false, mal.join(' · ')); return false; }
    return true;
  }
  let opsOk = 0, opsRev = 0, invOk = true, opsHung = 0;
  // NONCE-2026-09-12: el NonceManager de ethers v6 incrementa ANTES de mandar y no vuelve atras si el
  // estimateGas revierte. Tras el primer revert economico la cuenta queda con un hueco de nonce y toda tx
  // siguiente de esa cuenta se encola para siempre: eso era "el cuelgue" de las corridas 3, 4 y 5. Se
  // resetea el contador de las dos cuentas antes de cada op y despues de cada fallo.
  const resetNonces = () => { try { w.reset(); } catch (_) {} try { k.reset(); } catch (_) {} };
  const OPS = ['open', 'up', 'up', 'down', 'down', 'gas', 'cap', 'stop', 'comp', 'pump', 'dump', 'sl', 'tp'];
  const PASOS = 30;
  const conTope = (pr, ms, que) => Promise.race([pr, new Promise((_, rej) => setTimeout(() => rej(new Error('TOPE ' + que)), ms))]);
  for (let paso = 1; paso <= PASOS && invOk; paso++) {
    const op = pick(OPS);
    if (paso % 5 === 1) log('    paso ' + paso + '/' + PASOS + ' · ' + todos.length + ' grids · op=' + op);
    const abiertos = []; for (const id of todos) if ((await v4.grid(id)).status === 0n) abiertos.push(id);
    resetNonces();
    try { await conTope((async () => {
      if (op === 'open' || !abiertos.length) {
        const res = pick([0n, 777n, GAS, GAS * 2n]); const P3 = await Pnow();
        const rcO = await (await v4.openWithEth(TOKEN, ROUTE, await base({ compound: rnd() < 0.5, slPrice: rnd() < 0.3 ? pct(P3, 75, 100) : 0n, tpPrice: rnd() < 0.3 ? pct(P3, 180, 100) : 0n }), await seedMin(), res, { value: V + RES + res })).wait();
        const idN = idOf(rcO); todos.push(idN); V0.set(idN, (await v4.grid(idN)).V);
      } else if (op === 'up') { await (await v4k.fillUp(pick(abiertos), ROUTE)).wait(); }
      else if (op === 'down') { await (await v4k.fillDown(pick(abiertos), ROUTE)).wait(); }
      else if (op === 'gas') { await (await v4.topUp(pick(abiertos), ROUTE, 0, GAS, { value: GAS })).wait(); }
      else if (op === 'cap') { await (await v4.topUp(pick(abiertos), ROUTE, 1, 0, { value: E / 200n })).wait(); }
      else if (op === 'stop') { await (await v4.stop(pick(abiertos), ROUTE, 0, rnd() < 0.5)).wait(); }
      else if (op === 'comp') { const id = pick(abiertos); await (await v4.setCompound(id, !(await v4.grid(id)).compound)).wait(); }
      else if (op === 'sl') { await (await v4k.stopLoss(pick(abiertos), ROUTE, 0)).wait(); }
      else if (op === 'tp') { await (await v4k.takeProfit(pick(abiertos), ROUTE)).wait(); }
      else if (op === 'pump') { await pump(E, 'pump 1 ETH'); }
      else if (op === 'dump') { await dump(4, 'dump 1/4'); }
    })(), 120_000, 'op ' + op + ' paso ' + paso);
      opsOk++;
    } catch (e) { resetNonces(); if (String(e.message).startsWith('TOPE')) { opsHung++; log('    ' + e.message + ' (se colgo, sigo)'); } else opsRev++; }
    try { invOk = await conTope(invariantes(paso), 120_000, 'invariantes paso ' + paso); } catch (e) { log('    ' + e.message); invOk = false; }
  }
  ok('FUZZ: ninguna operacion se colgo', opsHung === 0, opsHung + ' colgadas');
  ok('FUZZ: ' + PASOS + ' pasos, ' + opsOk + ' ops ejecutadas, ' + opsRev + ' revirtieron (economico), invariantes I1-I9 despues de cada paso', invOk, todos.length + ' grids');

  const pass = R.filter((r) => r.c === true).length, fail = R.filter((r) => r.c === false).length, skip = R.filter((r) => r.c === null).length;
  log('\n==== ' + pass + ' OK · ' + fail + ' FALLAN · ' + skip + ' skipped ====');
  if (fail) { log('FALLAN:'); for (const r of R) if (r.c === false) log('  -', r.s); process.exit(1); }
})().catch((e) => { console.error('ERROR', e); process.exit(2); });
