load test_helper

@test "sourcing the script runs no subcommand (no status output)" {
  run bash -c "source '$SCRIPT_UNDER_TEST'; echo SOURCED_OK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SOURCED_OK"* ]]
  [[ "$output" != *"pr-review-poller status"* ]]
  [[ "$output" != *"=== pr-review-poller status ==="* ]]
}

@test "executing the script directly still dispatches (help works)" {
  run "$SCRIPT_UNDER_TEST" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"unattended PR auto-review"* ]]
}
