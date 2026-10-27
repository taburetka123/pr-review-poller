# pr-review-poller

Background launchd job that runs `claude -p "/kezoo-review-prs --auto"` on a timer so PRs by the roster, and by any author in the team's pod repos, get reviewed without you at the keyboard.

Pairs with the `--auto` mode on the personal `/kezoo-review-prs` skill — which posts every finding the reviewer did not dispute, and approves when none is blocker or major.

## What auto mode does per PR

Four possible actions:

- **POST** — leave each finding as a **standalone inline PR comment** (not wrapped in a review submission) so the timeline gets per-comment "commented on" entries instead of a "reviewed changes" block. Every body ends with a hidden `<!-- kezoo-review -->` marker, which the hold check reads to skip the poller's own comments. Used when the post set holds a blocker or major; every finding in the post set posts, at any severity and confidence. A POST also sends the review to your Slack channel.
- **HOLD** — submit no review. Record the PR in a local ledger (`~/.local/state/pr-review-poller/held.json`) and DM yourself on Slack with the full review so you can decide. The PR is skipped on subsequent polls (until new commits) so you aren't spammed. A HOLD for a prior-reviewer concern or a disputed finding still posts its post set. The hold reason never goes to GitHub.
- **POST + APPROVE** — when the post set holds only minor and nit findings: one `APPROVE` review on the reviewed commit that carries the line comments inside it and any file-level or out-of-diff finding in its body, which then ends with the hidden marker. All of it lands or none of it does; a rejected call is a HOLD.
- **APPROVE** — submit an `APPROVE` review with an empty body when there is nothing to post. No text, no noise.

GitHub drops a requested team once a member reviews, so a posted comment removes your team from the PR. After the triage, and on later ticks until it settles, the poller re-requests review from that team (`~/.local/state/pr-review-poller/team-requests.json`). It re-requests nothing after an APPROVE.

## Safety gates

Seven layered checks prevent duplicate reviews, mid-push reviews, reviews of other teams' PRs, and beating humans to the draw. **All seven run in the shell script before Claude is invoked** — on a tick where every PR is filtered out (the common case), no Claude session starts at all, so empty ticks cost nothing:

1. **Single-flight lock** — PID file at `~/.local/state/pr-review-poller.lock`. If a previous poll is still running, the new one exits; stale locks (process gone) are reclaimed.
2. **Last-review-commit dedup** — the skill's Phase 1 skips any PR where your last review was on the current head commit. Re-review runs only when the head has moved.
3. **Already-approved skip** — if any reviewer's latest review state is `APPROVED`, the skill skips the PR in auto mode. No piling on with comments after someone greenlit it.
4. **Commit-age gate** — a PR is only reviewed once its newest commit is ≥ `MIN_COMMIT_AGE` old (default 10 min). Gives humans a lead window and avoids reviewing mid-push.
5. **Held-ledger skip** — a PR currently marked HOLD at the current HEAD is skipped. When new commits land (HEAD moves), the entry goes stale and the PR is re-evaluated.
6. **Author gate** — a roster author is admitted wherever your login is a code owner. Any other author is admitted only when the repo's `Pod` in engineering-pods `config/repositories-config.csv` is `Otto - Leasing` or `Otto - Resident Experience` (the set follows the team the `roofstock-environment.md` project rule names). An empty pod, a repo with no row, or no map skips the PR with the reason in the log; when the map is unavailable the tick warns and goes on with the roster.
7. **Reviewed-by search** — a second search, `--reviewed-by=@me`, finds PRs whose approve a push dismissed (GitHub does not restore the review request). From it the poller takes only PRs with a record in `~/.local/state/pr-review-poller/reviewed.json`, written when the poller admits a PR; such a PR is reviewed again at its new head. Before the first tick that writes the record there is nothing to find: re-trigger an already dismissed PR by hand with `run --force` after re-requesting the review. A PR the poller admitted and you then reviewed by hand returns to the poller after the next push. A record that cannot be written is a `poll FAILED`, retried on the next hourly tick.

- `INFLIGHT_TTL` (default `1h`): how long an `[in-flight]` placeholder may persist
  before a new run treats it as orphaned (from a crashed/interrupted run) and
  re-reviews the PR. Real holds (findings verdicts) are unaffected.

The frequency gate is stamped with the tick's start time only after `poll done`; it passes 300 s early. A `poll FAILED` tick leaves no stamp, releases its own `[in-flight]` entries and shows a macOS notification, so the next hourly tick retries.

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
pr-review-poller start --no-post   # begin polling, never post (any later start with flags drops it)
pr-review-poller stop         # pause polling (launchctl unload)
pr-review-poller run          # run one cycle right now (headless, respects lock)
pr-review-poller run --head   # debug of the skill only; with no PR URLs the triage reviews nothing
pr-review-poller logs         # tail -F the stdout log
pr-review-poller config       # print the config file
pr-review-poller help
```

Ad-hoc override:

```
pr-review-poller run --min-commit-age 0   # disable age gate for this single run
pr-review-poller run --force              # bypass the frequency gate for this single run
pr-review-poller run --no-post            # do not post this run: POST decisions become HOLD,
                                          # APPROVE still approves. Default posts, except --verify and --head
```

## Uninstall

```
./uninstall.sh
```

Removes the plist, symlink, config, and lock file. Leaves the logs for post-mortem.
