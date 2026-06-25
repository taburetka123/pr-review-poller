# Design: expire stale `[in-flight]` held-ledger entries in pr-review-poller

## Problem

`bin/pr-review-poller` gate 7 (`filter_prs`, ~lines 363-380) skips a PR when
`held.json` has an entry whose `commit` equals the PR's current HEAD. Two entry
flavours share this gate:

- **Real HOLD** — written by `kezoo-review-prs` with a findings/complexity
  verdict as `reason`. Intended to persist until the commit changes or a human
  runs `clear-hold`. Correct as-is.
- **`[in-flight]` placeholder** — written by `cmd_run` *before* invoking claude
  (lines 500-521), `reason` exactly `[in-flight] auto-claimed before review`.
  Intended to stop the *next* tick from re-burning a retry on a PR that crashed
  mid-review.

The placeholder has **no expiry**. If a run is interrupted (killed,
rate-limited, timed out, user-stopped) after writing the placeholder but before
the skill overwrites it with a real verdict or deletes it on success, the
`[in-flight]` entry sticks at that HEAD **forever**, permanently skipping the PR
in gate 7.

**Evidence:** `held.json` held 28 stale `[in-flight]` entries dating back to May
2026 (manually cleared). `otto-prospects-service#460` was stuck since today's
03:00 run — silently never reviewed; noticed only because a human looked.

## Structural signal: the lock proves orphaned-ness

`cmd_run` takes a PID-file lock at the top (lines 429-438):

- If `$LOCK_FILE` exists and its PID is still alive (`kill -0`), the run exits
  immediately (lines 430-435) — it never reaches the prune or `filter_prs`.
- Otherwise it writes `$$` and installs an EXIT trap that removes the lock.

So **any run that reaches `filter_prs` holds the lock, which means no other run
is live.** An `[in-flight]` placeholder that exists at that moment was therefore
written by a *previous, now-dead* run — it is orphaned by definition. There is
no runtime watchdog and the launchd schedule is one-run-at-a-time gated by the
lock + a 2h frequency gate (per the loops registry), so this holds in practice.

(There is a pre-existing check-then-write TOCTOU window in the PID lock — two
ticks could both pass the `kill -0` check before either writes `$$`. This is an
existing property of the script, not introduced here. The TTL floor below makes
the prune robust to it anyway.)

## Fix (Approach A — selected)

At run start — **after** acquiring the lock and **after** the frequency gate
passes, immediately before `filter_prs` — prune `[in-flight]` placeholders whose
`held_at` is older than a cooldown TTL. Real holds are never touched.

### Mechanism

1. **`INFLIGHT_TTL` config** (`load_config`): `INFLIGHT_TTL="${INFLIGHT_TTL:-1h}"`,
   parsed with the existing `duration_to_seconds`. Overridable via config.env /
   env, same as `MIN_COMMIT_AGE` / `REVIEW_FREQUENCY`.

2. **`iso8601_to_epoch <ts>`** helper. Parses `held_at` (written by
   `date -Iseconds`, e.g. `2026-06-25T12:19:10+07:00`) to epoch seconds. BSD
   `date -j -f "%Y-%m-%dT%H:%M:%S%z"` **rejects** the `+07:00` colon offset
   (verified) but accepts `+0700`, so the helper normalises `Z`→`+0000` and
   strips the colon from a trailing `±HH:MM` offset before parsing. Returns
   non-zero on an unparseable timestamp.

3. **`prune_inflight_holds <ledger> <now_epoch> <ttl_seconds>`** — pure function,
   no gh/network:
   - No ledger file → no-op (return 0).
   - Select entries whose `reason` is a string starting with `[in-flight]`.
   - For each, compute `age = now_epoch - iso8601_to_epoch(held_at)`. If
     `held_at` is missing or unparseable, treat the entry as **expired**
     (a malformed placeholder must not be able to stick — that is the very
     failure mode being fixed). If `age >= ttl_seconds`, mark for deletion.
   - Delete all marked keys in one `jq` pass; log one line per pruned key.

4. **Wire-in** in `cmd_run`, after `date +%s > "$LAST_RUN_FILE"` (line 485) and
   before `filter_prs` (line 489):
   ```bash
   local _ttl; _ttl=$(duration_to_seconds "$INFLIGHT_TTL") || _ttl=3600
   prune_inflight_holds "$HOME/.local/state/pr-review-poller/held.json" \
     "$(date +%s)" "$_ttl"
   ```

After the prune, `filter_prs` gate 7 finds no entry for the un-stuck PR at HEAD,
so it survives filters and `cmd_run` writes a **fresh** `[in-flight]` entry
(new `held_at`) before re-invoking claude. If claude crashes again, the fresh
entry is pruned on the next real-work tick (~2h later) and retried — periodic
self-healing, never a permanent stick.

### Why TTL = 1h

- A healthy review tick (claude at effort medium over a handful of PRs) finishes
  well under an hour, so a merely-slow run is never pruned (and the lock already
  prevents pruning a live run's entries).
- `1h < 2h` frequency gate ⇒ a crashed-run placeholder is guaranteed expired by
  the next real-work tick, so a stranded PR self-heals on the *first* review
  cycle after the crash (≈2h worst case).
- In the `--force` path (frequency gate bypassed) the 1h TTL is the actual
  cooldown that stops a forced run from immediately re-burning a just-crashed PR.

This is "long enough not to re-burn immediately on a transient crash, short
enough to self-heal."

## Rejected alternatives

- **B — pure lock-based prune** (delete all `[in-flight]` regardless of age):
  ignores the manager's explicit "use `held_at` + cooldown"; fragile to the lock
  TOCTOU race (could wipe an entry a racing run wrote seconds ago); no cooldown
  in the `--force` path.
- **C — TTL check inside gate 7** (don't skip an expired in-flight, fall through
  to re-review): doesn't actually remove the stale entry — it lingers in the
  ledger and in `status` output until overwritten, and only un-sticks PRs still
  surfaced by `gh search` (not since-merged ones). A's direct ledger prune cleans
  all of them (matches the "28 stale back to May" evidence, many for long-merged
  PRs).

## Testability (TDD)

No bats tests exist yet; this change establishes the harness.

- Guard the CLI dispatcher: wrap lines 648-663 in
  `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then … fi` so the script is sourceable
  with no side effects.
- `test/prune_inflight_holds.bats` sources the script and unit-tests the pure
  function with crafted `held.json` files and explicit `now`/`ttl`:
  - **RED (reproduces the bug):** an old `[in-flight]` entry survives because
    nothing prunes it. (Pre-fix, the function does not exist / does not remove
    it.)
  - **GREEN:** old `[in-flight]` removed; fresh `[in-flight]` (age < TTL) kept;
    real HOLD kept regardless of age; malformed `held_at` removed; missing ledger
    is a no-op.
- `test/iso8601_to_epoch.bats`: parses `+07:00`, `Z`, and `+0000` forms to the
  same epoch; returns non-zero on garbage.
- `test/dispatcher_guard.bats`: sourcing the script runs no subcommand.

## Release / safety notes

- Personal repo (`taburetka123/pr-review-poller`), no Copilot. Tier-2 verifier +
  manager merge. PR opened ready-for-review; worker signals
  `ready-for-verifier`, does not merge, does not remove the worktree.
- Behaviour change is confined to `[in-flight]` placeholders. Real holds, the
  lock, the frequency gate, `clear-hold`, and `prune` (findings) are unchanged.
- `held.json` schema is unchanged — `held_at` already exists on every entry.
