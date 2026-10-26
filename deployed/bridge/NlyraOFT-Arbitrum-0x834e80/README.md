# NLYRA on Arbitrum One (NlyraOFT)

The official NLYRA on Arbitrum One: a LayerZero V2 OFT minted 1:1 against NLYRA locked in the adapter on Robinhood Chain, burned when it goes back. Stock LayerZero OFT plus an owner-settable outbound rate limit (20,000,000 NLYRA per day per destination).

| | |
|---|---|
| Address | [`0x834e80509b23dC82d79F982510a32348986B06b5`](https://arbiscan.io/address/0x834e80509b23dC82d79F982510a32348986B06b5) |
| Network | Arbitrum One (chainId 42161) |
| Status | live |
| Holds / moves user funds | no (it is the token) |
| Arbiscan | verified (full match) |
| Sourcify | exact match ([repo](https://repo.sourcify.dev/42161/0x834e80509b23dC82d79F982510a32348986B06b5)) |
| Contract | `NlyraOFT` in `src/src/NlyraOFT.sol` |
| Compiler | `v0.8.22+commit.4fc1097e` |
| Optimizer | enabled, 200 runs |
| EVM version | paris |
| viaIR | no |
| Deployed | 2026-10-19 by the treasury `0xe30647793192D15BFA6E53aE8651368d332fe04C` |
| Working source & tests | [`bridge/src/NlyraOFT.sol`](../../../bridge/src/NlyraOFT.sol) |

`src/` is the exact source the explorer holds for this address (43 files). `compiler.json` has the compiler settings and the constructor arguments. `abi.json` is the verified ABI.

## Constructor arguments

| Name | Type | Value |
|---|---|---|
| `_lzEndpoint` | `address` | `0x1a44076050125825900e736c501f859c50fe728c` |
| `_owner` | `address` | `0xe30647793192d15bfa6e53ae8651368d332fe04c` |
