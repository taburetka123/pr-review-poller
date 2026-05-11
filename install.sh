#!/usr/bin/env bash
# Install / re-install the pr-review-poller launchd job.
# Idempotent: re-run to change interval or commit-age.
set -euo pipefail

MIN_COMMIT_AGE="10m"
REVIEW_FREQUENCY="2h"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --min-commit-age) MIN_COMMIT_AGE="$2"; shift 2 ;;
    --frequency)      REVIEW_FREQUENCY="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
Usage: ./install.sh [--min-commit-age DURATION] [--frequency DURATION]

  --min-commit-age DUR   Minimum age of the newest commit before auto-review
                         fires. 10m, 1h, etc. 0 disables. Default 10m.

  --frequency DUR        Minimum gap between review runs. The launchd job
                         fires hourly; ticks that arrive sooner than DUR
                         since the last run are skipped. 1h, 2h, etc.
                         Default 2h.

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

cat > "$CONFIG_DIR/config.env" <<EOF
MIN_COMMIT_AGE="$MIN_COMMIT_AGE"
REVIEW_FREQUENCY="$REVIEW_FREQUENCY"
EOF

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
echo "  frequency gate:  $REVIEW_FREQUENCY"
echo "  min-commit-age:  $MIN_COMMIT_AGE"
echo "  bin:             $BIN_DST"
echo "  plist:           $PLIST_DST"
echo "  config:          $CONFIG_DIR/config.env"
echo "  logs:            ~/worktrees/.pr-review-poller-{stdout,stderr}.log"
echo "  status:          $RELOAD_MSG"
