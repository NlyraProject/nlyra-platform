# Fee Router BSC

Every bot swap on BNB Chain goes through it (PancakeSwap v2 router, v2 pair, v3 pool, v3 multi-hop through the SmartRouter); 1% fee per executed trade, accrued in the quote token for the treasury (fee collector).

| | |
|---|---|
| Address | [`0x0e86a190F7D92031CA181A50E5E21DaBB530c0E6`](https://bscscan.com/address/0x0e86a190F7D92031CA181A50E5E21DaBB530c0E6) |
| Network | BNB Smart Chain (chainId 56) |
| Status | live |
| Holds / moves user funds | moves |
| BscScan | verified (full match) |
| Contract | `ArchitectFeeRouterBSC` in `src/ArchitectFeeRouterBSC.sol` |
| Compiler | `v0.8.24+commit.e11b9ed9` |
| Optimizer | enabled, 200 runs |
| EVM version | cancun |
| viaIR | yes |
| Deploy transaction | [`0x948491eb1f2182f432b4280f822f4e9fb025c909fb3611c1f4cde1ebb13b5a16`](https://bscscan.com/tx/0x948491eb1f2182f432b4280f822f4e9fb025c909fb3611c1f4cde1ebb13b5a16) (block 129511543) |
| Deployed | 2026-10-24 by the treasury `0xe30647793192D15BFA6E53aE8651368d332fe04C` |
| Working source & tests | [`bsc/src/ArchitectFeeRouterBSC.sol`](../../../bsc/src/ArchitectFeeRouterBSC.sol) |

`src/` is the exact source the explorer holds for this address (1 file). `compiler.json` has the compiler settings and the constructor arguments. `abi.json` is the verified ABI.

## Constructor arguments

| Name | Type | Value |
|---|---|---|
| `v3Factory` | `address` | `0x0bfbcf9fa4f9c56b0f40a671ad40e0805a091865` |
| `v2Router` | `address` | `0x10ed43c718714eb63d5aa57b78b54704e256024e` |
| `v2Factory` | `address` | `0xca143ce32fe78f1f7019d7d551a6402fc5350c73` |
| `smartRouter` | `address` | `0x13f4ea83d0bd40e75c8222255bc855a974568dd4` |
| `treasury_` | `address` | `0xe30647793192d15bfa6e53ae8651368d332fe04c` |
| `wbnb` | `address` | `0xbb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c` |
