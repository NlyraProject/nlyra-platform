# Internal Audit — Round 2 — NLYRA Real Yield Staking v2 (remediated code)

**Date:** Sept 27, 2026 · **Status:** NOT deployed · **Scope:** `src/RealYieldStaking.sol` (907 lines), `src/NlyraFeeSplitter.sol` (135 lines), `src/interfaces/External.sol`, `script/Deploy.s.sol`, diffed against `src_pre_fix/` (not included in this repository).

**Methodology:** 10 independent review passes, each with a different focus: review of the fixes, tranche engine, time boundaries, stateful fuzzing, differential model, swap/callback, permissions and deployment, tokens, economics, and liveness. A final critic pass then looked for gaps between the others. Every confirmed finding has a PoC in `test/audit2/` that was independently re-run in a separate pass. `src/` was not modified, nothing was deployed, no transactions were sent, and no production infrastructure was used.

---

## 1. Summary and verdict

**There is nothing critical, high, or medium.** In no test was it possible to steal principal, render the contract insolvent, overcollect, or block a user's exit. All 8 fixes from Round 1 work. The new accounting (tranches, expiry at UTC midnight, exact per-user settlement) matches, to the wei, a separately written reference model across ~4,500 random scenarios and ~110,000 fuzz calls.

**7 low-severity findings** and **1 test-environment issue** were identified:

| # | Finding | Severity | Who loses? |
|---|----------|-----------|----------------|
| A | A whale holding more than ~91% of the weight drains the bonus reserve by donating rewards to itself | Low | Whoever funded the bonus reserve |
| B | The owner can renew the pause forever: the 30 days only protect against a lost key | Low | New stakers, the reserve, and those who want to renew |
| C | Fees sent directly to the staking contract are not distributed if the splitter does not leave ≥1 wei for stakers | Low | Stakers (delay, not loss) |
| D | Compounding into a lock opens a new position every time, and after 31 daily compounds it hits the 32-position cap | Low | Whoever compounds daily (bot/Desk) |
| E | `eligibleBalance`: "recent" stake never matures if something is added every less than 24 h | Low | The user who DCAs or compounds daily (loses the Desk discount) |
| F | The owner is written directly in the constructor and the script does not verify it: a typo cannot be fixed | Low (deployment) | The protocol (the emergency brake is lost) |
| G | The README says WETH and USDG are "standard", but they are upgradeable. If WETH breaks, NLYRA rewards get stuck | Low (trust/docs) | Stakers, only for rewards and only while WETH is broken |
| — | Environment: the fork cache for block 74180000 was emptied and a plain `forge test` now fails in setUp | Info (process) | Nobody on-chain. But the external auditor cannot reproduce the suite |

**Verdict: nearly ready.** A, B, and C must be decided before deployment, because the contract is immutable. All three have small fixes. D and E will look bad in the Desk from the first month of use, so they should be fixed in the same pass. F and G concern the script and README. None of this justifies holding back the external audit: they can proceed in parallel.

---

## 2. Confirmed findings (most to least important)

### A. The bonus reserve can be drained with self-donated rewards (thin-stake phase)
**Severity:** Low · **Location:** `notifyRewards()` L394-432 (free balance includes direct donations, L377) and `compound()` L654-671 (bonus = 10% of everything earned, L665). Reported independently by two lenses (R2-FC-2 and R2-ECON-1).

**Impact:** the 10% bonus is paid on any reward, regardless of its source. The attack:
1. The attacker sends NLYRA directly to the staking contract.
2. Calls `harvest()`, which is public (2 wei in the splitter is enough). The donation becomes a 7-day tranche.
3. After 7 days, calls `compound(0, TIER_30)`. Recovers their share of the donation plus 10% taken from the reserve.

If their share of the weight is `s`, they receive `1.1·s` for every 1 donated. It is profitable when **`s > ~91%`**, and it can be repeated until the reserve is empty.

**Who loses:** whoever funded `bonusReserve`. Others' principal and rewards are not at risk (in fact the others receive the `1-s` share of the donation).

