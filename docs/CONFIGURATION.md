# Configuration

Everything autofleet knows about your project arrives through four files. The
payload in `scripts/fleet/` knows about none of it, and a change that puts a
project detail in there is the thing that makes the next repo fork this one
(CLAUDE.md, hard rule 2).

| File | Read by | Overwritten on upgrade? |
|---|---|---|
| `.autofleet/config` | every fleet script, via `scripts/fleet/config.sh` | no |
| `.autofleet/setup.sh` | `scripts/fleet/setup.sh`, once per worktree | no |
| `.autofleet/teardown.sh` | `scripts/fleet/archive.sh`, once per removal | no |
| `.autofleet/guard.json` | `.claude/hooks/guard.py`, on every tool call | no |

## `.autofleet/config`

Shell, sourced. `scripts/fleet/config.sh` holds every default with `:=`, so the
precedence is **environment beats this file beats the defaults** — a one-off
`AUTOFLEET_MAX=1 ./scripts/fleet/fleet.sh run --auto` still works. Assign
outright (`AUTOFLEET_MAX=1`) if you want this file to win over the environment
too.

One knob is `=` rather than `:=`, and it says why at its own default:
`AUTOFLEET_TRANSCRIPT_DIR`, where **empty is the off switch**. `:=` substitutes
on unset *or null*, which would hand an explicitly emptied value straight back
the default and make the documented way to turn the cost report off do nothing.

### The dispatcher

| Knob | Default | What it costs to change |
|---|---|---|
| `AUTOFLEET_MAX` | `3` | The ceiling is not machine capacity, it is how many streams one person can review properly. Raising it makes the review queue the bottleneck. |
| `AUTOFLEET_POLL` | `60` | How often the dispatcher re-reads the world, in seconds. Lower burns API quota; higher delays every handoff. |
| `AUTOFLEET_TIMEBOX` | `10800` | How long one issue may hold a worktree. Long enough for a full test run and both review rounds; short enough that an overnight run does not spend the night on the one task that was never going to work. |
| `AUTOFLEET_RM_DEADLINE` | `180` | How long a worktree removal may take before it is reported as refused. |

### The labels

`unblock.yml` maintains the first two and `fleet.sh` reads them; the other three
a person applies. `install.sh` prints the `gh label create` line for all five —
create them before anything can carry one.

