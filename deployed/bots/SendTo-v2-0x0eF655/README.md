# SendTo v2

Router wrapper: buy or sell from one wallet and deliver the output to another. Holds nothing between transactions.

| | |
|---|---|
| Address | [`0x0eF655f16345afb66b42d4e65B71a16052d1Ddc0`](https://robinhoodchain.blockscout.com/address/0x0eF655f16345afb66b42d4e65B71a16052d1Ddc0) |
| Network | Robinhood Chain (chainId 4663) |
| Status | live |
| Holds / moves user funds | moves (does not keep balances) |
| Blockscout | verified, full match |
| Sourcify | exact match ([repo](https://repo.sourcify.dev/4663/0x0eF655f16345afb66b42d4e65B71a16052d1Ddc0)) |
| Contract | `ArchitectSendTo` in `ArchitectSendTo.sol` |
| Compiler | `v0.8.24+commit.e11b9ed9` |
| Optimizer | enabled, 200 runs |
| EVM version | cancun |
| viaIR | yes |
| Working source & tests | [`bots/contracts/ArchitectSendTo.sol`](../../../bots/contracts/ArchitectSendTo.sol) |

Verification status checked on 2026-09-28 through the Blockscout and Sourcify APIs.

`src/` is the exact source Blockscout holds for this address. `compiler.json` has the compiler settings and constructor arguments. `abi.json` is the verified ABI.

## Constructor arguments

| Name | Type | Value |
|---|---|---|
| `router` | `address` | `0x9d1eA9Abbb99D813b7acA7666285CDed7f833565` |
