# Shield Entrypoint (proxy)

ERC1967 proxy users interact with: deposits, association-set root, relayed withdrawals.

| | |
|---|---|
| Address | [`0x9c03515e1C7Aa04ADccCD1293bE4EA0Dd8f522F2`](https://robinhoodchain.blockscout.com/address/0x9c03515e1C7Aa04ADccCD1293bE4EA0Dd8f522F2) |
| Network | Robinhood Chain (chainId 4663) |
| Status | live |
| Holds / moves user funds | moves (does not keep balances) |
| Blockscout | verified (partial match) |
| Sourcify | not verified |
| Contract | `ERC1967Proxy` in `lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol` |
| Compiler | `v0.8.26+commit.8a97fa7a` |
| Optimizer | enabled, 10000 runs |
| EVM version | cancun |
| viaIR | yes |

Verification status checked on 2026-09-28 through the Blockscout and Sourcify APIs.

`src/` is the exact source Blockscout holds for this address. `compiler.json` has the compiler settings and constructor arguments. `abi.json` is the verified ABI.

## Constructor arguments

| Name | Type | Value |
|---|---|---|
| `implementation` | `address` | `0xda1e76Aeb6D7B78Fd6474912E4b6863eFa29D349` |
| `_data` | `bytes` | `0x485cc95500000000000000000000000019e3bd92889484bcabc1df94f7ecb98c32cfea1600000000000000000000000019e3bd92889484bcabc1df94f7ecb98c32cfea16` |
