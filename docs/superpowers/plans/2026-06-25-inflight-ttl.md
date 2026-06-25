# Expire stale `[in-flight]` held-ledger entries — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `[in-flight]` held-ledger placeholders in `bin/pr-review-poller` expire after a cooldown so an interrupted run no longer strands its PRs forever.

**Architecture:** Add a pure `prune_inflight_holds(ledger, now_epoch, ttl_seconds)` function (backed by an `iso8601_to_epoch` helper) and call it once per real-work tick — after the PID lock is held and the frequency gate passes, immediately before `filter_prs`. The lock guarantees no other run is live, so any surviving `[in-flight]` placeholder is orphaned; the `held_at`-based TTL is the cooldown (default `1h`) and a floor against the lock's check-then-write race. Real holds are never touched. The CLI dispatcher is guarded so the script is sourceable for bats unit tests.

**Tech Stack:** bash (BSD `date`), `jq`, bats-core 1.13.

**Spec:** `docs/superpowers/specs/2026-06-25-inflight-ttl-design.md`

---

## File structure

- `bin/pr-review-poller` — modify: add `INFLIGHT_TTL` to `load_config`; add `iso8601_to_epoch` + `prune_inflight_holds`; surface `INFLIGHT_TTL` in `cmd_status`; call the prune in `cmd_run` between the `LAST_RUN_FILE` stamp and `filter_prs`; guard the bottom dispatcher with `[[ "${BASH_SOURCE[0]}" == "${0}" ]]`.
- `test/test_helper.bash` — create: locate + source the script under test.
- `test/dispatcher_guard.bats` — create: sourcing runs no subcommand; CLI still dispatches.
- `test/iso8601_to_epoch.bats` — create: offset/`Z` parsing; garbage → non-zero.
- `test/prune_inflight_holds.bats` — create: RED (stale in-flight stranded) → GREEN (expired pruned, fresh/real kept, malformed pruned, missing ledger no-op).
- `test/config.bats` — create: `INFLIGHT_TTL` default + override via config.
- `README.md` — modify: one line documenting the `INFLIGHT_TTL` knob.

> **Note on the prune's single-run safety:** at the wire-in point (`cmd_run`, after `date +%s > "$LAST_RUN_FILE"`, before `filter_prs`) `filter_prs` has not run yet, so `FILTER_SURVIVORS` is empty and this tick has written **no** `[in-flight]` entry of its own (that happens later, at the in-flight pre-write loop). The prune therefore only ever sees prior-run entries — it cannot delete the current run's own placeholders.

---

## Task 1: Make the script sourceable (guard the CLI dispatcher)

**Files:**
- Create: `test/test_helper.bash`, `test/dispatcher_guard.bats`
- Modify: `bin/pr-review-poller` (dispatcher block at the bottom, currently lines 648-663)

- [ ] **Step 1: Write `test/test_helper.bash`**

```bash
# Locate and source bin/pr-review-poller for unit tests. The script's CLI
# dispatcher is guarded by [[ "${BASH_SOURCE[0]}" == "${0}" ]], so sourcing it
# defines the functions without running any subcommand.
SCRIPT_UNDER_TEST="${BATS_TEST_DIRNAME}/../bin/pr-review-poller"

source_script() {
  # shellcheck disable=SC1090
  source "$SCRIPT_UNDER_TEST"
}
```

- [ ] **Step 2: Write the failing test `test/dispatcher_guard.bats`**

```bash
load test_helper

@test "sourcing the script runs no subcommand (no status output)" {
  run bash -c "source '$SCRIPT_UNDER_TEST'; echo SOURCED_OK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SOURCED_OK"* ]]
  [[ "$output" != *"pr-review-poller status"* ]]
  [[ "$output" != *"=== pr-review-poller status ==="* ]]
}

@test "executing the script directly still dispatches (help works)" {
  run "$SCRIPT_UNDER_TEST" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"unattended PR auto-review"* ]]
}
```

