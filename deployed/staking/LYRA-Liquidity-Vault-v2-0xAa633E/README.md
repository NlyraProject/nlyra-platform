# LYRA Liquidity Vault v2

Invest with LYRA: ETH deposits for shares, deployed only as LP in whitelisted WETH pools; withdrawals pay actual proceeds.

| | |
|---|---|
| Address | [`0xAa633E2Ed66A90d39a58cF183df01B7EC3d6756A`](https://robinhoodchain.blockscout.com/address/0xAa633E2Ed66A90d39a58cF183df01B7EC3d6756A) |
| Network | Robinhood Chain (chainId 4663) |
| Status | live |
| Holds / moves user funds | holds |
| Blockscout | verified, full match |
| Sourcify | exact match ([repo](https://repo.sourcify.dev/4663/0xAa633E2Ed66A90d39a58cF183df01B7EC3d6756A)) |
| Contract | `LyraLiquidityVaultV2` in `LyraVaultV2.sol` |
| Compiler | `v0.8.24+commit.e11b9ed9` |
| Optimizer | enabled, 200 runs |
| EVM version | default |
| viaIR | yes |

Verification status checked on 2026-09-28 through the Blockscout and Sourcify APIs.

`src/` is the exact source Blockscout holds for this address. `compiler.json` has the compiler settings and constructor arguments. `abi.json` is the verified ABI.

## Constructor arguments

| Name | Type | Value |
|---|---|---|
| `_weth` | `address` | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
| `_treasury` | `address` | `0x371bB2107f6E021EF2a5a980a9204F5a73151926` |
| `_keeper` | `address` | `0xa6CD59b326F8bc5Cf68EcD2377Eee13AfBbb1657` |
| `_npmUni` | `address` | `0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3` |
| `_npmOurs` | `address` | `0x4b71BE063E72b0BE36F690535C9C0cE533A9FB5C` |
| `_facUni` | `address` | `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA` |
| `_facOurs` | `address` | `0x3FdaBf7AB5d871B89F1d9DA04Dc2E0733dB70CaF` |
| `_seasonCap` | `uint256` | `5000000000000000000` |
