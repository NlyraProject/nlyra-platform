# Infinity Grid v4 BSC

Infinity grid in BNB (no ceiling) with floor price, take profit, stop loss and a per-bot gas reserve that pays the keeper for each fill. Port of the Robinhood Chain v4.

| | |
|---|---|
| Address | [`0xE878aa6bE4c5429a5006A516C720A1232Bf18a8a`](https://bscscan.com/address/0xE878aa6bE4c5429a5006A516C720A1232Bf18a8a) |
| Network | BNB Smart Chain (chainId 56) |
| Status | live |
| Holds / moves user funds | yes |
| BscScan | verified (full match) |
| Contract | `ArchitectInfinityGridV4BSC` in `src/ArchitectInfinityGridV4BSC.sol` |
| Compiler | `v0.8.24+commit.e11b9ed9` |
| Optimizer | enabled, 200 runs |
| EVM version | cancun |
| viaIR | yes |
| Deploy transaction | [`0x2efa236d70ba2e84c777803fff346c850673a31b03228cc935db353b89b88084`](https://bscscan.com/tx/0x2efa236d70ba2e84c777803fff346c850673a31b03228cc935db353b89b88084) (block 129511558) |
| Deployed | 2026-10-24 by the treasury `0xe30647793192D15BFA6E53aE8651368d332fe04C` |
| Working source & tests | [`bsc/src/ArchitectInfinityGridV4BSC.sol`](../../../bsc/src/ArchitectInfinityGridV4BSC.sol) |

`src/` is the exact source the explorer holds for this address (2 files). `compiler.json` has the compiler settings and the constructor arguments. `abi.json` is the verified ABI.

## Constructor arguments

| Name | Type | Value |
|---|---|---|
| `router` | `address` | `0x0e86a190f7d92031ca181a50e5e21dabb530c0e6` |
| `weth` | `address` | `0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c` |
| `keeper` | `address` | `0xfbc9cff9579578c942cf9e7ab30189eab8c0714b` |