**Evidence:**
- `test/audit2/v_economic2_R2-ECON-1.t.sol`: 20M lock at 2.5x versus 1M flex, 40M reserve. Donates 100M, recovers 98M, and takes 9M of bonus per cycle. **After 5 cycles the reserve is at 0.** Control with `s = 0.83`: loses 9M. PASS.
- `test/audit2/v_fix-review_R2-FC-2.t.sol`: net gain of +3.92M NLYRA after fully exiting. With `s = 71%` it loses 10.7M. PASS.

With the ~353-368M from v1 migrated, the attack is impossible (it would require ~1.8B NLYRA locked, and total supply is 1B). It is real during the launch phase, or whenever a single wallet dominates the weight.

**Remediation:**
- **Operational (mandatory regardless):** do not fund the reserve until the v1 migration is complete and no wallet holds more than ~50% of `totalBoosted`. Afterwards, fund it in small increments.
- **Code (recommended, choose one):**
  - (a) A per-period spending cap on the reserve, global rather than per wallet, since a per-wallet cap is bypassed with multiple accounts. For example `bonus = min(10%, reserve, reserve·(now - lastBonusTs)/BONUS_DRIP_PERIOD)`, updating `lastBonusTs`.
  - (b) Have `notifyRewards` distribute only what the splitter reports having transferred, not the free balance. That way a donation generates neither reward nor bonus. This is more work and changes the documented behavior of README "option 6".

### B. The 30-day pause can be renewed indefinitely
**Severity:** Low · **Location:** `pause()` L737-740 and `whenNotPaused` L183-186. Reported by two lenses (R2-TIME-1 and R2-OWN-1).

**Impact:** `pause()` sets `pausedUntil = now + 30 days` with no checks, even if already paused. A malicious or compromised owner renews it every 29 days (or every block) and the contract never reopens. Meanwhile:
- Nobody new can enter (`stake`, `stakeLocked`).
- Locks cannot be renewed (`extendLock`), so expired locks drop to 1x.
- Nobody can compound (`compound`) or return from cooldown (`cancelUnstake`).
- The bonus reserve is frozen, because `compound` is its only exit and `recoverERC20` excludes NLYRA.
- `harvest` keeps working, so a fixed group of stakers (possibly insiders who locked just before the pause) keeps 100% of fees with nobody diluting them.

**What does NOT happen:** nobody loses principal or already-earned rewards. `claim`, `requestUnstake`, `withdrawLocked`, `withdraw`, and `kick` are never paused.

The README (L115 "expires on its own after 30 days", L250 "can pause again every 30 days") and CHANGES.md promise something the code does not guarantee against a hostile owner.

**Evidence:**
- `test/audit2/v_access-deploy_R2-OWN-1.t.sol`: re-paused 1 s after the first pause and then 26 more times every 29 days, ~2 years with no entry window. `harvest` keeps crediting alice and the reserve stays frozen. PASS.
- `test/audit2/v_time_R2-TIME-1.t.sol`: 13 renewals. Alice still exits with 100% of her principal. PASS.

**Remediation:**
```solidity
function pause() external onlyOwner {
    if (block.timestamp < pausedUntil) revert EnforcedPause();                          // cannot be renewed while active
    if (block.timestamp < uint256(lastPauseEnd) + PAUSE_GAP) revert PauseCooldown();    // mandatory window (7-14 days)
    pausedUntil = uint64(block.timestamp + MAX_PAUSE);
    lastPauseEnd = pausedUntil;
    emit Paused(pausedUntil);
}
function unpause() external onlyOwner { pausedUntil = uint64(block.timestamp); lastPauseEnd = uint64(block.timestamp); emit Unpaused(); }
```
- Optional: allow `extendLock` and `compound` into a lock to work during the pause, since no new funds enter. That way renewals and the reserve never depend on the owner.
- Correct the README and CHANGES.md to describe the actual guarantee.
- Add a regression test: a second `pause()` must revert while paused and also within the GAP.

### C. Fees sent directly to the staking contract can sit idle
**Severity:** Low · **Location:** `NlyraFeeSplitter.harvest()` L99-116 (`NothingToHarvest` and the `if (ws != 0 || ns != 0)`). Reported as CRIT-2.

