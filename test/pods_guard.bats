load test_helper

# Domain gate (Tier-2 incident follow-up): repo→pod via engineering-pods'
# repositories-config.csv, allowed pods from config. Distinct from the
# clone check — capability vs domain. Fail closed on every unresolved shape.

setup() {
  source_script
  PODS_CSV_FILE="$BATS_TEST_TMPDIR/pods.csv"
  cat > "$PODS_CSV_FILE" <<'CSV'
"GhStatus","Repository","CreatedDatePst","ModifiedDatePst","Type","Status","IsArchived","Visibility","IsFork","SolutionType","AppType","PrimaryLanguage","DevelopmentType","Pod"
"FoundInGh","otto-leases-service","1/1/2025","1/1/2025","Service","Active","FALSE","Internal","FALSE","","","Kotlin","TrunkBased","Otto - Leasing"
"FoundInGh","otto-business-process-service","1/1/2025","1/1/2025","Service","Active","FALSE","Internal","FALSE","","","Kotlin","TrunkBased","Otto - Core"
"FoundInGh","services-contracts","2/8/2023","2/8/2023","Protobuf","Active","FALSE","Internal","FALSE","Protobuf","","Protobuf","TrunkBased",""
CSV
  ALLOWED_PODS="Otto - Leasing|Otto - Resident Experience|Otto - Shared"
  ALLOWED_EXTRA_REPOS="services-contracts"
}

@test "repo in an allowed pod passes" {
  run pod_allowed otto-leases-service
  [ "$status" -eq 0 ]
}

@test "repo in a foreign pod is refused and the resolved pod is named" {
  run pod_allowed otto-business-process-service
  [ "$status" -eq 1 ]
  [[ "$output" == *"Otto - Core"* ]]
}

@test "repo absent from the CSV is refused (fail closed)" {
  run pod_allowed otto-unknown-service
  [ "$status" -eq 1 ]
  [[ "$output" == *"unresolved"* ]]
}

@test "empty-pod repo passes only via the extra-repos escape hatch" {
  run pod_allowed services-contracts
  [ "$status" -eq 0 ]
  ALLOWED_EXTRA_REPOS=""
  run pod_allowed services-contracts
  [ "$status" -eq 1 ]
}

@test "missing CSV refuses everything loudly (fail closed)" {
  PODS_CSV_FILE="$BATS_TEST_TMPDIR/nope.csv"
  run pod_allowed otto-leases-service
  [ "$status" -eq 1 ]
  [[ "$output" == *"pods map unavailable"* ]]
}

@test "allowed-pod match is exact, not substring" {
  cat >> "$PODS_CSV_FILE" <<'CSV'
"FoundInGh","otto-fake-service","1/1/2025","1/1/2025","Service","Active","FALSE","Internal","FALSE","","","Kotlin","TrunkBased","Otto - Leasing And More"
CSV
  run pod_allowed otto-fake-service
  [ "$status" -eq 1 ]
}