- [ ] **Step 3: Run to verify the first test fails**

Run: `bats test/dispatcher_guard.bats`
Expected: the "sourcing … no subcommand" test FAILS — sourcing currently runs `cmd_status` (prints `=== pr-review-poller status ===`).

- [ ] **Step 4: Guard the dispatcher in `bin/pr-review-poller`**

Wrap the existing dispatcher block:

```bash
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  SUB="${1:-status}"
  [[ $# -gt 0 ]] && shift

  case "$SUB" in
    status)     cmd_status     "$@" ;;
    start)      cmd_start      "$@" ;;
    stop)       cmd_stop       "$@" ;;
    run)        cmd_run        "$@" ;;
    logs)       cmd_logs       "$@" ;;
    findings)   cmd_findings   "$@" ;;
    clear-hold) cmd_clear_hold "$@" ;;
    prune)      cmd_prune      "$@" ;;
    config)     cmd_config     "$@" ;;
    help|-h|--help) cmd_help ;;
    *) echo "unknown subcommand: $SUB" >&2; cmd_help; exit 2 ;;
  esac
fi
```

- [ ] **Step 5: Run to verify both tests pass**

Run: `bats test/dispatcher_guard.bats`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add test/test_helper.bash test/dispatcher_guard.bats bin/pr-review-poller
git commit -m "Make pr-review-poller sourceable for unit tests"
```

---

## Task 2: `iso8601_to_epoch` helper

**Files:**
- Create: `test/iso8601_to_epoch.bats`
- Modify: `bin/pr-review-poller` (add helper near `duration_to_seconds`, ~line 264)

- [ ] **Step 1: Write the failing test `test/iso8601_to_epoch.bats`**

```bash
load test_helper

setup() { source_script; }

@test "parses a +07:00 colon offset" {
  run iso8601_to_epoch "2026-06-25T12:19:10+07:00"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1782364750 ]
}

@test "Z and +0000 and +07:00 of the same instant agree" {
  z=$(iso8601_to_epoch "2026-06-25T05:19:10Z")
  zero=$(iso8601_to_epoch "2026-06-25T05:19:10+0000")
  off=$(iso8601_to_epoch "2026-06-25T12:19:10+07:00")
  [ "$z" -eq "$zero" ]
  [ "$z" -eq "$off" ]
}

@test "garbage timestamp returns non-zero" {
  run iso8601_to_epoch "not-a-timestamp"
  [ "$status" -ne 0 ]
}

