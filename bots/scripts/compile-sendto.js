// Compila ArchitectSendTo con la MISMA toolchain que los deploys previos (solc 0.8.24, runs 200, viaIR, cancun).
const fs = require('fs'), path = require('path'), solc = require('solc');
const DIR = __dirname, OUT = path.join(DIR, 'artifacts');
fs.mkdirSync(OUT, { recursive: true });
const FILE = 'ArchitectSendTo.sol', NAME = 'ArchitectSendTo';
const read = (f) => fs.readFileSync(path.join(DIR, f), 'utf8');
const input = { language: 'Solidity', sources: { [FILE]: { content: read(FILE) } },
  settings: { optimizer: { enabled: true, runs: 200 }, viaIR: true, evmVersion: 'cancun', outputSelection: { '*': { '*': ['abi', 'evm.bytecode.object', 'evm.deployedBytecode.object', 'metadata'] } } } };
const out = JSON.parse(solc.compile(JSON.stringify(input)));
for (const e of (out.errors || [])) if (e.severity !== 'info') console.log('[' + e.severity + ']', e.formattedMessage.trim().split('\n').slice(0, 3).join(' | '));
const errs = (out.errors || []).filter((e) => e.severity === 'error');
if (errs.length) process.exit(1);
const c = out.contracts[FILE][NAME];
fs.writeFileSync(path.join(OUT, NAME + '.abi.json'), JSON.stringify(c.abi, null, 1));
fs.writeFileSync(path.join(OUT, NAME + '.bin'), c.evm.bytecode.object);
fs.writeFileSync(path.join(OUT, NAME + '.deployed.bin'), c.evm.deployedBytecode.object);
fs.writeFileSync(path.join(OUT, NAME + '.input.json'), JSON.stringify(input, null, 1));
const size = c.evm.deployedBytecode.object.length / 2;
console.log('compilado', NAME, 'runtime', size, 'bytes', size > 24576 ? '*** OVER EIP-170 ***' : '(< 24576 ok)');
const fns = c.abi.filter((f) => f.type === 'function').map((f) => f.name + '(' + f.inputs.map((i) => i.type).join(',') + ')' + (f.stateMutability === 'view' ? ' view' : f.stateMutability === 'payable' ? ' payable' : ''));
console.log('  funciones:', fns.join(' · '));
console.log('  eventos:', c.abi.filter((f) => f.type === 'event').map((f) => f.name).join(' '));
console.log('  errores:', c.abi.filter((f) => f.type === 'error').map((f) => f.name).join(' '));
console.log('  owner:', c.abi.find((f) => f.name === 'owner').outputs[0].type);
console.log('  sha256 .sol', require('crypto').createHash('sha256').update(read(FILE)).digest('hex').slice(0, 16), '· solc', solc.version());
