#!/usr/bin/env bash
# Install / re-install the pr-review-poller launchd job.
# Idempotent: re-run to change interval or commit-age.
set -euo pipefail

MIN_COMMIT_AGE=""
REVIEW_FREQUENCY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --min-commit-age) MIN_COMMIT_AGE="$2"; shift 2 ;;
    --frequency)      REVIEW_FREQUENCY="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
Usage: ./install.sh [--min-commit-age DURATION] [--frequency DURATION]

  --min-commit-age DUR   Minimum age of the newest commit before auto-review
                         fires. 10m, 1h, etc. 0 disables. Default 10m for a new config.env; an existing file keeps its value unless this flag is given.

  --frequency DUR        Minimum gap between review runs. The launchd job
                         fires hourly; ticks that arrive sooner than DUR
                         since the last run are skipped. 1h, 2h, etc.
                         Default 2h for a new config.env; an existing file keeps its value unless this flag is given.

The launchd job fires every hour at minute 0 (StartCalendarInterval). If the
Mac was asleep, one coalesced tick fires on wake — the frequency gate decides
whether that tick actually runs.
EOF
      exit 0
      ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
PLIST_DST="$HOME/Library/LaunchAgents/com.kezoo.pr-review-poller.plist"
BIN_DST="$HOME/.local/bin/pr-review-poller"
CONFIG_DIR="$HOME/.config/pr-review-poller"

mkdir -p "$(dirname "$BIN_DST")" "$CONFIG_DIR" "$HOME/worktrees" \
  "$HOME/Library/LaunchAgents"

ln -sfn "$REPO_DIR/bin/pr-review-poller" "$BIN_DST"

CONFIG="$CONFIG_DIR/config.env"
set_key() {
  local tmp="$CONFIG.tmp.$$"
  if grep -q "^$1=" "$CONFIG"; then
    awk -v k="$1" -v v="$2" 'index($0, k "=") == 1 { print k "=\"" v "\""; next } { print }' "$CONFIG" > "$tmp"
    mv "$tmp" "$CONFIG"
  else
    printf '%s="%s"\n' "$1" "$2" >> "$CONFIG"
  fi
}
if [[ ! -f "$CONFIG" ]]; then
  printf 'MIN_COMMIT_AGE="%s"\nREVIEW_FREQUENCY="%s"\n' "${MIN_COMMIT_AGE:-10m}" "${REVIEW_FREQUENCY:-2h}" > "$CONFIG"
else
  if [[ -n "$MIN_COMMIT_AGE" ]]; then set_key MIN_COMMIT_AGE "$MIN_COMMIT_AGE"; fi
  if [[ -n "$REVIEW_FREQUENCY" ]]; then set_key REVIEW_FREQUENCY "$REVIEW_FREQUENCY"; fi
fi

cp "$REPO_DIR/launchd/com.kezoo.pr-review-poller.plist.tmpl" "$PLIST_DST"

# If the job was already loaded, reload it so the new plist takes effect.
# Otherwise leave it unloaded — the user runs `pr-review-poller start` when ready.
if launchctl list | awk '{print $3}' | grep -qx "com.kezoo.pr-review-poller"; then
  launchctl unload "$PLIST_DST" 2>/dev/null || true
  launchctl load   "$PLIST_DST"
  RELOAD_MSG="reloaded (was already running)"
else
  RELOAD_MSG="not loaded — run 'pr-review-poller start' to begin polling"
fi

echo "Installed."
echo "  schedule:        hourly at minute 0 (StartCalendarInterval)"
echo "  frequency gate:  $(grep '^REVIEW_FREQUENCY=' "$CONFIG" || echo 'default 2h')"
echo "  min-commit-age:  $(grep '^MIN_COMMIT_AGE=' "$CONFIG" || echo 'default 40m')"
echo "  bin:             $BIN_DST"
echo "  plist:           $PLIST_DST"
echo "  config:          $CONFIG_DIR/config.env"
echo "  logs:            ~/worktrees/.pr-review-poller-{stdout,stderr}.log"
echo "  status:          $RELOAD_MSG"
