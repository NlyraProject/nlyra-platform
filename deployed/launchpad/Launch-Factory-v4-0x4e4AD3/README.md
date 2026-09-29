# Launch Factory v4

Current launchpad: pool-born tokens (ETH or USDG pairs), LP locked forever in a per-launch vault, creator fee share. Contains the token and vault templates.

| | |
|---|---|
| Address | [`0x4e4AD39E1A38104F8f74C3aF8d3F8c8E27f8836f`](https://robinhoodchain.blockscout.com/address/0x4e4AD39E1A38104F8f74C3aF8d3F8c8E27f8836f) |
| Network | Robinhood Chain (chainId 4663) |
| Status | live |
| Holds / moves user funds | holds |
| Blockscout | verified, full match |
| Sourcify | exact match ([repo](https://repo.sourcify.dev/4663/0x4e4AD39E1A38104F8f74C3aF8d3F8c8E27f8836f)) |
| Contract | `ArchitectLaunchFactoryV4` in `ArchitectLaunchPoolV4.sol` |
| Compiler | `v0.8.24+commit.e11b9ed9` |
| Optimizer | enabled, 200 runs |
| EVM version | default |
| viaIR | yes |

Verification status checked on 2026-09-28 through the Blockscout and Sourcify APIs.

`src/` is the exact source Blockscout holds for this address. `compiler.json` has the compiler settings and constructor arguments. `abi.json` is the verified ABI.

## Constructor arguments

| Name | Type | Value |
|---|---|---|
| `_treasury` | `address` | `0x371bB2107f6E021EF2a5a980a9204F5a73151926` |
| `_weth` | `address` | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
| `_npmOurs` | `address` | `0x4b71BE063E72b0BE36F690535C9C0cE533A9FB5C` |
| `_npmUni` | `address` | `0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3` |
| `_swapRouterOurs` | `address` | `0x4D0d17F66d1da788da50CF5217894F36684F958E` |
| `_ops` | `address` | `0xa6CD59b326F8bc5Cf68EcD2377Eee13AfBbb1657` |
| `_sqrtWeth0` | `uint160` | `3543191142285914205922034323214520` |
| `_sqrtWeth1` | `uint160` | `1771595571142957102961017` |
| `_tickEdgeWeth0` | `int24` | `214000` |
| `_tickEdgeWeth1` | `int24` | `-214000` |
