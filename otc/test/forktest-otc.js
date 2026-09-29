// ArchitectOTC fork test on an anvil fork of Robinhood Chain mainnet (port 8904).
// Calcado del harness de Shadow: wallets nuevas (las del mnemonic tienen delegate 7702 en mainnet),
// pools REALES (NLYRA/WETH V3 1%, USDG/WETH V3), burner REAL. Nada toca mainnet.
//   node otc/forktest-otc.js
const fs = require('fs'), path = require('path'), { ethers } = require('ethers');
const DIR = __dirname;
const p = new ethers.JsonRpcProvider('http://127.0.0.1:8904', 4663, { staticNetwork: true, batchMaxCount: 1 });
const _est = p.estimateGas.bind(p); p.estimateGas = async (t) => ((await _est(t)) * 3n) / 2n;

const WETH = '0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73';
const NLYRA = '0xb9d3824149ad8ac984153ceec91d5a2405d1fb95';
const USDG = '0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168';
const BURNER = '0x371bB2107f6E021EF2a5a980a9204F5a73151926';
const ROUTER = '0xcaf681a66d020601342297493863e78c959e5cb2';   // SwapRouter02 (burner.router())
const DEAD = '0x000000000000000000000000000000000000dEaD';
const NLYRA_POOL_FEE = 10000, USDG_POOL_FEE = 500;
const E = 10n ** 18n, U6 = 10n ** 6n;

const log = (...a) => console.log(...a);
const R = [];
const ok = (s, c, e) => { R.push({ s, c: !!c }); log(c ? ' OK  ' : ' XXX ', s, e === undefined ? '' : '| ' + e); };
const rpc = (m, ...a) => p.send(m, a);
let LASTBN = 0;
// anvil fork: 'latest' may come from the upstream RPC (the real chain keeps moving); always read by local block number
const headBn = async () => Math.max(LASTBN, Number(await p.getBlockNumber()));
const now = async () => Number((await p.getBlock(await headBn())).timestamp);
const erc20 = ['function balanceOf(address) view returns (uint256)', 'function approve(address,uint256) returns (bool)', 'function transfer(address,uint256) returns (bool)', 'function decimals() view returns (uint8)'];
const bal = (t, a) => new ethers.Contract(t, erc20, p).balanceOf(a);
const eth = (a, bn) => p.getBalance(a, bn === undefined ? 'latest' : bn);
const NONCE = {};
async function nonceOf(addr) { if (NONCE[addr] === undefined) NONCE[addr] = await p.getTransactionCount(addr, 'latest'); return NONCE[addr]; }
/** manda contract[fn](...args) llevando el nonce a mano; solo avanza si la tx entro */
async function tx(c, fn, args, ov, label) {
  const addr = c.runner.address; const n = await nonceOf(addr);
  const t = await c[fn](...args, { ...(ov || {}), nonce: n });
  const rc = await t.wait(); NONCE[addr] = n + 1; LASTBN = Math.max(LASTBN, rc.blockNumber);
  log('    tx', label || fn, 'gas', rc.gasUsed.toString()); return rc;
}
async function expectRevert(name, fn, errName, iface) {
  try { await fn(); ok('NEG ' + name + ' -> ' + errName, false, 'NO revirtio'); }
  catch (e) {
    const d = e.data || (e.info && e.info.error && e.info.error.data) || '';
    let got = e.shortMessage || e.message;
    try { const pe = iface.parseError(d); if (pe) got = pe.name + '(' + pe.args.join(',') + ')'; } catch (_) { }
    ok('NEG ' + name + ' -> ' + errName, String(got).includes(errName), 'got=' + String(got).slice(0, 90));
  }
}
const evOf = (rc, iface, n) => { for (const l of rc.logs) { try { const e = iface.parseLog({ topics: l.topics, data: l.data }); if (e && e.name === n) return e.args; } catch (_) { } } return null; };
const near = (a, b, bps) => { const d = a > b ? a - b : b - a; return d * 10000n <= (b === 0n ? 1n : b) * BigInt(bps); };

