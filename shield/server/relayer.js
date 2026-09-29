// LYRA SHIELD — relayer de retiros privados.
//
// Por qué existe: si el que retira paga su propio gas, necesita ETH en la wallet
// nueva… y ese ETH vino de algún lado que lo delata. El relayer paga el gas por
// él. Desde 2026-07-31 NO cobra fee en NLYRA: se financia con el prepago de ETH
// que cada depositante manda al depositar (regla del Arquitecto: no pegarle a
// $LYRA). Además, tras cada retiro le manda un poco de ETH a la wallet receptora
// para que la wallet fresca nazca operativa sin fondearse desde ningún lado.
// Eso no agrega vínculo nuevo: el retiro pool→receptor ya es público on-chain.
//
// Por qué NO hay que confiar en el relayer: el destinatario y el fee están
// DENTRO del contexto firmado por la prueba zk. Si el relayer cambia una coma,
// el contrato rechaza la transacción. Solo puede enviarla o no enviarla.
//
// El relayer NUNCA ve: la nota, el depósito de origen, ni quién es el usuario.
// Solo recibe una prueba matemática ya armada y la publica.
const { ethers } = require('ethers');

const RPC = 'https://rpc.mainnet.chain.robinhood.com';
const ENTRYPOINT_ABI = [
  'function relay((address processooor, bytes data) _withdrawal, (uint256[2] pA, uint256[2][2] pB, uint256[2] pC, uint256[8] pubSignals) _proof, uint256 _scope)',
  'function latestRoot() view returns (uint256)',
  // errores del pool y del entrypoint: sin esto ethers dice "unknown custom
  // error" y el usuario no sabe qué corregir
  'error InvalidProof()', 'error ContextMismatch()', 'error UnknownStateRoot()',
  'error IncorrectASPRoot()', 'error InvalidTreeDepth()', 'error InvalidProcessooor()',
  'error NullifierAlreadySpent()', 'error PoolNotFound()', 'error InvalidWithdrawalAmount()',
  'error RelayFeeGreaterThanMax()', 'error InvalidPoolState()', 'error PoolIsDead()',
  'error NoRootsAvailable()', 'error ScopeMismatch()',
];

// traducción a algo que un humano pueda accionar
const EXPLAIN = {
  IncorrectASPRoot: 'the association set was updated a moment ago — reload the page and try again',
  UnknownStateRoot: 'the pool state moved (someone deposited or withdrew) — reload the page and try again',
  ContextMismatch: 'recipient/fee data does not match the proof — rebuild the proof',
  InvalidProof: 'the zero-knowledge proof was rejected — check you pasted the right note',
  NullifierAlreadySpent: 'this note was already withdrawn',
  InvalidProcessooor: 'wrong processooor for a relayed withdrawal',
};

// límites anti-abuso: nadie nos drena el gas
const MAX_PER_HOUR_PER_IP = 5;
const MAX_PER_DAY_GLOBAL = 200;
const hits = new Map(); // ip -> timestamps
let dayCount = { day: '', n: 0 };

function cfg() {
  return {
    entrypoint: process.env.SHIELD_ENTRYPOINT || '',
    pool: process.env.SHIELD_POOL || '',
    scope: process.env.SHIELD_SCOPE || '',
    key: process.env.SHIELD_RELAYER_KEY || '',
    feeBps: Number(process.env.SHIELD_RELAY_FEE_BPS || 0),
    // ETH que se le regala a la wallet receptora tras un retiro exitoso
    dustEth: process.env.SHIELD_RECIPIENT_DUST_ETH || '0.0001',
    // ETH que el frontend pide al depositar para bancar el gas de los retiros
    prepayEth: process.env.SHIELD_GAS_PREPAY_ETH || '0.0003',
  };
}

function isEnabled() {
  const c = cfg();
  return !!(c.entrypoint && c.scope && c.key);
}

function rateOk(ip) {
  const now = Date.now();
  const day = new Date().toISOString().slice(0, 10);
  if (dayCount.day !== day) dayCount = { day, n: 0 };
  if (dayCount.n >= MAX_PER_DAY_GLOBAL) return 'daily limit reached, try tomorrow';
  const arr = (hits.get(ip) || []).filter((t) => now - t < 3600_000);
  if (arr.length >= MAX_PER_HOUR_PER_IP) return 'hourly limit reached for this IP';
  arr.push(now);
  hits.set(ip, arr);
  dayCount.n++;
  return null;
}

