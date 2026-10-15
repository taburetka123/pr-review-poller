load test_helper

KEY="roofstock/otto-leases-service#265"
ME="aleksandr-beliakov-rs"
TEAM="otto-leases-service-co"

setup() {
  source_script
  OWNED_CSV_FILE="$BATS_TEST_TMPDIR/code-owners.csv"
  cat > "$OWNED_CSV_FILE" <<'CSV'
"Team","Pod","Member"
"otto-leases-service-co","Property Services (RTM)","aleksandr-beliakov-rs"
"otto-leases-service-co","Property Services (RTM)","colleague-rs"
"otto-other-service-co","Property Services (RTM)","someone-else-rs"
CSV
  F="$BATS_TEST_TMPDIR/team-requests.json"

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/gh" <<'GH'
#!/bin/bash
D="${BATS_TEST_TMPDIR:?}"
case "$1 $2" in
  "pr view")
    [ -f "$D/pr-view.json" ] || { echo "HTTP 502: bad gateway" >&2; exit 1; }
    cat "$D/pr-view.json" ;;
  "api repos/roofstock/otto-leases-service/issues/265/timeline?per_page=100")
    [ -e "$D/timeline-fail" ] && { echo "HTTP 500: timeline down" >&2; exit 1; }
    if [ -f "$D/timeline.json" ]; then cat "$D/timeline.json"; else echo '[]'; fi ;;
  "api repos/roofstock/otto-leases-service/pulls/265/requested_reviewers")
    printf '%s\n' "$@" >> "$D/gh-writes"
    [ -e "$D/api-fail" ] && { echo "HTTP 422: Reviews may only be requested from collaborators" >&2; exit 1; }
    if [ -f "$D/rr-response.json" ]; then cat "$D/rr-response.json"; else echo '{"requested_teams":[{"slug":"otto-leases-service-co"}]}'; fi ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
GH
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

write_entry() {
  jq -n --arg k "$KEY" --argjson teams "${1:-[\"$TEAM\"]}" \
    '{($k): {teams: $teams, since: "2026-10-15T10:00:00Z", pr_url: "https://github.com/roofstock/otto-leases-service/pull/265"}}' > "$F"
}

pr_view() {
  jq -n --arg state "$1" --argjson rr "$2" --argjson reviews "$3" --arg author "${4:-pr-author-rs}" \
    '{state: $state, author: {login: $author}, reviewRequests: $rr, reviews: $reviews}' > "$BATS_TEST_TMPDIR/pr-view.json"
}

review() {
  printf '{"author":{"login":"%s"},"state":"%s","submittedAt":"%s"}' "$1" "$2" "$3"
}

his_comment() {
  review "$ME" COMMENTED 2026-10-15T10:20:00Z
}

key_present() {
  [ "$(jq --arg k "$KEY" 'has($k)' "$F")" = "true" ]
}

no_writes() {
  [ ! -e "$BATS_TEST_TMPDIR/gh-writes" ]
}

wrote_rerequest() {
  grep -qxF -- "-X" "$BATS_TEST_TMPDIR/gh-writes"
  grep -qxF -- "POST" "$BATS_TEST_TMPDIR/gh-writes"
  grep -qxF -- "-f" "$BATS_TEST_TMPDIR/gh-writes"
  grep -qxF -- "team_reviewers[]=$TEAM" "$BATS_TEST_TMPDIR/gh-writes"
}

@test "a team his comment removed is re-requested and the entry settles" {
  write_entry
  pr_view OPEN '[]' "[$(his_comment)]"
  run restore_team_requests "$F" "$ME" 0
  [ "$status" -eq 0 ]
  wrote_rerequest
  [[ "$output" == *"re-requested review from team $TEAM on $KEY"* ]]
  ! key_present || false
}

@test "a team still requested settles without a write" {
  write_entry
  pr_view OPEN '[{"__typename":"Team","slug":"roofstock/otto-leases-service-co"}]' "[$(his_comment)]"
  run restore_team_requests "$F" "$ME" 0
  [ "$status" -eq 0 ]
  no_writes
  ! key_present || false
}

