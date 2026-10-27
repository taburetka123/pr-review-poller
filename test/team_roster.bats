load test_helper

# Author gate (filter_prs gate 1). The roster is a hand-maintained mirror of the
# team-members list in ~/.claude/skills/kezoo-review-prs/SKILL.md; it tells a
# teammate (admitted wherever the login is a code owner) from an outside author
# (admitted only in a repo whose pod is a team pod, see repo_pod_ours).

setup() {
  source_script
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/projects/work/otto-leases-service" "$HOME/projects/work/otto-document-templates"

  WORK_GH_USER="aleksandr-beliakov-rs"
  MIN_COMMIT_AGE="10m"
  LEDGER_FILE="$BATS_TEST_TMPDIR/absent-ledger.json"
  REVIEWED_FILE="$BATS_TEST_TMPDIR/absent-reviewed.json"
  ALLOWED_EXTRA_REPOS=""
  OWNED_REPOS=$'otto-leases-service\notto-document-templates\n'
  OWNED_GATE_FAILED=0
  PODS_GATE_FAILED=0
  PODS_CSV_FILE="$BATS_TEST_TMPDIR/pods.csv"
  cat > "$PODS_CSV_FILE" <<'CSV'
"GhStatus","Repository","c3","c4","c5","c6","c7","c8","c9","c10","c11","c12","c13","Pod","c15","c16"
"FoundInGh","otto-leases-service","3","4","5","6","7","8","9","10","11","12","13","Otto - Leasing","15","16"
"FoundInGh","otto-document-templates","3","4","5","6","7","8","9","10","11","12","13","Otto - Shared","15","16"
CSV

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/gh" <<'GH'
#!/bin/bash
repo="${GH_STUB_REPO:-otto-leases-service}"
want="api repos/roofstock/$repo/commits/dc2354f0f3270e27d8b06cdd3801c1e7f6b69e28"
case "$1 $2" in
  "search prs")
    printf '[{"number":265,"title":"t","repository":{"nameWithOwner":"roofstock/%s"},"author":{"login":"%s"}}]\n' "$repo" "${GH_STUB_AUTHOR:?stub author not set}"
    ;;
  "pr view")
    echo '{"state":"OPEN","headRefOid":"dc2354f0f3270e27d8b06cdd3801c1e7f6b69e28","reviews":[],"headRefName":"LRX-9992-branch"}'
    ;;
  *)
    if [ "$1 $2" = "$want" ]; then
      echo "2026-01-01T00:00:00Z"
    else
      echo "unexpected gh call: $*" >&2; exit 1
    fi
    ;;
esac
GH
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# Runs filter_prs for one author WITHOUT a subshell, so FILTER_SURVIVORS (a
# global the caller reads) survives. `run`/$( ) would discard it — the same
# trap owner_guard.bats pins for derive_owned_repos.
filter_as() {
  export GH_STUB_AUTHOR="$1"
  FILTER_LOG="$BATS_TEST_TMPDIR/filter.log"
  filter_prs > "$FILTER_LOG"
}

@test "rustem-zhunussov-rs is on the team, so his PR reaches the review queue" {
  # The reported gap: the skill listed him (SKILL.md commit b407aa7) and the
  # poller's mirror did not, so auto-review silently dropped every PR he opened
  # while interactive review saw them.
  filter_as "rustem-zhunussov-rs"
  [ "${#FILTER_SURVIVORS[@]}" -eq 1 ]
  [[ "${FILTER_SURVIVORS[0]}" == *"otto-leases-service"* ]]
  ! grep -q "not on team" "$FILTER_LOG"
}

@test "an outside author in a team-pod repo is admitted, with the pod named" {
  filter_as "not-on-this-team-rs"
  [ "${#FILTER_SURVIVORS[@]}" -eq 1 ]
  grep -q "admit #265 (roofstock/otto-leases-service): outside author not-on-this-team-rs — pod Otto - Leasing (team pod)" "$FILTER_LOG"
}

@test "an outside author in Otto - Shared is skipped, with the pod named" {
  export GH_STUB_REPO=otto-document-templates
  filter_as "not-on-this-team-rs"
  [ "${#FILTER_SURVIVORS[@]}" -eq 0 ]
  grep -q "skip #265 (roofstock/otto-document-templates): outside author not-on-this-team-rs — pod 'Otto - Shared' is not a team pod" "$FILTER_LOG"
}

@test "a teammate in Otto - Shared is admitted as today" {
  export GH_STUB_REPO=otto-document-templates
  filter_as "dmitry-indikeev-rs"
  [ "${#FILTER_SURVIVORS[@]}" -eq 1 ]
  grep -q "admit #265 (roofstock/otto-document-templates): author dmitry-indikeev-rs on team" "$FILTER_LOG"
}

@test "an outside author is skipped when the pods gate failed, fail closed" {
  PODS_GATE_FAILED=1
  filter_as "not-on-this-team-rs"
  [ "${#FILTER_SURVIVORS[@]}" -eq 0 ]
  grep -q "outside author not-on-this-team-rs — pods map unavailable, fail closed" "$FILTER_LOG"
}

@test "a teammate is admitted when the pods gate failed" {
  PODS_GATE_FAILED=1
  filter_as "rustem-zhunussov-rs"
  [ "${#FILTER_SURVIVORS[@]}" -eq 1 ]
}
