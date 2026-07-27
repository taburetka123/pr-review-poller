load test_helper

# Unit tests for the --verify guard toolchain (setup_verify_guard): default-deny
# gh, push-blocked git, receive-pack-blocked ssh. A fake "real" gh/git ahead in
# PATH records what passes through and with which GH_CONFIG_DIR, so the tests
# prove both the deny wall and the config-restore on the allow path.

setup() {
  source_script
  mkdir -p "$BATS_TEST_TMPDIR/realbin"
  export REAL_CALLS="$BATS_TEST_TMPDIR/real-calls.log"
  : > "$REAL_CALLS"
  cat > "$BATS_TEST_TMPDIR/realbin/gh" <<'RG'
#!/bin/bash
echo "REAL-GH CALLED: $*" >> "${REAL_CALLS:?}"
echo "REAL-GH CFG: ${GH_CONFIG_DIR:-unset}" >> "$REAL_CALLS"
RG
  cat > "$BATS_TEST_TMPDIR/realbin/git" <<'RG'
#!/bin/bash
echo "REAL-GIT CALLED: $*" >> "${REAL_CALLS:?}"
RG
  chmod +x "$BATS_TEST_TMPDIR/realbin/gh" "$BATS_TEST_TMPDIR/realbin/git"
  export PATH="$BATS_TEST_TMPDIR/realbin:$PATH"
  export GH_CONFIG_DIR="$BATS_TEST_TMPDIR/real-gh-config"
  mkdir -p "$GH_CONFIG_DIR"
  setup_verify_guard
}

teardown() {
  [ -n "${VERIFY_GUARD_DIR:-}" ] && rm -rf "$VERIFY_GUARD_DIR"
}

@test "gh guard: read shapes pass through with the REAL gh config restored" {
  run env GH_CONFIG_DIR="$VERIFY_GUARD_DIR/gh-config-empty" "$VERIFY_GUARD_DIR/gh" pr view 11 -R roofstock/x --json state
  [ "$status" -eq 0 ]
  grep -q "REAL-GH CALLED: pr view 11" "$REAL_CALLS"
  grep -q "REAL-GH CFG: $BATS_TEST_TMPDIR/real-gh-config" "$REAL_CALLS"
  run "$VERIFY_GUARD_DIR/gh" search prs --limit 5
  [ "$status" -eq 0 ]
  run "$VERIFY_GUARD_DIR/gh" auth token --user someone
  [ "$status" -eq 0 ]
  run "$VERIFY_GUARD_DIR/gh" api "/repos/o/r/pulls/1/reviews?per_page=100"
  [ "$status" -eq 0 ]
}

@test "gh guard: review/merge/comment writes are denied, logged, and never reach real gh" {
  for bad in "pr review 11 --approve" "pr merge 11" "pr comment 11 --body hi" "pr edit 11" "pr close 11" "issue comment 5 --body x" "auth login"; do
    run "$VERIFY_GUARD_DIR/gh" $bad
    [ "$status" -eq 86 ]
  done
  [ "$(grep -c '^BLOCKED gh' "$VERIFY_GUARD_LOG")" -eq 7 ]
  ! grep -q "REAL-GH CALLED" "$REAL_CALLS"
}

@test "gh guard: mutating api shapes denied, GET-with-params allowed" {
  run "$VERIFY_GUARD_DIR/gh" api -X POST "/repos/o/r/pulls/1/comments" -f body=x
  [ "$status" -eq 86 ]
  run "$VERIFY_GUARD_DIR/gh" api --method=DELETE "/repos/o/r/thing"
  [ "$status" -eq 86 ]
  run "$VERIFY_GUARD_DIR/gh" api "/repos/o/r/pulls" -f state=closed
  [ "$status" -eq 86 ]
  run "$VERIFY_GUARD_DIR/gh" api -X GET "/search/issues" -f q=foo
  [ "$status" -eq 0 ]
}

@test "git guard: push and send-pack denied, fetch passes" {
  run "$VERIFY_GUARD_DIR/git" push origin main
  [ "$status" -eq 86 ]
  run "$VERIFY_GUARD_DIR/git" -C /tmp push --force
  [ "$status" -eq 86 ]
  grep -q "^BLOCKED git push origin main" "$VERIFY_GUARD_LOG"
  run "$VERIFY_GUARD_DIR/git" fetch origin main
  [ "$status" -eq 0 ]
  grep -q "REAL-GIT CALLED: fetch origin main" "$REAL_CALLS"
}

@test "ssh guard: remote git-receive-pack (push) refused" {
  run "$VERIFY_GUARD_DIR/verify-ssh" git@github.com "git-receive-pack 'o/r.git'"
  [ "$status" -eq 86 ]
  grep -q "^BLOCKED ssh" "$VERIFY_GUARD_LOG"
}
