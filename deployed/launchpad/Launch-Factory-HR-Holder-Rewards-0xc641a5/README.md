# Launch Factory HR (Holder Rewards)

Holder Rewards venue: launched tokens stream pool fees to holders through a rewards distributor. Rebuilt 2026-08-27.

| | |
|---|---|
| Address | [`0xc641a5bD946290cA1905A68c4BA3b1d969169398`](https://robinhoodchain.blockscout.com/address/0xc641a5bD946290cA1905A68c4BA3b1d969169398) |
| Network | Robinhood Chain (chainId 4663) |
| Status | live |
| Holds / moves user funds | holds |
| Blockscout | verified, full match |
| Sourcify | exact match ([repo](https://repo.sourcify.dev/4663/0xc641a5bD946290cA1905A68c4BA3b1d969169398)) |
| Contract | `ArchitectLaunchFactoryHR` in `ArchitectLaunchHR.sol` |
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
| `_npmUni` | `address` | `0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3` |
| `_v3factoryUni` | `address` | `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA` |
| `_keeper` | `address` | `0xa6CD59b326F8bc5Cf68EcD2377Eee13AfBbb1657` |
| `_sqrtWeth0` | `uint160` | `3543191142285914205922034323214520` |
| `_sqrtWeth1` | `uint160` | `1771595571142957102961017` |
| `_tickEdgeWeth0` | `int24` | `214000` |
| `_tickEdgeWeth1` | `int24` | `-214000` |
