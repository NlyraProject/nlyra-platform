# Internal Audit — Round 1 — NLYRA Real Yield Staking v2

**Date:** Sept 27, 2026 · **Code status:** NOT deployed · **Scope:** `src/RealYieldStaking.sol` (587 lines), `src/NlyraFeeSplitter.sol` (130 lines), `src/interfaces/External.sol`, and the integration with `PonsLaunchLocker` (reference copy in `reference/`, not included in this repository).

**Methodology:** every finding has a proof of concept (PoC) in `test/audit/`, run with Foundry 1.5.1 against a fork of Robinhood Chain (4663) pinned at block 74180000. Nothing was deployed and no real transactions were sent. The 25 original tests still pass.

---

## One-line summary per topic

**No critical or high-severity issues were found.** No external attacker can steal stakers' principal or render the contract insolvent. What we did find are **design flaws that move value from one staker to another**, some **configuration/administration pitfalls**, and **README promises the code does not keep** (for example, the "7-day stream"). Nearly everything can be fixed with small changes, but **they must be made before deployment**, because the contracts are immutable and cannot be corrected afterwards.

| # | Finding | Severity | Who loses? |
|---|----------|-----------|----------------|
| 1 | The compound bonus can be collected and withdrawn after 2 days | Low (fix before funding the reserve) | Donors to the bonus reserve |
| 2 | An expired lock keeps earning 1.5x/2.5x until someone calls `kick()` | Low | Other stakers |
| 3 | The "7-day stream" actually decays geometrically (1 wei per day is enough to stretch it) | Low | Whoever exits ~7 days after a large inflow |
| 4 | The 32-position cap is lifetime, and there is no way to renew a lock | Low | The loyal user who renews every month |
| 5 | Pause + owner renouncement traps the bonus reserve forever | Low | Donors to the bonus reserve |
| 6 | The constructor accepts any pool with the correct pair, and the callback pays whatever the pool asks | Low (deployment only) | All stakers, if misdeployed |
| 7 | The Desk's "stake at least 24 h old" rule does not exist on-chain | Low (integration) | The protocol (fee discounts wrongly granted) |
| 8 | A new `requestUnstake` resets the clock on funds already ready to withdraw | Low | The user themselves |
| 9 | Staker revenue depends on the treasury key | Informational (trust) | All stakers, if the key is compromised |
| 10 | If the fee redirect is activated before v1 stakers migrate, the first entrants capture almost everything | Informational (operational) | v1 stakers who arrive late |

---

## Confirmed findings (most to least important)

### 1. The compound bonus (10%) can be collected and withdrawn after 2 days: the reserve is given away without buying loyalty
**Severity:** Low. This is the most important one to fix if the reserve is going to be funded.
**Location:** `RealYieldStaking.sol` · `compound()` (L421-436), `requestUnstake()` (L289-300), `withdraw()` (L321-332).

**Impact:** `compound()` adds the reward + 10% bonus to the **flexible** stake, with no marker or vesting. The user can immediately request an unstake of that amount and withdraw it 2 days later. Doing "compound → unstake → withdraw" always yields ~10% more than any `claim` mode, and the only cost is 2 days of not earning on that amount. The reserve ends up as a +10% subsidy captured first by the most active and largest wallets, and it retains no one.
**Who loses:** whoever funded the reserve (the team, the Desk, or the community). With current numbers (~US$489/week for stakers), a 10M NLYRA reserve (~US$2,250) lasts ~46 weeks, or less if some whales compound every day.

**Evidence:** `test/audit/v_economic_compound-bonus-exit-farming.t.sol` · 2/2 PASS.
- Alice `claim(ALL_NLYRA)` = 203,130.85 NLYRA. Bob `compound → requestUnstake → withdraw` = 223,240.84 NLYRA (**+9.9%**) and his principal remains intact at 100M.
- A wallet holding only a 90-day lock can also exploit it: it took 40,607 NLYRA of bonus in one week.

**Remediation:** pay the bonus **only if the compound goes into a lock**. In `compound()` set `bonus = 0` and add `compoundToLock(tier, minOut)`, which creates a 30- or 90-day position containing `total + bonus`. Alternative: hold the bonus in a vesting balance that is forfeited (returned to the reserve) if an unstake is requested before N days. **In the meantime, do not fund the reserve.** (README L155 already leaves this question open: "Only if compounded into a lock?". The answer must be yes.)

---

