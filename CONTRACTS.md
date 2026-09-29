# Contracts

Every contract NLYRA has deployed on **Robinhood Chain** (chainId 4663), with its source in this repository and its verification link.

- **Status:** `live` is in use. `retired` is replaced: no new positions are opened, but existing positions can still be closed or withdrawn. `pre-launch` is written and tested, not deployed.
- **User funds:** `yes` means the contract holds user funds (escrow, pool, bankroll). `moves` means it routes user funds within one transaction and keeps no balance. `protocol fees` means it holds only protocol revenue.
- **Source:** each `deployed/…` folder holds the exact source that Blockscout (or Sourcify) verified for that address, plus `compiler.json`, the ABI and a short README. Where a working copy with tests exists, it is linked in that README.
- **Verification:** checked on 2026-09-28 through the Blockscout and Sourcify APIs. Every contract that holds or moves user funds is verified on Blockscout, Sourcify or both.

Machine-readable address book: [`deployments/desk-addresses.json`](deployments/desk-addresses.json).

## The Desk — routing, orders, names, predictions

| Contract | Address | What it does | User funds | Source | Blockscout | Status |
|---|---|---|---|---|---|---|
| Fee Router v2 | `0x9d1eA9Abbb99D813b7acA7666285CDed7f833565` | Every Desk trade and every bot swap routes through it (Uniswap V2/V3/V4 on Robinhood Chain); 1% fee per executed trade, 30% of it credited to the referrer. | moves | [`Fee-Router-v2-0x9d1eA9/`](deployed/desk/Fee-Router-v2-0x9d1eA9/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0x9d1eA9Abbb99D813b7acA7666285CDed7f833565) | live |
| Fee Router v1 | `0x513969D81C0F7D490790274203221C1551663690` | First fee router, replaced by v2. | moves | [`Fee-Router-v1-0x513969/`](deployed/desk/Fee-Router-v1-0x513969/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0x513969D81C0F7D490790274203221C1551663690) | retired |
| Limit Orders v2 | `0xAd100f712FA482938adCe1dc08B3B30C8834cBBb` | Gasless limit orders signed as a Permit2 witness; nothing is escrowed, a keeper fills when the price is met. | moves | [`Limit-Orders-v2-0xAd100f/`](deployed/desk/Limit-Orders-v2-0xAd100f/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0xAd100f712FA482938adCe1dc08B3B30C8834cBBb) | live |
| Limit Orders v1 | `0xD2C409Dfa5e37C094166B9e556086bA018b2cd09` | First limit-order settlement contract, replaced by v2. | moves | [`Limit-Orders-v1-0xD2C409/`](deployed/desk/Limit-Orders-v1-0xD2C409/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0xD2C409Dfa5e37C094166B9e556086bA018b2cd09) | retired |
| Registry | `0x80d4dCbc9814f1bCA48C0f10f70B36BF3bc09fAF` | On-chain @names (one handle per wallet) used for referrals, the leaderboard and copy trading. | no | [`Registry-0x80d4dC/`](deployed/desk/Registry-0x80d4dC/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0x80d4dCbc9814f1bCA48C0f10f70B36BF3bc09fAF) | live |
| Predict | `0x688c265886776005eaF321c7121bF2D1b76676A1` | BTC up/down in 5-minute rounds; the pot is escrowed while a round is open, winners split it minus 3%, unresolvable rounds refund. | yes | [`Predict-0x688c26/`](deployed/desk/Predict-0x688c26/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0x688c265886776005eaF321c7121bF2D1b76676A1) | live |
| Predict Oracle | `0xCC85d7B57819921f2D173134D0e21eca8A7B4F96` | Price each Predict round settles on; a posted price more than 10% away from the on-chain anchor is rejected. | no | [`Predict-Oracle-0xCC85d7/`](deployed/desk/Predict-Oracle-0xCC85d7/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0xCC85d7B57819921f2D173134D0e21eca8A7B4F96) | live |
| Predict (first deploy) | `0x93467d80EA3Dd3C6F04e310d821B4e2E6662F602` | Deployed and abandoned before use; listed so nobody mistakes it for the live one. | no | [`Predict-first-deploy-0x93467d/`](deployed/desk/Predict-first-deploy-0x93467d/) | [Sourcify exact](https://repo.sourcify.dev/4663/0x93467d80EA3Dd3C6F04e310d821B4e2E6662F602) (not on [Blockscout](https://robinhoodchain.blockscout.com/address/0x93467d80EA3Dd3C6F04e310d821B4e2E6662F602)) | retired |

## Trading bots

| Contract | Address | What it does | User funds | Source | Blockscout | Status |
|---|---|---|---|---|---|---|
| Spot Grid v4 (compound) | `0xF8ef52605FBcc968B24b7FdBD7e93c752A659D5f` | Spot grid with compounding and a per-bot gas reserve that pays the keeper for each fill. | yes | [`Spot-Grid-v4-compound-0xF8ef52/`](deployed/bots/Spot-Grid-v4-compound-0xF8ef52/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0xF8ef52605FBcc968B24b7FdBD7e93c752A659D5f) | live |
| Infinity Grid v4 (compound) | `0xBdC77e3D589D161489f7C986d8f654F30b88DDeb` | Infinity grid (no ceiling) where every realized gain grows the position; per-bot gas reserve. | yes | [`Infinity-Grid-v4-compound-0xBdC77e/`](deployed/bots/Infinity-Grid-v4-compound-0xBdC77e/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0xBdC77e3D589D161489f7C986d8f654F30b88DDeb) | live |
| Shadow (copy trading) | `0xE26dd0A09Cd7bA2F7d0a31e4B625E983B0B1B3D2` | Mirrors the swaps of a chosen wallet from the follower's own escrow, with per-position stop-loss / take-profit. | yes | [`Shadow-copy-trading-0xE26dd0/`](deployed/bots/Shadow-copy-trading-0xE26dd0/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0xE26dd0A09Cd7bA2F7d0a31e4B625E983B0B1B3D2) | live |
| Sniper v2 | `0x6B30B0946743eF8A2D323127c8CfaC9966b5C84c` | Configurable launch sniper (Pons bonding curves and router pools) under the owner's own limits. | yes | [`Sniper-v2-0x6B30B0/`](deployed/bots/Sniper-v2-0x6B30B0/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0x6B30B0946743eF8A2D323127c8CfaC9966b5C84c) | live |
| Sniper v1 | `0x2E47eA1ACAbAa69c12a2F051F9c685884497f1f5` | First deploy; paused for good after the security review, never held a bot. | no | [`Sniper-v1-0x2E47eA/`](deployed/bots/Sniper-v1-0x2E47eA/) | [Sourcify exact](https://repo.sourcify.dev/4663/0x2E47eA1ACAbAa69c12a2F051F9c685884497f1f5) (not on [Blockscout](https://robinhoodchain.blockscout.com/address/0x2E47eA1ACAbAa69c12a2F051F9c685884497f1f5)) | retired |
| SendTo v2 | `0x0eF655f16345afb66b42d4e65B71a16052d1Ddc0` | Router wrapper: buy or sell from one wallet and deliver the output to another. Holds nothing between transactions. | moves | [`SendTo-v2-0x0eF655/`](deployed/bots/SendTo-v2-0x0eF655/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0x0eF655f16345afb66b42d4e65B71a16052d1Ddc0) | live |
| SendTo v1 | `0xb7F767fE61138026B6D430FC2D2381364cbe3596` | First deploy; disabled on the router (it bound the router referral to the contract on the ETH paths). | moves | [`SendTo-v1-0xb7F767/`](deployed/bots/SendTo-v1-0xb7F767/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0xb7F767fE61138026B6D430FC2D2381364cbe3596) | retired |
| Spot Grid USDG | `0xdd13354cfE3E79a944d8F93476176F016f6311e4` | The v3 spot grid quoted in USDG (funded in USDG, profit banked in USDG). | yes | [`Spot-Grid-USDG-0xdd1335/`](deployed/bots/Spot-Grid-USDG-0xdd1335/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0xdd13354cfE3E79a944d8F93476176F016f6311e4) | live |
| Infinity Grid USDG | `0x551C66EF613c283FC439AE21DFa9C54c6f6b19a3` | The v3 infinity grid quoted in USDG, with floor price, take-profit and stop-loss. | yes | [`Infinity-Grid-USDG-0x551C66/`](deployed/bots/Infinity-Grid-USDG-0x551C66/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0x551C66EF613c283FC439AE21DFa9C54c6f6b19a3) | live |
| DCA v2 | `0x630d58f9B8Cb55D8e246268F52596AFc3471fc1d` | Equal buys on a schedule, delivered to the wallet or held for a take-profit; v2 adds stop-loss. | yes | [`DCA-v2-0x630d58/`](deployed/bots/DCA-v2-0x630d58/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0x630d58f9B8Cb55D8e246268F52596AFc3471fc1d) | live |
| Martingale v2 | `0x056A87cB9974f78fa4185BCe2e14807cBE357F8F` | Buys bigger on each step down and sells the lot at the target; v2 adds stop-loss. | yes | [`Martingale-v2-0x056A87/`](deployed/bots/Martingale-v2-0x056A87/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0x056A87cB9974f78fa4185BCe2e14807cBE357F8F) | live |
| TWAP | `0xF8bE45D8da70745B9Df1CF17848dfcDD4b4C2309` | One large order sliced over time; stop returns every unexecuted slice. | yes | [`TWAP-0xF8bE45/`](deployed/bots/TWAP-0xF8bE45/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0xF8bE45D8da70745B9Df1CF17848dfcDD4b4C2309) | live |
| Ladder | `0x9730274e9aB060eB2C9CC3417f85A323aeF7bB6C` | Stacked buy orders at descending prices, ETH held per rung; cancel returns every unfilled rung. | yes | [`Ladder-0x973027/`](deployed/bots/Ladder-0x973027/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0x9730274e9aB060eB2C9CC3417f85A323aeF7bB6C) | live |
| Spot Grid v3 | `0x994Cf0A4f0E876f52f3b76a2856D93924DA71511` | Previous spot grid; open grids keep working and can be stopped/withdrawn. | yes | [`Spot-Grid-v3-0x994Cf0/`](deployed/bots/Spot-Grid-v3-0x994Cf0/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0x994Cf0A4f0E876f52f3b76a2856D93924DA71511) | retired |
| Spot Grid v1 | `0xC0A3cE7e18FeE382432a18F750756E296D44dD4b` | First spot grid; grids opened before v3, same stop call. | yes | [`Spot-Grid-v1-0xC0A3cE/`](deployed/bots/Spot-Grid-v1-0xC0A3cE/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0xC0A3cE7e18FeE382432a18F750756E296D44dD4b) | retired |
| Infinity Grid v3 | `0x177a8837c0444e18677b618624C2a853573d2D7D` | Previous infinity grid (floor, take-profit, stop-loss); existing bots can still be stopped. | yes | [`Infinity-Grid-v3-0x177a88/`](deployed/bots/Infinity-Grid-v3-0x177a88/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0x177a8837c0444e18677b618624C2a853573d2D7D) | retired |
| Infinity Grid v2 | `0x6C56f98FF2A3867B43aFf8Cad47EC2b6da81E1ab` | Earlier infinity grid. | yes | [`Infinity-Grid-v2-0x6C56f9/`](deployed/bots/Infinity-Grid-v2-0x6C56f9/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0x6C56f98FF2A3867B43aFf8Cad47EC2b6da81E1ab) | retired |
| Infinity Grid v1 | `0x5B8555f254AbD8c4B2a25ca6595Cc4025308584c` | First infinity grid. | yes | [`Infinity-Grid-v1-0x5B8555/`](deployed/bots/Infinity-Grid-v1-0x5B8555/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0x5B8555f254AbD8c4B2a25ca6595Cc4025308584c) | retired |
| DCA v1 | `0x07D52Ced2EA760187Fa83D5AA96A4B8174124a0d` | First DCA contract. | yes | [`DCA-v1-0x07D52C/`](deployed/bots/DCA-v1-0x07D52C/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0x07D52Ced2EA760187Fa83D5AA96A4B8174124a0d) | retired |
| Martingale v1 | `0xad55Ab54B38F6eE5aB8408de627C0CE20aeF5Cef` | First martingale; still holds cycles opened before v2 (same withdraw). | yes | [`Martingale-v1-0xad55Ab/`](deployed/bots/Martingale-v1-0xad55Ab/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0xad55Ab54B38F6eE5aB8408de627C0CE20aeF5Cef) | retired |
| Ladder (first deploy) | `0xE988A365DbD77D28fD518074215866D675a5639E` | Deployed and abandoned before use; never held funds. Not verified; no source published. | no | not published | [not verified](https://robinhoodchain.blockscout.com/address/0xE988A365DbD77D28fD518074215866D675a5639E) | retired |

## OTC Desk

| Contract | Address | What it does | User funds | Source | Blockscout | Status |
|---|---|---|---|---|---|---|
| OTC Desk | `0x9656513aC910a9839B51dB7c92a6914ABB4F52e8` | Peer-to-peer block trades settled atomically from a non-custodial escrow (ETH / USDG / NLYRA); 0.5% fee buys and burns NLYRA. | yes | [`OTC-Desk-0x965651/`](deployed/otc/OTC-Desk-0x965651/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0x9656513aC910a9839B51dB7c92a6914ABB4F52e8) | live |

## Launchpad, presale and bounties

| Contract | Address | What it does | User funds | Source | Blockscout | Status |
|---|---|---|---|---|---|---|
| Launch Factory v4 | `0x4e4AD39E1A38104F8f74C3aF8d3F8c8E27f8836f` | Current launchpad: pool-born tokens (ETH or USDG pairs), LP locked forever in a per-launch vault, creator fee share. Contains the token and vault templates. | yes | [`Launch-Factory-v4-0x4e4AD3/`](deployed/launchpad/Launch-Factory-v4-0x4e4AD3/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0x4e4AD39E1A38104F8f74C3aF8d3F8c8E27f8836f) | live |
| Launch Factory HR (Holder Rewards) | `0xc641a5bD946290cA1905A68c4BA3b1d969169398` | Holder Rewards venue: launched tokens stream pool fees to holders through a rewards distributor. Rebuilt 2026-08-27. | yes | [`Launch-Factory-HR-Holder-Rewards-0xc641a5/`](deployed/launchpad/Launch-Factory-HR-Holder-Rewards-0xc641a5/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0xc641a5bD946290cA1905A68c4BA3b1d969169398) | live |
| Launch Factory HR v1 | `0x68F93ED8C4FB60f6402CaDB6d0C56ca8C199EF90` | First Holder Rewards factory, replaced on 2026-08-27 after a swap-callback guard issue; its launches keep their locked LP. | yes | [`Launch-Factory-HR-v1-0x68F93E/`](deployed/launchpad/Launch-Factory-HR-v1-0x68F93E/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0x68F93ED8C4FB60f6402CaDB6d0C56ca8C199EF90) | retired |
| Launch Factory v2 | `0x5fedb61690513D9EA1E0123c39f2E02CDAfEb720` | Earlier launchpad generation; its launches keep running side by side with v4. | yes | [`Launch-Factory-v2-0x5fedb6/`](deployed/launchpad/Launch-Factory-v2-0x5fedb6/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0x5fedb61690513D9EA1E0123c39f2E02CDAfEb720) | retired |
| Launch Factory (first deploy) | `0xd1E56b211191dABa8A715D861931173D967a4D0d` | First launchpad deployment (July 2026); its vaults keep their locked LP. | yes | [`Launch-Factory-first-deploy-0xd1E56b/`](deployed/launchpad/Launch-Factory-first-deploy-0xd1E56b/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0xd1E56b211191dABa8A715D861931173D967a4D0d) | retired |
| Buyback Burner | `0x371bB2107f6E021EF2a5a980a9204F5a73151926` | Launchpad treasury with no owner: 50% ops / 50% market-buys NLYRA to 0xdEaD; anyone can trigger it. | protocol fees | [`Buyback-Burner-0x371bB2/`](deployed/launchpad/Buyback-Burner-0x371bB2/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0x371bB2107f6E021EF2a5a980a9204F5a73151926) | live |
| Buyback Burner (first deploy) | `0xEb733465797c02146786F453DbC4aD1B701aA36e` | Burner of the first launchpad deployment. | protocol fees | [`Buyback-Burner-first-deploy-0xEb7334/`](deployed/launchpad/Buyback-Burner-first-deploy-0xEb7334/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0xEb733465797c02146786F453DbC4aD1B701aA36e) | retired |
| Bounty Escrow | `0xf01a4bD90aeF8dD75FCb1EA6a3865Ac4b72DFF2c` | Community bounties escrowed in USDG; no admin withdraw, rejections auto-refund. | yes | [`Bounty-Escrow-0xf01a4b/`](deployed/launchpad/Bounty-Escrow-0xf01a4b/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0xf01a4bD90aeF8dD75FCb1EA6a3865Ac4b72DFF2c) | live |
| Presale Factory | `0x06d3C711aAFC522931FAA6De895B8755cB84556f` | Architect Presale: contributions sit in the presale contract (never with the creator); soft cap refunds, the raise seeds locked liquidity. | yes | [`Presale-Factory-0x06d3C7/`](deployed/launchpad/Presale-Factory-0x06d3C7/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0x06d3C711aAFC522931FAA6De895B8755cB84556f) | live |

## Staking and vaults

| Contract | Address | What it does | User funds | Source | Blockscout | Status |
|---|---|---|---|---|---|---|
| StakingRewards (NLYRA staking v1) | `0x5e63228add4390f77BbcDb364F6A7b42bA7Aa3ef` | Single-sided NLYRA staking (Synthetix StakingRewards pattern); no owner migration path. | yes | [`StakingRewards-NLYRA-staking-v1-0x5e6322/`](deployed/staking/StakingRewards-NLYRA-staking-v1-0x5e6322/) | [verified (partial)](https://robinhoodchain.blockscout.com/address/0x5e63228add4390f77BbcDb364F6A7b42bA7Aa3ef) | live |
| Stake Pool Factory | `0x8347e6CD205C0D5CA68A0481B8292992A46519c2` | Architect Stake: deploys one fixed-APY pool per token; each stake pre-locks its full reward. | yes | [`Stake-Pool-Factory-0x8347e6/`](deployed/staking/Stake-Pool-Factory-0x8347e6/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0x8347e6CD205C0D5CA68A0481B8292992A46519c2) | live |
| LYRA Liquidity Vault v2 | `0xAa633E2Ed66A90d39a58cF183df01B7EC3d6756A` | Invest with LYRA: ETH deposits for shares, deployed only as LP in whitelisted WETH pools; withdrawals pay actual proceeds. | yes | [`LYRA-Liquidity-Vault-v2-0xAa633E/`](deployed/staking/LYRA-Liquidity-Vault-v2-0xAa633E/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0xAa633E2Ed66A90d39a58cF183df01B7EC3d6756A) | live |
| LYRA Liquidity Vault v1 | `0x277Db43abE111744b1Fb7C2683c9244268ed24a6` | First version of the liquidity vault (legacy on /invest). | yes | [`LYRA-Liquidity-Vault-v1-0x277Db4/`](deployed/staking/LYRA-Liquidity-Vault-v1-0x277Db4/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0x277Db43abE111744b1Fb7C2683c9244268ed24a6) | retired |
| Real Yield Staking v2 | `0x5CB0Cb16cA019bcff4E494b32575848E4CdB5aF8` | 50% of NLYRA creator trading fees streamed to stakers; lock tiers, compound bonus, position transfers and a Position Market. Internal audits in the folder. | yes | [`staking-v2/src/`](staking-v2/src/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0x5CB0Cb16cA019bcff4E494b32575848E4CdB5aF8) | live (closed beta) |
| NLYRA Fee Splitter | `0x8300Ef5cC02cAb1D141dBE1c0B33d8Ac115F2D48` | Harvests the NLYRA creator fees and splits them between stakers and the treasury. | moves | [`staking-v2/src/`](staking-v2/src/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0x8300Ef5cC02cAb1D141dBE1c0B33d8Ac115F2D48) | live (closed beta) |
| Position Market | `0x3BcA70536aC7FfB44023e971d204dAb7c23E95D7` | Marketplace for locked staking positions; 0.5% fee goes back into the split. | moves | [`staking-v2/src/`](staking-v2/src/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0x3BcA70536aC7FfB44023e971d204dAb7c23E95D7) | live (closed beta) |

## Lyra Shield (Privacy Pools)

| Contract | Address | What it does | User funds | Source | Blockscout | Status |
|---|---|---|---|---|---|---|
| Shield Entrypoint (proxy) | `0x9c03515e1C7Aa04ADccCD1293bE4EA0Dd8f522F2` | ERC1967 proxy users interact with: deposits, association-set root, relayed withdrawals. | moves | [`Shield-Entrypoint-proxy-0x9c0351/`](deployed/shield/Shield-Entrypoint-proxy-0x9c0351/) | [verified (partial)](https://robinhoodchain.blockscout.com/address/0x9c03515e1C7Aa04ADccCD1293bE4EA0Dd8f522F2) | live |
| Shield Entrypoint (implementation) | `0xda1e76Aeb6D7B78Fd6474912E4b6863eFa29D349` | Privacy Pools Entrypoint implementation behind the proxy. | moves | [`Shield-Entrypoint-implementation-0xda1e76/`](deployed/shield/Shield-Entrypoint-implementation-0xda1e76/) | [verified (partial)](https://robinhoodchain.blockscout.com/address/0xda1e76Aeb6D7B78Fd6474912E4b6863eFa29D349) | live |
| Shield Pool (PrivacyPoolComplex) | `0x6e179E19e594e82AB732646b898268F6Fb569E58` | Holds the shielded NLYRA; no owner withdraw; only zk proofs (or ragequit to the depositor) move funds. | yes | [`Shield-Pool-PrivacyPoolComplex-0x6e179E/`](deployed/shield/Shield-Pool-PrivacyPoolComplex-0x6e179E/) | [verified (partial)](https://robinhoodchain.blockscout.com/address/0x6e179E19e594e82AB732646b898268F6Fb569E58) | live |
| WithdrawalVerifier (Groth16) | `0xe8868719Dc0aaCa1f7c8aef0dfe9304AF57cA1Cb` | Zero-knowledge withdrawal verifier (0xbow Privacy Pools circuits). | no | [`WithdrawalVerifier-Groth16-0xe88687/`](deployed/shield/WithdrawalVerifier-Groth16-0xe88687/) | [verified (partial)](https://robinhoodchain.blockscout.com/address/0xe8868719Dc0aaCa1f7c8aef0dfe9304AF57cA1Cb) | live |
| CommitmentVerifier (ragequit) | `0xd1E125953bE2eEe7e59cAEF4789949e70402BEF4` | Groth16 verifier for ragequit proofs. | no | [`CommitmentVerifier-ragequit-0xd1E125/`](deployed/shield/CommitmentVerifier-ragequit-0xd1E125/) | [verified (partial)](https://robinhoodchain.blockscout.com/address/0xd1E125953bE2eEe7e59cAEF4789949e70402BEF4) | live |
| PoseidonT3 | `0x43c6f2bc0E1ea13c35F152892BdED810a0C68939` | Poseidon hash library (poseidon-solidity). | no | [`PoseidonT3-0x43c6f2/`](deployed/shield/PoseidonT3-0x43c6f2/) | [verified (partial)](https://robinhoodchain.blockscout.com/address/0x43c6f2bc0E1ea13c35F152892BdED810a0C68939) | live |
| PoseidonT4 | `0xb4E36ec6E801aF084A9c850C63BB71211A646CCE` | Poseidon hash library (poseidon-solidity). | no | [`PoseidonT4-0xb4E36e/`](deployed/shield/PoseidonT4-0xb4E36e/) | [verified (partial)](https://robinhoodchain.blockscout.com/address/0xb4E36ec6E801aF084A9c850C63BB71211A646CCE) | live |

## DEX (Uniswap V2 and V3, deployed verbatim)

| Contract | Address | What it does | User funds | Source | Blockscout | Status |
|---|---|---|---|---|---|---|
| UniswapV2Factory | `0xfa6253ee74F7956b022998F7bfa271990C8A82a8` | Uniswap V2 core, deployed verbatim; creates every V2 pair (pairs hold the liquidity). | yes | [`UniswapV2Factory-0xfa6253/`](deployed/dex/UniswapV2Factory-0xfa6253/) | [verified (partial)](https://robinhoodchain.blockscout.com/address/0xfa6253ee74F7956b022998F7bfa271990C8A82a8) | live |
| UniswapV2Router02 | `0xA5deC66ECa62AE363dC47965bB790C3B8870b6B6` | Uniswap V2 periphery, deployed verbatim; swaps and liquidity for /dex. | moves | [`UniswapV2Router02-0xA5deC6/`](deployed/dex/UniswapV2Router02-0xA5deC6/) | [verified (partial)](https://robinhoodchain.blockscout.com/address/0xA5deC66ECa62AE363dC47965bB790C3B8870b6B6) | live |
| UniswapV3Factory | `0x3FdaBf7AB5d871B89F1d9DA04Dc2E0733dB70CaF` | Uniswap V3 core, deployed verbatim (Architect Swap). | yes | [`UniswapV3Factory-0x3FdaBf/`](deployed/dex/UniswapV3Factory-0x3FdaBf/) | [verified (partial)](https://robinhoodchain.blockscout.com/address/0x3FdaBf7AB5d871B89F1d9DA04Dc2E0733dB70CaF) | live |
| SwapRouter (V3) | `0x4D0d17F66d1da788da50CF5217894F36684F958E` | Uniswap V3 periphery SwapRouter, deployed verbatim. | moves | [`SwapRouter-V3-0x4D0d17/`](deployed/dex/SwapRouter-V3-0x4D0d17/) | [verified (partial)](https://robinhoodchain.blockscout.com/address/0x4D0d17F66d1da788da50CF5217894F36684F958E) | live |
| NonfungiblePositionManager (V3) | `0x4b71BE063E72b0BE36F690535C9C0cE533A9FB5C` | Uniswap V3 positions NFT, deployed verbatim. | yes | [`NonfungiblePositionManager-V3-0x4b71BE/`](deployed/dex/NonfungiblePositionManager-V3-0x4b71BE/) | [verified (partial)](https://robinhoodchain.blockscout.com/address/0x4b71BE063E72b0BE36F690535C9C0cE533A9FB5C) | live |
| QuoterV2 (V3) | `0x7346b0435f165D33c5b8166fA227A3224646891F` | Uniswap V3 read-only quoter, deployed verbatim. | no | [`QuoterV2-V3-0x7346b0/`](deployed/dex/QuoterV2-V3-0x7346b0/) | [verified (partial)](https://robinhoodchain.blockscout.com/address/0x7346b0435f165D33c5b8166fA227A3224646891F) | live |

## Games

| Contract | Address | What it does | User funds | Source | Blockscout | Status |
|---|---|---|---|---|---|---|
| Lyra Roulette v2 | `0x4556051598F568f2626809552d25F8d44BdE0394` | Commit-reveal roulette; the contract holds the bankroll and pays winners itself. | yes | [`Lyra-Roulette-v2-0x455605/`](deployed/games/Lyra-Roulette-v2-0x455605/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0x4556051598F568f2626809552d25F8d44BdE0394) | live |
| Lyra Slots v2 | `0xC1854d1f194FD38A5A8F3F32432fF97c83C380B3` | Slot machine with public reel weights and payouts; the contract holds the bankroll. | yes | [`Lyra-Slots-v2-0xC1854d/`](deployed/games/Lyra-Slots-v2-0xC1854d/) | [verified (full)](https://robinhoodchain.blockscout.com/address/0xC1854d1f194FD38A5A8F3F32432fF97c83C380B3) | live |

## Tokens and third-party contracts we use (not ours)

| Contract | Address | Note |
|---|---|---|
| $NLYRA token | `0xb9d3824149ad8ac984153ceec91d5a2405d1fb95` | Launched on Pons; fixed supply of 1,000,000,000, no owner, no mint, no transfer tax. Token code is the Pons launcher template ([Blockscout](https://robinhoodchain.blockscout.com/address/0xb9d3824149ad8ac984153ceec91d5a2405d1fb95)). |
| PonsLaunchLocker | `0x736D76699C26D0d966744cAe304C000d471f7F35` | Holds the NLYRA launch liquidity position; owned by Pons ([Blockscout](https://robinhoodchain.blockscout.com/address/0x736D76699C26D0d966744cAe304C000d471f7F35)). |
| WETH | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` | Canonical wrapped ETH on Robinhood Chain. |
| USDG | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` | Paxos Global Dollar. |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` | Uniswap canonical Permit2; limit orders are signed against it. |

## Operational addresses (wallets, not contracts)

| Role | Address | Can do |
|---|---|---|
| Bot keeper | `0x96D0B8008d1E38d45A1B9cFCCCC932629059246c` | Trigger the fill / stop-loss / take-profit paths a bot already authorised. It cannot withdraw or change parameters. |
| Desk contracts owner | `0xa6CD59b326F8bc5Cf68EcD2377Eee13AfBbb1657` | Owner of the fee routers, limit orders, bot contracts and Predict: pause, fee band (hard ceiling 3%), referrer share, treasury address, surplus-only rescue. No code path into user escrow; nothing is upgradeable. |
| Treasury | `0xe30647793192D15BFA6E53aE8651368d332fe04C` | Fee treasury; owner of Roulette, Slots and the staking reward distributor. |

Ownership sits on single keys, not a multisig. The public docs at [nlyra.xyz/docs](https://nlyra.xyz/docs#admin-powers) list each admin power per contract.
