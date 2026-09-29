# CHANGES · fixes from the internal audit (Sept 27, 2026)

Base: `src_pre_fix/` (exact copy of the audited code; not included in this repository). The original PoCs, as they ran against that
code, are kept in `audit-poc-archive/pre-fix/` (not compiled; not included in this repository). In `test/audit/` each PoC `v_*.t.sol`
was converted into a regression test: it asserts the opposite of what the PoC proved (the attack no longer works).
Nothing was deployed and no transaction was sent. Everything runs on the local fork (block 74,180,000).

## Finding 1 · compound bonus collected and withdrawn after 2 days
- `compound(minOut)` becomes **`compound(minOut, tier)`**.
  - `TIER_FLEX (0)`: everything goes to flexible, **no bonus**.
  - `TIER_30 (1)` / `TIER_90 (2)`: opens a **new lock** with `total + bonus` (bonus = `min(10%, reserve)`).
    The bonus stays locked for 30/90 days and then exits through the 2-day cooldown.
- Regression: `v_economic_compound-bonus-exit-farming.t.sol` (compound+exit no longer beats `claim`;
  a lock-only wallet cannot extract a bonus without locking).

## Finding 2 · expired lock kept its boost until `kick()` and exited without cooldown
- Locks expire at **UTC midnight** on or after `now + 30/90 days`. Each lock schedules its
  weight drop in `boostDrop[midnight]`. Once that midnight passes, `totalBoosted` drops automatically (inside the
  global time advance) and the `rewardPerBoosted` at that instant is stored (`_rpbAt`).
- When the user is settled (any action of theirs, `kick`, or a view), anything overpaid since
  expiry is deducted exactly: `extra × (rpb_now − rpb_at_expiry)`. **The boost ends exactly at
  expiry, without a keeper.** `kick(user, id)` remains public but is optional (it only updates storage).
- Cost: one extra read (`nextExpiry`, in the same slot) per action; the loop over the user's
  positions runs only when one has expired. The global advance runs one iteration per elapsed midnight
  (with the daily harvest, one per day).
- **Exiting an expired lock goes through the 2-day cooldown**, same as flexible:
  `withdrawLocked(id)` now moves the amount to cooling (non-earning) and frees the slot; tokens exit
  via `withdraw()`.
- Regression: `v_locks_expired-lock-keeps-boost-until-kicked.t.sol` (50/50 with and without kick; exact boost
  until midnight; exit with cooldown; kick before expiry reverts).

## Finding 3 · the "7-day stream" decayed geometrically (1 wei per day was enough)
- Redesign using **tranches**: each `notifyRewards` opens a tranche with its own rate and its own end
  (`now + 7 days`). Earlier tranches are untouched: nobody can stretch a payout. The global rate is
  the sum of active tranches and drops at the exact second each one ends.
- Up to `MAX_TRANCHES = 8` tranches. The splitter now requires `minHarvestInterval ≥ 1 day`, so there are never
  more than 7. If the queue were full (only possible by calling `notify` directly), new rewards are added to the
  newest tranche, which is rescheduled to 7 days (safe and tested path, unreachable in production).
- **Dust**: the splitter does not notify if stakers' share is 0; staking does not open a tranche if the free
  amount is `< MIN_NOTIFY_WETH (1e12)` and `< MIN_NOTIFY_NLYRA (1e18)` (it carries over to the next one).
- Solvency: free = `balance − accrued debt − amount still to be emitted by tranches`; the separation
  between staked NLYRA and reward NLYRA is unchanged.
- Regression: `v_accounting_rollover-restream-geometric-decay.t.sol` (with and without 1 wei daily, Alice
  collects 100% in 7 days; Carol takes nothing from before) + `test_tranches_*` in the main suite.

## Finding 4 · lifetime cap of 32 positions and no renewal
- The cap applies to **open locks** (32-bit mask on the account). `withdrawLocked` frees the slot and
  the next lock reuses the first free slot; ids of open positions never change (no
  swap-and-pop, because the Desk and `kick` rely on ids).
- New **`extendLock(positionId, tier)`**: renews in the same slot, without moving tokens, starting now.
  It never shortens (neither a lower tier nor an earlier expiry). It also works on an expired lock.
- Regressions: `v_locks_positions-lifetime-cap-32.t.sol` (32 freed → 32 new; 40 monthly
  withdraw+relock cycles; 45 monthly cycles with `extendLock`) and
  `v_locks_no-lock-extension-relock.t.sol`.

