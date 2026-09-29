# Limit Orders v1

First limit-order settlement contract, replaced by v2.

| | |
|---|---|
| Address | [`0xD2C409Dfa5e37C094166B9e556086bA018b2cd09`](https://robinhoodchain.blockscout.com/address/0xD2C409Dfa5e37C094166B9e556086bA018b2cd09) |
| Network | Robinhood Chain (chainId 4663) |
| Status | retired |
| Holds / moves user funds | moves (does not keep balances) |
| Blockscout | verified, full match |
| Sourcify | exact match ([repo](https://repo.sourcify.dev/4663/0xD2C409Dfa5e37C094166B9e556086bA018b2cd09)) |
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
| `router` | `address` | `0x513969D81C0F7D490790274203221C1551663690` |
