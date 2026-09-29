// LYRA SHIELD — deploy del stack Privacy Pools para $NLYRA en Robinhood Chain.
// Secuencia idéntica a BaseDeploy.s.sol de 0xbow (sin CreateX: deploy normal).
//   1. WithdrawalVerifier (Groth16)   2. CommitmentVerifier (ragequit)
//   3. Entrypoint impl + ERC1967Proxy(initialize(owner, postman))
//   4. PrivacyPoolComplex(entrypoint, wVerifier, rVerifier, NLYRA)
//   5. entrypoint.registerPool(...)
// USO: DEPLOYER_KEY=0x... node deploy-shield.js            (dry-run)
//      DEPLOYER_KEY=0x... node deploy-shield.js --send
const { ethers } = require('ethers');
const fs = require('fs');

const RPC = 'https://rpc.mainnet.chain.robinhood.com';
const NLYRA = '0xb9d3824149ad8ac984153ceec91d5a2405d1fb95';
// v1 conservador: depósitos chicos para probar con plata real sin exponer nada
const MIN_DEPOSIT = ethers.parseEther(process.env.MIN_DEPOSIT || '100000'); // 100k NLYRA
const VETTING_FEE_BPS = 100n; // 1% — financia el ASP
const MAX_RELAY_FEE_BPS = 100n; // 1% tope que puede cobrar un relayer

const art = (n) => JSON.parse(fs.readFileSync(require('path').join(process.env.SHIELD_ARTIFACTS || 'artifacts', n + '.json'), 'utf8'));

(async () => {
  const key = process.env.DEPLOYER_KEY;
  if (!key) { console.error('Falta DEPLOYER_KEY'); process.exit(1); }
  const send = process.argv.includes('--send');
  const p = new ethers.JsonRpcProvider(RPC);
  const w = new ethers.Wallet(key, p);
  const net = await p.getNetwork();
  if (net.chainId !== 4663n) { console.error('¡No es Robinhood Chain!'); process.exit(1); }
  const fee = ((await p.getFeeData()).gasPrice * 3n) / 2n;
  const owner = process.env.SHIELD_OWNER || w.address;   // admin del protocolo
  const postman = process.env.SHIELD_POSTMAN || w.address; // quien publica la raíz del ASP

  console.log('deployer:', w.address, '| ETH:', ethers.formatEther(await p.getBalance(w.address)));
  console.log('owner:', owner, '| postman (ASP):', postman);
  console.log('depósito mínimo:', ethers.formatEther(MIN_DEPOSIT), 'NLYRA | vetting 1% | relay cap 1%');
  if (!send) return console.log('\ndry-run OK — agregá --send para deployar.');

  // reemplaza los placeholders __$hash$__ por la dirección de la librería ya deployada
  const link = (bytecode, refs, libs) => {
    let bc = bytecode;
    for (const [file, names] of Object.entries(refs || {})) {
      for (const [libName, spots] of Object.entries(names)) {
        const addr = libs[libName];
        if (!addr) throw new Error('falta la librería ' + libName);
        for (const s of spots) {
          const start = 2 + s.start * 2, end = start + s.length * 2;
          bc = bc.slice(0, start) + addr.toLowerCase().replace('0x', '') + bc.slice(end);
        }
      }
    }
    return bc;
  };

  const libs = {};
  const deploy = async (name, args = []) => {
    const a = art(name);
    const bc = link(a.bytecode, a.linkReferences, libs);
    const c = await new ethers.ContractFactory(a.abi, bc, w).deploy(...args, { gasPrice: fee });
    await c.waitForDeployment();
    const addr = await c.getAddress();
    console.log('   ' + name + ':', addr);
    return addr;
  };

  console.log('\n0/5 librerías Poseidon (hasher del árbol de Merkle)…');
  libs.PoseidonT3 = process.env.POSEIDON_T3 || (await deploy('PoseidonT3'));
  libs.PoseidonT4 = process.env.POSEIDON_T4 || (await deploy('PoseidonT4'));

  console.log('1/5 verificadores Groth16…');
  const wVer = await deploy('WithdrawalVerifier');
  const rVer = await deploy('CommitmentVerifier');

  console.log('2/5 Entrypoint (implementación)…');
  const impl = await deploy('Entrypoint');

  console.log('3/5 proxy ERC1967 + initialize…');
  const iface = new ethers.Interface(art('Entrypoint').abi);
  const initData = iface.encodeFunctionData('initialize', [owner, postman]);
  const entrypoint = await deploy('ERC1967Proxy', [impl, initData]);

  console.log('4/5 PrivacyPoolComplex para $NLYRA…');
  const pool = await deploy('PrivacyPoolComplex', [entrypoint, wVer, rVer, NLYRA]);

  console.log('5/5 registrando el pool en el Entrypoint…');
  const ep = new ethers.Contract(entrypoint, art('Entrypoint').abi, w);
  const tx = await ep.registerPool(NLYRA, pool, MIN_DEPOSIT, VETTING_FEE_BPS, MAX_RELAY_FEE_BPS, { gasPrice: fee });
  await tx.wait();
  console.log('   registrado ✅');

  const outFile = {
    chainId: 4663, deployer: w.address, owner, postman,
    poseidonT3: libs.PoseidonT3, poseidonT4: libs.PoseidonT4,
    withdrawalVerifier: wVer, ragequitVerifier: rVer,
    entrypointImpl: impl, entrypoint, pool, asset: NLYRA,
    minDeposit: MIN_DEPOSIT.toString(), vettingFeeBPS: 100, maxRelayFeeBPS: 100,
    at: new Date().toISOString(),
  };
  fs.writeFileSync(require('path').join(__dirname, '..', 'DEPLOYED_SHIELD.json'), JSON.stringify(outFile, null, 1));
  console.log('\nguardado en DEPLOYED_SHIELD.json');
  console.log('Siguiente: publicar la primera raíz del ASP (updateRoot) y probar depósito+retiro.');
})().catch((e) => { console.log('FALLO:', e.shortMessage || String(e.message).slice(0, 200)); process.exit(1); });
