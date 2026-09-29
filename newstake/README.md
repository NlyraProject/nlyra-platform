# Real Yield Staking v2: public preview page

**Live preview at [nlyra.xyz/newstake](https://nlyra.xyz/newstake).** This is the static page for [Real Yield Staking v2](../staking-v2/), which is **pre-launch**: its contracts are written, tested and internally audited, but not deployed.

The page explains the model (50% of NLYRA's creator trading fees streamed to stakers, no inflation, no printed rewards). It also shows live market data and a yield estimator. Until v2 is deployed, the numbers are a simulation at the last-7-day fee rate, and the page labels them as such. The current staking contract (StakingRewards, [`0x5e63…a3ef`](https://robinhoodchain.blockscout.com/address/0x5e63228add4390f77BbcDb364F6A7b42bA7Aa3ef)) stays live at [nlyra.xyz/staking](https://nlyra.xyz/staking).

| File | What it is |
|---|---|
| [`index.html`](index.html) | Page markup |
| [`newstake.js`](newstake.js) | Market data and the yield simulation (read-only, no wallet transactions) |
| [`newstake.css`](newstake.css) | Styles (NLYRA brand tokens) |
| [`dual-core.svg`](dual-core.svg), [`og.png`](og.png) | Logo and social card |
