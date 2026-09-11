load test_helper

HEAD_OID="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
HUNDREDTH_OID="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

setup() {
  source_script
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/projects/work/otto-leases-service"

  WORK_GH_USER="aleksandr-beliakov-rs"
  MIN_COMMIT_AGE="10m"
  LEDGER_FILE="$BATS_TEST_TMPDIR/absent-ledger.json"
  ALLOWED_EXTRA_REPOS=""
  OWNED_REPOS=$'otto-leases-service\n'
  OWNED_GATE_FAILED=0

  export HEAD_OID HUNDREDTH_OID
  export GH_STUB_REVIEWS='[]'
  export GH_STUB_HEAD_DATE="2026-01-01T00:00:00Z"
  export GH_STUB_SEARCH_COUNT=1

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/gh" <<'GH'
#!/bin/bash
case "$1 $2" in
  "search prs")
    jq -n --argjson n "$GH_STUB_SEARCH_COUNT" '[range(0; $n) | {number: (265 + .), title: "t", repository: {nameWithOwner: "roofstock/otto-leases-service"}, author: {login: "dmitry-indikeev-rs"}}]'
    ;;
  "pr view")
    jq -n --arg head "$HEAD_OID" --arg old "$HUNDREDTH_OID" --argjson reviews "$GH_STUB_REVIEWS" \
      '{state: "OPEN", headRefOid: $head, headRefName: "LRX-9992-branch", reviews: $reviews,
        commits: [{oid: $old, committedDate: "2020-01-01T00:00:00Z"}]}'
    ;;
  "api repos/roofstock/otto-leases-service/commits/$HEAD_OID")
    [ -n "$GH_STUB_API_FAILS" ] && exit 1
    echo "$GH_STUB_HEAD_DATE"
    ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
GH
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

teardown() {
  chmod -R u+w "$BATS_TEST_TMPDIR" 2>/dev/null || true
}

filter() {
  FILTER_LOG="$BATS_TEST_TMPDIR/filter.log"
  filter_prs > "$FILTER_LOG"
}

@test "a PR past 100 commits is queued at its real head, not at the 100th commit" {
  filter
  [ "${#FILTER_SURVIVORS[@]}" -eq 1 ]
  IFS=$'\t' read -r _ _ _ queued_head _ <<<"${FILTER_SURVIVORS[0]}"
  [ "$queued_head" = "$HEAD_OID" ]
}

@test "a review at the 100th commit does not hide new commits past it" {
  export GH_STUB_REVIEWS="[{\"author\":{\"login\":\"aleksandr-beliakov-rs\"},\"commit\":{\"oid\":\"$HUNDREDTH_OID\"},\"state\":\"COMMENTED\",\"submittedAt\":\"2026-01-01T00:00:00Z\"}]"
  filter
  ! grep -q "already reviewed" "$FILTER_LOG" || false
  [ "${#FILTER_SURVIVORS[@]}" -eq 1 ]
}

@test "a review at the real head skips the PR as already reviewed" {
  export GH_STUB_REVIEWS="[{\"author\":{\"login\":\"aleksandr-beliakov-rs\"},\"commit\":{\"oid\":\"$HEAD_OID\"},\"state\":\"COMMENTED\",\"submittedAt\":\"2026-01-01T00:00:00Z\"}]"
  filter
  grep -q "already reviewed at HEAD ${HEAD_OID:0:7}" "$FILTER_LOG"
  [ "${#FILTER_SURVIVORS[@]}" -eq 0 ]
}

@test "the commit-age gate reads the head commit's date" {
  export GH_STUB_HEAD_DATE="$(TZ=UTC date -u -v-60S +"%Y-%m-%dT%H:%M:%SZ")"
  filter
  grep -q "below 600s threshold" "$FILTER_LOG"
  [ "${#FILTER_SURVIVORS[@]}" -eq 0 ]
}

@test "a head commit whose date cannot be read is skipped, never queued" {
  export GH_STUB_API_FAILS=1
  filter
  grep -q "head commit lookup failed" "$FILTER_LOG"
  [ "${#FILTER_SURVIVORS[@]}" -eq 0 ]
}

@test "a search that fills the --limit cap says so in the log" {
  export GH_STUB_SEARCH_COUNT=50
  filter
  grep -q "WARN: gh search returned 50 PRs" "$FILTER_LOG"
}

@test "a search under the cap logs no cap warning" {
  export GH_STUB_SEARCH_COUNT=49
  filter
  ! grep -q "WARN: gh search returned" "$FILTER_LOG" || false
}

@test "a ledger that cannot be written warns and never aborts the pin" {
  mkdir -p "$BATS_TEST_TMPDIR/ro"
  LEDGER_FILE="$BATS_TEST_TMPDIR/ro/held.json"
  echo '{"roofstock/otto-leases-service#265":{"commit":"x","reason":"1 major finding at conf 4"}}' > "$LEDGER_FILE"
  chmod a-w "$BATS_TEST_TMPDIR/ro"
  pin_held_to_admitted_head $'roofstock\totto-leases-service\t265\t'"$HEAD_OID"$'\tLRX-9992-branch\t\turl' > "$BATS_TEST_TMPDIR/pin.log" 2>&1
  grep -q "WARN: could not pin held entry roofstock/otto-leases-service#265" "$BATS_TEST_TMPDIR/pin.log"
}
