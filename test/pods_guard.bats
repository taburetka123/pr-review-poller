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

@test "repo absent from the CSV is refused (fail closed) with a DISTINCT loud reason" {
  # Must be distinguishable from "resolved to a foreign pod": a repo missing
  # from the authoritative map means the map (or the allowlist) needs a human,
  # not that the repo is out of scope. services-contracts is absent for real.
  run pod_allowed otto-unknown-service
  [ "$status" -eq 1 ]
  [[ "$output" == *"ABSENT from the pods map"* ]]
  [[ "$output" != *"outside allowed domain"* ]]
}

@test "services-contracts: real shape is a PRESENT row with an EMPTY Pod cell, allowed only via the repo allowlist" {
  # Verified against the real map: line 764 of repositories-config.csv has the
  # row with a blank Pod cell — so the EMPTY-cell branch is what fires for it,
  # not the absent-repo branch. (A round-4 PR-body edit wrongly called it
  # absent; this test pins the truth so the claim cannot drift again.)
  run pod_allowed services-contracts
  [ "$status" -eq 0 ]
  ALLOWED_EXTRA_REPOS=""
  run pod_allowed services-contracts
  [ "$status" -eq 1 ]
  [[ "$output" == *"pod cell EMPTY in the pods map"* ]]
  [[ "$output" != *"ABSENT"* ]]
}

@test "the shipped default pod set covers every repo the poller actually meets" {
  # Guards the round-3 IMPORTANT: pure pod-derivation silently dropped
  # otto-service-requests-service (the poller's own default WORK_CWD).
  # Unset the fixture values so load_config yields the SHIPPED defaults —
  # this test exists to guard those, not the fixture.
  unset ALLOWED_PODS ALLOWED_EXTRA_REPOS
  CONFIG_FILE="$BATS_TEST_TMPDIR/no-such-config.env"
  load_config
  PODS_CSV_FILE="$BATS_TEST_TMPDIR/real-shaped.csv"
  cat > "$PODS_CSV_FILE" <<'CSV'
"GhStatus","Repository","x","x","x","x","x","x","x","x","x","x","x","Pod","t"
"FoundInGh","otto-leases-service","x","x","x","x","x","x","x","x","x","x","x","Otto - Leasing","t"
"FoundInGh","otto-prospects-service","x","x","x","x","x","x","x","x","x","x","x","Otto - Leasing","t"
"FoundInGh","otto-communication-service","x","x","x","x","x","x","x","x","x","x","x","Otto - Leasing","t"
"FoundInGh","otto-resident-automation-service","x","x","x","x","x","x","x","x","x","x","x","Otto - Resident Experience","t"
"FoundInGh","otto-service-requests-service","x","x","x","x","x","x","x","x","x","x","x","Otto - Property Services","t"
"FoundInGh","otto-document-templates","x","x","x","x","x","x","x","x","x","x","x","Otto - Shared","t"
"FoundInGh","otto-message-templates","x","x","x","x","x","x","x","x","x","x","x","Otto - Shared","t"
"FoundInGh","otto-web-core","x","x","x","x","x","x","x","x","x","x","x","Otto - Shared","t"
"FoundInGh","otto-business-process-service","x","x","x","x","x","x","x","x","x","x","x","Otto - Core","t"
CSV
  for repo in otto-leases-service otto-prospects-service otto-communication-service \
              otto-resident-automation-service otto-service-requests-service \
              otto-document-templates otto-message-templates otto-web-core services-contracts; do
    run pod_allowed "$repo"
    [ "$status" -eq 0 ] || { echo "REGRESSION: $repo would be skipped: $output"; return 1; }
  done
  run pod_allowed otto-business-process-service
  [ "$status" -eq 1 ]
  [[ "$output" == *"Otto - Core"* ]]
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
