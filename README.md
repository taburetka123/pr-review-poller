# pr-review-poller

Background launchd job that runs `claude -p "/review-prs --auto"` on a timer so teammate PRs get reviewed without you at the keyboard.

Pairs with the `--auto` mode on the personal `/review-prs` skill — which only posts confidence-5 blocker/major findings, approves otherwise, and silently drops everything else.

## Safety gates

Four layered checks prevent duplicate reviews, mid-push reviews, and beating humans to the draw:

1. **Single-flight lock** — `flock` on `~/.local/state/pr-review-poller.lock`. If a previous poll is still running, the new one exits.
2. **Last-review-commit dedup** — the skill's Phase 1 skips any PR where your last review was on the current head commit. Re-review runs only when the head has moved.
3. **Already-approved skip** — if any reviewer's latest review state is `APPROVED`, the skill skips the PR in auto mode. No piling on with comments after someone greenlit it.
4. **Commit-age gate** — a PR is only reviewed once its newest commit is ≥ `MIN_COMMIT_AGE` old (default 10 min). Gives humans a lead window and avoids reviewing mid-push.

## Install

```
./install.sh                                   # defaults: 10m interval, 10m commit-age gate
./install.sh --interval 300 --min-commit-age 5m
```

Re-run `install.sh` any time to change settings; it unloads and reloads the launchd agent.

After install:

- bin: `~/.local/bin/pr-review-poller` (symlink → repo)
- plist: `~/Library/LaunchAgents/com.kezoo.pr-review-poller.plist`
- config: `~/.config/pr-review-poller/config.env`
- logs: `~/worktrees/.pr-review-poller-{stdout,stderr}.log`

## Debug run (visible)

```
pr-review-poller --head
```

Opens a new iTerm2 tab and runs the review there. No lock (user-invoked). Useful for watching what `/review-prs --auto` actually does on real PRs.

## Ad-hoc override

```
pr-review-poller --min-commit-age 0   # disable age gate for this run
```

## Uninstall

```
./uninstall.sh
```

Removes the plist, symlink, config, and lock file. Leaves the logs.
