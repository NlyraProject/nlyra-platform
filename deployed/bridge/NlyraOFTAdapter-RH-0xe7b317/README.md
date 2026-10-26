# Bridge adapter (NlyraOFTAdapter)

Locks NLYRA on Robinhood Chain while the same amount circulates on Arbitrum One, unlocks it on the way back. Stock LayerZero V2 OFTAdapter plus the same outbound rate limit. Owner and LayerZero delegate: the treasury.

| | |
|---|---|
| Address | [`0xe7b3171b76B959Db805874926aA0D62b1A5d3264`](https://robinhoodchain.blockscout.com/address/0xe7b3171b76B959Db805874926aA0D62b1A5d3264) |
| Network | Robinhood Chain (chainId 4663) |
| Status | live |
| Holds / moves user funds | yes |
| Blockscout | verified (full match) |
| Contract | `NlyraOFTAdapter` in `src/src/NlyraOFTAdapter.sol` |
| Compiler | `v0.8.22+commit.4fc1097e` |
| Optimizer | enabled, 200 runs |
| EVM version | paris |
| viaIR | no |
| Deployed | 2026-10-19 by the treasury `0xe30647793192D15BFA6E53aE8651368d332fe04C` |
| Working source & tests | [`bridge/src/NlyraOFTAdapter.sol`](../../../bridge/src/NlyraOFTAdapter.sol) |

`src/` is the exact source the explorer holds for this address (41 files). `compiler.json` has the compiler settings and the constructor arguments. `abi.json` is the verified ABI.

## Constructor arguments

| Name | Type | Value |
|---|---|---|
| `_token` | `address` | `0xb9d3824149ad8ac984153ceec91d5a2405d1fb95` |
| `_lzEndpoint` | `address` | `0x6f475642a6e85809b1c36fa62763669b1b48dd5b` |
| `_owner` | `address` | `0xe30647793192d15bfa6e53ae8651368d332fe04c` |
