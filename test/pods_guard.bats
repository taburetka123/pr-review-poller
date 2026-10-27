load test_helper

# Author gate, second half: an outside author passes only when the repo's Pod
# in engineering-pods config/repositories-config.csv is one of the team's pods.
# The fixture keeps Pod as field 14 of 16 so $14 is never $NF by accident.

setup() {
  source_script
  PODS_CSV_FILE="$BATS_TEST_TMPDIR/pods.csv"
  write_pods_fixture "$PODS_CSV_FILE"
}

write_pods_fixture() {
  cat > "$1" <<'CSV'
"GhStatus","Repository","c3","c4","c5","c6","c7","c8","c9","c10","c11","c12","c13","Pod","c15","c16"
"FoundInGh","otto-leases-service","3","4","5","6","7","8","9","10","11","12","13","Otto - Leasing","15","16"
"FoundInGh","otto-case-management-service","3","4","5","6","7","8","9","10","11","12","13","Otto - Resident Experience","15","16"
"FoundInGh","otto-business-process-service","3","4","5","6","7","8","9","10","11","12","13","Otto - Core","15","16"
"FoundInGh","otto-document-templates","3","4","5","6","7","8","9","10","11","12","13","Otto - Shared","15","16"
"FoundInGh","terraform-messaging","3","4","5","6","7","8","9","10","11","12","13","DevOps","15","16"
"FoundInGh","otto-csat-service","3","4","5","6","7","8","9","10","11","12","13","Otto - Property Services","15","16"
"FoundInGh","services-contracts","3","4","5","6","7","8","9","10","11","12","13","","15","16"
"FoundInGh","otto-fake-service","3","4","5","6","7","8","9","10","11","12","13","Otto - Leasing And More","15","16"
CSV
}

@test "a repo in Otto - Leasing is a team pod" {
  run repo_pod_ours otto-leases-service
  [ "$status" -eq 0 ]
  [ "$output" = "pod Otto - Leasing (team pod)" ]
}

@test "a repo in Otto - Resident Experience is a team pod" {
  run repo_pod_ours otto-case-management-service
  [ "$status" -eq 0 ]
}

@test "Otto - Shared is not a team pod, and the pod is named" {
  run repo_pod_ours otto-document-templates
  [ "$status" -eq 1 ]
  [ "$output" = "pod 'Otto - Shared' is not a team pod" ]
}

@test "DevOps is not a team pod" {
  run repo_pod_ours terraform-messaging
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a team pod"* ]]
}

@test "Otto - Core is not a team pod" {
  run repo_pod_ours otto-business-process-service
  [ "$status" -eq 1 ]
}

@test "Otto - Property Services is not a team pod" {
  run repo_pod_ours otto-csat-service
  [ "$status" -eq 1 ]
}

@test "an EMPTY pod cell (services-contracts) refuses outside authors" {
  run repo_pod_ours services-contracts
  [ "$status" -eq 1 ]
  [[ "$output" == *"pod cell EMPTY"* ]]
  [[ "$output" != *"ABSENT"* ]]
}

@test "a repo ABSENT from the map is refused with a distinct reason" {
  run repo_pod_ours otto-unknown-service
  [ "$status" -eq 1 ]
  [[ "$output" == *"ABSENT from the pods map"* ]]
}

@test "a missing map refuses with 'unavailable'" {
  PODS_CSV_FILE="$BATS_TEST_TMPDIR/nope.csv"
  run repo_pod_ours otto-leases-service
  [ "$status" -eq 1 ]
  [[ "$output" == *"pods map unavailable"* ]]
}

@test "the pod match is exact, not substring" {
  run repo_pod_ours otto-fake-service
  [ "$status" -eq 1 ]
}

@test "a header without Pod in field 14 fails the pods gate" {
  printf '"a","Repository","c","Pod"\n' > "$PODS_CSV_FILE"
  run check_pods_header
  [ "$status" -eq 1 ]
  [[ "$output" == *"unexpected header"* ]]
}

@test "a header with Pod as the last of 14 fields still passes" {
  printf '"a","Repository","3","4","5","6","7","8","9","10","11","12","13","Pod"\n' > "$PODS_CSV_FILE"
  run check_pods_header
  [ "$status" -eq 0 ]
}

@test "the fixture header passes the pods gate" {
  run check_pods_header
  [ "$status" -eq 0 ]
}

@test "a missing map fails the pods gate with 'unavailable'" {
  PODS_CSV_FILE="$BATS_TEST_TMPDIR/nope.csv"
  run check_pods_header
  [ "$status" -eq 1 ]
  [[ "$output" == *"pods map unavailable"* ]]
}

@test "PR_REVIEW_PODS_CSV from the environment at script start overrides the fetch" {
  PODS_CSV_FILE="$BATS_TEST_TMPDIR/other.csv"
  PODS_CSV_OVERRIDE="$BATS_TEST_TMPDIR/pods.csv"
  resolve_pods_csv
  [ "$PODS_CSV_FILE" = "$BATS_TEST_TMPDIR/pods.csv" ]
}

@test "PR_REVIEW_PODS_CSV set after script start is ignored" {
  PODS_CSV_FILE="$BATS_TEST_TMPDIR/other.csv"
  PODS_CSV_OVERRIDE=""
  export HOME="$BATS_TEST_TMPDIR/home"
  STATE_DIR="$BATS_TEST_TMPDIR/state"
  PR_REVIEW_PODS_CSV="$BATS_TEST_TMPDIR/pods.csv" resolve_pods_csv
  [ "$PODS_CSV_FILE" != "$BATS_TEST_TMPDIR/pods.csv" ]
}
