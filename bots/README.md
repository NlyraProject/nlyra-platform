# The Desk bots: non-custodial trading bots on Robinhood Chain

This folder holds the source, the mainnet-fork tests and the verification artifacts for the current bot contracts behind [nlyra.xyz/desk/bots](https://nlyra.xyz/desk/bots). Every contract here is **live on Robinhood Chain (chainId 4663)** and **verified on Blockscout**. [`DEPLOYED_BOTS.json`](DEPLOYED_BOTS.json) has the addresses and links.

The older bot contracts (Spot Grid v1/v3, Infinity Grid v1–v3, the USDG grids, DCA, Martingale, TWAP, Ladder) are listed in [`../CONTRACTS.md`](../CONTRACTS.md). Their verified sources are in [`../deployed/bots/`](../deployed/bots/).

| Contract | What it does | Address |
|---|---|---|
| [`ArchitectSpotGridV4`](contracts/ArchitectSpotGridV4.sol) | Spot grid: buys low and sells high inside a range. **v4 compounds** every closed grid into the next buy and carries a **per-bot gas reserve** that pays the keeper for each fill. | [`0xF8ef…9D5f`](https://robinhoodchain.blockscout.com/address/0xF8ef52605FBcc968B24b7FdBD7e93c752A659D5f) |
| [`ArchitectInfinityGridV4`](contracts/ArchitectInfinityGridV4.sol) | Infinity grid (no ceiling): follows the price up, and every realized gain **grows the position it holds**. Same gas reserve. | [`0xBdC7…DDeb`](https://robinhoodchain.blockscout.com/address/0xBdC77e3D589D161489f7C986d8f654F30b88DDeb) |
| [`ArchitectShadow`](contracts/ArchitectShadow.sol) | Copy trading: mirrors every swap of a chosen wallet from the follower's own escrow, at the follower's size, with per-position stop-loss / take-profit. | [`0xE26d…B3D2`](https://robinhoodchain.blockscout.com/address/0xE26dd0A09Cd7bA2F7d0a31e4B625E983B0B1B3D2) |
| [`ArchitectSniper`](contracts/ArchitectSniper.sol) | Launch sniper: enters Pons bonding curves (and router pools) under the owner's own limits: size per entry, cap per token, max positions, and stop-loss / take-profit proven against cost. The strategy is configured per bot. 1% per trade. | [`0x6B30…C84c`](https://robinhoodchain.blockscout.com/address/0x6B30B0946743eF8A2D323127c8CfaC9966b5C84c) |
| [`ArchitectSendTo`](contracts/ArchitectSendTo.sol) | Not a bot: a 5 KB wrapper on the fee router that lets a wallet buy or sell and have the output delivered to another wallet. It holds nothing, and the router still validates fee, pairs, hooks, deadline and slippage. | [`0x0eF6…Ddc0`](https://robinhoodchain.blockscout.com/address/0x0eF655f16345afb66b42d4e65B71a16052d1Ddc0) |
| [`ArchitectFeeRouter`](contracts/ArchitectFeeRouter.sol) | The 1% fee router every Desk trade and bot swap goes through (Uniswap V2 / V3 / V4 pools on Robinhood Chain). | [`0x9d1e…3565`](https://robinhoodchain.blockscout.com/address/0x9d1eA9Abbb99D813b7acA7666285CDed7f833565) |
| [`ArchitectRegistry`](contracts/ArchitectRegistry.sol) | On-chain names for The Desk. Leaderboard, referrals and copy trading follow a name, not a hex string. | [`0x80d4…9fAF`](https://robinhoodchain.blockscout.com/address/0x80d4dCbc9814f1bCA48C0f10f70B36BF3bc09fAF) |
| [`ArchitectBotBase`](contracts/ArchitectBotBase.sol) | Shared base: escrow accounting, owner-only withdraw, keeper gate, fee routing. | (inherited) |

Every file in `contracts/` is byte-identical to the source verified for its address, with one exception. `ArchitectBotBase.sol` here is the Sniper's version, where `receive()` is `virtual` so the Sniper can also accept ETH from the curve it sells to. The grids and Shadow were compiled with the version just before that change, which is in each contract's folder under [`../deployed/bots/`](../deployed/bots/).

Retired deployments: Sniper v1 `0x2E47…f1f5` was paused after the security review and never held a bot. SendTo v1 `0xb7F7…3596` was disabled on the router because it bound the router referral to the contract on the ETH paths.

## Security model

- **Non-custodial.** A bot is a position inside the user's own escrow in the contract. Funds never move to us.
- **The keeper can only run the strategy.** The keeper EOA (`0x96D0…246c`) may call the fill / stop-loss / take-profit paths. It cannot withdraw, change parameters or redirect funds.
- **Only the owner withdraws.** `stop()` returns capital, tokens and whatever is left of the gas reserve to the bot owner. There is no admin withdraw, no upgrade path, and no pause that traps funds.
- **The gas reserve is fenced.** A gas `topUp` only ever tops up gas, `rescue` paths cannot touch it, and each fill is charged its exact gas from it (`gasOverhead` is bounded by `setGasOverhead`).
- **The fee is fixed at the router.** It is 1% per swap, taken by `ArchitectFeeRouter`, and the rate is written into each bot at creation.
- **Fee-aware sizing lives in the front end.** The Desk refuses to build a grid whose levels cannot clear the fee, which keeps the contracts small on purpose.

## Tests

The suites in [`test/`](test/) run against an **anvil fork of Robinhood Chain mainnet**. They use the **real** NLYRA/WETH Uniswap V3 pool and the **real** fee router, and deploy the contract under test fresh on the fork. Nothing touches mainnet.

| File | Covers |
|---|---|
| `forktest-v4.js` | Spot Grid v4: gas reserve (open, keeper payment, `NoGas`, gas-only top-up, refund on stop, rescue cannot touch it), compound (`profitFree`, boost on `fillBuy`, `setCompound`, `nextBuyQuote`), bounded `setGasOverhead`. |
| `forktest-infv4.js` | Infinity v4: open with reserve, `fillUp`/`fillDown` pay the keeper, `NoGas`, top-ups, `stop`/`refundExpired` return the reserve, compound really grows V, soft stop-loss with a small reserve, invariant fuzz. |
| `forktest-shadow.js` | Shadow: follow / mirror / stop-loss / take-profit / unfollow from clean wallets, through the fee router. |
| `forktest-sendto.js` | SendTo: buy from A delivered to B (fee accrued, nothing retained, referral bound to the recipient), sell from B paid to C, a recipient that rejects ETH reverts, allowlist and deadline checks. 17 checks. |
| `forktest-sniper.js` | Sniper: open with a gas reserve, enter a **live Pons curve** picked at fork time (fee to treasury, caps, venue checks, fake-curve rejection), partial and total exits with fee on output, take-profit after a whale pump, stop-loss after a whale dump, router-pool entry/exit, sources bitmask, `receive()` gate, top-up / limits / `NoGas` / stop with tokens / `refundExpired` / rescue. 126 checks, including a fake curve, a token that refuses transfers inside `stop()`, a capped buy that refunds ETH and a graduated curve. |
| `tpcheck-infv4.js`, `slcheck-*.js` | Targeted take-profit and stop-loss checks. |

The Infinity v4 contract, its test results, deploy transaction and verification are summarised in [`docs/infinity-v4-notes.md`](docs/infinity-v4-notes.md).

### Running a fork test

The compile scripts, contracts and tests were run from one flat working directory, so put them side by side first:

```bash
mkdir run && cp contracts/ArchitectSpotGridV4.sol contracts/ArchitectBotBase.sol scripts/compile-v4.js test/forktest-v4.js run/
cd run && npm i ethers solc@0.8.24
node compile-v4.js                               # writes artifacts/ArchitectSpotGridV4.{abi.json,bin}
anvil --fork-url https://rpc.mainnet.chain.robinhood.com --port 8901 --chain-id 4663 &
DESK_ADDRESSES=../../deployments/desk-addresses.json node forktest-v4.js
```

Each suite names its port at the top (8901–8906). The suites fund wallets by impersonation on the fork and always use **fresh random wallets**. The ten anvil default accounts carry an EIP-7702 delegation on Robinhood Chain mainnet, so they cannot be used on a fork.

## Reproducible verification

`artifacts/<Contract>/<Contract>.input.json` is the exact Solidity standard-JSON input behind the deployed bytecode: `solc 0.8.24`, optimizer on, `evmVersion: cancun`, `viaIR: true`. Submit it to Sourcify (or to Blockscout as "Solidity (Standard JSON input)") to reproduce the match yourself. `scripts/verify-*.js` are the Sourcify scripts we ran. The deploy scripts read the deployer key from the environment (`LAUNCHPAD_OPS_SECRET`) at run time, and no key is stored in this repository.
