# Lyra Roulette v2

Commit-reveal roulette; the contract holds the bankroll and pays winners itself.

| | |
|---|---|
| Address | [`0x4556051598F568f2626809552d25F8d44BdE0394`](https://robinhoodchain.blockscout.com/address/0x4556051598F568f2626809552d25F8d44BdE0394) |
| Network | Robinhood Chain (chainId 4663) |
| Status | live |
| Holds / moves user funds | holds |
| Blockscout | verified, full match |
| Sourcify | exact match ([repo](https://repo.sourcify.dev/4663/0x4556051598F568f2626809552d25F8d44BdE0394)) |
| Contract | `LyraRouletteV2` in `LyraRouletteV2.sol` |
| Compiler | `v0.8.26+commit.8a97fa7a` |
| Optimizer | enabled, 200 runs |
| EVM version | default |
| viaIR | no |

Verification status checked on 2026-09-28 through the Blockscout and Sourcify APIs.

`src/` is the exact source Blockscout holds for this address. `compiler.json` has the compiler settings and constructor arguments. `abi.json` is the verified ABI.

## Constructor arguments

| Name | Type | Value |
|---|---|---|
| `token_` | `address` | `0xB9d3824149aD8ac984153CeEc91D5a2405d1FB95` |
| `secretSigner_` | `address` | `0x3Bcc63463838C5ECbc21816B06f9419f01D0D3e7` |
| `croupier_` | `address` | `0x9B3F07126F9C23df4d89A2Ab3473A3De6294008a` |
| `minBet_` | `uint256` | `1000000000000000000000` |
| `maxBet_` | `uint256` | `100000000000000000000000` |
| `maxProfit_` | `uint256` | `250000000000000000000000` |
