load test_helper

setup() {
  source_script
  CONFIG_FILE="$BATS_TEST_TMPDIR/config.env"
}

@test "INFLIGHT_TTL defaults to 1h when not configured" {
  unset INFLIGHT_TTL
  load_config
  [ "$INFLIGHT_TTL" = "1h" ]
}

@test "INFLIGHT_TTL is overridable from the config file" {
  echo 'INFLIGHT_TTL="30m"' > "$CONFIG_FILE"
  unset INFLIGHT_TTL
  load_config
  [ "$INFLIGHT_TTL" = "30m" ]
}

@test "default INFLIGHT_TTL parses via duration_to_seconds to 3600" {
  unset INFLIGHT_TTL
  load_config
  run duration_to_seconds "$INFLIGHT_TTL"
  [ "$status" -eq 0 ]
  [ "$output" -eq 3600 ]
}