### 2. An expired lock keeps earning 1.5x/2.5x until someone calls `kick()`, and it also exits without a cooldown
**Severity:** Low. Two reports merged: *locks/expired-lock-keeps-boost-until-kicked* and *economic/expired-lock-boost-and-instant-exit*.
**Location:** `kick()` (L356-369), `withdrawLocked()` (L334-352), `_update()`.

**Impact:** when a 90-day lock expires, the owner can withdraw at any time and no longer bears any risk, but their weight stays at 2.5x. The only thing that lowers it is `kick()`: it pays nothing to the caller and does not claw back what was over-earned before the kick. If nobody calls it, the owner of the expired lock is overpaid every week. In addition, an expired lock is withdrawn instantly, whereas the flexible stake waits 2 days without earning.
**Who loses:** the other stakers. Measured example: an expired 50M lock in a ~362M pool takes 28.6% of the stream instead of 13.8%, i.e. ~US$72/week taken from the others.

**Evidence:**
- `test/audit/v_locks_expired-lock-keeps-boost-until-kicked.t.sol` · 2/2 PASS. Without a kick: Alice 7.14 WETH and Bob 2.86 WETH. With a kick at expiry: 5.00 WETH each. `kick` before expiry reverts (`StillLocked`) and costs ~12k gas.
- `test/audit/v_economic_expired-lock-boost-and-instant-exit.t.sol` · 2/2 PASS. Share of 2860 bps without a kick versus 1381 bps with a kick. A late kick does not recover what has already accrued.

**Why it is not more severe:** `kick()` is public and cheap, and the affected parties have an incentive to call it. There is no capital or solvency risk.

**Remediation:**
- (a) **Mandatory:** a keeper (on the existing cron infrastructure) that calls `kick(user, id)` as soon as each lock expires. Ideally with a `kickMany()` that processes several at once.
- (b) In the contract, in `_update(user)`, reduce the user's own expired positions to 1x. There are at most 32, so the loop is bounded. That way any user action "de-boosts" them.
- (c) Optional: pay the kicker ~1% of what the user accrued in that `_update`.
- Document that the no-cooldown exit from an expired lock is intentional, or make `withdrawLocked` of an already-kicked position go through the 2-day cooldown.

---

### 3. The "7-day linear stream" does not exist: with daily harvests the payout decays geometrically, and anyone can force it with 1 wei per day
**Severity:** Low. Three reports merged: *accounting/rollover-restream*, *splitter/interval-does-not-prevent-stretch*, and the informational note on the payout curve.
**Location:** `RealYieldStaking.notifyRewards()` (L236-249), `NlyraFeeSplitter.harvest()` (L75-114), the `MIN_HARVEST_INTERVAL` comment (NlyraFeeSplitter L27-29), README "Stream stretching" (L175).

**Impact:** each `notifyRewards` takes **everything** not yet emitted (including the part of the previous stream not yet paid out), spreads it over 7 new days, and pushes back the end date. `harvest()` is public and works with as little as 1 wei donated, because it tolerates `NoFeesToCollect`. With one harvest per day, each day pays out 1/7 of what remains: after 7 days **34%** is still unpaid, half is paid in ~4.5 days, and 99% only after ~30 days. The normal keeper produces the same effect, so an attacker makes nothing worse than daily operations already do. The code comment stating that the 1-day interval "prevents stretching the stream" **is false**: without the cap ~37% would remain, with the cap ~34%.
**Who loses:** nobody loses in aggregate, because the contract remains solvent. But value shifts between people: whoever exits ~7 days after a large inflow (a donation, a fee spike, or the first harvest) leaves behind ~1/3 of what they earned, which goes to those who stay or who enter later.

**Evidence:**
- `test/audit/v_accounting_rollover-restream-geometric-decay.t.sol` · PASS. Without extra harvests, Alice collects 100.00%. With 1 wei + a harvest per day, Alice collects 66.00%, and Carol, who entered after the inflow, takes 32.65%.
- `test/audit/v_splitter_interval-does-not-prevent-stretch.t.sol` · 2/2 PASS. The 7-day payout is 66.01%, exactly `1-(6/7)^7`.