@test "a team removed without his comment is left alone" {
  write_entry
  pr_view OPEN '[]' '[]'
  run restore_team_requests "$F" "$ME" 0
  [ "$status" -eq 0 ]
  no_writes
  ! key_present || false
}

@test "a comment from before the capture does not count" {
  write_entry
  pr_view OPEN '[]' "[$(review "$ME" COMMENTED 2026-10-15T09:59:59Z)]"
  run restore_team_requests "$F" "$ME" 0
  [ "$status" -eq 0 ]
  no_writes
  ! key_present || false
}

@test "his APPROVED review does not trigger a re-request" {
  write_entry
  pr_view OPEN '[]' "[$(review "$ME" APPROVED 2026-10-15T10:20:00Z)]"
  run restore_team_requests "$F" "$ME" 0
  [ "$status" -eq 0 ]
  no_writes
  ! key_present || false
}

@test "a team another member's review removed first is left alone" {
  write_entry
  pr_view OPEN '[]' "[$(review colleague-rs COMMENTED 2026-10-15T10:10:00Z),$(his_comment)]"
  run restore_team_requests "$F" "$ME" 0
  [ "$status" -eq 0 ]
  no_writes
  ! key_present || false
}

@test "the PR author's own comment does not count as the team's review" {
  write_entry
  pr_view OPEN '[]' "[$(review colleague-rs COMMENTED 2026-10-15T10:10:00Z),$(his_comment)]" colleague-rs
  run restore_team_requests "$F" "$ME" 0
  [ "$status" -eq 0 ]
  wrote_rerequest
  ! key_present || false
}

@test "an approve after his comment settles the entry without a write" {
  write_entry
  pr_view OPEN '[]' "[$(his_comment),$(review "$ME" APPROVED 2026-10-15T10:40:00Z)]"
  run restore_team_requests "$F" "$ME" 0
  [ "$status" -eq 0 ]
  no_writes
  ! key_present || false
}

@test "a member's approve after his comment settles the entry without a write" {
  write_entry
  pr_view OPEN '[]' "[$(his_comment),$(review colleague-rs APPROVED 2026-10-15T10:40:00Z)]"
  run restore_team_requests "$F" "$ME" 0
  [ "$status" -eq 0 ]
  no_writes
  ! key_present || false
}

@test "a non-member's earlier review does not block" {
  write_entry
  pr_view OPEN '[]' "[$(review roof-buddy-rs COMMENTED 2026-10-15T10:05:00Z),$(his_comment)]"
  run restore_team_requests "$F" "$ME" 0
  [ "$status" -eq 0 ]
  wrote_rerequest
  ! key_present || false
}

@test "a pending review with no submittedAt does not count and does not break the pass" {
  write_entry
  pr_view OPEN '[]' "[{\"author\":{\"login\":\"colleague-rs\"},\"state\":\"PENDING\",\"submittedAt\":null},$(his_comment)]"
  run restore_team_requests "$F" "$ME" 0
  [ "$status" -eq 0 ]
  wrote_rerequest
  ! key_present || false
}

@test "a team removed by hand is left alone" {
  write_entry
  pr_view OPEN '[]' "[$(his_comment)]"
  echo '[{"event":"review_request_removed","created_at":"2026-10-15T10:10:00Z","requested_team":{"slug":"otto-leases-service-co"}}]' > "$BATS_TEST_TMPDIR/timeline.json"
  run restore_team_requests "$F" "$ME" 0
  [ "$status" -eq 0 ]
  no_writes
  [[ "$output" == *"team $TEAM on $KEY was removed by hand; not re-requested"* ]]
  ! key_present || false
}

@test "a removal that names nobody blocks the re-request" {
  write_entry
  pr_view OPEN '[]' "[$(his_comment)]"
  echo '[{"event":"review_request_removed","created_at":"2026-10-15T10:10:00Z"}]' > "$BATS_TEST_TMPDIR/timeline.json"
  run restore_team_requests "$F" "$ME" 0
  [ "$status" -eq 0 ]
  no_writes
  ! key_present || false
}

