load test_helper

HEAD_OID="dc2354f0f3270e27d8b06cdd3801c1e7f6b69e28"

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/projects/work/otto-leases-service"
  export PR_REVIEW_POLLER_CONFIG="$BATS_TEST_TMPDIR/config.env"
  export PR_REVIEW_POLLER_STATE_DIR="$BATS_TEST_TMPDIR/state"
  mkdir -p "$PR_REVIEW_POLLER_STATE_DIR" "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/gh" <<'GH'
#!/bin/bash
echo "$*" >> "${BATS_TEST_TMPDIR:?}/gh-calls"
case "$1 $2" in
  "auth token") echo "gho_stub" ;;
  "pr view")
    [ -n "${GH_STUB_PR_FAIL:-}" ] && { echo "HTTP 502: bad gateway" >&2; exit 1; }
    printf '%s\n' "$GH_STUB_PR_JSON" ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
GH
  cat > "$BATS_TEST_TMPDIR/bin/launchctl" <<'LC'
#!/bin/bash
[ "$1" = print ] && exit 0
[ "$1" = list ] || { echo "unexpected launchctl call: $*" >&2; exit 1; }
printf 'PID\tStatus\tLabel\n'
[ "${LAUNCHCTL_STUB_LOADED:-1}" = 0 ] || printf -- '-\t0\tcom.kezoo.pr-review-poller\n'
LC
  chmod +x "$BATS_TEST_TMPDIR/bin/gh" "$BATS_TEST_TMPDIR/bin/launchctl"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  URL="https://github.com/roofstock/otto-leases-service/pull/265"
  F="$PR_REVIEW_POLLER_STATE_DIR/requested.d/roofstock__otto-leases-service__265.json"
  pr_json OPEN '[]'
}

pr_json() {
  export GH_STUB_PR_JSON='{"state":"'"$1"'","headRefOid":"'"$HEAD_OID"'","reviews":'"$2"'}'
}

last_line() {
  printf '%s' "${lines[${#lines[@]}-1]}"
}

hold_at_head() {
  jq -n --arg c "$HEAD_OID" --arg r "$1" '{"roofstock/otto-leases-service#265": {commit: $c, held_at: "2026-01-01T00:00:00Z", reason: $r, pr_url: "u"}}' > "$PR_REVIEW_POLLER_STATE_DIR/held.json"
}

@test "request queues an open PR and writes its file" {
  run "$SCRIPT_UNDER_TEST" request "$URL"
  [ "$status" -eq 0 ]
  [ "$(last_line)" = "queued roofstock/otto-leases-service#265" ]
  [ "$(jq -r .pr_url "$F")" = "$URL" ]
  [ -n "$(jq -r '.requested_at // empty' "$F")" ]
}

@test "a repeated request rewrites the file with a later stamp" {
  mkdir -p "$(dirname "$F")"
  jq -n --arg u "$URL" '{pr_url: $u, requested_at: "2026-01-01T00:00:00Z"}' > "$F"
  run "$SCRIPT_UNDER_TEST" request "$URL"
  [ "$status" -eq 0 ]
  [ "$(last_line)" = "queued roofstock/otto-leases-service#265" ]
  [[ "$(jq -r .requested_at "$F")" > "2026-01-01T00:00:00Z" ]]
  [ "$(jq -r .pr_url "$F")" = "$URL" ]
}

@test "request without a PR URL exits 2" {
  run "$SCRIPT_UNDER_TEST" request 265
  [ "$status" -eq 2 ]
  [ "$(last_line)" = "expected GitHub PR URL" ]
  run "$SCRIPT_UNDER_TEST" request
  [ "$status" -eq 2 ]
  [ "$(last_line)" = "expected GitHub PR URL" ]
  [ ! -e "$F" ]
}

@test "request with the job unloaded is not queued" {
  LAUNCHCTL_STUB_LOADED=0 run "$SCRIPT_UNDER_TEST" request "$URL"
  [ "$status" -eq 4 ]
  [ "$(last_line)" = "not queued: poller stopped" ]
  [ ! -e "$BATS_TEST_TMPDIR/gh-calls" ]
  [ ! -e "$F" ]
}

@test "a merged or closed PR is not queued" {
  pr_json MERGED '[]'
  run "$SCRIPT_UNDER_TEST" request "$URL"
  [ "$status" -eq 4 ]
  [ "$(last_line)" = "not queued: MERGED" ]
  pr_json CLOSED '[]'
  run "$SCRIPT_UNDER_TEST" request "$URL"
  [ "$status" -eq 4 ]
  [ "$(last_line)" = "not queued: CLOSED" ]
  [ ! -e "$F" ]
}

@test "a PR in a repo with no clone is not queued" {
  run "$SCRIPT_UNDER_TEST" request "https://github.com/roofstock/otto-other-service/pull/7"
  [ "$status" -eq 4 ]
  [ "$(last_line)" = "not queued: not cloned" ]
  [ ! -d "$PR_REVIEW_POLLER_STATE_DIR/requested.d" ]
}

@test "a PR he reviewed at its head is not queued" {
  pr_json OPEN '[{"author":{"login":"aleksandr-beliakov-rs"},"state":"COMMENTED","submittedAt":"2026-01-02T00:00:00Z","commit":{"oid":"'"$HEAD_OID"'"}}]'
  run "$SCRIPT_UNDER_TEST" request "$URL"
  [ "$status" -eq 4 ]
  [ "$(last_line)" = "not queued: reviewed at head" ]
  [ ! -e "$F" ]
}

@test "a PR someone approved is not queued" {
  pr_json OPEN '[{"author":{"login":"somebody-else-rs"},"state":"APPROVED","submittedAt":"2026-01-02T00:00:00Z","commit":{"oid":"'"$HEAD_OID"'"}}]'
  run "$SCRIPT_UNDER_TEST" request "$URL"
  [ "$status" -eq 4 ]
  [ "$(last_line)" = "not queued: approved" ]
  [ ! -e "$F" ]
}

@test "a PR held at its head is not queued" {
  hold_at_head "needs human"
  run "$SCRIPT_UNDER_TEST" request "$URL"
  [ "$status" -eq 4 ]
  [ "$(last_line)" = "not queued: held at head" ]
  [ ! -e "$F" ]
}

@test "an in-flight entry at the head still queues" {
  hold_at_head "[in-flight] auto-claimed before review"
  run "$SCRIPT_UNDER_TEST" request "$URL"
  [ "$status" -eq 0 ]
  [ "$(last_line)" = "queued roofstock/otto-leases-service#265" ]
  [ -f "$F" ]
}

@test "a gh failure exits 1 and queues nothing" {
  GH_STUB_PR_FAIL=1 run "$SCRIPT_UNDER_TEST" request "$URL"
  [ "$status" -eq 1 ]
  [[ "$output" != *"queued"* ]]
  [ ! -e "$F" ]
}

@test "status lists a queued PR with its request time" {
  mkdir -p "$(dirname "$F")"
  jq -n --arg u "$URL" '{pr_url: $u, requested_at: "2026-01-01T00:00:00Z"}' > "$F"
  run "$SCRIPT_UNDER_TEST" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"requested (waiting for the next tick):"* ]]
  [[ "$output" == *"  roofstock/otto-leases-service#265  requested 2026-01-01T00:00:00Z"* ]]
}

@test "status with an empty queue prints no requested block" {
  run "$SCRIPT_UNDER_TEST" status
  [ "$status" -eq 0 ]
  [[ "$output" != *"requested ("* ]]
}
