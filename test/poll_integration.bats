load test_helper

# End-to-end through cmd_run with every external boundary stubbed:
# gh (PATH shim), pr-review-run-all, claude, worktree cleanup. HOME is
# redirected into the test tmpdir so no real state is touched.
setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/projects/work/otto-leases-service" "$HOME/worktrees"
  export PR_REVIEW_POLLER_CONFIG="$BATS_TEST_TMPDIR/config.env"
  echo 'REVIEW_FREQUENCY="2h"' > "$PR_REVIEW_POLLER_CONFIG"
  export PR_REVIEW_POLLER_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export PR_REVIEW_POLLER_LOCK_FILE="$BATS_TEST_TMPDIR/poller.lock"
  export PR_REVIEW_FINDINGS_ROOT="$BATS_TEST_TMPDIR/findings"
  export PR_REVIEW_RESULT_DIR="$BATS_TEST_TMPDIR/pr-review"
  export PR_REVIEW_POLLER_WORK_CWD="$HOME/projects/work/otto-leases-service"
  export PR_REVIEW_RUN_ALL="$BATS_TEST_TMPDIR/stub-run-all"
  export PR_REVIEW_WORKTREE_SCRIPT="$BATS_TEST_TMPDIR/stub-worktree"
  export PR_REVIEW_POLLER_CLAUDE="$BATS_TEST_TMPDIR/stub-claude"
  mkdir -p "$PR_REVIEW_POLLER_STATE_DIR"
  # prune gate: stamp fresh so prune_findings skips (no gh calls from prune)
  date +%s > "$PR_REVIEW_POLLER_STATE_DIR/last-prune.epoch"

  # Domain gate fixture: without it the fail-closed pod gate refuses every PR.
  export PR_REVIEW_PODS_CSV="$BATS_TEST_TMPDIR/pods.csv"
  cat > "$PR_REVIEW_PODS_CSV" <<'CSV'
"GhStatus","Repository","x","x","x","x","x","x","x","x","x","x","x","Pod","tail"
"FoundInGh","otto-leases-service","x","x","x","x","x","x","x","x","x","x","x","Otto - Leasing","t"
CSV

  # gh stub: auth token / search prs / pr view
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/gh" <<'GH'
#!/bin/bash
case "$1 $2" in
  "auth token") echo "gho_stub" ;;
  "search prs") echo '[{"number":265,"title":"t","repository":{"nameWithOwner":"roofstock/otto-leases-service"},"author":{"login":"dmitry-indikeev-rs"}}]' ;;
  "pr view") echo '{"state":"'"${GH_STUB_PR_STATE:-OPEN}"'","commits":[{"oid":"dc2354f0f3270e27d8b06cdd3801c1e7f6b69e28","committedDate":"2026-01-01T00:00:00Z"}],"reviews":[],"headRefName":"LRX-9992-branch"}' ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
GH
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  # The stub tees its stdin OUTSIDE PR_REVIEW_RESULT_DIR (cleanup_dispatched
  # would eat anything inside it) so tests can assert the exact spec content
  # that reached run-all — guarding the tuple field-shift class at the seam.
  export RUN_ALL_INPUT="$BATS_TEST_TMPDIR/run-all-input.tsv"
  cat > "$PR_REVIEW_RUN_ALL" <<'RA'
#!/bin/bash
mkdir -p "${PR_REVIEW_RESULT_DIR:?}"
tee "${RUN_ALL_INPUT:?}" | while IFS=$'\t' read -r repo pr branch slug since; do
  [ -z "$pr" ] && continue
  printf 'Status: ok\nComplexity: 2\n## Findings\nNo findings.\n' > "$PR_REVIEW_RESULT_DIR/$pr.md"
done
echo "pr-review-run-all: completed"
RA
  chmod +x "$PR_REVIEW_RUN_ALL"
  printf '#!/bin/bash\nexit 0\n' > "$PR_REVIEW_WORKTREE_SCRIPT"
  chmod +x "$PR_REVIEW_WORKTREE_SCRIPT"
}

