// LYRA SHIELD — vetting fee a CERO (regla del Arquitecto: no pegarle a $NLYRA).
// El gas de los retiros se financia ahora con el prepago de ETH del depósito,
// no con un fee en tokens. maxRelayFeeBPS queda en 100 como techo por si algún
// día hay que volver a cobrar (el fee real lo fija el relayer y hoy es 0).
//
// USO: DEPLOYER_KEY=0x... node set-fees-zero.js            (dry-run: solo lee)
//      DEPLOYER_KEY=0x... node set-fees-zero.js --send     (ejecuta)
const { ethers } = require('ethers');

const RPC = 'https://rpc.mainnet.chain.robinhood.com';
const NLYRA = '0xb9d3824149ad8ac984153ceec91d5a2405d1fb95';
const ENTRYPOINT = '0x9c03515e1C7Aa04ADccCD1293bE4EA0Dd8f522F2';
const MIN_DEPOSIT = ethers.parseEther('100000'); // sin cambios
const VETTING_FEE_BPS = 0n;                      // ← el cambio
const MAX_RELAY_FEE_BPS = 100n;                  // techo, no el fee real

const ABI = [
  'function assetConfig(address) view returns (address pool, uint256 minimumDepositAmount, uint256 vettingFeeBPS)',
  'function updatePoolConfiguration(address _asset, uint256 _minimumDepositAmount, uint256 _vettingFeeBPS, uint256 _maxRelayFeeBPS)',
];

(async () => {
  const key = process.env.DEPLOYER_KEY;
  if (!key) { console.error('Falta DEPLOYER_KEY (la del owner 0x19e3…)'); process.exit(1); }
  const send = process.argv.includes('--send');
  const p = new ethers.JsonRpcProvider(RPC);
  const w = new ethers.Wallet(key, p);
  if ((await p.getNetwork()).chainId !== 4663n) { console.error('¡No es Robinhood Chain!'); process.exit(1); }

  const ep = new ethers.Contract(ENTRYPOINT, ABI, w);
  const before = await ep.assetConfig(NLYRA);
  console.log('firmante:', w.address, '| ETH:', ethers.formatEther(await p.getBalance(w.address)));
  console.log('ANTES  → vettingFeeBPS:', before.vettingFeeBPS.toString(), '| minDeposit:', ethers.formatEther(before.minimumDepositAmount));
  if (before.vettingFeeBPS === 0n) return console.log('Ya está en 0 — nada que hacer.');
  if (!send) {
    await ep.updatePoolConfiguration.staticCall(NLYRA, MIN_DEPOSIT, VETTING_FEE_BPS, MAX_RELAY_FEE_BPS);
    return console.log('dry-run OK (la simulación pasó) — agregá --send para ejecutar.');
  }
  const fee = ((await p.getFeeData()).gasPrice * 3n) / 2n;
  const tx = await ep.updatePoolConfiguration(NLYRA, MIN_DEPOSIT, VETTING_FEE_BPS, MAX_RELAY_FEE_BPS, { gasPrice: fee });
  console.log('tx:', tx.hash);
  await tx.wait();
  const after = await ep.assetConfig(NLYRA);
  console.log('DESPUÉS → vettingFeeBPS:', after.vettingFeeBPS.toString(), '✅ el shield ya no toca ni un token');
})().catch((e) => { console.error('FALLO:', e.shortMessage || String(e.message).slice(0, 200)); process.exit(1); });
