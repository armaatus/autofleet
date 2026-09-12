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
[REVIEW.md](../REVIEW.md) and in the reviewer's brief. This was found by the
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
