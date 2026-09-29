# Launch Factory (first deploy)

First launchpad deployment (July 2026); its vaults keep their locked LP.

| | |
|---|---|
| Address | [`0xd1E56b211191dABa8A715D861931173D967a4D0d`](https://robinhoodchain.blockscout.com/address/0xd1E56b211191dABa8A715D861931173D967a4D0d) |
| Network | Robinhood Chain (chainId 4663) |
| Status | retired |
| Holds / moves user funds | holds |
| Blockscout | verified, full match |
| Sourcify | not verified |
| Contract | `ArchitectLaunchFactoryV2` in `ArchitectLaunchPool.sol` |
| Compiler | `v0.8.24+commit.e11b9ed9` |
| Optimizer | enabled, 200 runs |
| EVM version | default |
| viaIR | yes |
| Working source & tests | [`launchpad/contracts/`](../../../launchpad/contracts/) |

Verification status checked on 2026-09-28 through the Blockscout and Sourcify APIs.

`src/` is the exact source Blockscout holds for this address. `compiler.json` has the compiler settings and constructor arguments. `abi.json` is the verified ABI.

## Constructor arguments

| Name | Type | Value |
|---|---|---|
| `_treasury` | `address` | `0xEb733465797c02146786F453DbC4aD1B701aA36e` |
| `_weth` | `address` | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
| `_npmOurs` | `address` | `0x4b71BE063E72b0BE36F690535C9C0cE533A9FB5C` |
| `_npmUni` | `address` | `0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3` |
| `_swapRouterOurs` | `address` | `0x4D0d17F66d1da788da50CF5217894F36684F958E` |
| `_sqrtWeth0` | `uint160` | `3543191142285914205922034323214520` |
| `_sqrtWeth1` | `uint160` | `1771595571142957102961017` |
| `_tickEdgeWeth0` | `int24` | `214000` |
| `_tickEdgeWeth1` | `int24` | `-214000` |
