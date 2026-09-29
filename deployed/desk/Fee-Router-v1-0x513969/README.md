# Fee Router v1

First fee router, replaced by v2.

| | |
|---|---|
| Address | [`0x513969D81C0F7D490790274203221C1551663690`](https://robinhoodchain.blockscout.com/address/0x513969D81C0F7D490790274203221C1551663690) |
| Network | Robinhood Chain (chainId 4663) |
| Status | retired |
| Holds / moves user funds | moves (does not keep balances) |
| Blockscout | verified, full match |
| Sourcify | exact match ([repo](https://repo.sourcify.dev/4663/0x513969D81C0F7D490790274203221C1551663690)) |
| Contract | `ArchitectFeeRouter` in `ArchitectFeeRouter.sol` |
| Compiler | `v0.8.24+commit.e11b9ed9` |
| Optimizer | enabled, 200 runs |
| EVM version | cancun |
| viaIR | yes |

Verification status checked on 2026-09-28 through the Blockscout and Sourcify APIs.

`src/` is the exact source Blockscout holds for this address. `compiler.json` has the compiler settings and constructor arguments. `abi.json` is the verified ABI.

## Constructor arguments

| Name | Type | Value |
|---|---|---|
| `v3Factory` | `address` | `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA` |
| `v2Router` | `address` | `0x0000000000000000000000000000000000000000` |
| `v4PoolManager` | `address` | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| `treasury_` | `address` | `0x371bB2107f6E021EF2a5a980a9204F5a73151926` |
| `weth` | `address` | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
