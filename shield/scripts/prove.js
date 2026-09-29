// Generación de la prueba de retiro directo con snarkjs (padding a 32 siblings).
const fs = require('fs');
const sdk = require('@0xbow/privacy-pools-core-sdk');
const snarkjs = require('snarkjs');

const ART = process.env.PP_ARTIFACTS || require('path').join(require.resolve('@0xbow/privacy-pools-core-sdk'), '..', 'artifacts');
const pad32 = (a) => { const o = (a || []).map(BigInt); while (o.length < 32) o.push(0n); return o.slice(0, 32).map(String); };

async function proveWithdrawal({ note, aspLeaves, stateLeaves, context, withdrawalAmount, newNullifier, newSecret }) {
  const label = BigInt(note.label);
  const commitment = BigInt(note.commitment);
  const aspProof = sdk.generateMerkleProof(aspLeaves, label);
  const stateProof = sdk.generateMerkleProof(stateLeaves, commitment);

  const input = {
    withdrawnValue: String(withdrawalAmount),
    stateRoot: String(stateProof.root),
    stateTreeDepth: String(stateProof.siblings.length),
    ASPRoot: String(aspProof.root),
    ASPTreeDepth: String(aspProof.siblings.length),
    context: String(context),
    label: String(label),
    existingValue: String(note.value),
    existingNullifier: String(note.nullifier),
    existingSecret: String(note.secret),
    newNullifier: String(newNullifier),
    newSecret: String(newSecret),
    stateSiblings: pad32(stateProof.siblings),
    stateIndex: String(Number.isFinite(Number(stateProof.index)) ? stateProof.index : 0),
    ASPSiblings: pad32(aspProof.siblings),
    ASPIndex: String(Number.isFinite(Number(aspProof.index)) ? aspProof.index : 0),
  };

  const { proof, publicSignals } = await snarkjs.groth16.fullProve(
    input, ART + '/withdraw.wasm', ART + '/withdraw.zkey'
  );
  return { proof, publicSignals, input, stateProof, aspProof };
}

module.exports = { proveWithdrawal, pad32 };

if (require.main === module) {
  (async () => {
    const NOTE = JSON.parse(fs.readFileSync(process.env.SHIELD_NOTE || 'NOTE.json', 'utf8'));
    try {
      const r = await proveWithdrawal({
        note: NOTE,
        aspLeaves: [BigInt(NOTE.label)],
        stateLeaves: [BigInt(NOTE.commitment)],
        context: 123456789n,
        withdrawalAmount: BigInt(NOTE.value),
        newNullifier: 111222333n,
        newSecret: 444555666n,
      });
      console.log('PRUEBA OK ✅ señales públicas:', r.publicSignals.length);
      console.log(JSON.stringify(r.publicSignals, null, 1).slice(0, 300));
    } catch (e) {
      console.log('ERROR REAL:', String(e.message).slice(0, 400));
    }
  })();
}
