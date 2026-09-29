# Buyback Burner (first deploy)

Burner of the first launchpad deployment.

| | |
|---|---|
| Address | [`0xEb733465797c02146786F453DbC4aD1B701aA36e`](https://robinhoodchain.blockscout.com/address/0xEb733465797c02146786F453DbC4aD1B701aA36e) |
| Network | Robinhood Chain (chainId 4663) |
| Status | retired |
| Holds / moves user funds | protocol fees only |
| Blockscout | verified, full match |
| Sourcify | not verified |
| Contract | `BuybackBurner` in `BuybackBurner.sol` |
| Compiler | `v0.8.24+commit.e11b9ed9` |
| Optimizer | enabled, 200 runs |
| EVM version | default |
| viaIR | yes |

Verification status checked on 2026-09-28 through the Blockscout and Sourcify APIs.

`src/` is the exact source Blockscout holds for this address. `compiler.json` has the compiler settings and constructor arguments. `abi.json` is the verified ABI.

## Constructor arguments

| Name | Type | Value |
|---|---|---|
| `_router` | `address` | `0xA5deC66ECa62AE363dC47965bB790C3B8870b6B6` |
| `_nlyra` | `address` | `0xB9d3824149aD8ac984153CeEc91D5a2405d1FB95` |
| `_weth` | `address` | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
| `_treasury` | `address` | `0xe30647793192D15BFA6E53aE8651368d332fe04C` |
| `_keepBps` | `uint16` | `5000` |
