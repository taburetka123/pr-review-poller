#!/usr/bin/env bash
# Remove the pr-review-poller launchd job and all installed artifacts.
set -euo pipefail

PLIST_DST="$HOME/Library/LaunchAgents/com.kezoo.pr-review-poller.plist"
BIN_DST="$HOME/.local/bin/pr-review-poller"
CONFIG_DIR="$HOME/.config/pr-review-poller"
LOCK_FILE="$HOME/.local/state/pr-review-poller.lock"

launchctl unload "$PLIST_DST" 2>/dev/null || true
rm -f "$PLIST_DST" "$BIN_DST" "$LOCK_FILE"
rm -rf "$CONFIG_DIR"

echo "Uninstalled pr-review-poller."
echo "Logs at ~/worktrees/.pr-review-poller-*.log are kept; delete manually if you want."