**Impact:** the README (section 6, "directly to staking") states that whatever the Desk, the OTC desk, or the bots send directly to the staking contract "enters with the next harvest". This does not always happen:
- (a) If there were no trades on Pons that day and the splitter holds 0, `harvest` reverts with `NothingToHarvest`.
- (b) If the splitter holds 1 wei, stakers' share is `1·5000/10000 = 0`. `notifyRewards` is skipped, but the day's interval is still consumed.

Anyone can trigger (b) every day for 1 wei plus gas. The funds are not lost: they remain free and enter with the first real notify. But a cron job that only calls `harvest()` can fail silently.

**Evidence:** `test/audit2/v_critic_CRIT-2.t.sol`. With 1 WETH sent directly to staking: case (a) reverts; in case (b) no tranche is opened and the WETH sits idle; in case (c), the next day with 2 wei, a tranche opens for ~1 WETH/7 days. PASS.

**Remediation:** in `harvest()`, always call `notifyRewards()`. It already ignores dust on its own, via `MIN_NOTIFY_*` and `NotifySkipped`. Also, do not revert with `NothingToHarvest` when the staking contract has free balance. Keep the one-tranche-per-day limit. If the code is not changed: route all fees through the splitter, or have the cron send ≥2 wei to the splitter before harvesting. In both cases, correct section 6 and step 8 of the README.

### D. Compounding into a lock collides with the 32-position cap
**Severity:** Low (UX/liveness, no fund risk) · **Location:** `compound()` L654-671 → `_openLock()` L459-479. Reported as R2-FC-1 and R2-ECON-3. This is Round 1 finding 4 returning as a side effect of the fix for finding 1.

**Impact:** since the bonus is now paid only when a lock is opened, each 30/90-day compound takes a new slot. A bot compounding daily into 90-day locks achieves 31 compounds and on day 32 receives `TooManyPositions`. `stakeLocked` is blocked as well. The only compound that keeps working is to flex, which pays no bonus.

**Evidence:**
- `test/audit2/v_fix-review_R2-FC-1.t.sol`: 31 compounds and then a revert. `earned()` remains intact. Compounding every 3 days into 90-day locks (and releasing expired ones) never reaches the cap.
- `test/audit2/v_economic2_R2-ECON-3.t.sol`: also demonstrates the workaround. PASS.

**Correction to the original report:** freeing a slot does **not** require going 2 days without yield. `withdrawLocked(id)` followed by `cancelUnstake()` in the same block frees the slot and returns the amount to flex, with the same `stakeOf` and the same weight (the expired lock was already at 1x). `extendLock(expiredId, tier)` also re-locks in the same slot. There are two costs:
- `cancelUnstake` brings back anything else the user had in cooldown.
- That amount counts as "recent" for 24 h for the discount.

**Remediation:** add `compound(minOut, tier, positionId)`, or a `compoundInto`, that adds `total + bonus` to an existing lock. It reuses the `extendLock` accounting:
- remove the old `boostDrop`;
- `tier = max`, `unlock = max(old, _unlockFor(tier))`;
- recompute `a.boosted`, `totalBoosted`, and `totalStaked`;
- `boostDrop[newUnlock] += extra`;
- update `nextExpiry` and call `_markIncrease`.

Pay the bonus only if the resulting unlock is ≥ `_unlockFor(tier)`. Cheaper alternative: when `usedMask` is full, merge into the user's first expired lock. If the code is not changed, the Desk must compound into a lock every ≥3 days and free expired ones with `withdrawLocked` + `cancelUnstake`.

### E. `eligibleBalance`: recent stake never matures with contributions less than 24 h apart
**Severity:** Low (correctness/UX, not exploitable) · **Location:** `_markIncrease()` L774-777 and `eligibleBalance()` L891-896. Reported as R2-FC-3 and R2-ECON-2.

**Impact:** each contribution within the window is added to `recent` and restarts the 24 h **for the entire accumulated amount**. A DCA every 23 h, a bot compounding "daily" with some jitter, or repeated `cancelUnstake` calls mean that stake from months ago never counts toward the Desk discount. The error only ever undercounts, so nobody obtains an undue discount and nobody can affect another user's window.

