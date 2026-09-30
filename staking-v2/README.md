# NLYRA Real Yield Staking v2

**Deployed on Robinhood Chain (chainId 4663) on Sept 29, 2026 — closed beta.** Source verified (exact match) on Sourcify and Blockscout.

| Contract | Address |
|---|---|
| `RealYieldStaking` | [`0x5CB0Cb16cA019bcff4E494b32575848E4CdB5aF8`](https://robinhoodchain.blockscout.com/address/0x5CB0Cb16cA019bcff4E494b32575848E4CdB5aF8) |
| `NlyraFeeSplitter` (created by the staking constructor) | [`0x8300Ef5cC02cAb1D141dBE1c0B33d8Ac115F2D48`](https://robinhoodchain.blockscout.com/address/0x8300Ef5cC02cAb1D141dBE1c0B33d8Ac115F2D48) |
| `PositionMarket` | [`0x3BcA70536aC7FfB44023e971d204dAb7c23E95D7`](https://robinhoodchain.blockscout.com/address/0x3BcA70536aC7FfB44023e971d204dAb7c23E95D7) |

- Owner: the NLYRA treasury `0xe30647793192D15BFA6E53aE8651368d332fe04C`. Constructor args: `SPLIT_BPS = 5000`, `MIN_HARVEST_INTERVAL = 86400`.
- Deploy txs: staking `0xe3838ad2813d09497bf1a11d6e83abe5814dd1ba99deb167538ef7efd677efb2` (block 75,661,721), market `0x30d2e3f19ddbe5172e0f38b2c21af507abdf0cb7f1f8fb4d19cadcdf241b3e20` (block 75,661,770).
- Pons `feeRedirects(NLYRA)` points to the splitter since Sept 29, 2026; the treasury can point it back at any time.
- The files in `src/` are byte-for-byte the verified sources (line endings aside).
- External audit: **Coinsult**, Sept 30, 2026, on the four contracts at commit `19880c0` (the deployed code). 0 critical,
  0 medium; every finding is low-risk or informational and has been resolved or acknowledged. Reports:
  [RealYieldStaking](https://github.com/Coinsult/Audits/blob/main/Nlyra_RealYieldStaking%20%281%29.pdf) ·
  [NlyraFeeSplitter](https://github.com/Coinsult/Audits/blob/main/Nlyra_NlyraFeeSplitter%20%281%29.pdf) ·
  [PositionMarket](https://github.com/Coinsult/Audits/blob/main/Nlyra_PositionMarket%20%281%29.pdf) ·
  [External](https://github.com/Coinsult/Audits/blob/main/Nlyra_External%20%281%29.pdf).

## Development history

Written on Sept 27, 2026 and revised to address the 8 findings of the internal audit ([`AUDIT.md`](AUDIT.md)); on Sept 28, 2026
it was revised again for the 7 findings of round 2 ([`AUDIT-2.md`](AUDIT-2.md)) plus the new tiers we decided on. Also on Sept 28 (round 3)
we added **lock transfers between wallets** and the **lock market** (`PositionMarket`), and the owner
became the treasury. What changed in each round: [`CHANGES.md`](CHANGES.md). Tested on a fork of Robinhood Chain (4663), pinned block **74,478,703** (`ForkPin.BLOCK` in
`test/ForkBase.sol`), through a Robinhood Chain RPC set in `RH_RPC` (see [Reproducing the tests](#reproducing-the-tests)).

## What's here

| file | what it is |
|---|---|
| `src/RealYieldStaking.sol` | the staking contract: stake NLYRA, rewards in WETH + NLYRA via tranches, boosted tiers, claim in 4 modes, compound |
| `src/NlyraFeeSplitter.sol` | target of NLYRA's `feeRedirect` on Pons: collects fees and splits them 50/50 staking/treasury |
| `src/PositionMarket.sol` | round 3: lock market in native ETH (no owner, fixed 0.5% fee to the splitter) |
| `src/interfaces/External.sol` | minimal interfaces (PonsLaunchLocker, v3 pool, WETH) |
| [`CONTRACT-NOTES.md`](CONTRACT-NOTES.md) | the explanatory comments in `src/` (written in Spanish), translated to English in code order with line numbers |
| `test/ForkBase.sol` | shared base for the fork tests (setUp, helpers, solvency invariant) |
| `test/RealYieldStaking.fork.t.sol` | main suite against the real locker, pool and tokens |
| `test/StakingInvariant.t.sol` | solvency invariants with a handler (sequence fuzzing) |
| `test/audit/v_*.t.sol` | round 1 PoCs turned into regression tests (the attack no longer works) |
| `test/r3/` | round 3: transfers (`r3_transfer_local`), market (`r3_market_local`) and both on the fork with the real fee (`r3_fork`) |
| `test/audit2/` | round 2: `v_*` PoCs turned into regression tests, local stateful fuzzing with an exact model (`inv2_stateful_local`), differential model (`diff_model_r2`), time edge cases, tranche engine, tokens, owner/deploy |
| `script/Deploy.s.sol` | deploy script (simulation + post-deploy checks); the mainnet deploy used the same constructor arguments |

Not included in this repository: snapshots of the code as audited in round 1 (before the fixes), in round 2 (before the
[`AUDIT-2.md`](AUDIT-2.md) fixes) and before round 3 (without transfers or the market); the original PoCs of each round as they ran
against the old code; and a copy of the verified `PonsLaunchLocker` source used as a reference.

Same toolchain as the v4 bots: **solc 0.8.24, optimizer 200, viaIR, cancun** (cancun is required:
the swap uses transient storage). OpenZeppelin 5.6.1 in `lib/oz`, forge-std v1.11.0.

```
forge build --sizes
forge test                                   # default profile (viaIR): ~15 min to compile the first time
FOUNDRY_PROFILE=dev forge test               # no viaIR, for iterating; gas and sizes: default
forge test --match-test test_gas_report -vv  # gas for each action
```

### Reproducing the tests

The fork tests read the RPC from `RH_RPC` (`robin = "${RH_RPC}"` in `foundry.toml`) and the block from
`FORK_BLOCK` (default: the pinned `ForkPin.BLOCK`). With the public RPC, fork the current block:

```bash
RH_RPC=https://rpc.mainnet.chain.robinhood.com FORK_BLOCK=$(cast block-number --rpc-url $RH_RPC) FOUNDRY_PROFILE=dev forge test
```

Reproducing the exact pinned block (74,478,703) requires an **archive** RPC: the public endpoint does not
serve historical state that far back. `lib/` (forge-std and OpenZeppelin) is vendored, so no `forge install` is needed.
Run one forge process at a time.

## How it works

```
Pons locker --collectFees--> NlyraFeeSplitter --50%--> RealYieldStaking (one 7-day tranche per harvest)
 (70% of the pool's 1%)       ^  harvest()     \--50%--> treasury fe04C
                              |  (anyone, once per day)
  WETH/NLYRA/ETH donations ---+  (Desk router, OTC, bots…)

  fees sent directly to staking --> RealYieldStaking.sweepDonations() (anyone, 1 tranche per day; the
                                     daily harvest also picks them up). They do NOT count toward the compound bonus.
```

### NlyraFeeSplitter
- `harvest()`: anyone can call it, **at most once every `MIN_HARVEST_INTERVAL`** (the
  constructor requires ≥ 1 day). It calls `locker.collectFees(NLYRA)`; it tolerates only `NoFeesToCollect` and
  `NotAuthorized` (exact 4-byte error) and emits `CollectSkipped`. Any other error, including
  running out of gas, reverts everything. It wraps donated native ETH, splits **the entire** WETH and
  NLYRA balance (`SPLIT_BPS` to staking, between 10% and 90%; the rest to the treasury, which keeps the rounding) and
  **always** calls `staking.notifyRewards(ws, ns)`, even when empty (it no longer reverts): this way fees
  that arrived directly at the staking contract also get picked up. Only what the splitter sends is eligible for the
  compound bonus.
- The constructor requires the locker to have code and `1 day ≤ MIN_HARVEST_INTERVAL ≤ 7 days`.
- No owner, no setters, no withdrawal. `sweep(token)` sends foreign tokens to the treasury. The emergency
  exit lives on Pons: the treasury calls `setFeeRedirect(NLYRA, otherWallet)`.
- It is created by the staking constructor, so both addresses are immutable without having to predict nonces.

### RealYieldStaking

**Tranche-based rewards.** Each `notifyRewards(wethIn, nlyraIn)` (splitter only) or `sweepDonations()`
(anyone, at most one tranche per day) opens a **tranche** with the free balance (the new amount + whatever was emitted
while there were no stakers + donations and direct fees), with **its own rate and its own end, 7
days out**. Earlier tranches are left untouched: each inflow is paid out in full over its 7 days, even if there are
harvests every day or someone forces 1-wei harvests. The current rate is the sum of the active
tranches: at most 7 from the splitter + 7 from `sweepDonations` = 14 (cap 16; if it ever filled up, the notify is
skipped and the balance waits for the next one; a tranche is never stretched). If the free balance is dust (`< 1e12` wei
of WETH and `< 1 NLYRA`) no tranche is opened; it waits for the next one and does not use up the day's `sweepDonations`.
Each tranche also carries the **bonus-eligible** portion (`eligWeth`/`eligNlyra`): the amount the
splitter sent in that harvest.

**Separate accounting.** NLYRA is both the stake and a reward. The NLYRA reward balance is
`balance − totalStaked − totalCooling − bonusReserve`, so principal is never used as a reward.
Invariants (checked in every test, at every fuzz step and in the invariant test):
`WETH.balance ≥ accrued but unclaimed + what remains to be emitted from the tranches` and
`NLYRA.balance ≥ totalStaked + totalCooling + bonusReserve + accrued + pending`; the total claimable by
everyone ≤ accrued; and principal, cooling and weight match the sum over users exactly.

**Tiers:** flexible 1x · **7-day lock 1.25x** (`TIER_7 = 1`) · **14 days 1.5x** (`TIER_14 = 2`) ·
**30 days 2x** (`TIER_30 = 3`). Weight determines each staker's share.
- Flexible: `requestUnstake(amount)` moves it into cooldown (**it stops earning**) → `withdraw()` after
  **2 days** · `cancelUnstake()`. If, when requesting a new unstake, there was a cooldown that had **already matured**, that
  amount is paid out immediately and only the new amount starts its clock (if it had not matured, they are added together and the clock
  restarts).
- Locks: each one is a position (at most **32 open** per wallet; when one is released, its slot is reused and
  the ids of open locks never change). They expire at **UTC midnight** on or after
  `now + 7/14/30 days` (they last between N and N+1 days).
  - **The boost switches off by itself, exactly, at expiry**: total weight drops at that midnight without anyone
    doing anything, and each user is settled with the boost up to expiry and at 1x afterwards. No
    keeper is needed. `kick(user, id)` still exists (anyone, free), but it only brings storage
    up to date.
  - `extendLock(id, tier)`: renews the lock **in the same slot, without moving tokens**, starting now. Only
    to the **same tier or a longer one**, and it never expires earlier. On an already expired lock (which is at 1x)
    it accepts any tier.
  - `withdrawLocked(id)` (expired): moves the amount into the **2-day cooldown**, same as flexible, and
    frees the slot. Tokens are taken out with `withdraw()`.

**`claim(mode, minOut)` / `claimTo(recipient, mode, minOut)`**: `AS_IS` (WETH + NLYRA, minOut is
ignored), `ALL_ETH` (pays WETH), `ALL_NLYRA`, `ALL_USDG` (NLYRA → WETH → USDG). `minOut` is the floor
for the output token (USDG has 6 decimals). `claimTo` to the staking contract itself or to the splitter reverts. Swaps
go **directly to two immutable v3 pools**: WETH/NLYRA 1% `0x483C…5C39` and WETH/USDG 0.01%
`0x52e6…71Ca`.
- The constructor requires each pool to be the **genuine one from the Uniswap v3 factory**
  (`0x1f7d7550…2EfA`): its address must result from `CREATE2(factory, token0, token1, fee)` with the
  canonical init code (`0xe34f199b…7b8b54`), and `pool.factory()` and the tokens must match. A
  contract imitating a pool does not pass, even if it returns the correct factory and fee.
- The callback pays only the pool of the swap in progress, only the input token and **only the exact amount**
  requested (stored in transient storage), exactly once; if the input is not fully consumed, it reverts.
- `ALL_ETH` pays WETH, not native ETH (no calls with `value` to foreign code; it works with any
  recipient, including multisigs and escrows without `receive()`).

**`compound(minOut, tier, positionId)`**: buys NLYRA with the WETH reward (buy pressure on
our pool) and adds everything to the stake.
- `tier = 0`: into flexible, **no bonus** (`positionId` must be `NEW_POSITION`).
- `tier = 1 / 2 / 3` with `positionId = NEW_POSITION` (`type(uint256).max`): into a **new lock**.
- `tier = 1 / 2 / 3` with the id of an open lock: **added to that lock**, which is re-locked from now under
  the `extendLock` rules (it uses no extra slots: a bot can compound every day into the same lock).
- **Bonus: only with `tier = 3` (30 days)**: `min(5% × the compounded amount that came from splitter fees,
  reserve)`. Whatever came from donations or direct fees pays no bonus (so nobody can self-donate rewards to
  drain the reserve). `earnedBonusEligible(user)` reports how much is eligible. The bonus stays locked in the
  lock.
- `minOut` is the floor for the compounded NLYRA, excluding the bonus. Anyone can fund the reserve
  (`fundBonusReserve`, not while paused), and it is one-way.

**Transferring a lock to another wallet (round 3)**: "stake from one wallet and withdraw from another", in two
steps so nobody sends a lock to the wrong address:
1. the lock owner calls `offerPosition(positionId, destination)` (replaces any previous offer for that lock);
2. the destination calls `acceptPosition(from, positionId)` and receives the lock in its first free slot (the id
   may change; it is returned by the function and by the `PositionTransferred` event).
- The owner can withdraw the offer with `cancelPositionOffer(positionId)` (also works while paused).
- **The whole lock travels, as is**: amount, expiry and tier/boost. Total weight does not change.
- **Rewards: whatever was earned up to the transfer belongs to the sender** (it stays credited to their wallet and they
  claim it with `claim` whenever they want, even if they no longer have a stake). **The recipient earns from that second on.**
  The compound-bonus-eligible portion does not travel either.
- **Any change to the lock clears the offer** (`extendLock`, `compound` into that lock, `withdrawLocked`):
  an offer never ends up attached to a different lock or to a reused slot.
- An **expired** lock can also be transferred (it arrives at 1x, ready for `withdrawLocked` by the recipient).
- **Requested withdrawal:** the cooldown belongs to the account. `withdrawLocked` takes the amount out of the lock and frees the
  slot, so a lock with a requested withdrawal no longer exists and cannot be transferred; the cooling amount does not travel.
- **Cap of 32 open locks:** if the recipient already has 32, `acceptPosition` reverts.
- **Desk discount:** for `eligibleBalance`, the received lock counts as a **new deposit** by the
  recipient (excluded for 24-48 h); for the sender it drops immediately. Passing a lock around to collect a
  discount does not work.
- **Pause:** offering and accepting are halted while it lasts (and with them, market sales).
- `acceptPositionTo(from, positionId, recipient)` does the same but for an **operator**: the party that received
  the offer delivers the lock to another wallet. It is used by `PositionMarket`.

**`eligibleBalance(user)`** (for Desk discounts): active stake (flexible + locks) **minus whatever
came in today or yesterday (UTC day)** via stake, lock, compound or `cancelUnstake`. Each deposit is excluded
for between 24 and 48 h and counts afterwards, even while new deposits keep arriving (a DCA or a daily compound no longer
leaves everything excluded). Decreases count immediately. A flash-stake, a top-up in the trade's block or
"park in cooldown and cancel" all yield 0. **The Desk must use this, not `stakeOf`.**

**Owner** (Ownable2Step; decided Sept 28, 2026: **the treasury `0xe306…fe04C`, an EOA with a MetaMask 7702 delegate,
no multisig**): `pause/unpause` and `recoverERC20` for tokens other than
NLYRA or WETH. A pause **expires on its own after 30 days**, **cannot be renewed** while active,
and the next one can only start **30 days after** the previous one ended (by expiry or
`unpause`): even with a hostile owner, the contract is open at least half of the time. It only halts
inflows (`stake`, `stakeLocked`, `extendLock`, `compound`, `cancelUnstake`, `fundBonusReserve`) and
lock transfers (`offerPosition`, `acceptPosition`, `acceptPositionTo`, i.e. also market
purchases);
`claim`, `requestUnstake`, `withdraw`, `withdrawLocked`, `kick` and `sweepDonations` remain open.
`renounceOwnership` is disabled. There is no function that moves principal or rewards to anyone other than
their staker, nor any that lets the owner move a lock (listed or not).

**Views:** `earned(user)`, `earnedBonusEligible(user)`, `rewardInfo()` (current rate for each token, end of the newest tranche, total
weight, stake, cooling and reserve: the inputs for APR), `tranches()`, `committedRewards()` (what the
contract owes in rewards today, for solvency monitoring), `rewardState(i)`, `userInfo(user)`
(`positionCount` = open locks), `positionsOf(user)` (`amount == 0` = free slot; `tier == 0` on a
lock = expired and already settled at 1x), `stakeOf(user)`, `eligibleBalance(user)`, `boostedBalanceOf(user)`
(already excludes expired locks), `boostDrop(midnight)`, `paused()`, `pausedUntil`,
`lastDonationSweep`.
`APR(tier) = rate × 365 d × token_price / (totalBoosted × NLYRA_price) × boost(tier)`.
Round 3: `positionOf(user, id)` (a single lock), `positionOffer(user, id)` (who it is offered to, 0 = nobody).

### PositionMarket (round 3)

A fixed-price market in **native ETH** for locks that are **still locked**. No owner, no setters, no
upgrades.
1. The seller offers **that specific** lock to the market on the staking contract: `staking.offerPosition(id, market)`. There is
   no blanket approval: the market can only move the lock that was offered to it, and only within
   a purchase, to whoever pays.
2. The seller lists it: `market.list(id, priceWei, expiry)` → returns a `listingId`. Listing the same
   lock again cancels the previous listing (and changes the id).
3. The buyer: `market.buy{value: price}(listingId, expectedPrice)`. Payment must be **exact**
   and `expectedPrice` must be the price they saw (if the seller changed the price, it reverts). The lock moves to the buyer's wallet in the same
   transaction, with the same amount, expiry and tier.
4. **Fixed 0.5% fee** (50 bps, constant; rounded up) to `NlyraFeeSplitter`: on the next
   `harvest()` it is wrapped to WETH and split 50/50 stakers/treasury like any other fee (and it counts
   toward the compound bonus, because it comes in through the splitter). The rest goes to the seller, who
   withdraws it with `withdrawProceeds(destination)` (pull payment: a sale never depends on the seller being able to
   receive ETH).
- `cancel(listingId)` takes the listing down; listings **expire** on their own (`expiry`).
- **If the seller touches the lock** (extends it, compounds into it, transfers it, withdraws it or withdraws the
  offer to the market), the listing can no longer be bought: the market stores a snapshot of the lock (amount,
  expiry, tier) and compares it at purchase time.
- **Expired locks: cannot be listed or bought** (they are already liquid: the owner withdraws them through the normal
  cooldown). A listing whose lock expires dies on its own.
- **Rewards:** whatever was earned up to the sale belongs to the seller; the buyer earns from the purchase on.
- No stuck ETH: the market does not accept stray ETH (it has no `receive`), a purchase requires the exact amount,
  and if ETH is forced in (selfdestruct), `sweepExcess()` (anyone) sends it to the splitter.
- Views: `getListing(id)`, `isBuyable(id)` (everything the purchase checks except the buyer's 32-lock
  cap), `quote(price)` (fee and net), `activeListing(seller, lockId)`, `proceeds(seller)`.

## Parameters

| parameter | value | where |
|---|---|---|
| SPLIT_BPS | 5000 (50% to stakers), allowed range 1000-9000 | constructor, immutable |
| MIN_HARVEST_INTERVAL | 1 day (allowed 1-7 days) | constructor, immutable |
| REWARD_DURATION | 7 days per tranche | constant |
| MAX_TRANCHES | 16 (in practice ≤ 14: 7 from the splitter + 7 from sweepDonations) | constant |
| DONATION_INTERVAL | 1 day between `sweepDonations` tranches | constant |
| MIN_NOTIFY_WETH / MIN_NOTIFY_NLYRA | 1e12 wei / 1 NLYRA (below that, no tranche is opened) | constant |
| UNSTAKE_COOLDOWN | 2 days (flexible and expired locks) | constant |
| LOCK_7 / LOCK_14 / LOCK_30 | 7 / 14 / 30 days, rounded up to the next UTC midnight | constant |
| BOOST | 1x / 1.25x / 1.5x / 2x | constant |
| COMPOUND_BONUS_BPS | 500 (+5%, capped at the reserve), only for compound into the 30-day lock and only on the eligible portion | constant |
| MAX_POSITIONS | 32 open locks per wallet (reusable slots) | constant |
| `eligibleBalance` | the current and previous UTC day are excluded (24-48 h) | code |
| MAX_PAUSE / PAUSE_GAP | 30 days of pause at most / 30 open days before another | constant |
| PositionMarket.FEE_BPS | 50 (0.5%), constant, to the splitter | constant |
| UNI_V3_FACTORY / POOL_INIT_CODE_HASH | `0x1f7d7550…2EfA` / `0xe34f199b…7b8b54` | constant |
| FEE_NLYRA_POOL / FEE_USDG_POOL | 10000 (1%) / 100 (0.01%): the constructor requires these fee tiers | constant |

## Tests

All accounts are `makeAddr(...)` with no code: never the anvil mnemonic accounts, which on this chain
have a 7702 delegate. The treasury is impersonated for `setFeeRedirect`.

**Pinned block and fork cache.** All fork tests use **a single block**: `ForkPin.BLOCK =
74,478,703` in `test/ForkBase.sol` (can be overridden with `FORK_BLOCK=<n>`). The non-archive RPC used for development only served state
for the last ~15-20k blocks (~30 minutes); anything older came from foundry's local cache
(`~/.foundry/cache/rpc/4663/74478703`, 332 KB). Keeping a read-only backup copy of that cache directory is recommended:
if the cache gets overwritten (e.g. by parallel forge runs), copy it back from the backup. **Run forge one at a time.** If a new test touches an account or slot outside the cache, it fails in
`setUp` with "http 403". To re-pin: take a recent block, run
`FORK_BLOCK=<n> FOUNDRY_PROFILE=dev forge test` once and immediately `FORK_BLOCK=<n> forge test` (within
~30 min), and only then change the constant. In long swap sequences, `_resetOracle()` resets the
pool's `observationIndex` to 79 (it only affects the TWAP, which nothing here uses).

**With viaIR, `block.timestamp` may not be re-read after `vm.warp` inside a function**: the tests
use `vm.getBlockTimestamp()` for time jumps.

What is tested:
- Main suite (`RealYieldStaking.fork.t.sol`, 34): full flow with real fees (exact
  1 : 1.5 : 2 split), the three locks (expire at midnight after 7/14/30 days, boost switches off by itself,
  exit via cooldown, optional `kick`), `extendLock` rules, 32 open locks and slot reuse,
  claim in all 4 modes with exact `minOut`, compound (flex/7d/14d without bonus, 30d with exactly 5%, into
  an existing lock, small reserve, slippage, pause), direct fees + `sweepDonations`, dust, full
  queue (skips, does not stretch), bounded pause, limited owner, constructor (pools, fee tier, zero owner),
  splitter limits, day-based `eligibleBalance`, proportionality fuzzing and 24-action sequences.
- Fork invariants (`StakingInvariant.t.sol`): handler with every action (including compound
  into a lock and `sweepDonations`), 48 × 60, no reverts: solvency, exact balance reconciliation, `paid ≤
  distributed`, tranches ≤ 14, future `boostDrop` = current extra weight.
- Round 1 (`test/audit/`, 41): regressions for the 8 findings and informational PoCs.
- Round 2 (`test/audit2/`, 90): the `v_*` PoCs turned into regressions (A-G), time edge cases, tranche
  engine, swaps and transient storage, tokens (broken WETH/USDG), owner and deploy script, liveness and
  gas; **local stateful fuzzing** (`inv2_stateful_local`, real contracts with mocks at the
  CREATE2 addresses, exact per-user reference model including the bonus-eligible portion; 2 suites × 6
  invariants; in dev 200 runs × 150 calls = 60,000 calls, 0 violations) and a **differential
  model** (`diff_model_r2`, 3 fuzz × 48 scenarios of 150 steps + 2 fixed).

- Round 3 (`test/r3/`, 38 local + 3 on the fork, plus `invariant_marketEth` in the 2 local stateful suites):
  transfers (16: whole lock, rewards to the sender, boost expiring exactly in the new wallet,
  expired lock transferable and withdrawable from another wallet, 32 cap and slot reuse, requested withdrawal, offer that
  dies with any change, `eligibleBalance`, bonus, pause, access control, conservation fuzzing), market
  (22: happy path, end-to-end fee all the way to stakers, per-lock approval, expired locks,
  price front-running, the seller extends/compounds/transfers/withdraws/cancels, reentrancy, seller that
  rejects ETH, forced ETH, staking owner, buyer's cap, rewards, fee fuzzing and chained-sale fuzzing)
  and on the fork (transfer + sale + real harvest: the fee reaches the treasury and
  the stakers 50/50 in real aeWETH). Local stateful fuzzing (`inv2_stateful_local`) now also transfers and
  sells locks, against the exact per-user rewards model, plus a new invariant for the market's ETH.

**Result: 211/211 tests in 49 suites, in both the default profile (viaIR, the deploy profile) and
`FOUNDRY_PROFILE=dev`**, with a plain `forge test`.

**Gas** (default profile, `test_gas_report`, fork with cold storage: includes the first writes to
new slots, so real-world figures will be lower, and lower still in steady state):

| action | gas |
|---|---|
| harvest (collectFees + split + notify, 2 tranches) | 514k |
| sweepDonations (opens a tranche) | 262k |
| stake (wallet's first stake / subsequent) | 377k / 22k |
| stakeLocked 7d / 14d / 30d | 91k / 69k / 69k |
| extendLock (active 7d→30d / expired, settles at expiry) | 55k / 520k |
| claim AS_IS / ALL_ETH / ALL_NLYRA / ALL_USDG | 458k / 473k / 473k / 580k |
| compound flex / 30d new lock / 30d into an existing lock | 472k / 542k / 499k |
| requestUnstake | 35k |
| withdraw | 8k |
| withdrawLocked (into cooldown) | 38k |
| offerPosition / cancelPositionOffer | 28k / 3k |
| acceptPosition (new wallet, first action of the day) | 552k |
| market.list / market.buy / market.withdrawProceeds | 107k / 307k / 36k |

The round 3 figures come from `test_gas_r3` (fork, dev profile). `acceptPosition` settles both
wallets (the first action of the day walks through midnight and writes the recipient's reward slots for the
first time); in steady state it is considerably less.

The claim/compound/harvest figures in the table are the first action after 7 days of inactivity (walking through
the midnights) and write the eligible-portion slots for the first time (≈ 20k each). Long
inactivity: `requestUnstake` after 1 year of nothing, 1.48 M; after 10 years with the worst possible seeding (≤ 31
midnights with pending decreases), 14 M. `withdraw` does not depend on this (26k after 40 years).

**Sizes (default profile, runtime):** RealYieldStaking **21,527 B** (3,049 B headroom under 24,576; initcode
28,127 B, 21,025 B headroom), PositionMarket **4,925 B**, NlyraFeeSplitter **3,263 B**. Round 2: 19,833 B; round
1: 16,919 B. The market is a separate contract precisely so it does not consume the staking contract's headroom.

## Deploy (future, NOT executed)

1. External audit and verification of this code (including the fixes).
2. Owner decided (Sept 28, 2026): the treasury `0xe306…fe04C`, already set in `EXPECTED_OWNER`.
3. Simulate: `STAKING_OWNER=0xe30647793192D15BFA6E53aE8651368d332fe04C forge script script/Deploy.s.sol
   --rpc-url robin`. Before broadcasting, the script requires `STAKING_OWNER == EXPECTED_OWNER`, chainid 4663 and
   that the owner is **exactly the treasury**, with no code or with a 7702 delegate (any other address,
   or the treasury with regular contract code, is rejected). It deploys the staking contract (which creates the splitter) and
   the **PositionMarket** wired to both, and then verifies owner, pools, tokens, splitter and market
   (staking, splitter as fee recipient, 50 bps, empty). The staking constructor rejects
   pools that are not the factory's genuine ones with the correct fee tier; the market's constructor rejects a staking contract whose
   splitter does not point back to it.
4. Real deploy, executed manually by the deployer, with `--broadcast` and a hardware wallet or keystore. Never with
   a private key on the command line.
5. Verify **all three** contracts (the splitter is created by the staking contract and its arguments come from
   `feeSplitter()`; the market has a single argument, the staking address), first on Sourcify and then confirming `is_verified` **on Blockscout by actually checking it**
   (a verification is only considered done once it is visible on Blockscout).
6. Treasury seed stake in a lock **before** the redirect (finding 10), or redirect only once
   v1 ends (Oct 17, 2026), with the date announced in advance.
7. The treasury `0xe306…fe04C` signs
   `PonsLaunchLocker.setFeeRedirect(NLYRA, <feeSplitter>)`.
8. Daily `harvest()` cron (anyone can call it; it no longer reverts with an empty splitter and also picks up
   direct fees). If the Desk/OTC/bots send fees directly to the staking contract, `sweepDonations()` starts
   streaming them without waiting for the harvest. **A `kick` keeper is no longer needed.** Monitoring alerts
   for `feeRedirects(NLYRA) != splitter` and for `CollectSkipped(NotAuthorized)`; optional:
   `committedRewards()` against balances.
9. Desk: read `earned`, `rewardInfo`, `tranches`, `positionsOf`; for discounts, **`eligibleBalance`**;
   build the claim/compound buttons with `minOut` quoted at that moment (slot0 plus a margin,
   because QuoterV2 reverts on this chain) and offer `AS_IS` if the simulation fails with `PartialFill`.
   Renew locks with `extendLock` (not withdraw and re-lock) and compound into a lock **within the same lock**
   (`compound(minOut, tier, id)`) so as not to use up slots. If `ALL_USDG` fails in simulation, offer
   `AS_IS` or `ALL_ETH`. Show the expected bonus with `earnedBonusEligible`. The `LockExtended` event
   now includes `added`, `Compounded` includes `positionId`, and `RewardsNotified` includes the eligible rates.

## Open decisions

1. **Owner**: decided Sept 28, 2026, the treasury (EOA with a 7702 delegate). Renouncing is not possible; ownership can be
   transferred via Ownable2Step if a multisig is wanted later.
2. **SPLIT_BPS**: 50% to stakers?
3. **Compound bonus** (decided Sept 28, 2026: 5%, 30 days only): who funds the reserve, and with how much?
   Do not fund it until the v1 migration is finished and weight is distributed.
4. **Boosts, locks and cooldown**: decided Sept 28, 2026: 1.25x/1.5x/2x at 7/14/30 days, flexible with 2 days.
5. **Relationship with the old StakingRewards** (`0x5e63…`, expires Oct 17, 2026): no migration; each staker exits
   and re-enters manually. Any incentive?
6. **Other fee sources**: Desk router, OTC and bots to the splitter (50/50, count toward the bonus) or
   directly to staking (100% to stakers, picked up by the daily harvest or `sweepDonations`, no bonus).
7. **Lock market**: fixed 0.5% fee (changing it requires deploying another market; users
   only need to offer their locks to the new one). Link it from the Desk at launch?

## Known risks and limitations

- **The treasury controls the tap** (finding 9): with `setFeeRedirect` it can cut off future fees
  and collect those accumulated on Pons. Whatever has already been streamed stays safe. The treasury key (fe04C) must be protected.
- **Slippage is set by the user.** `minOut = 0` means accepting any price (in the swap modes);
  the Desk and bots must always send a real `minOut` computed on the swapped portion.
- **Combined cooldown:** if a new unstake is requested while another has not yet matured, they are added together and the clock
  restarts (at most 2 days, only for that user; the frontend should warn about it).
- **`eligibleBalance` is conservative:** a deposit is excluded for between 24 and 48 h depending on the time of day;
  after a deposit followed by a partial exit it undercounts slightly (it never overcounts).
- **Bounded pause:** at most 30 consecutive days, then at least 30 open days. It only halts inflows
  (and compound); it never halts exits or claims.
- **Day-by-day time advancement:** the first transaction after N days of inactivity walks through N
  midnights (~2-5k gas per day); with the daily harvest it is one per day.
- **Upgradeable third-party tokens.** NLYRA is a fixed ERC20 (no proxy, no fees; `FeeOnTransfer` is
  still checked on every inflow). **WETH** is aeWETH behind a proxy controlled by the chain
  owner; **USDG** is Paxos's, UUPS, pausable and with address freezing. If USDG is paused or
  freezes an address, only `ALL_USDG` fails (atomic, no loss). If WETH breaks or is badly upgraded,
  **all** claims, `compound`, `harvest` and `sweepDonations` are blocked while it lasts (rewards remain
  intact). **Principal never depends on WETH or USDG**: `requestUnstake`, `withdrawLocked` and
  `withdraw` only touch NLYRA (tested with broken WETH and USDG, `v_tokens_TOK-1`).
- **Bonus-eligible rewards** are lost (they remain as non-eligible) in edge cases: what is emitted
  while there are no stakers, and the splitter portion of a notify skipped as dust. Never the other way around.
- **Gas per inactive day:** each midnight without activity costs ~1.2-3.4k gas in the next
  transaction, plus ~4 new writes when that midnight had lock expiries.
- **Dust.** Less than 604,800 wei per token per tranche is lost, plus 1 wei per user per
  update. It stays in the contract and is recycled into the next tranche.
- **Owner = an EOA** (by design): if the treasury key is lost or stolen, the thief
  controls the pause (at most 30 days every 60, halting inflows, transfers and sales) and
  `recoverERC20` for foreign tokens. **It cannot touch principal, rewards or locks.** That same key also
  controls the fee tap on Pons (see above).
- **Transfers and market:** a lock buyer does not receive rewards already earned (they belong to the
  seller) and inherits the expiry as is; the Desk must show expiry, tier and amount before
  purchase. A purchase can fail if the buyer already has 32 open locks or if staking is
  paused (no loss: it reverts entirely). The seller collects the ETH with `withdrawProceeds`; it is not sent automatically.
- **Market price:** set by the seller and fixed; the market does not validate that it is reasonable. A seller's
  typo (a very low price) will sell at that price.
- The external audit (Coinsult, Sept 30, 2026) covered the four contracts as deployed; an audit lowers the risk but
  cannot prove there are no bugs. The fork tests use real state but synthetic volume.

## New functions for the frontend (round 3)

Staking (`RealYieldStaking`):
- `offerPosition(uint256 positionId, address to)` · event `PositionOffered(from, positionId, to)`
- `cancelPositionOffer(uint256 positionId)` · event `PositionOfferCancelled(from, positionId)`
- `acceptPosition(address from, uint256 positionId) returns (uint256 newId)`
- `acceptPositionTo(address from, uint256 positionId, address recipient) returns (uint256 newId)`
- event `PositionTransferred(from, fromId, to, toId, amount, unlockTime, tier, operator)`
- views `positionOffer(address, uint256) returns (address)`, `positionOf(address, uint256) returns
  (Position)`; new error `NotOffered()` (and `BadRecipient`, `BadPosition`,
  `TooManyPositions`, `EnforcedPause`, `ZeroAddress` are reused)

Market (`PositionMarket`):
- `list(uint256 positionId, uint256 price, uint64 expiry) returns (uint256 listingId)`
- `cancel(uint256 listingId)`
- `buy(uint256 listingId, uint256 expectedPrice) payable returns (uint256 newId)`
- `withdrawProceeds(address to)`, `sweepExcess()`
- views `getListing(uint256)`, `isBuyable(uint256)`, `quote(uint256 price) returns (fee, sellerGets)`,
  `activeListing(address seller, uint256 positionId)`, `proceeds(address)`, `totalProceeds()`,
  `nextListingId()`, `STAKING()`, `FEE_RECIPIENT()`, `FEE_BPS()`
- events `Listed(listingId, seller, positionId, price, expiry, amount, unlockTime, tier)`,
  `ListingCancelled(listingId, seller)`, `Sold(listingId, seller, buyer, positionId, buyerPositionId,
  price, fee)`, `ProceedsWithdrawn(seller, to, amount)`, `ExcessSwept(amount)`
- errors `NotOfferedToMarket`, `NotLocked`, `NotListed`, `NotSeller`, `ListingExpired`,
  `PriceMismatch(price)`, `BadPayment`, `PositionChanged`, `BadPrice`, `BadExpiry`, `NothingToWithdraw`,
  `EthTransferFailed`
- Selling flow on the Desk: `offerPosition(id, market)` + `list(...)` (two signatures). To fully delist:
  `cancel(listingId)` + `cancelPositionOffer(id)`. To buy: read `getListing` + `isBuyable`, send
  `buy{value: price}(listingId, price)`.

## Bots: rewards straight into Infinity/DCA (future)

Today `claimTo(escrow, …)` sends to any address. But `ArchitectInfinityGridV4` (`0xBdC7…DDeb`)
only accepts capital via `topUp(bytes32 id, bytes route, uint256 seedMinOut, uint256 gasAdd) payable`:
**native ETH** and **only from the maker**. "Rewards to your bot" requires, in the next bot version, a
`topUpFor(id, wethAmount, seedMinOut)` that pulls WETH with `transferFrom` from anyone, or an
`onRewardsReceived(id)` hook. On the staking side, a `claimToBot(bot, id, minOut)` would be enough.
