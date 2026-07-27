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

  # gh stub: auth token / search prs / pr view
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/gh" <<'GH'
#!/bin/bash
case "$1 $2" in
  "auth token") echo "gho_stub" ;;
  "search prs") echo '[{"number":265,"title":"t","repository":{"nameWithOwner":"roofstock/otto-leases-service"},"author":{"login":"dmitry-indikeev-rs"}}]' ;;
  "pr view") echo '{"commits":[{"oid":"dc2354f0f3270e27d8b06cdd3801c1e7f6b69e28","committedDate":"2026-01-01T00:00:00Z"}],"reviews":[],"headRefName":"LRX-9992-branch"}' ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
GH
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

  cat > "$PR_REVIEW_RUN_ALL" <<'RA'
#!/bin/bash
mkdir -p "${PR_REVIEW_RESULT_DIR:?}"
while IFS=$'\t' read -r repo pr branch slug since; do
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
  if [ "$1" = "writes" ]; then
    cat > "$PR_REVIEW_POLLER_CLAUDE" <<'CL'
#!/bin/bash
mkdir -p "$PR_REVIEW_FINDINGS_ROOT/roofstock/otto-leases-service"
printf '=== stub ===\nAction: HOLD\n' >> "$PR_REVIEW_FINDINGS_ROOT/roofstock/otto-leases-service/265.log"
CL
  else
    printf '#!/bin/bash\nexit 0\n' > "$PR_REVIEW_POLLER_CLAUDE"
  fi
  chmod +x "$PR_REVIEW_POLLER_CLAUDE"
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
}
