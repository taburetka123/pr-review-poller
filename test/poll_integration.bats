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

  # Domain gate fixture: without it the fail-closed ownership gate refuses
  # every PR. Member column holds gh logins, matching the real map's shape.
  export PR_REVIEW_OWNED_CSV="$BATS_TEST_TMPDIR/code-owners.csv"
  cat > "$PR_REVIEW_OWNED_CSV" <<'CSV'
"Team","Pod","Member"
"otto-leases-service-co","Property Services (RTM)","aleksandr-beliakov-rs"
CSV

  # gh stub: auth token / search prs / pr view
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/gh" <<'GH'
#!/bin/bash
case "$1 $2" in
  "auth token") echo "gho_stub" ;;
  "search prs") echo '[{"number":265,"title":"t","repository":{"nameWithOwner":"roofstock/otto-leases-service"},"author":{"login":"dmitry-indikeev-rs"}}]' ;;
  "pr view") echo '{"state":"'"${GH_STUB_PR_STATE:-OPEN}"'","headRefOid":"dc2354f0f3270e27d8b06cdd3801c1e7f6b69e28","reviews":[],"headRefName":"LRX-9992-branch"}' ;;
  "api repos/roofstock/otto-leases-service/commits/dc2354f0f3270e27d8b06cdd3801c1e7f6b69e28") echo "2026-01-01T00:00:00Z" ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
GH
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"

  export STUB_REVIEW_MODEL="claude-probe-9-9"
  cat > "$BATS_TEST_TMPDIR/bin/dockwright" <<DW
#!/bin/bash
[ "\$1" = model ] && [ "\$2" = resolve ] || { echo "unexpected dockwright call: \$*" >&2; exit 2; }
[ "\$3" = '@opus' ] || { echo "wrong family token: \$3" >&2; exit 3; }
echo "$STUB_REVIEW_MODEL"
DW
  chmod +x "$BATS_TEST_TMPDIR/bin/dockwright"
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
  elif [ "$1" = "holds-stale" ]; then
    cat > "$PR_REVIEW_POLLER_CLAUDE" <<'CL'
#!/bin/bash
{ printf '%s\n' "$@"; echo '--CALL--'; } >> "${BATS_TEST_TMPDIR:?}/claude-argv"
L="$PR_REVIEW_POLLER_STATE_DIR/held.json"
jq '.["roofstock/otto-leases-service#265"] = {commit: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", held_at: "2026-01-01T00:00:00Z", reason: "1 major finding at conf 4", pr_url: "https://github.com/roofstock/otto-leases-service/pull/265"}' "$L" > "$L.tmp" && mv "$L.tmp" "$L"
mkdir -p "$PR_REVIEW_FINDINGS_ROOT/roofstock/otto-leases-service"
printf '=== stub ===\nAction: HOLD\n' >> "$PR_REVIEW_FINDINGS_ROOT/roofstock/otto-leases-service/265.log"
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

# The verify banner must never re-acquire the overclaim vocabulary that
# round-3 Tier-2 punctured. Positive checks cannot see an ADDED phrase, so this
# is the negative arm: strip the sanctioned "NOT airtight", then fail on any
# remaining overclaim token. Case-insensitive — "STRUCTURALLY" must not slip by.
assert_banner_has_no_overclaim() {
  local banner lower
  banner=$(printf '%s\n' "$1" | grep 'VERIFY MODE' || true)
  [ -n "$banner" ] || return 1
  lower=$(printf '%s' "$banner" | tr '[:upper:]' '[:lower:]')
  lower=${lower//not airtight/}
  local bad
  for bad in structurally impossible airtight "fully covered" "cannot write"; do
    case "$lower" in
      *"$bad"*) echo "OVERCLAIM in verify banner: '$bad'"; return 1 ;;
    esac
  done
  return 0
}

# Every recorded claude call must carry exactly ONE --model, valued as the
# roster pin. Presence is not enough: claude's CLI takes the LAST --model
# (spiked empirically by the Tier-2 delta), so a later duplicate silently
# shadows the pin (finding E); and a new unpinned call site must fail, not
# hide behind the last-written record (finding F).
assert_every_call_pinned() {
  awk -v want="$STUB_REVIEW_MODEL" '
    /^--CALL--$/ { calls++; if (models != 1 || value != want) bad=1; models=0; value=""; next }
    prev { value=$0; prev=0 }
    $0 == "--model" { models++; prev=1 }
    END { exit (calls < 1 || bad) ? 1 : 0 }
  ' "$BATS_TEST_TMPDIR/claude-argv"
}

write_osascript_shim() {
  cat > "$BATS_TEST_TMPDIR/bin/osascript" <<'OSA'
#!/bin/bash
cat > "${BATS_TEST_TMPDIR:?}/osa-script"
OSA
  chmod +x "$BATS_TEST_TMPDIR/bin/osascript"
}

