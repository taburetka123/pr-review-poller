load test_helper

@test "review invocation pins --model claude-opus-5 (public PR comments must not ride the global default)" {
  grep -qE '^[[:space:]]*CLAUDE_FLAGS=\(--model claude-opus-5 ' "$SCRIPT_UNDER_TEST"
}

@test "head-mode invocation pins --model claude-opus-5 too (composes with --post)" {
  grep -qE '^[[:space:]]*write text "\$CLAUDE --model claude-opus-5 -p ' "$SCRIPT_UNDER_TEST"
}
