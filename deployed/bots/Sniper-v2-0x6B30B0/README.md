# Sniper v2

Configurable launch sniper (Pons bonding curves and router pools) under the owner's own limits.

| | |
|---|---|
| Address | [`0x6B30B0946743eF8A2D323127c8CfaC9966b5C84c`](https://robinhoodchain.blockscout.com/address/0x6B30B0946743eF8A2D323127c8CfaC9966b5C84c) |
| Network | Robinhood Chain (chainId 4663) |
| Status | live |
| Holds / moves user funds | holds |
| Blockscout | verified, full match |
| Sourcify | exact match ([repo](https://repo.sourcify.dev/4663/0x6B30B0946743eF8A2D323127c8CfaC9966b5C84c)) |
| Contract | `ArchitectSniper` in `ArchitectSniper.sol` |
| Compiler | `v0.8.24+commit.e11b9ed9` |
| Optimizer | enabled, 1 runs |
| EVM version | cancun |
| viaIR | yes |
| Working source & tests | [`bots/contracts/ArchitectSniper.sol`](../../../bots/contracts/ArchitectSniper.sol) |

Verification status checked on 2026-09-28 through the Blockscout and Sourcify APIs.

`src/` is the exact source Blockscout holds for this address. `compiler.json` has the compiler settings and constructor arguments. `abi.json` is the verified ABI.

## Constructor arguments

| Name | Type | Value |
|---|---|---|
| `router` | `address` | `0x9d1eA9Abbb99D813b7acA7666285CDed7f833565` |
| `weth` | `address` | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
| `keeper` | `address` | `0x96D0B8008d1E38d45A1B9cFCCCC932629059246c` |
| `ponsFactory_` | `address` | `0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e` |
