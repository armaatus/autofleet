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
3. **Briefs the agent** from the issue body itself — build it test-first, open a
   PR with a closing line, and stop there. Everything after that is the
   dispatcher's: it arms auto-merge, runs **one** review, buys **one** fix
   session if that review asks for changes, re-reviews the fix once, and then
   either GitHub merges or a person is told why not.
4. **Gates the merge.** `merge-gate` is a required check that fails closed, and
   it asks three things: a `Closes #N` line, a change that does not touch the
   enforcement layer, and a review of the current head that said approve. CI
   green, every thread resolved and an approval dismissed on a push are branch
   protection, which `install.sh` sets. `unblock.yml` then re-derives
   the `blocked`/`ready` labels so the next issue becomes startable — on a merged
   pull request, and on an issue `opened`, `edited`, `closed` or `reopened`,
   because an issue filed with no blockers carries no label at all until one of
   those fires and the dispatcher starts nothing without `ready`.
5. **Reclaims the worktree** only when nothing goes with it: the PR merged and
   the tree is clean, or the issue can no longer produce a merged PR at all.

Afterwards — when you want to know what that cost — `./scripts/fleet/fleet.sh
cost` reports input, output, cache-read and cache-write tokens per issue, plus
how many sessions ran there, from the agent CLI's own transcripts. It is a
command you type, not something the loop above does: the four figures are
printed separately and never summed, because a cache read is roughly a tenth of
an input token and a run that looks expensive on `input` may be almost entirely
cache. `--json` for comparing runs to each other.

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
| `orca.yaml` | Orca's own hooks, for worktrees a person opens by hand. Optional. |

Nothing in `scripts/fleet/` knows about your project. See
[docs/CONFIGURATION.md](docs/CONFIGURATION.md).

## What it needs

- **GitHub**, with `gh` authenticated, and `merge-gate` set as a required check.
- **Claude Code**, for the agents, the review and the one fix answering it.
- **Nothing else.** A build is one `claude -p` in a plain `git worktree`, so
  the fleet runs on any machine with `git`, `gh` and `claude`.
  **[Orca](https://orca.computer)** is optional and runs the identical build in
  a terminal you can watch; that dependency is named rather than hidden, and
  everything Orca-specific is in `scripts/fleet/runner/` behind a driver seam —
  see [docs/RUNNERS.md](docs/RUNNERS.md).
- **macOS or Linux**, bash and Python 3.10+. No build, no dependencies.

## Where it came from

autofleet was extracted from [armaatus/rommsync-nx](https://github.com/armaatus/rommsync-nx),
where it ran three parallel agents against a C++ backlog for weeks. Comments
throughout cite that repo's issues (`armaatus/rommsync-nx#163`) because most of
these rules exist because something failed once, and the failure is the only
thing that makes the rule readable a year later.

## Docs

- [docs/WORKFLOW.md](docs/WORKFLOW.md) — the loop, why each rule of it exists,
  and what it cost to learn. The maintainer's page, read once; an agent's own
  instructions are the brief `scripts/fleet/issue-command.sh` prints.
- [docs/CONFIGURATION.md](docs/CONFIGURATION.md) — every knob, and what it costs.
- [docs/RUNNERS.md](docs/RUNNERS.md) — the driver contract.
- [REVIEW.md](REVIEW.md) — the review policy, and what makes a finding block.
- The review runs on your machine, started by the dispatcher, in a context that
  has not seen the conversation which produced the diff —
  [CONFIGURATION.md](docs/CONFIGURATION.md#the-review) for what that trades
  away.
- [CLAUDE.md](CLAUDE.md) — the working agreement for contributing here.

MIT.
