# NLYRA on BNB Smart Chain (NlyraOFT)

The official NLYRA on BNB Smart Chain: a LayerZero V2 OFT minted 1:1 against NLYRA locked in the adapter on Robinhood Chain, burned when it goes back. Same source, same compiler settings and same bytecode as the Arbitrum OFT; the adapter serves both destinations. Stock LayerZero OFT plus an owner-settable outbound rate limit (20,000,000 NLYRA per day per destination).

| | |
|---|---|
| Address | [`0x10Bd775269A3D53b056F43d9f5B3EeAc17166Bec`](https://bscscan.com/address/0x10Bd775269A3D53b056F43d9f5B3EeAc17166Bec) |
| Network | BNB Smart Chain (chainId 56) |
| Status | live |
| Holds / moves user funds | no (it is the token) |
| BscScan | verified |
| Sourcify | exact match ([repo](https://repo.sourcify.dev/56/0x10Bd775269A3D53b056F43d9f5B3EeAc17166Bec)) |
| Contract | `NlyraOFT` in `src/src/NlyraOFT.sol` |
| Compiler | `v0.8.22+commit.4fc1097e` |
| Optimizer | enabled, 200 runs |
| EVM version | paris |
| viaIR | no |
| Deployed | 2026-10-27 by the treasury `0xe30647793192D15BFA6E53aE8651368d332fe04C`, tx [`0xbcf0ffc8699b846298f07e5970a6c4b4fba1e569f8b0511803941430bd2f91ca`](https://bscscan.com/tx/0xbcf0ffc8699b846298f07e5970a6c4b4fba1e569f8b0511803941430bd2f91ca) |
| LayerZero endpoint | `0x1a44076050125825900e736c501f859c50fE728c` (eid 30102) |
| Peer | the Robinhood Chain adapter `0xe7b3171b76B959Db805874926aA0D62b1A5d3264` (eid 30416) |
| Working source & tests | [`bridge/src/NlyraOFT.sol`](../../../bridge/src/NlyraOFT.sol) |

`src/` is the exact source the explorer holds for this address (43 files). `compiler.json` has the compiler settings and the constructor arguments. `abi.json` is the verified ABI.

## Constructor arguments

| Name | Type | Value |
|---|---|---|
| `_lzEndpoint` | `address` | `0x1a44076050125825900e736c501f859c50fe728c` |
| `_owner` | `address` | `0xe30647793192d15bfa6e53ae8651368d332fe04c` |
