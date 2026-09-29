# SendTo v1

First deploy; disabled on the router (it bound the router referral to the contract on the ETH paths).

| | |
|---|---|
| Address | [`0xb7F767fE61138026B6D430FC2D2381364cbe3596`](https://robinhoodchain.blockscout.com/address/0xb7F767fE61138026B6D430FC2D2381364cbe3596) |
| Network | Robinhood Chain (chainId 4663) |
| Status | retired |
| Holds / moves user funds | moves (does not keep balances) |
| Blockscout | verified, full match |
| Sourcify | exact match ([repo](https://repo.sourcify.dev/4663/0xb7F767fE61138026B6D430FC2D2381364cbe3596)) |
| Contract | `ArchitectSendTo` in `ArchitectSendTo.sol` |
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