@test "a removal of a user does not block" {
  write_entry
  pr_view OPEN '[]' "[$(his_comment)]"
  echo '[{"event":"review_request_removed","created_at":"2026-10-15T10:10:00Z","requested_reviewer":{"login":"x"}}]' > "$BATS_TEST_TMPDIR/timeline.json"
  run restore_team_requests "$F" "$ME" 0
  [ "$status" -eq 0 ]
  wrote_rerequest
}

@test "a removal before the capture does not block" {
  write_entry
  pr_view OPEN '[]' "[$(his_comment)]"
  echo '[{"event":"review_request_removed","created_at":"2026-10-15T09:00:00Z","requested_team":{"slug":"otto-leases-service-co"}}]' > "$BATS_TEST_TMPDIR/timeline.json"
  run restore_team_requests "$F" "$ME" 0
  [ "$status" -eq 0 ]
  wrote_rerequest
}

@test "a removal on a later timeline page blocks the re-request" {
  write_entry
  pr_view OPEN '[]' "[$(his_comment)]"
  printf '%s\n%s\n' '[{"event":"commented","created_at":"2026-10-15T10:01:00Z"}]' '[{"event":"review_request_removed","created_at":"2026-10-15T10:10:00Z","requested_team":{"slug":"otto-leases-service-co"}}]' > "$BATS_TEST_TMPDIR/timeline.json"
  run restore_team_requests "$F" "$ME" 0
  [ "$status" -eq 0 ]
  no_writes
  ! key_present || false
}

@test "an unreadable timeline keeps the entry" {
  write_entry
  pr_view OPEN '[]' "[$(his_comment)]"
  touch "$BATS_TEST_TMPDIR/timeline-fail"
  run restore_team_requests "$F" "$ME" 0
  [ "$status" -eq 0 ]
  no_writes
  [[ "$output" == *"WARN: could not read the timeline of $KEY"*"retrying next tick"* ]]
  key_present
}

@test "a failed re-request keeps the entry for the next pass" {
  write_entry
  pr_view OPEN '[]' "[$(his_comment)]"
  touch "$BATS_TEST_TMPDIR/api-fail"
  run restore_team_requests "$F" "$ME" 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"ERROR: re-request of team $TEAM on $KEY failed"*"retrying next tick"* ]]
  key_present
  [ "$(jq -c --arg k "$KEY" '.[$k].teams' "$F")" = "[\"$TEAM\"]" ]
  rm "$BATS_TEST_TMPDIR/api-fail" "$BATS_TEST_TMPDIR/gh-writes"
  run restore_team_requests "$F" "$ME" 0
  [ "$status" -eq 0 ]
  wrote_rerequest
  ! key_present || false
}

@test "a response that does not list the team keeps the entry" {
  write_entry
  pr_view OPEN '[]' "[$(his_comment)]"
  echo '{"requested_teams":[]}' > "$BATS_TEST_TMPDIR/rr-response.json"
  run restore_team_requests "$F" "$ME" 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"ERROR: re-request of team $TEAM on $KEY failed (response does not list the team)"* ]]
  key_present
}

@test "an unreadable PR keeps the entry" {
  write_entry
  run restore_team_requests "$F" "$ME" 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN: could not read review requests of $KEY"*"retrying next tick"* ]]
  key_present
  no_writes
}

@test "a closed PR's entry is dropped without a write" {
  write_entry
  pr_view MERGED '[]' "[$(his_comment)]"
  run restore_team_requests "$F" "$ME" 0
  [ "$status" -eq 0 ]
  no_writes
  ! key_present || false
}

@test "verify mode never writes and keeps the entry" {
  write_entry
  pr_view OPEN '[]' "[$(his_comment)]"
  run restore_team_requests "$F" "$ME" 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"verify mode: would re-request review from team $TEAM on $KEY"* ]]
  no_writes
  key_present
}

@test "of two recorded teams only the unsettled one is kept" {
  write_entry "[\"$TEAM\",\"otto-other-service-co\"]"
  pr_view OPEN '[{"__typename":"Team","slug":"roofstock/otto-other-service-co"}]' "[$(his_comment)]"
  touch "$BATS_TEST_TMPDIR/api-fail"
  run restore_team_requests "$F" "$ME" 0
  [ "$status" -eq 0 ]
  [ "$(jq -c --arg k "$KEY" '.[$k].teams' "$F")" = "[\"$TEAM\"]" ]
}