**Evidence:**
- `test/audit2/v_fix-review_R2-FC-3.t.sol`: 91 contributions of 1M every 23h50m over 90 days give `stakeOf` = 91,000,010 and `eligibleBalance` = 10. After 24 h without contributions, everything counts.
- `test/audit2/v_economic2_R2-ECON-2.t.sol`: 162M staked and 100M eligible after 59 days. PASS.

**Remediation:** two buckets aligned to 24 h epochs, `recentEpoch`, `recentCur`, and `recentPrev`, which fit in the current storage space:
```
_markIncrease: e = now/1d; if e != epoch → prev = (e == epoch+1 ? cur : 0); cur = 0; epoch = e;  cur += amt
eligible:      r = (e == epoch) ? cur + prev : (e == epoch+1) ? cur : 0
```
This way each contribution is excluded for between 24 and 48 h, never less (a flash-stake still yields 0), and never accumulates. Do **not** use the "anchor the window without extending it" variant: it leaves an opening for a flash-stake near the window close. Correct the NatSpec at L887-889.

### F. Owner unverified at deployment: a typo is permanent
**Severity:** Low (operator error) · **Location:** `RealYieldStaking.sol:199` (`Ownable(owner_)`) and `script/Deploy.s.sol:25-37`. Reported as R2-OWN-2.

**Impact:** `Ownable2Step` only protects subsequent transfers. The initial owner is written directly, and since `renounceOwnership` always reverts, a mistyped `STAKING_OWNER` (an ownerless EOA, or a Safe from another chain) is irreversible. `pause`/`unpause` and `recoverERC20` are lost forever. Funds are not at risk (the pause expires on its own and `recoverERC20` excludes NLYRA and WETH), but regaining control requires redeploying and migrating. The script also does not check `chainid` or that the owner is not an EOA with a 7702 delegate.

**Evidence:** `test/audit2/v_access-deploy_R2-OWN-2.t.sol` runs the real `Deploy.s.sol`:
- a 1-bit typo is accepted, even on chainid 31337;
- the correct owner receives `OwnableUnauthorizedAccount` on everything;
- an owner with 7702 code is also accepted.

PASS.

**Remediation (script only, without touching `src/`):**
- Before broadcasting: `require(block.chainid == 4663)` and `require(owner_.code.length > 0 && !(code starts with 0xef0100))`. Optional: the Safe's `getThreshold() > 1`.
- Safest approach: deploy with the deployer as owner, call `transferOwnership(multisig)`, and have the multisig call `acceptOwnership()`. This proves the multisig is under control before the deployer steps away.
- After deployment, verify:
  - `owner()` and `pendingOwner()`;
  - `!paused()`;
  - the pools, the tokens, and `feeSplitter`.

### G. WETH and USDG are not "standard": rewards depend on WETH
**Severity:** Low (trust assumption and README) · **Location:** README §Risks L255, `_claim` L627-647, `compound`, and `NlyraFeeSplitter.harvest` L104. Reported as TOK-1.

**Impact:** according to the sources verified on Sourcify:
- **WETH** is aeWETH behind a proxy upgradeable by the chain owner.
- **USDG** is issued by Paxos, UUPS, pausable, and supports address freezing.

Consequences:
- A USDG pause or freeze breaks **only** the `ALL_USDG` mode (and `claimTo` to a frozen address). The revert is atomic and rewards remain intact.
- If WETH breaks or is upgraded incorrectly, **all** claims (all 4 modes go through WETH), `compound`, and `harvest` get stuck. There is no "NLYRA only" exit. Principal can always be withdrawn.

**Evidence:**
- `test/audit2/v_tokens_TOK-1.t.sol`: with WETH mocked to revert, all 4 claim modes, `compound`, and `harvest` revert; `earned()` remains intact and `requestUnstake` + `withdraw` return 1,000,000 NLYRA; once WETH is restored everything is collected. PASS.
- `test/audit2/tok_erc20_edges.t.sol` covers USDG.