## Finding 5 · pause + renounce trapped the reserve
- `renounceOwnership()` **always reverts** (`RenounceDisabled`).
- `fundBonusReserve` rejects deposits while paused.
- Pausing is now custom (no OZ `Pausable`) and **expires automatically after 30 days** (`MAX_PAUSE`): if the
  owner key is lost mid-pause, nothing stays locked forever. While paused, `stake`, `stakeLocked`,
  `extendLock`, `compound`, `cancelUnstake` and `fundBonusReserve` are blocked; `claim`,
  `requestUnstake`, `withdraw`, `withdrawLocked` and `kick` remain open.
- Regression: `v_access_pause-renounce-traps-bonus-reserve.t.sol`.

## Finding 6 · fake pool at deploy time and a callback that paid whatever was requested
- Constructor: each pool must equal `CREATE2(UNI_V3_FACTORY, keccak(token0, token1, fee),
  POOL_INIT_CODE_HASH)`, in addition to `pool.factory() == UNI_V3_FACTORY` and the correct tokens.
  Factory `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA` (the same for both pools, read from
  `pool.factory()`), init code hash `0xe34f199b…7b8b54` (the canonical v3-core one; verified by extracting the
  init code from the factory bytecode and recomputing both real addresses).
  - **Deviation from the requested fix:** instead of calling `factory.getPool(...)`, the CREATE2 address is used.
    It is equivalent (the factory only registers in `getPool` what it created with that CREATE2) and stronger:
    it guarantees the pool code is the real `UniswapV3Pool`. In addition, the development RPC did not serve the
    factory state at the pinned block (403), so with `getPool` the tests could not deploy.
    Separate verification against `latest`: `getPool(WETH, NLYRA, 10000)` and `getPool(WETH, USDG, 100)`
    return exactly the two pools.
- Callback: the swap stores pool, input token, amount and direction in **transient storage** (EIP-1153).
  The callback requires `msg.sender == current pool`, that the positive delta belongs to the input
  token and is **equal to the exact amount**, and it disarms itself after the first payment.
- Regressions: `v_swap-mev_misdeploy-pool-callback-trust.t.sol` (look-alike rejected, even if it
  imitates `factory()`/`fee()`; with the real pool's code replaced by a greedy one, claim reverts and
  principal remains intact) and `v_reentrancy_swap-callback-trusts-pool-owed.t.sol` (no fork: no
  mock passes the constructor).

## Finding 7 · the Desk's 24-hour rule did not exist on-chain
- New view **`eligibleBalance(user)`** = active stake (flexible + locks) **minus everything that came in during
  the last 24 h**. Inflows are: `stake`, `stakeLocked`, `compound` and `cancelUnstake`. Each
  inflow within the window restarts it for everything added in it (conservative: it never counts anything
  younger than 24 h). Outflows count immediately. Cost: one more slot per account (`recent`), written
  only on inflows.
- A flash-stake, a top-up in the same block as the trade, or "parking in cooldown and cancelling" all yield 0.
- Regression: `v_economic_desk-discount-no-onchain-age.t.sol`.