**Remediation:**
- In `harvest()`, do not call `notifyRewards` (or revert) when `ws == 0 && ns == 0`.
- In `notifyRewards`, if a stream is in progress and the new amount is small (for example, less than 10% of what remains to be emitted, in both tokens), **keep `periodFinish`** and recompute `rate = free / (periodFinish - now)`. Otherwise, do what is done today.
- To make each inflow truly last 7 days: with a stream in progress, `rate += new / (periodFinish - now)` without moving the end, or per-tranche streams (more gas).
- Note: the "classic Synthetix" formula `(leftover + new)/7d` proposed in one review pass **is exactly what is already implemented** and fixes nothing.
- At a minimum: correct the comment and the README ("66% in 7 days, ~99% in 30 days with daily harvests").

---

### 4. The 32-position cap is lifetime, and there is no way to renew a lock
**Severity:** Low. Three reports merged: *locks/positions-lifetime-cap-32*, *dos-gas/maxpositions-lifetime-cap*, and *locks/no-lock-extension-relock*.
**Location:** `_stake()` (L275-279), `withdrawLocked()` (L343-344).

**Impact:** `_stake` counts the array length (`_positions[user].length >= 32`), and `withdrawLocked` sets the amount to 0 but never frees the slot. A user who renews their 30-day lock every month, which is exactly the behavior we want to reward, **can never lock again after ~32 months**, even with no open locks. If they split their stake into small locks, this happens within months. In addition, renewing requires withdrawing, approving, and locking again, which uses up one slot per renewal.
**Who loses:** the user permanently loses the 1.5x/2.5x tiers on that wallet. No funds are lost. If they move to another wallet, they lose their Desk discount history. Nobody else can trigger this for them.

**Evidence:**
- `test/audit/v_locks_positions-lifetime-cap-32.t.sol` · PASS (32 cycles, "live locked: 0", `stakeLocked` reverts with `TooManyPositions`).
- `test/audit/v_dos-gas_maxpositions-lifetime-cap.t.sol` · 2/2 PASS.
- `test/audit/v_locks_no-lock-extension-relock.t.sol` · 2/2 PASS (no `relock` exists, and each renewal takes a new slot).
- Note: the older PoC `locks_positions-cap-lifetime.t.sol` fails because of a test error (`expectRevert` consumed by the `TIER_90()` getter), not because of the contract.

**Remediation:**
- In `_stake`, reuse a slot with `amount == 0` (searching among the ≤32) before doing a `push`, and count **open** locks (`openLocks[user]`: +1 on lock, -1 in `withdrawLocked`; `kick` does not change it). This keeps IDs stable and the array never exceeds 32. Do not use swap-and-pop, because it renumbers the IDs used by the Desk and `kick`.
- Add `relock(positionId, tier)`: renews in the same slot without moving tokens, only allows extending (never shortening), calls `_update` first, and adjusts `totalBoosted` by the difference.

---

### 5. Pausing and then renouncing ownership traps the bonus reserve forever (and funds are still accepted during the pause)
**Severity:** Low. Two reports merged: *access* and *dos-gas*.
**Location:** `compound()` L421 (`whenNotPaused`), `fundBonusReserve()` L440 (no `whenNotPaused`), inherited `renounceOwnership`, `recoverERC20` L493-494.

**Impact:** `compound()` is the **only** exit from the bonus reserve and does not work while paused. If the owner pauses and then calls `renounceOwnership()` (a single step; `Ownable2Step` does not prevent it), or loses the key while paused, nobody can ever unpause again. The reserve is trapped forever: `recoverERC20` does not allow withdrawing NLYRA and harvests do not recycle it. Meanwhile, `fundBonusReserve` keeps accepting donations.
**Who loses:** bonus donors. Stakers do **not** lose capital or rewards: `claim`, `withdraw`, and `withdrawLocked` keep working.

**Evidence:** `test/audit/v_access_pause-renounce-traps-bonus-reserve.t.sol` and `test/audit/v_dos-gas_pause-renounce-traps-bonus-reserve.t.sol` · PASS. 10,000,000 NLYRA trapped after everyone exited, and 5M more accepted during the pause. The control test shows that a pause on its own can be reverted.

**Remediation:**
- (1) Override `renounceOwnership()` so that it always reverts, or at least reverts while paused.
- (2) Add `whenNotPaused` to `fundBonusReserve`.
- Optional: a pause that expires automatically (for example 30 days), or allow `compound` while paused.

---

### 6. The constructor accepts any contract with the correct token pair, and the swap callback pays it whatever it asks
**Severity:** Low. This is a risk **only at deployment time**, but if it happens it is irreparable.
**Location:** `_poolDir()` (L183-190), `uniswapV3SwapCallback()` (L474-480), `_swap()` (L459-472).