@test "a missing team-requests file is a no-op" {
  run restore_team_requests "$F" "$ME" 0
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$F" ]
}

@test "an unparsable team-requests file warns and returns 0" {
  echo 'not json' > "$F"
  run restore_team_requests "$F" "$ME" 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN"*"$F"* ]]
  no_writes
}

@test "team_members lists the map's members of one team" {
  run team_members "$TEAM"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '%s\n%s' "$ME" colleague-rs)" ]
}

@test "a requested team he is not a member of is never recorded" {
  OWNED_TEAMS="$TEAM"
  run owned_team_requests '{"reviewRequests":[{"__typename":"Team","slug":"roofstock/ai-code-review"},{"__typename":"Team","slug":"roofstock/otto-leases-service-co"},{"__typename":"User","login":"u"}]}'
  [ "$status" -eq 0 ]
  [ "$output" = "$TEAM" ]
  run owned_team_requests '{"reviewRequests":[{"__typename":"Team","slug":"roofstock/ai-code-review"}]}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run owned_team_requests 'not json'
  [ "$status" -eq 1 ]
}

@test "a pr view without reviewRequests yields no team" {
  OWNED_TEAMS="$TEAM"
  run owned_team_requests '{"state":"OPEN"}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

survivor() {
  printf 'roofstock\totto-leases-service\t265\tdc2354f0f3270e27d8b06cdd3801c1e7f6b69e28\tLRX-9992-branch\t\thttps://github.com/roofstock/otto-leases-service/pull/265'
}

@test "a PR with no team request records nothing" {
  FILTER_SURVIVORS=("$(survivor)")
  FILTER_TEAMS=("")
  record_team_requests "$F" 2026-10-15T10:00:00Z
  [ ! -e "$F" ] || [ "$(jq --arg k "$KEY" 'has($k)' "$F")" = "false" ]
}

@test "a captured team is recorded with its since and PR URL" {
  FILTER_SURVIVORS=("$(survivor)")
  FILTER_TEAMS=("$TEAM")
  record_team_requests "$F" 2026-10-15T10:00:00Z
  [ "$(jq -c --arg k "$KEY" '.[$k]' "$F")" = '{"teams":["otto-leases-service-co"],"since":"2026-10-15T10:00:00Z","pr_url":"https://github.com/roofstock/otto-leases-service/pull/265"}' ]
}

@test "a new capture keeps a pending team and its older since" {
  jq -n --arg k "$KEY" '{($k): {teams: ["a-co"], since: "2026-10-01T00:00:00Z", pr_url: "u"}}' > "$F"
  FILTER_SURVIVORS=("$(survivor)")
  FILTER_TEAMS=("b-co")
  record_team_requests "$F" 2026-10-15T10:00:00Z
  [ "$(jq -c --arg k "$KEY" '.[$k].teams' "$F")" = '["a-co","b-co"]' ]
  [ "$(jq -r --arg k "$KEY" '.[$k].since' "$F")" = "2026-10-01T00:00:00Z" ]
}

@test "an unparsable team-requests file fails the record" {
  echo 'not json' > "$F"
  FILTER_SURVIVORS=("$(survivor)")
  FILTER_TEAMS=("b-co")
  run record_team_requests "$F" 2026-10-15T10:00:00Z
  [ "$status" -eq 1 ]
  [ "$(cat "$F")" = "not json" ]
}

@test "a team-requests file that cannot be written fails the record" {
  mkdir -p "$BATS_TEST_TMPDIR/ro"
  F="$BATS_TEST_TMPDIR/ro/team-requests.json"
  chmod a-w "$BATS_TEST_TMPDIR/ro"
  FILTER_SURVIVORS=("$(survivor)")
  FILTER_TEAMS=("$TEAM")
  run record_team_requests "$F" 2026-10-15T10:00:00Z
  chmod u+w "$BATS_TEST_TMPDIR/ro"
  [ "$status" -eq 1 ]
}
