# Spot Grid v4 BSC

Spot grid with a price range (2 to 60 grids) in BNB, compounding, per-bot gas reserve. Port of the Robinhood Chain v4.

| | |
|---|---|
| Address | [`0x8a678c93f745A853865F5718F9fbb6239e1837e1`](https://bscscan.com/address/0x8a678c93f745A853865F5718F9fbb6239e1837e1) |
| Network | BNB Smart Chain (chainId 56) |
| Status | live |
| Holds / moves user funds | yes |
| BscScan | verified (full match) |
| Contract | `ArchitectSpotGridV4BSC` in `src/ArchitectSpotGridV4BSC.sol` |
| Compiler | `v0.8.24+commit.e11b9ed9` |
| Optimizer | enabled, 200 runs |
| EVM version | cancun |
| viaIR | yes |
| Deploy transaction | [`0xef13581a746e98b745ebaa042fee6fa140581f027b03ffda8ccc7fa1d89ee6dd`](https://bscscan.com/tx/0xef13581a746e98b745ebaa042fee6fa140581f027b03ffda8ccc7fa1d89ee6dd) (block 129511574) |
| Deployed | 2026-10-24 by the treasury `0xe30647793192D15BFA6E53aE8651368d332fe04C` |
| Working source & tests | [`bsc/src/ArchitectSpotGridV4BSC.sol`](../../../bsc/src/ArchitectSpotGridV4BSC.sol) |

`src/` is the exact source the explorer holds for this address (2 files). `compiler.json` has the compiler settings and the constructor arguments. `abi.json` is the verified ABI.

## Constructor arguments

| Name | Type | Value |
|---|---|---|
| `router` | `address` | `0x0e86a190f7d92031ca181a50e5e21dabb530c0e6` |
| `weth` | `address` | `0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c` |
| `keeper` | `address` | `0xfbc9cff9579578c942cf9e7ab30189eab8c0714b` |
