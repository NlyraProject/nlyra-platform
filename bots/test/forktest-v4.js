// TEST EN FORK LOCAL (anvil, puerto 8901). No toca mainnet: ninguna tx sale de la maquina.
// Prueba SOLO lo que v4 agrega sobre v3 (la logica de grilla ya esta probada por el contrato vivo):
//   reserva de gas (open, pago al keeper, NoGas, topUp solo gas, refund al cerrar, rescue no la toca)
//   compound (profitFree, boost en fillBuy, setCompound, nextBuyQuote)
//   admin (setGasOverhead acotado)
// Contra el pool REAL NLYRA/WETH (V3, fee 1%) y el feeRouter v2 REAL, con el V4 recien deployado en el fork.
const fs = require('fs'), path = require('path'), { ethers } = require('ethers');
const DIR = __dirname, ROOT = path.dirname(DIR);
const A = JSON.parse(fs.readFileSync((process.env.DESK_ADDRESSES || require('path').join(__dirname, '../../deployments/desk-addresses.json')), 'utf8'));   // el canonico, no la copia de desk-deploy
const p = new ethers.JsonRpcProvider('http://127.0.0.1:8901', 4663, { staticNetwork: true, batchMaxCount: 1 });
// anvil en fork SUBESTIMA el gas (los SLOAD cacheados del fork salen "warm" en el estimado y
// "cold" al ejecutar): un fill de v4 termina con ~30k de _payGas y una llamada a WETH, y con el
// estimado pelado se quedo sin gas (status 0, sin data, gasUsed == limite). El keeper real
// multiplica el estimado por un margen (deskBots.js:2121); el test hace lo mismo.
const _est = p.estimateGas.bind(p);
p.estimateGas = async (t) => ((await _est(t)) * 3n) / 2n;
// cuenta 0 de anvil (mnemonic de test publico, sin valor)
// maker y keeper se ELIGEN al arrancar (ver abajo): las cuentas del mnemonic de anvil estan envenenadas en esta cadena
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
const rawCall = (to, data, from) => p.call({ to, data, from });
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
  // Las cuentas del mnemonic de anvil son PUBLICAS y en esta cadena el 95 % de las cuentas activas
  // tienen delegate 7702: la cuenta 0 tiene 23 bytes de codigo en mainnet (un designador 0xef0100…)
  // y el fork lo copia. _payEth le manda el ETH, la llamada tiene exito, y el delegate lo mueve a
  // otro lado — el balance del maker no cambia y el test lo lee como "no cobro". Maker y keeper se
  // eligen entre cuentas SIN codigo; si no hay, se generan al azar.
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
  log('fork block', await p.getBlockNumber(), '· maker', w.address, '(code ' + ((await p.getCode(w.address)).length - 2) / 2 + 'B) · keeper', k.address, '(code ' + ((await p.getCode(k.address)).length - 2) / 2 + 'B)');

  // 1. deploy + autorizar en el router + keeper de prueba
  const abi = JSON.parse(fs.readFileSync(path.join(DIR, 'artifacts', 'ArchitectSpotGridV4.abi.json'), 'utf8'));
  const bin = '0x' + fs.readFileSync(path.join(DIR, 'artifacts', 'ArchitectSpotGridV4.bin'), 'utf8');
  const v4 = await (await new ethers.ContractFactory(abi, bin, w).deploy(ROUTER, WETH, KEEPER)).waitForDeployment();
  const V4 = await v4.getAddress(), IF = new ethers.Interface(abi);
  const v4k = v4.connect(k);
  ok('deploy: V4 se deploya, keeper de prod allowlisteado, owner = deployer, gasOverhead = 80000',
    await v4.isKeeper(KEEPER) && (await v4.owner()) === w.address && (await v4.gasOverhead()) === 80000n, V4);
  await asAcct(ROUTER_OWNER, async (s) => { await tx(new ethers.Contract(ROUTER, ['function setCaller(address,bool)'], s).setCaller(V4, true), 'router.setCaller(V4)'); });
  ok('router: V4 en la allowlist de callers', await new ethers.Contract(ROUTER, ['function isCaller(address) view returns (bool)'], p).isCaller(V4));
  await tx(v4.setKeeper(k.address, true), 'setKeeper(keeper de prueba)');
  const weth = new ethers.Contract(WETH, erc20, p), tok = new ethers.Contract(TOKEN, erc20, p);

  // precio interno del par: token0 = WETH (quote), token1 = NLYRA (base) → WETH por NLYRA × 1e18
  const slot0 = await new ethers.Contract(POOL, ['function slot0() view returns (uint160,int24,uint16,uint16,uint16,uint8,bool)'], p).slot0();
  const sq = BigInt(slot0[0]); const P = (Q << 192n) / (sq * sq);
  ok('precio interno P de NLYRA en WETH > 0', P > 0n, 'P=' + P + ' (' + ethers.formatEther(P) + ' WETH/NLYRA)');

  const PER = E / 50n;                       // 0.02 ETH por nivel (~$49: pasa el minimo de $30)
  const GAS = E / 200n;                      // 0.005 ETH de reserva
  const base = (over) => ({ perLevel: PER, gBps: 300, nSeed: 0, slPrice: 0n, tpPrice: 0n, expiry: expiry(), feeBps: FEE_BPS, referrer: ethers.ZeroAddress, compound: false, ...(over || {}) });
  // 2 niveles de compra POR ENCIMA del precio: fillBuy llena ya (el pool esta mas barato que la linea)
  const bp = [pct(P, 115, 100), pct(P, 120, 100)], sp = [pct(P, 119, 100), pct(P, 124, 100)];
  const idOf = (rc) => evOf(rc, IF, 'GridOpened').id;

  // ── T1: abrir con reserva ─────────────────────────────────────────────────
  log('\n== T1 abrir con reserva de gas');
  await expectRevert('abrir mandando solo el capital (falta la reserva)', () => v4.openWithEth.staticCall(TOKEN, ROUTE, base(), bp, sp, 0, GAS, { value: PER * 2n }), 'BadValue', [IF]);
  await expectRevert('abrir mandando capital + reserva pero declarando otra reserva', () => v4.openWithEth.staticCall(TOKEN, ROUTE, base(), bp, sp, 0, GAS * 2n, { value: PER * 2n + GAS }), 'BadValue', [IF]);
  const rc1 = await tx(v4.openWithEth(TOKEN, ROUTE, base(), bp, sp, 0, GAS, { value: PER * 2n + GAS }), 'openWithEth 2×0.02 + 0.005 gas');
  const id1 = idOf(rc1);
  let g = await v4.grid(id1);
  const ga = evOf(rc1, IF, 'GasAdded');
  ok('T1: grid.gasReserve == reserva, gasEscrowed == reserva, GasAdded emitido', g.gasReserve === GAS && (await v4.gasEscrowed()) === GAS && ga && ga.amount === GAS, W(g.gasReserve));
  ok('T1: escrowed[WETH] == capital + reserva (la reserva esta ADENTRO del escrow)', (await v4.escrowed(WETH)) === PER * 2n + GAS, W(await v4.escrowed(WETH)));
  ok('T1: el balance WETH del contrato cubre lo escrowado', (await weth.balanceOf(V4)) >= (await v4.escrowed(WETH)));
  ok('T1: quoteHeld == capital (la reserva NO cuenta como capital de grilla)', g.quoteHeld === PER * 2n && g.compound === false && g.profitFree === 0n);

  // ── T5 (antes que nada toque): rescue no puede barrer la reserva ─────────
  await expectRevert('rescue(WETH) del owner con la reserva adentro', () => v4.rescue.staticCall(WETH, w.address), 'NothingToRefund', [IF]);

  // ── T3: el keeper cobra su gas en el fill ─────────────────────────────────
  log('\n== T3 fillBuy paga al keeper');
  await expectRevert('fillBuy desde el maker (no es keeper)', () => v4.fillBuy.staticCall(id1, 0, ROUTE), 'NotKeeper', [IF]);
  const kw0 = await weth.balanceOf(k.address);
  const rc3 = await tx(v4k.fillBuy(id1, 0, ROUTE), 'keeper fillBuy(0)');
  const gp = evOf(rc3, IF, 'GasPaid'), gf = evOf(rc3, IF, 'GridFilled');
  const kw1 = await weth.balanceOf(k.address);
  g = await v4.grid(id1);
  const costReal = rc3.gasUsed * rc3.gasPrice;
  ok('T3: GasPaid emitido al keeper', gp && gp.keeper === k.address && gp.owed > 0n, 'owed=' + W(gp ? gp.owed : 0n));
  ok('T3: el keeper recibio EXACTAMENTE owed en WETH', kw1 - kw0 === (gp ? gp.owed : -1n), W(kw1 - kw0));
  ok('T3: gasReserve bajo owed y gasEscrowed bajo owed', g.gasReserve === GAS - gp.owed && (await v4.gasEscrowed()) === GAS - gp.owed);
  ok('T3: escrowed[WETH] == quoteHeld + gasReserve (contabilidad cerrada)', (await v4.escrowed(WETH)) === g.quoteHeld + g.gasReserve, W(await v4.escrowed(WETH)));
  // owed tiene que cubrir el costo real de la tx (gasUsed × gasPrice) y no pasarse de mas del doble
  ok('T3: owed >= costo real de la tx (el keeper nunca pierde)', gp.owed >= costReal, 'owed=' + gp.owed + ' real=' + costReal + ' (' + ((Number(gp.owed) / Number(costReal)) * 100).toFixed(0) + '%)');
  ok('T3: owed <= 2× costo real (el maker no paga de mas)', gp.owed <= costReal * 2n);
  ok('T3: el fill en si es correcto (nivel BASE, cost = perLevel, base > 0)', gf && gf.amountIn === PER && (await v4.levels(id1))[0].state === 1n);
  ok('T3: sin allowance viva hacia el router', (await weth.allowance(V4, ROUTER)) === 0n);

  // ── T4: sin reserva no hay fill ───────────────────────────────────────────
  log('\n== T4 NoGas');
  const rc4 = await tx(v4.openWithEth(TOKEN, ROUTE, base(), bp, sp, 0, 1n, { value: PER * 2n + 1n }), 'openWithEth con 1 wei de reserva');
  const id4 = idOf(rc4);
  await expectRevert('fillBuy con 1 wei de reserva', () => v4k.fillBuy.staticCall(id4, 0, ROUTE), 'NoGas', [IF]);
  const rc4b = await tx(v4.openWithEth(TOKEN, ROUTE, base(), bp, sp, 0, 0n, { value: PER * 2n }), 'openWithEth con reserva 0 (permitido)');
  await expectRevert('fillBuy con reserva 0', () => v4k.fillBuy.staticCall(idOf(rc4b), 0, ROUTE), 'NoGas', [IF]);

  // ── T6: topUp solo gas ────────────────────────────────────────────────────
  log('\n== T6 topUp solo gas');
  const per0 = (await v4.grid(id4)).perLevel, ge0 = await v4.gasEscrowed();
  const rc6 = await tx(v4.topUp(id4, ROUTE, 0, GAS, { value: GAS }), 'topUp(gasAdd=0.005, capital=0)');
  g = await v4.grid(id4);
  ok('T6: la reserva subio, perLevel NO cambio, ToppedUp NO se emitio (no hubo capital)', g.gasReserve === 1n + GAS && g.perLevel === per0 && !evOf(rc6, IF, 'ToppedUp') && !!evOf(rc6, IF, 'GasAdded'));
  ok('T6: gasEscrowed subio exactamente gasAdd', (await v4.gasEscrowed()) === ge0 + GAS);
  await expectRevert('topUp con gasAdd > msg.value', () => v4.topUp.staticCall(id4, ROUTE, 0, GAS, { value: GAS / 2n }), 'BadValue', [IF]);
  await expectRevert('topUp con todo en cero', () => v4.topUp.staticCall(id4, ROUTE, 0, 0, { value: 0 }), 'BadValue', [IF]);
  const rc6b = await tx(v4k.fillBuy(id4, 0, ROUTE), 'keeper fillBuy(0) ahora que hay reserva');
  ok('T6: con la reserva cargada el fill sale', !!evOf(rc6b, IF, 'GasPaid'));

  // ── T7: stop devuelve la reserva que sobro ────────────────────────────────
  log('\n== T7 stop devuelve la reserva');
  g = await v4.grid(id1);
  const resto = g.gasReserve, ge7 = await v4.gasEscrowed();
  const rc7 = await tx(v4.stop(id1, ROUTE, 0, false), 'stop(keep base)');
  const gr = evOf(rc7, IF, 'GasRefunded');
  ok('T7: GasRefunded == lo que quedaba', gr && gr.amount === resto && gr.maker === w.address, W(gr ? gr.amount : 0n));
  ok('T7: grid.gasReserve == 0 y gasEscrowed bajo exactamente eso', (await v4.grid(id1)).gasReserve === 0n && (await v4.gasEscrowed()) === ge7 - resto);
  ok('T7: el grid quedo Stopped y sin escrow propio', (await v4.grid(id1)).status === 1n && (await v4.grid(id1)).quoteHeld === 0n);
  ok('T7: invariante global gasEscrowed <= escrowed[WETH]', (await v4.gasEscrowed()) <= (await v4.escrowed(WETH)));

  // ── T11: refundExpired devuelve la reserva ────────────────────────────────
  log('\n== T11 refundExpired devuelve la reserva');
  const rc11 = await tx(v4.openWithEth(TOKEN, ROUTE, base({ expiry: expiry(120) }), bp, sp, 0, GAS, { value: PER * 2n + GAS }), 'openWithEth expiry 2 min');
  const id11 = idOf(rc11);
  await rpc('evm_increaseTime', 200); await rpc('evm_mine');
  const rc11b = await tx(v4.connect(k).refundExpired(id11, ROUTE), 'refundExpired por CUALQUIERA (el keeper)');
  const gr11 = evOf(rc11b, IF, 'GasRefunded');
  ok('T11: la reserva entera volvio al MAKER aunque llamo otro', gr11 && gr11.amount === GAS && gr11.maker === w.address);

  // ── T9: setCompound ───────────────────────────────────────────────────────
  log('\n== T9 setCompound');
  const rc9 = await tx(v4.openWithEth(TOKEN, ROUTE, base({ compound: true }), bp, sp, 0, GAS, { value: PER * 2n + GAS }), 'openWithEth compound=true');
  const id9 = idOf(rc9);
  ok('T9: abre con compound=true', (await v4.grid(id9)).compound === true);
  await expectRevert('setCompound desde el keeper (no es maker)', () => v4k.setCompound.staticCall(id9, false), 'NotMaker', [IF]);
  const rc9b = await tx(v4.setCompound(id9, false), 'setCompound(false)');
  ok('T9: se apaga y emite CompoundSet', (await v4.grid(id9)).compound === false && evOf(rc9b, IF, 'CompoundSet').compound === false);
  await tx(v4.setCompound(id9, true), 'setCompound(true)');
  ok('T9: nextBuyQuote == perLevel cuando profitFree == 0', (await v4.nextBuyQuote(id9)) === PER);
  await expectRevert('setCompound sobre un grid cerrado', () => v4.setCompound.staticCall(id1, true), 'NotOpen', [IF]);

  // ── T8: compound de verdad — necesita una venta con ganancia ─────────────
  // Intento bombear el precio con el router publico. Si el router no deja (NotCaller), el test
  // de compound queda SKIPPED y se dice: no se inventa.
  log('\n== T8 compound (requiere pump del pool)');
  const rc8 = await tx(v4.openWithEth(TOKEN, ROUTE, base({ compound: true, gBps: 250 }), bp, sp, 0, GAS, { value: PER * 2n + GAS }), 'openWithEth compound');
  const id8 = idOf(rc8);
  await tx(v4k.fillBuy(id8, 0, ROUTE), 'fillBuy(0) → nivel 0 en BASE');
  let pumped = false;
  try {
    await asAcct('0x000000000000000000000000000000000000bEEF', async (s) => {
      const r = new ethers.Contract(ROUTER, ['function swapETH(address,uint256,uint16,address,uint256,bytes) payable returns (uint256)'], s);
      await tx(r.swapETH(TOKEN, 0, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE, { value: E * 3n }), 'PUMP: 3 ETH → NLYRA por el router');
    });
    pumped = true;
  } catch (e) { log('    pump fallo:', String(e.shortMessage || e.message).slice(0, 100)); }
  if (pumped) {
    const rc8b = await tx(v4k.fillSell(id8, 0, ROUTE), 'fillSell(0) con ganancia');
    const gf8 = evOf(rc8b, IF, 'GridFilled');
    g = await v4.grid(id8);
    ok('T8: la venta dio ganancia y profit == profitFree == gain (compound on)', gf8 && gf8.profit > 0n && g.profit === gf8.profit && g.profitFree === gf8.profit, 'gain=' + W(gf8 ? gf8.profit : 0n));
    const boostEsp = g.profitFree / 2n;
    ok('T8: nextBuyQuote == perLevel + profitFree/nLevels', (await v4.nextBuyQuote(id8)) === PER + boostEsp, W(await v4.nextBuyQuote(id8)));
    // el pump dejo el precio ARRIBA de la linea de compra del nivel 0: el contrato (bien) no compra por encima
    // de su linea. Para recomprar hay que devolver el precio: el que bombeo vende lo que compro.
    await asAcct('0x000000000000000000000000000000000000bEEF', async (s) => {
      const t = new ethers.Contract(TOKEN, erc20, s);
      const bal = await t.balanceOf('0x000000000000000000000000000000000000bEEF');
      await tx(t.approve(ROUTER, bal), 'DUMP: approve');
      const r = new ethers.Contract(ROUTER, ['function swapToETH(address,uint256,uint256,uint16,address,uint256,bytes) returns (uint256)'], s);
      await tx(r.swapToETH(TOKEN, bal, 0, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE), 'DUMP: NLYRA → ETH por el router');
    });
    // la prueba de que se puede recomprar es la tx real de abajo; aca solo que el nivel volvio a QUOTE
    ok('T8: tras la venta el nivel 0 volvio a QUOTE (buyMinOut > 0) y el minOut ya incluye el boost',
      (await v4.buyMinOut(id8, 0)) > 0n && (await v4.buyMinOut(id8, 0)) === ((PER + boostEsp) * Q + bp[0] - 1n) / bp[0]);
    const rc8c = await tx(v4k.fillBuy(id8, 0, ROUTE), 'fillBuy(0) reinvirtiendo');
    const rv = evOf(rc8c, IF, 'Reinvested'), gf8c = evOf(rc8c, IF, 'GridFilled');
    const g8 = await v4.grid(id8), lv8 = await v4.levels(id8);
    ok('T8: Reinvested emitido con el boost y la compra fue perLevel + boost', rv && rv.boost === boostEsp && gf8c.amountIn === PER + boostEsp);
    ok('T8: cost del nivel == perLevel + boost (la garantia gBps escala con el lote)', lv8[0].cost === PER + boostEsp);
    ok('T8: profit NO bajo (de por vida), profitFree SI bajo el boost', g8.profit === g.profit && g8.profitFree === g.profitFree - boostEsp);
    ok('T8: invariante profitFree <= quoteHeld', g8.profitFree <= g8.quoteHeld);
    // con compound apagado, la venta no alimenta profitFree. El precio quedo abajo tras el dump y el
    // contrato (bien) no vende a perdida: hay que bombear otra vez para que la venta sea rentable.
    await tx(v4.setCompound(id8, false), 'setCompound(false)');
    await asAcct('0x000000000000000000000000000000000000bEEF', async (s) => {
      const r = new ethers.Contract(ROUTER, ['function swapETH(address,uint256,uint16,address,uint256,bytes) payable returns (uint256)'], s);
      await tx(r.swapETH(TOKEN, 0, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE, { value: E * 3n }), 'PUMP 2: 3 ETH → NLYRA');
    });
    const rc8d = await tx(v4k.fillSell(id8, 0, ROUTE), 'fillSell(0) con compound OFF');
    const g8d = await v4.grid(id8);
    ok('T8: con compound off, profit sube pero profitFree NO', g8d.profit > g8.profit && g8d.profitFree === g8.profitFree);
  } else {
    log('    T8 SKIPPED: no se pudo bombear el pool en el fork. La contabilidad de compound queda cubierta solo por T9 (setCompound/nextBuyQuote).');
    R.push({ s: 'T8 compound con venta real', c: null });
  }

  // ── T10: setGasOverhead acotado ───────────────────────────────────────────
  log('\n== T10 setGasOverhead');
  await expectRevert('setGasOverhead desde el keeper', () => v4k.setGasOverhead.staticCall(60000), 'NotOwner', [IF]);
  await expectRevert('setGasOverhead 300000 (> MAX 200000)', () => v4.setGasOverhead.staticCall(300000), 'BadParams', [IF]);
  await tx(v4.setGasOverhead(60000), 'setGasOverhead(60000)');
  ok('T10: gasOverhead == 60000', (await v4.gasOverhead()) === 60000n);

  // ── F1: el stop-loss NO depende de la reserva ─────────────────────────────
  // Auditoria F1: SL/TP son la proteccion del maker. Con reserva vacia se ejecutan igual (soft gas).
  log('\n== F1 stop-loss con reserva vacia / chica (soft gas)');
  const Pnow = async () => { const s = await new ethers.Contract(POOL, ['function slot0() view returns (uint160,int24,uint16,uint16,uint16,uint8,bool)'], p).slot0(); const q2 = BigInt(s[0]); return (Q << 192n) / (q2 * q2); };
  const beef = '0x000000000000000000000000000000000000bEEF';
  async function dumpHasta(objetivo) {
    // vende de a 2 % la bolsa de bEEF hasta que P <= objetivo (o se acaba la bolsa). Devuelve P final.
    let P2 = await Pnow();
    for (let i = 0; i < 60 && P2 > objetivo; i++) {
      const bal = await tok.balanceOf(beef); if (bal === 0n) break;
      const chunk = bal / 50n || bal;
      await asAcct(beef, async (s) => {
        await (await new ethers.Contract(TOKEN, erc20, s).approve(ROUTER, chunk)).wait();
        await (await new ethers.Contract(ROUTER, ['function swapToETH(address,uint256,uint256,uint16,address,uint256,bytes) returns (uint256)'], s).swapToETH(TOKEN, chunk, 0, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE)).wait();
      });
      P2 = await Pnow();
    }
    return P2;
  }
  // bEEF tiene NLYRA del PUMP 2. Abro un grid con nSeed=1 (nace en BASE) y SL al 80 % del precio actual.
  const P0 = await Pnow();
  const seedMin = ((PER * Q) / P0) * 85n / 100n;
  const slp = pct(P0, 80, 100);
  const bpF = [pct(P0, 110, 100), pct(P0, 115, 100)], spF = [pct(P0, 114, 100), pct(P0, 119, 100)];
  const rcF = await tx(v4.openWithEth(TOKEN, ROUTE, base({ nSeed: 1, slPrice: slp }), bpF, spF, seedMin, 12345n, { value: PER * 2n + 12345n }), 'openWithEth nSeed=1, SL=80%, reserva 12345 wei');
  const idF = idOf(rcF);
  ok('F1: el grid nacio con base (nSeed=1) y 12345 wei de reserva', (await v4.grid(idF)).baseHeld > 0n && (await v4.grid(idF)).gasReserve === 12345n);
  const Pd = await dumpHasta(slp);
  const enVentana = Pd <= slp && Pd >= pct(slp, 95, 100);
  log('    P tras el dump:', String(Pd), '| SL:', String(slp), '| ventana [0.95 SL, SL]:', enVentana ? 'SI' : 'NO (P=' + ((Number(Pd) / Number(slp)) * 100).toFixed(1) + '% del SL)');
  if (enVentana) {
    const mw0 = await p.getBalance(w.address);
    const rcSL = await tx(v4k.stopLoss(idF, ROUTE, 0), 'keeper stopLoss con 12345 wei de reserva');
    const gpF = evOf(rcSL, IF, 'GasPaid'), gsF = evOf(rcSL, IF, 'GridStopped'), grF = evOf(rcSL, IF, 'GasRefunded');
    ok('F1: el stop-loss SE EJECUTO con reserva insuficiente (no revirtio NoGas)', gsF && gsF.kind === 3n);
    ok('F1: cobro EXACTAMENTE la reserva (12345 wei), no mas: owed quedo clampeado', gpF && gpF.owed === 12345n && gpF.remaining === 0n, 'owed=' + (gpF ? String(gpF.owed) : '-'));
    ok('F1: no hubo GasRefunded (no sobro nada)', !grF);
    const pend = await v4.pendingEth(w.address);
    // DIAG: a donde fue el ETH. Balance por bloque exacto, codigo del maker, y lo que dice GridStopped.
    const bn = rcSL.blockNumber;
    const bAntes = await p.getBalance(w.address, bn - 1), bDesp = await p.getBalance(w.address, bn), bLatest = await p.getBalance(w.address);
    log('    DIAG maker=' + w.address + ' code=' + ((await p.getCode(w.address)).length - 2) / 2 + 'B');
    log('    DIAG balance bloque ' + (bn - 1) + ': ' + W(bAntes) + ' | bloque ' + bn + ': ' + W(bDesp) + ' | latest: ' + W(bLatest) + ' | mw0: ' + W(mw0));
    log('    DIAG GridStopped: kind=' + (gsF ? String(gsF.kind) : '-') + ' baseSold=' + (gsF ? String(gsF.baseSold) : '-') + ' proceeds=' + W(gsF ? gsF.proceeds : 0n) + ' baseReturned=' + (gsF ? String(gsF.baseReturned) : '-') + ' quoteReturned=' + W(gsF ? gsF.quoteReturned : 0n));
    const ethPend = evOf(rcSL, IF, 'EthPending');
    log('    DIAG EthPending emitido: ' + (ethPend ? W(ethPend.amount) : 'no') + ' | pendingEth(maker)=' + W(pend) + ' | ETH del contrato V4: ' + W(await p.getBalance(V4)));
    ok('F1: el maker cobro el ETH de la venta (directo o en pendingEth)', bDesp > bAntes || pend > 0n, 'delta=' + W(bDesp - bAntes));
    ok('F1: gasEscrowed no quedo con resto fantasma del grid', (await v4.grid(idF)).gasReserve === 0n);
  } else {
    // sin ventana, igual se prueba el DELTA: que la razon de revert NO sea NoGas
    let razon = 'no revirtio';
    try { await v4k.stopLoss.staticCall(idF, ROUTE, 0, { gasPrice: (await p.getFeeData()).gasPrice }); } catch (e) { const d = e.data || (e.info && e.info.error && e.info.error.data) || ''; try { razon = IF.parseError(d).name; } catch (_) { try { razon = ROUTER_IF.parseError(d).name; } catch (__) { razon = 'desconocido'; } } }
    ok('F1 (sin ventana de precio): stopLoss con reserva chica NO revierte por NoGas (revierte por precio: ' + razon + ')', razon !== 'NoGas', razon);
    R.push({ s: 'F1 ejecucion real del SL (no se llego a la ventana de precio)', c: null });
  }

  // ── FUZZ: 40 operaciones al azar, invariantes despues de CADA una ──────────
  log('\n== FUZZ de invariantes (semilla fija)');
  let seed = 1234; const rnd = () => { seed |= 0; seed = seed + 0x6D2B79F5 | 0; let t = Math.imul(seed ^ seed >>> 15, 1 | seed); t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t; return ((t ^ t >>> 14) >>> 0) / 4294967296; };
  const pick = (a) => a[Math.floor(rnd() * a.length)];
  const todos = [id1, id4, idOf(rc4b), id11, id9, id8, idF];    // todos los grids que este test abrio
  async function invariantes(paso) {
    let sumGas = 0n, sumQ = 0n, sumB = 0n, mal = [];
    for (const id of todos) {
      const G2 = await v4.grid(id);
      sumGas += G2.gasReserve; sumQ += G2.quoteHeld + G2.gasReserve; sumB += G2.baseHeld;
      if (G2.status === 0n) {
        if (G2.profitFree > G2.quoteHeld) mal.push('I6 profitFree>quoteHeld ' + id.slice(0, 8));
        if (G2.profitFree > G2.profit) mal.push('I7 profitFree>profit ' + id.slice(0, 8));
      } else if (G2.quoteHeld !== 0n || G2.gasReserve !== 0n || G2.baseHeld !== 0n) mal.push('I8 grid cerrado con saldo ' + id.slice(0, 8));
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
  let opsOk = 0, opsRev = 0, invOk = true;
  const OPS = ['open', 'open', 'buy', 'buy', 'buy', 'sell', 'sell', 'gas', 'cap', 'stop', 'comp', 'pump', 'dump'];
  const PASOS = 25;
  for (let paso = 1; paso <= PASOS && invOk; paso++) {
    const op = pick(OPS);
    if (paso % 5 === 1) log('    paso ' + paso + '/' + PASOS + ' · ' + todos.length + ' grids · op=' + op);
    const abiertos = []; for (const id of todos) if ((await v4.grid(id)).status === 0n) abiertos.push(id);
    try {
      if (op === 'open' || !abiertos.length) {
        const P3 = await Pnow(); const res = pick([0n, 777n, GAS, GAS * 2n]);
        const rcO = await (await v4.openWithEth(TOKEN, ROUTE, base({ compound: rnd() < 0.5 }), [pct(P3, 105, 100), pct(P3, 112, 100)], [pct(P3, 109, 100), pct(P3, 116, 100)], 0, res, { value: PER * 2n + res })).wait();
        todos.push(idOf(rcO));
      } else if (op === 'buy') {
        const id = pick(abiertos); const lv = await v4.levels(id); const qs = []; lv.forEach((l, i) => { if (l.state === 0n) qs.push(i); });
        if (!qs.length) throw new Error('sin QUOTE'); await (await v4k.fillBuy(id, pick(qs), ROUTE)).wait();
      } else if (op === 'sell') {
        const id = pick(abiertos); const lv = await v4.levels(id); const bs = []; lv.forEach((l, i) => { if (l.state === 1n) bs.push(i); });
        if (!bs.length) throw new Error('sin BASE'); await (await v4k.fillSell(id, pick(bs), ROUTE)).wait();
      } else if (op === 'gas') { await (await v4.topUp(pick(abiertos), ROUTE, 0, GAS, { value: GAS })).wait(); }
      else if (op === 'cap') { const id = pick(abiertos); const nb = (await v4.levels(id)).filter((l) => l.state === 1n).length; await (await v4.topUp(id, ROUTE, nb ? 1n : 0, 0, { value: PER })).wait(); }
      else if (op === 'stop') { await (await v4.stop(pick(abiertos), ROUTE, 0, false)).wait(); }
      else if (op === 'comp') { const id = pick(abiertos); await (await v4.setCompound(id, !(await v4.grid(id)).compound)).wait(); }
      else if (op === 'pump') { await asAcct(beef, async (s) => { await (await new ethers.Contract(ROUTER, ['function swapETH(address,uint256,uint16,address,uint256,bytes) payable returns (uint256)'], s).swapETH(TOKEN, 0, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE, { value: E })).wait(); }); }
      else if (op === 'dump') { const bal = await tok.balanceOf(beef); if (bal === 0n) throw new Error('bolsa vacia'); await asAcct(beef, async (s) => { const c2 = bal / 4n || bal; await (await new ethers.Contract(TOKEN, erc20, s).approve(ROUTER, c2)).wait(); await (await new ethers.Contract(ROUTER, ['function swapToETH(address,uint256,uint256,uint16,address,uint256,bytes) returns (uint256)'], s).swapToETH(TOKEN, c2, 0, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE)).wait(); }); }
      opsOk++;
    } catch (e) { opsRev++; }
    invOk = await invariantes(paso);
  }
  ok('FUZZ: ' + PASOS + ' pasos, ' + opsOk + ' ops ejecutadas, ' + opsRev + ' revirtieron (economico), invariantes I1-I8 despues de cada paso', invOk, todos.length + ' grids');

  // ── resumen ───────────────────────────────────────────────────────────────
  const pass = R.filter((r) => r.c === true).length, fail = R.filter((r) => r.c === false).length, skip = R.filter((r) => r.c === null).length;
  log('\n==== ' + pass + ' OK · ' + fail + ' FALLAN · ' + skip + ' skipped ====');
  if (fail) { log('FALLAN:'); for (const r of R) if (r.c === false) log('  -', r.s); process.exit(1); }
})().catch((e) => { console.error('ERROR', e); process.exit(2); });