@test "head mode hands iTerm a claude command pinned to the resolved model" {
  write_claude_stub silent
  write_osascript_shim
  run "$SCRIPT_UNDER_TEST" run --head --post
  [ "$status" -eq 0 ]
  local cmd
  cmd=$(sed -n 's/^[[:space:]]*write text "\(.*\)"$/\1/p' "$BATS_TEST_TMPDIR/osa-script")
  [ -n "$cmd" ]
  bash -c "${cmd//\\\"/\"}"
  assert_every_call_pinned
  grep -q -- "--post" "$BATS_TEST_TMPDIR/claude-argv"
}

@test "an unresolvable review model fails the run before anything launches, in both modes" {
  write_claude_stub writes
  write_osascript_shim
  printf '#!/bin/bash\nexit 0\n' > "$BATS_TEST_TMPDIR/bin/dockwright"
  run "$SCRIPT_UNDER_TEST" run --force --min-commit-age 0
  [ "$status" -eq 1 ]
  [[ "$output" == *"poll FAILED"*"nothing was reviewed"* ]]
  [[ "$output" != *"launching"* ]]
  [ ! -e "$RUN_ALL_INPUT" ]
  [ ! -e "$BATS_TEST_TMPDIR/claude-argv" ]
  run "$SCRIPT_UNDER_TEST" run --head --post
  [ "$status" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/osa-script" ]
}

@test "a dockwright that exits nonzero fails the run with the poller's own line" {
  write_claude_stub writes
  printf '#!/bin/bash\necho claude-partial-1\nexit 4\n' > "$BATS_TEST_TMPDIR/bin/dockwright"
  run "$SCRIPT_UNDER_TEST" run --force --min-commit-age 0
  [ "$status" -eq 1 ]
  [[ "$output" == *"poll FAILED"*"rc=4"* ]]
  [ ! -e "$RUN_ALL_INPUT" ]
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

@test "a HOLD the triage wrote is pinned to the head the poller admitted, so the next tick skips it" {
  write_claude_stub holds-stale
  run "$SCRIPT_UNDER_TEST" run --force --min-commit-age 0
  [ "$status" -eq 0 ]
  [ "$(jq -r '.["roofstock/otto-leases-service#265"].commit' "$PR_REVIEW_POLLER_STATE_DIR/held.json")" = "dc2354f0f3270e27d8b06cdd3801c1e7f6b69e28" ]
  run "$SCRIPT_UNDER_TEST" run --force --min-commit-age 0
  [[ "$output" == *"held at HEAD dc2354f pending human review"* ]]
  [[ "$output" != *"launching"* ]]
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

@test "repo the login does not code-own is skipped by the domain gate, reviewer never launched" {
  write_claude_stub writes
  cat > "$PR_REVIEW_OWNED_CSV" <<'CSV'
"Team","Pod","Member"
"otto-other-service-co","Property Services (RTM)","aleksandr-beliakov-rs"
CSV
  run "$SCRIPT_UNDER_TEST" run --force --min-commit-age 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"domain gate — not a code owner of it"* ]]
  [[ "$output" == *"no PRs survived filters"* ]]
  [[ "$output" != *"launching"* ]]
}

@test "zero code-owner rows mutes the tick LOUDLY, never silently" {
  write_claude_stub writes
  cat > "$PR_REVIEW_OWNED_CSV" <<'CSV'
"Team","Pod","Member"
"otto-leases-service-co","Property Services (RTM)","somebody-else-rs"
CSV
  run "$SCRIPT_UNDER_TEST" run --force --min-commit-age 0
  # A gate-failure tick must NOT look like a healthy empty queue (Tier-2 #1):
  # nonzero exit, its own terminal line, and never "poll done".
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: domain gate unavailable"* ]]
  [[ "$output" == *"ZERO code-owner teams matched"* ]]
  [[ "$output" == *"domain gate unavailable (see the ERROR above) — fail closed"* ]]
  [[ "$output" == *"poll FAILED — domain gate unavailable"* ]]
  [[ "$output" != *"poll done"* ]]
  [[ "$output" != *"no PRs survived filters"* ]]
  [[ "$output" != *"launching"* ]]
}

@test "a healthy empty queue still exits 0 with poll done (the gate-failure branch must not overreach)" {
  write_claude_stub writes
  cat > "$PR_REVIEW_OWNED_CSV" <<'CSV'
"Team","Pod","Member"
"otto-other-service-co","Property Services (RTM)","aleksandr-beliakov-rs"
CSV
  run "$SCRIPT_UNDER_TEST" run --force --min-commit-age 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"no PRs survived filters"* ]]
  [[ "$output" == *"poll done"* ]]
  [[ "$output" != *"poll FAILED"* ]]
}

