// Compila ArchitectOTC con la misma toolchain que los bots: solc 0.8.24 (npm), optimizer 200, evmVersion cancun (lock TSTORE).
//   node otc/compile-otc.js
const fs = require('fs'), path = require('path'), solc = require('solc');
const DIR = __dirname, OUT = path.join(DIR, 'artifacts');
fs.mkdirSync(OUT, { recursive: true });
const FILE = 'ArchitectOTC.sol', NAME = 'ArchitectOTC';
const input = {
  language: 'Solidity',
  sources: { [FILE]: { content: fs.readFileSync(path.join(DIR, FILE), 'utf8') } },
  settings: {
    optimizer: { enabled: true, runs: 200 }, evmVersion: 'cancun',
    outputSelection: { '*': { '*': ['abi', 'evm.bytecode.object', 'evm.deployedBytecode.object', 'metadata'] } },
  },
};
const out = JSON.parse(solc.compile(JSON.stringify(input)));
for (const e of (out.errors || [])) if (e.severity !== 'info') console.log('[' + e.severity + ']', e.formattedMessage.trim().split('\n')[0]);
const errs = (out.errors || []).filter((e) => e.severity === 'error');
if (errs.length) { console.error(errs.map((e) => e.formattedMessage).join('\n')); process.exit(1); }
const c = out.contracts[FILE][NAME];
fs.writeFileSync(path.join(OUT, NAME + '.abi.json'), JSON.stringify(c.abi, null, 1));
fs.writeFileSync(path.join(OUT, NAME + '.bin'), c.evm.bytecode.object);
fs.writeFileSync(path.join(OUT, NAME + '.deployed.bin'), c.evm.deployedBytecode.object);
fs.writeFileSync(path.join(OUT, NAME + '.input.json'), JSON.stringify(input, null, 1));
const size = c.evm.deployedBytecode.object.length / 2;
console.log('compilado', NAME, 'runtime', size, 'bytes', size > 24576 ? '*** OVER EIP-170 ***' : '(< 24576 ok)');
const has = (n) => c.abi.some((f) => f.type === 'function' && f.name === n);
let bad = size > 24576;
for (const n of ['create', 'fill', 'cancel', 'getOffers', 'flush', 'flushEth', 'claimEth', 'setFeeBps', 'setQuote', 'setFlusher', 'setPaused', 'rescue', 'offers', 'count', 'escrowed', 'accruedFee'])
  if (!has(n)) { console.error(NAME, 'falta', n); bad = true; }
for (const n of ['OfferCreated', 'OfferFilled', 'OfferCancelled', 'FeeToBurner', 'FeeBurned'])
  if (!c.abi.some((f) => f.type === 'event' && f.name === n)) { console.error(NAME, 'falta evento', n); bad = true; }
console.log('  payable:', JSON.stringify(c.abi.filter((f) => f.stateMutability === 'payable').map((f) => f.name || f.type)));
console.log('  sha256 .sol:', require('crypto').createHash('sha256').update(input.sources[FILE].content).digest('hex').slice(0, 16));
if (bad) process.exit(1);
console.log('solc', solc.version());