// Convierte lo que manda el browser (strings decimales) a BigInt validando forma.
function parseProof(body) {
  const bn = (v) => {
    const s = String(v);
    if (!/^\d+$/.test(s)) throw new Error('invalid field element');
    return BigInt(s);
  };
  const { withdrawal, proof, scope } = body;
  if (!withdrawal || !proof) throw new Error('missing withdrawal or proof');
  if (!ethers.isAddress(withdrawal.processooor)) throw new Error('bad processooor');
  if (typeof withdrawal.data !== 'string' || !/^0x[0-9a-fA-F]*$/.test(withdrawal.data)) throw new Error('bad data');
  const pA = proof.pA.map(bn);
  const pB = proof.pB.map((r) => r.map(bn));
  const pC = proof.pC.map(bn);
  const pub = proof.pubSignals.map(bn);
  if (pA.length !== 2 || pB.length !== 2 || pC.length !== 2 || pub.length !== 8) throw new Error('bad proof shape');
  return { withdrawal: [withdrawal.processooor, withdrawal.data], proof: [pA, pB, pC, pub], scope: bn(scope) };
}

// ── AUTOSUSTENTO ──────────────────────────────────────────────────
// Ingreso principal: los prepagos de ETH que llegan al depositar. Fallback:
// si igual se queda sin ETH y todavía tiene NLYRA de la era con fees, lo
// convierte. Si no puede relayar, los fondos de nadie quedan atrapados:
// siempre se puede retirar directo pagando gas propio, o hacer ragequit —
// pero se pierde la privacidad.
const NLYRA = '0xb9d3824149ad8ac984153ceec91d5a2405d1fb95';
const WETH = '0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73';
const UNI_ROUTER = '0xcaf681a66d020601342297493863e78c959e5cb2'; // SwapRouter02 (pool profundo)
const MIN_GAS = ethers.parseEther('0.0015');    // por debajo de esto, recargar
const TARGET_SWAP = ethers.parseEther('200000'); // NLYRA a convertir por recarga
const R02_ABI = [
  'function exactInputSingle((address,address,uint24,address,uint256,uint256,uint160)) payable returns (uint256)',
  'function unwrapWETH9(uint256,address) payable',
  'function multicall(bytes[]) payable returns (bytes[])',
];
let lastRefill = 0;

async function ensureGas(p, w) {
  const bal = await p.getBalance(w.address);
  if (bal >= MIN_GAS) return { ok: true, bal };
  if (Date.now() - lastRefill < 3600_000) return { ok: false, bal, why: 'refill cooling down' };
  try {
    const tok = new ethers.Contract(NLYRA, [
      'function balanceOf(address) view returns (uint256)',
      'function allowance(address,address) view returns (uint256)',
      'function approve(address,uint256) returns (bool)',
    ], w);
    const held = await tok.balanceOf(w.address);
    if (held === 0n) return { ok: false, bal, why: 'no fees collected yet to convert' };
    const amount = held < TARGET_SWAP ? held : TARGET_SWAP;
    const fee = ((await p.getFeeData()).gasPrice * 3n) / 2n;
    if ((await tok.allowance(w.address, UNI_ROUTER)) < amount) {
      await (await tok.approve(UNI_ROUTER, ethers.MaxUint256, { gasPrice: fee })).wait();
    }
    const rt = new ethers.Contract(UNI_ROUTER, R02_ABI, w);
    const c1 = rt.interface.encodeFunctionData('exactInputSingle', [[NLYRA, WETH, 10000, UNI_ROUTER, amount, 0n, 0n]]);
    const c2 = rt.interface.encodeFunctionData('unwrapWETH9', [0n, w.address]);
    await (await rt.multicall([c1, c2], { gasPrice: fee, gasLimit: 900000 })).wait();
    lastRefill = Date.now();
    const after = await p.getBalance(w.address);
    console.log(`[shield] relayer se recargó solo: ${ethers.formatEther(amount)} NLYRA -> ${ethers.formatEther(after - bal)} ETH`);
    return { ok: after >= MIN_GAS / 2n, bal: after, refilled: true };
  } catch (e) {
    console.error('[shield] auto-recarga falló:', e.shortMessage || e.message);
    return { ok: false, bal, why: 'refill failed' };
  }
}

// El recipient viaja DENTRO de withdrawal.data (el mismo tuple que sella la
// prueba zk), así que mandarle ETH no revela nada que la chain no muestre ya.
async function sendRecipientDust(p, w, data, dustEth) {
  const amount = ethers.parseEther(String(dustEth || '0'));
  if (amount === 0n) return null;
  const [ctx] = ethers.AbiCoder.defaultAbiCoder().decode(
    ['tuple(address recipient, address feeRecipient, uint256 relayFeeBPS)'], data);
  const to = ctx.recipient;
  const [mine, theirs] = await Promise.all([p.getBalance(w.address), p.getBalance(to)]);
  if (theirs >= amount) return null;             // ya tiene gas: no regalar de más
  if (mine < amount + MIN_GAS) return null;      // primero sobrevive el relayer
  const gasPrice = ((await p.getFeeData()).gasPrice * 3n) / 2n;
  const tx = await w.sendTransaction({ to, value: amount, gasPrice, gasLimit: 30000 });
  await tx.wait();
  console.log(`[shield] dust de gas ${dustEth} ETH -> ${to.slice(0, 10)}… tx=${tx.hash}`);
  return tx.hash;
}

