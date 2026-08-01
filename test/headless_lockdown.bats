#!/usr/bin/env bats
#
# Every `claude` spawn in this repo must go through the dockwright headless
# wrapper, or say in a marker why not.
#
# This guard lives HERE, not only in dockwright's pytest, because nobody editing
# this repo runs dockwright's suite — and this repo owns the site that fires
# HOURLY over attacker-writable PR text. A guard that fires in a different repo
# from the edit is a guard that fires after the fact.
#
# Derived by PARSING, not from a hand-maintained list of known sites: per
# ~/.claude/rules/drift-guard-tests.md §ADD-ONE, "if the guarded set is a
# hand-maintained list, the next entry is unguarded by construction." Adding a
# new `claude -p` anywhere under bin/ or lib/ fails this test by construction;
# exempting it is a line a reviewer sees.

load test_helper

REPO_ROOT="${BATS_TEST_DIRNAME}/.."

# Every token that could name a claude binary in an executable position, with a
# print flag after it. Broad on purpose: `$CLAUDE`, `${PSP_CLAUDE_BIN}`,
# `/abs/path/claude`, `claude_bin`, `--print` as well as `-p`, and the `=` form.
_spawn_lines() {
  grep -rnE '([[:alnum:]_./$${}~-]*claude[[:alnum:]_./$${}~-]*)([^|;&]{0,200})(-p |--print|-p=)' \
    "$REPO_ROOT/bin" "$REPO_ROOT/lib" 2>/dev/null \
    | grep -vE ':[[:space:]]*#'
}

@test "every claude spawn is wrapper-routed or carries a headless-lockdown marker" {
  local unguarded=()
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local file="${line%%:*}"
    local rest="${line#*:}"
    local lineno="${rest%%:*}"
    # The marker may sit on the invocation itself or in the contiguous comment
    # block just above it — an honest exemption states WHY, which takes lines.
    local window
    window="$(sed -n "$((lineno > 14 ? lineno - 14 : 1)),${lineno}p" "$file")"
    if echo "$window" | grep -q 'headless_spawn'; then continue; fi
    if echo "$window" | grep -qE 'headless-lockdown:[[:space:]]*(wrapper|exempt|verified-by-test)\([^)]+\)'; then
      continue
    fi
    unguarded+=("$file:$lineno")
  done < <(_spawn_lines)

  if [ "${#unguarded[@]}" -gt 0 ]; then
    printf 'unguarded claude spawn(s):\n' >&2
    printf '  %s\n' "${unguarded[@]}" >&2
    printf 'Route it through ~/.claude/scripts/headless_spawn.py (declare a lane in\n' >&2
    printf 'headless-lanes.toml), or add: # headless-lockdown: exempt(<class>) — <why>\n' >&2
    return 1
  fi
}

@test "the guard actually sees a spawn — it has not gone blind" {
  # A pass that means "I found nothing to look at" is indistinguishable from a
  # pass that means "nothing is wrong" (drift-guard-tests.md § sibling class).
  # This repo HAS a spawn site (the attended --head tab); if the matcher stops
  # finding it, the test above goes permanently, silently green.
  local n
  n="$(_spawn_lines | wc -l | tr -d ' ')"
  [ "$n" -ge 1 ]
}

@test "ADD-ONE: a new unhardened claude spawn fails the guard" {
  local scratch="$REPO_ROOT/bin/.headless-lockdown-addone-probe"
  printf '#!/bin/bash\nclaude -p "/some-skill $UNTRUSTED" --model claude-opus-5\n' > "$scratch"
  run bash -c "cd '$REPO_ROOT' && bats test/headless_lockdown.bats -f 'wrapper-routed'"
  rm -f "$scratch"
  [ "$status" -ne 0 ]
}

@test "the triage invocation passes a lane, not capability flags" {
  # Anchor to the ACT line, not to any line that mentions the launcher: a
  # header comment quoting the flag is exactly what blinds a substring guard
  # (drift-guard-tests.md, PR #203).
  grep -qE '^[[:space:]]*"\$LAUNCHER" spawn --lane pr-review-triage' \
    "$REPO_ROOT/bin/pr-review-poller"
}

@test "a missing launcher fails the tick loudly instead of running unhardened" {
  grep -qE 'poll FAILED — headless_spawn.py missing' "$REPO_ROOT/bin/pr-review-poller"
}
