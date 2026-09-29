# Infinity Grid v4 (compound)

Infinity grid (no ceiling) where every realized gain grows the position; per-bot gas reserve.

| | |
|---|---|
| Address | [`0xBdC77e3D589D161489f7C986d8f654F30b88DDeb`](https://robinhoodchain.blockscout.com/address/0xBdC77e3D589D161489f7C986d8f654F30b88DDeb) |
| Network | Robinhood Chain (chainId 4663) |
| Status | live |
| Holds / moves user funds | holds |
| Blockscout | verified, full match |
| Sourcify | exact match ([repo](https://repo.sourcify.dev/4663/0xBdC77e3D589D161489f7C986d8f654F30b88DDeb)) |
| Contract | `ArchitectInfinityGridV4` in `ArchitectInfinityGridV4.sol` |
| Compiler | `0.8.24+commit.e11b9ed9` |
| Optimizer | enabled, 200 runs |
| EVM version | cancun |
| viaIR | yes |
| Working source & tests | [`bots/contracts/ArchitectInfinityGridV4.sol`](../../../bots/contracts/ArchitectInfinityGridV4.sol) |

Verification status checked on 2026-09-28 through the Blockscout and Sourcify APIs.

`src/` is the exact source Blockscout holds for this address. `compiler.json` has the compiler settings and constructor arguments. `abi.json` is the verified ABI.

## Constructor arguments

| Name | Type | Value |
|---|---|---|
| `router` | `address` | `0x9d1eA9Abbb99D813b7acA7666285CDed7f833565` |
| `weth` | `address` | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
| `keeper` | `address` | `0x96D0B8008d1E38d45A1B9cFCCCC932629059246c` |