write_claude_stub() {  # $1 = "writes" | "silent"
  # Both stubs APPEND their argv (one element per line, --CALL-- terminator)
  # so tests can assert on EVERY claude invocation of the tick, not just the
  # last one — a retry path added later must not escape the pin guard
  # (Tier-2 delta finding F).
  if [ "$1" = "writes" ]; then
    cat > "$PR_REVIEW_POLLER_CLAUDE" <<'CL'
#!/bin/bash
{ printf '%s\n' "$@"; echo '--CALL--'; } >> "${BATS_TEST_TMPDIR:?}/claude-argv"
printf 'GH_CONFIG_DIR=%s\nPATH_HEAD=%s\nGH_RESOLVED=%s\n' "${GH_CONFIG_DIR:-unset}" "${PATH%%:*}" "$(command -v gh)" > "$BATS_TEST_TMPDIR/claude-env"
mkdir -p "$PR_REVIEW_FINDINGS_ROOT/roofstock/otto-leases-service"
printf '=== stub ===\nAction: HOLD\n' >> "$PR_REVIEW_FINDINGS_ROOT/roofstock/otto-leases-service/265.log"
CL
  elif [ "$1" = "attempts-write" ]; then
    # Simulates a triage session that decides APPROVE and tries to submit it:
    # the gh resolved via ITS OWN PATH must be the verify guard, which denies.
    cat > "$PR_REVIEW_POLLER_CLAUDE" <<'CL'
#!/bin/bash
{ printf '%s\n' "$@"; echo '--CALL--'; } >> "${BATS_TEST_TMPDIR:?}/claude-argv"
gh pr review 265 --approve --body "" || echo "write attempt denied rc=$?" >> "${BATS_TEST_TMPDIR:?}/claude-denials"
mkdir -p "$PR_REVIEW_FINDINGS_ROOT/roofstock/otto-leases-service"
printf '=== stub ===\nAction: APPROVE (blocked by verify guard)\n' >> "$PR_REVIEW_FINDINGS_ROOT/roofstock/otto-leases-service/265.log"
CL
  else
    cat > "$PR_REVIEW_POLLER_CLAUDE" <<'CL'
#!/bin/bash
{ printf '%s\n' "$@"; echo '--CALL--'; } >> "${BATS_TEST_TMPDIR:?}/claude-argv"
exit 0
CL
  fi
  chmod +x "$PR_REVIEW_POLLER_CLAUDE"
}

# Every recorded claude call must carry exactly ONE --model, valued as the
# roster pin. Presence is not enough: claude's CLI takes the LAST --model
# (spiked empirically by the Tier-2 delta), so a later duplicate silently
# shadows the pin (finding E); and a new unpinned call site must fail, not
# hide behind the last-written record (finding F).
assert_every_call_pinned() {
  awk '
    /^--CALL--$/ { calls++; if (models != 1 || value != "claude-opus-5") bad=1; models=0; value=""; next }
    prev { value=$0; prev=0 }
    $0 == "--model" { models++; prev=1 }
    END { exit (calls < 1 || bad) ? 1 : 0 }
  ' "$BATS_TEST_TMPDIR/claude-argv"
}

@test "RED: triage that writes no findings log fails the tick loudly" {
  write_claude_stub silent
  run "$SCRIPT_UNDER_TEST" run --force --min-commit-age 0
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: findings log missing for roofstock/otto-leases-service#265"* ]]
  [[ "$output" == *"poll FAILED"* ]]
  [[ "$output" != *"poll done"* ]]
}

@test "GREEN: triage that writes the findings log passes" {
  write_claude_stub writes
  run "$SCRIPT_UNDER_TEST" run --force --min-commit-age 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"poll done"* ]]
  [ -f "$PR_REVIEW_FINDINGS_ROOT/roofstock/otto-leases-service/265.log" ]
}

@test "reviewers are launched by the poller, not the claude session" {
  write_claude_stub writes
  run "$SCRIPT_UNDER_TEST" run --force --min-commit-age 0
  [ "$status" -eq 0 ]
  # cmd_run's cleanup_dispatched (abf2ba5, spec-review F2) rm's the result .md
  # before returning, so a post-hoc [-f] check on it always fails regardless
  # of whether pr-review-run-all ran. Assert on the stub's own stdout marker
  # instead — it flows through unredirected via the `| "$RUN_ALL_SCRIPT"` pipe
  # and proves pr-review-run-all executed during this tick.
  [[ "$output" == *"pr-review-run-all: completed"* ]]
  [[ "$output" == *"launching 1 reviewer(s)"* ]]
  [[ "$output" == *"--reviews-pre-run"* ]]
  # The exact spec line that reached run-all (field-shift guard at the seam):
  [ "$(cat "$RUN_ALL_INPUT")" = $'otto-leases-service\t265\tLRX-9992-branch\troofstock/otto-leases-service\t' ]
  # And the argv claude was ACTUALLY invoked with (not just the log echo):
  grep -q -- "--reviews-pre-run" "$BATS_TEST_TMPDIR/claude-argv"
  # Model pin at the act level (Tier-2 finding 1 + delta findings E/F):
  # every recorded call must carry exactly one --model with the roster value —
  # dropping the expansion, shadowing it with a later duplicate --model, or
  # adding a new unpinned call site must all go red.
  assert_every_call_pinned
}