**Remediation:**
- Correct the README.
- Optional, while the contract is not yet deployed: a `claimNlyraOnly()`, or have `AS_IS` attempt the WETH transfer without reverting on failure and restore the debt.
- In the Desk and bots: simulate `ALL_USDG` and fall back to `AS_IS` or `ALL_ETH` if it reverts.

### Test environment: the pinned-block cache was emptied
**Severity:** Info (process, not the contract) · **Location:** the local Foundry RPC cache for chain 4663 at block 74180000, which is 413 bytes (`accounts:{}`, `storage:{}`), and `test/ForkBase.sol:15` (`FORK_BLOCK = 74_180_000`). Reported as TOK-OPS-1 and CRIT-1.

**What happened:** several forge runs in parallel against the same pinned block overwrote the cache file with an empty one (~20:25). The Robinhood Chain RPC backing the fork returns 403 for uncached state. Since then **every test inheriting `ForkBase` fails in `setUp`**, including the main suite. Confirmed with `test/audit2/v_critic_CRIT-1.t.sol`: block 74180000 fails and 74330000 passes. It was also observed that `--no-storage-caching` still touches the file.

**What was done to ensure nothing goes unverified:** `test/audit2/critic_mainsuite_rerun.t.sol` inherits the entire main suite and only moves the fork to 74_330_000. It passes **32/32 in the dev profile and 32/32 in the default profile (viaIR, the deployment profile)**. `critic_invariant_rerun.t.sol` passes 2/2 invariants (1,920 calls, 0 reverts). In other words: **the remediated code passes its own suite**. What is broken is the default command.

**Remediation:**
- Change `FORK_BLOCK` to 74_330_000 (healthy cache, 326 KB), or restore the cache from a backup.
- Keep a read-only copy of the good cache.
- Run forks with `-j 1`, or with a separate cache copy per runner.
- Run the full suite with the default profile before handing it to the external auditor.
- Any "failed in setUp with 403" in this round is due to the environment, not the contract.

---

## 3. Status of the 8 fixes from Round 1

| # | Fix | Status | Comment |
|---|---------|--------|------------|
| 1 | Compound bonus only into a lock | **Closed** | Compounding to flex pays 0. Compounding and exiting no longer beats a claim, because the bonus is locked for 30/90 days plus the cooldown. Side effects: D (slot cap) and A (self-donation drains the reserve; the mechanism existed before, the fix did not address it). |
| 2 | Boost ends at UTC midnight, without relying on `kick` | **Closed** | The global drop at midnight and per-user settlement `extra·(rpb − rpbAt[u])` are exact to the wei (differential model and fuzzing). `nextExpiry` is always a lower bound, so there is no underflow. `kick` no longer moves value. `withdrawLocked` goes through the cooldown. |
| 3 | Independent 7-day tranches with no stretching | **Closed** | Each notify opens its own tranche with its own end, dust is ignored, and the accounting `used = dist − paid + pending` is correct. With harvests ≥1 day apart there are at most 7 tranches. The merge path (full queue) is unreachable via the splitter and solvent regardless. |
| 4 | Slot reuse and `extendLock` | **Incomplete** | IDs are preserved, there are never more than 32 slots, and `extendLock` never shortens and moves `boostDrop` correctly. But compounding into a lock fills the slots again (finding D). |
| 5 | `renounceOwnership` blocked and self-expiring pause | **Incomplete** | `renounce` always reverts and the pause expires after 30 days if the key is lost. But a hostile owner can renew it without limit (finding B). |
| 6 | Pools validated via CREATE2 and callback bound via transient storage | **Closed** | Only real code of a v3 pool from the factory is accepted. The callback checks pool, token, and exact amount, and pays only once. A revert inside a try/catch leaves no armed slots. No conflict with `ReentrancyGuardTransient`. Note: the fee tier is not pinned (see notes). |
| 7 | On-chain `eligibleBalance` (excluding stake from the last 24 h) | **Closed for security, incomplete for UX** | No path increases active stake without marking it, so a flash-stake yields 0. But the clock restarts for the entire accumulated amount (finding E). |
| 8 | Cooldown: matured funds are paid out, unmatured funds are merged | **Closed** | No combination shortens a wait. `withdraw` at the exact second of `cooldownEnd` works, and 1 s earlier it reverts. |

