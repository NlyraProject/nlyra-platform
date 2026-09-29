// Compila ArchitectSpotGridV4 con la MISMA toolchain que los deploys previos:
// solc 0.8.24 (npm), optimizer runs 200, viaIR, evmVersion cancun (el lock usa TSTORE).
//   node v4/compile-v4.js
const fs = require('fs'), path = require('path'), solc = require('solc');
const DIR = __dirname, OUT = path.join(DIR, 'artifacts');
fs.mkdirSync(OUT, { recursive: true });
const FILE = 'ArchitectSpotGridV4.sol', NAME = 'ArchitectSpotGridV4';
const read = (f) => fs.readFileSync(path.join(DIR, f), 'utf8');
const input = {
  language: 'Solidity',
  sources: { [FILE]: { content: read(FILE) }, 'ArchitectBotBase.sol': { content: read('ArchitectBotBase.sol') } },
  settings: {
    optimizer: { enabled: true, runs: 200 }, viaIR: true, evmVersion: 'cancun',
    outputSelection: { '*': { '*': ['abi', 'evm.bytecode.object', 'evm.deployedBytecode.object', 'metadata'] } },
  },
};
const out = JSON.parse(solc.compile(JSON.stringify(input)));
let bad = false;
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
if (size > 24576) bad = true;
// lo que v4 TIENE que exponer, y lo que v3 ya exponia y no puede desaparecer
const has = (n) => c.abi.some((f) => f.type === 'function' && f.name === n);
for (const n of ['openWithEth', 'openWithBase', 'fillBuy', 'fillSell', 'stopLoss', 'takeProfit', 'stop', 'refundExpired', 'topUp',
  'setCompound', 'setGasOverhead', 'gasEscrowed', 'gasOverhead', 'nextBuyQuote', 'buyMinOut', 'sellMinOut', 'grid', 'levels', 'rescue', 'setKeeper'])
  if (!has(n)) { console.error(NAME, 'falta', n); bad = true; }
const ev = (n) => c.abi.some((f) => f.type === 'event' && f.name === n);
for (const n of ['GasPaid', 'GasAdded', 'GasRefunded', 'Reinvested', 'CompoundSet', 'GridFilled', 'GridOpened', 'GridStopped', 'ToppedUp'])
  if (!ev(n)) { console.error(NAME, 'falta evento', n); bad = true; }
const er = (n) => c.abi.some((f) => f.type === 'error' && f.name === n);
for (const n of ['NoGas', 'GasPayFailed']) if (!er(n)) { console.error(NAME, 'falta error', n); bad = true; }
// el struct Params tiene que tener compound al final y Grid tiene que exponer gasReserve/profitFree/compound
const gridOut = c.abi.find((f) => f.name === 'grid').outputs[0].components.map((x) => x.name);
for (const n of ['gasReserve', 'profitFree', 'compound', 'profit']) if (!gridOut.includes(n)) { console.error('Grid sin', n); bad = true; }
console.log('  Grid:', gridOut.join(' '));
console.log('  payable:', JSON.stringify(c.abi.filter((f) => f.stateMutability === 'payable').map((f) => f.name || f.type)));
if (bad) process.exit(1);
console.log('solc', solc.version());
