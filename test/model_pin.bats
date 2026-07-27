load test_helper

@test "review invocation pins --model claude-opus-5 (public PR comments must not ride the global default)" {
  grep -qE '^[[:space:]]*CLAUDE_FLAGS=\(--model claude-opus-5 ' "$SCRIPT_UNDER_TEST"
}

@test "head-mode invocation pins --model claude-opus-5 too (composes with --post)" {
  grep -qE '^[[:space:]]*write text "\$CLAUDE --model claude-opus-5 -p ' "$SCRIPT_UNDER_TEST"
}

@test "the executed claude call actually expands CLAUDE_FLAGS (assignment pin is dead weight without it)" {
  # Tier-2 finding 1: the assignment anchor above passes even when the real
  # invocation drops the array — and then the triage session that posts public
  # PR comments rides the global default model. Anchor the ACT line too.
  # (poll_integration.bats additionally asserts --model on the stub's argv.)
  grep -qE '^[[:space:]]*"\$CLAUDE" "\$\{CLAUDE_FLAGS\[@\]\}" -p ' "$SCRIPT_UNDER_TEST"
}