**Renaming works for three of the five today.** `AUTOFLEET_FOUNDATION_LABEL`,
`AUTOFLEET_HUMAN_STEP_LABEL` and `AUTOFLEET_PRIORITY_LABEL` are read through the
variable. `AUTOFLEET_READY_LABEL` is not — `ready` is a literal in the
dispatcher's queue filter, and `unblock.yml` writes both `ready` and `blocked` by
name in JavaScript — so renaming that one gives you a dispatcher looking for a
label nothing writes: an empty queue, forever, with nothing on screen saying why.
That is [#57](https://github.com/armaatus/autofleet/issues/57). Until it lands,
keep `ready` and `blocked`.

`AUTOFLEET_READY_LABEL` (`ready`), `AUTOFLEET_BLOCKED_LABEL` (`blocked`),
`AUTOFLEET_FOUNDATION_LABEL` (`foundation`),
`AUTOFLEET_HUMAN_STEP_LABEL` (`needs-human-step`),
`AUTOFLEET_PRIORITY_LABEL` (`priority`).

`priority` is the only one that says *when* rather than *what*, and the only
ordering the tracker cannot derive: an issue carrying it goes to the front of the
ready list, ahead of whatever frees the most other work. It reorders and nothing
more — it cannot start a `blocked` issue, cannot start a `needs-human-step` one,
and does not lift a foundation hold. Label several and the ordinary ordering
decides between them. `fleet.sh status` marks the rows that carry it, so a queue
that looks reordered says why.

One consequence worth knowing before you use it, and it is larger than a
reordering. A `priority` issue can start ahead of a `ready` foundation issue,
and while it runs the foundation issue waits — a foundation issue will not join
worktrees already in flight. The part that costs: the scan **stops at the first
foundation issue** once anything is in flight, so every ready issue behind it is
skipped for that pass as well, whether or not it has anything to do with it.

The fleet therefore runs at **one** worktree for the priority issue's whole
time-box, and at one again while the foundation issue lands alone. Nothing about
"a foundation issue lands alone" is weakened, and what depends on it is `blocked`
either way — but the dependants are not what stalls, so that is the wrong thing
to be reassured by.

Measure that against the right baseline. Those dependants are also what make the
foundation issue sort to the *front* of an unlabelled queue — the second sort key
is how many issues it frees — so it would have taken a solo time-box first
anyway. The label therefore adds one solo time-box rather than costing the
difference between a full fleet and one worktree; `docs/WORKFLOW.md` works the
arithmetic through. If another time-box at one worktree is not what you meant,
the foundation issue is the one to label.

### The review

Two reviews gate a pull request, and only the second one is configurable here.
The first is the local `/code-review` and `/mattpocock-skills:code-review` pass
the author runs before pushing — `guard.py` refuses the push without it, and
`merge_gate.py` refuses to merge a PR whose body does not name both. That is
required in every mode.

The second is the **independent** review: a verdict from a context that has not
seen the conversation which produced the diff. `AUTOFLEET_REVIEW_MODE` says where
it runs.

| Knob | Default | Notes |
|---|---|---|
| `AUTOFLEET_REVIEW_MODE` | `github` | `github` or `local`. |
| `AUTOFLEET_REVIEW_CMD` | `claude` | What `local` mode runs, with `-p` and a fixed tool allowlist. A command on `PATH`, so a wrapper can point it at another model or another account. |
| `AUTOFLEET_REVIEW_TIMEOUT` | `1800` | Seconds one local review may run before it is killed and the PR left for the next poll. The wall-clock backstop for a wedged process. |
| `AUTOFLEET_REVIEW_MAX_TRIES` | `3` | How many attempts one head may get that end with **no verdict** — a reviewer that ran and submitted nothing, or one killed at the timeout. A run that never reached a reviewer (the fleet was stopped, `gh` would not answer, the command is not on `PATH`) does not spend one. A reviewer that runs and returns no verdict is retried, because that is usually transient — unbounded, it is a full-budget reviewer every poll against a head that will never get one. At the cap the dispatcher says so, names the transcript, and stops; a push starts the count again. **Must be a positive whole number: a value that is not is refused, and because this file is sourced the refusal ends every fleet command that reads it, `stop.sh` included.** A cap that is silently absent is the failure the check exists to prevent, so it refuses rather than warns. |
| `AUTOFLEET_REVIEW_MAX_ROUNDS` | `4` | **`local` mode only** — `review_open_prs` returns early in `github` mode, so there are no dispatcher-started reviewers to cap. How many reviews one **pull request** may accrue before the dispatcher stops starting them and asks a person. A different question from `AUTOFLEET_REVIEW_MAX_TRIES`, which is per *head* and counts only reviewers that submitted **nothing** — a reviewer that submits findings clears that one, so a PR whose every round produces findings was bounded by nothing at all. `AWAIT_REVIEW_MAX_ROUNDS` bounds the *agent's* side and only while the agent is alive; a PR was measured collecting a fourth review after its agent had already stopped at that cap. The count lives in `<pr>.rounds` under the fleet's `reviewing/` directory, counts reviews **submitted** across every head, and survives `stop.sh` — what it counts belongs to the pull request, not to one dispatcher's run. Default is above the agent's `3` on purpose: two caps at the same number is one of them being dead code. **Must be a positive whole number**, refused the same way and for the same reason as its neighbour. |
| `AWAIT_REVIEW_MAX_ROUNDS` | `3` | The **agent's** cap, and the only one of the three that is not `AUTOFLEET_`-prefixed — it is read by `await-review.sh` alone and has never had a row here. On the fourth call for one PR the script exits 5 rather than waiting, and the agent stops and says what is unresolved. Per *worktree*, in `.autofleet/run/review-rounds`, and counted only on the path that actually read a review back on this worktree's head — so it undercounts against the reviews a PR really had, deliberately: three CI timeouts in a row must not exhaust the cap without a finding having been seen. That undercount is why `AUTOFLEET_REVIEW_MAX_ROUNDS` exists as well; the two are not redundant. **Must be a positive whole number: a value that is not is refused, and `await-review.sh` exits 2 rather than waiting** — `[ 4 -gt three ]` returns 2, which reads as false, so an unvalidated cap never fires and the agent laps forever. Empty means unset, and the default applies. |
| `AUTOFLEET_REVIEW_MAX_TURNS` | `80` | The reviewer's turn budget, passed as `--max-turns`. The bound it can *see* and spend against, which is what makes "submit before you run out" a budget rather than a hope. `claude-review.yml` grants the same number. |

**`github`** — [`claude-review.yml`](../.github/workflows/claude-review.yml)
submits it, from that workflow's own account. It needs a
`CLAUDE_CODE_OAUTH_TOKEN` secret on the repository; mint one with
`claude setup-token`.

> Without that secret the job **no-ops with a notice and a green check**, and
> because `merge_gate.py` requires an independent review on the current head,
> every pull request the fleet opens then blocks forever on a review that cannot
> arrive. The agents wait out `await-review.sh`'s 45-minute deadline, three
> times, and the backlog stops. It is the loudest possible consequence of the
> quietest possible failure, which is why `fleet.sh status` names the mode on its
> first screen.

**`local`** — the dispatcher runs the reviewer on this machine
([`scripts/fleet/review.sh`](../scripts/fleet/review.sh), briefed by
[`.claude/agents/reviewer.md`](../.claude/agents/reviewer.md)) and submits with
`gh pr review`. Same policy, same `REVIEW.md`, same trailers.

#### What `local` gives up, exactly

The reviewer signs in as whoever `gh` is logged in as, which is normally the same
account that opened the pull request. So independence stops being something
GitHub can attest to and becomes something the fleet asserts:

|  | `github` | `local` |
|---|---|---|
| Reviewer's context | fresh | fresh |
| Reviewer's identity | a different account | **the author's account** |
| What proves it | GitHub's own author field | a marker in the review body |
| `--request-changes` | available | **refused by GitHub** — see below |
| Reviewer's credential | an Actions token, scoped by the job's `permissions:`, in a container that is then destroyed | **your own `gh` login**, reaching every repo and org that account can |
| Inline comments | yes (`gh api` is granted) | no — `gh api` is deliberately **not** granted, so findings go in the body |
| The round-three floor | **never fires** — nothing tells the reviewer which round it is, and `REVIEW.md`'s fallback is "treat it as round one" | fires — `review.sh` passes `Review round: N` from `<pr>.rounds` |
| `AUTOFLEET_REVIEW_MAX_ROUNDS` | **not applied** — `review_open_prs` returns early unless the mode is `local`, so the dispatcher starts no reviewers to cap | applied |

The last two rows are new and point the other way from the rest: this is `local`
having something `github` does not. Both belong here for the reason the section
already gives about `--request-changes` — a control that is documented and
silently inapplicable is worse than one that is absent. `REVIEW.md`,
`.claude/agents/reviewer.md` and [WORKFLOW.md](WORKFLOW.md) all state the floor
without a mode qualifier, because a reviewer reads them without knowing which
mode started it; the fallback is what makes that safe, and this table is where
the difference is recorded.


**The reviewer runs as you.** That is the row above with the widest blast
radius, and it is not narrowed by `guard.py`: the reviewer runs from the repo
root precisely so that the fleet-worktree rules do not apply to it, which is what
lets it submit at all. So the ceiling on what it can do is its **tool allowlist**,
and that is why `Bash(gh api:*)` — which `claude-review.yml` does grant — is
withheld here. What is left can read the tree, read the pull request, and submit
one review. It is an agent reading a diff written by somebody else; the prompt
hardening in its brief is a mitigation, not a boundary, exactly as with the guard
above.

**`--request-changes` does not exist in `local` mode.** GitHub will not accept
`CHANGES_REQUESTED` on a self-authored pull request (*"Review Can not request
changes on your own pull request"*), and here the reviewer is the author's
account. So `merge_gate.py`'s "the latest review still requests changes"
condition is unreachable, and `<!-- review-findings: N -->` is the only lever
holding the branch. It is enough — any `N` above zero blocks the merge until the
author answers — but a control that is documented and silently inapplicable is
worse than one that is absent, so it is written down here, in
[REVIEW.md](../REVIEW.md) and in the reviewer's brief.

`<!-- review-important: M -->` rides alongside it and is **not** a second lever:
it holds nothing and releases nothing. It exists because the verdict type used
to carry severity and in this mode cannot, so with `N` alone every reader
downstream saw "five nits" and "one data-loss bug" as the same integer. What `M`
buys is the *instruction*: at `0`, `await-review.sh` tells the agent that
`answer-review.sh` discharges the hold with no commit, where a fix would move the
head and buy the next round. Omitting `M` is read as "did not say", never as
zero. This was found by the
local reviewer being unable to submit its own verdict.

`merge_gate.independent_reviews()` normally discards anything the PR's author
submitted. In `local` mode it accepts one **iff** the body carries
`<!-- independent-review: local <head-sha> -->` for the current head. That is a
checklist gate, exactly as `record-review.sh` is, and three things keep it
meaningful:

1. **Opt-in per repository.** The knob lives in `.autofleet/config`, and
   `install.sh` normalises a freshly seeded config back to `github` so no host
   project inherits the weaker mode by accident.
2. **Read from the base ref.** `merge-gate.yml` sparse-checks-out
   `.autofleet/config` at `pull_request.base.sha`, so a PR cannot switch its own
   repository into the weaker mode as part of the change that mode is judging.
3. **Out of the ordinary reach of the author.** `guard.py` refuses, from a
   fleet-owned worktree, every way to submit a review it can recognise:
   `gh pr review`, `gh api .../pulls/N/reviews`, the `addPullRequestReview` and
   `submitPullRequestReview` GraphQL mutations — and any `gh api` carrying a
   body it cannot read (`--input`, `@file`), because a payload this hook cannot
   inspect is one it cannot judge.

   *Recognise* is the operative word, and it is not a synonym for *all*. This
   list has grown twice, each time because a review found a spelling that walked
   past it — first the REST name, then GraphQL, then a body in a file. Treat it
   as the set of mistakes caught so far, not as a proof. The dispatcher runs the reviewer from the repo root, which is not a
   fleet worktree, which is how it still submits.

   *Reach*, not *possibility*: this is a hook over a command line, not a
   capability boundary. It stops an agent that drifts into reviewing itself and
   an agent that follows an instruction planted in a diff. It does not stop an
   agent that sets out to defeat it, and the summary below says so. The first
   two spellings shipped guarded; the third did not, and the independent review
   of that change found it.

`local` **adds** a way to satisfy the requirement; it never removes the strong
one. A review by a different account still counts, with no marker at all.

The honest summary: `local` protects against an author's blind spots, which is
what the second opinion is actually for. It does not protect against an author
determined to forge one. If you need that, keep `github`, or give the reviewer
its own account and log `gh` in as that.

### The handoff note

One session covers the plan, the implementation, both self-review passes, the
push, the PR and up to three review rounds, inside one `AUTOFLEET_TIMEBOX` and
one context window. When the dispatcher interrupts that worktree, or
`./scripts/fleet/fleet.sh retry N` hands the issue back, the next attempt used
to begin from the issue body alone and re-derive from the files every decision
the first one made. `scripts/fleet/handoff.sh` is the note that carries those
decisions across, and the opening brief asks for it in both halves — when the
work is put down, and at the push and after every review round:

```bash
./scripts/fleet/handoff.sh write 42 --stdin <<'NOTE'
...
NOTE
./scripts/fleet/handoff.sh          # print this worktree's note
```

It holds the decisions taken and why, the files touched, what each review round
said and how it was answered, and what is still open — not the plan, which is in
the PR body, and not the diff.

Two things read it back. `issue-command.sh` prints it **between the issue's
spec and the brief** in the next session **in that worktree** — which is the
case it is for and the one that always works; the `resumed` test phase asserts
that ordering, so a session gets the spec, then what the last attempt left, then
its marching orders. `./scripts/fleet/fleet.sh retry N` names it by absolute path when
you hand the issue back, so a second worktree opened alongside a first one still
standing can be pointed at it. The dispatcher's own opening prompt names it too,
in a narrower state than either — `handoff_note_for` in `scripts/fleet/fleet.sh`
is where that is argued, and `retry` is the line to read.

**It lives at `.autofleet/run/handoff-<issue>.md`, and it dies with the
worktree.** That directory is gitignored and per worktree: the note survives a
session restart *inside* the worktree, which is the case it exists for, and it
goes when the worktree is reaped. It is not durable storage and nothing backs it
up. That is deliberate rather than unfinished — a note that outlived its
worktree would be read by an attempt working from a different tree, telling it
which files were touched in a tree it cannot see.

| Knob | Default | Notes |
|---|---|---|
| `AUTOFLEET_HANDOFF_MAX_WORDS` | `300` | How long the note may be. Over it the script **refuses and changes nothing** rather than truncating: a note cut off at the sentence that said what is still open reads exactly like one where nothing was. Unbounded, the note grows into a second spec the next attempt reads in full before its first edit, which is the cost it exists to remove. `0` turns the cap off. **Must be a whole number**: a value that is not is refused, and because this file is sourced the refusal ends every fleet command that reads it — a non-number would otherwise make the comparison error out, the cap never fire, and the guard be absent with nothing on screen saying so. |

### What the fleet keeps

Every store under `$FLEET_DIR` only ever grew until these two knobs arrived, and
the cost is not the bytes: stale state gets read as current. A transcript named
for a head nobody is reviewing is a file the next reader opens looking for an
answer. Set either to `0` to keep everything, which is what a host project
debugging its own reviewer wants.

| Knob | Default | Notes |
|---|---|---|
| `AUTOFLEET_KEEP_REVIEWS` | `3` | Reviewer transcripts kept **per open pull request**, and the off switch for the `reviewed-<sha>` sweep too, so `0` means every piece of review state the dispatcher would otherwise delete. |
| `AUTOFLEET_LOG_MAX_BYTES` | `1048576` | Bytes of `fleet.log` kept before it rotates to `fleet.log.1`. **One** generation, because the point is a bound and two files at the cap is twice the cap. |

**What goes, and when.** Older transcripts for an open PR go; every transcript
for a PR that is no longer open goes regardless, because a review of a closed PR
is answering a question nobody is asking. Never on the pass the PR drops off the
open list, though, and never while a reviewer for it is still writing: the sweep
keeps one bookkeeping file per closed PR, `reviews/.closed-<n>`, recording that
it was already seen closed on an earlier pass, and collects that file as soon as
the transcripts it tracks are gone.

**What it costs.** `review_open_prs` runs the sweep from the open list it already
has, plus **one `gh pr view <n> --json state` per candidate pull request per
pass** — per pull request, not per transcript, and only after a whole grace pass.
The open list is `--author "@me"`, which is right for deciding whom to review and
wrong for "is this PR still open": on a host whose worktrees open PRs under a
different account than the dispatcher's `gh` login, absence from it would mean
every PR looked closed. Anything but a confident `CLOSED`/`MERGED` keeps the file.
An `OPEN` answer returns the PR to the open list for the rest of that sweep, so
its transcripts are capped like any other open PR's rather than accumulating with
nothing to trim them — and drops the `.closed-<n>` marker, so the question is
asked again on the pass after next rather than on every one. The sweep says how
many it took.

**The rotation** is `mv` rather than truncate-in-place, and **not while a
reviewer is running** — `review.sh` is spawned with `>>` on `fleet.log` and holds
the inode for up to `AUTOFLEET_REVIEW_TIMEOUT`, so rotating under it sends its
output to a file nobody reads and the next rotation unlinks what it is still
writing. The dispatcher's own writes are `tee -a`, fresh per call, and follow a
rename without noticing. So the cap is a bound the fleet reaches **between**
reviews, not a hard ceiling: on a busy fleet the log can sit above it until the
reviewers finish. If the rotation cannot happen at all — a read-only state
directory, an undeletable `fleet.log.1` — it says so once per dispatcher, and
again after a rotation that works.


### What a run costs

`./scripts/fleet/fleet.sh cost` reports what each issue's worktree spent, read
back out of the agent CLI's own session transcripts — no extra instrumentation,
because the CLI already wrote the answer.

```
issue  sessions  input  output  cache read  cache write
   48         3    170  23,340   2,898,820      102,120
   52         1     48  24,838   2,024,487       89,837
-----  --------  -----  ------  ----------  -----------
total         4    218  48,178   4,923,307      191,957
```

`--json` prints the same figures for something that is not a person, which is
the point: these numbers are only useful compared across runs.

| Knob | Default | Notes |
|---|---|---|
| `AUTOFLEET_TRANSCRIPT_DIR` | `~/.claude/projects` | Where the agent CLI writes one JSONL per session, under `<root>/<cwd-slug>/<session-id>.jsonl`. Set it **empty** to turn the report off — one explanatory line, exit 0. |

It moves the **path**, not the format. `cost.sh` reads a fixed entry shape
(`type: assistant`, `message.usage`, the four token keys) and a fixed slug rule,
so a host whose CLI writes that shape somewhere else points this at it — and a
host whose CLI writes something else entirely sets it empty rather than getting
a report of zeros.

`scripts/fleet/cost.sh`'s header is the authority on how the report reads a
transcript; this section describes the same rules for whoever is setting the
knob, and if the two disagree, this one is wrong.

**The four figures are never added together.** A cache read is roughly a tenth
of an input token, so a run that looks expensive on `input` may be almost
entirely cache, and one total would hide exactly the difference the report
exists to show.

**What ties a session to an issue** is the worktree path. The slug is the
absolute working directory with every non-alphanumeric character turned into
`-`, truncated at **200** characters with a hash of the path appended past that
— a slug over the cap is matched on its prefix, and a prefix that matches more
than one directory identifies none of them and is reported rather than guessed.
`own()` records each issue's path under `$FLEET_DIR/ran/<issue>` —
*appended*, so an issue that `retry` ran twice is measured across both
worktrees, and deliberately *not* cleared when the worktree is released, or the
report would empty itself exactly when a run finishes. One short file per issue
the fleet ever starts.

**Subagent transcripts count.** A subagent writes its own file under
`<session-id>/subagents/`, and this repo mandates four of them per issue — the
verifier, the researcher and two review passes. They are folded into the four
token figures; `sessions` counts the top-level sessions only, so it stays the
number of times an agent *produced* something in that worktree — a session
interrupted before its first assistant message carries no `usage` and is not
one.

**It never fails a run.** No transcript root, a root that is not there, a
worktree already reaped, an entry with no `usage`, a half-written last line in a
transcript a live agent is still appending to: each costs one line on stderr and
exits 0. Explanations go to stderr in both shapes, so `--json` on stdout stays
machine-readable.

**What it does not see.** Only sessions whose working directory was the worktree
itself. A reviewer run from the main checkout (`AUTOFLEET_REVIEW_MODE=local`)
lands under the main checkout's slug, not the worktree's, so its tokens are not
in that issue's row.

### Per-worktree isolation

A worktree's identity is a pure function of its absolute path: a slug, an offset,
and a project name. Teardown **recomputes** it rather than reading `.env` back,
because `.env` is generated by a hook that is itself allowed to fail half way,
and a port nothing can re-derive is a port nothing can release.

| Knob | Default | Notes |
|---|---|---|
| `AUTOFLEET_PROJECT_PREFIX` | `af` | Must be unique to this project on this machine: `reap.sh` sweeps stacks matching it whose worktree is gone. |
| `AUTOFLEET_PORTS` | *(empty)* | `name:base` pairs, e.g. `API:21000 PROXY:23000`. Each worktree gets `base + offset`, written to `.env` as `NAME=<port>`. |
| `AUTOFLEET_PORT_SPAN` | `2000` | The modulus the offset is taken over, and therefore the width of each range above. Bases must be at least this far apart. |
| `AUTOFLEET_COMPOSE_FILE` | *(empty)* | Empty means this project runs no containers, and teardown skips docker entirely. |
| `AUTOFLEET_COMPOSE_DOWN_ARGS` | *(empty)* | Your `--profile` flags. **Getting this wrong leaks**: `down` only touches services whose profile is active, so an inactive one survives teardown, comes back under `restart: unless-stopped`, and holds a port with no directory left to identify it by. |

### The rest

`AUTOFLEET_RUNNER` (`orca`) — see [RUNNERS.md](RUNNERS.md).
`AUTOFLEET_SETUP_HOOK` / `AUTOFLEET_TEARDOWN_HOOK` — paths to the two hooks.
`AUTOFLEET_TEST_COMMAND` — quoted into the agent's opening prompt, so it names
the command your project actually runs rather than one autofleet guessed.
`AUTOFLEET_NOTIFY_TITLE` — the title on the macOS notifications the dispatcher
posts.
`AUTOFLEET_DIR` (env only, `~/.autofleet`) — where `STOP`, `DRAIN` and the owned-
worktree registry live. Outside every worktree on purpose: a stop that only some
processes can see is not a stop.

## `.autofleet/setup.sh`

Runs once per worktree, from the repo root, with `.env` already exported and
`FLEET_OFFSET` available. **Its exit status is provisioning's exit status** — a
non-zero exit fails the worktree loudly rather than handing an agent a broken
rig, which is the failure mode `wait-for-setup` exists to prevent.

This is where containers, fixtures, a build, a venv, seeded data all go.

## `.autofleet/teardown.sh`

Runs before the stack comes down, from the repo root, when a worktree is removed.
Never fatal: the runner is removing the worktree either way, and a hook that
exits non-zero must not stop the stack removal, which is the part that leaks if
it is skipped.

## `.autofleet/guard.json`

What `guard.py` refuses to write in **this** repo, over and above its universal
rules (merging a PR, force-pushing the default branch, editing `unblock.yml`,
editing `.env`, and — in a fleet worktree only — editing the hooks themselves).

```json
{
  "protected_paths": [
    {"path": "server/contract/captures/",
     "tail": "captures/",
     "reason": "the pinned API contract a test diffs a live probe against"}
  ],
  "secret_suffixes": ["/config.ini"],
  "secret_contains": ["/token.dat"],
  "secret_tails":    ["token.dat", "config.ini"]
}
```

`reason` is the whole value of a `protected_paths` entry: "blocked" with no *why*
sends the agent looking for a way around it. `tail` is how a relative path after
a `cd` is still recognised — suffix-matching a distinctive tail is imperfect, and
the module docstring says so.

A malformed file is **fatal**, not ignored. A guard that silently falls back to
"protect nothing" on a typo reports success on every write it was installed to
stop.

## Checking your work

```bash
./evals/lint.sh                                # is the agent config well-formed
python3 .claude/hooks/guard.py --selftest      # do the guards still guard
python3 .github/scripts/merge_gate.py --selftest
```
