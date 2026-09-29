# Presale Factory

Architect Presale: contributions sit in the presale contract (never with the creator); soft cap refunds, the raise seeds locked liquidity.

| | |
|---|---|
| Address | [`0x06d3C711aAFC522931FAA6De895B8755cB84556f`](https://robinhoodchain.blockscout.com/address/0x06d3C711aAFC522931FAA6De895B8755cB84556f) |
| Network | Robinhood Chain (chainId 4663) |
| Status | live |
| Holds / moves user funds | holds |
| Blockscout | verified, full match |
| Sourcify | exact match ([repo](https://repo.sourcify.dev/4663/0x06d3C711aAFC522931FAA6De895B8755cB84556f)) |
| Contract | `ArchitectPresaleFactory` in `ArchitectPresale.sol` |
| Compiler | `v0.8.24+commit.e11b9ed9` |
| Optimizer | enabled, 200 runs |
| EVM version | default |
| viaIR | yes |

Verification status checked on 2026-09-28 through the Blockscout and Sourcify APIs.

`src/` is the exact source Blockscout holds for this address. `compiler.json` has the compiler settings and constructor arguments. `abi.json` is the verified ABI.

## Constructor arguments

| Name | Type | Value |
|---|---|---|
| `_treasury` | `address` | `0x371bB2107f6E021EF2a5a980a9204F5a73151926` |
| `_weth` | `address` | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` |
| `_npmOurs` | `address` | `0x4b71BE063E72b0BE36F690535C9C0cE533A9FB5C` |
| `_npmUni` | `address` | `0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3` |
| `_platformFeeBps` | `uint16` | `500` |
