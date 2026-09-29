// Deploy de ArchitectOTC (nlyra.xyz/otc). Calcado de v4/deploy-v4.js: NO toca nada de lo ya deployado,
// escribe las claves NUEVAS `otc`, `otcTx`, `otcBlock` en desk-addresses.json y NUNCA sobreescribe una existente.
//
//   node otc/deploy-otc.js compile   -> compila (otc/artifacts), tamaño EIP-170, invariantes
//   node otc/deploy-otc.js estimate  -> SOLO LECTURA: gas y costo en ETH del deploy
//   node otc/deploy-otc.js deploy    -> deploya + chequeo post-deploy + guarda direcciones
//   node otc/deploy-otc.js verify    -> Sourcify v2 (+ intento Blockscout standard-input)
//   node otc/deploy-otc.js check     -> SOLO LECTURA: estado post-deploy
//
// La clave privada se lee del entorno EN TIEMPO DE EJECUCION (LAUNCHPAD_OPS_SECRET via a local .env file,
// como el resto de los deploys). No esta hardcodeada ni se imprime.
const fs = require('fs');
const path = require('path');
const { ethers } = require('ethers');
require('dotenv').config({ path: process.env.DOTENV_CONFIG_PATH || '.env', quiet: true });

const DIR = __dirname;
const OUT = path.join(DIR, 'artifacts');
const ROOT = path.dirname(DIR);
const RPC = process.env.RH_RPC || 'https://rpc.mainnet.chain.robinhood.com';
const CHAIN_ID = 4663;
const ADDR_FILE = process.env.DESK_ADDRESSES || path.join(ROOT, '..', 'deployments', 'desk-addresses.json');
const SITE_COPY = (process.env.DESK_ADDRESSES || require('path').join(__dirname, '../../deployments/desk-addresses.json'));
const WEB_CFG = process.env.OTC_WEB_CONFIG || path.join(ROOT, 'web', 'config.json');
const NAME = 'ArchitectOTC', FILE = 'ArchitectOTC.sol';

const NLYRA = '0xb9d3824149ad8ac984153ceec91d5a2405d1fb95';
const BURNER = '0x371bB2107f6E021EF2a5a980a9204F5a73151926';
const ROUTER = '0xcaf681a66d020601342297493863e78c959e5cb2';   // SwapRouter02 = burner.router()
const FEE_BPS = 50;

const readState = () => JSON.parse(fs.readFileSync(ADDR_FILE, 'utf8'));
const ctorArgs = (s) => [s.weth || s.WETH, NLYRA, BURNER, ROUTER, s.USDG || s.usdg, s.keeper, FEE_BPS];
const CTOR_TYPES = ['address', 'address', 'address', 'address', 'address', 'address', 'uint16'];