@test "an override-admitted repo says so in the log" {
  write_claude_stub writes
  cat > "$PR_REVIEW_OWNED_CSV" <<'CSV'
"Team","Pod","Member"
"otto-other-service-co","Property Services (RTM)","aleksandr-beliakov-rs"
CSV
  ALLOWED_EXTRA_REPOS="otto-leases-service" run "$SCRIPT_UNDER_TEST" run --force --min-commit-age 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"admit #265 (roofstock/otto-leases-service): domain gate — ALLOWED_EXTRA_REPOS override"* ]]
}

@test "a derived repo is admitted as code owner, not as an override" {
  write_claude_stub writes
  run "$SCRIPT_UNDER_TEST" run --force --min-commit-age 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"admit #265 (roofstock/otto-leases-service): domain gate — code owner (otto-leases-service-co)"* ]]
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
  # Banner states the accurate claim (no gh/git/MCP write path) AND names all
  # three residuals — an overclaim here is the failure this wording replaced.
  [[ "$output" == *"VERIFY MODE: no GitHub write on any gh / git / MCP path"* ]]
  [[ "$output" == *"NOT airtight"* ]]
  [[ "$output" == *"raw HTTP clients"* ]]
  [[ "$output" == *"keyring"* ]]
  [[ "$output" == *"security"* ]]
  # NEGATIVE ARM: positive substring checks catch an OMITTED residual but are
  # blind to an ADDED overclaim — a re-added "structurally impossible" passed
  # every check above. Forbid the overclaim vocabulary outright. "NOT airtight"
  # is the one sanctioned use of "airtight", so strip it before matching.
  assert_banner_has_no_overclaim "$output"
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

@test "a non-executable PR_REVIEW_POLLER_CLAUDE falls back to the default and says so" {
  write_claude_stub writes
  export PR_REVIEW_POLLER_CLAUDE_DEFAULT="$PR_REVIEW_POLLER_CLAUDE"
  export PR_REVIEW_POLLER_CLAUDE="$BATS_TEST_TMPDIR/no-such-claude"
  run "$SCRIPT_UNDER_TEST" run --force --min-commit-age 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"PR_REVIEW_POLLER_CLAUDE=$BATS_TEST_TMPDIR/no-such-claude is not an executable file; falling back to $PR_REVIEW_POLLER_CLAUDE_DEFAULT"* ]]
  [ -s "$BATS_TEST_TMPDIR/claude-argv" ]
}

@test "a directory is not accepted as PR_REVIEW_POLLER_CLAUDE" {
  write_claude_stub writes
  export PR_REVIEW_POLLER_CLAUDE_DEFAULT="$PR_REVIEW_POLLER_CLAUDE"
  export PR_REVIEW_POLLER_CLAUDE="$BATS_TEST_TMPDIR"
  run "$SCRIPT_UNDER_TEST" run --force --min-commit-age 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"is not an executable file; falling back to"* ]]
  [ -s "$BATS_TEST_TMPDIR/claude-argv" ]
}

@test "under bats a broken PR_REVIEW_POLLER_CLAUDE with no default override refuses instead of running the real claude" {
  export PR_REVIEW_POLLER_CLAUDE="$BATS_TEST_TMPDIR/no-such-claude"
  unset PR_REVIEW_POLLER_CLAUDE_DEFAULT
  run "$SCRIPT_UNDER_TEST" run --force --min-commit-age 0
  [ "$status" -eq 3 ]
  [[ "$output" == *"refusing the real claude under test"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/claude-argv" ]
}

@test "under bats with no claude override at all the poller refuses instead of running the real claude" {
  unset PR_REVIEW_POLLER_CLAUDE PR_REVIEW_POLLER_CLAUDE_DEFAULT
  run "$SCRIPT_UNDER_TEST" run --force --min-commit-age 0
  [ "$status" -eq 3 ]
  [[ "$output" == *"refusing the real claude under test"* ]]
}

@test "under bats a PR_REVIEW_POLLER_CLAUDE that names the real claude is refused" {
  unset PR_REVIEW_POLLER_CLAUDE_DEFAULT
  export PR_REVIEW_POLLER_CLAUDE=/Users/kezoo/.local/bin/claude
  run "$SCRIPT_UNDER_TEST" run --force --min-commit-age 0
  [ "$status" -eq 3 ]
  [[ "$output" == *"refusing the real claude under test"* ]]
}

@test "under bats a PR_REVIEW_POLLER_CLAUDE that names the real claude's resolved target is refused" {
  [ -e /Users/kezoo/.local/bin/claude ] || skip "no real claude on this machine"
  unset PR_REVIEW_POLLER_CLAUDE_DEFAULT
  export PR_REVIEW_POLLER_CLAUDE="$(/bin/realpath /Users/kezoo/.local/bin/claude)"
  run "$SCRIPT_UNDER_TEST" run --force --min-commit-age 0
  [ "$status" -eq 3 ]
  [[ "$output" == *"refusing the real claude under test"* ]]
}
