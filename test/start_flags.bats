load test_helper

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/Library/LaunchAgents" "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/bash\necho "$*" >> "%s/launchctl.log"\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/launchctl"
  chmod +x "$BATS_TEST_TMPDIR/bin/launchctl"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  PLIST="$HOME/Library/LaunchAgents/com.kezoo.pr-review-poller.plist"
  cp "$BATS_TEST_DIRNAME/../launchd/com.kezoo.pr-review-poller.plist.tmpl" "$PLIST"
}

job_args() {
  plutil -extract ProgramArguments json -o - "$PLIST" | jq -c '.[1:]'
}

@test "start --no-post bakes the opt-out into the plist" {
  run "$SCRIPT_UNDER_TEST" start --no-post
  [ "$status" -eq 0 ]
  [ "$(job_args)" = '["run","--no-post"]' ]
}