function compile() {
  const r = require('child_process').spawnSync('node', [path.join(DIR, 'compile-otc.js')], { stdio: 'inherit' });
  if (r.status !== 0) process.exit(1);
  const abi = JSON.parse(fs.readFileSync(path.join(OUT, NAME + '.abi.json'), 'utf8'));
  const bin = '0x' + fs.readFileSync(path.join(OUT, NAME + '.bin'), 'utf8');
  const input = JSON.parse(fs.readFileSync(path.join(OUT, NAME + '.input.json'), 'utf8'));
  return { abi, bin, input };
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

function wallet() {
  const pk = process.env.LAUNCHPAD_OPS_SECRET;
  if (!pk) { console.error('LAUNCHPAD_OPS_SECRET missing en el entorno'); process.exit(1); }
  const provider = new ethers.JsonRpcProvider(RPC, CHAIN_ID, { staticNetwork: true });
  return new ethers.Wallet(pk.startsWith('0x') ? pk : '0x' + pk, provider);
}

async function preflight(provider) {
  const s = readState();
  const [weth, nlyra, burner, router, usdg, keeper] = ctorArgs(s);
  for (const [k, v] of Object.entries({ weth, nlyra, burner, router, usdg, keeper })) if (!/^0x[0-9a-fA-F]{40}$/.test(String(v))) { console.error('config invalido:', k, v); process.exit(1); }
  const b = new ethers.Contract(burner, ['function router() view returns (address)', 'function weth() view returns (address)', 'function nlyra() view returns (address)'], provider);
  const [br, bw, bn] = await Promise.all([b.router(), b.weth(), b.nlyra()]);
  console.log('preflight · burner.router()', br, '| burner.weth()', bw, '| burner.nlyra()', bn);
  if (br.toLowerCase() !== router.toLowerCase()) { console.error('ROUTER != burner.router()'); process.exit(1); }
  if (bw.toLowerCase() !== weth.toLowerCase()) { console.error('WETH del config != burner.weth()'); process.exit(1); }
  if (bn.toLowerCase() !== nlyra.toLowerCase()) { console.error('NLYRA != burner.nlyra()'); process.exit(1); }
  console.log('preflight · ctor', JSON.stringify({ weth, nlyra, burner, router, usdg, flusher: keeper, feeBps: FEE_BPS }));
  if (s.otc) console.log('preflight · otc YA existe en el config:', s.otc, '(deploy hara skip)');
  return s;
}

async function estimate() {
  const provider = new ethers.JsonRpcProvider(RPC, CHAIN_ID, { staticNetwork: true });
  const s = await preflight(provider);
  const c = compile();
  const fee = await provider.getFeeData();
  const gp = fee.gasPrice || fee.maxFeePerGas || 0n;
  const data = c.bin + ethers.AbiCoder.defaultAbiCoder().encode(CTOR_TYPES, ctorArgs(s)).slice(2);
  const from = s.deployer || s.owner || '0xa6CD59b326F8bc5Cf68EcD2377Eee13AfBbb1657';
  const g = await provider.estimateGas({ from, data });
  const bal = await provider.getBalance(from);
  console.log('deploy gas', g.toString(), '~', ethers.formatEther(g * gp), 'ETH · gasPrice', ethers.formatUnits(gp, 'gwei'), 'gwei · deployer', from, 'balance', ethers.formatEther(bal), 'ETH');
}

async function deploy() {
  const w = wallet();
  const s = await preflight(w.provider);
  if (s.otc) { console.log('otc ya deployado en', s.otc, '- skip'); return; }
  const c = compile();
  const args = ctorArgs(s);
  const f = new ethers.ContractFactory(c.abi, c.bin, w);
  console.log('deployer', w.address, 'balance', ethers.formatEther(await w.provider.getBalance(w.address)), 'ETH');
  const ct = await f.deploy(...args);
  const tx = ct.deploymentTransaction();
  console.log('tx', tx.hash);
  const rc = await tx.wait();
  const addr = await ct.getAddress();
  console.log('ArchitectOTC deployado en', addr, 'bloque', rc.blockNumber, 'gas', rc.gasUsed.toString());
  save({ otc: addr, otcTx: tx.hash, otcBlock: rc.blockNumber });
  try {
    const cfg = { address: addr, deployBlock: rc.blockNumber, feeBps: FEE_BPS };
    fs.writeFileSync(WEB_CFG, JSON.stringify(cfg) + '\n');
    console.log('web config escrito:', WEB_CFG);
  } catch (e) { console.log('web config NO escrito:', e.message); }
  await check();
}

async function check() {
  const provider = new ethers.JsonRpcProvider(RPC, CHAIN_ID, { staticNetwork: true });
  const s = readState();
  if (!s.otc) { console.log('otc no esta en el config'); return; }
  const c = new ethers.Contract(s.otc, JSON.parse(fs.readFileSync(path.join(OUT, NAME + '.abi.json'), 'utf8')), provider);
  const [owner, fee, flusher, paused, count, qU, qN, weth, burner] = await Promise.all([c.owner(), c.feeBps(), c.flusher(), c.paused(), c.count(), c.isQuote(s.USDG || s.usdg), c.isQuote(NLYRA), c.WETH(), c.BURNER()]);
  console.log('check ·', s.otc, '| owner', owner, '| feeBps', fee.toString(), '| flusher', flusher, '| paused', paused, '| count', count.toString(), '| USDG quote', qU, '| NLYRA quote', qN, '| WETH', weth, '| burner', burner);
}

async function verify() {
  const s = readState();
  if (!s.otc) { console.log('otc no esta en el config'); return; }
  const ADDR = s.otc;
  const BS = 'https://robinhoodchain.blockscout.com', SOURCIFY = 'https://sourcify.dev/server';
  const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36';
  const input = JSON.parse(fs.readFileSync(path.join(OUT, NAME + '.input.json'), 'utf8'));
  const v = require('solc').version();
  const compilerVersion = v.split('.Emscripten')[0];
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  console.log('compiler', compilerVersion, '· evm', input.settings.evmVersion, '· runs', input.settings.optimizer.runs, '· viaIR', !!input.settings.viaIR);
  let st = await (await fetch(`${SOURCIFY}/v2/contract/${CHAIN_ID}/${ADDR}`)).json().catch(() => ({}));
  console.log('sourcify antes:', st.match || 'none');
  if (!st.match) {
    const r = await fetch(`${SOURCIFY}/v2/verify/${CHAIN_ID}/${ADDR}`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ stdJsonInput: input, compilerVersion, contractIdentifier: `${FILE}:${NAME}` }) });
    const t = await r.text();
    console.log('sourcify submit HTTP', r.status, t.slice(0, 160));
    if (r.ok) {
      const id = JSON.parse(t).verificationId;
      for (let i = 0; i < 20; i++) { await sleep(4000); const j = await (await fetch(`${SOURCIFY}/v2/verify/${id}`)).json(); if (j.isJobCompleted) { console.log('sourcify job:', j.error ? 'ERROR ' + JSON.stringify(j.error).slice(0, 200) : 'done'); break; } }
    }
    st = await (await fetch(`${SOURCIFY}/v2/contract/${CHAIN_ID}/${ADDR}`)).json().catch(() => ({}));
    console.log('sourcify ahora:', st.match || 'none');
  }
  try {
    const form = new FormData();
    form.append('compiler_version', compilerVersion); form.append('license_type', 'mit'); form.append('contract_name', NAME); form.append('autodetect_constructor_args', 'true');
    form.append('files[0]', new Blob([JSON.stringify(input)], { type: 'application/json' }), 'standard-input.json');
    const rb = await fetch(`${BS}/api/v2/smart-contracts/${ADDR}/verification/via/standard-input`, { method: 'POST', body: form, headers: { 'user-agent': UA } });
    const tb = await rb.text().catch(() => '');
    console.log('blockscout submit HTTP', rb.status, tb.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').slice(0, 120));
  } catch (e) { console.log('blockscout: ', e.message); }
}

const cmd = process.argv[2];
({ compile: async () => compile(), estimate, deploy, verify, check }[cmd] || (async () => { console.log('uso: compile | estimate | deploy | verify | check'); }))()
  .catch((e) => { console.error('ERR', e.shortMessage || e.message); process.exit(1); });
