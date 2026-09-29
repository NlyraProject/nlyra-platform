# StakingRewards (NLYRA staking v1)

Single-sided NLYRA staking (Synthetix StakingRewards pattern); no owner migration path.

| | |
|---|---|
| Address | [`0x5e63228add4390f77BbcDb364F6A7b42bA7Aa3ef`](https://robinhoodchain.blockscout.com/address/0x5e63228add4390f77BbcDb364F6A7b42bA7Aa3ef) |
| Network | Robinhood Chain (chainId 4663) |
| Status | live |
| Holds / moves user funds | holds |
| Blockscout | verified (partial match) |
| Sourcify | match (partial) ([repo](https://repo.sourcify.dev/4663/0x5e63228add4390f77BbcDb364F6A7b42bA7Aa3ef)) |
| Contract | `StakingRewards` in `StakingRewards.sol` |
| Compiler | `v0.5.16+commit.9c3226ce` |
| Optimizer | disabled |
| EVM version | default |
| viaIR | no |

Verification status checked on 2026-09-28 through the Blockscout and Sourcify APIs.

`src/` is the exact source Blockscout holds for this address. `compiler.json` has the compiler settings and constructor arguments. `abi.json` is the verified ABI.

## Constructor arguments

| Name | Type | Value |
|---|---|---|
| `_rewardsDistribution` | `address` | `0xe30647793192D15BFA6E53aE8651368d332fe04C` |
| `_rewardsToken` | `address` | `0xB9d3824149aD8ac984153CeEc91D5a2405d1FB95` |
| `_stakingToken` | `address` | `0xB9d3824149aD8ac984153CeEc91D5a2405d1FB95` |
