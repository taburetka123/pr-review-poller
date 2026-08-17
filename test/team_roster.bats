load test_helper

# Team filter (filter_prs gate 1). The roster is a hand-maintained mirror of the
# team-members list in ~/.claude/skills/kezoo-review-prs/SKILL.md, so these
# tests pin the two things the mirror can get wrong: a teammate the skill knows
# and the poller does not (silent under-review), and a stranger the poller would
# admit (over-review — the 2026-07-27 incident class).

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

  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/gh" <<'GH'
#!/bin/bash
case "$1 $2" in
  "search prs")
    printf '[{"number":265,"title":"t","repository":{"nameWithOwner":"roofstock/otto-leases-service"},"author":{"login":"%s"}}]\n' "${GH_STUB_AUTHOR:?stub author not set}"
    ;;
  "pr view")
    echo '{"state":"OPEN","commits":[{"oid":"dc2354f0f3270e27d8b06cdd3801c1e7f6b69e28","committedDate":"2026-01-01T00:00:00Z"}],"reviews":[],"headRefName":"LRX-9992-branch"}'
    ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
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

# The roster as the RUNNING CODE holds it. setup() sourced the script, so this
# is the array filter_prs itself loops — not a regex over the source. An earlier
# version parsed the file, and any behaviour-preserving reformat (a wrapped
# line, a `team+=` append, quoted elements) silently shrank the covered set
# while every test stayed green.
roster_from_script() {
  printf '%s\n' "${TEAM[@]}"
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

@test "every login in the shipped roster is admitted" {
  local login checked=0 expected=0
  for login in $(roster_from_script); do
    # `gh search prs --review-requested=@me` cannot return a PR this login
    # authored, so admitting our own login is an input the real source never
    # emits — and asserting it would false-red a later "skip my own PRs" guard.
    [ "$login" = "$WORK_GH_USER" ] && continue
    expected=$((expected + 1))
    filter_as "$login"
    if [ "${#FILTER_SURVIVORS[@]}" -ne 1 ]; then
      echo "roster member '$login' was NOT admitted: $(cat "$FILTER_LOG")"
      return 1
    fi
    checked=$((checked + 1))
  done
  # The loop walks the live TEAM array, so coverage tracks the roster by
  # construction — no floor to go stale. These two only refuse a VACUOUS pass:
  # an empty or self-only TEAM would otherwise satisfy the loop by never running.
  [ "$expected" -eq "$(( ${#TEAM[@]} - 1 ))" ]
  [ "$checked" -ge 4 ]
}

@test "an author outside the roster is skipped, with the team reason named" {
  filter_as "not-on-this-team-rs"
  [ "${#FILTER_SURVIVORS[@]}" -eq 0 ]
  grep -q "author not-on-this-team-rs not on team" "$FILTER_LOG"
}
