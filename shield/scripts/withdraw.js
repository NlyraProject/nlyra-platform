// RETIRO PRIVADO REAL — LYRA SHIELD.
// El contrato exige: msg.sender == processooor, context == keccak(abi.encode(withdrawal, SCOPE)) % FIELD,
// state root conocido, y ASP root == entrypoint.latestRoot().
// USO: DEPLOYER_KEY=0x... node withdraw.js [--send] [--to 0x...]
const { ethers } = require('ethers');
const fs = require('fs');
const sdk = require('@0xbow/privacy-pools-core-sdk');
const { proveWithdrawal } = require('./prove.js');

const D = JSON.parse(fs.readFileSync(process.env.SHIELD_DEPLOYED || require('path').join(__dirname, '..', 'DEPLOYED_SHIELD.json'), 'utf8'));
const NOTE = JSON.parse(fs.readFileSync(process.env.SHIELD_NOTE || 'NOTE.json', 'utf8'));
const RPC = 'https://rpc.mainnet.chain.robinhood.com';
const SNARK_FIELD = 21888242871839275222246405745257275088548364400416034343698204186575808495617n;
const POOL_ABI = JSON.parse(fs.readFileSync(require('path').join(process.env.SHIELD_ARTIFACTS || 'artifacts', 'PrivacyPoolComplex.json'), 'utf8')).abi;
const EP_ABI = JSON.parse(fs.readFileSync(require('path').join(process.env.SHIELD_ARTIFACTS || 'artifacts', 'Entrypoint.json'), 'utf8')).abi;

(async () => {
  const send = process.argv.includes('--send');
  const ti = process.argv.indexOf('--to');
  const p = new ethers.JsonRpcProvider(RPC);
  const w = new ethers.Wallet(process.env.DEPLOYER_KEY, p);
  const fee = ((await p.getFeeData()).gasPrice * 3n) / 2n;

  const pool = new ethers.Contract(D.pool, POOL_ABI, w);
  const ep = new ethers.Contract(D.entrypoint, EP_ABI, w);
  const scope = await pool.SCOPE();

  // el processooor DEBE ser quien manda la tx (lo exige el modifier)
  const processooor = w.address;
  const finalTo = ti > -1 ? process.argv[ti + 1] : w.address;
  console.log('pool:', D.pool);
  console.log('processooor (= quien firma):', processooor);
  if (finalTo !== w.address) console.log('destino final (transferencia posterior):', finalTo);

  // ── 1. raíz del ASP con nuestro label aprobado ──
  const label = BigInt(NOTE.label);
  const aspLeaves = [label];
  const aspProof = sdk.generateMerkleProof(aspLeaves, label);
  const aspRoot = BigInt(aspProof.root);
  // latestRoot() revierte con NoRootsAvailable() si nunca se publicó una
  const latest = await ep.latestRoot().catch(() => 0n);
  console.log('\n1/4 ASP root:', aspRoot.toString().slice(0, 22) + '… | publicada en el entrypoint:', latest.toString().slice(0, 22) + '…');
  if (latest !== aspRoot) {
    if (!send) console.log('   (falta publicarla — se hace con --send)');
    else {
      const tx = await ep.updateRoot(aspRoot, 'QmLyraShieldASPv1RobinhoodChainNLYRA000000000000', { gasPrice: fee });
      await tx.wait();
      console.log('   raíz del ASP publicada ✅', tx.hash);
    }
  } else console.log('   ya coincide ✅');

  // ── 2. contexto exacto que valida el contrato ──
  const withdrawal = { processooor, data: '0x' };
  const encoded = ethers.AbiCoder.defaultAbiCoder().encode(
    ['tuple(address processooor, bytes data)', 'uint256'], [withdrawal, scope]
  );
  const context = BigInt(ethers.keccak256(encoded)) % SNARK_FIELD;
  console.log('2/4 context:', context.toString().slice(0, 22) + '…');

  // ── 3. prueba zk ──
  console.log('3/4 generando la prueba zk (~2-4 min)…');
  const value = BigInt(NOTE.value);
  const newNullifier = (BigInt(NOTE.nullifier) ^ 987654321n) % SNARK_FIELD;
  const newSecret = (BigInt(NOTE.secret) ^ 123456789n) % SNARK_FIELD;
  const { proof, publicSignals } = await proveWithdrawal({
    note: NOTE,
    aspLeaves,
    stateLeaves: [BigInt(NOTE.commitment)],
    context,
    withdrawalAmount: value,
    newNullifier,
    newSecret,
  });
  console.log('   prueba lista ✅');

  const pA = [BigInt(proof.pi_a[0]), BigInt(proof.pi_a[1])];
  const pB = [[BigInt(proof.pi_b[0][1]), BigInt(proof.pi_b[0][0])], [BigInt(proof.pi_b[1][1]), BigInt(proof.pi_b[1][0])]];
  const pC = [BigInt(proof.pi_c[0]), BigInt(proof.pi_c[1])];
  const pub = publicSignals.map(BigInt);

  console.log('4/4 withdraw on-chain…');
  if (!send) return console.log('   dry-run — agregá --send.');
  const nlyra = new ethers.Contract(D.asset, ['function balanceOf(address) view returns (uint256)', 'function transfer(address,uint256) returns (bool)'], w);
  const before = await nlyra.balanceOf(processooor);
  const tx = await pool.withdraw([withdrawal.processooor, withdrawal.data], [pA, pB, pC, pub], { gasPrice: fee, gasLimit: 2_500_000 });
  const rc = await tx.wait();
  const got = (await nlyra.balanceOf(processooor)) - before;
  console.log('   tx:', rc.hash, '| gas:', rc.gasUsed.toString());
  console.log('   NLYRA RECUPERADOS:', ethers.formatEther(got), '✅');

  if (finalTo !== processooor && got > 0n) {
    const t = await nlyra.transfer(finalTo, got, { gasPrice: fee });
    await t.wait();
    console.log('   transferidos a', finalTo, '✅');
  }
})().catch((e) => { console.log('FALLO:', e.shortMessage || String(e.message).slice(0, 300)); process.exit(1); });
