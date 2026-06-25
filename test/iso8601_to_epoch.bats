load test_helper

setup() { source_script; }

@test "parses a +07:00 colon offset" {
  run iso8601_to_epoch "2026-06-25T12:19:10+07:00"
  [ "$status" -eq 0 ]
  [ "$output" -eq 1782364750 ]
}

@test "Z and +0000 and +07:00 of the same instant agree" {
  z=$(iso8601_to_epoch "2026-06-25T05:19:10Z")
  zero=$(iso8601_to_epoch "2026-06-25T05:19:10+0000")
  off=$(iso8601_to_epoch "2026-06-25T12:19:10+07:00")
  [ "$z" -eq "$zero" ]
  [ "$z" -eq "$off" ]
}

@test "garbage timestamp returns non-zero" {
  run iso8601_to_epoch "not-a-timestamp"
  [ "$status" -ne 0 ]
}

@test "empty timestamp returns non-zero" {
  run iso8601_to_epoch ""
  [ "$status" -ne 0 ]
}
