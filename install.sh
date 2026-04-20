#!/usr/bin/env bash
# Install / re-install the pr-review-poller launchd job.
# Idempotent: re-run to change interval or commit-age.
set -euo pipefail

INTERVAL_SECONDS=600
MIN_COMMIT_AGE="10m"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval) INTERVAL_SECONDS="$2"; shift 2 ;;
    --min-commit-age) MIN_COMMIT_AGE="$2"; shift 2 ;;
    -h|--help)
      cat <<EOF
Usage: ./install.sh [--interval SECONDS] [--min-commit-age DURATION]

  --interval SECONDS     launchd poll interval. Default 600 (10 min).
                         Re-run to change.
  --min-commit-age DUR   Minimum age of the newest commit before auto-review
                         fires. 10m, 1h, etc. 0 disables. Default 10m.
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
EOF

sed "s|{{INTERVAL_SECONDS}}|$INTERVAL_SECONDS|g" \
  "$REPO_DIR/launchd/com.kezoo.pr-review-poller.plist.tmpl" > "$PLIST_DST"

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
echo "  interval:        ${INTERVAL_SECONDS}s"
echo "  min-commit-age:  $MIN_COMMIT_AGE"
echo "  bin:             $BIN_DST"
echo "  plist:           $PLIST_DST"
echo "  config:          $CONFIG_DIR/config.env"
echo "  logs:            ~/worktrees/.pr-review-poller-{stdout,stderr}.log"
echo "  status:          $RELOAD_MSG"