**Impact:** `_poolDir` only checks `token0/token1`, not the factory or the fee tier. The callback pays the positive delta reported by the pool, with no cap relative to the requested `amountIn`, and the `PartialFill` check trusts the numbers returned by that same pool. If a malicious contract impersonating a pool is passed in by mistake at deployment (a typo, an address copied from a fake site), **the first `claim(ALL_ETH)` hands it all of the contract's NLYRA, including everyone's principal**.
**Who loses:** all stakers, but only if the deployment uses a wrong address. With the real pools (canonical factory `0x1f7d7550…2EfA`, fees 10000 and 100) the pool charges exactly what is requested and there is no way to exploit it. No user or attacker can change the pool after deployment.

**Evidence:**
- `test/audit/v_swap-mev_misdeploy-pool-callback-trust.t.sol` · 2/2 PASS. The fake pool was accepted and drained 1,011,000 NLYRA, leaving 0. The real pools are canonical and charge exactly.
- Also `test/audit/v_reentrancy_swap-callback-trusts-pool-owed.t.sol` (with mocks, 3/3 PASS): nobody can call the callback from outside a swap.

**Remediation** (either one is sufficient; doing both is ideal):
- (1) In `_swap`, store the expected `amountIn` (transient storage) and in the callback require `0 < owed <= amountIn` and that the positive side is the input token.
- (2) In the constructor, verify `IUniswapV3Factory(0x1f7d…2EfA).getPool(WETH, NLYRA, 10000) == poolNlyra` and `getPool(WETH, USDG, 100) == poolUsdg`.
- And in the deploy script, manually verify the addresses against the block explorer.

---

### 7. The Desk's "stake at least 24 h old" rule cannot be read on-chain and can be bypassed
**Severity:** Low. This is an integration requirement for the Desk, not a contract bug.
**Location:** `stakeOf()` (L579-582), `cancelUnstake()` (L305-318), `compound()`.

**Impact:** `stakeOf` returns the current stake, with no timestamp. There are two ways to game the Desk discount:
- **(a) Top-up:** stake 1 NLYRA, wait 24 h, and add the large amount in the same block as the trade. This works if the Desk measures age from the first `Staked` event.
- **(b) Parking:** request an unstake of everything, wait out the cooldown, and hold the funds liquid and earning nothing. Then `cancelUnstake` right before the trade and `requestUnstake` right after. `cancelUnstake` and `compound` do not emit `Staked`.

**Who loses:** the protocol, up to 0.2% of that wallet's volume in uncollected fees. Stakers lose nothing.

**Evidence:** `test/audit/v_economic_desk-discount-no-onchain-age.t.sol` · 2/2 PASS. In both cases the naive rule grants the full tier, and `min(stakeOf now, stakeOf 24 h ago)` returns 1e18 and 0 respectively.

**Remediation:** in the Desk, use as the discount stake the **minimum of `stakeOf` over the entire last 24 h**, reconstructed from the `Staked`, `Compounded`, `UnstakeRequested`, and `UnstakeCancelled` events, or with historical `eth_call` at every block where it changed. Taking only the two endpoints is not enough. Never measure age from the first `Staked`. Optional on-chain: `lastIncrease[user]` updated in `_stake`, `cancelUnstake`, and `compound`.

---

### 8. A new `requestUnstake` resets the 2-day clock also for funds that were already ready
**Severity:** Low (UX; the user only harms themselves).
**Location:** `requestUnstake()` (L289-302).

**Impact:** Alice requested to withdraw 1M, the 2 days passed, and she can now withdraw. If she requests 1 more NLYRA (manually or because the frontend does it), `cooldownEnd` goes back to "now + 2 days" and `withdraw()` reverts for everything, including the 1M that was already free. Those tokens earn nothing in the meantime.
**Who loses:** only the user: up to 2 days of yield on that amount. Nobody else can trigger it.

**Evidence:** `test/audit/v_locks_requestUnstake-resets-matured-cooldown.t.sol` · PASS (`relock_seconds: 172800`).

**Remediation:** in `requestUnstake`, if there is already matured cooling, revert with `CooldownFinishedWithdrawFirst()` or pay it out automatically first (this is safe: `nonReentrant` + CEI). In the frontend, call `withdraw()` before any new `requestUnstake`.

---

