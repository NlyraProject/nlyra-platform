# Shield Pool (PrivacyPoolComplex)

Holds the shielded NLYRA; no owner withdraw; only zk proofs (or ragequit to the depositor) move funds.

| | |
|---|---|
| Address | [`0x6e179E19e594e82AB732646b898268F6Fb569E58`](https://robinhoodchain.blockscout.com/address/0x6e179E19e594e82AB732646b898268F6Fb569E58) |
| Network | Robinhood Chain (chainId 4663) |
| Status | live |
| Holds / moves user funds | holds |
| Blockscout | verified (partial match) |
| Sourcify | not verified |
| Contract | `PrivacyPoolComplex` in `core/packages/contracts/src/contracts/implementations/PrivacyPoolComplex.sol` |
| Compiler | `v0.8.28+commit.7893614a` |
| Optimizer | enabled, 10000 runs |
| EVM version | default |
| viaIR | yes |

Verification status checked on 2026-09-28 through the Blockscout and Sourcify APIs.

`src/` is the exact source Blockscout holds for this address. `compiler.json` has the compiler settings and constructor arguments. `abi.json` is the verified ABI.

## Constructor arguments

| Name | Type | Value |
|---|---|---|
| `_entrypoint` | `address` | `0x9c03515e1C7Aa04ADccCD1293bE4EA0Dd8f522F2` |
| `_withdrawalVerifier` | `address` | `0xe8868719Dc0aaCa1f7c8aef0dfe9304AF57cA1Cb` |
| `_ragequitVerifier` | `address` | `0xd1E125953bE2eEe7e59cAEF4789949e70402BEF4` |
| `_asset` | `address` | `0xB9d3824149aD8ac984153CeEc91D5a2405d1FB95` |
