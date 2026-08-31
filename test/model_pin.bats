load test_helper

@test "triage invocation pins the reviewed LANE, which is where the model pin moved" {
  # Was: `CLAUDE_FLAGS=(--model claude-opus-5 …)`. Since harden-headless the
  # triage session is spawned through headless_spawn.py, which builds the argv
  # from the `pr-review-triage` lane — a call site that could pass --model could
  # equally pass --allow 'Bash(python3:*)', so it may pass neither. The pin
  # moved to headless-lanes.toml (a reviewed diff); this asserts the poller
  # binds to that specific lane, and poll_integration.bats asserts exactly one
  # --lane reaches the spawn.
  grep -qE '^[[:space:]]*"\$LAUNCHER" spawn --lane pr-review-triage' "$SCRIPT_UNDER_TEST"
}

@test "head-mode invocation pins --model claude-opus-5 too (composes with --post)" {
  grep -qE '^[[:space:]]*write text "\$CLAUDE --model claude-opus-5 -p ' "$SCRIPT_UNDER_TEST"
}

@test "no capability flag survives on the triage invocation line" {
  # Tier-2 finding 1 kept its shape: anchor the ACT line, not a declaration a
  # header comment could satisfy. The inversion is the point now — the executed
  # line must carry NO --model/--tools/--allowedTools/--settings/--mcp-config,
  # because everything that carries authority comes from the lane.
  local act
  act="$(grep -A3 -E '^[[:space:]]*"\$LAUNCHER" spawn --lane pr-review-triage' "$SCRIPT_UNDER_TEST")"
  [ -n "$act" ]
  ! echo "$act" | grep -qE -- '--(model|tools|allowedTools|allowed-tools|settings|mcp-config|setting-sources|add-dir|permission-mode|dangerously-skip-permissions)'
}
