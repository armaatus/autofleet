# autofleet

A fleet of coding agents that turns a GitHub backlog into merged pull requests,
unattended.

A deterministic shell dispatcher decides *which* issue gets a worktree and
*when*. An agent works each issue to a pull request. The **rules** — a merge
gate, a guard hook, an independent review — decide whether that PR merges. No
model runs in the dispatcher, and no agent merges its own work.

```bash
./scripts/fleet/fleet.sh run 11 12 13    # work exactly these, then hand off
./scripts/fleet/fleet.sh run --auto      # keep taking `ready` issues
./scripts/fleet/fleet.sh run --auto --until 08:00 --max-prs 5
./scripts/fleet/fleet.sh status          # what is running, what is next
./scripts/fleet/fleet.sh stop [--now]    # drain, or freeze
```

## What it actually does

1. **Picks.** Anything labelled `ready` and not already in flight, ordered by how
   many open issues name it in a `Blocked by #N` line — the work that frees the
   most other work goes first, and anything labelled `priority` ahead of that.
   `blocked`, `needs-human-step` and foundation issues are handled by rules, not
   by judgement.
2. **Opens a worktree** with its own isolated identity: a derived project name, a
   derived block of ports, its own `.env`. Your project's setup hook provisions
   whatever else it needs, and the agent's tab is held until that finishes.
3. **Briefs the agent** from the issue body itself — plan, build test-first,
   review its own branch, open a PR with a closing line, arm auto-merge, answer
   the independent review.
4. **Gates the merge.** `merge-gate` is a required check that fails closed: no
   local review recorded, no independent review, an unanswered finding, an
   unresolved thread, no `Closes #N` — no merge. `unblock.yml` then re-derives
   the `blocked`/`ready` labels so the next issue becomes startable — on a merged
   pull request, and on an issue `opened`, `edited`, `closed` or `reopened`,
   because an issue filed with no blockers carries no label at all until one of
   those fires and the dispatcher starts nothing without `ready`.
5. **Reclaims the worktree** only when nothing goes with it: the PR merged and
   the tree is clean, or the issue can no longer produce a merged PR at all.

Two files stop it, and they live outside every worktree because the case you
most need a stop in is the one where something is unhealthy. `DRAIN` means start
nothing new. `STOP` means nothing goes out — no push, no PR, no comment, from any
agent, whether or not it has read the news.

## Install

```bash
git clone https://github.com/armaatus/autofleet
./autofleet/install.sh /path/to/your-repo
```

The payload is **vendored**: it lands in your repo and is committed there. Every
piece of it is something a reviewer has to read in the diff of the repo it
governs, and something CI has to run without autofleet checked out anywhere.
Upgrades are a re-run and a diff, not a version bump.

Then tell it about your project — the four files the installer seeds:

| File | What you put in it |
|---|---|
| `.autofleet/config` | Ports, compose file, test command, labels, concurrency. |
| `.autofleet/setup.sh` | What a fresh worktree needs before work can start. |
| `.autofleet/guard.json` | Paths and secrets the guard hook must refuse to write. |
| `orca.yaml` | The runner's own hooks. Already wired; edit the tabs. |

Nothing in `scripts/fleet/` knows about your project. See
[docs/CONFIGURATION.md](docs/CONFIGURATION.md).

## What it needs

- **GitHub**, with `gh` authenticated, and `merge-gate` set as a required check.
- **Claude Code**, for the agents themselves and for `claude-review.yml`.
- **[Orca](https://orca.computer)**, today, for worktrees and terminals. That
  dependency is named rather than hidden: everything Orca-specific is in
  `scripts/fleet/runner/`, behind a driver seam. A tmux/plain-`git worktree`
  driver is the backlog's first real feature — see
  [docs/RUNNERS.md](docs/RUNNERS.md).
- **macOS or Linux**, bash and Python 3.10+. No build, no dependencies.

## Where it came from

autofleet was extracted from [armaatus/rommsync-nx](https://github.com/armaatus/rommsync-nx),
where it ran three parallel agents against a C++ backlog for weeks. Comments
throughout cite that repo's issues (`armaatus/rommsync-nx#163`) because most of
these rules exist because something failed once, and the failure is the only
thing that makes the rule readable a year later.

## Docs

- [docs/WORKFLOW.md](docs/WORKFLOW.md) — the loop an agent runs inside a worktree.
- [docs/CONFIGURATION.md](docs/CONFIGURATION.md) — every knob, and what it costs.
- [docs/RUNNERS.md](docs/RUNNERS.md) — the driver contract.
- [REVIEW.md](REVIEW.md) — the review policy `/code-review` and the workflow follow.
- The independent review runs in GitHub Actions by default and needs a
  `CLAUDE_CODE_OAUTH_TOKEN` secret. Without one, set
  `AUTOFLEET_REVIEW_MODE=local` and the dispatcher runs it on your machine
  instead — [CONFIGURATION.md](docs/CONFIGURATION.md#the-review) for what that
  trades away.
- [CLAUDE.md](CLAUDE.md) — the working agreement for contributing here.

MIT.
