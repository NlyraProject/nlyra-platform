# NLYRA Real Yield Staking app (standalone)

This folder is published with GitHub Pages: **https://nlyraproject.github.io/nlyra-platform/staking/**

It is the same app as [nlyra.xyz/newstake/app](https://nlyra.xyz/newstake/app/), built to keep working without any
NLYRA server:

- It reads the chain through the public Robinhood Chain RPC (`https://rpc.mainnet.chain.robinhood.com`).
- Prices come straight from the Uniswap v3 pools the staking contract itself swaps in (WETH/USDG and WETH/NLYRA),
  whose addresses are immutables of the contract.
- Transactions are signed in the user's own wallet and go directly to the verified contracts
  ([`staking-v2/`](../staking-v2)): `RealYieldStaking`, `NlyraFeeSplitter` and `PositionMarket`.
- The daily fee collection (`NlyraFeeSplitter.harvest()`) is permissionless. When it is due, the app shows a
  **Pay it out now** button, so any user can trigger it and only pays the gas.

The contracts have no admin that can move staked funds, and exits are never blocked. Even without this page,
everything can be done from the contract pages on [Blockscout](https://robinhoodchain.blockscout.com/address/0x5CB0Cb16cA019bcff4E494b32575848E4CdB5aF8?tab=contract).

To host your own copy, serve the `staking/` folder from any static web server (or open it locally through one);
it needs no build step and no backend.
