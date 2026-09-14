# Review policy

What `/code-review` looks for on this repo, what counts as **Important** rather
than a **Nit**, and what it should not report at all.

CLAUDE.md requires `/code-review` on your own branch before a PR, findings in
the body. This file makes those findings comparable between agents and between
PRs: without it, three worktrees produce three different reviews of three
different things, and a human cannot tell a serious finding from a preference.

Read this before reviewing. If you are the author, read it before you finish --
a finding you can predict is one you can avoid.

## The passes

Run all three. Report them separately.

### 1. Correctness

Bugs, logic errors, and the failure paths this project cares about most:

- **The save guarantee.** Any path that overwrites a save file backs it up first
  and writes atomically. An interruption anywhere in the sequence leaves either
  the old file or the new one. A failed backup aborts the write. This is hard
  rule 2, and a breach is always Important.
- **Network calls.** Every one has a timeout, is safe offline, retries with
  backoff, and never blocks boot. A call missing a timeout is Important.
- **Conflict resolution.** The server is the source of truth. Local-wins
  behaviour that is not explicitly specified in the issue is a bug.
- **Partial state.** What is left on disk when the process dies here? A
  half-written state.db, a `.tmp` beside a save, or a token file with no
  matching device record is Important.
- **Integer and buffer handling** in anything that parses a server response.

### 2. Portability and platform rules

- Nothing in `core/` includes a host-only or libnx header (hard rule 4). CI
  catches the mechanical form; report the ones it cannot -- a platform
  assumption smuggled in as a type, a path separator, an endianness assumption,
  a `long` that is not the same width on aarch64.
- Nothing new is on the boot path.
- No production system is touched, and no hard rule in CLAUDE.md is broken. A test or
  script that reaches a non-loopback address is Important -- `policy.loopback_only`
  exists for this and a finding here means it was worked around.
- No secrets in the tree (hard rule 5).

### 3. Compliance with the spec

- Against the issue: does the diff do what **Scope** asked, and does it satisfy
  **Acceptance**? Name anything in the diff that is outside Scope, and anything
  in Acceptance the diff does not cover.
- Against the PR body's `## Plan`: where the implementation departed from it, is
  the departure written down? An undocumented one is Important; a documented one
  is fine.
- Is there a test that would have failed before this change? Name it. Its
  absence is Important regardless of how green the suite is.
- Did the work invalidate an issue -- any issue -- that has not been edited? That
  is Important: those bodies are the only channel between parallel worktrees.
- **A fleet PR body carries its `fleet.sh cost` figure.** The ceilings bound the
  text; that number says whether the run got cheaper. Missing, it is a Nit.

## Important vs Nit

**Important** is reserved for a finding that would break behaviour, destroy or
corrupt a save, leak a secret, breach a hard rule, break the build on either
target, or leave the tracker saying something untrue.

Everything else is a **Nit**: naming, comment wording, ordering, a clearer
formulation of something already correct.

Report at most **five nits**, and summarise the rest as a count. A review whose
signal is buried in twenty preferences costs more attention than it saves.

## A late round with no Important finding files issues, not findings

From **round three onward**, a review that finds nothing Important stops asking
for a diff: name the nits in the **body**, not as threads, say they belong in a
follow-up issue, and report `review-important: 0` with a real
`review-findings: N`.

**Not `0` findings** — `0` releases the gate and the branch lands before the
issue exists. Rounds one and two are unchanged. `review.sh` names the round;
absent one, treat it as one. Why, in [docs/WORKFLOW.md](docs/WORKFLOW.md).

## Say how many findings you left

Every review ends its body with these lines, **in this order** — the block
`review.sh` and `claude-review.yml` dictate verbatim, because a policy that
disagrees with the prompt gets a real review discarded:

```
<!-- review-important: M -->
<!-- review-findings: N -->
```

and, under `AUTOFLEET_REVIEW_MODE=local` only, one more naming the commit the
review judged:

```
<!-- independent-review: local <head-sha> -->
```

Nothing else follows them.

That marker is what makes a review count at all in that mode; `github` mode has
none ([docs/CONFIGURATION.md](docs/CONFIGURATION.md#the-review)).

**This file names every trailer that is allowed, and never says how many there
are anywhere else.** A count stated twice goes stale in one of them.

`N` is Important plus Nit, across all three passes, inline comments included;
`0` means nothing found. `M` is the Important subset of `N`.

**`M` decides nothing about merging** — `N` above zero holds the branch either
way; see below. Omitting `M` reads as "did not say", never as zero, so write it
even when `M` equals `N`.

They are HTML comments, invisible in the rendered review. They exist because
`merge-gate` cannot otherwise tell five nits from nothing at all: both are a
COMMENTED verdict, and both satisfy every other condition it has.

**Under `AUTOFLEET_REVIEW_MODE=local` the count is the only lever there is.**
GitHub refuses to *request changes on your own pull request*, and in that mode
the reviewer signs in as the author's account — so use `--comment` for every
verdict and let `N` hold the branch. A reviewer that tries the other route gets
a non-zero exit on its last action and may end having submitted nothing.

`gh pr merge --auto` is armed when the PR opens and this review runs afterwards,
so a wrong `0` merges the branch while its author is still fixing what you
found; four PRs went in that way. Leaving the line out is safe — the PR is held
as though findings were left. Write the line.

## Do not report

- Anything CI already enforces: compiler warnings, `core/` include hygiene,
  shell scripts that do not parse, an unformatted Python file, artifact shape.
  CI going red says it better, and says it without a reader.
- Comment density or naming that matches the surrounding code. CLAUDE.md asks
  for consistency with what is there, not for a house style this file does not
  define.
- Generated or vendored trees: `build/`, `.venv/`, `server/testing/library/`,
  `.cache/`.
- `server/contract/captures/` content. It is a recorded snapshot of a real
  server; it is not written by hand and reviewing its style is meaningless.
  A *change* to it, on the other hand, is Important and belongs in pass 3.

## What findings do and do not do

No review here approves, and no agent merges its own work — the brief's step 4
states that rule, and `guard.py` refuses the command either way. Findings do not
decide whether a PR is good enough; a human reading them does.

They do hold the branch, though, and that is not the same thing. `merge-gate`
refuses a PR while a `--request-changes` is standing, while a review thread is
open, and while a review reporting findings has not been answered by its author
-- `./scripts/fleet/answer-review.sh "<what you did>"` is that answer, and "I am
not doing this, because" is as good an answer as a fix.

That answer costs **no commit** — which is what `review-important: 0` is for:
a fix moves the head and buys the next round; words do not.

When a review flags the same mistake twice across PRs, the correction goes into
CLAUDE.md as part of that review. That is how this stops being a review finding
and starts being something the next session already knows.