(async () => {
  const limpia = async () => ethers.Wallet.createRandom().connect(p);
  const s = await limpia(), b = await limpia(), k = await limpia(), o = await limpia();   // seller, buyer, flusher, other
  for (const x of [s, b, k, o]) await rpc('anvil_setBalance', x.address, '0x56BC75E2D63100000'); // 100 ETH

  // ── comprar NLYRA y USDG reales en el fork (SwapRouter02, como hace el burner) ──
  const RI = ['function exactInputSingle((address,address,uint24,address,uint256,uint256,uint160)) payable returns (uint256)'];
  const rs = new ethers.Contract(ROUTER, RI, s), rb = new ethers.Contract(ROUTER, RI, b), ro = new ethers.Contract(ROUTER, RI, o);
  await tx(rs, 'exactInputSingle', [[WETH, NLYRA, NLYRA_POOL_FEE, s.address, E / 2n, 0, 0]], { value: E / 2n }, 'seller buys NLYRA');
  await tx(rb, 'exactInputSingle', [[WETH, USDG, USDG_POOL_FEE, b.address, E, 0, 0]], { value: E }, 'buyer buys USDG');
  await tx(ro, 'exactInputSingle', [[WETH, NLYRA, NLYRA_POOL_FEE, o.address, E / 5n, 0, 0]], { value: E / 5n }, 'other buys NLYRA');
  const sN = await bal(NLYRA, s.address), bU = await bal(USDG, b.address), oN = await bal(NLYRA, o.address);
  log('  seller NLYRA', ethers.formatEther(sN), '| buyer USDG', ethers.formatUnits(bU, 6), '| other NLYRA', ethers.formatEther(oN));
  ok('fixtures: seller has NLYRA, buyer has USDG', sN > 0n && bU > 0n);

  // ── deploy ──
  const abi = JSON.parse(fs.readFileSync(path.join(DIR, 'artifacts', 'ArchitectOTC.abi.json'), 'utf8'));
  const bin = '0x' + fs.readFileSync(path.join(DIR, 'artifacts', 'ArchitectOTC.bin'), 'utf8');
  const otc = await (await new ethers.ContractFactory(abi, bin, s).deploy(WETH, NLYRA, BURNER, ROUTER, USDG, k.address, 50, { nonce: await nonceOf(s.address) })).waitForDeployment(); NONCE[s.address] += 1;
  const OTC = await otc.getAddress(), IF = new ethers.Interface(abi);
  const otcB = otc.connect(b), otcK = otc.connect(k), otcO = otc.connect(o);
  ok('deployed; owner = deployer, fee 50 bps, USDG+NLYRA quotes', (await otc.owner()) === s.address && (await otc.feeBps()) === 50n && (await otc.isQuote(USDG)) && (await otc.isQuote(NLYRA)));
  const tokS = new ethers.Contract(NLYRA, erc20, s), usdgB = new ethers.Contract(USDG, erc20, b), tokO = new ethers.Contract(NLYRA, erc20, o);

  // ── 1. NLYRA por ETH: crear, fill parcial, fill final (dust vuelve al seller), fee al burner ──
  const amt1 = 1_000_000n * E, want1 = E / 10n;                    // 1M NLYRA por 0.1 ETH
  await tx(tokS, 'approve', [OTC, amt1], null, 'approve NLYRA');
  let rc = await tx(otc, 'create', [NLYRA, amt1, ethers.ZeroAddress, want1, want1 / 10n, BigInt(await now()) + 3600n, ethers.ZeroAddress], null, 'create #1');
  const ev1 = evOf(rc, IF, 'OfferCreated');
  ok('#1 created: id 1, amount escrowed, escrowed[NLYRA] = amount', ev1 && ev1.id === 1n && (await otc.escrowed(NLYRA)) === amt1 && (await bal(NLYRA, OTC)) === amt1);
  await expectRevert('fill #1 below minFill', () => otcB.fill(1, 0, { value: want1 / 100n }), 'BelowMinFill', IF);
  await expectRevert('fill #1 above want', () => otcB.fill(1, 0, { value: want1 * 2n }), 'TooMuch', IF);
  await expectRevert('fill #1 with zero value', () => otcB.fill(1, 0, { value: 0 }), 'BadValue', IF);
  const burner0 = await eth(BURNER), seller0 = await eth(s.address), bN0 = await bal(NLYRA, b.address);
  rc = await tx(otcB, 'fill', [1, 0], { value: want1 / 4n }, 'fill #1 25%');
  let f = evOf(rc, IF, 'OfferFilled');
  ok('#1 partial: buyer gets 25% of tokens, not closed', f && f.tokenOut === amt1 / 4n && f.closed === false && (await bal(NLYRA, b.address)) - bN0 === amt1 / 4n);
  { const bn = rc.blockNumber; const bd = (await eth(BURNER, bn)) - (await eth(BURNER, bn - 1)), sd = (await eth(s.address, bn)) - (await eth(s.address, bn - 1));
    log('    dbg block', bn, 'burner delta', bd.toString(), 'seller delta', sd.toString(), 'latest-read deltas', ((await eth(BURNER)) - burner0).toString(), ((await eth(s.address)) - seller0).toString(), '| otc eth', (await eth(OTC)).toString(), 'pendingEth[s]', (await otc.pendingEth(s.address)).toString(), 'accruedFee[0]', (await otc.accruedFee(ethers.ZeroAddress)).toString());
    ok('#1 partial: fee 0.5% reached the burner in the same tx', bd === (want1 / 4n) * 50n / 10000n && f.fee === (want1 / 4n) * 50n / 10000n, 'burner delta=' + bd);
    ok('#1 partial: seller got payment minus fee', sd === want1 / 4n - f.fee, 'seller delta=' + sd); }
  let of1 = await otc.offers(1);
  ok('#1 partial: remaining amount 75%, want 75%', of1.amount === (amt1 * 3n) / 4n && of1.want === (want1 * 3n) / 4n && of1.status === 0n);
  // remate: pagar exactamente lo que falta cierra la oferta
  rc = await tx(otcB, 'fill', [1, 0], { value: (want1 * 3n) / 4n }, 'fill #1 rest');
  f = evOf(rc, IF, 'OfferFilled');
  of1 = await otc.offers(1);
  ok('#1 closed: status Filled, amount 0, escrow back to 0, buyer holds all', f.closed === true && of1.status === 1n && of1.amount === 0n && (await otc.escrowed(NLYRA)) === 0n && (await bal(NLYRA, b.address)) - bN0 === amt1);
  await expectRevert('fill closed #1', () => otcB.fill(1, 0, { value: 1000n }), 'NotOpen', IF);
  ok('stats: totalVolume[ETH] = 0.1 ETH, totalFee[ETH] = 0.0005', (await otc.totalVolume(ethers.ZeroAddress)) === want1 && (await otc.totalFee(ethers.ZeroAddress)) === want1 * 50n / 10000n);

  // ── 2. NLYRA por USDG: fee acumulada, flush por el flusher al burner ──
  const amt2 = 500_000n * E, want2 = 20n * U6;                      // 500k NLYRA por 20 USDG
  await tx(tokS, 'approve', [OTC, amt2], null, 'approve NLYRA');
  rc = await tx(otc, 'create', [NLYRA, amt2, USDG, want2, 0, BigInt(await now()) + 3600n, ethers.ZeroAddress], null, 'create #2 (USDG)');
  await expectRevert('fill USDG offer with ETH value', () => otcB.fill(2, want2, { value: 1000n }), 'BadValue', IF);
  await tx(usdgB, 'approve', [OTC, want2], null, 'approve USDG');
  const sU0 = await bal(USDG, s.address);
  rc = await tx(otcB, 'fill', [2, want2], null, 'fill #2 full');
  f = evOf(rc, IF, 'OfferFilled');
  const fee2 = want2 * 50n / 10000n;
  ok('#2: seller got 19.9 USDG, fee 0.1 USDG accrued (not sent yet)', (await bal(USDG, s.address)) - sU0 === want2 - fee2 && (await otc.accruedFee(USDG)) === fee2 && f.closed === true);
  await expectRevert('flush by a stranger', () => otcO.flush(USDG, USDG_POOL_FEE, 0), 'NotFlusher', IF);
  const burner1 = await eth(BURNER);
  rc = await tx(otcK, 'flush', [USDG, USDG_POOL_FEE, 0], null, 'flush USDG -> ETH -> burner');
  const fl = evOf(rc, IF, 'FeeToBurner');
  { const bn = rc.blockNumber; const bd = (await eth(BURNER, bn)) - (await eth(BURNER, bn - 1));
    log('    dbg flush ethOut', fl.ethOut.toString(), 'burner delta(block)', bd.toString(), 'otc eth', (await eth(OTC)).toString(), 'otc weth', (await bal(WETH, OTC)).toString());
    ok('flush: accrued USDG -> 0, burner received ETH, contract keeps no WETH/ETH', (await otc.accruedFee(USDG)) === 0n && bd === fl.ethOut && fl.ethOut > 0n && (await eth(OTC)) === 0n && (await bal(WETH, OTC)) === 0n, 'burner delta=' + bd); }
  await expectRevert('flush with nothing accrued', () => otcK.flush(USDG, USDG_POOL_FEE, 0), 'Nothing', IF);

  // ── 3. USDG por NLYRA: la fee en NLYRA se quema a 0xdEaD ──
  const amt3 = 5n * U6, want3 = 100_000n * E;                       // 5 USDG por 100k NLYRA
  await tx(usdgB, 'approve', [OTC, amt3], null, 'approve USDG');
  rc = await tx(otcB, 'create', [USDG, amt3, NLYRA, want3, 0, BigInt(await now()) + 3600n, ethers.ZeroAddress], null, 'create #3 (sell USDG for NLYRA)');
  await tx(tokO, 'approve', [OTC, want3], null, 'approve NLYRA');
  const dead0 = await bal(NLYRA, DEAD);
  rc = await tx(otcO, 'fill', [3, want3], null, 'fill #3');
  const fee3 = want3 * 50n / 10000n;
  ok('#3: NLYRA fee burned to 0xdEaD, totalNlyraBurned updated', (await bal(NLYRA, DEAD)) - dead0 === fee3 && (await otc.totalNlyraBurned()) === fee3 && (await bal(USDG, o.address)) === amt3);

  // ── 4. taker fijo, expiry, cancel ──
  const amt4 = 10_000n * E, want4 = E / 1000n;
  await tx(tokS, 'approve', [OTC, amt4 * 20n], null, 'approve NLYRA (x20)');
  await tx(otc, 'create', [NLYRA, amt4, ethers.ZeroAddress, want4, 0, BigInt(await now()) + 3600n, b.address], null, 'create #4 (taker = buyer)');
  await expectRevert('other fills a taker-locked offer', () => otcO.fill(4, 0, { value: want4 }), 'NotTaker', IF);
  await tx(otcB, 'fill', [4, 0], { value: want4 }, 'taker fills #4');
  ok('#4 filled by the named taker', (await otc.offers(4)).status === 1n);
  await tx(otc, 'create', [NLYRA, amt4, ethers.ZeroAddress, want4, 0, BigInt(await now()) + 120n, ethers.ZeroAddress], null, 'create #5 (expires in 2 min)');
  await expectRevert('stranger cancels a live offer', () => otcO.cancel(5), 'NotSeller', IF);
  const exp5 = Number((await otc.offers(5)).expiry);
  await rpc('evm_increaseTime', 3600); await rpc('evm_setNextBlockTimestamp', exp5 + 100); await rpc('evm_mine');
  await expectRevert('fill after expiry', () => otcB.fill.staticCall(5, 0, { value: want4, blockTag: 'pending' }), 'Expired', IF);
  const sN5 = await bal(NLYRA, s.address);
  await rpc('evm_setNextBlockTimestamp', exp5 + 200);
  try { rc = await tx(otcO, 'cancel', [5], { gasLimit: 300000 }, 'stranger cancels EXPIRED #5'); }
  catch (e) { const h = e.receipt && e.receipt.hash; const r = h ? await p.getTransactionReceipt(h) : null; const blk = r ? await p.getBlock(r.blockNumber) : null;
    log('    dbg cancel(5) reverted on-chain: status', r && r.status, 'block', r && r.blockNumber, 'block ts', blk && Number(blk.timestamp), 'expiry', exp5, '| offer5', JSON.stringify(await otc.offers(5), (k, v) => typeof v === 'bigint' ? v.toString() : v));
    throw e; }
  { const blk = await p.getBlock(rc.blockNumber); log('    dbg cancel block ts', Number(blk.timestamp), 'expiry', exp5); }
  const c5 = evOf(rc, IF, 'OfferCancelled');
  ok('#5 expired: anyone can cancel, tokens go back to the SELLER', c5.expired === true && (await bal(NLYRA, s.address)) - sN5 === amt4 && (await otc.offers(5)).status === 2n);
  await tx(otc, 'create', [NLYRA, amt4, ethers.ZeroAddress, want4, 0, BigInt(await now()) + 3600n, ethers.ZeroAddress], null, 'create #6');
  const sN6 = await bal(NLYRA, s.address);
  await tx(otc, 'cancel', [6], null, 'seller cancels #6');
  ok('#6 cancelled by seller: refund exact, escrow 0', (await bal(NLYRA, s.address)) - sN6 === amt4 && (await otc.escrowed(NLYRA)) === 0n);
  await expectRevert('cancel twice', () => otc.cancel(6), 'NotOpen', IF);

  const EXP = BigInt(await now()) + 3600n;
  // ── 5. params, owner, pause, rescue ──
  await expectRevert('create with token == quote', () => otc.create(NLYRA, amt4, NLYRA, want4, 0, EXP, ethers.ZeroAddress), 'BadParams', IF);
  await expectRevert('create with a non-allowed quote (WETH)', () => otc.create(NLYRA, amt4, WETH, want4, 0, EXP, ethers.ZeroAddress), 'BadQuote', IF);
  await expectRevert('create with expiry in the past', () => otc.create(NLYRA, amt4, ethers.ZeroAddress, want4, 0, EXP - 3610n, ethers.ZeroAddress), 'BadParams', IF);
  await expectRevert('create with expiry > 1 year', () => otc.create(NLYRA, amt4, ethers.ZeroAddress, want4, 0, EXP + 400n * 86400n, ethers.ZeroAddress), 'BadParams', IF);
  await expectRevert('create without allowance', () => otcO.create(NLYRA, oN, ethers.ZeroAddress, want4, 0, EXP, ethers.ZeroAddress), 'TransferFailed', IF);
  await expectRevert('setFeeBps 101 (cap 1%)', () => otc.setFeeBps(101), 'BadFee', IF);
  await expectRevert('non-owner setFeeBps', () => otcO.setFeeBps(10), 'NotOwner', IF);
  await tx(otc, 'setFeeBps', [0], null, 'fee -> 0');
  await tx(otc, 'create', [NLYRA, amt4, ethers.ZeroAddress, want4, 0, BigInt(await now()) + 3600n, ethers.ZeroAddress], null, 'create #7 (fee 0)');
  rc = await tx(otcB, 'fill', [7, 0], { value: want4 }, 'fill #7 with fee 0');
  ok('fee 0: seller receives the whole payment', (await eth(s.address, rc.blockNumber)) - (await eth(s.address, rc.blockNumber - 1)) === want4 && evOf(rc, IF, 'OfferFilled').fee === 0n);
  await tx(otc, 'setFeeBps', [50], null, 'fee -> 50');
  await tx(otc, 'setPaused', [true], null, 'pause');
  await expectRevert('create while paused', () => otc.create(NLYRA, amt4, ethers.ZeroAddress, want4, 0, EXP, ethers.ZeroAddress), 'IsPaused', IF);
  await tx(otc, 'setPaused', [false], null, 'unpause');
  await tx(otc, 'create', [NLYRA, amt4, ethers.ZeroAddress, want4, 0, BigInt(await now()) + 3600n, ethers.ZeroAddress], null, 'create #8');
  await tx(otc, 'setPaused', [true], null, 'pause');
  await expectRevert('fill while paused', () => otcB.fill(8, 0, { value: want4 }), 'IsPaused', IF);
  await tx(otc, 'cancel', [8], null, 'cancel #8 while paused (always allowed)');
  ok('paused: cancel still works', (await otc.offers(8)).status === 2n);
  await tx(otc, 'setPaused', [false], null, 'unpause');
  // rescue cannot touch escrow: with an open offer, rescue(NLYRA) has nothing free
  await tx(otc, 'create', [NLYRA, amt4, ethers.ZeroAddress, want4, 0, BigInt(await now()) + 3600n, ethers.ZeroAddress], null, 'create #9');
  await expectRevert('rescue(NLYRA) with only escrow inside', () => otc.rescue(NLYRA, s.address), 'Nothing', IF);
  await tx(usdgB, 'transfer', [OTC, 1000n], null, 'buyer sends 1000 units of USDG by mistake');
  const sU9 = await bal(USDG, s.address);
  await tx(otc, 'rescue', [USDG, s.address], null, 'rescue the stray 1000 USDG units');
  ok('rescue: only the stray amount leaves, NLYRA escrow intact', (await bal(USDG, s.address)) - sU9 === 1000n && (await bal(NLYRA, OTC)) === amt4 && (await otc.escrowed(NLYRA)) === amt4 && (await bal(USDG, OTC)) === 0n);
  const nO = await nonceOf(o.address);
  await expectRevert('plain ETH transfer to the contract', () => o.sendTransaction({ to: OTC, value: 1000n, nonce: nO }), 'BadValue', IF);
  const list = await otc.getOffers(1, 50);
  ok('getOffers(1,50) returns all 9 offers with the right sellers', list.length === 9 && list[0].seller === s.address && list[2].seller === b.address && list[8].status === 0n);
  const list2 = await otc.getOffers(8, 50);
  ok('getOffers(8,50) clamps to 2', list2.length === 2);

  // ── 6. el burner cierra el circuito: quema el ETH recibido ──
  const bu = new ethers.Contract(BURNER, ['function burn(uint256) returns (uint256)', 'function totalNlyraBurned() view returns (uint256)'], o);
  const dead1 = await bal(NLYRA, DEAD);
  rc = await tx(bu, 'burn', [0], null, 'burner.burn(0)');
  ok('burner.burn: NLYRA bought with the OTC fees landed in 0xdEaD', (await bal(NLYRA, DEAD)) > dead1);

  const pass = R.filter((x) => x.c).length;
  log('\n' + pass + '/' + R.length + ' OK');
  if (pass !== R.length) { for (const x of R) if (!x.c) log('  FAIL', x.s); process.exit(1); }
})().catch((e) => { console.error('ERR', e.shortMessage || e.message, e.data || ''); process.exit(1); });