The Round 1 hardening notes that were applied (`claimTo` to staking/splitter reverts, `splitBps ≥ 1000`, interval ≥1 day, `cancelUnstake` subject to pause, `err.length == 4`) were verified and work.

---

## 4. What was verified as safe

- **Stateful fuzzing without a fork** (`test/audit2/inv2_stateful_local.t.sol`, `inv2_idle_gas.t.sol`). Real unmodified contracts, with mock pools at the real CREATE2 addresses, so constructor validation and the callback actually execute. ~110,000 calls, multiple seeds and a long horizon, **0 violations**. Verified:
  - WETH and NLYRA solvency (the same token is both stake and reward);
  - exact conservation of principal, cooling, reserve, and weight;
  - per-user rewards equal to an exact model (mutation testing confirms the check catches errors);
  - paid ≤ distributed ≤ received, and claim = `earned()`;
  - never more than 7 tranches;
  - exact bonus;
  - the pause blocks exactly what it should;
  - everyone can fully exit at the end.
- **Differential test** (`test/audit2/diff_model_r2.t.sol`). An independent model distributes by tranches over time, cutting at every tranche end and every expiry midnight. ~4,500 scenarios of 150 steps with jumps to exact midnight, midnight −1 s, the same block, and bursts. Results:
  - maximum difference of 9 wei in the contract's favor and **0 wei of overpayment**;
  - `boostedBalanceOf`, `stakeOf`, cooldown, slots, `extendLock` rules, tranche rates (±3 wei), and the merge path match the model.
- **Main suite and repository invariants on the remediated code:** 32/32 (dev and viaIR) and 2/2 invariants (see the environment section).
- **Tranche engine** (`r2_tranche_engine_te.t.sol`, dev and viaIR): hand calculation matches to the wei, ordered queue, no time regression, recycling when there are no stakers, overflow margins.
- **Time boundaries** (`r2_time_boundaries.t.sol`):
  - locks opened at 00:00:00 and at 23:59:59;
  - `kick` at `u`, at `u+1`, and no action at all: the same reward to the wei;
  - tranche ending exactly at midnight;
  - cooldown to the exact second;
  - 24 h window;
  - the pause expires at the exact second;
  - sequencer drift margin (−24 h/+1 h) gives the user no leverage.
- **Swap and callback** (`r2_swap_transient_paths.t.sol`): transient storage, CREATE2 (salt, factory, init code hash), swap direction and sign, price limits, 1-wei swap, no dangling allowances, and no reentrancy.
- **Tokens** (`tok_erc20_edges.t.sol`):
  - NLYRA is a fixed ERC20 with no fees, hooks, blacklist, or proxy, and its launch restrictions have already expired;
  - principal never touches WETH or USDG.
- **Permissions and deployment** (`r2_owner_deploy_surface.t.sol`, `critic_deploy_script_sim.t.sol`):
  - the owner can only pause and rescue foreign tokens;
  - there are no setters;
  - executing the real `Deploy.s.sol` leaves everything correct;
  - sizes: 16,919 B runtime / 22,590 B initcode, under the EIP-170/3860 limits.
- **Liveness and gas** (`r2_liveness_dos.t.sol`, `v_tranches_TE-1.t.sol`):
  - 1 year of inactivity costs 1.26-3.24M gas;
  - 10 years, 11-13M;
  - the worst case engineered by an attacker adds at most ~4M, once (~91 midnights);
  - `withdraw()` does not depend on this (26k gas after 40 years).
- **Economics** (`r2_econ_*.t.sol`):
  - entering just before or after a harvest gives no advantage;
  - the lock → expiry → exit cycle pays the cooldown;
  - self-sandwiching to inflate the bonus is only profitable with ≥50% of supply.

---

## 5. Dismissed claims

