# Infinity Grid v4.1 BSC

The same infinity grid quoted in USDT or USDC (ERC-20 quote instead of BNB), with the fee-on-transfer gate. Deployed 26 October 2026.

| | |
|---|---|
| Address | [`0x354Ade1eE04D44B21c037Af8A61189d647027cBE`](https://bscscan.com/address/0x354Ade1eE04D44B21c037Af8A61189d647027cBE) |
| Network | BNB Smart Chain (chainId 56) |
| Status | live |
| Holds / moves user funds | yes |
| BscScan | verified (full match) |
| Sourcify | exact match ([repo](https://repo.sourcify.dev/56/0x354Ade1eE04D44B21c037Af8A61189d647027cBE)) |
| Contract | `ArchitectInfinityGridV41BSC` in `src/ArchitectInfinityGridV41BSC.sol` |
| Compiler | `v0.8.24+commit.e11b9ed9` |
| Optimizer | enabled, 200 runs |
| EVM version | cancun |
| viaIR | yes |
| Deploy transaction | [`0xb6825d3b377ac1bd68caad1579d778ab4f0fa1ac2a786769c5bec527375b8ad9`](https://bscscan.com/tx/0xb6825d3b377ac1bd68caad1579d778ab4f0fa1ac2a786769c5bec527375b8ad9) (block 129888489) |
| Deployed | 2026-10-26 by the treasury `0xe30647793192D15BFA6E53aE8651368d332fe04C` |
| Working source & tests | [`bsc/src/ArchitectInfinityGridV41BSC.sol`](../../../bsc/src/ArchitectInfinityGridV41BSC.sol) |

`src/` is the exact source the explorer holds for this address (2 files). `compiler.json` has the compiler settings and the constructor arguments. `abi.json` is the verified ABI.

## Constructor arguments

| Name | Type | Value |
|---|---|---|
| `router` | `address` | `0x0e86a190f7d92031ca181a50e5e21dabb530c0e6` |
| `weth` | `address` | `0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c` |
| `keeper` | `address` | `0xfbc9cff9579578c942cf9e7ab30189eab8c0714b` |