@test "empty timestamp returns non-zero" {
  run iso8601_to_epoch ""
  [ "$status" -ne 0 ]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats test/iso8601_to_epoch.bats`
Expected: FAIL — `iso8601_to_epoch: command not found` (function undefined).

- [ ] **Step 3: Implement `iso8601_to_epoch` in `bin/pr-review-poller`**

Insert after `duration_to_seconds` (the `}` at ~line 264):

```bash
# Parse an ISO8601 timestamp as written by `date -Iseconds` (e.g.
# 2026-06-25T12:19:10+07:00, or a Z form) to epoch seconds. BSD `date -j -f`
# with %z rejects the colon in a +HH:MM offset and the bare `Z`, so normalise
# Z -> +0000 and strip the colon from a trailing +HH:MM / -HH:MM offset first.
# The offset embedded in the timestamp is authoritative — do NOT force TZ here.
# Returns non-zero (and prints nothing) on an unparseable timestamp.
iso8601_to_epoch() {
  local ts="$1"
  [[ -z "$ts" ]] && return 1
  ts="${ts/Z/+0000}"
  if [[ "$ts" =~ ^(.+)([+-][0-9]{2}):([0-9]{2})$ ]]; then
    ts="${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
  fi
  date -j -f "%Y-%m-%dT%H:%M:%S%z" "$ts" +%s 2>/dev/null
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bats test/iso8601_to_epoch.bats`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add test/iso8601_to_epoch.bats bin/pr-review-poller
git commit -m "Add iso8601_to_epoch helper for held_at parsing"
```

---

## Task 3: `prune_inflight_holds` pure function (the fix core — RED reproduces the stick)

**Files:**
- Create: `test/prune_inflight_holds.bats`
- Modify: `bin/pr-review-poller` (add function after `iso8601_to_epoch`)

- [ ] **Step 1: Write the failing test `test/prune_inflight_holds.bats`**

```bash
load test_helper

setup() {
  source_script
  LEDGER="$BATS_TEST_TMPDIR/held.json"
  NOW=$(date +%s)
}

# held_at = NOW - $1 seconds, in the same ISO8601 form cmd_run writes.
ago() { date -r $(( NOW - $1 )) -Iseconds; }

write_ledger() { printf '%s' "$1" > "$LEDGER"; }

@test "stale [in-flight] placeholder is pruned (reproduces the permanent stick)" {
  write_ledger "$(jq -n --arg h "$(ago 7200)" '{
    "o/r#460": {commit:"abc", held_at:$h, reason:"[in-flight] auto-claimed before review", pr_url:"u"}
  }')"
  run prune_inflight_holds "$LEDGER" "$NOW" 3600
  [ "$status" -eq 0 ]
  # After pruning, the entry is gone -> gate 7 can no longer strand the PR.
  [ "$(jq -r 'has("o/r#460")' "$LEDGER")" = "false" ]
}

@test "fresh [in-flight] placeholder (younger than TTL) is kept" {
  write_ledger "$(jq -n --arg h "$(ago 60)" '{
    "o/r#1": {commit:"abc", held_at:$h, reason:"[in-flight] auto-claimed before review", pr_url:"u"}
  }')"
  run prune_inflight_holds "$LEDGER" "$NOW" 3600
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("o/r#1")' "$LEDGER")" = "true" ]
}

@test "real HOLD is never pruned, even when old" {
  write_ledger "$(jq -n --arg h "$(ago 999999)" '{
    "o/r#2": {commit:"abc", held_at:$h, reason:"blocker: null deref at Foo.kt:42", pr_url:"u"}
  }')"
  run prune_inflight_holds "$LEDGER" "$NOW" 3600
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("o/r#2")' "$LEDGER")" = "true" ]
}

@test "malformed held_at on an [in-flight] entry is pruned" {
  write_ledger "$(jq -n '{
    "o/r#3": {commit:"abc", held_at:"garbage", reason:"[in-flight] auto-claimed before review", pr_url:"u"}
  }')"
  run prune_inflight_holds "$LEDGER" "$NOW" 3600
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("o/r#3")' "$LEDGER")" = "false" ]
}

@test "missing held_at on an [in-flight] entry is pruned" {
  write_ledger "$(jq -n '{
    "o/r#4": {commit:"abc", reason:"[in-flight] auto-claimed before review", pr_url:"u"}
  }')"
  run prune_inflight_holds "$LEDGER" "$NOW" 3600
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("o/r#4")' "$LEDGER")" = "false" ]
}

@test "mixed ledger: only expired in-flight removed, real + fresh kept" {
  write_ledger "$(jq -n --arg old "$(ago 7200)" --arg new "$(ago 60)" '{
    "o/r#10": {commit:"a", held_at:$old, reason:"[in-flight] auto-claimed before review", pr_url:"u"},
    "o/r#11": {commit:"b", held_at:$new, reason:"[in-flight] auto-claimed before review", pr_url:"u"},
    "o/r#12": {commit:"c", held_at:$old, reason:"major (conf 5): broken", pr_url:"u"}
  }')"
  run prune_inflight_holds "$LEDGER" "$NOW" 3600
  [ "$status" -eq 0 ]
  [ "$(jq -r 'has("o/r#10")' "$LEDGER")" = "false" ]
  [ "$(jq -r 'has("o/r#11")' "$LEDGER")" = "true" ]
  [ "$(jq -r 'has("o/r#12")' "$LEDGER")" = "true" ]
}

@test "missing ledger file is a no-op (return 0)" {
  run prune_inflight_holds "$BATS_TEST_TMPDIR/does-not-exist.json" "$NOW" 3600
  [ "$status" -eq 0 ]
}

@test "empty ledger object is a no-op" {
  write_ledger '{}'
  run prune_inflight_holds "$LEDGER" "$NOW" 3600
  [ "$status" -eq 0 ]
  [ "$(jq -r 'length' "$LEDGER")" -eq 0 ]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats test/prune_inflight_holds.bats`
Expected: FAIL — `prune_inflight_holds: command not found`. The first test documents the bug: with no prune, the stale entry would persist (permanent stick).

- [ ] **Step 3: Implement `prune_inflight_holds` in `bin/pr-review-poller`**

Insert after `iso8601_to_epoch`:

```bash
# Remove abandoned "[in-flight]" placeholders from the held ledger. A placeholder
# is abandoned when its held_at is older than $3 seconds (or missing/unparseable).
# Real holds (any reason NOT starting with "[in-flight]") are never touched.
# Called from cmd_run after the PID lock is held, so any surviving placeholder is
# necessarily orphaned from a dead run (see the lock in cmd_run); the TTL is the
# cooldown and a floor against the lock's check-then-write race. Pure: no gh/net.
prune_inflight_holds() {
  local ledger="$1" now_epoch="$2" ttl_seconds="$3"
  [[ -f "$ledger" ]] || return 0

  local expired_keys=() key held_at held_epoch age
  while IFS=$'\t' read -r key held_at; do
    [[ -z "$key" ]] && continue
    if held_epoch=$(iso8601_to_epoch "$held_at"); then
      age=$(( now_epoch - held_epoch ))
      [[ "$age" -ge "$ttl_seconds" ]] && expired_keys+=("$key")
    else
      # Missing/unparseable held_at: a malformed placeholder must not be able to
      # stick forever (that is the bug being fixed) — treat it as expired.
      expired_keys+=("$key")
    fi
  done < <(jq -r '
    to_entries[]
    | select(.value.reason | type == "string" and startswith("[in-flight]"))
    | [.key, (.value.held_at // "")]
    | @tsv' "$ledger" 2>/dev/null)

  [[ ${#expired_keys[@]} -eq 0 ]] && return 0

  local keys_json tmp
  keys_json=$(printf '%s\n' "${expired_keys[@]}" | jq -R . | jq -s 'map([.])')
  tmp=$(mktemp)
  if jq --argjson drop "$keys_json" 'delpaths($drop)' "$ledger" > "$tmp"; then
    mv "$tmp" "$ledger"
    for key in "${expired_keys[@]}"; do
      echo "  prune in-flight: $key (placeholder older than ${ttl_seconds}s, orphaned from a dead run — eligible for re-review)"
    done
  else
    rm -f "$tmp"
    echo "  prune in-flight: jq delete failed, ledger left unchanged" >&2
    return 1
  fi
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `bats test/prune_inflight_holds.bats`
Expected: PASS (8 tests).

- [ ] **Step 5: Commit**

```bash
git add test/prune_inflight_holds.bats bin/pr-review-poller
git commit -m "Add prune_inflight_holds to expire stale in-flight placeholders"
```

---

## Task 4: Config knob + wire the prune into `cmd_run` + surface in status

**Files:**
- Create: `test/config.bats`
- Modify: `bin/pr-review-poller` (`load_config`, `cmd_status`, `cmd_run`)

- [ ] **Step 1: Write the failing test `test/config.bats`**

```bash
load test_helper

setup() {
  source_script
  CONFIG_FILE="$BATS_TEST_TMPDIR/config.env"
}

@test "INFLIGHT_TTL defaults to 1h when not configured" {
  unset INFLIGHT_TTL
  load_config
  [ "$INFLIGHT_TTL" = "1h" ]
}

@test "INFLIGHT_TTL is overridable from the config file" {
  echo 'INFLIGHT_TTL="30m"' > "$CONFIG_FILE"
  unset INFLIGHT_TTL
  load_config
  [ "$INFLIGHT_TTL" = "30m" ]
}

@test "default INFLIGHT_TTL parses via duration_to_seconds to 3600" {
  unset INFLIGHT_TTL
  load_config
  run duration_to_seconds "$INFLIGHT_TTL"
  [ "$status" -eq 0 ]
  [ "$output" -eq 3600 ]
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `bats test/config.bats`
Expected: FAIL — `INFLIGHT_TTL` is unset after `load_config` (empty, not `1h`).

- [ ] **Step 3: Add `INFLIGHT_TTL` to `load_config`**

In `load_config`, after the `REVIEW_FREQUENCY` default line:

```bash
  INFLIGHT_TTL="${INFLIGHT_TTL:-1h}"
```

- [ ] **Step 4: Run to verify config tests pass**

Run: `bats test/config.bats`
Expected: PASS (3 tests).

- [ ] **Step 5: Surface `INFLIGHT_TTL` in `cmd_status`**

In `cmd_status`, after the `REVIEW_FREQUENCY` echo line:

```bash
  echo "  INFLIGHT_TTL:     $INFLIGHT_TTL"
```

- [ ] **Step 6: Wire the prune into `cmd_run`**

In `cmd_run`, immediately after `date +%s > "$LAST_RUN_FILE"` (the frequency-gate stamp) and before the `filter_prs` call, insert:

```bash
  # Expire abandoned "[in-flight]" placeholders before filtering. The PID lock is
  # held here, so any surviving placeholder is orphaned from a dead run; filter
  # has not run yet (FILTER_SURVIVORS empty, no in-flight written this tick), so
  # this only ever prunes prior-run entries. Lets a crash-stranded PR re-surface.
  local _inflight_ttl; _inflight_ttl=$(duration_to_seconds "$INFLIGHT_TTL") || _inflight_ttl=3600
  prune_inflight_holds "$HOME/.local/state/pr-review-poller/held.json" "$(date +%s)" "$_inflight_ttl"
```

- [ ] **Step 7: Verify no syntax regression and the dispatcher still works**

Run: `bash -n bin/pr-review-poller && bats test/dispatcher_guard.bats`
Expected: no syntax errors; PASS (2 tests).

- [ ] **Step 8: Commit**

```bash
git add test/config.bats bin/pr-review-poller
git commit -m "Wire in-flight prune into cmd_run; add INFLIGHT_TTL knob"
```

---

## Task 5: Document the knob + full suite green

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Document `INFLIGHT_TTL` in `README.md`**

Add a line wherever `MIN_COMMIT_AGE` / `REVIEW_FREQUENCY` config knobs are described (or a short "Config" note if absent):

```
- `INFLIGHT_TTL` (default `1h`): how long an `[in-flight]` placeholder may persist
  before a new run treats it as orphaned (from a crashed/interrupted run) and
  re-reviews the PR. Real holds (findings/complexity verdicts) are unaffected.
```

- [ ] **Step 2: Run the whole suite**

Run: `bats test/`
Expected: all tests PASS (dispatcher_guard 2, iso8601_to_epoch 4, prune_inflight_holds 8, config 3 = 17).

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "Document INFLIGHT_TTL knob"
```

---

## Rollback

Each task is an isolated commit. Revert any task's commit to roll it back; the prune call in `cmd_run` (Task 4) is the only behavioural change to the running poller — reverting Task 4 alone restores the prior (buggy-but-stable) behaviour while keeping the tested helper functions dormant.
