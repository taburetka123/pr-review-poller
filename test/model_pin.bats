load test_helper

@test "review invocation pins --model claude-opus-4-8 (public PR comments must not ride the global default)" {
  grep -qE 'CLAUDE_FLAGS=\(--model claude-opus-4-8 ' "$SCRIPT_UNDER_TEST"
}

@test "head-mode invocation pins --model claude-opus-4-8 too (composes with --post)" {
  grep -qE -- 'CLAUDE --model claude-opus-4-8 -p ' "$SCRIPT_UNDER_TEST"
}
