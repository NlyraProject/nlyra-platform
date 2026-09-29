# CONTINUITY — how this survives without us

This document exists so that **anyone technical can keep every platform alive** if the
original operators disappear. It separates what runs forever by itself from what needs
a human (and shows exactly how to be that human).

Network: **Robinhood Chain** — chainId `4663`, RPC `https://rpc.mainnet.chain.robinhood.com`,
explorer `https://robinhoodchain.blockscout.com`.

---

## 1. What runs FOREVER with no operator

These are immutable contracts. Nobody can stop them, including us.

| Contract | Address |
|---|---|
| $NLYRA token | `0xb9d3824149ad8ac984153ceec91d5a2405d1fb95` |
| DEX Factory (Uniswap V2 verbatim) | `0xfa6253ee74F7956b022998F7bfa271990C8A82a8` |
| DEX Router | `0xA5deC66ECa62AE363dC47965bB790C3B8870b6B6` |
| WETH | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
| Launchpad factories + vaults + burner | see [`CONTRACTS.md`](CONTRACTS.md) → Launchpad |
| Shield PrivacyPool (holds funds) | `0x6e179E19e594e82AB732646b898268F6Fb569E58` |
| Shield WithdrawalVerifier (zk) | `0xe8868719Dc0aaCa1f7c8aef0dfe9304AF57cA1Cb` |
| Shield CommitmentVerifier (ragequit) | `0xd1E125953bE2eEe7e59cAEF4789949e70402BEF4` |

- **DEX**: swap/LP works through the router forever. Frontend in `dex/dex.html` is a single
  static file — host it anywhere, it only talks to the chain through the user's wallet.
- **Launchpad**: every launched pool's LP position is owned by a vault contract with no
  withdraw function — locked literally forever. The BuybackBurner can be triggered by
  **anyone** (public function, it market-buys $NLYRA and burns it).
- **Shield ragequit**: any depositor can ALWAYS recover their funds to their original
  wallet with only their secret note — no server, no relayer, no ASP required.
  This is the guaranteed exit and it can never be turned off.

## 2. The Shield — the one platform with off-chain parts

Entrypoint (user-facing proxy): `0x9c03515e1C7Aa04ADccCD1293bE4EA0Dd8f522F2`
(impl `0xda1e76Aeb6D7B78Fd6474912E4b6863eFa29D349`). All verified on Blockscout.

Three off-chain roles, in order of importance:

### a) ASP root publisher ("postman") — REQUIRED for private withdrawals
After every new deposit the association-set root must be re-published on-chain, or
withdrawals revert with `IncorrectASPRoot` (funds stay safe; ragequit still works).

- Reference implementation: `shield/server/asp.js` — builds the set from the pool's
  `Deposited` events and calls `updateRoot` on the Entrypoint.
- Requires a wallet with the `ASP_POSTMAN` role (granted by the OWNER via
  `grantRole(keccak256("ASP_POSTMAN"), <addr>)`) and a little ETH for gas
  (~$0.02 per update).
- Env: `SHIELD_ENTRYPOINT`, `SHIELD_POOL`, `SHIELD_ASP_KEY` (postman private key), and
  optionally `SHIELD_ASP_BLOCKLIST` (a JSON array of depositor addresses to leave out of
  the set; a host process can also plug in its own source with `setBlocklistProvider`).
  With no blocklist configured, every deposit is included.

### b) Relayer — OPTIONAL (privacy quality-of-life)
Pays withdrawal gas so the fresh recipient wallet never funds itself from a traceable
source, and sends the recipient a little ETH to operate. Without it users can still
withdraw directly from any wallet (they pay gas and lose some privacy).

- Reference implementation: `shield/server/relayer.js` (HTTP POST endpoint).
- It **cannot steal**: recipient and fee are sealed inside the zk proof context.
- Fees: 0% in $NLYRA. It runs on small voluntary ETH prepays sent by depositors.
- Env: `SHIELD_RELAYER_KEY`, `SHIELD_ENTRYPOINT`, `SHIELD_POOL`, `SHIELD_SCOPE`,
  `SHIELD_RELAY_FEE_BPS=0`, `SHIELD_RECIPIENT_DUST_ETH`, `SHIELD_GAS_PREPAY_ETH`.

### c) Frontend — static, host anywhere
`shield/frontend/shield.html` + the two artifacts in `shield/artifacts/`
(`withdraw.wasm`, `withdraw.zkey` — **irreplaceable**, they come from the trusted-setup
ceremony; without the zkey no new proofs can be built, so MIRROR THESE FILES).
The page builds zk proofs entirely in the browser. It expects:
- `"__SHIELD_CONFIG__"` replaced with `{entrypoint, pool, asset, feeRecipient, feeBps, prepayEth}`
- `/api/shield/state` returning `{commitments[], aspLabels[], ...}` (see `asp.js` +
  the pool's `LeafInserted` events — ordered by `_index`, they ARE the state tree)
- `/api/shield/relay` (the relayer) and `/shield/withdraw.{wasm,zkey}` served statically.

### Shield gotchas (learned the hard way — read before operating)
- The state tree source of truth is the `LeafInserted(_index,_leaf,_root)` event,
  NOT `Deposited` (withdrawals also insert leaves).
- Merkle proofs must use `@zk-kit/lean-imt` (`insertMany`/`indexOf`/`generateProof`) —
  hand-rolled LeanIMT gives wrong proof indexes.
- `context = keccak256(abi.encode(withdrawal, SCOPE)) % SNARK_FIELD`.
- `updateRoot`'s ipfsCID argument must be 32-64 chars.
- Denominations are fixed (100K/500K/1M) — that's what makes withdrawals uniform.

## 3. Admin keys and roles (the human part)

- Shield Entrypoint uses AccessControl: `OWNER_ROLE` can update pool config
  (`updatePoolConfiguration`), grant/revoke roles, and upgrade the proxy.
  Vetting fee is 0 and max relay fee 100 bps as of 2026-07-31.
- The launchpad factory and DEX have no meaningful admin powers over user funds
  (DEX fee switch only routes protocol fees).
- If you are inheriting this system: rotate every key you receive, grant yourself
  `ASP_POSTMAN`, and consider moving `OWNER_ROLE` to a multisig — or renouncing it
  once you're sure the config is final (warning: the Entrypoint proxy then becomes
  non-upgradeable forever).

## 4. Minimal takeover checklist

1. Clone this repo. `npm i ethers snarkjs` next to the scripts you need.
2. Host `shield/frontend/` + `shield/artifacts/` on any static host (IPFS/Arweave work).
3. Run `shield/server/asp.js` logic on a cron (or manually after each deposit).
4. (Optional) run `shield/server/relayer.js` behind any HTTP server with a funded wallet.
5. The DEX and launchpad frontends are single static HTML files — host and go.