async function handleRelay(req, res, send) {
  const c = cfg();
  if (!isEnabled()) return send(res, 503, { error: 'relayer not configured' });
  const ip = (req.headers['x-forwarded-for'] || req.socket.remoteAddress || '?').split(',')[0].trim();

  let raw = '';
  let tooBig = false;
  req.on('data', (ch) => { raw += ch; if (raw.length > 200_000) { tooBig = true; req.destroy(); } });
  req.on('end', async () => {
    if (tooBig) return send(res, 413, { error: 'payload too large' });
    try {
      const limited = rateOk(ip);
      if (limited) return send(res, 429, { error: limited });

      const body = JSON.parse(raw);
      const { withdrawal, proof, scope } = parseProof(body);
      if (scope.toString() !== c.scope) return send(res, 400, { error: 'unknown pool scope' });
      if (withdrawal[0].toLowerCase() !== c.entrypoint.toLowerCase()) {
        return send(res, 400, { error: 'processooor must be the entrypoint for relayed withdrawals' });
      }

      const p = new ethers.JsonRpcProvider(RPC);
      const w = new ethers.Wallet(c.key, p);

      // ¿tiene con qué pagar el gas? si no, intenta convertir sus fees a ETH
      const gas = await ensureGas(p, w);
      if (!gas.ok) {
        console.error('[shield] relayer sin gas:', gas.why, ethers.formatEther(gas.bal));
        return send(res, 503, {
          error: 'the relayer is out of gas right now. Your funds are safe — you can withdraw directly from your own wallet (you pay the gas and lose privacy), or wait until the relayer is refilled.',
          code: 'RELAYER_OUT_OF_GAS',
        });
      }

      const ep = new ethers.Contract(c.entrypoint, ENTRYPOINT_ABI, w);

      // simulamos antes de gastar un centavo de gas
      try {
        await ep.relay.staticCall(withdrawal, proof, scope);
      } catch (e) {
        const name = e.revert?.name || null;
        const why = name ? (EXPLAIN[name] || name) : (e.shortMessage || 'proof rejected');
        console.error('[shield] retiro rechazado:', name || e.shortMessage);
        return send(res, 400, { error: why, code: name });
      }

      const fee = ((await p.getFeeData()).gasPrice * 3n) / 2n;
      const tx = await ep.relay(withdrawal, proof, scope, { gasPrice: fee, gasLimit: 3_000_000 });
      const rc = await tx.wait();
      console.log(`[shield] retiro relayado ok tx=${rc.hash} gas=${rc.gasUsed}`);

      // La wallet receptora nace con un poco de ETH para operar: si tuviera que
      // fondearse desde otra wallet, ese fondeo la delataría. Solo si está seca
      // (si ya tiene gas, regalarle más es tirar el tanque del relayer).
      const dust = sendRecipientDust(p, w, withdrawal[1], c.dustEth)
        .catch((e) => { console.error('[shield] dust al receptor falló:', e.shortMessage || e.message); return null; });

      const dustTx = await dust;
      return send(res, 200, { ok: true, txHash: rc.hash, gasUsed: rc.gasUsed.toString(), gasDust: dustTx || undefined });
    } catch (e) {
      console.error('[shield] relay error:', e.message);
      return send(res, 400, { error: String(e.message).slice(0, 160) });
    }
  });
}

async function status() {
  const c = cfg();
  if (!isEnabled()) return { enabled: false };
  try {
    const p = new ethers.JsonRpcProvider(RPC);
    const w = new ethers.Wallet(c.key, p);
    const [gas, root] = await Promise.all([
      p.getBalance(w.address),
      new ethers.Contract(c.entrypoint, ENTRYPOINT_ABI, p).latestRoot().catch(() => 0n),
    ]);
    const perWithdrawal = 10300000000000n; // ~500k gas al precio actual
    return {
      enabled: true,
      relayer: w.address,
      gasBalance: ethers.formatEther(gas),
      withdrawalsLeft: Number(gas / perWithdrawal),
      lowGas: gas < ethers.parseEther('0.0015'),
      feeBps: c.feeBps,
      dustEth: c.dustEth,
      prepayEth: c.prepayEth,
      aspRootPublished: root !== 0n,
      entrypoint: c.entrypoint,
      pool: c.pool,
      scope: c.scope,
    };
  } catch (e) {
    return { enabled: true, error: e.message.slice(0, 100) };
  }
}

module.exports = { handleRelay, status, isEnabled };
