# Spot Grid v1

First spot grid; grids opened before v3, same stop call.

| | |
|---|---|
| Address | [`0xC0A3cE7e18FeE382432a18F750756E296D44dD4b`](https://robinhoodchain.blockscout.com/address/0xC0A3cE7e18FeE382432a18F750756E296D44dD4b) |
| Network | Robinhood Chain (chainId 4663) |
| Status | retired |
| Holds / moves user funds | holds |
| Blockscout | verified, full match |
| Sourcify | exact match ([repo](https://repo.sourcify.dev/4663/0xC0A3cE7e18FeE382432a18F750756E296D44dD4b)) |
| Contract | `ArchitectSpotGrid` in `ArchitectSpotGrid.sol` |
| Compiler | `v0.8.24+commit.e11b9ed9` |
| Optimizer | enabled, 200 runs |
| EVM version | cancun |
| viaIR | yes |

Verification status checked on 2026-09-28 through the Blockscout and Sourcify APIs.

`src/` is the exact source Blockscout holds for this address. `compiler.json` has the compiler settings and constructor arguments. `abi.json` is the verified ABI.

## Constructor arguments

| Name | Type | Value |
|---|---|---|
| `router` | `address` | `0x9d1eA9Abbb99D813b7acA7666285CDed7f833565` |
| `weth` | `address` | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
| `keeper` | `address` | `0x96D0B8008d1E38d45A1B9cFCCCC932629059246c` |