## Finding 8 · a new `requestUnstake` reset already-matured cooling
- When a new cooldown starts (`requestUnstake` or `withdrawLocked`), any cooling that has **already matured
  is paid out immediately** and only the new amount starts its clock. If the previous amount has not matured yet, it is added and the
  clock restarts for everything (documented; at most 2 days of the user's own funds).
- Regression: `v_locks_requestUnstake-resets-matured-cooldown.t.sol`.

## Hardening notes from the report (done)
- Note 1: `claimTo` pointing to the staking contract itself or to the splitter reverts (`BadRecipient`).
- Note 4: the splitter requires `splitBps ≥ 1000` and `minHarvestInterval ≥ 1 day`.
- Note 5: `cancelUnstake` respects the pause.
- Note 6: tolerated Pons errors are matched with `err.length == 4` in addition to the selector.
- Note 8: `MIN_HARVEST_INTERVAL` comment and README corrected.
- `ReentrancyGuardTransient` (same `nonReentrant`, cheaper).
- Not done (intentionally): `minOut == 0` is still allowed (handled by the Desk/bot, see README), bonus based on
  spot price (note 3; matters less now that the bonus requires a lock), per-period bonus cap.

## Tests
- `test/ForkBase.sol`: shared base (setUp, helpers, strong solvency invariant). PoCs no longer inherit
  the whole suite (previously each PoC re-ran the 25 tests).
- Main suite adapted and extended (tranches, dust, full queue, extendLock, slots, expiring pause,
  renounce, eligibleBalance, gas for every action).
- `test/StakingInvariant.t.sol`: handler-based invariants (48 runs × 60 calls, no reverts
  allowed) and `testFuzz_randomOps_solvent` extended to 24 steps covering all actions.
- Removed from `test/audit/` (copies in `audit-poc-archive/pre-fix/`, not included in this repository): the 18 PoCs without the `v_` prefix
  (older versions of the `v_` ones; some failed only because of the fork cache) and 4 duplicate `v_` files
  (`v_dos-gas_pause-renounce…`, `v_dos-gas_maxpositions…`, `v_splitter_interval…`,
  `v_economic_expired-lock-boost-and-instant-exit`), whose cases were folded into the regressions
  for the same finding.
- Fork limitation: the development RPC returned 403 for any slot or account not in the cache for the
  pinned block. Tests use only cached accounts, and for long swap sequences
  `_resetOracle()` sets the pool's `observationIndex` back to 79 (observations 82+ are not cached;
  this only affects the pool's TWAP, which is not used here).
- `dev` profile in `foundry.toml` (no viaIR) for fast iteration: `FOUNDRY_PROFILE=dev forge test`.
  With viaIR, compiling the whole suite takes ~15 min. Final gas and sizes are measured with the default profile.


---

# Round 2 · fixes from AUDIT-2.md + new tiers (Sept 28, 2026)

Base: `src_pre_r2/` (exact copy of the round 2 code; not included in this repository). The round 2 PoCs, as they ran
against that code, are kept in `audit-poc-archive/r2/` (not compiled; not included in this repository). In `test/audit2/` each `v_*` PoC
became a regression (the attack now fails), and the local stateful fuzz and the differential model
are kept and extended. Nothing was deployed and no transaction was sent; everything ran locally.

## Design decisions (Sept 28)
- **New tiers**: flexible 1x (2-day cooldown) · **7-day lock 1.25x** (`TIER_7 = 1`) · **14 days
  1.5x** (`TIER_14 = 2`) · **30 days 2x** (`TIER_30 = 3`). They expire at the UTC midnight following the
  duration. `extendLock` only to an equal or longer tier (an already-expired lock, which is at 1x, accepts
  any). `LOCK_90`/`BOOST_90` were removed.
- **Compound bonus**: **5%** (previously 10%) and **only** when compounding into the 30-day lock. 7d, 14d and
  flexible: no bonus.

## A · the bonus reserve could be drained with self-donated rewards
- In addition to the two reward streams (WETH, NLYRA), staking tracks the **bonus-eligible portion**
  of each one, using the same engine (per-tranche rate, `rewardPerBoosted`, per-user settlement, boost
  drop at expiry). **Only what the splitter sends** in that harvest is eligible
  (`notifyRewards(wethIn, nlyraIn)`); donations, amounts sent directly by Desk/OTC/bots and recycled amounts
  enter the tranche but are **not** eligible.
- `bonus = min(5% × (eligible NLYRA + NLYRA bought with eligible WETH), reserve)`. It never exceeds
  5% of the compounded amount. The reserve remains one-way.
- In addition, the splitter does not allow sending more than **90%** to stakers (`MAX_SPLIT_BPS`): self-donating through the
  splitter leaves at least 10% in the treasury and `0.9 × 1.05 < 1`, so it does not pay off even with 100% of the weight.
- New view `earnedBonusEligible(user)`.
- Regressions: `v_economic2_R2-ECON-1` (5 cycles of 100M donated: bonus 0, reserve intact, every
  cycle loses; through the splitter it loses ~half), `v_fix-review_R2-FC-2` (with 97.6% of the weight: bonus 0
  and net loss), `r2_econ_recent_window_and_slots` (c), `r2_fixcomplete_regress` (F2).

## B · the pause could be renewed forever
- `pause()` reverts (`PauseCooldown(allowedAt)`) while the pause is active and during the
  **30 days** following its end (`PAUSE_GAP`). `unpause()` only while paused (`NotPaused`) and it also
  starts those 30 days. In the worst case the contract is open at least half of the time.
- Exits and claims are never paused (`claim`, `requestUnstake`, `withdrawLocked`, `withdraw`,
  `kick`).
- Regressions: `v_access-deploy_R2-OWN-1` (the owner tries to renew every 29 days for ~2 years: there are
  entry windows and the reserve comes out), `v_time_R2-TIME-1`, `r2_owner_deploy_surface`,
  `r2_liveness_dos`, `test_pause_blocksOnlyNewStakes_bounded` and `invariant_pauseBounded`.

## C · fees sent directly to staking could sit idle
- The splitter's `harvest()` **always** calls `notifyRewards(ws, ns)` and no longer reverts with an empty
  splitter (`NothingToHarvest` was removed): the tranche also picks up whatever arrived directly at staking.
- New **`sweepDonations()`** on staking: callable by anyone, at most **one tranche per day**, with the same
  dust threshold (dust neither opens a tranche nor consumes the day). It works even if the splitter or Pons are
  broken. Amounts entering this way are not bonus-eligible.
- `MAX_TRANCHES` goes from 8 to **16**: splitter ≤ 7 active + `sweepDonations` ≤ 7 active. Merging with
  a full queue (which re-stretched the newest tranche, note 6) was replaced by **skipping** (the balance stays
  free for the next tranche); it is unreachable.
- Regressions: `v_critic_CRIT-2`, `test_directFees_sweepDonations`, `v_splitter_harvest-liveness…`
  (with Pons broken, direct fees are still streamed), `test_tranches_fullQueueSkipsSafely`,
  `test_trancheCount_dailyHarvestAndSweep` (maximum 14).

## D · compounding into a lock collided with the 32-position cap
- **`compound(minOut, tier, positionId)`**: `positionId = NEW_POSITION` (`type(uint256).max`) opens a
  new lock; any other id **adds to the open lock** and re-locks it from now under the
  `extendLock` rules (equal or higher tier, never expires earlier; an expired one accepts any tier). The bonus
  (if 30d) is added to the same lock. `extendLock` and compounding into an existing lock share the same
  internal function (`_addToLock`). The `LockExtended` event gains the `added` field.
- **Deviation from the suggestion**: `positionId = 0` was proposed for "open new", but position ids
  start at 0 (0 is a real lock), so the sentinel is `type(uint256).max`.
- Regressions: `v_fix-review_R2-FC-1` (60 daily compounds at 30d into the same lock),
  `v_economic2_R2-ECON-3` (32 slots full: compound into an active one and an expired one),
  `r2_econ_recent_window_and_slots`, `r2_fixcomplete_regress` (F1), `test_compound_intoExistingLock`.

## E · `eligibleBalance` never matured with consecutive deposits
- Two buckets per **UTC day** (`recentDay`, `recentCur`, `recentPrev`, in the same slots previously
  used by `recentTime`/`recent`): what comes in on day D is excluded during D and D+1 (**between 24 and
  48 h**) and counts afterwards, even if deposits keep coming in. A flash-stake still yields 0 for at
  least 24 h.
- Regressions: `v_economic2_R2-ECON-2`, `v_fix-review_R2-FC-3`, `v_economic_desk-discount…`,
  `test_eligibleBalance_twoDayBuckets` and, in the local fuzz, bounds on both sides (never counts anything
  < 24 h old, always counts anything > 48 h old).

## F · owner not verified at deploy time
- `Deploy.s.sol`: constant **`EXPECTED_OWNER`** (currently `address(0)`: the Safe address must be set;
  while it is empty the script does not deploy) that must match `STAKING_OWNER`; `chainid ==
  4663`; the owner must have code (Safe) and **not** be an EOA with a 7702 delegate; prints owner and
  chainid before broadcasting; post-deploy checks (owner, `pendingOwner`, not paused, tokens,
  pools, splitter = `CREATE(staking, 1)`, splitter parameters).
- Constructor: `Ownable` already rejects owner 0 (`OwnableInvalidOwner`); this is covered by a test (a
  custom check in the body would never execute, because the base constructor runs first).
- Regressions: `v_access-deploy_R2-OWN-2` (1-bit typo, other chain, EOA, 7702 and empty constant
  rejected; the valid path deploys), `r2_owner_deploy_surface`.

## G · WETH and USDG are upgradeable
- README corrected (WETH = aeWETH behind a proxy controlled by the chain owner; USDG = Paxos, UUPS,
  pausable and with freezing).
- Verified that **no principal exit calls WETH or USDG** (`requestUnstake`,
  `withdrawLocked`, `withdraw` only touch NLYRA): `v_tokens_TOK-1` with WETH broken (transfer and balanceOf
  revert) withdraws the flexible stake and an expired lock in full; same with USDG broken.

## Hardening notes applied
- Note 1: the constructor pins the **fee tier** of each pool (1% WETH/NLYRA, 0.01% WETH/USDG).
- Note 3: the callback reverts with **`PartialFill`** when the pool requests less than agreed (previously
  `BadCallback`); requesting more is still `BadCallback`.
- Note 5: the splitter requires the locker to have code and `minHarvestInterval ≤ 7 days`.
- Note 6: merging with a full queue was replaced by skipping (see C).
- New invariant: sum of future `boostDrop` = `totalBoosted − totalStaked` (fork and local).
- Not done: `poke(maxDays)` (it would take decades without activity to matter), `claimNlyraOnly`
  (G, optional: principal already exits without WETH), checking `getLaunchedToken(NLYRA).deployer` in the
  script (Pons ABI not verified here).

## Test environment
- **A single pinned block** for all fork tests: `ForkPin.BLOCK` in `test/ForkBase.sol`
  (can be overridden with `FORK_BLOCK=<n>` to warm up a new cache). Tests that forked on their
  own (74,180,000, 74,330,000 or `latest`) now use that same block.
- The development RPC only served the last ~15-20k blocks (~30 min); everything else came from the foundry cache.
  The re-pinning procedure is documented in `ForkBase.sol` and in the README.
- Removed from `test/audit2/` (copies in `audit-poc-archive/r2/`, not included in this repository): `critic_mainsuite_rerun`,
  `critic_invariant_rerun` (they repeated the suite at another block), `critic_deploy_script_sim` (replaced
  by the F regressions), `v_critic_CRIT-1` (probe of the dead block) and `r2_time_base.sol` (copy of
  ForkBase at `latest`).

## Result (Sept 28)
- **168/168 tests in 46 suites** with plain `forge test`, on the default profile (viaIR) and on
  `FOUNDRY_PROFILE=dev`. Main suite 34, fork invariants 3, round 1 41, round 2 90.
- Local stateful fuzz: 2 suites × 6 invariants, in dev 200 × 150 (60,000 calls), 0 violations;
  differential model: 3 × 48 scenarios of 150 steps + 2 fixed ones, no overpayment.
- Runtime size (default): RealYieldStaking 19,833 B (previously 16,919 B), NlyraFeeSplitter 3,263 B.
- Gas: table in the README (`test_gas_report`, default).
- During the default run, 4 failures appeared that were not present in dev: they were tests doing
  `vm.warp(block.timestamp + x)` in a loop (with viaIR, `block.timestamp` is not re-read after the warp).
  All time jumps in the tests were changed to `vm.getBlockTimestamp()`; the contract did not change.



---

# Round 3 · lock transfers, lock marketplace and owner = treasury (Sept 28, 2026)

Base: `src_pre_r3/` (exact copy of the code before this round; not included in this repository). Nothing was deployed and no
transaction was sent; everything ran locally (fork against a Robinhood Chain RPC, pinned block 74,478,703).

## Design decisions (Sept 28)
- **Owner = the treasury** `0xe30647793192D15BFA6E53aE8651368d332fe04C` (EOA with a MetaMask 7702
  delegate), no multisig. `script/Deploy.s.sol` already required `owner == TREASURY` with no code or with a 7702
  delegate (backup in `Deploy.s.sol.bak-safe`). Tests expecting the old rule were rewritten
  (`r2_owner_deploy_surface`: `test_deployScript_simulation` and `test_deployScript_rejectsBadOwners`;
  `v_access-deploy_R2-OWN-2`): the treasury passes with and without a 7702 delegate (also via `run()`), any
  other address (EOA, Safe or delegated) is rejected, and so is the treasury with regular contract code.
- **Lock transfers** in two steps inside staking.
- **Lock marketplace** in a separate contract, 0.5% fee to the splitter.

## A · Lock transfers (`RealYieldStaking`)
- `offerPosition(positionId, to)` → `acceptPosition(from, positionId)`; `cancelPositionOffer(positionId)`;
  `acceptPositionTo(from, positionId, recipient)` for operators (the marketplace). One offer per lock
  (`positionOffer[holder][id]`); offering again replaces it.
- The whole lock moves (amount, `unlockTime`, tier). `totalBoosted`, `totalStaked` and `boostDrop` do not
  change: the lock still exists and its boost drop was already scheduled at its midnight.
- **Rewards:** `acceptPosition` settles both wallets (`_update`) before moving the weight. Everything accrued
  up to that second, including the bonus-eligible portion, stays in the sender's `_rewards`; the
  recipient starts with `rewardPerBoostedPaid` = now. An expired lock is settled at 1x in that `_update` and
  travels at 1x. The sender keeps `nextExpiry` (it remains a valid lower bound; at most one extra
  `_demote` pass); the recipient lowers it if the lock expires earlier.
- **No dangling offers:** `extendLock`, `compound` into that lock (`_addToLock`),
  `withdrawLocked` and the transfer itself clear the offer. A reused slot never inherits an offer.
- **Cooldown:** it belongs to the account; `withdrawLocked` takes the amount out and frees the slot, so a lock with
  a requested withdrawal no longer exists (there is no "lock with pending unstake" case). Cooling does not travel.
- **Cap of 32:** the recipient uses its first free slot (`_putPosition`, extracted from `_openLock`, same
  behavior); full → `TooManyPositions`.
- **`eligibleBalance`:** the received lock is marked as a new deposit of the recipient (`_markIncrease`):
  it is excluded for 24-48 h. For the sender it drops immediately. A flash-transfer (or a round trip in the same
  block) yields a 0 discount.
- **Compound bonus:** eligibility belongs to whoever accrued it; it does not travel. A bonus already added to a 30-day
  lock travels with the lock but stays locked until expiry.
- **Pause:** `offerPosition`, `acceptPosition` and `acceptPositionTo` respect the pause; cancelling does not.
- Invalid destinations: 0, the staking contract itself, the splitter, oneself (`BadRecipient`/`ZeroAddress`).
- Events `PositionOffered`, `PositionOfferCancelled`, `PositionTransferred` (with `operator`). New error
  `NotOffered`. New view `positionOf(user, id)`.

## B · `PositionMarket` (new contract)
- No owner, no setters. `FEE_BPS = 50` **constant** (chosen over "owner with cap ≤ 100 bps": nothing to
  trust or protect; to change it, a new marketplace is deployed and users offer their locks to it).
- **Per-lock approval:** listing requires `staking.positionOffer(seller, id) == market`. There is no general
  approval; the marketplace only calls `acceptPositionTo(seller, id, msg.sender)` inside `buy`.
- **Only locked positions** (`unlockTime > now`, boosted tier); expired ones cannot be listed or bought
  (they are already liquid). A listing dies automatically when the lock expires or when the listing expires.
- **Lock snapshot** (amount, expiry, tier) in each listing: if the seller extends it, compounds
  into it, transfers it, withdraws it or withdraws the offer, `buy` reverts (`PositionChanged`/`NotOffered`),
  even if the seller offers it again afterwards.
- **Price front-running:** `buy(listingId, expectedPrice)` with exact `msg.value`; relisting
  changes the `listingId`.
- **Payments:** the fee (rounded up) is pushed to the splitter on purchase (immutable, known contract,
  empty `receive()`); the seller's net amount is a **pull payment** (`proceeds`, `withdrawProceeds`).
  CEI + `nonReentrant` everywhere; `buy` does not call buyer or seller code.
- **Stuck ETH:** no `receive`; `sweepExcess()` sends anything above `totalProceeds` to the splitter.
- Constructor: the staking contract must have code and its splitter must point back to it.
- Fee path verified end to end: ETH in the splitter → `harvest()` wraps it
  (real aeWETH on the fork) → 50% to staking (7-day tranche, bonus-eligible) and 50% to the treasury.

## C · Deploy
- `Deploy.s.sol` also deploys the marketplace (`new PositionMarket(address(st))`) in the same broadcast and
  verifies post-deploy: code, `STAKING`, `FEE_RECIPIENT == splitter`, `FEE_BPS == 50`, empty, `quote`.
  `deploy()`/`run()` now return `(staking, splitter, market)`.

## Tests
- `test/r3/r3_transfer_local.t.sol` (16), `test/r3/r3_market_local.t.sol` (22), `test/r3/r3_fork.t.sol`
  (3, including `test_gas_r3`).
- `inv2_stateful_local`: new actions `transferPosition` (with a third party attempting to accept, and
  cancellations) and `marketSale` (offer, listing, purchase with ETH), in the exact per-user reward
  model (the sender keeps what was accrued, the recipient earns from then on) and in the
  principal/weight/cooling/`eligibleBalance` checks; new invariant `invariant_marketEth` (marketplace ETH ==
  debt to sellers; paid == debt + fees). In dev: 200 × 150 per invariant, 0 violations.
- **211/211 tests in 49 suites** (dev and default/viaIR).

## Sizes (default, runtime)
RealYieldStaking **21,527 B** (previously 19,833; 3,049 B margin under 24,576), PositionMarket **4,925 B**,
NlyraFeeSplitter 3,263 B (unchanged).
