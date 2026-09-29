// Deploy de ArchitectSendTo sobre el fee router v2. Calcado de v4/deploy-infv4.js.
// NO toca nada de lo ya deployado: escribe la clave NUEVA `sniper` (+Tx, +Block, +CallerTx) en los DOS
// desk-addresses.json y NUNCA sobreescribe una clave existente.
//
//   node sendto/deploy-sendto.js compile   -> compila, ABI/bin en sniper/artifacts, tamaño EIP-170, invariantes de la ABI
//   node sendto/deploy-sendto.js estimate  -> SOLO LECTURA: estima el gas y el costo en ETH
//   node sendto/deploy-sendto.js deploy    -> deploya + router.setCaller(sniper, true) + chequeo post-deploy
//   node sendto/deploy-sendto.js check     -> SOLO LECTURA: estado post-deploy
//
// La clave privada se lee del entorno EN TIEMPO DE EJECUCION (LAUNCHPAD_OPS_SECRET, via a local .env file).
const fs = require('fs');
const path = require('path');
const solc = require('solc');
const { ethers } = require('ethers');
require('dotenv').config({ path: process.env.DOTENV_CONFIG_PATH || '.env', quiet: true });

const DIR = __dirname;
const OUT = path.join(DIR, 'artifacts');
const ROOT = path.dirname(DIR);
const RPC = process.env.RH_RPC || 'https://rpc.mainnet.chain.robinhood.com';
const CHAIN_ID = 4663;
const ADDR_FILE = process.env.DESK_ADDRESSES || path.join(ROOT, '..', 'deployments', 'desk-addresses.json');
const SITE_COPY = (process.env.DESK_ADDRESSES || require('path').join(__dirname, '../../deployments/desk-addresses.json'));
const KEY = 'sendTo', NAME = 'ArchitectSendTo';
const GAS_OVERHEAD_EXPECTED = 80_000n;
const readState = () => JSON.parse(fs.readFileSync(ADDR_FILE, 'utf8'));

function compile() {
  const read = (f) => fs.readFileSync(path.join(DIR, f), 'utf8');
  const file = NAME + '.sol';
  const input = { language: 'Solidity', sources: { [file]: { content: read(file) } },
    settings: { optimizer: { enabled: true, runs: 200 }, viaIR: true, evmVersion: 'cancun', outputSelection: { '*': { '*': ['abi', 'evm.bytecode.object', 'evm.deployedBytecode.object', 'metadata'] } } } };
  const out = JSON.parse(solc.compile(JSON.stringify(input)));
  const errs = (out.errors || []).filter((e) => e.severity === 'error');
  if (errs.length) { console.error(errs.map((e) => e.formattedMessage).join('\n')); process.exit(1); }
  const c = out.contracts[file][NAME];
  fs.mkdirSync(OUT, { recursive: true });
  fs.writeFileSync(path.join(OUT, NAME + '.abi.json'), JSON.stringify(c.abi, null, 1));
  fs.writeFileSync(path.join(OUT, NAME + '.bin'), c.evm.bytecode.object);
  fs.writeFileSync(path.join(OUT, NAME + '.deployed.bin'), c.evm.deployedBytecode.object);
  fs.writeFileSync(path.join(OUT, NAME + '.input.json'), JSON.stringify(input, null, 1));
  const size = c.evm.deployedBytecode.object.length / 2;
  console.log('compilado', NAME, 'runtime', size, 'bytes', size > 24576 ? '*** OVER EIP-170 ***' : '(< 24576 ok)');
  if (size > 24576) process.exit(1);
  const fn = (n) => c.abi.find((f) => f.type === 'function' && f.name === n);
  for (const n of ['buyWithETH', 'buyWithToken', 'sellToETH', 'sellToToken', 'sweep', 'owner', 'ROUTER', 'WETH']) if (!fn(n)) { console.error(NAME, 'falta', n); process.exit(1); }
  if (!c.abi.some((f) => f.type === 'event' && f.name === 'SentTo')) { console.error('falta evento SentTo'); process.exit(1); }
  const sha = require('crypto').createHash('sha256').update(read(file)).digest('hex').slice(0, 16);
  console.log('  sha256 del .sol:', sha, '(tiene que ser el que paso forktest-sendto.js)');
  return { abi: c.abi, bin: '0x' + c.evm.bytecode.object, size, sha };
}

function save(patch) {
  for (const f of [ADDR_FILE, SITE_COPY]) {
    let cur = {};
    try { cur = JSON.parse(fs.readFileSync(f, 'utf8')); } catch (_) { cur = readState(); }
    for (const [k, v] of Object.entries(patch)) {
      if (cur[k] !== undefined && cur[k] !== v) { console.error('NO se sobreescribe la clave existente', k, '=', cur[k]); process.exit(1); }
      cur[k] = v;
    }
    fs.writeFileSync(f, JSON.stringify(cur, null, 2));
  }
}

/// constructor(address router)
const ctorArgs = (s) => [s.feeRouterV2 || s.feeRouter];

function wallet() {
  const pk = process.env.LAUNCHPAD_OPS_SECRET;
  if (!pk) { console.error('LAUNCHPAD_OPS_SECRET missing en el entorno'); process.exit(1); }
  const provider = new ethers.JsonRpcProvider(RPC, CHAIN_ID, { staticNetwork: true });
  return new ethers.Wallet(pk.startsWith('0x') ? pk : '0x' + pk, provider);
}

