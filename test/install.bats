setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/bash\necho "$*" >> "%s/launchctl.log"\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/launchctl"
  chmod +x "$BATS_TEST_TMPDIR/bin/launchctl"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  INSTALL="$BATS_TEST_DIRNAME/../install.sh"
  CONFIG="$HOME/.config/pr-review-poller/config.env"
}

seed_config() {
  mkdir -p "$(dirname "$CONFIG")"
  printf 'MIN_COMMIT_AGE="40m"\nREVIEW_FREQUENCY="2h"\n# keep me\nALLOWED_EXTRA_REPOS="services-contracts"\n' > "$CONFIG"
}

@test "install without flags leaves an existing config.env byte-identical" {
  seed_config
  cp "$CONFIG" "$BATS_TEST_TMPDIR/before"
  run "$INSTALL"
  [ "$status" -eq 0 ]
  cmp "$CONFIG" "$BATS_TEST_TMPDIR/before"
}

@test "install --min-commit-age rewrites only that key" {
  seed_config
  run "$INSTALL" --min-commit-age 15m
  [ "$status" -eq 0 ]
  grep -qx 'MIN_COMMIT_AGE="15m"' "$CONFIG"
  [ "$(grep -c '^MIN_COMMIT_AGE=' "$CONFIG")" -eq 1 ]
  grep -qx 'REVIEW_FREQUENCY="2h"' "$CONFIG"
  grep -qx '# keep me' "$CONFIG"
  grep -qx 'ALLOWED_EXTRA_REPOS="services-contracts"' "$CONFIG"
}

@test "install --frequency appends the key when config.env lacks it" {
  mkdir -p "$(dirname "$CONFIG")"
  printf 'MIN_COMMIT_AGE="40m"\n' > "$CONFIG"
  run "$INSTALL" --frequency 3h
  [ "$status" -eq 0 ]
  grep -qx 'MIN_COMMIT_AGE="40m"' "$CONFIG"
  grep -qx 'REVIEW_FREQUENCY="3h"' "$CONFIG"
}

@test "install with no config.env writes the defaults" {
  run "$INSTALL"
  [ "$status" -eq 0 ]
  grep -qx 'MIN_COMMIT_AGE="10m"' "$CONFIG"
  grep -qx 'REVIEW_FREQUENCY="2h"' "$CONFIG"
}

@test "install rejects an empty flag value and leaves config.env untouched" {
  seed_config
  cp "$CONFIG" "$BATS_TEST_TMPDIR/before"
  run "$INSTALL" --min-commit-age ""
  [ "$status" -eq 2 ]
  [[ "$output" == *"--min-commit-age needs a non-empty value"* ]]
  cmp "$CONFIG" "$BATS_TEST_TMPDIR/before"
  run "$INSTALL" --frequency
  [ "$status" -eq 2 ]
  [[ "$output" == *"--frequency needs a non-empty value"* ]]
  cmp "$CONFIG" "$BATS_TEST_TMPDIR/before"
}
