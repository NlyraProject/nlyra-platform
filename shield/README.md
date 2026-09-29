# Lyra Shield: private NLYRA transfers (Privacy Pools)

**Live at [nlyra.xyz/shield](https://nlyra.xyz/shield).** Lyra Shield runs the [0xbow Privacy Pools](https://github.com/0xbow-io/privacy-pools-core) protocol (Apache-2.0, audited by Oxorio and Auditware) for $NLYRA on Robinhood Chain. A user deposits a fixed denomination (100K / 500K / 1M NLYRA) and later withdraws to a fresh wallet with a zero-knowledge proof built entirely in the browser. The pool never learns which deposit a withdrawal comes from.

| Contract | Address | Role |
|---|---|---|
| Entrypoint (ERC1967 proxy) | [`0x9c03515e1C7Aa04ADccCD1293bE4EA0Dd8f522F2`](https://robinhoodchain.blockscout.com/address/0x9c03515e1C7Aa04ADccCD1293bE4EA0Dd8f522F2) | Deposits, association-set root, relayed withdrawals |
| Entrypoint implementation | [`0xda1e76Aeb6D7B78Fd6474912E4b6863eFa29D349`](https://robinhoodchain.blockscout.com/address/0xda1e76Aeb6D7B78Fd6474912E4b6863eFa29D349) | Logic behind the proxy |
| PrivacyPoolComplex | [`0x6e179E19e594e82AB732646b898268F6Fb569E58`](https://robinhoodchain.blockscout.com/address/0x6e179E19e594e82AB732646b898268F6Fb569E58) | **Holds the shielded NLYRA.** No owner withdraw; only proofs move funds |
| WithdrawalVerifier (Groth16) | [`0xe8868719Dc0aaCa1f7c8aef0dfe9304AF57cA1Cb`](https://robinhoodchain.blockscout.com/address/0xe8868719Dc0aaCa1f7c8aef0dfe9304AF57cA1Cb) | Verifies withdrawal proofs |
| CommitmentVerifier (Groth16) | [`0xd1E125953bE2eEe7e59cAEF4789949e70402BEF4`](https://robinhoodchain.blockscout.com/address/0xd1E125953bE2eEe7e59cAEF4789949e70402BEF4) | Verifies ragequit proofs |

All of them are verified on Blockscout. The verified sources, including the Poseidon libraries, are in [`../deployed/shield/`](../deployed/shield/).

## Guarantees

- **Ragequit always works.** Any depositor can recover their funds to the original wallet with only their secret note. No server, relayer or association-set provider is needed, and this path cannot be turned off.
- **The relayer cannot steal.** The recipient and the fee are sealed inside the proof context, so the relayer can only submit the transaction or refuse to.
- **Fees:** 0% in NLYRA. The relayer's gas is covered by small voluntary ETH prepays sent with deposits ([`scripts/set-fees-zero.js`](scripts/set-fees-zero.js) is the transaction that set the vetting fee to 0).
- **Admin surface:** the Entrypoint uses AccessControl. `OWNER_ROLE` can update the pool configuration, manage roles and upgrade the proxy; `ASP_POSTMAN` publishes the association-set root. See [`../CONTINUITY.md`](../CONTINUITY.md).

## Contents

| Path | What it is |
|---|---|
| [`frontend/shield.html`](frontend/shield.html) | Static page; builds the proofs in the browser |
| [`artifacts/`](artifacts/) | `withdraw.wasm` and `withdraw.zkey` from the trusted-setup ceremony. **Mirror these**: without the zkey no new proofs can be built |
| [`server/asp.js`](server/asp.js) | Reference association-set publisher (rebuilds the set from `Deposited` events and calls `updateRoot`) |
| [`server/relayer.js`](server/relayer.js) | Reference relayer (optional: users can always withdraw directly) |
| [`scripts/`](scripts/) | Deployment (same sequence as 0xbow's `BaseDeploy.s.sol`), fee configuration, proof generation and a direct withdrawal |
| [`DEPLOYED_SHIELD.json`](DEPLOYED_SHIELD.json) | Deployment record |

[`../CONTINUITY.md`](../CONTINUITY.md) explains how to run each off-chain role, the environment variables it needs, and the gotchas we hit.
