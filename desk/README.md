# The Desk

**[nlyra.xyz/desk](https://nlyra.xyz/desk)**, also available as Telegram Mini Apps (`t.me/LYRAA_AI_bot/desk`, `t.me/LYRAA_AI_bot/bots`).

The Desk is NLYRA's trading terminal for Robinhood Chain. It runs on our own infrastructure: a Robinhood Chain full node synced at the tip, our own indexer, the **risk layer** (a live sell test and Risk Level for every token) and the **NERON** forensic scanner, which indexes and tags every token created on the chain within seconds. From one screen a trader gets:

- charts, trades and holder structure for any token, with NERON's verdict (bundles, fresh-wallet clusters, deployer history);
- the risk layer's sell test and Risk Level; a token that fails the sell test is marked CAN'T SELL and The Desk refuses the buy (enforced off-chain by the hosted service, see [the main README](../README.md#risk-layer-hosted-service-closed-source));
- swaps through the fee router, with the best route across Uniswap V2 / V3 / V4 pools;
- limit orders signed with Permit2, so nothing is escrowed, in ETH or USDG (the generic V2/V3 path accepts any ERC20);
- the bots: spot and infinity grids (ETH- or USDG-quoted), DCA, TWAP, martingale, ladder, Shadow copy trading and the launch sniper, with paper mode to try a bot without funds;
- OTC block trades, on-chain names, referrals and a public leaderboard.

## What is open and what is hosted

> The Desk, the risk layer, the NERON scanner and the bot keepers are operated by us as hosted services (closed source). Everything that holds user funds, the smart contracts, is open, tested and verified on Blockscout.

- **Open (this repository):** every contract The Desk talks to. See [`../CONTRACTS.md`](../CONTRACTS.md) (sections *The Desk* and *Trading bots*), the working sources and fork tests in [`../bots/`](../bots/) and [`../otc/`](../otc/), and the verified sources in [`../deployed/`](../deployed/).
- **Hosted (closed source):** the web app, its API, the indexer, the risk layer, the NERON scanner and the keepers that execute bots. Transactions and verified contracts can be inspected on [Blockscout](https://robinhoodchain.blockscout.com).

## Why that split is safe

- Every trade is signed by the user's own wallet. The Desk never holds a key that can move user funds.
- A bot's escrow can be withdrawn only by its owner, directly on-chain, whether or not The Desk or the keeper is online. The [docs](https://nlyra.xyz/docs) include a rescue guide with the exact call for each contract.
- The keeper key can trigger only the execution paths a bot already authorised (fill, stop-loss, take-profit), under the limits written into the bot.

Public read-only data, with no account needed: [`/api/risk?token=0x…`](https://nlyra.xyz/api/risk?token=0xb9d3824149ad8ac984153ceec91d5a2405d1fb95) · [`/api/desk/stats`](https://nlyra.xyz/api/desk/stats) · [`/api/staking`](https://nlyra.xyz/api/staking) · [`/api/launch/list`](https://nlyra.xyz/api/launch/list) · [`/api/supply/circulating`](https://nlyra.xyz/api/supply/circulating).
