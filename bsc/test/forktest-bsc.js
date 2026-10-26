'use strict';
// TEST EN FORK LOCAL de BNB Smart Chain (anvil, puerto 8956). No toca mainnet: ninguna tx sale de la maquina.
// Levantar con run/run-forktest.sh (anvil --fork-url <RPC publico con archivo> --fork-block-number <reciente>).
//
// Prueba, contra los contratos REALES de PancakeSwap en el fork (V2 factory/router/pairs, V3 factory/pools, SmartRouter, QuoterV2):
//   R  ArchitectFeeRouterBSC: compra y venta de CAKE y USDT contra WBNB por V2 (router y pair directo), V3 (pool directo, fee
//      tiers) y V3 multi-hop (SmartRouter), contabilidad de fees (tesoreria, referidor 30 %, claim), quote tokens, limites de
//      fee, deadline, pausa, callback V3 protegido, pendingEth, tokens con tax (PIT real + mock 10 %), path al reves.
//   I  ArchitectInfinityGridV4BSC: abrir con BNB + reserva, fillUp/fillDown pagan al keeper, NoGas (pre-flight NO ciego),
//      topUp, stop, refundExpired, compound, take-profit, stop-loss, piso/techo del precio de gas, pausa, rescue.
//   S  ArchitectSpotGridV4BSC: abrir, fillBuy/fillSell, compound, take-profit, stop-loss, stop, refundExpired, NoGas, techo de gas.
//   F  tokens con tax / blacklist en los bots: openWithBase rechaza, openWithEth mide, stop no traba fondos, pendingToken.
//   G  tabla de gas por operacion con costo en BNB y USD (precio BNB/USDT leido del pool V3 en el fork).
const fs = require('fs'), path = require('path'), { ethers } = require('ethers');
const ROOT = path.join(__dirname, '..');
const A = JSON.parse(fs.readFileSync(path.join(ROOT, 'deployments', 'bsc-addresses.json'), 'utf8'));
const PORT = process.env.ANVIL_PORT || 8956;
// cacheTimeout -1: ethers v6 cachea 250 ms las llamadas identicas (eth_getTransactionCount incluida) y con anvil
// minando al instante dos tx seguidas de la misma cuenta salian con el mismo nonce ("nonce too low").
const p = new ethers.JsonRpcProvider('http://127.0.0.1:' + PORT, 56, { staticNetwork: true, batchMaxCount: 1, cacheTimeout: -1 });
// anvil en fork SUBESTIMA el gas (SLOAD cacheados salen "warm" en el estimado y "cold" al ejecutar): margen como el keeper real
const _est = p.estimateGas.bind(p);
p.estimateGas = async (t) => ((await _est(t)) * 3n) / 2n;

const Q = 10n ** 18n, E = 10n ** 18n, GWEI = 10n ** 9n;
const WBNB = A.WBNB, USDT = A.USDT, USDC = A.USDC, CAKE = A.CAKE;
const PIT = '0xa57ac35ce91ee92caefaa8dc04140c8e232c2e50';      // Pitbull: token real con tax (~4 %), 9 decimales, pair V2 con WBNB
const FLOKI = '0xfb5b838b6cfeedc2873ab27866079ac55363d37e';    // Floki: tax 0,3 %, 9 decimales
const FEE_BPS = 100;
const AC = ethers.AbiCoder.defaultAbiCoder();
const ROUTE_V3 = (fee) => AC.encode(['uint8', 'bytes'], [0, AC.encode(['uint24'], [fee])]);
const ROUTE_V2 = (pathArr) => AC.encode(['uint8', 'bytes'], [1, AC.encode(['address[]'], [pathArr])]);
const ROUTE_V2D = (pair, feeNum) => AC.encode(['uint8', 'bytes'], [3, AC.encode(['address', 'uint256'], [pair, feeNum === undefined ? 9975 : feeNum])]);
const ROUTE_V3P = (tokens, fees) => { const t = [], v = []; for (let i = 0; i < tokens.length; i++) { t.push('address'); v.push(tokens[i]); if (i < fees.length) { t.push('uint24'); v.push(fees[i]); } } return AC.encode(['uint8', 'bytes'], [4, AC.encode(['bytes'], [ethers.solidityPacked(t, v)])]); };
const W = (x) => ethers.formatEther(x) + ' BNB';
const log = (...a) => console.log(...a);
const R = [];
const ok = (s, c, e) => { R.push({ s, c: !!c }); log(c ? ' OK  ' : ' XXX ', s, e === undefined ? '' : '| ' + e); };
const skip = (s, why) => { R.push({ s, c: null }); log(' --  SKIP', s, '|', why); };
const rpc = (m, ...a) => p.send(m, a);
const expiry = (s) => BigInt(Math.floor(Date.now() / 1000) + (s || 86400));
const pct = (x, n, d) => (x * BigInt(n)) / BigInt(d || 100);
const now = async () => BigInt((await p.getBlock('latest')).timestamp);

const ERC20 = ['function balanceOf(address) view returns (uint256)', 'function approve(address,uint256) returns (bool)', 'function transfer(address,uint256) returns (bool)', 'function allowance(address,address) view returns (uint256)', 'function decimals() view returns (uint8)', 'function symbol() view returns (string)'];
const PCS_V2 = ['function getAmountsOut(uint256,address[]) view returns (uint256[])', 'function swapExactETHForTokens(uint256,address[],address,uint256) payable returns (uint256[])', 'function swapExactTokensForETH(uint256,uint256,address[],address,uint256) returns (uint256[])', 'function addLiquidityETH(address,uint256,uint256,uint256,address,uint256) payable returns (uint256,uint256,uint256)', 'function factory() view returns (address)', 'function WETH() view returns (address)'];
const PAIR = ['function getReserves() view returns (uint112,uint112,uint32)', 'function token0() view returns (address)'];
const POOL3 = ['function slot0() view returns (uint160,int24,uint16,uint16,uint16,uint32,bool)', 'function liquidity() view returns (uint128)'];
const SMART = ['function exactInputSingle((address tokenIn,address tokenOut,uint24 fee,address recipient,uint256 amountIn,uint256 amountOutMinimum,uint160 sqrtPriceLimitX96)) payable returns (uint256)'];
const QUOTER = ['function quoteExactInputSingle((address tokenIn,address tokenOut,uint256 amountIn,uint24 fee,uint160 sqrtPriceLimitX96)) returns (uint256 amountOut,uint160,uint32,uint256)'];
const FACTORY2 = ['function getPair(address,address) view returns (address)'];

const art = (n) => ({ abi: JSON.parse(fs.readFileSync(path.join(ROOT, 'artifacts', n + '.abi.json'), 'utf8')), bin: '0x' + fs.readFileSync(path.join(ROOT, 'artifacts', n + '.bin'), 'utf8') });
const IFACES = [];
const G = [];   // gas por operacion
async function tx(pr, label, extra) {
  const t = await pr; const rc = await t.wait();
  if (rc.status !== 1) throw new Error('tx revirtio: ' + label);
  G.push({ label, gas: rc.gasUsed, price: rc.gasPrice, ...(extra || {}) });
  log('    tx', label, 'gas', rc.gasUsed.toString());
  return rc;
}
async function expectRevert(name, fn, errName) {
  try { await fn(); ok('NEG ' + name + ' -> ' + errName, false, 'NO revirtio'); }
  catch (e) {
    const d = e.data || (e.info && e.info.error && e.info.error.data) || '';
    let got = e.shortMessage || e.message;
    for (const i of IFACES) { try { const pe = i.parseError(d); if (pe) { got = pe.name + '(' + pe.args.map(String).join(',') + ')'; break; } } catch (_) { } }
    if (typeof d === 'string' && d.startsWith('0x08c379a0')) { try { got = 'Error(' + AC.decode(['string'], '0x' + d.slice(10))[0] + ')'; } catch (_) { } }
    ok('NEG ' + name + ' -> ' + errName, String(got).includes(errName), 'got=' + String(got).slice(0, 100));
  }
}
const evOf = (rc, iface, n) => { for (const l of rc.logs) { try { const e = iface.parseLog({ topics: l.topics, data: l.data }); if (e && e.name === n) return e.args; } catch (_) { } } return null; };
const evAll = (rc, iface, n) => { const r = []; for (const l of rc.logs) { try { const e = iface.parseLog({ topics: l.topics, data: l.data }); if (e && e.name === n) r.push(e.args); } catch (_) { } } return r; };
const fund = (a, bnb) => rpc('anvil_setBalance', a, ethers.toBeHex(ethers.parseEther(String(bnb))));
const fresh = async (bnb) => { const w = ethers.Wallet.createRandom().connect(p); await fund(w.address, bnb || 1000); return w; };
const bal = (t, a) => new ethers.Contract(t, ERC20, p).balanceOf(a);
const gasCost = (rc) => rc.gasUsed * rc.gasPrice;

/// Acredita `amount` de un token BEP20 a `holder` buscando el slot del mapping de balances (anvil_setStorageAt). Solo fork.
async function credit(token, holder, amount) {
  const c = new ethers.Contract(token, ERC20, p);
  for (let slot = 0; slot < 30; slot++) {
    const key = ethers.keccak256(AC.encode(['address', 'uint256'], [holder, slot]));
    const prev = await rpc('eth_getStorageAt', token, key, 'latest');
    await rpc('anvil_setStorageAt', token, key, ethers.toBeHex(amount, 32));
    if ((await c.balanceOf(holder)) === amount) return slot;
    await rpc('anvil_setStorageAt', token, key, prev);
  }
  throw new Error('no encontre el slot de balances de ' + token);
}

