load test_helper

# Domain gate v2: the allowed repo set is DERIVED at runtime from the
# engineering-pods code-owner map — every `<repo>-co` team the poller's own gh
# login belongs to is a repo it reviews, because that membership is what
# generates the review requests. Replaces the pod-ownership gate, which was
# wrong in both directions (it admitted otto-business-process-service, the
# 2026-07-27 incident repo, and excluded repos the engineer actually reviews).

setup() {
  source_script
  WORK_GH_USER="aleksandr-beliakov-rs"
  ALLOWED_EXTRA_REPOS="services-contracts"
  OWNED_CSV_FILE="$BATS_TEST_TMPDIR/code-owners.csv"
  cat > "$OWNED_CSV_FILE" <<'CSV'
"Team","Pod","Member"
"account-mgmt-admin-app-co","Seller Services","jia-ming-li-rs"
"otto-leases-service-co","Property Services (RTM)","aleksandr-beliakov-rs"
"otto-prospects-service-co","Property Services (RTM)","aleksandr-beliakov-rs"
"otto-document-templates-co","Property Services (RTM)","aleksandr-beliakov-rs"
"otto-service-requests-service-co","Property Services","someone-else-rs"
"otto-business-process-service-co","Otto Core","another-person-rs"
CSV
}

@test "derives the owned set from the caller's own gh login" {
  run derive_owned_repos
  [ "$status" -eq 0 ]
  derive_owned_repos
  [[ "$OWNED_REPOS" == *"otto-leases-service"* ]]
  [[ "$OWNED_REPOS" == *"otto-prospects-service"* ]]
  [[ "$OWNED_REPOS" == *"otto-document-templates"* ]]
  # another member's teams must not leak in
  [[ "$OWNED_REPOS" != *"account-mgmt-admin-app"* ]]
}

@test "a repo whose -co team the login is NOT in is refused, with an actionable reason" {
  derive_owned_repos
  run repo_owned otto-service-requests-service
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a code owner"* ]]
  run repo_owned otto-business-process-service
  [ "$status" -eq 1 ]
}

@test "the incident repo is refused by the shipped derivation" {
  # otto-business-process-service is the repo the 2026-07-27 E2E posted into.
  derive_owned_repos
  run repo_owned otto-business-process-service
  [ "$status" -eq 1 ]
}

@test "ALLOWED_EXTRA_REPOS is additive on top of the derived set" {
  derive_owned_repos
  run repo_owned services-contracts
  [ "$status" -eq 0 ]
  ALLOWED_EXTRA_REPOS=""
  run repo_owned services-contracts
  [ "$status" -eq 1 ]
}

@test "FAIL CLOSED loudly: zero rows matched for the identity mutes nothing silently" {
  # Removing the login's rows must NOT read as "owns nothing, skip quietly" —
  # a renamed login or a mangled map looks identical from the inside.
  grep -v "aleksandr-beliakov-rs" "$OWNED_CSV_FILE" > "$OWNED_CSV_FILE.tmp"
  mv "$OWNED_CSV_FILE.tmp" "$OWNED_CSV_FILE"
  run derive_owned_repos
  [ "$status" -eq 1 ]
  [[ "$output" == *"ZERO code-owner teams matched"* ]]
  [[ "$output" == *"aleksandr-beliakov-rs"* ]]
}

@test "FAIL CLOSED: missing map file has its own reason" {
  OWNED_CSV_FILE="$BATS_TEST_TMPDIR/nope.csv"
  run derive_owned_repos
  [ "$status" -eq 1 ]
  [[ "$output" == *"code-owner map unavailable"* ]]
  [[ "$output" != *"ZERO code-owner teams"* ]]
}

@test "FAIL CLOSED: an unparseable map shape is refused, never ignored" {
  # A silently-changed schema must not degrade to "matched nothing".
  printf '"Something","Else"\n"a","b"\n' > "$OWNED_CSV_FILE"
  run derive_owned_repos
  [ "$status" -eq 1 ]
  [[ "$output" == *"unexpected header"* ]]
}

@test "FAIL CLOSED: an empty map file is refused with the unparseable reason" {
  : > "$OWNED_CSV_FILE"
  run derive_owned_repos
  [ "$status" -eq 1 ]
  [[ "$output" == *"unexpected header"* ]]
}

@test "team names must end in -co; an odd row cannot silently widen the set" {
  cat >> "$OWNED_CSV_FILE" <<'CSV'
"weird-team-without-suffix","Pod","aleksandr-beliakov-rs"
CSV
  run derive_owned_repos
  [ "$status" -eq 1 ]
  [[ "$output" == *"team name without the -co suffix"* ]]
}

@test "matching is exact: a login that merely contains ours does not inherit its teams" {
  cat >> "$OWNED_CSV_FILE" <<'CSV'
"otto-secret-service-co","Pod","not-aleksandr-beliakov-rs-either"
CSV
  derive_owned_repos
  run repo_owned otto-secret-service
  [ "$status" -eq 1 ]
}

@test "derive_owned_repos must be called in the CURRENT shell, not a subshell" {
  # Regression: cmd_run first captured the reason with $(derive_owned_repos),
  # which forks — OWNED_REPOS was built in the child and lost, so every repo
  # looked unowned and the tick muted itself silently. Pin the call shape.
  grep -qE '^[[:space:]]*if ! derive_owned_repos > "\$owned_out"; then' "$SCRIPT_UNDER_TEST"
  # Match EXECUTED lines only: the comment above the call site quotes the
  # forbidden form deliberately, and a whole-file grep would trip on it —
  # the same prose-blinds-the-guard trap, inverted.
  [ "$(grep -vE '^[[:space:]]*#' "$SCRIPT_UNDER_TEST" | grep -cE '\$\(derive_owned_repos\)')" -eq 0 ]
}

@test "an admitted repo reports WHICH mechanism admitted it" {
  # Tier-2 #2: an override admit was indistinguishable from a derived one, so
  # a stale ALLOWED_EXTRA_REPOS entry could keep a repo reviewed after its -co
  # membership was removed, with nothing in the log to show it.
  derive_owned_repos
  run repo_owned otto-leases-service
  [ "$status" -eq 0 ]
  [[ "$output" == *"code owner"* ]]
  [[ "$output" != *"override"* ]]
  run repo_owned services-contracts
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALLOWED_EXTRA_REPOS override"* ]]
}

@test "an override entry that is ALSO derived reports the derivation, not the override" {
  # The live config lists all 19 derived repos in the override; a repo that
  # would pass on its own merit must not be reported as override-admitted.
  ALLOWED_EXTRA_REPOS="services-contracts|otto-leases-service"
  derive_owned_repos
  run repo_owned otto-leases-service
  [ "$status" -eq 0 ]
  [[ "$output" == *"code owner"* ]]
}

@test "the last-review dedup uses the resolved login, not a hardcoded name" {
  # PR #5 advertises "no hardcoded identity"; filter_prs kept a literal.
  [ "$(grep -vE '^[[:space:]]*#' "$SCRIPT_UNDER_TEST" | grep -cE 'local me="aleksandr-beliakov-rs"')" -eq 0 ]
  grep -qE '^[[:space:]]*local me="\$WORK_GH_USER"' "$SCRIPT_UNDER_TEST"
}
