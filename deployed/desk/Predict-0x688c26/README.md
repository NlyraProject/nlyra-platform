# Predict

BTC up/down in 5-minute rounds; the pot is escrowed while a round is open, winners split it minus 3%, unresolvable rounds refund.

| | |
|---|---|
| Address | [`0x688c265886776005eaF321c7121bF2D1b76676A1`](https://robinhoodchain.blockscout.com/address/0x688c265886776005eaF321c7121bF2D1b76676A1) |
| Network | Robinhood Chain (chainId 4663) |
| Status | live |
| Holds / moves user funds | holds |
| Blockscout | verified, full match |
| Sourcify | exact match ([repo](https://repo.sourcify.dev/4663/0x688c265886776005eaF321c7121bF2D1b76676A1)) |
| Contract | `ArchitectPredict` in `ArchitectPredict.sol` |
| Compiler | `v0.8.24+commit.e11b9ed9` |
| Optimizer | enabled, 200 runs |
| EVM version | cancun |
| viaIR | yes |

Verification status checked on 2026-09-28 through the Blockscout and Sourcify APIs.

`src/` is the exact source Blockscout holds for this address. `compiler.json` has the compiler settings and constructor arguments. `abi.json` is the verified ABI.

## Constructor arguments

| Name | Type | Value |
|---|---|---|
| `oracle_` | `address` | `0xCC85d7B57819921f2D173134D0e21eca8A7B4F96` |
| `operator_` | `address` | `0x96D0B8008d1E38d45A1B9cFCCCC932629059246c` |
| `treasury_` | `address` | `0xe30647793192D15BFA6E53aE8651368d332fe04C` |
| `minBet` | `uint128` | `400000000000000` |
