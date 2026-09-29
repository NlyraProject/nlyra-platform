# Fee Router v2

Every Desk trade and every bot swap routes through it (Uniswap V2/V3/V4 on Robinhood Chain); 1% fee per executed trade, 30% of it credited to the referrer.

| | |
|---|---|
| Address | [`0x9d1eA9Abbb99D813b7acA7666285CDed7f833565`](https://robinhoodchain.blockscout.com/address/0x9d1eA9Abbb99D813b7acA7666285CDed7f833565) |
| Network | Robinhood Chain (chainId 4663) |
| Status | live |
| Holds / moves user funds | moves (does not keep balances) |
| Blockscout | verified, full match |
| Sourcify | exact match ([repo](https://repo.sourcify.dev/4663/0x9d1eA9Abbb99D813b7acA7666285CDed7f833565)) |
| Contract | `ArchitectFeeRouter` in `ArchitectFeeRouter.sol` |
| Compiler | `v0.8.24+commit.e11b9ed9` |
| Optimizer | enabled, 200 runs |
| EVM version | cancun |
| viaIR | yes |
| Working source & tests | [`bots/contracts/ArchitectFeeRouter.sol`](../../../bots/contracts/ArchitectFeeRouter.sol) |

Verification status checked on 2026-09-28 through the Blockscout and Sourcify APIs.

`src/` is the exact source Blockscout holds for this address. `compiler.json` has the compiler settings and constructor arguments. `abi.json` is the verified ABI.

## Constructor arguments

| Name | Type | Value |
|---|---|---|
| `v3Factory` | `address` | `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA` |
| `v2Router` | `address` | `0x0000000000000000000000000000000000000000` |
| `v2Factory` | `address` | `0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f` |
| `v4PoolManager` | `address` | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| `treasury_` | `address` | `0x371bB2107f6E021EF2a5a980a9204F5a73151926` |
| `weth` | `address` | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
