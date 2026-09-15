# How work happens here

This project is built by agents working in parallel, one per Orca worktree, with
one human deciding what the rules are. **This page is the maintainer's**, read
once and not per issue: it is that loop end to end — what each stage produces,
what starts the next, where a person is required, how to stop the whole thing,
and why each rule is the shape it is. An agent's own instructions are the brief
([`scripts/fleet/issue-command.sh`](../scripts/fleet/issue-command.sh) `<n>`,
then `--after-pr <n>`), with [CLAUDE.md](../CLAUDE.md) the working agreement
above it. `evals/lint.sh` holds what an agent reads before its first edit — those
two and [REVIEW.md](../REVIEW.md), which the brief names at its review step —
under a word ceiling.

An agent comes here for the conventions behind a rule — the `<!-- blockers -->`
marker in [Stage 2](#stage-2--spec) chief among them — and not for what to run.
It used to be told otherwise: the
brief opened by sending the agent here, and the agent that did as it was told
read 13,425 words — CLAUDE.md, the brief, and this page's longer retelling of
the brief — before its first edit, then carried them in the prompt prefix of
every request for the rest of the session
([#54](https://github.com/armaatus/autofleet/issues/54)). Nothing was deleted
here for being long; what changed is who is told to read it. Where this page and
the brief disagree about what to do, the brief is right, and `evals/lint.sh`
keeps this one from growing a second copy of it.

The shape is adapted from Anthropic's
[AI-native SDLC playbook](https://claude.com/blog/the-ai-native-sdlc-playbook).
The idea it turns on: **each stage ends by committing an artifact, and the next
stage begins by reading it.** The chain of commits is the audit trail — who asked
for what, what the agent produced, what approved it. No handoff meetings; only
files.

Three things shape every decision below.

**The machine is free.** This Mac has effectively unlimited time and the fixtures
already on disk, so the heavy work — building, the full suite against a real
the fixture, both review passes — happens locally. GitHub Actions is the independent
second opinion and the gate, and at roughly 5.5 minutes per PR it is not the
scarce resource.

**A PR arrives reviewed, or it does not arrive.** By the time a pull request
exists it has been through `/code-review` and `/mattpocock-skills:code-review`
locally and the findings are in its body. The push is gated on a local marker
and the merge is gated on those findings being in the body — see
[the merge gate](#the-merge-gate).

**Nothing merges on trust.** The agent never merges and never approves. It asks
GitHub to merge, and one required check — [`merge-gate`](#the-merge-gate) —
decides whether that is allowed.

---

## Start it

Run the dispatcher in a terminal the runner opens, so it is as visible as the
work it starts. The exact command is the runner's, so ask the fleet for it
rather than reading one off this page — a host project on a different
`AUTOFLEET_RUNNER` gets a different line:

```bash
./scripts/fleet/fleet.sh          # prints it, under "Run it in a terminal..."
```

If it answers "the runner is not usable here" instead, that IS the answer: the
dispatcher checks the runner before it will do anything, and there is no terminal
for it to open until that is fixed. `docs/RUNNERS.md` says what each driver
needs.

Or directly:

```bash
./scripts/fleet/fleet.sh run 11 12 13              # work exactly these issues
./scripts/fleet/fleet.sh run --auto                # keep taking `ready` issues
./scripts/fleet/fleet.sh run --auto --until 08:00  # ...and stop then
./scripts/fleet/fleet.sh run --auto --for 6h --max-prs 5
./scripts/fleet/fleet.sh status                    # what is running, what is next
./scripts/fleet/stop.sh                            # stop. See below — this always works.
```

`fleet.sh` is deterministic shell. No model runs in it. Its whole job is to decide
*which* issue gets a worktree and *when*.

**What it picks:** anything `ready` and not already in flight, ordered by how many
open issues name it in a `Blocked by #N` line. The work that frees the most other
work goes first, which is the fastest way to turn a mostly-blocked backlog into a
wide one. Milestones do not order it — `ready` already means every blocker is
closed, and a milestone number is not a claim about what can be built *now*.

Ahead of all of it: anything labelled `priority`. The blocker graph says what
*can* start, not what *should* go first, and the only way to say "this one next"
used to be to invent a dependency. A person applies that label; it reorders the
ready list and changes nothing else, so a `blocked` or `needs-human-step` issue
is no more startable for carrying it. `fleet.sh status` marks those rows.

It does not lift a foundation hold, and delaying one costs more than it looks.
A `priority` issue that starts first holds a worktree, and a foundation issue
will not join work already in flight — so the foundation issue waits. But the
scan **stops at the first foundation issue** once anything is in flight, so
every ready issue behind it is skipped for that pass too, including ones that
have nothing to do with it.

Ready list `[#151 priority, #F foundation, #A, #B]`, nothing running: pass one
launches #151; pass two reaches #F, sees a worktree in flight, and stops — #A
and #B are never considered. The fleet runs at **one** worktree for #151's whole
time-box, then at one again while #F lands alone.

Unlabelled, the same backlog — all four; #151 does not vanish when the label
comes off — sorts `[#A, #B, #151, #F]` and fills **three**, with #F waiting on
them. (`[#A, #B, #F]` would fill two, not three: the scan breaks at #F with two
worktrees live, for the same reason this passage is about.)

That order stipulates a foundation issue that frees nothing, which is the worst
case rather than the usual one. The second sort key is how many issues an issue
frees, so an `#F` that even one open `Blocked by #N` line names sorts **first**
unlabelled — `[#F, #A, #B, #151]` — and the fleet is already down to one worktree
while it lands alone, filling three only afterwards. Against that `#F`, which is
the kind the "lands alone" rule exists for, the label buys one *extra* solo
time-box, not the whole gap.

So the question to ask before applying it is not "does this jump the queue" but
"is this worth another time-box at one worktree". If it is not, the foundation
issue is the one to label.

`--auto` never pauses; it stops when the queue empties, at `--until`/`--for`, or
after `--max-prs`, and says which.

`ready` on its own is not enough, incidentally: the label stays until the PR
merges, so `fleet.sh` also excludes any issue that already has an open PR
closing it. It reads that line the way GitHub does — any of the nine closing
keywords, in any case — from
[`.github/scripts/issue_refs.py`](../.github/scripts/issue_refs.py), which is
also where the `Blocked by #N` pattern lives, spelled to match `unblock.yml`.

**What it will not do:** it does not merge, and it never touches a worktree it did
not create.

## Stop it

```bash
./scripts/fleet/stop.sh          # drain: no new worktrees, the agents in flight finish
./scripts/fleet/stop.sh --now    # ...and interrupt the fleet's agents, and freeze
                                #    every outward effect while it is set
./scripts/fleet/stop.sh --all    # ...and every other agent Orca knows about
./scripts/fleet/fleet.sh resume  # carry on
```

The stop is a **file**, not a signal, and it lives outside every worktree. That
is deliberate: a signal only reaches a process that is still healthy, and the
moment you most need a stop is the one where something is not.

There are **two** of them, in `~/.autofleet/`, because "start nothing new"
and "let nothing out" are two instructions and only one of them is the agents'
(#183):

| file | means | set by | read by |
|---|---|---|---|
| `DRAIN` | no new worktrees | every stop | `fleet.sh` alone |
| `STOP` | nothing goes out | `--now`, `--all` | `guard.py`, `await-review.sh`, `review-status.sh`, `resolve-thread.sh`, `fleet.sh` |

Under a **drain**, the dispatcher launches nothing and keeps reaping, and the
agents in flight are *not* frozen: they finish, push, open their PRs and
comment. That is the point rather than a leak — a merged PR is what releases the
worktree the drain is waiting on, so a drain that also froze them would wait for
what it had itself forbidden, and end only when the time-box gave each worktree
up three hours at a time. That is exactly what it used to do.

Under a **stop**, nothing reaches GitHub from any agent, whether or not it has
read the news:

- `fleet.sh` checks it before every decision and opens nothing new.
- `await-review.sh` checks it between polls and returns exit 3.
- **`guard.py` refuses `git push`, `gh pr create`, every `gh … comment/edit`
  and any `gh api` with a write method while it exists.**

Reading, building and testing stay open in both — the point is to stop work
reaching anyone, not to freeze the machine.

`fleet.sh status` says which of the two it is in, and nothing removes either
file except `fleet.sh resume`, which removes both.

## Restart it

`fleet.sh run` is a long-lived bash process. It parses its functions **once**, at
start, and never re-reads the file. So a fix merged to `main` is live in your
worktree and *not* live in the dispatcher that is running — and it fails in
halves, which is what makes it confusing: anything the poll re-derives through
`gh` (the queue filter, the labels) keeps working, while everything living in an
already-parsed shell function does not. On 2026-09-07 a dispatcher ran for 27
hours across four merged PRs that changed `fleet.sh`, none of them running
(#173).

`fleet.sh status` now says so. It records what it parsed at start, and reports
the difference:

```
running   (pid 59280)
  up since 2026-09-06 16:57:58, running fleet.sh @ 6d610ca

  STALE -- /path/to/your-repo/scripts/fleet/fleet.sh has changed since it
  started, and it parses the file once. These are NOT live in the dispatcher
  running:
    3994f12 harness.partial's flake is the fixture retiring a worker
    7bdb8ec A worktree whose issue can no longer merge is released
```

It answers about the **dispatcher's** checkout — the main worktree it was
started in, recorded at start — not about the one you are standing in. So
running it from a fleet worktree branched before the fix still says the
dispatcher is stale, which is the case that actually comes up.

There are two ways to be behind, and it distinguishes them, because they need
different things done:

- **STALE** — the checkout has the fix and the dispatcher is running the file as
  it was. A restart is enough.
- **BEHIND** — the fix merged and *nothing pulled that checkout*. Nothing in the
  fleet does: an agent rebases its own worktree, never the main one. So the
  bytes on disk are still the bytes the dispatcher parsed, and a restart alone
  would start the same old code again. It says so, and prints the `git pull`
  first. (This is read from the shared `origin/main`, so it costs no network and
  is as fresh as the last fetch any worktree of this repo made.)

A dispatcher that recorded nothing — one started before this existed, or whose
checkout has since gone — says "cannot say" and prints the restart anyway. A
staleness report that fails open is the same silence.

To make a change live:

```bash
./scripts/fleet/stop.sh          # drain: the agents in flight finish and their
                                # PRs land, the dispatcher stays up to reap
                                # their worktrees, then exits
./scripts/fleet/fleet.sh status  # until it says `idle` (it says that while
                                # draining too — that is how a drain ends)
git -C /path/to/your-repo pull --ff-only   # if it said BEHIND
./scripts/fleet/fleet.sh resume  # clear the drain
cd /path/to/your-repo && ./scripts/fleet/fleet.sh run --auto
```

Start it from the **main worktree**, and only there — which is why `status`
names that path rather than printing a relative command. A dispatcher started
inside a fleet worktree has its cwd and its own `fleet.sh` under a directory the
fleet removes as soon as that worktree's PR merges.

A drain is the polite version and it can take hours — it waits for the PRs in
flight to merge, because the dispatcher is what reaps a worktree once one does,
and killing it strands the stacks under `restart: unless-stopped`.
`./scripts/fleet/stop.sh --now` interrupts the fleet's agents and stops the
dispatcher immediately; anything it had not reaped is then yours, with
`./scripts/fleet/reap.sh --yes`.

A drain is safe with agents mid-work — it sets `DRAIN` and not `STOP`, so they
finish and their PRs land. What it costs is the wait. When you want the
dispatcher restarted *now* and the agents left alone, take it over directly
instead:

```bash
./scripts/fleet/fleet.sh status  # names the pid, and verifies it is a dispatcher
kill <that pid>
./scripts/fleet/fleet.sh status  # until it says `idle`
cd /path/to/your-repo && ./scripts/fleet/fleet.sh run --auto
```

`status` first, and take the pid from it rather than from `cat fleet.pid`. The
pidfile alone names whoever wrote it last; if a `kill -9` left it behind and the
OS has since recycled that number, `kill $(cat …)` signals a stranger — plausibly
one of the agents. `status` is what checks.

**Only one dispatcher runs at a time**, and `fleet.sh run` refuses to be the
second: `MAX_WORKTREES` is enforced per process, so two of them count the same
worktrees and open twice the cap between them, then reap, card and interrupt
each other's (#179). The refusal names the pid that holds
`~/.autofleet/fleet.pid` and prints both restarts above.

It refuses only to a dispatcher this machine can still see running one: `kill
-0` *and* `ps` still naming a `fleet.sh run`. A pidfile a `kill -9` left behind,
or whose pid the OS has since handed to an unrelated process, is taken over
rather than obeyed — otherwise one stale file would hold the fleet down for
good. `status` and `stop --now` ask the same question, so they cannot disagree
about whether the fleet is up, and `--now` will not signal a pid that is no
longer a dispatcher.

There is a third answer, and the two commands want opposite things from it: a
pid that is alive while `ps` says nothing at all about it. `status` reports
`running?` rather than `idle`, because `idle` is the line that sends somebody to
start a second dispatcher. `run` starts anyway — one unreadable pidfile may not
hold the fleet down — but warns and names the pid. `stop --now` signals it
anyway, because it promises the dispatcher is down when it returns.

**The settings work the same way.** `AUTOFLEET_MAX` (how many worktrees run
at once, default 3), `AUTOFLEET_POLL` and `AUTOFLEET_TIMEBOX` are read
once at start, so putting one in front of `fleet.sh status` changes nothing. The
cap changes across a restart and only there:

```bash
AUTOFLEET_MAX=2 ./scripts/fleet/fleet.sh run --auto
```

Restarting deliberately does *not* clear what the dispatcher gave up on — a
crash and a reboot are not decisions about an issue. `fleet.sh retry N` is
still the only way one comes back onto the queue.

---

## The loop

| Stage | Artifact | Starts the next stage | Who decides |
|---|---|---|---|
| 1. Intent | an `intent`-labelled issue | giving it Goal/Scope/Acceptance | anyone files |
| 2. Spec | the issue body, `ready` | `fleet.sh` opening a worktree | the maintainer |
| 3. Build | the diff and its tests | the test suite green | enforced by the hook |
| 4. Local review | `.autofleet/run/reviewed-<sha>` + the PR body | the push gate lifting | enforced by the hook |
| 5. Independent review | a GitHub review | `merge-gate` going green | the rules you set |
| 6. Maintain | a new issue, or an eval case | back to stage 1 | the maintainer |

### Stage 1 — Intent

An idea, a bug, a rough observation. File it with the **Intent** template
([`.github/ISSUE_TEMPLATE/intent.yml`](../.github/ISSUE_TEMPLATE/intent.yml)):
problem, proposed outcome, affected systems, constraints, open questions, in your
own words. An idea should not have to wait until someone has time to write a
proper issue.

### Stage 2 — Spec

An issue is workable when it carries the four sections every issue here carries —
#5 and #40 are the standard: **Goal**, **Scope** (including what is *not* in),
**Design notes** (the decisions already made, and why), **Acceptance** (each item
something a test or a command can demonstrate).

Below a `<!-- blockers -->` marker, `Blocked by #N` lines name its dependencies.
[`unblock.yml`](../.github/workflows/unblock.yml) derives `blocked`/`ready` from
those lines, and `fleet.sh` reads the same lines to order its queue. **Never
hand-edit those labels.** The lines are editable, but changing one changes what
other agents may start — do it deliberately, alone, and say so in the PR body.

It runs on a merged pull request, and on an issue `opened`, `edited`, `closed` or
`reopened` — not only on a merge. Two consequences worth holding on to, because
this file tells you to edit issue bodies as you work:

- **Your edit relabels the whole backlog**, not just the issue you touched: every
  run recomputes every open issue. That is deliberate and idempotent, and the
  runs are serialised by a `concurrency` group on the job, newest wins. A
  cancelled run can still stop partway through the backlog — so the stale label
  is removed *before* the new one is added, which leaves an issue with neither
  label rather than both. Neither is the fail-open state: `fleet.sh` starts
  nothing that does not carry `ready`, and the next run finishes the job.

  The ordering alone was not enough, and it took two goes to say so accurately.
  It covers a run that *dies* between the calls. A run whose *removal fails* fell
  straight through to the add, because the label list is a pre-run snapshot — so
  a rate-limited `removeLabel('ready')` was recorded and `addLabels('blocked')`
  ran anyway, producing the both-labels state the reorder was supposed to rule
  out. The add is now **gated on the removal succeeding**: either both writes
  land or neither does, and the issue keeps the single label it had.

  What that leaves, stated because it is the honest end of it: an issue whose
  removal failed keeps its old label. One that should have become `blocked` still
  carries `ready`, and `ready_issues()` will start it on an open blocker until a
  later run repairs it. The failure is recorded, the rest of the backlog is still
  relabelled, and the run goes red — but a red check is not something `fleet.sh`
  reads. Closing that last gap means teaching `ready_issues()` to consult
  `blocked`, which is its own change.
- **Only a line below the marker counts — when the body has one.** `Blocked by
  #N` has to begin a line, below the **first** `<!-- blockers -->` marker;
  everything under the earliest one is read, so pasting a second marker lower
  down does not supersede the section above it, it adds to it. Below a marker,
  prose in Goal, Scope or Design notes does not block anything — including a
  sentence like *"no longer blocked by #7"*, which used to register as a blocker
  and could get the agent that wrote it interrupted and its worktree reaped
  (#47).

  **A body with no marker is read whole**, and that is the case to be careful in.
  The fallback is deliberate — reading those as unblocked would start work on a
  foundation that has not landed — but it means any line that *begins* with
  `Blocked by #N`, or with a list bullet and then `Blocked by #N`, counts
  wherever it appears. Writing `- Blocked by #12 until that lands` into Design
  notes on such an issue marks it `blocked`, and `fleet.sh` reads `blocked` as
  "this worktree will never produce a merged PR": it interrupts the agent and
  reclaims the slot. **If you are adding blocker lines to an issue that has no
  marker, add the marker too** — that is what makes the rest of the body inert.

  Three boundaries either way. The anchor sees the start of a line and nothing
  before it, so a negation that *wrapped* onto the previous line still counts —
  keep a blocker line, and any sentence about one, on one line. The prefix accepts
  `-`, `*`, `+`, `>`, `1.`, `1)`, `- [ ]` and `**bold**`, so a bulleted mention is
  a blocker as surely as a bare one. And **neither reader knows what a fenced code
  block is** — a `<!-- blockers -->` line inside one is a marker like any other,
  and being first it wins, so everything below it (ordinary prose included) is
  read as blocker space. A pasted example is the body most likely to trip this,
  and the two obvious dodges do not work: **indenting** it does not help (the
  pattern allows leading whitespace) and **splitting it across two lines** does
  not either (the pattern allows a newline inside the comment). What works is
  leaving anything else on the line — write it inline in backticks the way this
  page's prose does, or put a note after it. A line that contains only the marker
  is a marker, however it is indented or wrapped.

One rule the labels cannot express: **a foundation issue lands alone.** An issue
that defines an interface later issues include (M0-2's `HttpClient` is the
standing example) merges before anything depending on it starts. Label it
`foundation` and `fleet.sh` holds the fan-out for it.

And one the labels express badly: **an issue no agent can close.** Label it
**`needs-human-step`**. That happens two ways, and the label means either:

- **The last step is a person's.** Tagging a v1 (#148), touching a real console
  (#44) — outward, irreversible, and the maintainer's call. `ready` cannot say
  this: every blocker really is closed, and the label stays through the PR that
  does the preparatory work, so the issue comes back to the front of the queue
  the moment that PR merges. #148 was picked up again eighteen seconds after its
  own preparation landed, and would have been picked up once per cycle forever.
- **No agent can start at all.** #139 is the standing example: its scope is
  `.claude/hooks/guard.py`, and `.claude/hooks/` is in `PROTECTED_TAILS` in
  [`guard.py`](../.claude/hooks/guard.py), so from a fleet worktree the guard
  refuses to write there — from an `Edit` and from a shell command alike. #139's
  agent hit exactly that, produced no PR, and applied the label itself: the rule
  it would have had to go around is the rule its own issue exists to tighten.

Both want the **same queue behaviour** — never open a worktree — so both carry
the same label. Which one you have is in the issue's own **Scope**, not in the
label: read it before assuming there is agent-ready work behind it.

`fleet.sh` does four things with it:

- it is **not startable** — the dispatcher opens no worktree for it, in `--auto`
  or from an explicit `fleet.sh run 148`. Removing the label hands it to an
  agent, which only ever makes sense in the first sense above;
- an agent `waiting` on one is reported as **waiting for you, as expected**
  rather than as a stall. #142 stopped before `git tag` exactly as its issue told
  it to, and was flagged for it — noise on the one signal that is supposed to
  mean something is wrong;
- it is **exempt from the time-box**. This is the half that matters: #44 was
  interrupted at three hours for correctly producing nothing;
- and its worktree is **released** once there is nothing left in it — see
  "Releasing a worktree" below. Without this, #139's worktree waits for a merged
  PR that can never exist.

**In the first meaning only**, the label is a claim about the *last* step, not
the whole issue — and where there is real agent work in front of that step, it
belongs in **its own issue with its own `Closes` line**, because `merge-gate`
refuses a PR that closes nothing. That is what #142 and #148 are: #142 prepared
the release and closed on PR #146; #148 *is* the release and only the maintainer
can close it. An issue split that way can carry `needs-human-step` from the
moment it is filed.

**In the second, do nothing but label it.** There is no preparation to carve out:
a child issue of #139 is no more doable than #139 — the same guard refuses the
same writes for the same reason — and it would arrive `ready`, so the fleet would
open a worktree for it. That is the once-per-cycle re-pick above, the loop #145
closed on #148, coming back through the front door. The work is the maintainer's
start to finish; leave it as one issue.

### Stage 3 — Build, in the worktree

`fleet.sh` creates the worktree with the issue linked and the brief already sent;
`orca.yaml`'s setup hook provisions it — isolated ports, seeded ROM fixtures, a
full build, its own fixture stack, its own data, a browser tab signed in as the
fixture admin. `setupAgentStartupPolicy: wait-for-setup` holds the agent's tab
until that finishes, so its first the test suite means something.

**There is no planning phase.** The agent's opening prompt is `/implement`, and
the issue is the plan: Goal, Scope, Design notes and Acceptance were settled at
Stage 2, on the tracker, which is where the deciding belongs. A planning round
before the first edit re-derived what the issue already said, and then rode in
the prompt prefix of every request for the rest of the session.

`## Plan` in the PR body survives, with its meaning narrowed to the half that was
ever read downstream: **what the issue asked for, and where the implementation
departed from it and why.** Departing is normal; departing silently is not, and
the review checks that section against the diff.

`/implement` is a skill from the mattpocock plugin, and it ships
`disable-model-invocation: true` — an agent will not reach for it on its own, and
no other skill can call it. What makes it reachable here is that
`agent-autostart.sh` delivers the brief as a **typed prompt**, not as an
instruction to a model. That is worth knowing before anyone tries to move the
brief somewhere a model merely reads it.

**The brief arrives in two stages, and the second one is fetched, not pushed.**
[`scripts/fleet/issue-command.sh`](../scripts/fleet/issue-command.sh) `<n>`
prints the spec, steps 1 to 3 — build, record the review, and a pointer;
`issue-command.sh --after-pr <n>` prints steps 4 to 6, the post-PR contract:
what the PR body must carry, arming auto-merge, the one review and the two
validations. Whole,
the brief was 1,521 words of which 1,272 were that second half, and all of it
arrived before the agent had opened a file and then rode in the prompt prefix of
every request it made for the rest of the session (armaatus/autofleet#49). Both
stages are still written in that one file, so `orca.yaml` and
`agent-autostart.sh` cannot drift from it, and `evals/lint.sh` asserts that the two together still name every
script in the loop — an instruction that fell out of both halves is a rule
nobody enforces.

Then it builds, with three things that are not negotiable:

- **There is no mock for the service under test.** Tests run against a real service in Docker, per
  worktree, on its own port. Failure modes a healthy server will not produce on
  demand — 401 mid-sync, a truncated body, a dropped connection, a stall — are
  forced with the fault proxy. See [TESTING.md](TESTING.md).
- **Every change carries a test that would have failed before it.** Not "the
  suite still passes". For a bug fix, write the failing test first, watch it fail
  for the reason you expect, commit it, and only then fix the code —
  `/mattpocock-skills:tdd` is that loop.
- **Verification is part of "done".** Run the test suite and read the output. If
  the rig's smoke test reports **Skipped**, the fixture is not running and most of the suite is
  meaningless.
- **When `main` moves under you, rebase onto it — never merge it in.**
  `scripts/release-notes.sh` builds the notes with `git log --no-merges`, because
  a squash-merge repo has no merge commits worth listing, so a merge commit at
  the head of a branch is a commit the notes cannot see: `release.notes` goes
  red saying the notes do not list the commit at HEAD, and the branch's own work
  is missing from them. The failure names the symptom and not the cause, which
  is why it is written here. Rebasing costs resolving the same region once per
  commit; do that. Whatever you resolve, diff the result against a tree you have
  actually run — `git add -A` on a round where a second file was also conflicted
  is how conflict markers reach a commit that still builds.

There used to be a `verifier` subagent here: a fresh context that built, ran the
suite, and answered `READY` or `NOT READY` before the PR opened. It is gone, and
the reason is arithmetic rather than distrust. `/implement` runs the full suite
at the end of the build, CI runs it on the push, and the **validator** runs it
again with a reason to — "did the commits answering the review break anything" is
not answerable by reading. A fourth run, before the pull request existed, was the
belt-and-braces this whole change is about removing.

An issue gets **three hours**. On expiry, if no PR closing it is open, the fleet
interrupts the agent, comments on the issue saying so, and **leaves the worktree
standing** — a stuck task is exactly the one worth looking at, and its fixture
and build state are the evidence. You get a notification.

If it cannot reach GitHub to find out, it does nothing and says so in the log:
an agent is only ever stopped on an answer, never on a lookup that failed. The
one it would otherwise stop is as likely to be the one waiting on a review as
the one grinding.

### Stage 4 — Local review, before anything leaves

**One pass, and `/implement` runs it** — `/mattpocock-skills:code-review`, at the
end of the build, before it commits, against [REVIEW.md](../REVIEW.md). What to
run is the brief's step 1; the command that records it is step 2. This section is
why that recording exists at all.

It used to be two, `/code-review` alongside it. They overlapped heavily, and
`merge_gate.py` refused any PR body that did not name both — so every pull
request paid for two reviews of the same diff before a reviewer who had never
seen the conversation had looked at it once. The surviving pass covers both axes
the second was there for: standards, and spec-vs-diff.

Recording writes `.autofleet/run/reviewed-<sha>`, and **`guard.py` refuses `git push` and
`gh pr create` from a fleet-owned worktree without it.** The marker records what
it is given; it cannot tell whether a review really happened, so it is a
checklist gate. What actually enforces the pass is `merge-gate`, which
reads the PR body — and that a human can read too. The marker is
per-commit, so amending or adding a commit needs the review re-run — which is the
point. A worktree you opened by hand is never gated: pushing a half-finished
branch is normal, and a guard that argues about it is a guard people route
around.

What the PR body must carry is the brief's step 4, and it is not decoration:
[`merge-gate`](#the-merge-gate) reads it — which is why the list lives in one
place and not here as well.

### Stage 5 — One review, two validations, and the merge

**The loop is bounded by two numbers, and this is the section about why.**
`AUTOFLEET_REVIEW_MAX` is 1 and `AUTOFLEET_VALIDATE_MAX` is 2, so a pull request
costs at most three agent runs after it opens and often one.

What it replaced was bounded at four **reviews** per pull request, and it spent
them. The mechanism was not a bad reviewer; it was a correct one in a loop with
no fixed point. A review is bound to the commit it judged. The author answers a
finding with a commit. The commit moves the head. The moved head invalidates the
review that asked for the fix, so `merge-gate` wants a verdict on the new head,
so the reviewer reads the whole diff again — and finds one more thing, a level
down, because there is always one more thing. #86 burned four reviews without one
of them ever judging the commit that eventually merged. #79 converged on
behaviour after two rounds and spent six more on the same finding one level
further down; every one of the six was correct, which is the whole problem.

So the second and later passes stopped being reviews. A **validation** asks two
questions and no others:

1. Is each finding the review left actually addressed — fixed, or answered with a
   reason this reader accepts?
2. Do the commits written since the review break anything — a red suite, or a
   Critical defect *in that diff*?

It does not re-read the branch. That narrowness is not modesty, it is the
termination argument: a validator that looks for new things finds them, and new
things are another round.

**A `pass` stands in for the review.** `merge_gate.py` reads
`<!-- validated: <head-sha> pass -->` on the current head as satisfying the
"reviewed on this head" condition — which it has to, because from the first fix
onward there is no review on the head and no second review is coming. Without
that substitution every pull request would block forever on a review that cannot
arrive, which is exactly the failure `AUTOFLEET_REVIEW_MODE=local` exists to
remove, reintroduced one phase up.

**The trailer rides in a `gh pr review`, not a `gh pr comment`**, and that is a
security choice. `guard.py` already refuses `gh pr review` from a fleet-owned
worktree in all four spellings it has, so the certificate is out of reach of the
branch it certifies. `gh pr comment` had to stay reachable — `answer-review.sh`
needs it — and a certificate its subject can write certifies nothing. The hook
also refuses `validate.sh` by name from a worktree, so the refusal arrives at the
command rather than one process deep in a log after a full-budget run.

**Anything but a literal `pass` or `fail` is "not validated".** A missing
trailer, a garbled verdict, a validator that crashed before writing one: all of
them hold the pull request. That is the fail-closed direction and it is the one
the whole phase rests on — nothing at all must not read as consent. The
corollary is the refund: a validator killed at its deadline, or one whose CLI was
not on `PATH`, does **not** burn a try. A cap that fires early here hands a
person a branch nothing validated, and that is worse than a cap that fires late,
because late still ends in a person.

**Threads stayed.** The reviewer's inline comments are still threads, and
`merge-gate` still refuses to merge while any is unresolved — #88 and #89 both
sat green and blocked on exactly one. What changed is who closes them: the
**validator** resolves the threads it is satisfied by. An author closing its own
would be holding the ledger it is judged against.

**A Critical or Important finding is fixed. A Suggestion is answered.** The
asymmetry is because no second reviewer is coming: whatever an argument can close
here, nothing else will catch. That replaced the old round-three nit floor, which
existed to stop a reviewer spending rounds on preferences — a problem that only
arises when there are rounds to spend.

**Where this review runs is a knob**, `AUTOFLEET_REVIEW_MODE` in
`.autofleet/config`. The rest of this stage describes the default, `github`.
Under `local` the reviewer is a process the **dispatcher** starts on the machine
— [`scripts/fleet/review.sh`](../scripts/fleet/review.sh), briefed by
[`.claude/agents/reviewer.md`](../.claude/agents/reviewer.md) — and everything
below still holds except who submits: same `REVIEW.md`, same verdict states, same
`<!-- review-findings: N -->` trailer, same `await-review.sh` on this side.

Two things differ, and both are the agent's business:

- **You cannot start it and you cannot fake it.** `guard.py` refuses
  `gh pr review` from a fleet worktree. The reviewer's verdict carries a second
  trailer, `<!-- independent-review: local <head-sha> -->`, and that marker is the
  only reason `merge_gate.py` counts a review submitted by your own account.
- **There is no Actions run to look at.** A silent reviewer leaves a line in
  `~/.autofleet/fleet.log` and a transcript under `~/.autofleet/reviews/`, not a
  `verdict` comment on the PR.

**One reviewer at a time, and an answer per review.** `#64`. Two reviewers
landed on PR #1's head within fourteen minutes — 7 findings and then 10 — because
the dispatcher decides to spawn from `[ -e "$REVIEWING_DIR/<pr>" ]` and writes
that lock *after* the spawn, so a second poll, or a hand-run `review.sh` beside a
running dispatcher (what clearing a backlog looks like), both saw no lock. The
claim is the reviewer's own now, and it is a create-or-fail
(`fleet_lock_claim`): of two racing claims exactly one wins and the other exits
**9**, naming the pid that holds it. A lock whose process is gone is taken over
rather than obeyed — nothing clears that directory across a dispatcher's death,
and a stale marker read as "one is running" retires a pull request from review
for good.

The half that lost information was the gate's. `merge_gate` collapsed the
reviews on a head to the latest one *per author*, and in `local` mode every
reviewer is the same account — so the second review superseded the first, and
the first's findings were never owed an answer. On PR #1 the author answered the
07:13 review, that commit moved the head, and the 07:27 review's ten findings
went unread with a green log beside them. Two changes: the findings condition is
**per review** (the `CHANGES_REQUESTED` condition is still per author — that is
a reviewer's standing verdict, which a later review from the same reviewer does
supersede), and the gate names any review on an **abandoned** head whose
findings nothing answered — on **every** path, not only the "no review on the
current head" refusal it started inside. That arm already refuses, so reporting
there added detail to a pull request that was blocked anyway and said nothing on
the two paths a PR merges through: the exact sequence above, where a second
review lands on the new head, is one of them. A PR held that way is also due a
validation, because the validation is the reader the refusal names and a hold
whose remedy never starts is a permanent one. One comment
still answers every review on the head, because `answered()` only requires it to
come after the review it answers; what changed is that it can no longer answer
one and be counted for two.

**The round count is the pull request's, not this fleet's.** `#91` bounded the
rounds and `#65` made the number honest. `<pr>.rounds` was a tally `review.sh`
incremented on exit 0, and its own comment recorded three reviews it could not
see: one submitted by the workflow rather than by this script, one found on exit
8 that no run ever counted, and one a killed reviewer had already left. Each is
a real review a real PR really had, so a PR could pass the cap unnoticed.
`review.sh` now also derives the count from the PR payload it already fetches —
how many distinct heads carry a review `merge_gate` counts — and keeps the
larger of the two. Larger, never smaller: a force-push that orphans every
earlier review drops the derived count to zero, and that must not reopen the
loop the cap closed. Two of the three are covered; the exit-8 case is not,
because that run returns before the derivation, so a PR whose rounds arrive only
that way overshoots by one and the correction lands on the next run that
submits. `fleet.sh status` shows the count per open PR, which is
where a person sees a pull request quietly on its fourth round.

**What a round reads is also a knob.** `AUTOFLEET_REVIEW_SCOPE=delta` scopes
round N to `<last reviewed head>..<head>` — derived from the pull request
`review.sh` already fetches, never stored — and hands the reviewer a byte-capped
file holding what the last round found, how it was answered, and the threads
still open. It degrades to `full` on round one, on a force-push that orphans the
last reviewed head, when the fetch of the PR ref fails, and every
`AUTOFLEET_REVIEW_FULL_EVERY`th round, and it says in the log which it used.
What it does **not** change is what the gate accepts: `merge_gate.py` still
requires a counting independent review on the current head, per head. A narrower
read is not a weaker gate.

[CONFIGURATION.md](CONFIGURATION.md#the-review) has the trade in full, including
what `local` gives up, the three counters side by side, and the per-round cost
row every review appends to `$FLEET_DIR/reviews/cost.tsv`. autofleet itself runs
on `local`, because it has no `CLAUDE_CODE_OAUTH_TOKEN`.

On GitHub, in `github` mode:

- [`ci.yml`](../.github/workflows/ci.yml) — host tests against the real fixture, three
  Switch targets, `core/` include hygiene. ~5.5 minutes.
- [`agent-config.yml`](../.github/workflows/agent-config.yml) — regression-tests
  the agent configuration whenever it changes.
- [`claude-review.yml`](../.github/workflows/claude-review.yml) — the independent
  review, from a context that has not seen the conversation which produced the
  diff. It submits a **real GitHub review**: `REQUEST_CHANGES` when it has a
  Critical or Important finding, `COMMENT` when it does not, never `APPROVE`.
  **It no longer fires on `synchronize`** — that was the trigger that turned one
  review into one per push.
- [`validate.yml`](../.github/workflows/validate.yml) — the `github`-mode twin of
  `validate.sh`, on `synchronize`. Both modes get a validator or the payload is
  broken in one of them: a host repository with the review secret and no
  dispatcher would otherwise inherit a merge gate demanding a validation with
  nothing able to write one.

  Silence is its failure mode, so two things guard it. The review job is keyed on
  the **head sha** and never cancels in progress: a build can be superseded by
  the next push, but a review cannot, because the gate wants a verdict on one
  specific commit and a cancelled run leaves that commit with none — and the
  no-verdict notice is `needs: review`, so it does not fire either. And when a
  run finishes having submitted nothing, the `verdict` job says so in a comment
  *and asks for one more review, once per head*. That dispatch runs as
  `github-actions[bot]`, which the action refuses as a non-human actor unless it
  is named in `allowed_bots` — so the review job names it, and only it. Before that, both remedies the
  comment named were manual, so a PR whose review was silent waited for a person
  to notice — which is the same dead end as a gate nothing re-runs.

  **A PR that edits this file gets no review at all, and that is the action's
  rule rather than this repository's.** `claude-code-action` refuses to run
  unless the workflow file is byte-identical to the copy on the default branch:

  > Skipping action due to workflow validation: Workflow validation failed. The
  > workflow file must exist and have identical content to the version on the
  > repository's default branch.

  It is a supply-chain control — otherwise a pull request could rewrite the
  prompt and the tool list of the agent reviewing it.

  **The remedy is a dispatch, not giving up.** A `workflow_dispatch` run uses
  the DEFAULT BRANCH's copy of the workflow, so it passes that validation and
  reviews `refs/pull/N/head` — the PR's content, judged by the agreed workflow:

  ```bash
  gh workflow run claude-review.yml -f pr=<N>
  ```

  The review it submits lands against the PR's current head, so `merge-gate`'s
  independence requirement is genuinely satisfied by it. PR #87 was reviewed
  this way while editing this same file, and so was #147, which is where the
  rule was diagnosed. What must NOT happen is waiting out `await-review.sh` for
  an automatic review that cannot start; the `verdict` job's comment is the
  signal to dispatch one instead.

  The reviewer is also told to submit with `gh pr review --body`, not
  `--body-file`. Its allowed tools are Read, Grep, Glob and a fixed list of
  `gh`/`git` calls: no Write, no generic Bash, no redirection, so it had no way
  to create the file the instruction named. A run submitted only if it
  improvised away from what it was told, and PR #131 produced three green review
  runs and zero reviews. `evals/lint.sh` now checks the documented command
  against the granted tool list.
- [`merge-gate.yml`](../.github/workflows/merge-gate.yml) — the required check
  that decides whether the PR may merge itself.

Back in the worktree the agent waits with one blocking call, `await-review.sh`,
which the brief's step 5 hands it at the moment it applies.

This is the cheap half of the loop. An agent that waits by *thinking about
whether the review has arrived* burns tokens the whole time. An agent that waits
inside one tool call burns nothing — the session is suspended until the script
returns. No webhook, no ingress, no daemon; `gh` on a 30-second poll.

It also returns early on the two things a review cannot answer, rather than
spending the deadline on them: exit 7 when the PR's build is red, and exit 8 when
GitHub says `DIRTY` because something merged underneath the branch. Both print
what to do instead — for the conflict that is a rebase, a fresh
`record-review.sh .autofleet/run/self-review.md` (the marker is per-commit, and a
rebase changes every sha),
and `git push --force-with-lease`.

What it waits *for* is not "any review record": it imports
[`merge_gate.py`](../.github/scripts/merge_gate.py) and asks the gate, exactly as
`review-status.sh` does. A review counts when it is not by the PR's own author,
is on the head GitHub currently has, and carries a body worth reading or at least
one inline comment. That matters because replying to a review thread submits a
`COMMENTED` review attributed to the replier — so an agent answering findings
used to be handed its own empty reply back as "the review", spend a round on it,
and then watch `merge-gate` refuse the PR for the reason the wait had just called
satisfied ([#114](https://github.com/armaatus/rommsync-nx/issues/114)).

It also hands a given review back exactly once. A round can begin on an unchanged
head — `claude-review.yml` still fires on `review_requested`, the one manual route
to a second opinion — so the wait remembers the newest review it reported, in
`.autofleet/run/review-rounds` beside the round count, and waits for a *newer* one rather
than spending a second round on findings already in hand.

**The inline findings obey that same rule, and for one round did not.** A review
verdict is only half of what the wait hands back; the other half is the review
threads, which is where the findings actually are. That half used to come from
`pulls/<n>/comments`, an endpoint that cannot report `isResolved` and has no
notion of a round: it returns every review comment the PR has ever had, so round
two re-read round one's findings — already fixed — and round three re-read both,
with the one live comment buried among them. It was also cut at two hundred
lines, mid-comment, in the middle of the text the agent was being told to act on.

So the wait asks for *threads*, through the same
[`pr_payload.sh`](../.github/scripts/pr_payload.sh) query `merge-gate` and
`review-status.sh` use, and prints a thread when it is unresolved **and** its
newest comment is newer than the one recorded on the last round. A thread the
agent has already seen and nobody has touched is not repeated; a thread it
replied to and the reviewer answered has *moved*, and is. The agent's *own*
reply does not count as movement — the loop tells it to reply with its reasoning
before resolving, so without that test every thread it answered would come back
with its own answer underneath, which is the same failure by another route. In
`local` mode the reviewer and the author are one account, nothing can tell the
two replies apart, and the thread is shown rather than guessed at. Still-open threads it
withholds are counted, never truncated, and pointed at `review-status.sh`, which
exists to print every one of them.

That leaves the wait's own closing prose as the commands and one line of why —
what the PR body must carry, how the merge is queued and what auto-merge is doing
meanwhile are the brief's, and a second copy of a contract is what an agent reads
instead of the original.

Then it fixes what is Critical or Important, replies with a reason where it
disagrees with a Suggestion, and **leaves the threads alone** — the validator
resolves what it accepts, which is the whole of what makes a resolved thread mean
anything. `answer-review.sh`, then a push if anything changed, then
`review-status.sh`, whose exit 0 means every thread resolved and every check
green. The brief's step 5 is the order and the exact invocations; the rest of
this section is why each has to exist.

The order matters: an answer has to come *after* the review it answers, and a
push invalidates that review. So answering a review you have just pushed over
would be discarded by the review of the new head — `answer-review.sh` refuses
when no review has been submitted against the current head, rather than posting
one that nothing will count.

Resolving goes through `resolve-thread.sh` — which is now the **validator's** to
run, and a person's — rather than the `resolveReviewThread` mutation, because
**no GitHub event re-runs `merge-gate` when a thread is resolved**.
`pull_request_review_thread` is a webhook event, not a workflow trigger — putting
it in `on:` invalidates the whole file, and actionlint rejects it — so the gate
went red on an open thread, the agent closed the thread, and nothing asked the
gate again. `--auto` never fired, and only a later push or `review_requested`
rescued it. `resolve-thread.sh` resolves the threads and, once the *last* one is
shut, re-runs the gate's own failed run on this head, which updates that check
run in place. That is the same mechanism `merge-gate.yml`'s `clear-stale` job
uses, and the only one available: a `workflow_dispatch` run's checks attach to
the ref it was dispatched on, not to a PR head.

### Answering the review, and why the branch waits for it

`gh pr merge --auto --squash` is run the moment the PR exists, and the review
only runs after that. So from the instant a review is submitted the branch is one
green check away from merging — and `merge-gate`'s other conditions do not stop
it. A standing `--request-changes` does. An open thread does. **Nits in the body
of a `COMMENTED` review do not**: the gate is satisfied, `--auto` fires, and the
branch goes in while the agent is still editing.

That happened four times — [#146](https://github.com/armaatus/rommsync-nx/pull/146),
[#154](https://github.com/armaatus/rommsync-nx/pull/154),
[#159](https://github.com/armaatus/rommsync-nx/pull/159),
[#168](https://github.com/armaatus/rommsync-nx/pull/168) — each leaving real work
uncommitted in a worktree the dispatcher then tried to delete, and #154's took a
defect that silences the stalled-agent detector to `main` with it
([#170](https://github.com/armaatus/rommsync-nx/issues/170)).

The window is not the life of the PR. `merge-gate` requires a review on the
*current head*, so the agent's next push turns the gate red on its own; the race
runs from the review being submitted until anything is pushed. What the agent
does in between is read the findings, fix them, run the test suite, and push — and a
full suite here is 20 to 30 minutes. All four merged inside that run, because
that run *is* the window.

So the review declares what it left, and the author answers it:

- every review body ends with `<!-- review-important: M -->` and
  `<!-- review-findings: N -->`
  ([REVIEW.md](../REVIEW.md), and `claude-review.yml`'s prompt demands both).
  `N` of `0` is the only thing that can tell "nothing at all" from "five nits" —
  both are a `COMMENTED` verdict. `M` splits the second case again, into "five
  nits" and "one data-loss bug", which nothing downstream could previously tell
  apart either;
- **`M` does not decide whether the branch merges.** `N` above zero holds the PR
  either way. What `M == 0` changes is what `await-review.sh` tells the agent:
  that the answer may be *words*, because `answer-review.sh` clears the hold with
  no commit at all. That difference is worth a paragraph of its own, below;
- a review reporting anything other than `0`, **or not saying**, holds the PR
  until its author comments an answer. `answer-review.sh` writes it, carrying the
  head sha, and re-runs the gate's failed run exactly as `resolve-thread.sh` does
  — an issue comment is not one of `merge-gate.yml`'s triggers and cannot be, since
  an `issue_comment` run's check attaches to the default branch rather than to
  this PR's head;
- **"I am not doing this, because" is as good an answer as a fix.** The gate
  cannot tell them apart and does not try. What it asserts is that somebody read
  the findings and decided before the code went in;
- a review reporting `0` needs no answer, so a finished PR still merges with
  nobody watching. That is the property arming `--auto` early exists to keep
  ([#90](https://github.com/armaatus/rommsync-nx/issues/90)), and it is why the
  requirement is conditional rather than a blanket "the agent declares done" — an
  agent that dies must not be able to strand a PR that nothing was wrong with.

Missing the trailer fails *closed*: the PR is held as though findings were left.
Guessing "clean" re-opens the race; guessing "found something" costs one command.

Two consequences of failing closed, both deliberate and neither free:

- **a human leaving a `COMMENTED` review holds the PR too**, since a human does
  not write the trailer. Add `<!-- review-findings: 0 -->` to the body if you
  meant "nothing here", **approve it** — an approval asks for nothing, so it is
  never held, and it is the one verdict the review job cannot give — or merge by
  hand, since `enforce_admins` is off and that works with the check red. What
  the gate deliberately does *not* do is exempt human reviewers as such: that
  would make *who* reviewed decide whether findings can be outrun, and the
  reviewer's identity is not what the race is about;
- **a review whose findings were all inline** cannot carry a trailer if its body
  is empty, so it is held until answered even once every thread is resolved.
  That is the right way round: resolving a thread says the finding was handled,
  and the answer says the review was.

One thing the answer does *not* close: `merge_gate.py` reads the **latest**
substantive review per author, so a second review on the same head declaring `0`
supersedes an earlier unanswered one. That is the same property that lets a clean
re-review clear a standing `CHANGES_REQUESTED` without a dismissal step, and it
is older than this condition; taking it away here would wedge the PRs it exists
to unwedge.

Exit 4 is the same verdict on a PR that touches `.claude/`, `.github/workflows/`,
`.github/scripts/`, `.autofleet/guard.json`, `.autofleet/config` or
`.autofleet/review.md`: nothing left to fix, and a person merges it. The last
three are the project-owned half of the same layer — `guard.json` *is*
`guard.py`'s project rules, `config` carries `AUTOFLEET_REVIEW_MODE`, and
`review.md` is the host's own correctness rules, which the reviewer applies —
while `.autofleet/setup.sh` and `teardown.sh` beside them are ordinary project
code the fleet merges for itself. Exit 1 prints
the reasons, and three of them are not waiting on a review — GitHub answering
`BLOCKED` while every check is green is [#84](https://github.com/armaatus/rommsync-nx/issues/84),
a stale run still counted by branch protection, and the script prints the
`gh run rerun --job` that clears it; `DIRTY` is a conflict with the base, and
`BEHIND` is a base that moved. None of the three is answered by another review.

Checks are judged the way GitHub judges them, newest run per check *name*.
`merge-gate` runs several times on one head on purpose, and every run before the
review lands is an honest failure its own later run supersedes.

Resolution comes from GitHub's own state through GraphQL, not from whether a
reply exists — the REST endpoint for PR comments cannot report it, and
`isOutdated` is not `isResolved`.

**A nit is answered, not fixed.** When the review in hand declares
`review-important: 0`, `await-review.sh` prints a different instruction: answer,
open one follow-up issue for anything worth keeping, and push only if something
there is genuinely worth a commit. It is not printing a weaker review — the nits
are printed in full — it is printing the cheaper of two ways to discharge them.

The expensive way was the default, and it was the default silently. A fix moves
the head; a moved head invalidates the review that asked for the fix
(`merge_gate.py` requires one on the *current* head); the dispatcher then starts
a fresh reviewer, which reads the whole diff again and finds one more nit. Three
pull requests were measured sitting in that cycle — #85, #86 and #88 — with
`answer-review.sh`, which clears the same hold with no commit, never once run on
any of them. Nothing forbade the cheap path. Nothing mentioned it either.

**The other half of that floor has been removed, and with it the floor.** It used
to live in [REVIEW.md](../REVIEW.md): from round three on, a review finding
nothing Important stopped asking for a diff and named its nits in the body as
follow-up issues instead. It was a correct rule for a loop with rounds to spend,
and the loop no longer has them — the reviewer runs once. What replaced it is the
asymmetry in the policy itself: a Critical or Important finding is fixed, a
Suggestion is answered, and the validator will not accept an argument in place of
the first two because no second reviewer is coming.

One thing the old floor got right is worth keeping in view, because it is the
reason `0` is still dangerous: `review-findings: 0` releases the gate outright,
and auto-merge is armed from the moment the PR opens. A review that found five
Suggestions and reported `0` merges the branch while its author is still reading
them. That has happened four times.

**At most three waits, counted by the script.** `await-review.sh` keeps the count
in `.autofleet/run/review-rounds` and exits 5 on the fourth call rather than
waiting, so this is not something an agent has to remember. Three is still the
right number under the new shape for a different reason than it was under the old
one: one review plus two validations is three things an agent waits for. When it
trips, the agent stops, comments saying exactly what is unresolved and why it
disagrees, and flags the card. Another lap is not what a disagreement needs; your
attention is.

**And `AUTOFLEET_REVIEW_MAX` and `AUTOFLEET_VALIDATE_MAX` on the dispatcher's
side**, which are different caps answering a different question. The agent's is
per-worktree and binds only while the agent is alive: #85's agent stopped at its
cap and a fourth review landed with nobody left to answer it. The dispatcher's
count lives in `<pr>.rounds` and `v-<pr>.rounds`, counts what was *submitted* on
the pull request across every head, and survives `stop.sh`, because what it
counts belongs to the PR rather than to one dispatcher's run.

Reaching the review cap is now the **ordinary** path rather than the exhausted
one — at a cap of 1, every healthy pull request reaches it on its second poll —
so the dispatcher no longer announces "needs you" there. It hands the PR to the
validator instead. The hold that still means a person is due is the **validation**
cap, and `validate.sh` prints it, where the number lives.

Nothing in this section is where the merge gets armed. It used to end by saying
the agent runs `gh pr merge --auto --squash` "when it is green" — a second copy
of the rule, ninety lines below the first, saying the opposite of it: the merge
is armed the moment the PR exists, which is the whole of
[#90](https://github.com/armaatus/rommsync-nx/issues/90) and what
[the section above](#answering-the-review-and-why-the-branch-waits-for-it) opens
with. That is what a second copy costs, and why the brief is the only one.

### The merge gate

[`merge_gate.py`](../.github/scripts/merge_gate.py) is the required check
`--auto` waits on. It passes only when all seven hold:

1. the PR body shows a local `/code-review` pass;
2. …and a local `/mattpocock-skills:code-review` pass;
3. an independent review exists on the **current head SHA** — pushing a fix
   invalidates it, so a re-review is required. Whose review counts depends on
   `AUTOFLEET_REVIEW_MODE`: in `github` mode, anyone but the PR's author; in
   `local` mode, that plus the author's own review when it carries
   `<!-- independent-review: local <head-sha> -->`. The mode is read from the
   **base** ref, so a PR cannot turn on the second rule for itself;
4. the **latest** review from each author is not `CHANGES_REQUESTED`;
5. no review thread is unresolved — read from a **complete** thread list, not
   from the first page of one;
6. the body says which issue it closes. Any keyword GitHub acts on counts, so
   `Fixes #12` is as good as `Closes #12` — but a body with none merges without
   closing anything, `unblock.yml` relabels nothing, and the fleet then reports
   "nothing startable" with the work available;
7. every review still standing that reports findings — or does not say what it
   found — has been **answered** by the PR's author, on this head, since it was
   submitted. "Answering the review" above is what that is for.

Point 5's second half is its own trap. Both readers of the thread list asked for
`reviewThreads(first:100)`, the first hundred, so on a longer PR the newest
threads fell off the end and the gate reported "no review thread is unresolved"
about a state it had never established. The query now lives once, in
[`pr_payload.sh`](../.github/scripts/pr_payload.sh), which pages to the end; if
paging ever runs out the gate refuses to answer rather than answering from half
a list.

Point 4 is the whole trick. GitHub's `reviewDecision` is sticky: once a reviewer
requests changes it stays `CHANGES_REQUESTED` until dismissed or until that
reviewer *approves* — and this reviewer never approves, by design. Reading it
would leave a PR whose findings were all addressed blocked forever. Taking the
latest review per author instead lets a clean re-review supersede the old verdict
on its own, with no dismissal step and nothing waiting on a person.

A PR touching **`.claude/**`**, **`.github/workflows/**`** or
**`.github/scripts/**`** fails the gate on purpose. Those are the paths that can
disable the checks gating their own PR — the last one because `merge_gate.py`
*is* the gate, and a change to what "may merge" means must not merge itself on
the strength of its own new rules. `enforce_admins` is off, so you merge them by
hand with the check red — which is exactly the intended shape.

The decision lives in a script rather than in the YAML so it can be run and
tested without a pull request: `python3 .github/scripts/merge_gate.py --selftest`,
and `evals/lint.sh` runs it.

Say `@claude …` on a PR or a review comment and the mention job picks it up,
makes the change and pushes — gated to `OWNER`, `MEMBER` and `COLLABORATOR`,
because that is the job that can write.

### Stage 6 — Maintain

Once the PR merges, `fleet.sh` marks the card `completed`, comments which PR
landed, and removes the worktree — first checking the working tree is clean, the
way it already checks nothing is unpushed. Then the next `ready` issue takes the
slot.

The removal runs **no Orca hooks**, and sweeps the stack itself once the worktree
is confirmed gone. `--run-hooks` looks like the obvious way to run `orca.yaml`'s
archive hook, and it is the wrong one: Orca runs the hook *before* it decides
whether it will remove the worktree at all, so a removal it then refuses — a
dirty tree, the submodule — has already taken that worktree's fixture stack and
volumes down. #163 caught this in #122's worktree: the agent was mid-the test suite,
`ipc.engine` failed after 90s with ~130 tests skipped behind it, and the log said
only "could not remove it". So `fleet.sh` removes without hooks and then runs
`./scripts/fleet/reap.sh --yes`, which needs no worktree; a refused removal now
leaves the stack up and says so.

#### Releasing a worktree

A merged PR is not the only way an issue stops being worked, and for a long time
it was the only way a worktree was ever released — so a blocked or abandoned one
held a slot forever. Two were cleared by hand on 2026-09-07, each holding four
containers, two ports and four volumes; while #148 sat blocked with its worktree
open, #119, #122 and #139 were queued behind work that could never start.

So `fleet.sh` also releases a worktree whose issue **went `blocked`**, **closed
with no merged PR for that branch**, **acquired `needs-human-step`**, or whose
agent the **time-box stopped**. None of those carries the guarantee "the PR
merged and nothing is unpushed" does — an abandoned worktree may hold the only
copy of real work — so the release refuses rather than guesses, on the pair that
was verified by hand before every one of those removals:

- `git status --porcelain` empty, **and**
- nothing in `git log origin/main..HEAD`.

Fail either, or fail to answer at all, and the worktree is **kept** and the log
says what is in there — the way the merged reap already reports unpushed commits
rather than removing them. `origin/main` is read as it stands and never fetched:
a stale one only ever makes commits look absent that are in fact merged, so every
error it can cause keeps a worktree rather than deleting one.

That pair answers *is anything here worth keeping*. It does not answer *is anyone
using this* — every by-hand check behind it was made on a worktree that was
already finished — and this file is where the two come apart: **an agent plans
before it edits**, so a worktree forty minutes into real work is legitimately
empty. `blocked` is not a label a person types either —
`unblock.yml` re-derives it on any issue or merge event, so it can arrive under
an agent that
is mid-plan, as `needs-human-step` can arrive from the agent's own hand. So the
first pass that finds a reason **warns**: it interrupts the agent, says on the
card that the worktree goes next pass, and leaves it. The pass after that asks
the pair again — a minute is long enough to commit, or to write a plan down — and
only then removes it. If the agent is working on a `blocked` issue, that is the
point: the label says stop.

A time-box release has one extra half. Releasing the slot would otherwise hand
the issue straight back to the front of the queue and to the same three hours, so
the dispatcher records that it gave up and declines the issue — in `--auto` and
from an explicit `fleet.sh run 44` alike, the same way `needs-human-step` is
declined from both. It is listed by `fleet.sh status`, and cleared **by name**:

```bash
./scripts/fleet/fleet.sh retry 44
```

Restarting the dispatcher deliberately does not clear it. A crash and a reboot
are not decisions about an issue.

And what comes back from the change re-enters at stage 1:

- A review finding that appears **twice** stops being a review finding: the
  correction goes into [CLAUDE.md](../CLAUDE.md) or a skill as part of that
  review. `/mattpocock-skills:writing-for-agents` is the skill for editing those.
- Anything that reached `main` and had to be reverted earns an eval case in
  [`evals/cases/`](../evals/cases), written by whoever handled it.
- Anything the work invalidated in the tracker is edited as it is found —
  including issues that are not yours.

---

## Where to look

Everything runs through the runner, so its board is the status surface. `fleet.sh`
drives it: **`in-progress`** while a worktree builds, **`in-review`** once the
agent has opened its PR, **`completed`** on merge, and a one-line comment on each
card saying what it is waiting for. From inside a worktree an agent sets its own
card with `./scripts/fleet/board.sh in-review "<what it is waiting for>"` --
which goes through the runner driver, so the brief never names one runner's CLI.

You get a macOS notification for the two cases you would otherwise miss: the
fleet stopping, and an issue giving up on its time-box. Everything else is
visible without being interrupted.

## Guardrails

Three layers, in increasing order of how hard they are to ignore.

**`CLAUDE.md`** — read in full at the start of every session, so its size is paid
on every task in every worktree. `evals/lint.sh` fails if it grows past 200 lines.

**Skills** — loaded when they become relevant rather than read every time.
Repo-owned ones live in [`.claude/skills/`](../.claude/skills): `save-safety` on
anything that writes a save, `core-portability` on anything reaching for a
platform facility inside `core/`, `tracker-is-spec` on anything that finds an
issue to be wrong. The `mattpocock-skills` plugin is enabled in the **committed**
`.claude/settings.json`, so every worktree has it — `code-review` (standards and
spec-vs-diff), `tdd`, `diagnosing-bugs`, `writing-for-agents`, `research`,
`grilling` for stress-testing a plan before you commit to it. `evals/lint.sh`
fails if that entry disappears, because the agent brief names those skills.

**Hooks** ([`.claude/hooks/guard.py`](../.claude/hooks/guard.py)) — deterministic.

| It blocks | Why |
|---|---|
| `gh pr merge`, and the `gh api …/merge` spelling | separation of duties: the agent that wrote it does not merge it |
| `gh pr merge --auto` is **allowed** — but not while the fleet is stopped | that asks GitHub to merge once `merge-gate` passes, so a rule decides rather than the agent. A stop is different: arming a merge hands GitHub an instruction that outlives it, which is an outward effect like any other |
| the GraphQL names for all of it — `mergePullRequest`, `addPullRequestReview`, `dismissPullRequestReview` | the same acts by a third name. Each was reachable until a review found it |
| `gh api` carrying a body from a file (`--input`, `@file`) from a fleet worktree | a payload this hook cannot read is one it cannot judge, and `-F query=@file` put a whole mutation out of its sight |
| force-pushing `main` | the commit chain is the audit trail |
| writing to `server/contract/captures/` | rewriting a capture silences the only test that notices RomM changing |
| editing secrets, `.env`, `token.dat`, `device.dat` | hard rule 5 |
| editing `unblock.yml` | it decides what other worktrees may start |
| editing `.claude/hooks/` and `settings.json` **in a fleet worktree** | an agent rewriting its own guards while nobody is watching has none |
| editing `.autofleet/guard.json`, `.autofleet/config` or `.autofleet/review.md` **in a fleet worktree** | the same rule for the project's half of the layer. `merge-gate` will not let a PR touching these merge itself, but `guard.py` re-reads `guard.json` on every tool call — so an agent that empties it has disarmed every project rule while the PR is still open. Reading them is untouched: `config.sh` sources the config on the way into every fleet script |
| `gh api` with `-X POST/PUT/PATCH/DELETE` while stopped | a write is outward; a read is not |
| pushing or opening a PR from a fleet worktree with no `.autofleet/run/reviewed-<sha>` | a PR arrives reviewed or it does not arrive |
| anything outward while `~/.autofleet/STOP` exists (a drain sets `DRAIN`, which this does not read) | a stop that depends on cooperation is not a stop |

Three of those apply **only in a worktree the fleet opened**: editing
`.claude/hooks/` and `settings.json`, editing the `.autofleet/` files that set
the rules, and pushing with no recorded review. In
your own worktree you are the control, and a guard that argues with a person
doing manual work is a guard people route around. The two stop rows apply
everywhere — a stop that reached only the fleet's own worktrees would not be
one. It is also why the guards can still be
improved: the first version protected itself everywhere, and made its own bug
unfixable.

**What the hook is not: a sandbox.** It reads a command and decides; it does not
confine one. A session that means to get past it can — an interpreter one-liner
that opens a file, a path assembled from a variable. What it holds is the
*routine* line: the heredoc, the redirect, the `sed -i`, the `gh pr merge`, the
shapes an agent reaches for while solving the problem in front of it rather than
working around a rule. Past that, the backstops are the diff and `merge-gate`.
Do not write documentation — or a commit message — that claims more.

Four properties are deliberate:

- **It does not fail open.** An unreadable payload or an unparseable command
  blocks. A guard that quietly stops guarding when something upstream changes
  shape is worse than no guard, because nothing says the enforcement went away.
- **It tokenises with `shlex`**, splits compound commands on `;`, `&&`, `||` and
  `|`, recurses into `bash -c`, and skips heredoc *bodies* — so
  `true && rm .env` is caught while a document quoting that line is not.
- **A write is a write whichever verb performs it.** Redirects, `tee`, `cp`/`mv`
  destinations, `sed -i`, `rm`, `dd of=` all go through the same rules an `Edit`
  does. The first version checked paths only for the editing tools, so
  `cat >` into a guarded file rewrote it and the guard said nothing.
- **Skills and subagents are never protected.** They are advisory by design, and
  an agent improving one is the loop working.

`guard.py --selftest` is 68 assertions kept next to the code they constrain,
and it counts what it ran rather than asserting a number kept in step by hand. Every
row is either a rule this repo depends on or an escape somebody actually found.
It is the record of what has been checked — **not** a proof that nothing else
gets through.

Agents run in **auto** permission mode (`permissions.defaultMode`), which is only
safe because the above decides what they may do rather than a prompt for each
command.

## Repository settings this depends on

`main` is protected. Required checks: `static`, `host-tests`, `switch-build`,
`configuration is well-formed`, `merge-gate`. Conversation resolution required.
**No required approving review** — that would make you the bottleneck on exactly
the PRs that already did the work. `enforce_admins: false`, so you can always
merge the enforcement-layer PRs that `merge-gate` deliberately fails.

Auto-merge is enabled at the repository level; without it `gh pr merge --auto`
errors out.

## The configuration is tested

Every way `.claude/` breaks is silent. A skill whose frontmatter does not parse
never loads. A hook whose path is wrong never runs. A guard whose pattern stopped
matching stops blocking. None of it shows in a diff review or turns a build red.

- **`./evals/lint.sh`** — deterministic, free, no model. Also `the test suite -R
  agent.config`, so a worktree sees a break before CI does.
- **`./evals/run.sh`** — one headless session per case in `evals/cases/`, scoring
  what the agent actually answers. Needs `CLAUDE_CODE_OAUTH_TOKEN`.

The eval job runs on **push to `main`**, never on a pull request. What it
evaluates is the instructions an agent loads, and it evaluates them by handing
them to an agent holding the token — on a PR trigger those files are whatever the
branch says they are, and a settings hook is plain command execution. A PR gets
the token-less lint.

## Working in parallel

At most **three worktrees**. The ceiling is not machine capacity; it is how many
streams one person can review properly. Each is fully isolated — its own ports,
compose project, RomM database and `build/`. Only the immutable, expensive things
are shared (`.cache/roms`, `.cache/ccache`), so no agent can corrupt another's
fixtures.

Removing a worktree from the **Orca UI** runs the teardown hook. `orca worktree
rm` does **not** unless you pass `--run-hooks`. Sweep anything left behind with
`./scripts/fleet/reap.sh --yes` — which is what `fleet.sh` does deliberately
rather than passing the flag, for the reason in Stage 6.

## When the loop stalls

| Symptom | Cause | Fix |
|---|---|---|
| `fleet.sh run` opens nothing | the stop file is set | `./scripts/fleet/fleet.sh resume` |
| `fleet.sh status` shows no next issue | everything `ready` is already in flight | merge something, or file work |
| ...and `status` lists the issue you want under "gave up on" | the time-box stopped it, and the fleet will not start it again on its own | `./scripts/fleet/fleet.sh retry <n>` |
| Worktree provisioned, agent idle, nothing in the composer | Orca drafts the issue prompt instead of sending it | `./scripts/fleet/agent-autostart.sh` — `setup.sh` starts the `--watch` form |
| Every hook says "this worktree has no linked issue" | the `orca` CLI on `PATH` cannot find `Orca.app` | nothing — the hooks probe it and fall back. If it persists: `sudo chmod -h 755 /usr/local/bin/orca` |
| `git push` refused, "nothing leaves one of those unreviewed" | the local review is not recorded for this commit | `./scripts/fleet/self-review.sh` — it runs both passes and records the marker |
| `await-review.sh` times out | the review job never ran. Any other reason the wait had — records the gate discounts, a review already handed back, an unpushed worktree — it printed the moment it found it | `gh run list`; check `CLAUDE_CODE_OAUTH_TOKEN` is a repo secret |
| `await-review.sh` exits 2, naming `merge_gate.py` | that file is what decides which reviews count, and it does not import | fix the syntax or the missing name; nothing in the loop can answer until it does |
| `await-review.sh` exits 8, "GitHub says DIRTY" | something merged underneath the branch | rebase, re-run `record-review.sh .autofleet/run/self-review.md`, `git push --force-with-lease` |
| `merge-gate` red on a PR that looks fine | usually the body is missing a review section, the review predates the last push, or a review reporting findings has not been answered | read the check's output; it says which of the seven |
| A PR sits queued and never merges | a required check never reported | `gh pr checks <n>` |
| the test suite reports `rig.smoke` **Skipped** | RomM is not running for this worktree | `./scripts/fleet/compose.sh up -d` |
