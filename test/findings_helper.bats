# Tests the machine-local helper the kezoo-review-prs skill calls to write
# findings logs. The helper lives in ~/.claude/scripts (operator-owned, next to
# its pr-review-run siblings), outside this repo — override the location with
# PR_REVIEW_FINDINGS_APPEND. Tests skip when it isn't installed.

HELPER="${PR_REVIEW_FINDINGS_APPEND:-$HOME/.claude/scripts/pr-review-findings-append}"

setup() {
  [ -x "$HELPER" ] || skip "helper not installed at $HELPER"
  export PR_REVIEW_FINDINGS_ROOT="$BATS_TEST_TMPDIR/findings"
}

@test "valid args append stdin to <owner>/<repo>/<number>.log with a timestamp header and print the path" {
  run bash -c "printf 'Action: HOLD\nbody\n' | '$HELPER' roofstock otto-leases-service 265"
  [ "$status" -eq 0 ]
  [ "$output" = "$PR_REVIEW_FINDINGS_ROOT/roofstock/otto-leases-service/265.log" ]
  grep -q "^=== " "$PR_REVIEW_FINDINGS_ROOT/roofstock/otto-leases-service/265.log"
  grep -q "body" "$PR_REVIEW_FINDINGS_ROOT/roofstock/otto-leases-service/265.log"
}

@test "second append accumulates entries (two headers)" {
  bash -c "echo one | '$HELPER' o r 1" >/dev/null
  bash -c "echo two | '$HELPER' o r 1" >/dev/null
  run grep -c "^=== " "$PR_REVIEW_FINDINGS_ROOT/o/r/1.log"
  [ "$output" -eq 2 ]
}

@test "repo containing a summary line is rejected loudly, nothing created" {
  run bash -c "echo x | '$HELPER' roofstock 'otto-service-requests-service 1457 HOLD' 1457"
  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid repo"* ]]
  [ ! -d "$PR_REVIEW_FINDINGS_ROOT/roofstock/otto-service-requests-service 1457 HOLD" ]
}

@test "non-numeric pr number rejected" {
  run bash -c "echo x | '$HELPER' o r '12 HOLD'"
  [ "$status" -eq 2 ]
}

@test "dot and dot-dot path components rejected" {
  run bash -c "echo x | '$HELPER' .. r 1"
  [ "$status" -eq 2 ]
  run bash -c "echo x | '$HELPER' o . 1"
  [ "$status" -eq 2 ]
}

@test "missing args rejected" {
  run bash -c "echo x | '$HELPER' o r"
  [ "$status" -eq 2 ]
}
