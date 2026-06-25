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
