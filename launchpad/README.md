# Architect Launch: tokens born inside a locked pool

**Live at [nlyra.xyz/launch](https://nlyra.xyz/launch).** A creator launches a token with one call. The whole supply is minted as a single-sided concentrated Uniswap-V3-style position, so the token is tradeable from any aggregator from block one, with no bonding curve to graduate from and no migration. The position NFT is owned by a per-launch **vault that has no function to move, decrease or burn it**, so the liquidity is locked forever.

- The pool fee tier is 1%. All of it accrues to the locked position, and `collectFees()` splits it between the creator and the protocol at an immutable ratio. Anyone can trigger the split, and the money always goes to fixed destinations.
- The protocol share goes to the **Buyback Burner**. It has no owner and no withdraw, and anyone can trigger it: it keeps a fixed share for operations and market-buys NLYRA with the rest, sending it to `0x…dEaD`.
- An optional creator first buy happens atomically inside `create()` and is hard-capped at 5% of supply, so nobody can front-run the creator.

## Generations

| Generation | Factory | Status | Source |
|---|---|---|---|
| v4: ETH or USDG pairs, creator fee share, bounty escrow | [`0x4e4A…836f`](https://robinhoodchain.blockscout.com/address/0x4e4AD39E1A38104F8f74C3aF8d3F8c8E27f8836f) | live | [`deployed/launchpad/Launch-Factory-v4-0x4e4AD3/`](../deployed/launchpad/Launch-Factory-v4-0x4e4AD3/) |
| HR: Holder Rewards venue (pool fees stream to holders) | [`0xc641…9398`](https://robinhoodchain.blockscout.com/address/0xc641a5bD946290cA1905A68c4BA3b1d969169398) | live | [`deployed/launchpad/Launch-Factory-HR-Holder-Rewards-0xc641a5/`](../deployed/launchpad/Launch-Factory-HR-Holder-Rewards-0xc641a5/) |
| v2: the design documented in this folder | [`0x5fed…b720`](https://robinhoodchain.blockscout.com/address/0x5fedb61690513D9EA1E0123c39f2E02CDAfEb720) | retired (launches keep running) | [`contracts/ArchitectLaunchPool.sol`](contracts/ArchitectLaunchPool.sol) |
| first deploy of v2 (July 2026) | [`0xd1E5…4D0d`](https://robinhoodchain.blockscout.com/address/0xd1E56b211191dABa8A715D861931173D967a4D0d) | retired | same source |

Presale and bounty contracts, the HR v1 factory and both burners are listed in [`../CONTRACTS.md`](../CONTRACTS.md).

## Contents

| Path | What it is |
|---|---|
| [`contracts/ArchitectLaunchPool.sol`](contracts/ArchitectLaunchPool.sol) | Launch Factory v2 with its token and vault templates, byte-identical to the verified source |
| [`contracts/BuybackBurner.sol`](contracts/BuybackBurner.sol) | The Buyback Burner, byte-identical to the verified source of [`0x371b…1926`](https://robinhoodchain.blockscout.com/address/0x371bB2107f6E021EF2a5a980a9204F5a73151926) |
| [`DEPLOYED_LAUNCHPAD.json`](DEPLOYED_LAUNCHPAD.json) | Record of the first deployment (factory, burner, price-floor constants) |
| [`launch.html`](launch.html) | Single-file static frontend; talks to the chain through the user's wallet |

All launchpad contracts are compiled with `solc 0.8.24`, optimizer 200 runs, and are verified on Blockscout (full match).