(async () => {
  const fork = await p.getBlockNumber();
  const w = await fresh(5000), k = await fresh(100), u = await fresh(2000), rf = await fresh(1), T = await fresh(1), whale = await fresh(2_000_000);
  log('fork block', fork, '· owner/maker', w.address, '· keeper', k.address, '· user', u.address, '· treasury', T.address, '· referrer', rf.address);
  const fee0 = await p.getFeeData();
  log('fee data del fork: gasPrice', fee0.gasPrice && ethers.formatUnits(fee0.gasPrice, 'gwei'), 'gwei · baseFee bloque', (await p.getBlock('latest')).baseFeePerGas);

  const pcs = new ethers.Contract(A.V2_ROUTER, PCS_V2, p), f2 = new ethers.Contract(A.V2_FACTORY, FACTORY2, p);
  const pair2 = new ethers.Contract(A.pools.CAKE_WBNB_V2, PAIR, p), pool3 = new ethers.Contract(A.pools.CAKE_WBNB_V3_2500, POOL3, p), poolU = new ethers.Contract(A.pools.USDT_WBNB_V3_500, POOL3, p);
  const smart = new ethers.Contract(A.SMART_ROUTER, SMART, p), quoter = new ethers.Contract(A.QUOTER_V2, QUOTER, p);
  const wbnb = new ethers.Contract(WBNB, ERC20, p), cake = new ethers.Contract(CAKE, ERC20, p), usdt = new ethers.Contract(USDT, ERC20, p);
  ok('fork: pair V2 CAKE/WBNB token0 == CAKE (orden de reservas que asume el test)', (await pair2.token0()).toLowerCase() === CAKE.toLowerCase());
  const sU = await poolU.slot0(); const sqU = BigInt(sU[0]);
  const bnbUsd = Number((Q << 192n) / (sqU * sqU)) / 1e18;
  ok('fork: precio BNB/USDT del pool V3 500 razonable', bnbUsd > 50 && bnbUsd < 20000, bnbUsd.toFixed(2) + ' USDT por BNB');
  const P3 = async () => { const s = await pool3.slot0(); const sq = BigInt(s[0]); return (sq * sq * Q) >> 192n; };   // WBNB por CAKE x1e18 (token0 = CAKE)
  const P2 = async () => { const r = await pair2.getReserves(); return (BigInt(r[1]) * Q) / BigInt(r[0]); };
  log('precios: CAKE en WBNB · V3 2500', ethers.formatEther(await P3()), '· V2', ethers.formatEther(await P2()), '· liquidez V3', (await pool3.liquidity()).toString());

  // ───────────────────────────── R: ROUTER ─────────────────────────────
  log('\n================ R: ArchitectFeeRouterBSC ================');
  const RA = art('ArchitectFeeRouterBSC'), IR = new ethers.Interface(RA.abi); IFACES.push(IR);
  // un deploy que revierte se prueba con eth_call del initcode (deploy() con gasLimit fijo no espera el recibo)
  const deployCall = (a, types, args) => p.call({ from: w.address, data: a.bin + AC.encode(types, args).slice(2) });
  const T6 = ['address', 'address', 'address', 'address', 'address', 'address'];
  await expectRevert('deploy del router con WBNB equivocado (USDT): el cruce con PancakeRouter.WETH() lo rechaza', () => deployCall(RA, T6, [A.V3_FACTORY, A.V2_ROUTER, A.V2_FACTORY, A.SMART_ROUTER, T.address, USDT]), 'BadRoute');
  await expectRevert('deploy del router con V3 factory equivocada: el cruce con SmartRouter.factory() lo rechaza', () => deployCall(RA, T6, [A.V2_FACTORY, A.V2_ROUTER, A.V2_FACTORY, A.SMART_ROUTER, T.address, WBNB]), 'BadRoute');
  await expectRevert('deploy del router con treasury 0', () => deployCall(RA, T6, [A.V3_FACTORY, A.V2_ROUTER, A.V2_FACTORY, A.SMART_ROUTER, ethers.ZeroAddress, WBNB]), 'ZeroAddress');
  const routerC = await new ethers.ContractFactory(RA.abi, RA.bin, w).deploy(A.V3_FACTORY, A.V2_ROUTER, A.V2_FACTORY, A.SMART_ROUTER, T.address, WBNB);
  const rcDR = await routerC.deploymentTransaction().wait(); G.push({ label: 'router: deploy', gas: rcDR.gasUsed, price: rcDR.gasPrice });
  const router = await routerC.waitForDeployment(); const ROUTER = await router.getAddress();
  log('    router', ROUTER, 'deploy gas', rcDR.gasUsed.toString());
  ok('R0: immutables y defaults (WETH()==WBNB()==WBNB, treasury, fee 100-200 sin referidos, V2_FEE_NUM 9975)',
    (await router.WETH()) === WBNB && (await router.WBNB()) === WBNB && (await router.treasury()) === T.address && (await router.minFeeBps()) === 100n && (await router.maxFeeBps()) === 200n && (await router.V2_FEE_NUM()) === 9975n && (await router.isQuoteToken(WBNB)) && (await router.owner()) === w.address);
  await tx(router.setQuoteToken(USDT, true), 'router.setQuoteToken(USDT)'); await tx(router.setQuoteToken(USDC, true), 'router.setQuoteToken(USDC)');
  ok('R0: USDT y USDC quote tokens; CAKE no', (await router.isQuoteToken(USDT)) && (await router.isQuoteToken(USDC)) && !(await router.isQuoteToken(CAKE)));
  const rU = router.connect(u);
  const pairCake = await f2.getPair(CAKE, WBNB);
  ok('R0: factory V2 devuelve el pair CAKE/WBNB conocido', pairCake.toLowerCase() === A.pools.CAKE_WBNB_V2.toLowerCase(), pairCake);

  // R1: compra por V2 (PancakeRouter) con referidor: fee exacto sobre el input, output == getAmountsOut
  const v1 = ethers.parseEther('2');
  const swapIn1 = v1 - (v1 * BigInt(FEE_BPS)) / 10000n;
  const q1 = await pcs.getAmountsOut(swapIn1, [WBNB, CAKE]);
  const c0 = await cake.balanceOf(u.address), accT0 = await router.accrued(T.address, WBNB), accR0 = await router.accrued(rf.address, WBNB);
  const rc1 = await tx(rU.swapETH(CAKE, q1[1], FEE_BPS, rf.address, expiry(), ROUTE_V2([WBNB, CAKE]), { value: v1 }), 'router: swapETH BNB->CAKE V2 (PancakeRouter path)');
  const sw1 = evOf(rc1, IR, 'Swap');
  ok('R1: CAKE recibido == getAmountsOut(valor - 1 %) (fee 0,25 % de PancakeSwap, sin tax)', (await cake.balanceOf(u.address)) - c0 === q1[1] && sw1.amountOut === q1[1], q1[1].toString());
  ok('R1: fee 1 % del BNB, TODO a la tesoreria (sin referidos); el referrer de la llamada no cobra nada', sw1.feeAmount === v1 / 100n && sw1.feeToken === WBNB && (await router.accrued(T.address, WBNB)) - accT0 === v1 / 100n && (await router.accrued(rf.address, WBNB)) - accR0 === 0n);
  ok('R1: el evento Swap lleva referrer 0 aunque la llamada mando uno', sw1.referrer === ethers.ZeroAddress);
  ok('R1: el router tiene el WBNB de los fees (balance >= acumulado)', (await wbnb.balanceOf(ROUTER)) >= (await router.accrued(T.address, WBNB)));

  // R2: compra por V2_DIRECT (pair): output == formula 9975/10000 sobre reservas
  const v2 = ethers.parseEther('1');
  const swapIn2 = v2 - v2 / 100n;
  const rs = await pair2.getReserves(); const rIn = BigInt(rs[1]), rOut = BigInt(rs[0]);   // WBNB -> CAKE: in = reserve1 (WBNB), out = reserve0 (CAKE)
  const calc2 = (swapIn2 * 9975n * rOut) / (rIn * 10000n + swapIn2 * 9975n);
  const c1 = await cake.balanceOf(u.address);
  const rc2 = await tx(rU.swapETH(CAKE, calc2, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE_V2D(pairCake), { value: v2 }), 'router: swapETH BNB->CAKE V2_DIRECT (pair)');
  ok('R2: V2_DIRECT: CAKE recibido == formula 9975/10000 sobre las reservas (sin pasar por el PancakeRouter)', (await cake.balanceOf(u.address)) - c1 === calc2, calc2.toString());
  ok('R2: sin referidos: el evento lleva referrer 0', evOf(rc2, IR, 'Swap').referrer === ethers.ZeroAddress);
  await expectRevert('V2_DIRECT con feeNum 9970 en un pair de la factory (tiene que ser 9975)', () => rU.swapETH.staticCall(CAKE, 1, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE_V2D(pairCake, 9970), { value: v2 }), 'BadRoute');
  await expectRevert('V2_DIRECT con un pair falso (no esta en la factory)', () => rU.swapETH.staticCall(CAKE, 1, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE_V2D(u.address), { value: v2 }), 'BadPool');
  await expectRevert('V2_DIRECT con feeNum 10001', () => rU.swapETH.staticCall(CAKE, 1, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE_V2D(pairCake, 10001), { value: v2 }), 'BadRoute');

  // R3: venta por V2_DIRECT cobrando BNB: fee sobre el output en WBNB
  const sell3 = (await cake.balanceOf(u.address)) / 3n;
  await tx(cake.connect(u).approve(ROUTER, sell3), 'CAKE.approve(router)');
  const rs3 = await pair2.getReserves(); const calc3 = (sell3 * 9975n * BigInt(rs3[1])) / (BigInt(rs3[0]) * 10000n + sell3 * 9975n);
  const b3 = await p.getBalance(u.address); const accT3 = await router.accrued(T.address, WBNB);
  const rc3 = await tx(rU.swapToETH(CAKE, sell3, calc3 - calc3 / 100n, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE_V2D(pairCake)), 'router: swapToETH CAKE->BNB V2_DIRECT');
  const sw3 = evOf(rc3, IR, 'Swap');
  ok('R3: el pool pago la formula exacta, el usuario cobro el 99 % en BNB nativo, fee 1 % en WBNB', sw3.feeAmount === calc3 / 100n && sw3.amountOut === calc3 - calc3 / 100n && (await p.getBalance(u.address)) - b3 + gasCost(rc3) === sw3.amountOut, W(sw3.amountOut));
  ok('R3: la tesoreria acumulo el 100 % del fee de la venta', (await router.accrued(T.address, WBNB)) - accT3 === calc3 / 100n);
  ok('R3: sin allowance viva del router hacia el PancakeRouter ni CAKE suelto en el router', (await cake.allowance(ROUTER, A.V2_ROUTER)) === 0n && (await cake.balanceOf(ROUTER)) === 0n);

  // R4: compra por V3 (pool directo, fee 2500) == QuoterV2
  const v4 = ethers.parseEther('1');
  const swapIn4 = v4 - v4 / 100n;
  const q4 = await quoter.quoteExactInputSingle.staticCall({ tokenIn: WBNB, tokenOut: CAKE, amountIn: swapIn4, fee: 2500, sqrtPriceLimitX96: 0 });
  const c4 = await cake.balanceOf(u.address);
  await tx(rU.swapETH(CAKE, q4[0], FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE_V3(2500), { value: v4 }), 'router: swapETH BNB->CAKE V3 pool directo (2500)');
  ok('R4: V3 directo: CAKE recibido == QuoterV2.quoteExactInputSingle (callback pancakeV3SwapCallback pago al pool)', (await cake.balanceOf(u.address)) - c4 === q4[0], q4[0].toString());
  for (const fee of [100, 500, 10000]) {
    const qf = await quoter.quoteExactInputSingle.staticCall({ tokenIn: WBNB, tokenOut: CAKE, amountIn: ethers.parseEther('0.0495'), fee, sqrtPriceLimitX96: 0 }).catch(() => null);
    if (!qf || qf[0] === 0n) { skip('R4: V3 fee tier ' + fee + ' CAKE/WBNB', 'pool sin liquidez para cotizar'); continue; }
    const cb = await cake.balanceOf(u.address);
    await tx(rU.swapETH(CAKE, qf[0], FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE_V3(fee), { value: ethers.parseEther('0.05') }), 'router: swapETH V3 fee tier ' + fee);
    ok('R4: V3 fee tier ' + fee + ': output == QuoterV2', (await cake.balanceOf(u.address)) - cb === qf[0]);
  }
  await expectRevert('V3 con un fee tier inexistente (1234) -> BadPool', () => rU.swapETH.staticCall(CAKE, 1, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE_V3(1234), { value: v4 }), 'BadPool');
  // R5: venta por V3 cobrando BNB
  const sell5 = (await cake.balanceOf(u.address)) / 4n;
  await tx(cake.connect(u).approve(ROUTER, sell5), 'CAKE.approve(router)');
  const q5 = await quoter.quoteExactInputSingle.staticCall({ tokenIn: CAKE, tokenOut: WBNB, amountIn: sell5, fee: 2500, sqrtPriceLimitX96: 0 });
  const b5 = await p.getBalance(u.address);
  const rc5 = await tx(rU.swapToETH(CAKE, sell5, q5[0] - q5[0] / 100n, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE_V3(2500)), 'router: swapToETH CAKE->BNB V3 (2500)');
  const sw5 = evOf(rc5, IR, 'Swap');
  ok('R5: V3 venta: recibido == quoter, fee 1 % del output, BNB nativo al usuario', sw5.feeAmount === q5[0] / 100n && (await p.getBalance(u.address)) - b5 + gasCost(rc5) === q5[0] - q5[0] / 100n);
  // R6: USDT: compra por V2, y swap() ERC20 USDT->CAKE por V3_PATH (USDT-500-WBNB-2500-CAKE), fee en USDT (quote input)
  await tx(rU.swapETH(USDT, 1, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE_V2([WBNB, USDT]), { value: ethers.parseEther('3') }), 'router: swapETH BNB->USDT V2');
  const uUsdt = await usdt.balanceOf(u.address);
  ok('R6: el usuario tiene USDT (18 decimales en BSC)', uUsdt > ethers.parseEther('100') && (await usdt.decimals()) === 18n, ethers.formatEther(uUsdt) + ' USDT');
  const in6 = uUsdt / 3n;
  await tx(usdt.connect(u).approve(ROUTER, in6), 'USDT.approve(router)');
  const c6 = await cake.balanceOf(u.address), accT6 = await router.accrued(T.address, USDT);
  const rc6 = await tx(rU.swap(USDT, CAKE, in6, 1, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE_V3P([USDT, WBNB, CAKE], [500, 2500])), 'router: swap USDT->CAKE V3_PATH 2 hops (SmartRouter)');
  const sw6 = evOf(rc6, IR, 'Swap');
  ok('R6: V3_PATH (SmartRouter exactInput) entrego CAKE al usuario y el fee se cobro en USDT (input quote)', (await cake.balanceOf(u.address)) - c6 === sw6.amountOut && sw6.amountOut > 0n && sw6.feeToken === USDT && sw6.feeAmount === in6 / 100n && (await router.accrued(T.address, USDT)) - accT6 === in6 / 100n, sw6.amountOut.toString() + ' CAKE');
  ok('R6: sin allowance viva hacia el SmartRouter, sin USDT ni CAKE sueltos en el router', (await usdt.allowance(ROUTER, A.SMART_ROUTER)) === 0n && (await usdt.balanceOf(ROUTER)) === (await router.accrued(T.address, USDT)) + (await router.accrued(rf.address, USDT)) && (await cake.balanceOf(ROUTER)) === 0n);
  // R7: paths al reves (los bots usan una sola ruta para comprar y vender)
  await tx(usdt.connect(u).approve(ROUTER, in6), 'USDT.approve(router)');
  const c7 = await cake.balanceOf(u.address);
  await tx(rU.swap(USDT, CAKE, in6, 1, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE_V3P([CAKE, WBNB, USDT], [2500, 500])), 'router: swap USDT->CAKE con V3_PATH escrito al reves');
  ok('R7: V3_PATH al reves se oriento solo y entrego CAKE', (await cake.balanceOf(u.address)) - c7 > 0n);
  const sell7 = (await cake.balanceOf(u.address)) / 5n;
  await tx(cake.connect(u).approve(ROUTER, sell7), 'CAKE.approve(router)');
  const u7 = await usdt.balanceOf(u.address);
  const rc7 = await tx(rU.swap(CAKE, USDT, sell7, 1, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE_V2([USDT, WBNB, CAKE])), 'router: swap CAKE->USDT con ROUTE_V2 path al reves (2 hops)');
  const sw7 = evOf(rc7, IR, 'Swap');
  ok('R7: ROUTE_V2 al reves se dio vuelta; venta a quote: fee sobre el output en USDT', (await usdt.balanceOf(u.address)) - u7 === sw7.amountOut && sw7.feeToken === USDT && sw7.feeAmount > 0n);
  await tx(cake.connect(u).approve(ROUTER, 1000n), 'CAKE.approve(router) para los negativos');
  await expectRevert('ROUTE_V2 con un path que no toca tokenIn/tokenOut', () => rU.swap.staticCall(CAKE, USDT, 1n, 1, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE_V2([WBNB, USDC])), 'BadRoute');
  await expectRevert('V3_PATH con un path que no toca tokenIn/tokenOut', () => rU.swap.staticCall(CAKE, USDT, 1n, 1, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE_V3P([WBNB, USDC], [500])), 'BadRoute');
  await expectRevert('V3_PATH mal formado (largo)', () => rU.swap.staticCall(CAKE, USDT, 1n, 1, FEE_BPS, ethers.ZeroAddress, expiry(), AC.encode(['uint8', 'bytes'], [4, AC.encode(['bytes'], ['0x1234'])])), 'BadRoute');
  // R8: quote-token checks y limites
  await expectRevert('swap CAKE->FLOKI (ninguno es quote) sin allowExoticPairs', () => rU.swap.staticCall(CAKE, FLOKI, 1n, 1, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE_V2([CAKE, WBNB, FLOKI])), 'NoQuoteToken');
  await expectRevert('feeBps 50 (< piso 100)', () => rU.swapETH.staticCall(CAKE, 1, 50, ethers.ZeroAddress, expiry(), ROUTE_V3(2500), { value: v4 }), 'FeeTooLow');
  await expectRevert('feeBps 90 (la vieja tarifa referida ya no existe en BSC)', () => rU.swapETH.staticCall(CAKE, 1, 90, ethers.ZeroAddress, expiry(), ROUTE_V3(2500), { value: v4 }), 'FeeTooLow');
  await expectRevert('feeBps 250 (> techo 200)', () => rU.swapETH.staticCall(CAKE, 1, 250, ethers.ZeroAddress, expiry(), ROUTE_V3(2500), { value: v4 }), 'FeeTooHigh');
  await expectRevert('deadline vencido', () => rU.swapETH.staticCall(CAKE, 1, FEE_BPS, ethers.ZeroAddress, 1n, ROUTE_V3(2500), { value: v4 }), 'Expired');
  await expectRevert('swapETH con tokenOut == WBNB', () => rU.swapETH.staticCall(WBNB, 1, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE_V3(2500), { value: v4 }), 'BadRoute');
  await expectRevert('swap con tokenIn == tokenOut', () => rU.swap.staticCall(CAKE, CAKE, 1n, 1, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE_V3(2500)), 'BadRoute');
  await expectRevert('ruta kind 2 (era V4 en Robinhood; no existe en BSC)', () => rU.swapETH.staticCall(CAKE, 1, FEE_BPS, ethers.ZeroAddress, expiry(), AC.encode(['uint8', 'bytes'], [2, '0x']), { value: v4 }), 'BadRoute');
  await expectRevert('ruta kind 9', () => rU.swapETH.staticCall(CAKE, 1, FEE_BPS, ethers.ZeroAddress, expiry(), AC.encode(['uint8', 'bytes'], [9, '0x']), { value: v4 }), 'BadRoute');
  await expectRevert('swapWithFee desde una cuenta que no es caller', () => rU.swapWithFee.staticCall(WBNB, CAKE, 1n, 1, u.address, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE_V3(2500)), 'NotCaller');
  await expectRevert('pancakeV3SwapCallback llamado por un EOA (no es el pool)', () => rU.pancakeV3SwapCallback.staticCall(1, 1, '0x'), 'BadPool');
  await expectRevert('slippage: minAmountOut imposible', () => rU.swapETH.staticCall(CAKE, ethers.parseEther('1000000'), FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE_V3(2500), { value: v4 }), 'Slippage');
  await tx(router.setPaused(true), 'router.setPaused(true)');
  await expectRevert('swap con el router pausado', () => rU.swapETH.staticCall(CAKE, 1, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE_V3(2500), { value: v4 }), 'IsPaused');
  await tx(router.setPaused(false), 'router.setPaused(false)');
  await expectRevert('setTreasury desde el usuario', () => rU.setTreasury.staticCall(u.address), 'NotOwner');
  await expectRevert('setMaxFeeBps 301 (> 300)', () => router.setMaxFeeBps.staticCall(301), 'techo');
  // exotic pair: CAKE -> FLOKI con allowExoticPairs (fee en FLOKI, medido por delta; FLOKI tiene tax 0,3 %)
  await tx(router.setAllowExoticPairs(true), 'router.setAllowExoticPairs(true)');
  const sell8 = (await cake.balanceOf(u.address)) / 10n;
  await tx(cake.connect(u).approve(ROUTER, sell8), 'CAKE.approve(router)');
  const fl0 = await bal(FLOKI, u.address);
  const rc8 = await tx(rU.swap(CAKE, FLOKI, sell8, 1, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE_V2([CAKE, WBNB, FLOKI])), 'router: swap CAKE->FLOKI exotic (fee en FLOKI, token con tax)');
  const sw8 = evOf(rc8, IR, 'Swap');
  ok('R8: par exotico con allowExoticPairs: fee en FLOKI, usuario recibio el delta medido (post-tax)', sw8.feeToken.toLowerCase() === FLOKI && (await bal(FLOKI, u.address)) - fl0 > 0n && sw8.amountOut > 0n);
  await tx(router.setAllowExoticPairs(false), 'router.setAllowExoticPairs(false)');
  // R9: claim
  const wr0 = await wbnb.balanceOf(rf.address);
  const rcC = await tx(router.connect(rf).claim(WBNB), 'router: claim (el que antes era referidor, WBNB)');
  ok('R9: sin referidos: el referrer no acumulo nada y su claim entrega 0', (await router.accrued(rf.address, WBNB)) === 0n && (await wbnb.balanceOf(rf.address)) === wr0 && evOf(rcC, IR, 'Claimed').amount === 0n);
  const accTT = await router.accrued(T.address, WBNB);
  await tx(router.connect(T).claim(WBNB), 'router: claim (tesoreria, WBNB)');
  await tx(router.connect(T).claim(USDT), 'router: claim (tesoreria, USDT)');
  ok('R9: la tesoreria reclamo WBNB y USDT', (await wbnb.balanceOf(T.address)) === accTT && (await usdt.balanceOf(T.address)) > 0n && (await router.accrued(T.address, WBNB)) === 0n);
  ok('R9: claim sin saldo no revierte y da 0', (await router.connect(rf).claim.staticCall(USDC)) === 0n);
  // R10: pendingEth con un receptor que revierte
  const MA = art('GreedyReceiver'), IG = new ethers.Interface(MA.abi);
  const greedy = await (await new ethers.ContractFactory(MA.abi, MA.bin, w).deploy()).waitForDeployment(); const GR = await greedy.getAddress();
  await fund(GR, 10);
  await tx(greedy.exec(ROUTER, IR.encodeFunctionData('swapETH', [CAKE, 1, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE_V3(2500)]), { value: ethers.parseEther('1') }), 'greedy: swapETH (compra CAKE)');
  const gc = await cake.balanceOf(GR);
  await tx(greedy.exec(CAKE, new ethers.Interface(ERC20).encodeFunctionData('approve', [ROUTER, gc])), 'greedy: approve');
  await tx(greedy.setReject(true), 'greedy.setReject(true)');
  const rc10 = await tx(greedy.exec(ROUTER, IR.encodeFunctionData('swapToETH', [CAKE, gc, 1, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE_V3(2500)])), 'greedy: swapToETH con receive() que revierte');
  const ep = evOf(rc10, IR, 'EthPending');
  ok('R10: el swap NO se bloqueo: EthPending emitido y pendingEth == amountOut', ep && ep.amount === evOf(rc10, IR, 'Swap').amountOut && (await router.pendingEth(GR)) === ep.amount, W(ep ? ep.amount : 0n));
  await tx(greedy.setReject(false), 'greedy.setReject(false)');
  const gb0 = await p.getBalance(GR);
  await tx(greedy.exec(ROUTER, IR.encodeFunctionData('withdrawEth', [])), 'greedy: withdrawEth');
  ok('R10: withdrawEth cobro el pendiente', (await p.getBalance(GR)) - gb0 === ep.amount && (await router.pendingEth(GR)) === 0n);
  // R11: token REAL con tax (PIT): compra por V2, venta por V2_DIRECT (una tax) y por V2 router (dos taxes)
  const pairPit = await f2.getPair(PIT, WBNB);
  if (pairPit === ethers.ZeroAddress) skip('R11 PIT', 'sin pair'); else {
    const pit = new ethers.Contract(PIT, ERC20, p);
    const vP = ethers.parseEther('0.5'); const qP = await pcs.getAmountsOut(vP - vP / 100n, [WBNB, PIT]);
    const pb0 = await pit.balanceOf(u.address);
    const rcP = await tx(rU.swapETH(PIT, 1, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE_V2([WBNB, PIT]), { value: vP }), 'router: swapETH BNB->PIT (token real con tax) V2');
    const gotP = (await pit.balanceOf(u.address)) - pb0; const taxP = Number((qP[1] - gotP) * 10000n / qP[1]) / 100;
    ok('R11: PIT (tax real): recibido < cotizacion, medido por delta (evento == delta), sin revert', gotP > 0n && gotP < qP[1] && evOf(rcP, IR, 'Swap').amountOut === gotP, 'tax ~' + taxP + ' %');
    const half = gotP / 2n;
    await tx(pit.connect(u).approve(ROUTER, gotP), 'PIT.approve(router)');
    const rb0 = await p.getBalance(u.address);
    const rcP1 = await tx(rU.swapToETH(PIT, half, 1, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE_V2D(pairPit)), 'router: swapToETH PIT->BNB V2_DIRECT (tax una vez)');
    const outD = evOf(rcP1, IR, 'Swap').amountOut;
    const rcP2 = await tx(rU.swapToETH(PIT, gotP - half, 1, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE_V2([PIT, WBNB])), 'router: swapToETH PIT->BNB V2 router (tax dos veces)');
    const outR = evOf(rcP2, IR, 'Swap').amountOut;
    ok('R11: vender PIT funciona por las dos rutas; el pair directo rinde mas que pasar por el PancakeRouter (una tax menos)', outD > 0n && outR > 0n && outD > outR, 'directo ' + W(outD) + ' vs router ' + W(outR));
    ok('R11: el usuario cobro en BNB lo que dicen los eventos; el router no retuvo PIT', (await p.getBalance(u.address)) - rb0 + gasCost(rcP1) + gasCost(rcP2) === outD + outR && (await pit.balanceOf(ROUTER)) === 0n);
  }

  // ───────────────────────────── bots: deploy ─────────────────────────────
  log('\n================ I: ArchitectInfinityGridV4BSC ================');
  const IA = art('ArchitectInfinityGridV4BSC'), II = new ethers.Interface(IA.abi); IFACES.push(II);
  const SA = art('ArchitectSpotGridV4BSC'), IS = new ethers.Interface(SA.abi); IFACES.push(IS);
  await expectRevert('deploy del Infinity con WBNB != router.WETH()', () => deployCall(IA, ['address', 'address', 'address'], [ROUTER, USDT, k.address]), 'BadGrid');
  await expectRevert('deploy del Infinity con router 0', () => deployCall(IA, ['address', 'address', 'address'], [ethers.ZeroAddress, WBNB, k.address]), 'ZeroAddress');
  const infC = await new ethers.ContractFactory(IA.abi, IA.bin, w).deploy(ROUTER, WBNB, k.address);
  const rcDI = await infC.deploymentTransaction().wait(); G.push({ label: 'infinity: deploy', gas: rcDI.gasUsed, price: rcDI.gasPrice });
  const inf = await infC.waitForDeployment(); const INF = await inf.getAddress(); const infK = inf.connect(k);
  const spotC = await new ethers.ContractFactory(SA.abi, SA.bin, w).deploy(ROUTER, WBNB, k.address);
  const rcDS = await spotC.deploymentTransaction().wait(); G.push({ label: 'spot: deploy', gas: rcDS.gasUsed, price: rcDS.gasPrice });
  const spot = await spotC.waitForDeployment(); const SPOT = await spot.getAddress(); const spotK = spot.connect(k);
  log('    infinity', INF, 'gas', rcDI.gasUsed.toString(), '· spot', SPOT, 'gas', rcDS.gasUsed.toString());
  await tx(router.setCaller(INF, true), 'router.setCaller(infinity)'); await tx(router.setCaller(SPOT, true), 'router.setCaller(spot)');
  ok('I0: deploy: keeper allowlisteado, owner = deployer, gasOverhead 40000 (BSC), piso 0,05 gwei, techo 5 gwei, WETH()==WBNB()==WBNB, callers en el router',
    (await inf.isKeeper(k.address)) && (await inf.owner()) === w.address && (await inf.gasOverhead()) === 40000n && (await inf.gasPriceFloor()) === 50_000_000n && (await inf.gasPriceCap()) === 5n * GWEI && (await inf.WETH()) === WBNB && (await inf.WBNB()) === WBNB && (await router.isCaller(INF)) && (await router.isCaller(SPOT)));

  // helpers de precio / pump / dump sobre el pool V3 2500 (Infinity) y el pair V2 (Spot)
  const smartW = smart.connect(whale), pcsW = pcs.connect(whale), cakeW = cake.connect(whale);
  const CHUNK3 = ethers.parseEther('20');
  async function pump3(target, label) {
    let P = await P3(); let n = 0;
    while (P <= target && n < 80) { await (await smartW.exactInputSingle({ tokenIn: WBNB, tokenOut: CAKE, fee: 2500, recipient: whale.address, amountIn: CHUNK3, amountOutMinimum: 0, sqrtPriceLimitX96: 0 }, { value: CHUNK3 })).wait(); P = await P3(); n++; }
    log('    ' + (label || 'PUMP V3') + ': ' + n + ' x ' + W(CHUNK3) + ' -> P3 ' + ethers.formatEther(P));
    return P;
  }
  await credit(CAKE, whale.address, ethers.parseEther('3000000'));
  ok('fork: whale acreditado con CAKE para los dumps', (await cake.balanceOf(whale.address)) >= ethers.parseEther('3000000'));
  await (await cakeW.approve(A.SMART_ROUTER, ethers.MaxUint256)).wait(); await (await cakeW.approve(A.V2_ROUTER, ethers.MaxUint256)).wait();
  async function dump3(target, chunkCake, label) {
    let P = await P3(); let n = 0;
    while (P > target && n < 200) { await (await smartW.exactInputSingle({ tokenIn: CAKE, tokenOut: WBNB, fee: 2500, recipient: whale.address, amountIn: chunkCake, amountOutMinimum: 0, sqrtPriceLimitX96: 0 })).wait(); P = await P3(); n++; }
    log('    ' + (label || 'DUMP V3') + ': ' + n + ' x ' + ethers.formatEther(chunkCake) + ' CAKE -> P3 ' + ethers.formatEther(P));
    return P;
  }
  const CHUNK2 = ethers.parseEther('100');
  async function pump2(target, label) {
    let P = await P2(); let n = 0;
    while (P <= target && n < 80) { await (await pcsW.swapExactETHForTokens(0, [WBNB, CAKE], whale.address, expiry(), { value: CHUNK2 })).wait(); P = await P2(); n++; }
    log('    ' + (label || 'PUMP V2') + ': ' + n + ' x ' + W(CHUNK2) + ' -> P2 ' + ethers.formatEther(P));
    return P;
  }
  async function dump2(target, chunkCake, label) {
    let P = await P2(); let n = 0;
    while (P > target && n < 200) { await (await pcsW.swapExactTokensForETH(chunkCake, 0, [CAKE, WBNB], whale.address, expiry())).wait(); P = await P2(); n++; }
    log('    ' + (label || 'DUMP V2') + ': ' + n + ' x ' + ethers.formatEther(chunkCake) + ' CAKE -> P2 ' + ethers.formatEther(P));
    return P;
  }

  // ───────────────────────────── I: INFINITY sobre CAKE/WBNB V3 2500 ─────────────────────────────
  const RT3 = ROUTE_V3(2500);
  const V = ethers.parseEther('0.5'), RES = ethers.parseEther('1'), GAS = ethers.parseEther('0.02'), STEP = 300;
  const baseI = async (over) => ({ V, P0: 0n, stepBps: STEP, floorPrice: pct(await P3(), 50), tpPrice: 0n, slPrice: 0n, expiry: expiry(), feeBps: FEE_BPS, referrer: rf.address, compound: false, ...(over || {}) });
  const seedMin3 = async (v) => (((v || V) * Q) / (await P3())) * 90n / 100n;
  const idOfI = (rc) => evOf(rc, II, 'GridOpened').id;
  const abrirI = async (over, gas, label) => { const g = gas === undefined ? GAS : gas; const rc = await tx(inf.openWithEth(CAKE, RT3, await baseI(over), await seedMin3(), g, { value: V + RES + g }), label || 'infinity: openWithEth (seed buy V3)'); return { rc, id: idOfI(rc) }; };
  const KP = { gasPrice: GWEI };   // el keeper manda tx legacy a 1 gwei (BSC: basefee 0, precio legacy)
  const keeperPaid = async (rc, IF, label) => {
    const gp = evOf(rc, IF, 'GasPaid'); const real = gasCost(rc);
    if (gp) { G[G.length - 1].owed = gp.owed; G[G.length - 1].ratio = Number(gp.owed * 1000n / real) / 1000; }
    return gp;
  };

  log('\n== I1 abrir con reserva de gas');
  await expectRevert('abrir con msg.value < V + gas declarado', async () => inf.openWithEth.staticCall(CAKE, RT3, await baseI(), await seedMin3(), GAS, { value: V + GAS - 1n }), 'BadValue');
  await expectRevert('abrir con V = 0', async () => inf.openWithEth.staticCall(CAKE, RT3, await baseI({ V: 0n }), await seedMin3(), GAS, { value: RES + GAS }), 'BadValue');
  await expectRevert('abrir con step 100 bps (< 250)', async () => inf.openWithEth.staticCall(CAKE, RT3, await baseI({ stepBps: 100 }), await seedMin3(), GAS, { value: V + RES + GAS }), 'BadParams');
  await expectRevert('abrir con SL por encima del ancla', async () => inf.openWithEth.staticCall(CAKE, RT3, await baseI({ slPrice: pct(await P3(), 150) }), await seedMin3(), GAS, { value: V + RES + GAS }), 'BadParams');
  await expectRevert('abrir con feeBps 50 (fuera del rango del router)', async () => inf.openWithEth.staticCall(CAKE, RT3, await baseI({ feeBps: 50 }), await seedMin3(), GAS, { value: V + RES + GAS }), 'BadFee');
  await expectRevert('abrir con token == WBNB', async () => inf.openWithEth.staticCall(WBNB, RT3, await baseI(), await seedMin3(), GAS, { value: V + RES + GAS }), 'BadGrid');
  const accT_I0 = await router.accrued(T.address, WBNB), accR_I0 = await router.accrued(rf.address, WBNB);   // el grid se abre CON referrer: se tiene que ignorar
  const { rc: rcI1, id: id1 } = await abrirI({}, GAS);
  let g = await inf.grid(id1);
  const gaI = evOf(rcI1, II, 'GasAdded'), goI = evOf(rcI1, II, 'GridOpened');
  ok('I1: grid.gasReserve == reserva, gasEscrowed == reserva, GasAdded emitido', g.gasReserve === GAS && (await inf.gasEscrowed()) === GAS && gaI && gaI.amount === GAS);
  ok('I1: escrowed[WBNB] == reserva de compra + gas (V se gasto en el seed)', (await inf.escrowed(WBNB)) === RES + GAS);
  ok('I1: quoteHeld == reserva, V == 0.5, P0 > 0, base > 0, lastK == 0, referrer en 0 aunque se mando uno', g.quoteHeld === RES && g.V === V && g.P0 > 0n && g.baseHeld > 0n && g.lastK === 0n && g.referrer === ethers.ZeroAddress, 'P0=' + ethers.formatEther(g.P0) + ' WBNB/CAKE · base=' + ethers.formatEther(g.baseHeld) + ' CAKE');
  ok('I1: GridOpened.quoteIn == V + reserva (sin el gas), baseIn == baseHeld, routeHash == keccak(route)', goI.quoteIn === V + RES && goI.baseIn === g.baseHeld && goI.routeHash === ethers.keccak256(RT3));
  ok('I1: balance WBNB cubre lo escrowado; escrowed[CAKE] == baseHeld', (await wbnb.balanceOf(INF)) >= (await inf.escrowed(WBNB)) && (await inf.escrowed(CAKE)) === g.baseHeld);
  ok('I1: el seed pago 1 % al router, TODO a la tesoreria (el referrer del grid no cobra)', (await router.accrued(T.address, WBNB)) - accT_I0 === V / 100n && (await router.accrued(rf.address, WBNB)) - accR_I0 === 0n);
  await expectRevert('rescue(WBNB) del owner con la reserva adentro', () => inf.rescue.staticCall(WBNB, w.address), 'NothingToRefund');
  await expectRevert('rescue(CAKE) del owner con el base escrowado', () => inf.rescue.staticCall(CAKE, w.address), 'NothingToRefund');

  log('\n== I2 fillUp paga al keeper (hay que subir el precio un escalon)');
  await expectRevert('fillUp antes de que el precio suba (el router corta por slippage)', () => infK.fillUp.staticCall(id1, RT3, KP), 'Slippage');
  const P1 = await pump3(pct(g.P0, 10300 + 150, 10000), 'PUMP V3 por encima de P1');
  ok('I2: el pump movio el precio por encima de P_1', P1 > pct(g.P0, 103), ethers.formatEther(P1));
  const nu = await inf.nextUp(id1);
  ok('I2: nextUp dice k=1 con base a vender > 0 y pk == P0*1.03', nu.k === 1n && nu.sellAmt > 0n && nu.pk === (g.P0 * 10300n) / 10000n);
  await expectRevert('fillUp desde el maker (no es keeper)', () => inf.fillUp.staticCall(id1, RT3), 'NotKeeper');
  const kw0 = await wbnb.balanceOf(k.address);
  const rcI2 = await tx(infK.fillUp(id1, RT3, KP), 'infinity: fillUp (sell V3)');
  const gp = await keeperPaid(rcI2, II), gf = evOf(rcI2, II, 'GridFilled');
  g = await inf.grid(id1);
  ok('I2: GasPaid al keeper, owed > 0, cobrado EXACTAMENTE en WBNB', gp && gp.keeper === k.address && gp.owed > 0n && (await wbnb.balanceOf(k.address)) - kw0 === gp.owed, 'owed=' + W(gp.owed));
  ok('I2: owed >= costo real (gasUsed x 1 gwei) y <= 1.6x', gp.owed >= gasCost(rcI2) && gp.owed <= gasCost(rcI2) * 16n / 10n, 'owed/real = ' + G[G.length - 1].ratio);
  ok('I2: gasReserve y gasEscrowed bajaron owed; escrowed[WBNB] == quoteHeld + gasReserve', g.gasReserve === GAS - gp.owed && (await inf.gasEscrowed()) === GAS - gp.owed && (await inf.escrowed(WBNB)) === g.quoteHeld + g.gasReserve);
  ok('I2: GridFilled SELL k=1, profit > 0, lastK 1, base == V/P1, profit == gain, V sin cambios', gf && gf.side === 1n && gf.level === 1n && gf.profit > 0n && g.lastK === 1n && g.baseHeld === (V * Q) / nu.pk && g.profit === gf.profit && g.V === V, 'gain=' + W(gf.profit));
  ok('I2: sin allowance viva hacia el router', (await cake.allowance(INF, ROUTER)) === 0n);
  await pump3(pct(await inf.levelPrice(id1, 2), 1015, 1000), 'PUMP V3 por encima de P2');
  const rcI2b = await tx(infK.fillUp(id1, RT3, KP), 'infinity: fillUp k=2'); await keeperPaid(rcI2b, II);
  ok('I2: segundo fillUp en k=2 (el precio ya estaba arriba)', evOf(rcI2b, II, 'GridFilled').level === 2n && (await inf.grid(id1)).lastK === 2n);

  log('\n== I3 fillDown paga al keeper (hay que bajar el precio)');
  g = await inf.grid(id1);
  const pDown = (g.P0 * 10300n) / 10000n;
  const Pd = await dump3(pct(pDown, 98), ethers.parseEther('2000'), 'DUMP V3 por debajo de P1');
  ok('I3: el dump dejo el precio por debajo de P_1', Pd < pDown);
  const nd = await inf.nextDown(id1);
  ok('I3: nextDown dice k=1 con quote a gastar > 0 (V - valor actual)', nd.k === 1n && nd.buyQuote > 0n && nd.buyQuote <= g.quoteHeld, W(nd.buyQuote));
  const kw2 = await wbnb.balanceOf(k.address);
  const rcI3 = await tx(infK.fillDown(id1, RT3, KP), 'infinity: fillDown (buy V3)');
  const gp3 = await keeperPaid(rcI3, II), gf3 = evOf(rcI3, II, 'GridFilled'); const g3 = await inf.grid(id1);
  ok('I3: GasPaid y cobrado en WBNB; owed >= real', gp3 && (await wbnb.balanceOf(k.address)) - kw2 === gp3.owed && gp3.owed >= gasCost(rcI3), 'owed/real = ' + G[G.length - 1].ratio);
  ok('I3: GridFilled BUY k=1, amountIn == buyQuote, lastK 1, lote anotado, valor ~V', gf3 && gf3.side === 0n && gf3.level === 1n && gf3.amountIn === nd.buyQuote && g3.lastK === 1n && (await inf.lotAt(id1, 1)).cost === nd.buyQuote && (g3.baseHeld * pDown) / Q >= pct(V, 99));

  log('\n== I4 NoGas y pre-flight NO ciego (piso de precio de gas)');
  const { id: id4a } = await abrirI({}, 1n, 'infinity: openWithEth reserva 1 wei'); const { id: id4b } = await abrirI({}, 0n, 'infinity: openWithEth reserva 0');
  await pump3(pct((await inf.grid(id4a)).P0, 10300 + 150, 10000), 'PUMP V3 un escalon para los nuevos');
  ok('I4: hay algo que vender', (await inf.nextUp(id4a)).sellAmt > 0n);
  await expectRevert('fillUp con 1 wei de reserva (tx a 1 gwei)', () => infK.fillUp.staticCall(id4a, RT3, KP), 'NoGas');
  await expectRevert('fillUp con reserva 0', () => infK.fillUp.staticCall(id4b, RT3, KP), 'NoGas');
  await expectRevert('PRE-FLIGHT: staticCall con gasPrice 0 (como eth_call en BSC) igual dispara NoGas gracias al piso', () => infK.fillUp.staticCall(id4a, RT3, { gasPrice: 0 }), 'NoGas');

  log('\n== I5 techo y piso del precio de gas');
  const { id: id5 } = await abrirI({}, ethers.parseEther('0.1'), 'infinity: openWithEth reserva 0.1');
  await pump3(pct((await inf.grid(id5)).P0, 10300 + 150, 10000), 'PUMP V3');
  const rcI5 = await tx(infK.fillUp(id5, RT3, { gasPrice: 50n * GWEI }), 'infinity: fillUp con gasPrice 50 gwei (techo 5)');
  const gp5 = evOf(rcI5, II, 'GasPaid'); const units5 = gp5.owed / (5n * GWEI);
  ok('I5: con tx a 50 gwei el grid pago a 5 gwei (techo): unidades cobradas ~ gasUsed + overhead, no 10x', units5 >= rcI5.gasUsed - 20000n && units5 <= rcI5.gasUsed + 80000n && gp5.owed < gasCost(rcI5), 'unidades=' + units5 + ' gasUsed=' + rcI5.gasUsed);
  await pump3(pct(await inf.levelPrice(id5, 2), 1015, 1000), 'PUMP V3 por encima de P2');
  const rcI5b = await tx(infK.fillUp(id5, RT3, { gasPrice: 10_000_000n }), 'infinity: fillUp con gasPrice 0.01 gwei (piso 0.05)');
  const gp5b = evOf(rcI5b, II, 'GasPaid'); const units5b = gp5b.owed / 50_000_000n;
  ok('I5: con tx a 0,01 gwei el grid pago a 0,05 gwei (piso)', units5b >= rcI5b.gasUsed - 20000n && units5b <= rcI5b.gasUsed + 80000n && gp5b.owed > gasCost(rcI5b), 'unidades=' + units5b + ' gasUsed=' + rcI5b.gasUsed);
  await expectRevert('setGasPriceBounds cap 51 gwei (> MAX 50)', () => inf.setGasPriceBounds.staticCall(GWEI / 20n, 51n * GWEI), 'BadParams');
  await expectRevert('setGasPriceBounds floor 2 gwei (> MAX 1)', () => inf.setGasPriceBounds.staticCall(2n * GWEI, 5n * GWEI), 'BadParams');
  await expectRevert('setGasPriceBounds floor > cap', () => inf.setGasPriceBounds.staticCall(GWEI, GWEI / 2n), 'BadParams');
  await expectRevert('setGasPriceBounds desde el keeper', () => infK.setGasPriceBounds.staticCall(0, GWEI), 'NotOwner');
  const rcB = await tx(inf.setGasPriceBounds(GWEI / 10n, 3n * GWEI), 'infinity: setGasPriceBounds(0.1, 3 gwei)');
  ok('I5: setGasPriceBounds aplico y emitio', (await inf.gasPriceFloor()) === GWEI / 10n && (await inf.gasPriceCap()) === 3n * GWEI && !!evOf(rcB, II, 'GasPriceBoundsSet'));
  await tx(inf.setGasPriceBounds(50_000_000n, 5n * GWEI), 'infinity: setGasPriceBounds(back)');

  log('\n== I6 topUp solo gas / con capital');
  const ge0 = await inf.gasEscrowed(), v0 = (await inf.grid(id1)).V, gr0 = (await inf.grid(id1)).gasReserve;
  const rcI6 = await tx(inf.topUp(id1, RT3, 0, GAS, { value: GAS }), 'infinity: topUp (solo gas)');
  g = await inf.grid(id1);
  ok('I6: la reserva subio, V no cambio, ToppedUp no, GasAdded si, gasEscrowed +gasAdd', g.gasReserve === gr0 + GAS && g.V === v0 && !evOf(rcI6, II, 'ToppedUp') && !!evOf(rcI6, II, 'GasAdded') && (await inf.gasEscrowed()) === ge0 + GAS);
  await expectRevert('topUp con gasAdd > msg.value', () => inf.topUp.staticCall(id1, RT3, 0, GAS, { value: GAS / 2n }), 'BadValue');
  await expectRevert('topUp desde el keeper (no es maker)', () => infK.topUp.staticCall(id1, RT3, 0, 0, { value: GAS }), 'NotMaker');
  const CAP = ethers.parseEther('0.1');
  const nextP6 = await inf.levelPrice(id1, (await inf.grid(id1)).lastK + 1n);
  const Pd6 = await dump3(pct(nextP6, 97), ethers.parseEther('1000'), 'DUMP V3 por debajo del proximo escalon');
  if (Pd6 >= nextP6) skip('I6 topUp con capital', 'no se bajo el precio'); else {
    const q6 = (await inf.grid(id1)).quoteHeld, b6 = (await inf.grid(id1)).baseHeld, v6 = (await inf.grid(id1)).V;
    const rcI6b = await tx(inf.topUp(id1, RT3, 1, GAS, { value: CAP + GAS }), 'infinity: topUp (capital + gas)');
    const tu = evOf(rcI6b, II, 'ToppedUp'); g = await inf.grid(id1);
    ok('I6: ToppedUp con amountIn == capital, base comprado > 0; V +mitad, quoteHeld +otra mitad, base +comprado', tu && tu.amountIn === CAP && tu.baseBought > 0n && g.V === v6 + CAP / 2n && g.quoteHeld === q6 + (CAP - CAP / 2n) && g.baseHeld === b6 + tu.baseBought);
  }

  log('\n== I7 stop devuelve la reserva + refundExpired');
  g = await inf.grid(id1);
  const resto = g.gasReserve, ge7 = await inf.gasEscrowed(), mc0 = await cake.balanceOf(w.address), mb0 = await p.getBalance(w.address);
  const rcI7 = await tx(inf.stop(id1, RT3, 0, false), 'infinity: stop (keep base)');
  const grf = evOf(rcI7, II, 'GasRefunded'), gs7 = evOf(rcI7, II, 'GridStopped');
  ok('I7: GasRefunded == lo que quedaba; grid Stopped sin escrow; gasEscrowed bajo', grf && grf.amount === resto && (await inf.grid(id1)).gasReserve === 0n && (await inf.gasEscrowed()) === ge7 - resto && (await inf.grid(id1)).status === 1n && (await inf.grid(id1)).quoteHeld === 0n && (await inf.grid(id1)).baseHeld === 0n);
  ok('I7: el maker recibio el base y el BNB (quote + reserva)', (await cake.balanceOf(w.address)) - mc0 === g.baseHeld && gs7.kind === 1n && gs7.baseReturned === g.baseHeld && (await p.getBalance(w.address)) - mb0 + gasCost(rcI7) === g.quoteHeld + resto, W(g.quoteHeld + resto));
  await expectRevert('fillUp sobre un grid cerrado', () => infK.fillUp.staticCall(id1, RT3, KP), 'NotOpen');
  await expectRevert('stop de nuevo', () => inf.stop.staticCall(id1, RT3, 0, false), 'NotOpen');
  const { id: id7 } = await abrirI({ expiry: (await now()) + 120n }, GAS, 'infinity: openWithEth expiry 2 min');
  await rpc('evm_increaseTime', 200); await rpc('evm_mine');
  await expectRevert('fillUp vencido', () => infK.fillUp.staticCall(id7, RT3, KP), 'Expired');
  await expectRevert('refundExpired antes de vencer (sobre un grid vivo)', async () => inf.refundExpired.staticCall((await abrirI({}, GAS, 'infinity: openWithEth (para refundExpired negativo)')).id, RT3), 'NotExpired');
  const rcI7b = await tx(inf.connect(k).refundExpired(id7, RT3), 'infinity: refundExpired (por cualquiera)');
  const gr7 = evOf(rcI7b, II, 'GasRefunded');
  ok('I7: refundExpired: la reserva entera volvio al MAKER aunque llamo otro; kind 2', gr7 && gr7.amount === GAS && gr7.maker === w.address && evOf(rcI7b, II, 'GridStopped').kind === 2n);

  log('\n== I8 compound agranda la posicion');
  const { id: id8 } = await abrirI({ compound: true }, GAS, 'infinity: openWithEth compound=true');
  await expectRevert('setCompound desde el keeper', () => infK.setCompound.staticCall(id8, false), 'NotMaker');
  await pump3(pct((await inf.grid(id8)).P0, 10300 + 200, 10000), 'PUMP V3');
  const g8a = await inf.grid(id8);
  const rcI8 = await tx(infK.fillUp(id8, RT3, KP), 'infinity: fillUp compound ON'); await keeperPaid(rcI8, II);
  const gf8 = evOf(rcI8, II, 'GridFilled'), rv8 = evOf(rcI8, II, 'Reinvested'); const g8 = await inf.grid(id8);
  ok('I8: Reinvested == gain, V == V + gain, reinvested == gain, profit == gain, quoteHeld += amountOut', gf8.profit > 0n && rv8 && rv8.amount === gf8.profit && g8.V === g8a.V + gf8.profit && g8.reinvested === gf8.profit && g8.profit === gf8.profit && g8.quoteHeld === g8a.quoteHeld + gf8.amountOut, 'gain=' + W(gf8.profit));
  await tx(inf.setCompound(id8, false), 'infinity: setCompound(false)');
  await pump3(pct(await inf.levelPrice(id8, 2), 1015, 1000), 'PUMP V3 por encima de P2');
  const rcI8c = await tx(infK.fillUp(id8, RT3, KP), 'infinity: fillUp compound OFF'); await keeperPaid(rcI8c, II); const g8c = await inf.grid(id8);
  ok('I8: con compound off, profit sube pero V y reinvested no', g8c.profit > g8.profit && g8c.V === g8.V && g8c.reinvested === g8.reinvested && !evOf(rcI8c, II, 'Reinvested'));

  log('\n== I9 take-profit (keeper, gas soft, reserva devuelta)');
  const P9 = await P3(); const tp9 = pct(P9, 125);
  const rcI9 = await tx(inf.openWithEth(CAKE, RT3, await baseI({ tpPrice: tp9, floorPrice: pct(P9, 40) }), await seedMin3(), 777n, { value: V + RES + 777n }), 'infinity: openWithEth con TP 125 %, reserva 777 wei');
  const id9 = idOfI(rcI9);
  await expectRevert('takeProfit con el precio por debajo del TP', () => infK.takeProfit.staticCall(id9, RT3, KP), 'Slippage');
  await pump3(pct(tp9, 106), 'PUMP V3 por encima del TP');
  const g9 = await inf.grid(id9); const mb9 = await p.getBalance(w.address);
  const rcI9b = await tx(infK.takeProfit(id9, RT3, KP), 'infinity: takeProfit'); const gp9 = await keeperPaid(rcI9b, II);
  const gs9 = evOf(rcI9b, II, 'GridStopped');
  ok('I9: takeProfit: kind 4, vendio todo el base, proceeds >= base * tp', gs9 && gs9.kind === 4n && gs9.baseSold === g9.baseHeld && gs9.proceeds * Q >= g9.baseHeld * tp9, W(gs9.proceeds));
  ok('I9: gas soft: cobro solo los 777 wei (reserva chica) y no revirtio; el maker cobro proceeds + quote en BNB', gp9 && gp9.owed === 777n && gp9.remaining === 0n && (await p.getBalance(w.address)) - mb9 === gs9.proceeds + g9.quoteHeld && (await inf.grid(id9)).status === 1n);

  log('\n== I10 stop-loss (keeper, gas soft)');
  const P10 = await P3(); const sl10 = pct(P10, 80);
  const rcI10 = await tx(inf.openWithEth(CAKE, RT3, await baseI({ slPrice: sl10, floorPrice: pct(P10, 40) }), await seedMin3(), 12345n, { value: V + RES + 12345n }), 'infinity: openWithEth con SL 80 %, reserva 12345 wei');
  const id10 = idOfI(rcI10);
  ok('I10: nacio con SL, StopLossSet emitido, slMinOut > 0', (await inf.grid(id10)).slPrice === sl10 && !!evOf(rcI10, II, 'StopLossSet') && (await inf.slMinOut(id10)) > 0n);
  await expectRevert('stopLoss con el precio por encima del SL', () => infK.stopLoss.staticCall(id10, RT3, 0, KP), 'PriceNotReached');
  let Pd10 = await dump3(sl10, ethers.parseEther('1500'), 'DUMP V3 hasta el SL');
  const enVentana = Pd10 <= sl10 && Pd10 >= pct(sl10, 97);
  log('    P tras el dump:', ethers.formatEther(Pd10), '| SL:', ethers.formatEther(sl10), '| ventana [0.97 SL, SL]:', enVentana ? 'SI' : 'NO');
  if (enVentana) {
    const g10 = await inf.grid(id10); const mb10 = await p.getBalance(w.address);
    const rcSL = await tx(infK.stopLoss(id10, RT3, 0, KP), 'infinity: stopLoss'); const gpF = await keeperPaid(rcSL, II);
    const gsF = evOf(rcSL, II, 'GridStopped'), slE = evOf(rcSL, II, 'StopLoss');
    ok('I10: stop-loss ejecutado con reserva chica: kind 3, StopLoss, owed clampeado a 12345, sin refund', gsF && gsF.kind === 3n && slE && gpF.owed === 12345n && gpF.remaining === 0n && !evOf(rcSL, II, 'GasRefunded'));
    ok('I10: el maker cobro proceeds + quote en BNB; proceeds <= base * SL', (await p.getBalance(w.address)) - mb10 === gsF.proceeds + g10.quoteHeld && gsF.proceeds * Q <= g10.baseHeld * sl10);
  } else skip('I10 ejecucion real del SL', 'no se llego a la ventana de precio');
  await expectRevert('setStopLoss desde el keeper', () => infK.setStopLoss.staticCall(id8, 1n), 'NotMaker');
  const rcSS = await tx(inf.setStopLoss(id8, pct((await inf.grid(id8)).P0, 70)), 'infinity: setStopLoss(70 %)');
  ok('I10: setStopLoss cambio slPrice y emitio StopLossSet', (await inf.grid(id8)).slPrice === pct((await inf.grid(id8)).P0, 70) && !!evOf(rcSS, II, 'StopLossSet'));

  log('\n== I11 pausa y rescue');
  await tx(inf.setPaused(true), 'infinity: setPaused(true)');
  await expectRevert('fillUp pausado', () => infK.fillUp.staticCall(id8, RT3, KP), 'IsPaused');
  await expectRevert('openWithEth pausado', async () => inf.openWithEth.staticCall(CAKE, RT3, await baseI(), await seedMin3(), GAS, { value: V + RES + GAS }), 'IsPaused');
  const g11 = await inf.grid(id8);
  const rcI11 = await tx(inf.stop(id8, RT3, 0, false), 'infinity: stop pausado (keep)');
  ok('I11: stop funciona pausado y devolvio base + quote + gas', evOf(rcI11, II, 'GridStopped').baseReturned === g11.baseHeld && !!evOf(rcI11, II, 'GasRefunded'));
  await tx(inf.setPaused(false), 'infinity: setPaused(false)');
  await tx(cake.connect(u).transfer(INF, ethers.parseEther('1')), 'CAKE mandado por error al contrato');
  const esc = await inf.escrowed(CAKE), mc11 = await cake.balanceOf(w.address);
  await tx(inf.rescue(CAKE, w.address), 'infinity: rescue(CAKE)');
  ok('I11: rescue saco SOLO el exceso (1 CAKE) y el escrow quedo intacto', (await cake.balanceOf(w.address)) - mc11 === ethers.parseEther('1') && (await inf.escrowed(CAKE)) === esc && (await cake.balanceOf(INF)) === esc);
  await expectRevert('setKeeper desde el keeper', () => infK.setKeeper.staticCall(u.address, true), 'NotOwner');
  await tx(inf.transferOwnership(u.address), 'infinity: transferOwnership(u)');
  ok('I11: ownership en 2 pasos: sigue siendo del owner hasta aceptar', (await inf.owner()) === w.address && (await inf.pendingOwner()) === u.address);
  await tx(inf.connect(u).acceptOwnership(), 'infinity: acceptOwnership'); ok('I11: acepto', (await inf.owner()) === u.address);
  await tx(inf.connect(u).transferOwnership(w.address), 'back'); await tx(inf.acceptOwnership(), 'back');

  // ───────────────────────────── S: SPOT sobre CAKE/WBNB V2 (ROUTE_V2 path, se da vuelta sola al vender) ─────────────────────────────
  log('\n================ S: ArchitectSpotGridV4BSC ================');
  const RT2 = ROUTE_V2([WBNB, CAKE]);
  const PER = ethers.parseEther('0.2');
  const baseS = (over) => ({ perLevel: PER, gBps: 300, nSeed: 0, slPrice: 0n, tpPrice: 0n, expiry: expiry(), feeBps: FEE_BPS, referrer: rf.address, compound: false, ...(over || {}) });
  const idOfS = (rc) => evOf(rc, IS, 'GridOpened').id;
  const Ps = await P2();
  // 2 niveles de compra POR ENCIMA del precio: fillBuy llena ya (el pool esta mas barato que la linea)
  const bp = [pct(Ps, 115), pct(Ps, 120)], sp = [pct(Ps, 119), pct(Ps, 124)];
  log('\n== S1 abrir con reserva');
  await expectRevert('abrir mandando solo el capital (falta la reserva)', () => spot.openWithEth.staticCall(CAKE, RT2, baseS(), bp, sp, 0, GAS, { value: PER * 2n }), 'BadValue');
  await expectRevert('abrir con sellPrice < buyPrice*(1+gBps)', () => spot.openWithEth.staticCall(CAKE, RT2, baseS(), bp, [pct(Ps, 116), pct(Ps, 124)], 0, GAS, { value: PER * 2n + GAS }), 'BadParams');
  await expectRevert('abrir con gBps 100 (< 250)', () => spot.openWithEth.staticCall(CAKE, RT2, baseS({ gBps: 100 }), bp, sp, 0, GAS, { value: PER * 2n + GAS }), 'BadParams');
  const rcS1 = await tx(spot.openWithEth(CAKE, RT2, baseS(), bp, sp, 0, GAS, { value: PER * 2n + GAS }), 'spot: openWithEth (2 niveles, sin seed)');
  const s1 = idOfS(rcS1); let gs = await spot.grid(s1);
  ok('S1: gasReserve, gasEscrowed, escrowed[WBNB] == capital + reserva, quoteHeld == capital, GasAdded', gs.gasReserve === GAS && (await spot.gasEscrowed()) === GAS && (await spot.escrowed(WBNB)) === PER * 2n + GAS && gs.quoteHeld === PER * 2n && !!evOf(rcS1, IS, 'GasAdded') && gs.nLevels === 2n);
  await expectRevert('rescue(WBNB) con la reserva adentro', () => spot.rescue.staticCall(WBNB, w.address), 'NothingToRefund');

  log('\n== S2 fillBuy paga al keeper');
  await expectRevert('fillBuy desde el maker', () => spot.fillBuy.staticCall(s1, 0, RT2), 'NotKeeper');
  await expectRevert('fillBuy nivel 5 (no existe)', () => spotK.fillBuy.staticCall(s1, 5, RT2, KP), 'BadLevel');
  const kws0 = await wbnb.balanceOf(k.address);
  const rcS2 = await tx(spotK.fillBuy(s1, 0, RT2, KP), 'spot: fillBuy (V2 path)'); const gps = await keeperPaid(rcS2, IS); const gfs = evOf(rcS2, IS, 'GridFilled');
  gs = await spot.grid(s1);
  ok('S2: GasPaid al keeper en WBNB == owed, owed >= real y <= 1.6x', gps && (await wbnb.balanceOf(k.address)) - kws0 === gps.owed && gps.owed >= gasCost(rcS2) && gps.owed <= gasCost(rcS2) * 16n / 10n, 'owed/real = ' + G[G.length - 1].ratio);
  ok('S2: nivel 0 en BASE con cost == perLevel, base > 0; escrowed[WBNB] == quoteHeld + gasReserve', gfs.amountIn === PER && (await spot.levels(s1))[0].state === 1n && (await spot.levels(s1))[0].cost === PER && (await spot.levels(s1))[0].base > 0n && (await spot.escrowed(WBNB)) === gs.quoteHeld + gs.gasReserve);
  await expectRevert('fillBuy del mismo nivel otra vez (ya esta en BASE)', () => spotK.fillBuy.staticCall(s1, 0, RT2, KP), 'BadLevel');
  const rcS2b = await tx(spotK.fillBuy(s1, 1, RT2, KP), 'spot: fillBuy nivel 1'); await keeperPaid(rcS2b, IS);
  ok('S2: nivel 1 comprado; quoteHeld == 0', (await spot.levels(s1))[1].state === 1n && (await spot.grid(s1)).quoteHeld === 0n);

  log('\n== S3 fillSell con ganancia (pump V2)');
  await expectRevert('fillSell antes del pump (no llega a cost*(1+gBps)): corta por slippage', () => spotK.fillSell.staticCall(s1, 0, RT2, KP), 'Slippage');
  await pump2(pct(sp[1], 103), 'PUMP V2 por encima del sellPrice[1]');
  const rcS3 = await tx(spotK.fillSell(s1, 0, RT2, KP), 'spot: fillSell (V2 path al reves)'); await keeperPaid(rcS3, IS);
  const gfs3 = evOf(rcS3, IS, 'GridFilled'); gs = await spot.grid(s1);
  ok('S3: fillSell nivel 0: profit >= 3 % neto de cost, nivel vuelve a QUOTE, profit del grid == gain', gfs3 && gfs3.side === 1n && gfs3.profit >= (PER * 300n) / 10000n && (await spot.levels(s1))[0].state === 0n && gs.profit === gfs3.profit, 'gain=' + W(gfs3.profit));
  const rcS3b = await tx(spotK.fillSell(s1, 1, RT2, KP), 'spot: fillSell nivel 1'); await keeperPaid(rcS3b, IS);
  ok('S3: nivel 1 vendido; quoteHeld == 2*perLevel + profit; sin allowance viva', (await spot.grid(s1)).quoteHeld === PER * 2n + (await spot.grid(s1)).profit && (await cake.allowance(SPOT, ROUTER)) === 0n);
  ok('S3: los fills del Spot NO le pagaron nada al referrer del grid (sin referidos en BSC)', (await router.accrued(rf.address, WBNB)) === 0n);

  log('\n== S4 NoGas + pre-flight no ciego');
  const Ps4 = await P2();   // precio fresco (S3 lo bombeo): las lineas de compra tienen que quedar POR ENCIMA del precio para que el fill sea posible
  const rcS4 = await tx(spot.openWithEth(CAKE, RT2, baseS(), [pct(Ps4, 115), pct(Ps4, 120)], [pct(Ps4, 119), pct(Ps4, 125)], 0, 1n, { value: PER * 2n + 1n }), 'spot: openWithEth reserva 1 wei');
  const s4 = idOfS(rcS4);
  await expectRevert('fillBuy con 1 wei de reserva', () => spotK.fillBuy.staticCall(s4, 0, RT2, KP), 'NoGas');
  await expectRevert('PRE-FLIGHT con gasPrice 0: NoGas igual (piso)', () => spotK.fillBuy.staticCall(s4, 0, RT2, { gasPrice: 0 }), 'NoGas');
  await tx(spot.topUp(s4, RT2, 0, GAS, { value: GAS }), 'spot: topUp (solo gas)');
  const rcS4b = await tx(spotK.fillBuy(s4, 0, RT2, { gasPrice: 50n * GWEI }), 'spot: fillBuy con gasPrice 50 gwei (techo 5)');
  const gps4 = evOf(rcS4b, IS, 'GasPaid'); const units4 = gps4.owed / (5n * GWEI);
  ok('S4: con la reserva cargada el fill sale; a 50 gwei cobra al techo de 5 gwei', gps4 && units4 >= rcS4b.gasUsed - 20000n && units4 <= rcS4b.gasUsed + 80000n && gps4.owed < gasCost(rcS4b));

  log('\n== S5 compound (profitFree -> boost)');
  const Ps5 = await P2();
  const bp5 = [pct(Ps5, 115), pct(Ps5, 120)], sp5 = [pct(Ps5, 119), pct(Ps5, 124)];
  const rcS5 = await tx(spot.openWithEth(CAKE, RT2, baseS({ compound: true, gBps: 250 }), bp5, sp5, 0, GAS, { value: PER * 2n + GAS }), 'spot: openWithEth compound');
  const s5 = idOfS(rcS5);
  await tx(spotK.fillBuy(s5, 0, RT2, KP), 'spot: fillBuy(0) compound');
  await pump2(pct(sp5[1], 103), 'PUMP V2');
  const rcS5b = await tx(spotK.fillSell(s5, 0, RT2, KP), 'spot: fillSell(0) compound'); const gf5 = evOf(rcS5b, IS, 'GridFilled'); let g5 = await spot.grid(s5);
  ok('S5: venta con ganancia: profit == profitFree == gain; nextBuyQuote == perLevel + profitFree/2', gf5.profit > 0n && g5.profit === gf5.profit && g5.profitFree === gf5.profit && (await spot.nextBuyQuote(s5)) === PER + g5.profitFree / 2n);
  await dump2(pct(bp5[0], 97), ethers.parseEther('20000'), 'DUMP V2 por debajo del buyPrice[0]');
  const boost = g5.profitFree / 2n;
  const rcS5c = await tx(spotK.fillBuy(s5, 0, RT2, KP), 'spot: fillBuy(0) reinvirtiendo'); const rv5 = evOf(rcS5c, IS, 'Reinvested'); const g5b = await spot.grid(s5);
  ok('S5: Reinvested == boost, compra == perLevel + boost, cost del nivel escalo, profit no bajo, profitFree -boost', rv5 && rv5.boost === boost && evOf(rcS5c, IS, 'GridFilled').amountIn === PER + boost && (await spot.levels(s5))[0].cost === PER + boost && g5b.profit === g5.profit && g5b.profitFree === g5.profitFree - boost);
  await tx(spot.setCompound(s5, false), 'spot: setCompound(false)');
  ok('S5: setCompound off', (await spot.grid(s5)).compound === false);

  log('\n== S6 take-profit y stop-loss (nSeed=1)');
  const Ps6 = await P2(); const tp6 = pct(Ps6, 130);
  const seedMin2 = ((PER * Q) / Ps6) * 85n / 100n;
  const rcS6 = await tx(spot.openWithEth(CAKE, RT2, baseS({ nSeed: 1, tpPrice: tp6 }), [pct(Ps6, 110), pct(Ps6, 115)], [pct(Ps6, 114), pct(Ps6, 119)], seedMin2, 555n, { value: PER * 2n + 555n }), 'spot: openWithEth nSeed=1 con TP');
  const s6 = idOfS(rcS6); const g6 = await spot.grid(s6);
  ok('S6: nacio con base (nSeed=1) y 555 wei de reserva', g6.baseHeld > 0n && g6.gasReserve === 555n && (await spot.levels(s6))[1].state === 1n);
  await expectRevert('takeProfit por debajo del TP', () => spotK.takeProfit.staticCall(s6, RT2, KP), 'Slippage');
  await pump2(pct(tp6, 105), 'PUMP V2 por encima del TP');
  const mb6 = await p.getBalance(w.address);
  const rcS6b = await tx(spotK.takeProfit(s6, RT2, KP), 'spot: takeProfit'); const gps6 = await keeperPaid(rcS6b, IS); const gss6 = evOf(rcS6b, IS, 'GridStopped');
  ok('S6: takeProfit kind 4, proceeds >= base*tp, gas soft (555 wei), maker cobro proceeds + quote', gss6 && gss6.kind === 4n && gss6.proceeds * Q >= g6.baseHeld * tp6 && gps6.owed === 555n && (await p.getBalance(w.address)) - mb6 === gss6.proceeds + g6.quoteHeld);
  const Ps7 = await P2(); const sl7 = pct(Ps7, 80);
  const rcS7 = await tx(spot.openWithEth(CAKE, RT2, baseS({ nSeed: 1, slPrice: sl7 }), [pct(Ps7, 110), pct(Ps7, 115)], [pct(Ps7, 114), pct(Ps7, 119)], ((PER * Q) / Ps7) * 85n / 100n, 12345n, { value: PER * 2n + 12345n }), 'spot: openWithEth nSeed=1 con SL');
  const s7 = idOfS(rcS7); const g7 = await spot.grid(s7);
  await expectRevert('stopLoss por encima del SL', () => spotK.stopLoss.staticCall(s7, RT2, 0, KP), 'PriceNotReached');
  const Pd7 = await dump2(sl7, ethers.parseEther('30000'), 'DUMP V2 hasta el SL');
  const enV7 = Pd7 <= sl7 && Pd7 >= pct(sl7, 95);
  log('    P tras el dump:', ethers.formatEther(Pd7), '| SL:', ethers.formatEther(sl7), '| ventana [0.95 SL, SL]:', enV7 ? 'SI' : 'NO');
  if (enV7) {
    const mb7 = await p.getBalance(w.address);
    const rcS7b = await tx(spotK.stopLoss(s7, RT2, 0, KP), 'spot: stopLoss'); const gps7 = await keeperPaid(rcS7b, IS); const gss7 = evOf(rcS7b, IS, 'GridStopped');
    ok('S7: stopLoss kind 3 con reserva chica (gas soft, owed 12345), maker cobro proceeds + quote', gss7 && gss7.kind === 3n && gps7.owed === 12345n && (await p.getBalance(w.address)) - mb7 === gss7.proceeds + g7.quoteHeld);
  } else skip('S7 ejecucion real del SL', 'no se llego a la ventana');

  log('\n== S8 stop y refundExpired');
  const g8s = await spot.grid(s1); const mb8 = await p.getBalance(w.address);
  const rcS8 = await tx(spot.stop(s1, RT2, 0, false), 'spot: stop (keep)');
  ok('S8: stop: GasRefunded == resto, maker cobro quote + reserva, grid Stopped', evOf(rcS8, IS, 'GasRefunded').amount === g8s.gasReserve && (await p.getBalance(w.address)) - mb8 + gasCost(rcS8) === g8s.quoteHeld + g8s.gasReserve && (await spot.grid(s1)).status === 1n);
  const rcS8b = await tx(spot.openWithEth(CAKE, RT2, baseS({ expiry: (await now()) + 100n }), bp, sp, 0, GAS, { value: PER * 2n + GAS }), 'spot: openWithEth expiry corto');
  await rpc('evm_increaseTime', 200); await rpc('evm_mine');
  const rcS8c = await tx(spot.connect(u).refundExpired(idOfS(rcS8b), RT2), 'spot: refundExpired');
  ok('S8: refundExpired devolvio la reserva al maker (kind 2)', evOf(rcS8c, IS, 'GasRefunded').maker === w.address && evOf(rcS8c, IS, 'GridStopped').kind === 2n);
  // invariantes globales del Spot
  const spotIds = [s1, s4, s5, s6, s7, idOfS(rcS8b)]; let sumG = 0n, sumQ = 0n, sumB = 0n;
  for (const id of spotIds) { const gg = await spot.grid(id); sumG += gg.gasReserve; sumQ += gg.quoteHeld + gg.gasReserve; sumB += gg.baseHeld; }
  ok('S9: invariantes: gasEscrowed == sum(gasReserve), escrowed[WBNB] == sum(quote+gas) <= balance, escrowed[CAKE] == sum(base) <= balance', (await spot.gasEscrowed()) === sumG && (await spot.escrowed(WBNB)) === sumQ && (await wbnb.balanceOf(SPOT)) >= sumQ && (await spot.escrowed(CAKE)) === sumB && (await cake.balanceOf(SPOT)) >= sumB);

  // ───────────────────────────── F: tokens con tax / blacklist en los bots ─────────────────────────────
  log('\n================ F: tokens con tax / blacklist ================');
  const TA = art('MockTaxToken'), BA = art('MockBlockingToken'), FA = art('MockFalseToken'), RFA = art('MockReflectToken');
  const taxW = await fresh(1);
  const taxd = await (await new ethers.ContractFactory(TA.abi, TA.bin, w).deploy(1000, taxW.address)).waitForDeployment(); const TAXD = await taxd.getAddress();
  await tx(taxd.mint(w.address, ethers.parseEther('1000000')), 'TAXD.mint'); await tx(taxd.setExempt(w.address, true), 'TAXD exento el LP');
  await tx(taxd.approve(A.V2_ROUTER, ethers.MaxUint256), 'TAXD.approve(PancakeRouter)');
  await tx(pcs.connect(w).addLiquidityETH(TAXD, ethers.parseEther('500000'), 0, 0, w.address, expiry(), { value: ethers.parseEther('100') }), 'PancakeRouter.addLiquidityETH(TAXD, 100 BNB)');
  const pairTax = await f2.getPair(TAXD, WBNB);
  ok('F1: el pair TAXD/WBNB existe en la factory de PancakeSwap (creado en el fork)', pairTax !== ethers.ZeroAddress, pairTax);
  await tx(taxd.setExempt(w.address, false), 'TAXD: el LP deja de ser exento');
  const taxdC = new ethers.Contract(TAXD, ERC20, p);
  // router: compra por V2 (tax 10 % medido), venta por V2_DIRECT y por V2 router
  const vT = ethers.parseEther('1'); const qT = await pcs.getAmountsOut(vT - vT / 100n, [WBNB, TAXD]);
  const tb0 = await taxdC.balanceOf(u.address);
  const rcF1 = await tx(rU.swapETH(TAXD, 1, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE_V2([WBNB, TAXD]), { value: vT }), 'router: swapETH BNB->TAXD (mock 10 % tax) V2');
  const gotT = (await taxdC.balanceOf(u.address)) - tb0;
  ok('F1: router compra TAXD: recibido == 90 % de la cotizacion (tax 10 % medida por delta), evento == delta', gotT === qT[1] - qT[1] / 10n && evOf(rcF1, IR, 'Swap').amountOut === gotT);
  await tx(taxdC.connect(u).approve(ROUTER, gotT), 'TAXD.approve(router)');
  const ub0 = await p.getBalance(u.address);
  const rcF1b = await tx(rU.swapToETH(TAXD, gotT / 2n, 1, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE_V2D(pairTax)), 'router: swapToETH TAXD->BNB V2_DIRECT'); const oD = evOf(rcF1b, IR, 'Swap').amountOut;
  const rcF1c = await tx(rU.swapToETH(TAXD, gotT - gotT / 2n, 1, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE_V2([TAXD, WBNB])), 'router: swapToETH TAXD->BNB V2 router'); const oR = evOf(rcF1c, IR, 'Swap').amountOut;
  ok('F1: vender TAXD no revierte: el router mide lo que entra (90 %) y opera con eso; directo rinde mas que por el PancakeRouter', oD > 0n && oR > 0n && oD > oR && (await p.getBalance(u.address)) - ub0 + gasCost(rcF1b) + gasCost(rcF1c) === oD + oR, 'directo ' + W(oD) + ' vs router ' + W(oR));
  ok('F1: el router no retuvo TAXD', (await taxdC.balanceOf(ROUTER)) === 0n);
  // bots: openWithBase rechaza; openWithEth mide; stop no traba
  const RTT = ROUTE_V2D(pairTax);
  const PT = async () => { const pr = new ethers.Contract(pairTax, PAIR, p); const r = await pr.getReserves(); const t0 = (await pr.token0()).toLowerCase() === TAXD.toLowerCase(); return t0 ? (BigInt(r[1]) * Q) / BigInt(r[0]) : (BigInt(r[0]) * Q) / BigInt(r[1]); };
  await tx(taxd.approve(INF, ethers.parseEther('1000')), 'TAXD.approve(infinity)');
  await expectRevert('openWithBase con un token con tax (entrega menos de lo declarado)', async () => inf.openWithBase.staticCall(TAXD, RTT, { ...(await baseI()), P0: await PT() }, ethers.parseEther('1000'), GAS, { value: RES + GAS }), 'TransferFailed');
  const seedT = (((V * Q) / (await PT())) * 75n) / 100n;   // 10 % tax + 1 % fee + 0,25 % + impacto
  const rcF2 = await tx(inf.openWithEth(TAXD, RTT, { ...(await baseI()), floorPrice: pct(await PT(), 50) }, seedT, GAS, { value: V + RES + GAS }), 'infinity: openWithEth con TAXD (token con tax)');
  const idT = idOfI(rcF2); const gT = await inf.grid(idT);
  ok('F2: el bot abrio con el token con tax: baseHeld == lo que LLEGO (post-tax) == escrowed, balance real == escrowed', gT.baseHeld > 0n && (await inf.escrowed(TAXD)) === gT.baseHeld && (await taxdC.balanceOf(INF)) === gT.baseHeld);
  const mt0 = await taxdC.balanceOf(w.address), mb2 = await p.getBalance(w.address);
  const rcF2b = await tx(inf.stop(idT, RTT, 0, false), 'infinity: stop (keep) con TAXD');
  ok('F2: stop(keep): el maker recibio el base (menos la tax del token) y TODO el BNB; escrow en 0', (await taxdC.balanceOf(w.address)) - mt0 === gT.baseHeld - gT.baseHeld / 10n && (await p.getBalance(w.address)) - mb2 + gasCost(rcF2b) === gT.quoteHeld + GAS && (await inf.escrowed(TAXD)) === 0n);
  const rcF3 = await tx(inf.openWithEth(TAXD, RTT, { ...(await baseI()), floorPrice: pct(await PT(), 50) }, seedT, GAS, { value: V + RES + GAS }), 'infinity: openWithEth con TAXD (2)');
  const idT2 = idOfI(rcF3); const gT2 = await inf.grid(idT2); const mb3 = await p.getBalance(w.address);
  const rcF3b = await tx(inf.stop(idT2, RTT, 1, true), 'infinity: stop (sellAll) con TAXD por V2_DIRECT');
  const gsT = evOf(rcF3b, II, 'GridStopped');
  ok('F2: stop(sellAll) con token con tax: vendio (proceeds > 0) y devolvio proceeds + quote + gas en BNB', gsT.kind === 0n && gsT.proceeds > 0n && (await p.getBalance(w.address)) - mb3 + gasCost(rcF3b) === gsT.proceeds + gT2.quoteHeld + GAS && (await inf.escrowed(TAXD)) === 0n, W(gsT.proceeds));
  // blacklist: el token rechaza la transferencia al maker al cerrar
  for (const [nm, ART] of [['BLCK (revierte)', BA], ['FALS (devuelve false)', FA]]) {
    const tk = await (await new ethers.ContractFactory(ART.abi, ART.bin, w).deploy()).waitForDeployment(); const TK = await tk.getAddress();
    await tx(tk.mint(w.address, ethers.parseEther('1000000')), nm + '.mint'); await tx(tk.approve(A.V2_ROUTER, ethers.MaxUint256), nm + '.approve');
    await tx(pcs.connect(w).addLiquidityETH(TK, ethers.parseEther('500000'), 0, 0, w.address, expiry(), { value: ethers.parseEther('100') }), 'PancakeRouter.addLiquidityETH(' + nm + ')');
    const pairB = await f2.getPair(TK, WBNB); const RTB = ROUTE_V2D(pairB);
    const prB = new ethers.Contract(pairB, PAIR, p); const PB = async () => { const r = await prB.getReserves(); const t0 = (await prB.token0()).toLowerCase() === TK.toLowerCase(); return t0 ? (BigInt(r[1]) * Q) / BigInt(r[0]) : (BigInt(r[0]) * Q) / BigInt(r[1]); };
    const rcB1 = await tx(inf.openWithEth(TK, RTB, { ...(await baseI()), floorPrice: pct(await PB(), 50) }, (((V * Q) / (await PB())) * 90n) / 100n, GAS, { value: V + RES + GAS }), 'infinity: openWithEth con ' + nm);
    const idB = idOfI(rcB1); const gB = await inf.grid(idB);
    await tx(tk.setBlocked(w.address, true), nm + ': bloquear al maker');
    const mbB = await p.getBalance(w.address);
    const rcB2 = await tx(inf.stop(idB, RTB, 0, false), 'infinity: stop (keep) con ' + nm + ' que no deja transferir al maker');
    const tp = evOf(rcB2, II, 'TokenPending'), gsB = evOf(rcB2, II, 'GridStopped');
    ok('F3 ' + nm + ': el stop NO revirtio: TokenPending == base, baseReturned 0, el BNB (quote + gas) volvio igual', tp && tp.amount === gB.baseHeld && gsB.baseReturned === 0n && (await inf.pendingToken(w.address, TK)) === gB.baseHeld && (await p.getBalance(w.address)) - mbB + gasCost(rcB2) === gB.quoteHeld + GAS);
    ok('F3 ' + nm + ': el base sigue escrowado (rescue no lo ve)', (await inf.escrowed(TK)) === gB.baseHeld);
    await expectRevert('rescue(' + nm + ') con el base pendiente adentro', () => inf.rescue.staticCall(TK, w.address), 'NothingToRefund');
    await expectRevert('withdrawToken con el maker todavia bloqueado', () => inf.withdrawToken.staticCall(TK), 'TransferFailed');
    await tx(tk.setBlocked(w.address, false), nm + ': desbloquear');
    const tb = await tk.balanceOf(w.address);
    const rcB3 = await tx(inf.withdrawToken(TK), 'infinity: withdrawToken(' + nm + ')');
    ok('F3 ' + nm + ': withdrawToken entrego el base, escrow y pendiente en 0, TokenWithdrawn', (await tk.balanceOf(w.address)) - tb === gB.baseHeld && (await inf.escrowed(TK)) === 0n && (await inf.pendingToken(w.address, TK)) === 0n && !!evOf(rcB3, II, 'TokenWithdrawn'));
    await expectRevert('withdrawToken sin pendiente', () => inf.withdrawToken.staticCall(TK), 'NothingToRefund');
  }
  // F5 (revision 24/10): token con reflexion. Al entregarle el base al maker el saldo del bot baja MENOS que el base
  // (el token le acredita la reflexion al que manda). Antes _trySend lo tomaba como falla y ADEMAS lo anotaba en
  // pendingToken: el maker lo cobraba dos veces con withdrawToken, con tokens de otros makers.
  {
    const tk = await (await new ethers.ContractFactory(RFA.abi, RFA.bin, w).deploy()).waitForDeployment(); const TK = await tk.getAddress();
    await tx(tk.mint(w.address, ethers.parseEther('1000000')), 'REFL.mint'); await tx(tk.approve(A.V2_ROUTER, ethers.MaxUint256), 'REFL.approve');
    await tx(pcs.connect(w).addLiquidityETH(TK, ethers.parseEther('500000'), 0, 0, w.address, expiry(), { value: ethers.parseEther('100') }), 'PancakeRouter.addLiquidityETH(REFL)');
    const pairR = await f2.getPair(TK, WBNB); const RTR = ROUTE_V2D(pairR);
    const prR = new ethers.Contract(pairR, PAIR, p); const PR = async () => { const r = await prR.getReserves(); const t0 = (await prR.token0()).toLowerCase() === TK.toLowerCase(); return t0 ? (BigInt(r[1]) * Q) / BigInt(r[0]) : (BigInt(r[0]) * Q) / BigInt(r[1]); };
    const rcR1 = await tx(inf.openWithEth(TK, RTR, { ...(await baseI()), floorPrice: pct(await PR(), 50) }, (((V * Q) / (await PR())) * 90n) / 100n, GAS, { value: V + RES + GAS }), 'infinity: openWithEth con REFL (token con reflexion)');
    const idR = idOfI(rcR1); const gR = await inf.grid(idR);
    const mt0 = await tk.balanceOf(w.address);
    const rcR2 = await tx(inf.stop(idR, RTR, 0, false), 'infinity: stop (keep) con REFL');
    ok('F5: reflexion: el maker recibio el base UNA vez, sin TokenPending, pendingToken 0, escrow 0', (await tk.balanceOf(w.address)) - mt0 === gR.baseHeld && !evOf(rcR2, II, 'TokenPending') && (await inf.pendingToken(w.address, TK)) === 0n && (await inf.escrowed(TK)) === 0n && evOf(rcR2, II, 'GridStopped').baseReturned === gR.baseHeld);
    await expectRevert('F5: withdrawToken despues del cierre con reflexion (no hay nada que cobrar dos veces)', () => inf.withdrawToken.staticCall(TK), 'NothingToRefund');
  }
  // maker contrato con receive() que revierte: pendingEth en el bot
  await tx(greedy.exec(INF, II.encodeFunctionData('openWithEth', [CAKE, RT3, await baseI(), await seedMin3(), GAS]), { value: V + RES + GAS }), 'greedy: openWithEth (maker contrato)');
  const idG = (await inf.grid(ethers.keccak256(AC.encode(['uint256', 'address', 'uint256', 'address'], [56, INF, await inf.count(), GR])))).maker === GR ? ethers.keccak256(AC.encode(['uint256', 'address', 'uint256', 'address'], [56, INF, await inf.count(), GR])) : null;
  ok('F4: el id del grid es keccak(chainid 56, contrato, count, maker)', !!idG);
  await tx(greedy.setReject(true), 'greedy.setReject(true)');
  const gG = await inf.grid(idG);
  const rcG = await tx(greedy.exec(INF, II.encodeFunctionData('stop', [idG, RT3, 0, false])), 'greedy: stop con receive() que revierte');
  const eps = evAll(rcG, II, 'EthPending');
  ok('F4: el stop no se bloqueo: EthPending (quote y reserva) y pendingEth == quote + gas', eps.length === 2 && (await inf.pendingEth(GR)) === gG.quoteHeld + gG.gasReserve);
  await tx(greedy.setReject(false), 'greedy.setReject(false)'); const gb1 = await p.getBalance(GR);
  await tx(greedy.exec(INF, II.encodeFunctionData('withdrawEth', [])), 'greedy: withdrawEth del bot');
  ok('F4: withdrawEth cobro el pendiente del bot', (await p.getBalance(GR)) - gb1 === gG.quoteHeld + gG.gasReserve);

  // ───────────────────────────── G: tabla de gas ─────────────────────────────
  log('\n================ G: gas por operacion (fork; BNB = ' + bnbUsd.toFixed(2) + ' USDT) ================');
  const ops = {};
  for (const r of G) { if (!r.label.includes(':')) continue; const o = ops[r.label] || (ops[r.label] = { n: 0, min: r.gas, max: r.gas, sum: 0n, ratios: [] }); o.n++; o.sum += r.gas; if (r.gas < o.min) o.min = r.gas; if (r.gas > o.max) o.max = r.gas; if (r.ratio) o.ratios.push(r.ratio); }
  const cost = (gas, gwei) => Number(gas) * gwei / 1e9;
  const rows = [];
  for (const [label, o] of Object.entries(ops)) {
    const avg = o.sum / BigInt(o.n);
    rows.push({ op: label, n: o.n, gasAvg: Number(avg), gasMin: Number(o.min), gasMax: Number(o.max), bnb1gwei: cost(avg, 1), usd1gwei: cost(avg, 1) * bnbUsd, bnb005: cost(avg, 0.05), usd005: cost(avg, 0.05) * bnbUsd, owedOverReal: o.ratios.length ? (o.ratios.reduce((a, b) => a + b, 0) / o.ratios.length).toFixed(2) : '' });
  }
  rows.sort((a, b) => a.op.localeCompare(b.op));
  const pad = (s, n) => String(s).padEnd(n);
  log(pad('operacion', 58) + pad('n', 4) + pad('gas prom', 10) + pad('min', 9) + pad('max', 9) + pad('BNB@1gwei', 12) + pad('USD@1gwei', 11) + pad('BNB@0.05', 12) + pad('USD@0.05', 10) + 'owed/real');
  for (const r of rows) log(pad(r.op, 58) + pad(r.n, 4) + pad(r.gasAvg, 10) + pad(r.gasMin, 9) + pad(r.gasMax, 9) + pad(r.bnb1gwei.toFixed(6), 12) + pad(r.usd1gwei.toFixed(4), 11) + pad(r.bnb005.toFixed(7), 12) + pad(r.usd005.toFixed(5), 10) + r.owedOverReal);
  fs.mkdirSync(path.join(ROOT, 'run'), { recursive: true });
  fs.writeFileSync(path.join(ROOT, 'run', 'gas-report.json'), JSON.stringify({ forkBlock: fork, bnbUsd, assumedGasPriceGwei: [1, 0.05], rows, generated: new Date().toISOString() }, null, 1));

  const pass = R.filter((r) => r.c === true).length, fail = R.filter((r) => r.c === false).length, sk = R.filter((r) => r.c === null).length;
  log('\n==== ' + pass + ' OK · ' + fail + ' FALLAN · ' + sk + ' skipped · fork block ' + fork + ' ====');
  fs.writeFileSync(path.join(ROOT, 'run', 'results.json'), JSON.stringify({ forkBlock: fork, pass, fail, skipped: sk, checks: R, generated: new Date().toISOString() }, null, 1));
  if (fail) { log('FALLAN:'); for (const r of R) if (r.c === false) log('  -', r.s); process.exit(1); }
})().catch((e) => { console.error('ERROR', e); process.exit(2); });
