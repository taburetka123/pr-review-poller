load test_helper

setup() {
  source_script
  FINDINGS_DIR="$BATS_TEST_TMPDIR/findings"
  SURVIVOR=$'roofstock\totto-leases-service\t265\tdc2354f\tbranch\t\turl'
}

@test "assert_findings_fresh: missing log returns 1 and prints ERROR" {
  run assert_findings_fresh "$(date +%s)" "$SURVIVOR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: findings log missing for roofstock/otto-leases-service#265"* ]]
}

@test "assert_findings_fresh: stale log (mtime < tick start) returns 1" {
  mkdir -p "$FINDINGS_DIR/roofstock/otto-leases-service"
  echo old > "$FINDINGS_DIR/roofstock/otto-leases-service/265.log"
  touch -t 202601010000 "$FINDINGS_DIR/roofstock/otto-leases-service/265.log"
  run assert_findings_fresh "$(date +%s)" "$SURVIVOR"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: findings log stale"* ]]
}

@test "assert_findings_fresh: fresh log returns 0, no ERROR" {
  local start; start=$(date +%s)
  mkdir -p "$FINDINGS_DIR/roofstock/otto-leases-service"
  echo fresh > "$FINDINGS_DIR/roofstock/otto-leases-service/265.log"
  run assert_findings_fresh "$start" "$SURVIVOR"
  [ "$status" -eq 0 ]
  [[ "$output" != *"ERROR"* ]]
}

@test "assert_findings_fresh: counts multiple misses" {
  local s2=$'roofstock\totto-prospects-service\t486\th\tb\t\tu'
  run assert_findings_fresh "$(date +%s)" "$SURVIVOR" "$s2"
  [ "$status" -eq 2 ]
}