### 9. Staker revenue depends on the treasury key, and it cannot be rotated without redeploying
**Severity:** Informational (trust assumption, already mentioned in README L167-169).
**Location:** `NlyraFeeSplitter` (immutable `TREASURY` and `STAKING`, tolerance of `NotAuthorized` at L88), immutable `RealYieldStaking.feeSplitter` (L69/L237).

**Impact:** the treasury `0xe306…fe04C` is the deployer of the Pons launch and has an EIP-7702 delegate. With that key one can change the `feeRedirect`, collect 100% of the accumulated fees (including the stakers' half), and point it back at the splitter. The splitter only emits `CollectSkipped`. A trail does remain in the locker (`FeeRedirectUpdated`, `FeesClaimed`), but nobody is monitoring it. And if a compromised treasury had to be removed, the entire staking system would need to be redeployed and everyone migrated, with 90-day locks still running.
**Who loses:** all stakers lose future yield and unharvested fees. Capital and already-streamed rewards are not at risk.

**Evidence:** `test/audit/v_access_treasury-can-divert-staker-yield-no-rotation.t.sol` · 2/2 PASS (the attacker took 0.0368 WETH + 379,074 NLYRA in fees; a new splitter is rejected with `OnlySplitter`).

**Remediation (operational, not code):**
- (a) Before `setFeeRedirect`, move the deployer/treasury role to a multisig or timelock without a 7702 delegate. If Pons does not allow transferring the deployer, keep the key in cold storage and remove the delegate.
- (b) Set up a cron-based monitor with Telegram alerts that fires if `feeRedirects(NLYRA) != splitter`, if a `FeesClaimed` for NLYRA appears from any account other than the splitter, or if the splitter emits `CollectSkipped(NotAuthorized)`.
- (c) Expand the README note: the treasury can not only cut off future fees, it can also take the accumulated ones.
- Clarification: a `setTreasury` in the splitter does **not** protect stakers against a compromised key, because that key controls Pons directly.

---

### 10. If the fee redirect is activated before v1 stakers migrate, the first entrants capture almost everything
**Severity:** Informational (launch sequencing).
**Location:** deployment sequence (`harvest` / `notifyRewards`).

**Impact:** v1 pays out until Oct 17, so its ~353-362M will not migrate before then. If the redirect to the splitter is activated earlier, with very little stake in v2, anyone who stakes even 1 wei captures ~100% of the stream (~US$489/week, on the order of US$1.5-2k in total if it is brought forward by several weeks). This is the normal behavior of a pro-rata staking contract: it is open to everyone and takes nothing already earned from anyone. But it is best avoided.

**Evidence:** `test/audit/v_economic_launch-thin-stake-stream-capture.t.sol` · PASS. With 1 wei ~100% is collected, a 100M seed stake neutralizes it, and a late entrant earns pro-rata from their entry.

**Remediation:** before `setFeeRedirect(NLYRA, splitter)`, have the treasury stake a significant seed amount in a lock. Or keep the redirect pointed at the treasury until Oct 17 and **announce the date publicly** so everyone enters together.

---

## Dismissed claims

- **The callback pays whatever the pool asks (reentrancy lens):** this is the same mechanism as finding 6. It only occurs with a misconfigured deployment. Nobody can call the callback from outside and the real pools charge exactly. Reported once, as finding 6.
- **`minOut` also covers the non-swapped portion, so a sandwich steals:** the mechanism is real, but the sandwich **loses money** at every size tested (from 0.0005 to 1 WETH, even with `minOut = 0`), because the pool charges 1% in each direction and the swapped portion is small. In addition, there is no public mempool. Kept as a UX note.
- **`harvest()` gets stuck if Pons reverts with a different error (splitter and dos-gas lenses):** only reproducible with mocks. In the real Pons the factory is set once and is neither a proxy nor pausable, `_lockedTokens` is never deleted, and the Pons owner cannot make `collectFees` revert. Nobody can trigger it. If it did happen, ~1 day of fees would be stuck without touching capital. Caution: do **not** "tolerate any revert with data", because that reopens an out-of-gas griefing vector.

---

## Informational and hardening notes

1. **`claimTo` to itself or to the splitter:** if `recipient` is the staking contract or the splitter, the reward is marked as paid but the tokens remain as free balance and get redistributed. → Revert if `recipient == address(this) || recipient == feeSplitter`.
2. **Swaps without a price limit and `minOut = 0` accepted** (including `claimTo` for bot escrows). → Revert on `minOut == 0` in swap modes, or add a deadline and `sqrtPriceLimit`. Document that in `ALL_USDG` the `minOut` is denominated in USDG units (6 decimals). The Desk and bots must always compute a real `minOut` from the swap quote, not from the total.
3. **The compound bonus is computed on NLYRA bought at the spot price** and could be inflated by pushing the price down in the same transaction. Today this is not profitable because of the pool's 1% fee. → Compute the bonus on `n` or with a TWAP, or cap it per period. If the fix for finding 1 is applied (bonus only into a lock), this matters less.
4. **The constructor does not bound** `splitBps = 0` or `minHarvestInterval = 0`. → Require ranges (for example `splitBps >= 1000`, interval `>= 1 hour`) or make them constants, and verify them in the deploy script.
5. **`cancelUnstake` lacks `whenNotPaused`:** while paused, funds in cooling can start earning again. → Add the modifier or document that the pause only blocks new deposits and compounding.
6. **Tolerated errors compared by selector only:** a `NotAuthorized()`/`NoFeesToCollect()` bubbling up from a nested contract is also accepted. → Additionally require `err.length == 4`.
7. **`PartialFill` if the pool lacks liquidity:** `ALL_ETH`, `ALL_NLYRA`, `ALL_USDG`, and `compound` revert if the immutable pool cannot absorb the full amount, and the only way out is `AS_IS`. → Have the Desk simulate the transaction and offer `AS_IS` automatically if it fails.
8. **Outdated README:** correct "7-day stream" (finding 3), the stretching note (L175), and the `MIN_HARVEST_INTERVAL` comment. Document the keeper dependency for `kick` (finding 2) and the trust assumption on the treasury (finding 9).
9. **Test infrastructure:** the Robinhood Chain RPC backing the fork currently returns "missing trie node / historical state" for accounts it does not have cached. Some older PoCs in `test/audit/` (for example `swap-mev_callback-pays-unbounded-owed.t.sol`) fail **because of this**, not because of the code. The `v_*.t.sol` PoCs were adapted to use cached addresses.

---

## Verdict: is it ready to deploy?

**Not yet.** It is close: there is no way to steal capital, the contract remained solvent in every test, and the owner's permissions are narrow (pausing new stakes and rescuing foreign tokens). But because everything is **immutable**, anything that goes wrong cannot be corrected. Outstanding items:

**Code fixes before deployment (in this order):**
1. Compound bonus only into a lock (`compoundToLock`), or `bonus = 0` until decided (finding 1).
2. Reuse slots and count open locks, plus `relock()` (finding 4).
3. Reduce expired locks to 1x in `_update(user)`, plus `kickMany()` (finding 2).
4. `notifyRewards` without resets from dust, and `harvest` that does not notify when 0 reaches stakers (finding 3).
5. Cap `owed <= amountIn` in the callback and verify the pools against the factory in the constructor (finding 6).
6. Block `renounceOwnership` and add `whenNotPaused` to `fundBonusReserve` (finding 5).
7. `requestUnstake` that does not reset already-matured cooling (finding 8), and notes 1, 4, 5, and 6.

**After the fixes:**
- Re-run the 25 original tests and **turn each PoC in `test/audit/v_*.t.sol` into a regression test** in which the attack must now fail (i.e., the healthy case passes).
- Add fuzzed invariant tests (solvency: `balance NLYRA >= staked + cooling + bonusReserve + rewards owed`, and sum of payouts ≤ inflows) and a multi-month simulation with daily harvests, kicks, and renewed locks.
- **Independent external audit** before moving the ~350M from v1 in. This contract will custody everyone's principal, and this review is internal.

**Operational, before activating the fee redirect:**
- Treasury/deployer on a multisig or timelock without a 7702 delegate, and a Telegram monitor for `feeRedirects` + `CollectSkipped` (finding 9).
- Keeper performing a daily harvest and `kick` of expired locks (findings 2 and 3).
- Treasury seed stake in a lock before the redirect, or redirect only once v1 ends (Oct 17), with the date announced (finding 10).
- Desk: discount computed using the minimum of `stakeOf` over the last 24 h (finding 7), `minOut` always computed, and fallback to `AS_IS`.
- Deploy script that verifies pool addresses, `splitBps`, and `minHarvestInterval`.
- Do not fund the bonus reserve until the fix for finding 1 is in place.
