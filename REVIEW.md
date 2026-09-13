# Review policy

What `/code-review` looks for on this repo, what counts as **Important** rather
than a **Nit**, and what it should not report at all.

CLAUDE.md makes `/code-review` on your own branch a required step before opening
a PR, with the findings in the PR body. This file is what makes those findings
comparable between agents and between PRs: without it, three worktrees produce
three different reviews of three different things, and a human cannot tell a
serious finding from a preference.

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
for a diff. Name the nits **in the body**, not as inline threads, say plainly
that they belong in a follow-up issue rather than in this pull request, and
report the real counts: `review-important: 0`, and `review-findings: N` with `N`
the number of nits you actually named.

**Do not report `0` findings to end the round.** `0` releases the gate outright,
and auto-merge is armed from the moment the pull request opens — the branch
would land before the follow-up issue the paragraph exists to become was ever
filed, which is the opposite of the trade this rule is making. The real count
holds the branch until the author answers, and the answer is where the issue
gets named. Answering costs no commit, so the round is still not spent.

Body and not threads for the same reason: an unresolved thread holds the branch
regardless of either count, and `answer-review.sh` does not close threads. A nit
left as an open thread costs the author exactly what a fix would have.

This exists because the loop has no other floor. A reviewer can always name one
more assertion, an author can always add one, and a fix moves the head, and a
head move invalidates the review that asked for it, which buys another round.
Eight rounds on #79 converged on behaviour after two and spent six more on the
same finding one level further down; every one was correct. Round one and round
two are unchanged, because behaviour findings arrive early and this rule must
not suppress them.

`scripts/fleet/review.sh` tells you which round you are on. If it did not, treat
it as round one.

## Say how many findings you left

Every review of a pull request ends its body with these lines, **in this
order** — the same block `scripts/fleet/review.sh` and `claude-review.yml`
dictate verbatim, because a policy that disagrees with the prompt is a policy
that gets a real review discarded:

```
<!-- review-important: M -->
<!-- review-findings: N -->
```

and, under `AUTOFLEET_REVIEW_MODE=local` only, one more naming the commit the
review judged:

```
<!-- independent-review: local <head-sha> -->
```

Those three are the whole list. Nothing else follows them.

That is what makes a review count at all in that mode. This file used to forbid
any line following the count, which forbade that marker — so a reviewer obeying
the policy it is told to read first and in full omitted it, `merge-gate`
discarded a review that had been written, read and submitted, and the pull
request blocked on a review that already existed. Found by the independent
review that hit it. See
[docs/CONFIGURATION.md](docs/CONFIGURATION.md#the-review); in the default
`github` mode there is no local-review marker, and `review-findings` is the last
line.

The list grew from one to two for the same reason it grew from zero to one, and
the rule that survived both is the one worth keeping: **this file names every
trailer that is allowed, and never says how many there are anywhere else.** A
count stated twice is a count that goes stale in one of the two places.

`N` is Important plus Nit, across all three passes, inline comments included.
`0` means the review found nothing. `M` is the Important subset of `N`, counted
the same way; `0` means everything you found was a nit.

**`M` does not decide whether the branch merges.** `N` above zero holds the pull
request until its author answers, whatever `M` says. What `M` buys is that the
author is told the answer may be *words*: a nit answered with
`./scripts/fleet/answer-review.sh` costs no commit, and a nit answered with a
commit moves the head, invalidates this review, and buys the next round. Three
pull requests were measured sitting on that difference with nobody having run
that script once.

Omitting `M` is not the same as writing `0`. A review that does not say is read
as not having said, which is the behaviour that predates the trailer — held
until answered, exactly as before.

It is an HTML comment, so it does not show up in the rendered review. It exists
because `merge-gate` cannot otherwise tell a review that found five nits from
one that found nothing: REVIEW.md sends anything Important to
`--request-changes` and everything else to `--comment`, so both of those are a
COMMENTED verdict and both satisfy every other condition the gate has.

**Under `AUTOFLEET_REVIEW_MODE=local` the count is the only lever there is.**
GitHub refuses `CHANGES_REQUESTED` on a self-authored pull request — "Review Can
not request changes on your own pull request" — and in that mode the reviewer
signs in as the author's account. So `--request-changes` is not a route that
exists there; use `--comment` for every verdict and let `N` hold the branch. A
reviewer that tries the other one gets a non-zero exit on its last action and may
end having submitted nothing, which is the worst outcome this file has.

`gh pr merge --auto` is armed when the PR is opened -- deliberately, so a
finished PR does not sit green with nobody left to merge it -- and this review
runs afterwards. Get the number wrong in the `0` direction and the branch merges
while its author is still fixing what you found. Four PRs went in that way.

Leaving the line out is safe: the PR is then held as though findings were left,
and its author has to answer a review that said nothing. Write the line.

## Do not report

- Anything CI already enforces: compiler warnings, `core/` include hygiene,
  shell scripts that do not parse, an unformatted Python file, artifact shape.
  CI going red says it better and does not need a human to read it.
- Comment density or naming that matches the surrounding code. CLAUDE.md asks
  for consistency with what is there, not for a house style this file does not
  define.
- Generated or vendored trees: `build/`, `.venv/`, `server/testing/library/`,
  `.cache/`.
- `server/contract/captures/` content. It is a recorded snapshot of a real
  server; it is not written by hand and reviewing its style is meaningless.
  A *change* to it, on the other hand, is Important and belongs in pass 3.

## What findings do and do not do

No review here approves, and no agent merges its own work (CLAUDE.md, "Finishing
a task"). Findings do not decide whether a PR is good enough; a human reading
them does.

They do hold the branch, though, and that is not the same thing. `merge-gate`
refuses a PR while a `--request-changes` is standing, while a review thread is
open, and while a review reporting findings has not been answered by its author
-- `./scripts/fleet/answer-review.sh "<what you did>"` is that answer, and "I am
not doing this, because" is as good an answer as a fix. What none of that does
is judge the finding; it only makes sure somebody read it before the code went
in.

When a review flags the same mistake twice across PRs, the correction goes into
CLAUDE.md as part of that review. That is how this stops being a review finding
and starts being something the next session already knows.
