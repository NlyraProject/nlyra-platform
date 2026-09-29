# OTC Desk: peer-to-peer block trades

**Live at [nlyra.xyz/otc](https://nlyra.xyz/otc)** · contract [`ArchitectOTC`](contracts/ArchitectOTC.sol) at [`0x9656513aC910a9839B51dB7c92a6914ABB4F52e8`](https://robinhoodchain.blockscout.com/address/0x9656513aC910a9839B51dB7c92a6914ABB4F52e8) (Blockscout full match + Sourcify exact match).

A seller escrows a token and names a price in ETH, USDG or NLYRA. A buyer pays, and in the same transaction the tokens leave the escrow and the payment reaches the seller. No pool is touched, so there is no price impact and no slippage: the price is the one the seller wrote. Offers can be partially fillable, can be private to one buyer, and expire.

## Fees

Every completed fill pays `feeBps` of the payment, capped at 1% in the contract (`MAX_FEE_BPS = 100`; 0.5% at deploy). The fee goes to the NLYRA buyback burner:

- paid in ETH: forwarded to the burner in the same transaction;
- paid in NLYRA: sent straight to `0x…dEaD`;
- paid in USDG: accrued and later swapped to ETH for the burner by the *flusher*, a bounded job that can move only accrued fees, never escrow.

## Non-custodial guarantees

- Escrowed tokens can only go to the buyer (fill) or back to the seller (cancel / expiry).
- There is no admin withdraw of escrow and no upgrade path. `rescue` is capped at what sits above escrow plus accrued fees.
- The owner can set the fee (at most 1%), the allowed quote assets and the flusher, and can pause new offers and fills. **Cancel always works, even when paused.** The fee destination (the burner) is immutable.

## Contents

| Path | What it is |
|---|---|
| [`contracts/ArchitectOTC.sol`](contracts/ArchitectOTC.sol) | The contract, byte-identical to the verified source |
| [`test/forktest-otc.js`](test/forktest-otc.js) | Mainnet-fork test with the real pools and the real burner: offers in ETH, USDG and NLYRA, partial fills, taker-locked offers, expiry refunds, cancel while paused, fee routing and USDG flush, rescue limits, and 22 expected-revert cases |
| [`scripts/`](scripts/) | `compile-otc.js`, `deploy-otc.js` (the deployer key comes from the environment). To reproduce the verification, submit `artifacts/ArchitectOTC.input.json` to Sourcify, or to Blockscout as "Solidity (Standard JSON input)" |
| [`artifacts/`](artifacts/) | Verified ABI and the exact standard-JSON compiler input (`solc 0.8.24`, optimizer 200 runs, `cancun`) |
| [`web/`](web/) | The static page served at nlyra.xyz/otc |
| [`DEPLOYED_OTC.json`](DEPLOYED_OTC.json) | Address, deploy transaction and block, constructor arguments |

## Running the fork test

```bash
mkdir run && cp contracts/ArchitectOTC.sol scripts/compile-otc.js test/forktest-otc.js run/ && cd run
npm i ethers solc@0.8.24 && node compile-otc.js
anvil --fork-url https://rpc.mainnet.chain.robinhood.com --port 8904 --chain-id 4663 &
node forktest-otc.js
```
