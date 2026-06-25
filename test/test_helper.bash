# Locate and source bin/pr-review-poller for unit tests. The script's CLI
# dispatcher is guarded by [[ "${BASH_SOURCE[0]}" == "${0}" ]], so sourcing it
# defines the functions without running any subcommand.
SCRIPT_UNDER_TEST="${BATS_TEST_DIRNAME}/../bin/pr-review-poller"

source_script() {
  # shellcheck disable=SC1090
  source "$SCRIPT_UNDER_TEST"
}
