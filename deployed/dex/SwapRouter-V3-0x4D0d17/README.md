# SwapRouter (V3)

Uniswap V3 periphery SwapRouter, deployed verbatim.

| | |
|---|---|
| Address | [`0x4D0d17F66d1da788da50CF5217894F36684F958E`](https://robinhoodchain.blockscout.com/address/0x4D0d17F66d1da788da50CF5217894F36684F958E) |
| Network | Robinhood Chain (chainId 4663) |
| Status | live |
| Holds / moves user funds | moves (does not keep balances) |
| Blockscout | verified (partial match) |
| Sourcify | not verified |
| Contract | `SwapRouter` in `contracts/SwapRouter.sol` |
| Compiler | `v0.7.6+commit.7338295f` |
| Optimizer | enabled, 1000000 runs |
| EVM version | istanbul |
| viaIR | no |

Verification status checked on 2026-09-28 through the Blockscout and Sourcify APIs.

`src/` is the exact source Blockscout holds for this address. `compiler.json` has the compiler settings and constructor arguments. `abi.json` is the verified ABI.

## Constructor arguments

| Name | Type | Value |
|---|---|---|
| `_factory` | `address` | `0x3FdaBf7AB5d871B89F1d9DA04Dc2E0733dB70CaF` |
| `_WETH9` | `address` | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
