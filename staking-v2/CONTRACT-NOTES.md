# Real Yield Staking v2: contract notes in English

The explanatory comments inside the Solidity sources in [`src/`](src) are written in Spanish. This document is
their English companion: every explanatory note in the four audited files, translated and kept in code order,
with the line numbers where each note sits.

The `.sol` files themselves are intentionally left as they are. They are byte for byte the sources verified on
Blockscout and Sourcify for the deployed contracts (commit `19880c0`), and editing even a comment would break that
match. Line numbers below refer to that commit. Publishing these notes was recommended by the Coinsult audit
(finding RYSI1).

| Contract | Address |
|---|---|
| `RealYieldStaking` | [`0x5CB0Cb16cA019bcff4E494b32575848E4CdB5aF8`](https://robinhoodchain.blockscout.com/address/0x5CB0Cb16cA019bcff4E494b32575848E4CdB5aF8) |
| `NlyraFeeSplitter` | [`0x8300Ef5cC02cAb1D141dBE1c0B33d8Ac115F2D48`](https://robinhoodchain.blockscout.com/address/0x8300Ef5cC02cAb1D141dBE1c0B33d8Ac115F2D48) |
| `PositionMarket` | [`0x3BcA70536aC7FfB44023e971d204dAb7c23E95D7`](https://robinhoodchain.blockscout.com/address/0x3BcA70536aC7FfB44023e971d204dAb7c23E95D7) |

Contents: [RealYieldStaking](#1-realyieldstakingsol) · [NlyraFeeSplitter](#2-nlyrafeesplittersol) ·
[PositionMarket](#3-positionmarketsol) · [External interfaces](#4-interfacesexternalsol)

---

## 1. `RealYieldStaking.sol`

### Overview (L13–L33)

**RealYieldStaking** (NLYRA staking v2, including the fixes from the internal audits of September 27 and 28).
You stake NLYRA and earn WETH and NLYRA from the token's real trading fees.

- **Rewards are paid in tranches.** Each notify creates a tranche that pays out the new amount over exactly
  7 days, with its own rate and its own end. The splitter opens at most one per day and `sweepDonations()` at most
  one more per day, so there are never more than 14 active tranches (the cap is 16).
- **Tiers:** flexible 1× (2-day cooldown), 7-day lock 1.25×, 14-day lock 1.5×, 30-day lock 2×. Locks expire at
  the UTC midnight after their 7, 14 or 30 days, and the boost switches off at exactly that moment: for the total
  weight with no keeper needed, and for the user when they are settled at the expiry time (on their next action,
  or through `kick`).
- **Exiting always goes through the 2-day cooldown**, both for the flexible stake and for expired locks.
- **`compound(minOut, tier, positionId)`:** a 5% bonus from the reserve is paid ONLY when compounding into the
  30-day lock, and ONLY on rewards earned from the fees the splitter sent (never on donations or loose balance).
  You can compound into an open lock without using a new slot.
- **Round 3:** a lock can be passed to another wallet in two steps (`offerPosition` → `acceptPosition`). What it
  earned up to that moment stays with the sender; the receiver earns from the transfer onwards. This is what
  enables `PositionMarket` (a separate contract), which buys on the buyer's behalf through `acceptPositionTo`.

**Solvency.** NLYRA is both the staked token and a reward token, so the contract keeps:

```
NLYRA.balance >= totalStaked + totalCooling + bonusReserve + (distributed - paid)[NLYRA] + pending tranche amounts
WETH.balance  >=                                               (distributed - paid)[WETH]  + pending tranche amounts
```

Tranches only distribute the free balance (balance minus accrued debt minus what the open tranches still have to
pay). Besides the two reward flows (WETH and NLYRA), the contract also tracks the part of each one that is
**eligible for the compound bonus** (what came from the splitter), using the same engine: indices 2 and 3 of
`rate` / `rewardPerBoosted` / `rewards`.

### Parameters (L37–L89)

| Constant | Value | Note |
|---|---|---|
| `REWARD_DURATION` | 7 days | every tranche streams over exactly 7 days |
| `UNSTAKE_COOLDOWN` | 2 days | |
| `LOCK_7` / `LOCK_14` / `LOCK_30` | 7 / 14 / 30 days | |
| `BOOST_FLEX` / `BOOST_7` / `BOOST_14` / `BOOST_30` | 1× / 1.25× / 1.5× / 2× | in basis points (10,000 = 1×) |
| `COMPOUND_BONUS_BPS` | 500 | +5%, only on compounds into the 30-day lock |
| `MAX_POSITIONS` | 32 | OPEN locks per wallet; freed slots are reused |
| `MAX_TRANCHES` | 16 | |
| `MIN_NOTIFY_WETH` / `MIN_NOTIFY_NLYRA` | 1e12 / 1e18 | if the new amount is below both, no tranche is opened |
| `DONATION_INTERVAL` | 1 day | `sweepDonations` opens at most one tranche per day |
| `MAX_PAUSE` | 30 days | a pause expires on its own |
| `PAUSE_GAP` | 30 days | after a pause ends, 30 open days must pass before another one |
| `NEW_POSITION` | `type(uint256).max` | `compound`: open a new lock |
| `UNI_V3_FACTORY`, `POOL_INIT_CODE_HASH` | | the Uniswap v3 factory on Robinhood Chain and the pool init code hash: the canonical v3-core value, checked against both real pools (`CREATE2(factory, salt, hash) == pool`) |
| `FEE_NLYRA_POOL` / `FEE_USDG_POOL` | 10,000 / 100 | WETH/NLYRA 1% pool, WETH/USDG 0.01% pool |
| `T_POOL`, `T_TOKEN`, `T_AMOUNT`, `T_DIR` | | transient-storage slots for the swap in progress: expected pool, input token, exact amount to pay, direction (`zeroForOne`) |

**`OutMode`** (how a claim is paid):

- `AS_IS`: WETH and NLYRA as they are.
- `ALL_ETH`: everything in WETH (the NLYRA is sold in the WETH/NLYRA pool).
- `ALL_NLYRA`: everything in NLYRA (the WETH buys NLYRA).
- `ALL_USDG`: everything in USDG (NLYRA → WETH → USDG).

**Flow indices:** 0 and 1 are the rewards (WETH, NLYRA); 2 and 3 are the bonus-eligible part of each.

### Immutables (L91–L99)

- `POOL_NLYRA`: the Uniswap v3 WETH/NLYRA pool. `POOL_USDG`: the Uniswap v3 WETH/USDG pool.

### Reward state (L101–L131)

- `RewardState.rate`: sum of the rates of the active tranches (tokens per second).
- `RewardState.rewardPerBoosted`: the accumulator, scaled by 1e36.
- `RewardState.distributed`: total assigned to stakers (an upper bound of what can be claimed).
- `RewardState.paid`: total already paid out or compounded.
- `EligState`: the bonus-eligible part (what came from the splitter); it only needs a rate and an accumulator.
- `Tranche.eligWeth` / `Tranche.eligNlyra`: the part of `rateWeth` / `rateNlyra` that came from the splitter.
- `_reward` and `_elig`: index 0 is WETH, index 1 is NLYRA.
- `periodFinish`: end of the newest tranche (informational only).
- `pausedUntil`: end of the current pause, or of the last one (it also anchors `PAUSE_GAP`).
- `lastDonationSweep`: the last tranche opened by `sweepDonations`.
- `_tranches`: a circular queue ordered by end time.

### Stake state (L133–L168)

`Position`:

- `amount`: NLYRA (0 means a free slot).
- `unlockTime`: a UTC midnight.
- `tier`: `TIER_7` / `TIER_14` / `TIER_30` while boosted; 0 once expired and already settled at 1×.

`Account`:

- `flexible`: the flexible stake (1×).
- `locked`: sum of the open locks, expired or not.
- `boosted`: the settled weight (expired locks are lowered on the user's next action).
- `cooling`: the amount in cooldown, which earns NO rewards.
- `nextExpiry`: a lower bound of the next boosted expiry (0 = none).
- `recentDay`: the UTC day (timestamp / 1 day) of the `recentCur` bucket, used by `eligibleBalance`.
- `usedMask`: which position slots are occupied.
- `recentCur` / `recentPrev`: stake added on day `recentDay` / on day `recentDay - 1`.

Totals and mappings:

- `totalBoosted`: as of `lastUpdateTime`.
- `totalStaked`: flexible + locked, excluding what is cooling.
- `boostDrop`: UTC midnight ⇒ the extra weight (boost − 1×) of the locks that expire at that midnight.
- `_rpbAt`: the `rewardPerBoosted` of the four flows at that midnight.
- `_rewards`: per user, `[WETH, NLYRA, eligible WETH, eligible NLYRA]`.
- `positionOffer`: holder ⇒ lock id ⇒ the address it was offered to (0 = no offer). The offer is deleted on any
  change to the lock (`extendLock`, a compound into that lock, `withdrawLocked`, a transfer), so it can never stay
  attached to a reused slot or to a different lock than the one that was offered.

### Events (L170–L211)

- `LockExtended.added`: NLYRA added to the lock (0 for `extendLock`; the total plus bonus for a compound into
  that lock).
- `PositionTransferred.operator`: who accepted the transfer (the recipient, or `PositionMarket` in a sale).

### Constructor (L245–L284)

- `Ownable` already rejects a zero owner (`OwnableInvalidOwner`); the deploy script checks the rest.
- Each pool must be a GENUINE Uniswap v3 pool from the expected factory, pair and fee tier. Its address is
  derived with CREATE2 from the canonical init code, so its code is the real pool's code.

### Reward core (L286–L504)

- **`G` (L288)**: an in-memory snapshot of the global state, used to advance time through tranche ends and
  midnights.
- **`_accrue` (L315)**: with no stakers, emitted rewards are not assigned; they return in the next notify.
  `distributed` is rounded up, so the sum of what users claim (rounded down) never exceeds it.
- **`_advance` (L326)**: advances `g` up to `to`, in order: tranche ends (the rate goes down) and midnights (the
  boost of the locks expiring there goes down). It returns true as soon as it applies a boost drop (with
  `g.last` set to that midnight), so that the caller stores the `rewardPerBoosted` of that moment.
- **`_update` (L389)**: settles a user. An expired lock earns with its boost only until its expiry midnight: the
  contract subtracts `extra * (rpb_now - rpb_at_expiry)`, exactly, and lowers the weight to 1×.
- **`_demote` (L411)**: lowers the user's expired locks to 1× and subtracts from `num` what was over-accrued since
  each expiry. Returns the weight removed and the next boosted expiry (0 = none).
- **`_rewardBalance` (L439)**: the part of the contract balance that belongs to rewards, assigned or not yet
  assigned.
- **`_pending` (L445)**: what the tranches in `g` still have to emit from time `t` onwards.
- **`notifyRewards` (L457)**: called by the splitter after it transfers `wethIn` / `nlyraIn`. Opens a new 7-day
  tranche with ALL the free balance (the new amount, anything emitted while there were no stakers, and direct
  donations). Only the part the splitter sent counts for the compound bonus.
- **`sweepDonations` (L465)**: anyone can call it. Opens a tranche with the free balance (fees sent straight to
  the staking contract by the Desk, OTC or bots, donations, rewards emitted while there were no stakers). At most
  one tranche per day; with only dust it opens nothing and does not use up the interval. Nothing that enters this
  way counts for the compound bonus.
- **`_notify` (L474)**: a new tranche with the free balance. Existing tranches stay exactly as they are, so nobody
  can stretch them. With only dust, or with the queue full (which cannot happen: at most 7 tranches from the
  splitter plus 7 from `sweepDonations`), nothing is opened. The eligible part can never exceed what actually
  enters the tranche.

### Stake and unstake (L506–L673)

- **`stakeLocked` (L513)**: `tier` is `TIER_7` (1.25×), `TIER_14` (1.5×) or `TIER_30` (2×). Each lock is a
  separate position.
- **`_openLock` (L530)**: opens a lock in the first free slot. The ids of open positions never change.
- **`_putPosition` (L546)**: stores the position in the user's first free slot (at most `MAX_POSITIONS` open) and
  returns its id.
- **`_addToLock` (L557)**: adds `amt` (which can be 0) to an open lock and re-locks it from now with `tier`.
  Extend rules: a boosted lock can only move to the same or a higher tier and can never end earlier; an expired
  lock (already at 1×) accepts any tier. Requires `_update(user)` first. Any previous offer is deleted, because
  it was made for the lock as it was.
- **`extendLock` (L587)**: renews a lock in the same slot without moving tokens: it starts again from now with
  `tier`. Only to the same tier or a longer one, and it can never end earlier. It also works on an expired lock,
  which is first settled and left at 1× (tier 0).
- **`requestUnstake` (L596)**: moves `amount` from the flexible stake into cooldown, where it stops earning. If a
  previous cooldown had already finished, that amount is paid out right away; if one had not finished yet, the
  amounts are added together and **the 2-day clock restarts**.
- **`withdrawLocked` (L610)**: releases an expired lock: its amount enters the same 2-day cooldown as the flexible
  stake, and the slot is freed. Any offer on the lock dies with it. Like `requestUnstake`, this goes through
  `_startCooldown` (L628), so it also restarts the clock of a cooldown that had not finished yet.
- **`cancelUnstake` (L645)**: re-stakes, as flexible, everything that is in cooldown.
- **`withdraw` (L662)**: withdraws what has finished its cooldown. Always to the staker's own address, and it only
  moves NLYRA (never WETH or USDG).
- **`kick` (L675)**: optional. The boost of an expired lock already switches off by itself at the exact hour
  (for the total and, when the user is settled, for the user). `kick` only brings the user's storage up to date;
  it moves no funds.

### Lock transfers (L692–L773)

Two steps: the holder offers a lock to ONE address (`offerPosition`) and that address accepts it
(`acceptPosition`, or `acceptPositionTo` when it is an operator such as `PositionMarket`). The rules:

- The whole lock moves as it is: amount, expiry (`unlockTime`) and tier/weight. Total weight, total stake and
  `boostDrop` do not change (the lock keeps existing and expires the same way).
- Rewards: on acceptance both sides are settled. Everything accrued up to that second (including the
  bonus-eligible part) stays credited to the sender, who can claim it whenever they want; the receiver earns
  from the transfer onwards. Nobody inherits someone else's rewards or bonus eligibility.
- An expired lock can also be transferred: it arrives at 1×, ready for the receiver's `withdrawLocked`. This is
  how "stake from one wallet and withdraw from another" works.
- The cooldown belongs to the ACCOUNT, not to the lock: `withdrawLocked` takes the lock's amount out and frees
  the slot, so a lock with a requested withdrawal no longer exists and cannot be transferred. Cooling amounts
  never travel.
- The receiver uses their first free slot (the cap is 32 open locks; if it is full, the transfer reverts), and the
  id can be different. For `eligibleBalance` the lock counts as a NEW contribution of the receiver (excluded for
  24–48 hours), so passing a lock around does not help with the Desk discount. For the sender it drops at once.
- Pause: offering and accepting are stopped; cancelling an offer never is.

Functions:

- **`offerPosition` (L710)**: step 1. Offers lock `positionId` to `to`, replacing any previous offer for that
  lock. The offer deletes itself if the lock changes (`extendLock`, a compound into that lock, `withdrawLocked`).
- **`cancelPositionOffer` (L720)**: withdraws the offer on a lock. It also works while paused.
- **`acceptPosition` (L727)**: step 2. The address the lock was offered to takes it. Returns its id in the new
  wallet.
- **`acceptPositionTo` (L732)**: step 2 through an operator. The address the lock was offered to (for example
  `PositionMarket`) delivers it to `recipient`. Only the address the holder offered THAT lock to can call it.
- **`_transferPosition` (L749)**: moves lock `id` from `from` to `to` (first free slot), settling both sides
  before the weight moves. What accrued until now stays with the sender (an expired lock drops to 1× at this
  point). `af.nextExpiry` stays a valid lower bound (at worst it costs one extra pass of `_demote`). As an
  anti-flash-transfer measure, the Desk treats the lock as new stake of the receiver.

> Audit note (Coinsult RYSM1): the final `recipient` of `acceptPositionTo` is not asked for consent, so anyone can
> push locks into another wallet and fill its 32 slots. No funds, rewards, claims or withdrawals are affected.
> An unwanted lock can be removed once it unlocks, or moved to another wallet right away, and the official app
> shows the slot count, flags tiny locks and offers both actions. A recipient opt-in is planned for the next
> version.

### Claim and compound (L775–L872)

- **`claimTo` (L781)**: like `claim`, but the staker chooses who receives the payout (for example a bot's escrow).
- **`_takeRewards` (L788)**: returns `[WETH, NLYRA, eligible WETH, eligible NLYRA]` and resets them to zero.
- **`_claim` (L801)**: `AS_IS` converts nothing: `minOut` is ignored and `amountOut` is 0 (the amounts are in the
  event). In the other modes `minOut` is the minimum of the output token (WETH, NLYRA, or USDG with 6 decimals).
- **`compound` (L828)**: buys NLYRA with the WETH reward and adds everything to the stake.
  - `tier = TIER_FLEX`: into the flexible stake, with NO bonus (`positionId` must be `NEW_POSITION`).
  - `tier = TIER_7` / `TIER_14`: into a lock (new or existing), with NO bonus.
  - `tier = TIER_30`: into a lock (new or existing), with a bonus from the reserve equal to
    `min(5% of the compounded amount that came from splitter fees, reserve)`. Donations earn no bonus.
  - `minOut`: the minimum NLYRA compounded NOT counting the bonus (NLYRA reward plus NLYRA bought).
  - `positionId`: `NEW_POSITION` opens a new lock; otherwise the amount is added to that open lock, which is
    re-locked from now with `tier` (same rules as `extendLock`: same or higher tier, never ending earlier).
- **`_bonus` (L858)**: 5% of the eligible part (eligible NLYRA plus what the eligible WETH bought), capped at the
  reserve.
- **`fundBonusReserve` (L866)**: anyone can fund the compound bonus reserve. It is one-way: funds only leave it as
  a bonus into 30-day locks. It does not accept funds while the contract is paused.

### Swaps, directly against the v3 pools (L874–L927)

- **`_swap` (L884)**: exact input against an immutable pool; the whole input must be consumed (no partial fills).
  The callback pays only the pool of the swap in progress, only the input token, and only the exact amount.
- **`uniswapV3SwapCallback` (L906)**: a pool that asks for MORE than agreed reverts with `BadCallback`; one that
  asks for less (a partial fill caused by liquidity or the price limit) reverts with `PartialFill`. There is a
  single payment per swap: the transient slot is cleared before paying.

### Owner, limited (L929–L963)

- **`pause` (L931)**: stops new entries (stake, locks, extend, compound, cancel of an unstake, funding the
  reserve) and lock transfers (offer and accept, and therefore sales on `PositionMarket`) for up to 30 days. It
  cannot be renewed: a new pause is only possible 30 days after the previous one ended (by expiry or by
  `unpause`). It never stops `claim`, `requestUnstake`, `withdrawLocked`, `withdraw` or `kick`.
- **`renounceOwnership` (L952)**: disabled, because without an owner nobody could lift a pause early or rescue
  tokens sent by mistake.
- **`recoverERC20` (L957)**: rescues OTHER tokens sent to the contract by mistake. Never NLYRA or WETH (principal
  and rewards). USDG is only ever held for a moment inside a single claim transaction.

### Helpers (L965–L1006)

- **`_markIncrease` (L975)**: two buckets per UTC day. What is added on day D stays out of `eligibleBalance`
  during D and D+1 (between 24 and 48 hours), without piling up: new contributions do not reset the clock of
  earlier days.
- **`_unlockFor` (L997)**: a lock ends at the UTC midnight at or after now + its duration, so boost drops happen
  once per day.

### Views (L1008–L1139)

- **`_earned` (L1019)**: `[WETH, NLYRA, eligible WETH, eligible NLYRA]` not yet claimed, with expired locks
  settled.
- **`earned` (L1039)**: rewards accrued and not yet claimed (with expired locks settled at their expiry).
- **`earnedBonusEligible` (L1045)**: of what `earned()` returns, the part that came from splitter fees. It is the
  base of the 30-day compound bonus: 5% of this, with the WETH converted to NLYRA at the compound price.
- **`rewardInfo` (L1052)**: APR inputs: the reward per second of each token (sum of the active tranches) and the
  total weight. `APR(tier) = rate × 365d × token_price / (totalBoosted × NLYRA_price) × boost(tier)`.
- **`committedRewards` (L1071)**: what the contract owes in rewards today (accrued and unclaimed, plus what the
  tranches still have to emit). Solvency: `WETH.balance >= weth`; `NLYRA.balance >= staked + cooling + reserve +
  nlyra`.
- **`tranches` (L1080)**: the active tranches (rate per second, end, and the bonus-eligible part of the rate).
- **`rewardState` (L1087)**: raw accounting of one reward token (0 = WETH, 1 = NLYRA), as of `lastUpdateTime`.
- **`userInfo` (L1092)**: `positionCount` is the number of open locks (the ones using a slot).
- **`positionsOf` (L1103)**: all positions (`amount == 0` is a free slot that will be reused). The id is the index.
- **`positionOf` (L1108)**: one lock (`amount == 0` means a free slot or an id out of range).
- **`stakeOf` (L1113)**: NLYRA staked and active (flexible plus locks, excluding what is cooling).
- **`eligibleBalance` (L1119)**: the stake the Desk can use for fee discounts: the active stake MINUS what came in
  today or yesterday (UTC days) through stake, lock, compound or `cancelUnstake`. Every contribution stays out for
  24 to 48 hours and then counts, even if new contributions arrive. Decreases count immediately. A flash stake
  gives 0.
- **`boostedBalanceOf` (L1131)**: the current weight in the rewards (expired locks already count at 1×).

---

## 2. `NlyraFeeSplitter.sol`

### Overview (L9–L16)

The target of NLYRA's `feeRedirect` on Pons. `harvest()`, which anyone can call, collects the creator fees from
the locker and distributes ALL the WETH and NLYRA the contract holds: `SPLIT_BPS` goes to the staking contract
(which pays it out in its own 7-day tranche) and the rest to the treasury. It also distributes direct donations
(WETH, NLYRA, or native ETH, which gets wrapped) from other fee sources such as the Desk router, OTC and bots.
What reaches the staking contract through the splitter counts for the compound bonus; what is sent straight to
the staking contract does not.

No owner, no setters, no withdrawal function: everything is immutable. If it ever has to change, NLYRA's deployer
on Pons (the treasury) redirects the fees somewhere else with `setFeeRedirect`. That is the way out.

### Parameters (L20–L37)

| Constant | Value | Note |
|---|---|---|
| `MIN_SPLIT_BPS` | 1,000 | at least 10% to stakers |
| `MAX_SPLIT_BPS` | 9,000 | at most 90% to stakers: a "donation" routed through here leaves at least 10% in the treasury, so self-donating bonus-eligible rewards (5% bonus) never pays off (0.9 × 1.05 < 1) |
| `MIN_INTERVAL` | 1 day | so there are never more than 7 active tranches from the splitter |
| `MAX_INTERVAL` | 7 days | |

- **`MIN_HARVEST_INTERVAL` (L34)**: the minimum time between harvests (at least 1 day). Each harvest opens at
  most one 7-day tranche in the staking contract and never touches the tranches already open, so extra harvests
  (even 1-wei ones) cannot stretch any payout; the interval bounds the number of active tranches (at most 7).
  Deployed value: 86,400 seconds (1 day). Split deployed: `SPLIT_BPS = 5000` (50% to stakers).

### Functions (L82–L142)

- **`receive` (L82)**: native ETH donations are wrapped into WETH on the next harvest.
- **`harvest` (L85)**: collects the Pons fees (if there are any, and if the splitter is still the `feeRedirect`),
  distributes the whole balance, and ALWAYS notifies the staking contract, which opens a tranche with the new
  amount plus anything sent to it directly (unless it is dust). Even when there is nothing to distribute it does
  not revert: it still uses up the interval.
  1. Collect. Only two "expected" errors are tolerated: there are no fees, or the splitter is no longer the
     recipient (the treasury pointed the redirect elsewhere). Any other error, including running out of gas
     (which arrives with no data), reverts everything, so nobody can "burn" the interval without collecting.
  2. Donated native ETH is wrapped into WETH.
  3. The whole balance is distributed.
  4. The staking contract opens a tranche with its free balance. What the splitter sends counts for the
     compound bonus; fees that arrived straight at the staking contract are included too, but without bonus.
     With only dust, nothing is opened.
- **`sweep` (L129)**: tokens other than WETH or NLYRA (sent by mistake) go to the treasury. Anyone can call it.
- **`harvestableIn` (L137)**: seconds until the next harvest is allowed (0 = now).

---

## 3. `PositionMarket.sol`

### Overview (L8–L27)

**PositionMarket** (round 3): a market for `RealYieldStaking` locks, priced in native ETH.

The seller lists ONE of their own locks that is STILL LOCKED at a fixed ETH price; the buyer pays and receives
the lock in the same transaction. A fixed 0.5% commission goes to `NlyraFeeSplitter`, which wraps it into WETH and
splits it 50/50 between stakers and the treasury on its next harvest. The rest belongs to the seller, who
withdraws it with `withdrawProceeds` (pull payment).

- **How authorization works:** the seller must offer THAT lock to the market in the staking contract
  (`staking.offerPosition(id, market)`) and list it here (`list`). There is no blanket approval: the market can
  only move the lock it was offered, only inside `buy`, and only to whoever pays.
- **Snapshot:** each listing stores a snapshot of the lock (amount, expiry, tier). If the seller changes the lock
  (`extendLock`, a compound into it), transfers it, withdraws it or withdraws the offer, the listing can no longer
  be bought. The buyer passes the price they saw (`expectedPrice`) and the listing id, which changes if the seller
  lists again, so a last-second price change can never catch them.
- **No owner, no setters, no upgrade:** the commission is a constant (50 bps). Nobody, neither the staking owner
  nor whoever deployed this contract, can remove a listed lock or take the sellers' money.
- **Expired locks** can NOT be listed or bought. They are already liquid (the owner withdraws them through the
  normal 2-day cooldown), so selling them would just be selling NLYRA in another wrapper. A lock that expires
  while listed automatically becomes unbuyable.
- **Rewards:** what the lock earned until the sale belongs to the seller (the staking contract settles it on the
  transfer); the buyer earns from the purchase onwards. The price is for the lock only.

### State (L29–L52)

- `FEE_BPS = 50`: 0.5%, immutable.
- `FEE_RECIPIENT`: the staking contract's `NlyraFeeSplitter` (its `receive()` accepts ETH; `harvest()` wraps and
  distributes it).
- `Listing.expiry`: the listing is valid while `block.timestamp < expiry`. `Listing.price`: in wei of native ETH.
  `amount`, `unlockTime`, `tier`: the snapshot of the lock taken when it was listed.
- `nextListingId` starts at 1 (0 means none).
- `activeListing`: seller ⇒ lock id ⇒ the current listing (0 = none). Listing the lock again replaces the
  previous listing.
- `proceeds`: ETH from sales waiting to be withdrawn, per seller.

### Functions (L103–L216)

- **`list` (L103)**: lists lock `positionId` (your own, still locked) at `price` wei until `expiry`. The lock must
  first be offered to the market in the staking contract: `staking.offerPosition(positionId, market)`. If the lock
  was already listed, the previous listing is cancelled and its id stops being valid.
- **`cancel` (L124)**: removes one of your own listings. The offer in the staking contract is withdrawn
  separately, with `staking.cancelPositionOffer(positionId)`; without a listing the market cannot use it anyway.
- **`withdrawProceeds` (L135)**: sends your ETH from sales to `to`. It is a pull payment, so a sale never depends
  on the seller being able to receive ETH.
- **`buy` (L150)**: buys listing `listingId`. `msg.value` must be EXACTLY the price, and `expectedPrice` the price
  you saw (if it changed, the call reverts). The lock arrives in your wallet (in the first free slot, so you need
  fewer than 32 open locks) with the same amount, expiry and tier, and you earn rewards from that moment. Returns
  the lock's id in your wallet. All state changes happen before any external call, and the commission is rounded
  up. The staking contract requires the offer of THAT lock to be to this market (otherwise `NotOffered`),
  delivers the lock straight to the buyer, and settles the seller's rewards up to that moment.
- **`sweepExcess` (L178)**: ETH that arrived without a sale (for example forced in with `selfdestruct`) goes to the
  splitter, so nothing gets stuck. Anyone can call it; the sellers' funds are never touched.
- **`isBuyable` (L194)**: true if the listing can be bought right now: listed, not expired, the lock identical to
  the snapshot, still locked and offered to the market, and the staking contract not paused. It does not check
  the buyer's 32-slot cap.
- **`quote` (L205)**: the commission and the seller's net amount for a given price.
- **`_checkPosition` (L211)**: the lock must still be exactly as it was when listed, and still locked.

---

## 4. `interfaces/External.sol`

- **File header (L4–L5)**: minimal interfaces of external contracts (Pons, Uniswap v3, WETH), copied from their
  verified sources, declaring only what the project uses.
- **`IPonsLaunchLocker` (L7)**: PonsLaunchLocker `0x736D76699C26D0d966744cAe304C000d471f7F35`. The contracts only
  call `collectFees`; `feeRedirects` and `setFeeRedirect` are declared for reference, because they are used by
  NLYRA's deployer on Pons (the treasury), not by these contracts. The declarations match the deployed locker: a
  live harvest succeeded on September 29, 2026
  ([`0xd5d5d9b1…0886`](https://robinhoodchain.blockscout.com/tx/0xd5d5d9b1717fab7eed17e6f5fde1babb3f7e03658790aa4e4b27cf7cf3b10886),
  block 75,688,653), calling `collectFees` and paying the staking contract.
- **`IUniswapV3PoolLike` (L16)**: a Uniswap v3 pool, reduced to `swap` plus the immutables used to validate the
  pool against the factory.
