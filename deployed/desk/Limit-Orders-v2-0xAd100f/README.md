# Limit Orders v2

Gasless limit orders signed as a Permit2 witness; nothing is escrowed, a keeper fills when the price is met.

| | |
|---|---|
| Address | [`0xAd100f712FA482938adCe1dc08B3B30C8834cBBb`](https://robinhoodchain.blockscout.com/address/0xAd100f712FA482938adCe1dc08B3B30C8834cBBb) |
| Network | Robinhood Chain (chainId 4663) |
| Status | live |
| Holds / moves user funds | moves (does not keep balances) |
| Blockscout | verified, full match |
| Sourcify | exact match ([repo](https://repo.sourcify.dev/4663/0xAd100f712FA482938adCe1dc08B3B30C8834cBBb)) |
| Contract | `ArchitectLimitOrders` in `ArchitectLimitOrders.sol` |
| Compiler | `v0.8.24+commit.e11b9ed9` |
| Optimizer | enabled, 200 runs |
| EVM version | cancun |
| viaIR | yes |

Verification status checked on 2026-09-28 through the Blockscout and Sourcify APIs.

`src/` is the exact source Blockscout holds for this address. `compiler.json` has the compiler settings and constructor arguments. `abi.json` is the verified ABI.

## Constructor arguments

| Name | Type | Value |
|---|---|---|
| `permit2` | `address` | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| `router` | `address` | `0x9d1eA9Abbb99D813b7acA7666285CDed7f833565` |
