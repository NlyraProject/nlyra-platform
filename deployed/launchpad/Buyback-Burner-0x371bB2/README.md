# Buyback Burner

Launchpad treasury with no owner: 50% ops / 50% market-buys NLYRA to 0xdEaD; anyone can trigger it.

| | |
|---|---|
| Address | [`0x371bB2107f6E021EF2a5a980a9204F5a73151926`](https://robinhoodchain.blockscout.com/address/0x371bB2107f6E021EF2a5a980a9204F5a73151926) |
| Network | Robinhood Chain (chainId 4663) |
| Status | live |
| Holds / moves user funds | protocol fees only |
| Blockscout | verified, full match |
| Sourcify | exact match ([repo](https://repo.sourcify.dev/4663/0x371bB2107f6E021EF2a5a980a9204F5a73151926)) |
| Contract | `BuybackBurner` in `BuybackBurner.sol` |
| Compiler | `v0.8.24+commit.e11b9ed9` |
| Optimizer | enabled, 200 runs |
| EVM version | default |
| viaIR | yes |
| Working source & tests | [`launchpad/contracts/BuybackBurner.sol`](../../../launchpad/contracts/BuybackBurner.sol) |

Verification status checked on 2026-09-28 through the Blockscout and Sourcify APIs.

`src/` is the exact source Blockscout holds for this address. `compiler.json` has the compiler settings and constructor arguments. `abi.json` is the verified ABI.

## Constructor arguments

| Name | Type | Value |
|---|---|---|
| `_router` | `address` | `0xCaf681a66D020601342297493863E78C959E5cb2` |
| `_nlyra` | `address` | `0xB9d3824149aD8ac984153CeEc91D5a2405d1FB95` |
| `_weth` | `address` | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
| `_pool` | `address` | `0x483C24d1e36Df01b650F1E9BEEB2a1c31C005C39` |
| `_treasury` | `address` | `0xe30647793192D15BFA6E53aE8651368d332fe04C` |
| `_keepBps` | `uint16` | `5000` |
