# Predict Oracle

Price each Predict round settles on; a posted price more than 10% away from the on-chain anchor is rejected.

| | |
|---|---|
| Address | [`0xCC85d7B57819921f2D173134D0e21eca8A7B4F96`](https://robinhoodchain.blockscout.com/address/0xCC85d7B57819921f2D173134D0e21eca8A7B4F96) |
| Network | Robinhood Chain (chainId 4663) |
| Status | live |
| Holds / moves user funds | no |
| Blockscout | verified, full match |
| Sourcify | exact match ([repo](https://repo.sourcify.dev/4663/0xCC85d7B57819921f2D173134D0e21eca8A7B4F96)) |
| Contract | `PredictOracle` in `PredictOracle.sol` |
| Compiler | `v0.8.24+commit.e11b9ed9` |
| Optimizer | enabled, 200 runs |
| EVM version | cancun |
| viaIR | yes |

Verification status checked on 2026-09-28 through the Blockscout and Sourcify APIs.

`src/` is the exact source Blockscout holds for this address. `compiler.json` has the compiler settings and constructor arguments. `abi.json` is the verified ABI.

## Constructor arguments

| Name | Type | Value |
|---|---|---|
| `anchor_` | `address` | `0xa2c5184bF03d373Dc9dE4876eb4Bce595B460251` |
| `pusher` | `address` | `0x96D0B8008d1E38d45A1B9cFCCCC932629059246c` |
