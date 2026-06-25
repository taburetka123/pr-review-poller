# pr-review-poller

Background launchd job that runs `claude -p "/kezoo-review-prs --auto"` on a timer so teammate PRs get reviewed without you at the keyboard.

Pairs with the `--auto` mode on the personal `/kezoo-review-prs` skill — which only posts confidence-5 blocker/major findings, approves otherwise, and silently drops everything else.

## What auto mode does per PR

Three possible actions:

- **POST** — leave each finding as a **standalone inline PR comment** (not wrapped in a review submission) so the timeline gets per-comment "commented on" entries instead of a "reviewed changes" block. Every body is footer-tagged `*Automated review*` so humans can tell the source. Only used when a `blocker` or `major` finding clears the author's post threshold (see trust matrix in the `/kezoo-review-prs` skill).
- **HOLD** — don't touch GitHub. Record the PR in a local ledger (`~/.local/state/pr-review-poller/held.json`) and DM yourself on Slack with the full review so you can decide. The PR is skipped on subsequent polls (until new commits) so you aren't spammed.
- **APPROVE** — submit an `APPROVE` review with an empty body. No text, no noise.

Trust is per-author and expressed as the **maximum PR complexity (1–5) we'll let the bot act on without a human**. The reviewing subagent rates each PR's complexity 1–5; if `complexity > author trust`, the action is HOLD — no findings are examined for the auto-action, the PR just goes to a Slack DM for human review. The complexity gate is a prerequisite for any auto-action, not just approval: only once it passes do we look at findings and decide POST (`blocker`/`major` at confidence 5) vs APPROVE. Full matrix lives in the `/kezoo-review-prs` skill.

## Safety gates

Five layered checks prevent duplicate reviews, mid-push reviews, and beating humans to the draw. **All five run in the shell script before Claude is invoked** — on a tick where every PR is filtered out (the common case), no Claude session starts at all, so empty ticks cost nothing:

1. **Single-flight lock** — PID file at `~/.local/state/pr-review-poller.lock`. If a previous poll is still running, the new one exits; stale locks (process gone) are reclaimed.
2. **Last-review-commit dedup** — the skill's Phase 1 skips any PR where your last review was on the current head commit. Re-review runs only when the head has moved.
3. **Already-approved skip** — if any reviewer's latest review state is `APPROVED`, the skill skips the PR in auto mode. No piling on with comments after someone greenlit it.
4. **Commit-age gate** — a PR is only reviewed once its newest commit is ≥ `MIN_COMMIT_AGE` old (default 10 min). Gives humans a lead window and avoids reviewing mid-push.
5. **Held-ledger skip** — a PR currently marked HOLD at the current HEAD is skipped. When new commits land (HEAD moves), the entry goes stale and the PR is re-evaluated.

- `INFLIGHT_TTL` (default `1h`): how long an `[in-flight]` placeholder may persist
  before a new run treats it as orphaned (from a crashed/interrupted run) and
  re-reviews the PR. Real holds (findings/complexity verdicts) are unaffected.

## Install

```
./install.sh                                         # defaults: hourly trigger, 2h frequency gate, 10m commit-age gate
./install.sh --frequency 4h --min-commit-age 5m      # custom
```

`launchd` fires the job hourly at minute 0 (`StartCalendarInterval`). If the Mac was asleep, one coalesced tick fires immediately on wake. A tick that arrives sooner than `--frequency` since the previous run is skipped in the shell before any work happens, so the effective cadence is "every N hours, plus one catch-up tick on wake from sleep".

Re-run any time to change settings. `install.sh` renders the plist and config but does NOT start polling — use `pr-review-poller start` when you're ready.

Installed artifacts:
- bin: `~/.local/bin/pr-review-poller` (symlink → repo)
- plist: `~/Library/LaunchAgents/com.kezoo.pr-review-poller.plist`
- config: `~/.config/pr-review-poller/config.env`
- logs: `~/worktrees/.pr-review-poller-{stdout,stderr}.log`

## Day-to-day

```
pr-review-poller              # status — is it running? schedule? last run? config?
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
pr-review-poller run --force              # bypass the frequency gate for this single run
pr-review-poller run --post               # allow posting. Default is no-post:
                                          # POST decisions become HOLD, APPROVE still approves
```

## Uninstall

```
./uninstall.sh
```

Removes the plist, symlink, config, and lock file. Leaves the logs for post-mortem.
