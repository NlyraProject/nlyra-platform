# The Desk bots on BNB Chain

The same non-custodial grid bots that run on Robinhood Chain, ported to BNB Smart Chain (chainId 56) and live since 24 October 2026 behind [nlyra.xyz/bsc](https://nlyra.xyz/bsc): Infinity Grid and Spot Grid on PancakeSwap, in BNB, USDT or USDC, on paper (hosted simulation with live quotes) or for real (a position in one of these contracts, under the user's wallet). Every contract is immutable: no proxy, no upgrade path, no admin withdraw. The keeper can only execute fills inside a bot's own rules; only the owner of a bot can close it.

| Contract | What it does | Address |
|---|---|---|
| [`ArchitectFeeRouterBSC`](src/ArchitectFeeRouterBSC.sol) | The 1% fee router every bot swap goes through: PancakeSwap v2 router, v2 pair direct, v3 pool direct and v3 multi-hop through the SmartRouter. Fees accrue in the quote token for the fee collector. | [`0x0e86…c0E6`](https://bscscan.com/address/0x0e86a190F7D92031CA181A50E5E21DaBB530c0E6#code) |
| [`ArchitectInfinityGridV4BSC`](src/ArchitectInfinityGridV4BSC.sol) | Infinity grid in BNB: no ceiling, floor price, take profit, stop loss, per-bot gas reserve that pays the keeper per fill. | [`0xE878…8a8a`](https://bscscan.com/address/0xE878aa6bE4c5429a5006A516C720A1232Bf18a8a#code) |
| [`ArchitectInfinityGridV41BSC`](src/ArchitectInfinityGridV41BSC.sol) | The same grid quoted in USDT or USDC (`ArchitectBotBaseQ`: ERC-20 quote, fee-on-transfer gate). | [`0x354A…7cBE`](https://bscscan.com/address/0x354Ade1eE04D44B21c037Af8A61189d647027cBE#code) |
| [`ArchitectSpotGridV4BSC`](src/ArchitectSpotGridV4BSC.sol) | Spot grid with a price range, 2 to 60 grids, compounding, gas reserve. | [`0x8a67…37e1`](https://bscscan.com/address/0x8a678c93f745A853865F5718F9fbb6239e1837e1#code) |
| [`ArchitectBotBase`](src/ArchitectBotBase.sol) / [`ArchitectBotBaseQ`](src/ArchitectBotBaseQ.sol) | Shared base: escrow accounting, owner-only withdraw, keeper gate, fee routing, the BSC gas model (price floor and ceiling), `pendingToken` for tokens that refuse a transfer at close. | (inherited) |

Every file in `src/` is byte-identical to the source verified on BscScan for its address; the exact verified copies, with ABI and compiler settings, are in [`../deployed/bsc/`](../deployed/bsc/). The address book, with deploy transactions and blocks, is [`deployments/bsc-addresses.json`](deployments/bsc-addresses.json).

## What changed from Robinhood Chain

The two grids were generated from the verified Robinhood Chain v4 sources with exact replacements: contract names, the PancakeSwap routes instead of Uniswap (no V4 pools, no hooks), WBNB instead of WETH, and the gas model of BNB Chain. Everything else (grid math, escrow, keeper gate, gas reserve, take profit, stop loss, compounding) is the same code. v4.1 adds an ERC-20 quote (USDT, USDC) on top of the same grid.

## Tests

The tests run on a local fork of BNB Chain (anvil, pinned block) with node and ethers. They deploy the contracts on the fork, open bots against real PancakeSwap pools, drive the price and check every fill, the fee accounting, the gas reserve, take profit, stop loss, close and withdraw, and the fee-on-transfer and tax cases with the mock tokens in `src/test/`.

```
anvil --fork-url <bsc rpc> --fork-block-number <block>   # in another shell
node test/forktest-bsc.js      # Infinity Grid v4 + Spot Grid v4 + fee router
node test/forktest-v41.js      # Infinity Grid v4.1 (USDT / USDC quote)
node test/spot-fork.js         # Spot Grid: range, grids, keeper work, close
node test/tp-fot-fork.js       # take profit + fee-on-transfer tokens
node test/fot-routes-fork.js   # PancakeSwap routes with tax tokens
```

Compiler: solc 0.8.24, optimizer 200 runs, viaIR, EVM cancun ([`foundry.toml`](foundry.toml)): the same toolchain as the Robinhood Chain contracts.

## Operational addresses on BNB Chain

| | |
|---|---|
| Keeper (executes fills, cannot withdraw) | `0xfBc9CFf9579578C942cf9E7ab30189EAb8c0714B` |
| Treasury / deployer / owner | `0xe30647793192D15BFA6E53aE8651368d332fe04C` (same as on Robinhood Chain) |
| Fee collector (being set up) | `0xbf98Df1Ff6072C7278c58536Ac6dd8C155198d62`: fees are swapped to BNB, bridged to Robinhood Chain and sent to the Fee Splitter, which pays 50% to NLYRA stakers |
