# Shadow (copy trading)

Mirrors the swaps of a chosen wallet from the follower's own escrow, with per-position stop-loss / take-profit.

| | |
|---|---|
| Address | [`0xE26dd0A09Cd7bA2F7d0a31e4B625E983B0B1B3D2`](https://robinhoodchain.blockscout.com/address/0xE26dd0A09Cd7bA2F7d0a31e4B625E983B0B1B3D2) |
| Network | Robinhood Chain (chainId 4663) |
| Status | live |
| Holds / moves user funds | holds |
| Blockscout | verified, full match |
| Sourcify | exact match ([repo](https://repo.sourcify.dev/4663/0xE26dd0A09Cd7bA2F7d0a31e4B625E983B0B1B3D2)) |
| Contract | `ArchitectShadow` in `ArchitectShadow.sol` |
| Compiler | `0.8.24+commit.e11b9ed9` |
| Optimizer | enabled, 200 runs |
| EVM version | cancun |
| viaIR | yes |
| Working source & tests | [`bots/contracts/ArchitectShadow.sol`](../../../bots/contracts/ArchitectShadow.sol) |

Verification status checked on 2026-09-28 through the Blockscout and Sourcify APIs.

`src/` is the exact source Blockscout holds for this address. `compiler.json` has the compiler settings and constructor arguments. `abi.json` is the verified ABI.

## Constructor arguments

| Name | Type | Value |
|---|---|---|
| `router` | `address` | `0x9d1eA9Abbb99D813b7acA7666285CDed7f833565` |
| `weth` | `address` | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
| `keeper` | `address` | `0x96D0B8008d1E38d45A1B9cFCCCC932629059246c` |
