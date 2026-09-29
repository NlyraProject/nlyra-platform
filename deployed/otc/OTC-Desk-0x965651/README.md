# OTC Desk

Peer-to-peer block trades settled atomically from a non-custodial escrow (ETH / USDG / NLYRA); 0.5% fee buys and burns NLYRA.

| | |
|---|---|
| Address | [`0x9656513aC910a9839B51dB7c92a6914ABB4F52e8`](https://robinhoodchain.blockscout.com/address/0x9656513aC910a9839B51dB7c92a6914ABB4F52e8) |
| Network | Robinhood Chain (chainId 4663) |
| Status | live |
| Holds / moves user funds | holds |
| Blockscout | verified, full match |
| Sourcify | exact match ([repo](https://repo.sourcify.dev/4663/0x9656513aC910a9839B51dB7c92a6914ABB4F52e8)) |
| Contract | `ArchitectOTC` in `ArchitectOTC.sol` |
| Compiler | `v0.8.24+commit.e11b9ed9` |
| Optimizer | enabled, 200 runs |
| EVM version | cancun |
| viaIR | no |
| Working source & tests | [`otc/contracts/ArchitectOTC.sol`](../../../otc/contracts/ArchitectOTC.sol) |

Verification status checked on 2026-09-28 through the Blockscout and Sourcify APIs.

`src/` is the exact source Blockscout holds for this address. `compiler.json` has the compiler settings and constructor arguments. `abi.json` is the verified ABI.

## Constructor arguments

| Name | Type | Value |
|---|---|---|
| `weth` | `address` | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
| `nlyra` | `address` | `0xB9d3824149aD8ac984153CeEc91D5a2405d1FB95` |
| `burner` | `address` | `0x371bB2107f6E021EF2a5a980a9204F5a73151926` |
| `router` | `address` | `0xCaf681a66D020601342297493863E78C959E5cb2` |
| `usdg` | `address` | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| `flusher_` | `address` | `0x96D0B8008d1E38d45A1B9cFCCCC932629059246c` |
| `feeBps_` | `uint16` | `50` |
