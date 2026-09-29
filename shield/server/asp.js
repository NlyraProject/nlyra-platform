// LYRA SHIELD: Association Set Provider (reference implementation).
//
// The ASP publishes the set of deposits that may withdraw privately. This is
// what separates "honest privacy" from a blind mixer. Policy: every deposit is
// included except those whose depositor appears on a blocklist (rug pullers,
// scam deployers, hack wallets). The blocklist source is pluggable (see
// "Blocklist provider" below); with no provider configured, every deposit is
// included.
//
// If the ASP does not include a deposit, its funds are NOT lost: the pool has
// ragequit (withdraw to the original wallet, without privacy and without any
// custodian).
const { ethers } = require('ethers');

const RPC = process.env.RH_RPC || 'https://rpc.mainnet.chain.robinhood.com';
const POOL_ABI = [
  'event Deposited(address indexed _depositor, uint256 _commitment, uint256 _label, uint256 _value, uint256 _merkleRoot)',
];
const EP_ABI = [
  'function updateRoot(uint256 _root, string _ipfsCID) returns (uint256)',
  'function latestRoot() view returns (uint256)',
];

// LeanIMT with Poseidon (the same tree the circuit uses)
let poseidonP = null;
async function poseidon2() {
  if (!poseidonP) poseidonP = require('circomlibjs').buildPoseidon();
  const p = await poseidonP;
  return (a, b) => BigInt(p.F.toString(p([a, b])));
}

// LeanIMT: incremental tree where a node is hashed only if it has a sibling.
async function leanIMTRoot(leaves) {
  if (!leaves.length) return 0n;
  const h = await poseidon2();
  let level = leaves.map(BigInt);
  while (level.length > 1) {
    const next = [];
    for (let i = 0; i < level.length; i += 2) {
      next.push(i + 1 < level.length ? h(level[i], level[i + 1]) : level[i]);
    }
    level = next;
  }
  return level[0];
}

function cfg() {
  return {
    pool: process.env.SHIELD_POOL || '',
    entrypoint: process.env.SHIELD_ENTRYPOINT || '',
    key: process.env.SHIELD_ASP_KEY || process.env.SHIELD_RELAYER_KEY || '',
    blocklistFile: process.env.SHIELD_ASP_BLOCKLIST || '',
  };
}

// ── Blocklist provider ──
// A blocklist provider is an async function that returns an array of addresses
// (strings) whose deposits must be left out of the association set. Operators
// plug in their own source in one of two ways:
//   1. setBlocklistProvider(async () => ['0xabc...', ...]) from the host process;
//   2. SHIELD_ASP_BLOCKLIST=/path/to/blocklist.json, a JSON array of addresses
//      (or of objects with an `address` field).
// With neither configured the set is inclusive: every deposit is included.
let blocklistProvider = null;
function setBlocklistProvider(fn) {
  if (fn !== null && typeof fn !== 'function') throw new TypeError('blocklist provider must be a function or null');
  blocklistProvider = fn;
}

async function loadBlocklist() {
  const out = new Set();
  const add = (list) => {
    for (const x of Array.isArray(list) ? list : []) {
      const a = (typeof x === 'string' ? x : (x && x.address) || '').toLowerCase();
      if (a) out.add(a);
    }
  };
  if (blocklistProvider) {
    try { add(await blocklistProvider()); } catch (_) { /* provider failed: stay inclusive */ }
  }
  const file = cfg().blocklistFile;
  if (file) {
    try { add(JSON.parse(require('fs').readFileSync(file, 'utf8'))); } catch (_) { /* unreadable file: stay inclusive */ }
  }
  return out;
}

// Collects every deposit in the pool and drops those from blocklisted wallets.
async function buildSet() {
  const c = cfg();
  if (!c.pool) return { labels: [], excluded: [], root: 0n };
  const p = new ethers.JsonRpcProvider(RPC);
  const pool = new ethers.Contract(c.pool, POOL_ABI, p);
  const head = await p.getBlockNumber();

  // scan in chunks (the RPC limits the block range per query)
  const CHUNK = 45000;
  const from = Math.max(0, head - CHUNK * 12);
  let evs = [];
  for (let b = from; b <= head; b += CHUNK) {
    const to = Math.min(b + CHUNK - 1, head);
    const part = await pool.queryFilter(pool.filters.Deposited(), b, to).catch(() => []);
    evs = evs.concat(part);
  }

  const flagged = await loadBlocklist();

  const labels = [];
  const excluded = [];
  for (const e of evs) {
    const depositor = (e.args._depositor || '').toLowerCase();
    if (flagged.has(depositor)) { excluded.push({ label: e.args._label.toString(), depositor }); continue; }
    labels.push(e.args._label);
  }
  const root = await leanIMTRoot(labels);
  return { labels: labels.map(String), excluded, root, deposits: evs.length };
}

// Publishes the root on-chain (requires the ASP_POSTMAN role).
async function publishRoot() {
  const c = cfg();
  const { labels, root, excluded } = await buildSet();
  if (!labels.length) return { skipped: 'no deposits yet' };
  const p = new ethers.JsonRpcProvider(RPC);
  const w = new ethers.Wallet(c.key, p);
  const ep = new ethers.Contract(c.entrypoint, EP_ABI, w);
  const current = await ep.latestRoot().catch(() => 0n);
  if (current === root) return { unchanged: true, root: root.toString(), labels: labels.length };
  const fee = ((await p.getFeeData()).gasPrice * 3n) / 2n;
  // the contract requires the CID to be 32-64 characters long
  const cid = ('QmLyraShieldASP' + Date.now().toString(36) + '0'.repeat(48)).slice(0, 46);
  const tx = await ep.updateRoot(root, cid, { gasPrice: fee });
  await tx.wait();
  console.log(`[shield-asp] root published: ${labels.length} deposits included, ${excluded.length} excluded, tx ${tx.hash}`);
  return { published: true, root: root.toString(), labels: labels.length, excluded: excluded.length, tx: tx.hash };
}

module.exports = { buildSet, publishRoot, leanIMTRoot, setBlocklistProvider, loadBlocklist };
