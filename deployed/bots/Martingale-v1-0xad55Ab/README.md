# Martingale v1

First martingale; still holds cycles opened before v2 (same withdraw).

| | |
|---|---|
| Address | [`0xad55Ab54B38F6eE5aB8408de627C0CE20aeF5Cef`](https://robinhoodchain.blockscout.com/address/0xad55Ab54B38F6eE5aB8408de627C0CE20aeF5Cef) |
| Network | Robinhood Chain (chainId 4663) |
| Status | retired |
| Holds / moves user funds | holds |
| Blockscout | verified, full match |
| Sourcify | exact match ([repo](https://repo.sourcify.dev/4663/0xad55Ab54B38F6eE5aB8408de627C0CE20aeF5Cef)) |
| Contract | `ArchitectMartingale` in `ArchitectMartingale.sol` |
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