@test "repo owned by a foreign pod is skipped by the domain gate, reviewer never launched" {
  write_claude_stub writes
  cat > "$PR_REVIEW_PODS_CSV" <<'CSV'
"GhStatus","Repository","x","x","x","x","x","x","x","x","x","x","x","Pod","tail"
"FoundInGh","otto-leases-service","x","x","x","x","x","x","x","x","x","x","x","Otto - Core","t"
CSV
  run "$SCRIPT_UNDER_TEST" run --force --min-commit-age 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"domain gate — pod 'Otto - Core' outside allowed domain"* ]]
  [[ "$output" == *"no PRs survived filters"* ]]
  [[ "$output" != *"launching"* ]]
}

@test "PR no longer OPEN is skipped before any reviewer is launched" {
  write_claude_stub writes
  export GH_STUB_PR_STATE=MERGED
  run "$SCRIPT_UNDER_TEST" run --force --min-commit-age 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip #265 (roofstock/otto-leases-service): state is MERGED, not OPEN"* ]]
  [[ "$output" == *"no PRs survived filters"* ]]
  [[ "$output" != *"launching"* ]]
}

@test "verify mode: guard env reaches the claude session (MCP-empty flags, guard PATH, empty gh config)" {
  write_claude_stub writes
  run "$SCRIPT_UNDER_TEST" run --verify --min-commit-age 0
  [ "$status" -eq 0 ]
  # Banner states the accurate claim (no gh/git/MCP write path) AND names the
  # residuals — an overclaim here is the failure this wording replaced.
  [[ "$output" == *"VERIFY MODE: no GitHub write on any gh / git / MCP path"* ]]
  [[ "$output" == *"NOT airtight"* ]]
  [[ "$output" == *"raw HTTP clients"* ]]
  [[ "$output" == *"keyring"* ]]
  [[ "$output" == *"poll done"* ]]
  grep -q -- "--strict-mcp-config" "$BATS_TEST_TMPDIR/claude-argv"
  assert_every_call_pinned
  # the claude session inherited the guard PATH: gh resolved AT CLAUDE RUNTIME
  # to the guard dir's gh (the head of its PATH), not the test's stub — the
  # guard dir itself is gone by now (EXIT trap), so assert from the runtime
  # capture, and pin the EMPTY gh config dir
  local path_head gh_resolved
  path_head=$(grep '^PATH_HEAD=' "$BATS_TEST_TMPDIR/claude-env" | cut -d= -f2-)
  gh_resolved=$(grep '^GH_RESOLVED=' "$BATS_TEST_TMPDIR/claude-env" | cut -d= -f2-)
  [ "$gh_resolved" = "$path_head/gh" ]
  [ "$path_head" != "$BATS_TEST_TMPDIR/bin" ]
  grep -q 'GH_CONFIG_DIR=.*/gh-config-empty$' "$BATS_TEST_TMPDIR/claude-env"
}

@test "verify mode: a write attempt from the claude session is denied, logged, and does not fail the tick" {
  write_claude_stub attempts-write
  run "$SCRIPT_UNDER_TEST" run --verify --min-commit-age 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 GitHub write attempt(s) BLOCKED this tick"* ]]
  [[ "$output" == *"BLOCKED gh pr review 265 --approve"* ]]
  [[ "$output" == *"poll done"* ]]
  grep -q "write attempt denied rc=86" "$BATS_TEST_TMPDIR/claude-denials"
}

@test "verify mode refuses --post and --head" {
  run "$SCRIPT_UNDER_TEST" run --verify --post
  [ "$status" -eq 2 ]
  run "$SCRIPT_UNDER_TEST" run --verify --head
  [ "$status" -eq 2 ]
}