- **Catch-up cost after a long period of inactivity (gas):** it grows only with time, an attacker can add at most ~4M once, any action clears it, and `withdraw` does not depend on it. It would take ~26 years with no activity at all. Kept as a note.
- **`ALL_USDG` trusts the pool delta rather than the balance received:** this would only matter if USDG started charging a transfer fee. Even then the result is an atomic revert with no loss, with `AS_IS` available.
- **Duplicate findings A/D/E/B:** merged. R2-FC-2 = R2-ECON-1, R2-FC-1 = R2-ECON-3, R2-FC-3 = R2-ECON-2, R2-TIME-1 = R2-OWN-1.
- **"Freeing a slot requires 2 days without yield" (part of R2-ECON-3):** false. `withdrawLocked` + `cancelUnstake` in the same block loses nothing.

---

## 6. Hardening notes (optional)

1. **Pin the pools' fee tier** in the constructor: `fee() == 10000` for NLYRA/WETH and `== 100` for WETH/USDG. Currently any real v3 pool for the pair is accepted.
2. **Public `poke(maxDays)`** to advance global state in chunks after a very long period of inactivity.
3. **`PartialFill` never triggers:** a partial fill reverts as `BadCallback`. Revert with `PartialFill` when `0 < owed < amountIn`, or document it for the Desk.
4. **Small claims in swap modes** lose almost everything with `minOut = 0` (especially `ALL_USDG`). The Desk must always compute `minOut` from a quote and reject 0.
5. **Splitter constructor:** require `locker.code.length > 0` and a cap on `minHarvestInterval` (≤7 days). In the script, verify `getLaunchedToken(NLYRA).deployer == TREASURY` before broadcasting.
6. **Merging with a full queue** re-stretches the newest tranche. It is unreachable via the splitter. Optional: revert in that case.
7. **Rounding dust** left in `distributed − paid` (less than 200 wei). Document it.
8. **`eligibleBalance` after a contribution followed by a partial exit** undercounts. Resolved by the fix for E.
9. **On Robinhood Chain, `block.number` is the L1 block number.** It does not affect NLYRA. Keep it in mind if reused with other Pons tokens.
10. **Document in the README** the gas cost per inactive day (~1.2-3.4k per midnight), for gas estimation from the RPC.

---

## 7. Outstanding items before deployment

**Code (decide and apply, because it is immutable):**
1. **B:** pause not renewable while active, with a mandatory window afterwards (and a regression test).
2. **C:** `harvest()` that always calls `notifyRewards()` and does not revert if the staking contract has free balance.
3. **A:** per-period spending cap on the reserve, or notify only what the splitter sends.
4. **D:** `compound` into an existing lock (or automatic merge into an expired lock).
5. **E:** two 24 h buckets in `eligibleBalance`.
6. Optional: pin the fee tier (note 1), `claimNlyraOnly` (G), and `poke` (note 2).

**Script and README:**
- `Deploy.s.sol`: chainid 4663, owner with Safe code (not 7702), 2-step flow (`transferOwnership` + `acceptOwnership`), and post-deploy checks (F).
- README: pause (B), direct fees (C), WETH/USDG (G), cost per inactive day.

**Testing:**
- Fix `ForkBase` (block 74_330_000 or restored cache) and run the **entire** suite with the default profile, without parallelism.
- Turn this round's `v_*` PoCs into regression tests, which after the fixes must show that the attack fails.
- Add `inv2_stateful_local.t.sol` and `diff_model_r2.t.sol`, which run without a fork, to the suite, and add an invariant: sum of future `boostDrop` = `totalBoosted − totalStaked` of active locks.
- **Independent external audit** before migrating the ~350M from v1.

**Operational:**
- Do not fund `bonusReserve` until the v1 migration is complete and weight is distributed (A).
- Owner and treasury on a multisig without a 7702 delegate.
- Keeper with daily harvest that sends ≥2 wei to the splitter if there are direct fees and the code has not changed (C).
- Desk and bots: compound into a lock every ≥3 days, or handle `TooManyPositions` (D); `minOut` always quoted; if `ALL_USDG` fails, use `AS_IS`/`ALL_ETH`.
- Blockscout/Sourcify checklist after deployment: exact verification of both contracts, reads of owner, pools, tokens, and splitter, and `feeRedirects(NLYRA) == splitter` after the treasury signs. This must be confirmed **by viewing the page**.