async function preflight(provider) {
  const s = readState();
  const routerAddr = s.feeRouterV2 || s.feeRouter;
  const [router] = ctorArgs(s); const weth = s.weth || s.WETH;
  const r = new ethers.Contract(routerAddr, ['function WETH() view returns (address)', 'function owner() view returns (address)', 'function paused() view returns (bool)', 'function treasury() view returns (address)', 'function minFeeBps() view returns (uint16)', 'function maxFeeBps() view returns (uint16)'], provider);
  const rw = await r.WETH();
  console.log('preflight · router', routerAddr, 'owner', await r.owner(), 'paused', await r.paused(), 'treasury', await r.treasury(), 'fee', (await r.minFeeBps()).toString() + '-' + (await r.maxFeeBps()).toString(), 'bps');
  console.log('preflight · WETH', weth, '| router.WETH()', rw);
  if (String(rw).toLowerCase() !== String(weth).toLowerCase()) { console.error('router.WETH() != weth: el constructor revierte con BadGrid.'); process.exit(1); }
  if (s[KEY]) console.log('preflight ·', KEY, 'YA existe en el config:', s[KEY], '(deploy hara skip)');
  return { s, routerAddr };
}

async function estimate() {
  const provider = new ethers.JsonRpcProvider(RPC, CHAIN_ID, { staticNetwork: true });
  const { s } = await preflight(provider);
  const fee = await provider.getFeeData();
  const gp = fee.gasPrice || fee.maxFeePerGas || 0n;
  const c = compile();
  const data = c.bin + ethers.AbiCoder.defaultAbiCoder().encode(['address'], ctorArgs(s)).slice(2);
  let g; try { g = await provider.estimateGas({ from: s.deployer, data }); } catch (e) { console.log('estimateGas fallo:', (e.shortMessage || e.message).slice(0, 160)); return; }
  console.log(KEY, 'deploy gas', g.toString(), '~', ethers.formatEther(g * gp), 'ETH · + setCaller ~50k · gasPrice', ethers.formatUnits(gp, 'gwei'), 'gwei');
}

async function deploy() {
  const w = wallet();
  const { s: s0, routerAddr } = await preflight(w.provider);
  console.log('deployer', w.address, ethers.formatEther(await w.provider.getBalance(w.address)), 'ETH');
  if (w.address.toLowerCase() !== String(s0.deployer).toLowerCase()) console.log('AVISO: el deployer del entorno no coincide con desk-addresses.deployer', s0.deployer);
  const routerAbi = JSON.parse(fs.readFileSync(path.join(ROOT, 'ArchitectFeeRouter.abi.json'), 'utf8'));
  let state = readState();
  const c = compile();
  if (state[KEY]) console.log(KEY, 'ya esta en', state[KEY], '(skip deploy)');
  else {
    const f = new ethers.ContractFactory(c.abi, c.bin, w);
    console.log('deployando', NAME, 'args', ctorArgs(state));
    const ct = await f.deploy(...ctorArgs(state));
    const rc = await ct.deploymentTransaction().wait();
    const addr = await ct.getAddress();
    save({ [KEY]: addr, [KEY + 'Tx']: rc.hash, [KEY + 'Block']: rc.blockNumber });
    console.log(' ->', KEY, addr, 'gas', rc.gasUsed.toString(), 'tx', rc.hash, 'block', rc.blockNumber);
  }
  state = readState();
  const r = new ethers.Contract(routerAddr, routerAbi, w);
  if (!(await r.isCaller(state[KEY]))) {
    const tx = await r.setCaller(state[KEY], true); const rc = await tx.wait();
    save({ [KEY + 'CallerTx']: tx.hash });
    console.log(` router.setCaller(${KEY}, true)`, tx.hash, 'gas', rc.gasUsed.toString());
  }
  const C = new ethers.Contract(state[KEY], c.abi, w);
  console.log(KEY, 'isCaller', await r.isCaller(state[KEY]), 'owner', await C.owner(), 'ROUTER', await C.ROUTER(), 'WETH', await C.WETH());
  console.log('balance del deployer despues', ethers.formatEther(await w.provider.getBalance(w.address)));
}

async function check() {
  const provider = new ethers.JsonRpcProvider(RPC, CHAIN_ID, { staticNetwork: true });
  const s = readState();
  if (!s[KEY]) { console.log(KEY, 'sin deployar'); return; }
  const r = new ethers.Contract(s.feeRouterV2 || s.feeRouter, ['function isCaller(address) view returns (bool)'], provider);
  const abi = JSON.parse(fs.readFileSync(path.join(OUT, NAME + '.abi.json'), 'utf8'));
  const C = new ethers.Contract(s[KEY], abi, provider);
  console.log(KEY, s[KEY], '| isCaller', await r.isCaller(s[KEY]), '| owner', await C.owner(), '| code', ((await provider.getCode(s[KEY])).length - 2) / 2, 'bytes', '| block', s[KEY + 'Block']);
  const local = '0x' + fs.readFileSync(path.join(OUT, NAME + '.deployed.bin'), 'utf8');
  const onchain = await provider.getCode(s[KEY]);
  const strip = (x) => x.slice(0, -106);
  console.log('  bytecode EXACT', local === onchain, '| SIN_METADATA', strip(local) === strip(onchain), '(los immutable hacen que EXACT sea false: esperable)');
}

const cmd = process.argv[2];
({ compile: async () => compile(), estimate, deploy, check }[cmd] || (async () => { console.log('uso: compile | estimate | deploy | check'); }))().catch((e) => { console.error('ERR', e.shortMessage || e.message); process.exit(1); });
