// ArchitectSendTo fork test (anvil :8906, fork of Robinhood Chain mainnet): buy from A and receive in B; sell from B and get paid in C.
const fs = require('fs'), path = require('path'), { ethers } = require('ethers');
const DIR = __dirname;
const A = JSON.parse(fs.readFileSync((process.env.DESK_ADDRESSES || require('path').join(__dirname, '../../deployments/desk-addresses.json')), 'utf8'));
const p = new ethers.JsonRpcProvider('http://127.0.0.1:8906', 4663, { staticNetwork: true, batchMaxCount: 1 });
const WETH = A.weth || A.WETH, ROUTER = A.feeRouterV2, ROUTER_OWNER = '0xa6CD59b326F8bc5Cf68EcD2377Eee13AfBbb1657';
const TOKEN = '0xb9d3824149ad8ac984153ceec91d5a2405d1fb95', POOL_FEE = 10000, FEE_BPS = 100, E = 10n ** 18n;
const AC = ethers.AbiCoder.defaultAbiCoder();
const ROUTE = AC.encode(['uint8', 'bytes'], [0, AC.encode(['uint24'], [POOL_FEE])]);
const W = (x) => ethers.formatEther(x) + ' ETH';
const R = []; const log = (...a) => console.log(...a);
const ok = (s, c, e) => { R.push({ s, c: !!c }); log(c ? ' OK  ' : ' XXX ', s, e === undefined ? '' : '| ' + e); };
const rpc = (m, ...a) => p.send(m, a);
const NONCE = {};   // anvil fork: getTransactionCount de una wallet nueva vuelve 0 aunque ya haya minado; se lleva a mano (wallets random arrancan en 0)
const nn = async (w) => { const n = NONCE[w.address] || 0; NONCE[w.address] = n + 1; return { nonce: n }; };
const expiry = (s) => BigInt(Math.floor(Date.now() / 1000) + (s || 3600));
const erc20 = ['function balanceOf(address) view returns (uint256)', 'function approve(address,uint256) returns (bool)'];
const RI = new ethers.Interface(['function setCaller(address,bool)', 'function isCaller(address) view returns (bool)', 'function accrued(address,address) view returns (uint256)', 'function treasury() view returns (address)', 'function referrerOf(address) view returns (address)', 'error NotCaller()', 'error Slippage(uint256,uint256)', 'error Expired()', 'error BadRoute()']);
async function expectRevert(name, fn, errName, ifaces) {
  try { await fn(); ok('NEG ' + name + ' -> ' + errName, false, 'NO revirtio'); }
  catch (e) { const d = e.data || (e.info && e.info.error && e.info.error.data) || ''; let got = e.shortMessage || e.message; for (const i of ifaces.concat([RI])) { try { const pe = i.parseError(d); if (pe) { got = pe.name; break; } } catch (_) {} } ok('NEG ' + name + ' -> ' + errName, got === errName || String(got).includes(errName), got); }
}
const evOf = (rc, iface, n) => { for (const l of rc.logs) { try { const e = iface.parseLog({ topics: l.topics, data: l.data }); if (e && e.name === n) return e.args; } catch (_) {} } return null; };
(async () => {
  const mk = () => ethers.Wallet.createRandom().connect(p);
  const a = mk(), b = mk(), c = mk(), o = mk();
  for (const x of [a, b, c, o]) await rpc('anvil_setBalance', x.address, '0x56BC75E2D63100000');
  const abi = JSON.parse(fs.readFileSync(path.join(DIR, 'artifacts', 'ArchitectSendTo.abi.json'), 'utf8'));
  const bin = '0x' + fs.readFileSync(path.join(DIR, 'artifacts', 'ArchitectSendTo.bin'), 'utf8');
  const st = await (await new ethers.ContractFactory(abi, bin, o).deploy(ROUTER)).waitForDeployment();
  const ST = await st.getAddress(), IF = new ethers.Interface(abi);
  const tok = new ethers.Contract(TOKEN, erc20, p), router = new ethers.Contract(ROUTER, RI, p);
  const TREAS = await router.treasury();
  ok('T0 WETH del contrato == router.WETH()', (await st.WETH()).toLowerCase() === WETH.toLowerCase());
  // antes del allowlist: el router rechaza al contrato (ruta V3 -> swapWithFee)
  await expectRevert('buyWithETH sin allowlist del router', () => st.connect(a).buyWithETH.staticCall(TOKEN, 1n, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE, b.address, { value: E / 100n }), 'NotCaller', [IF]);
  await rpc('anvil_impersonateAccount', ROUTER_OWNER); await rpc('anvil_setBalance', ROUTER_OWNER, '0x56BC75E2D63100000');
  const h = await rpc('eth_sendTransaction', { from: ROUTER_OWNER, to: ROUTER, data: RI.encodeFunctionData('setCaller', [ST, true]), gas: '0x30000' });
  for (let i = 0; i < 60 && !(await p.getTransactionReceipt(h)); i++) await new Promise((r) => setTimeout(r, 250));
  await rpc('anvil_stopImpersonatingAccount', ROUTER_OWNER);
  ok('T0 router.isCaller(sendTo)', await router.isCaller(ST));
  // ── T1 A compra, B recibe ──
  const aTok0 = await tok.balanceOf(a.address), bTok0 = await tok.balanceOf(b.address), tr0 = await router.accrued(TREAS, WETH);
  await expectRevert('recipient cero', () => st.connect(a).buyWithETH.staticCall(TOKEN, 1n, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE, ethers.ZeroAddress, { value: E / 100n }), 'ZeroAddress', [IF]);
  await expectRevert('sin ETH', () => st.connect(a).buyWithETH.staticCall(TOKEN, 1n, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE, b.address, { value: 0n }), 'BadValue', [IF]);
  await expectRevert('deadline vencido', () => st.connect(a).buyWithETH.staticCall(TOKEN, 1n, FEE_BPS, ethers.ZeroAddress, expiry(-10), ROUTE, b.address, { value: E / 100n }), 'Expired', [IF]);
  await expectRevert('minOut imposible', () => st.connect(a).buyWithETH.staticCall(TOKEN, 10n ** 30n, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE, b.address, { value: E / 100n }), 'Slippage', [IF]);
  const rc1 = await (await st.connect(a).buyWithETH(TOKEN, 1n, FEE_BPS, c.address, expiry(), ROUTE, b.address, { value: E / 100n, ...(await nn(a)) })).wait();
  const e1 = evOf(rc1, IF, 'SentTo');
  const bTok1 = await tok.balanceOf(b.address);
  ok('T1 B recibio el token, A no (compro A)', bTok1 > bTok0 && (await tok.balanceOf(a.address)) === aTok0 && e1 && e1.recipient === b.address && e1.payer === a.address && e1.amountOut === bTok1 - bTok0, (bTok1 - bTok0) + ' tok · gas ' + rc1.gasUsed);
  ok('T1 fee 1 % en WETH quedo en el router para la tesoreria', (await router.accrued(TREAS, WETH)) > tr0);
  ok('T1 el contrato no retiene nada', (await tok.balanceOf(ST)) === 0n && (await p.getBalance(ST)) === 0n && (await new ethers.Contract(WETH, erc20, p).balanceOf(ST)) === 0n);
  ok('T1 el referral se ato al DESTINATARIO (B), no al que pago', (await router.referrerOf(b.address)).toLowerCase() === c.address.toLowerCase());
  // ── T2 B vende, C cobra el ETH ──
  await (await tok.connect(b).approve(ST, bTok1, await nn(b))).wait();
  const cEth0 = await p.getBalance(c.address), bEth0 = await p.getBalance(b.address);
  await expectRevert('vender a un contrato que rechaza ETH (el router)', () => st.connect(b).sellToETH.staticCall(TOKEN, bTok1, 1n, FEE_BPS, ethers.ZeroAddress, expiry(), ROUTE, ROUTER), 'EthTransferFailed', [IF]);
  const rc2 = await (await st.connect(b).sellToETH(TOKEN, bTok1, 1n, FEE_BPS, a.address, expiry(), ROUTE, c.address, await nn(b))).wait();   // referrer no-cero a proposito: el contrato lo descarta
  const e2 = evOf(rc2, IF, 'SentTo');
  const bn2 = rc2.blockNumber;   // saldos por numero de bloque: en el fork 'latest' queda viejo para wallets nuevas
  const cEthNow = await p.getBalance(c.address, bn2), cEthPrev = await p.getBalance(c.address, bn2 - 1), bEthNow = await p.getBalance(b.address, bn2), bEthPrev = await p.getBalance(b.address, bn2 - 1);
  ok('T2 C cobro el ETH, B quedo sin el token y pago solo el gas', cEthNow - cEthPrev === e2.amountOut && (await tok.balanceOf(b.address)) === 0n && bEthNow < bEthPrev, W(e2.amountOut) + ' · C +' + W(cEthNow - cEthPrev) + ' · gas ' + rc2.gasUsed);
  ok('T2 el contrato no retiene nada', (await tok.balanceOf(ST)) === 0n && (await p.getBalance(ST)) === 0n);
  ok('T2 el router NO quedo con un referido atado al contrato (swapToETH con referrer 0)', (await router.referrerOf(ST)) === ethers.ZeroAddress);
  // ── T3 sweep solo del owner; ETH suelto rechazado ──
  const nA = await nn(a);
  await expectRevert('receive() desde una wallet', () => a.sendTransaction({ to: ST, value: 1n, ...nA }).then((t) => t.wait()), 'BadRoute', [IF]);
  await expectRevert('sweep desde otro', () => st.connect(a).sweep.staticCall(TOKEN, a.address), 'NotOwner', [IF]);
  const pass = R.filter((r) => r.c).length, fail = R.filter((r) => !r.c).length;
  log('\n==== ' + pass + ' OK · ' + fail + ' FALLAN ====');
  if (fail) process.exit(1);
})().catch((e) => { console.error('ERROR', e); process.exit(2); });
