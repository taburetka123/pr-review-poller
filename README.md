# pr-review-poller

Background launchd job that runs `claude -p "/kezoo-review-prs --auto"` on a timer so teammate PRs get reviewed without you at the keyboard.

Pairs with the `--auto` mode on the personal `/kezoo-review-prs` skill — which only posts confidence-5 blocker/major findings, approves otherwise, and silently drops everything else.

## What auto mode does per PR

Three possible actions:

- **POST** — leave each finding as a **standalone inline PR comment** (not wrapped in a review submission) so the timeline gets per-comment "commented on" entries instead of a "reviewed changes" block. Every body is footer-tagged `*Automated review*` so humans can tell the source. Only used when a `blocker` or `major` finding clears the author's post threshold (see trust matrix in the `/kezoo-review-prs` skill).
- **HOLD** — don't touch GitHub. Record the PR in a local ledger (`~/.local/state/pr-review-poller/held.json`) and DM yourself on Slack with the full review so you can decide. The PR is skipped on subsequent polls (until new commits) so you aren't spammed.
- **APPROVE** — submit an `APPROVE` review with an empty body. No text, no noise.

Trust is per-author: high-trust teammates never HOLD (only POST or APPROVE); low-trust teammates HOLD on borderline findings instead of auto-approving.

## Safety gates

Five layered checks prevent duplicate reviews, mid-push reviews, and beating humans to the draw:

1. **Single-flight lock** — `flock` on `~/.local/state/pr-review-poller.lock`. If a previous poll is still running, the new one exits.
2. **Last-review-commit dedup** — the skill's Phase 1 skips any PR where your last review was on the current head commit. Re-review runs only when the head has moved.
3. **Already-approved skip** — if any reviewer's latest review state is `APPROVED`, the skill skips the PR in auto mode. No piling on with comments after someone greenlit it.
4. **Commit-age gate** — a PR is only reviewed once its newest commit is ≥ `MIN_COMMIT_AGE` old (default 10 min). Gives humans a lead window and avoids reviewing mid-push.
5. **Held-ledger skip** — a PR currently marked HOLD at the current HEAD is skipped. When new commits land (HEAD moves), the entry goes stale and the PR is re-evaluated.

## Install

```
./install.sh                                         # defaults: 10m interval, 10m commit-age gate
./install.sh --interval 300 --min-commit-age 5m      # custom
```

Re-run any time to change settings. `install.sh` renders the plist and config but does NOT start polling — use `pr-review-poller start` when you're ready.

Installed artifacts:
- bin: `~/.local/bin/pr-review-poller` (symlink → repo)
- plist: `~/Library/LaunchAgents/com.kezoo.pr-review-poller.plist`
- config: `~/.config/pr-review-poller/config.env`
- logs: `~/worktrees/.pr-review-poller-{stdout,stderr}.log`

## Day-to-day

```
pr-review-poller              # status — is it running? interval? last run? config?
pr-review-poller start        # begin polling (launchctl load)
pr-review-poller stop         # pause polling (launchctl unload)
pr-review-poller run          # run one cycle right now (headless, respects lock)
pr-review-poller run --head   # run one cycle in a new iTerm2 tab, no lock (debug)
pr-review-poller logs         # tail -F the stdout log
pr-review-poller config       # print the config file
pr-review-poller help
```

Ad-hoc override:

```
pr-review-poller run --min-commit-age 0   # disable age gate for this single run
pr-review-poller run --no-post            # POST decisions become HOLD for this run
                                          # (APPROVE still approves; nothing posts to GitHub)
```

## Uninstall

```
./uninstall.sh
```

Removes the plist, symlink, config, and lock file. Leaves the logs for post-mortem.
