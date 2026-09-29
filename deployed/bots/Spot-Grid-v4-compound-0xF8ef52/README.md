# Spot Grid v4 (compound)

Spot grid with compounding and a per-bot gas reserve that pays the keeper for each fill.

| | |
|---|---|
| Address | [`0xF8ef52605FBcc968B24b7FdBD7e93c752A659D5f`](https://robinhoodchain.blockscout.com/address/0xF8ef52605FBcc968B24b7FdBD7e93c752A659D5f) |
| Network | Robinhood Chain (chainId 4663) |
| Status | live |
| Holds / moves user funds | holds |
| Blockscout | verified, full match |
| Sourcify | exact match ([repo](https://repo.sourcify.dev/4663/0xF8ef52605FBcc968B24b7FdBD7e93c752A659D5f)) |
| Contract | `ArchitectSpotGridV4` in `ArchitectSpotGridV4.sol` |
| Compiler | `v0.8.24+commit.e11b9ed9` |
| Optimizer | enabled, 200 runs |
| EVM version | cancun |
| viaIR | yes |
| Working source & tests | [`bots/contracts/ArchitectSpotGridV4.sol`](../../../bots/contracts/ArchitectSpotGridV4.sol) |

Verification status checked on 2026-09-28 through the Blockscout and Sourcify APIs.

`src/` is the exact source Blockscout holds for this address. `compiler.json` has the compiler settings and constructor arguments. `abi.json` is the verified ABI.

## Constructor arguments

| Name | Type | Value |
|---|---|---|
| `router` | `address` | `0x9d1eA9Abbb99D813b7acA7666285CDed7f833565` |
| `weth` | `address` | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
| `keeper` | `address` | `0x96D0B8008d1E38d45A1B9cFCCCC932629059246c` |
