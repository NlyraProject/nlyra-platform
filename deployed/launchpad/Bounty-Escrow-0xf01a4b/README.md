# Bounty Escrow

Community bounties escrowed in USDG; no admin withdraw, rejections auto-refund.

| | |
|---|---|
| Address | [`0xf01a4bD90aeF8dD75FCb1EA6a3865Ac4b72DFF2c`](https://robinhoodchain.blockscout.com/address/0xf01a4bD90aeF8dD75FCb1EA6a3865Ac4b72DFF2c) |
| Network | Robinhood Chain (chainId 4663) |
| Status | live |
| Holds / moves user funds | holds |
| Blockscout | verified, full match |
| Sourcify | exact match ([repo](https://repo.sourcify.dev/4663/0xf01a4bD90aeF8dD75FCb1EA6a3865Ac4b72DFF2c)) |
| Contract | `BountyEscrow` in `BountyEscrow.sol` |
| Compiler | `v0.8.24+commit.e11b9ed9` |
| Optimizer | enabled, 200 runs |
| EVM version | default |
| viaIR | yes |

Verification status checked on 2026-09-28 through the Blockscout and Sourcify APIs.

`src/` is the exact source Blockscout holds for this address. `compiler.json` has the compiler settings and constructor arguments. `abi.json` is the verified ABI.

## Constructor arguments

| Name | Type | Value |
|---|---|---|
| `_arbiter` | `address` | `0x0C90088dDbb86BDa9381Cd0F04d9D971Dd3cd4d4` |
| `_feeSink` | `address` | `0xe30647793192D15BFA6E53aE8651368d332fe04C` |
| `tokens` | `address[]` | `["0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168", "0xB9d3824149aD8ac984153CeEc91D5a2405d1FB95"]` |
| `caps` | `uint256[]` | `["500000000", "20000000000000000000000000"]` |
