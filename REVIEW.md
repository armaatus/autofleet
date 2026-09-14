# Review policy

What the independent review looks for, which findings **block a merge** and
which do not, and what it should not report at all.

The pull request arrives already reviewed: step 3 of the brief runs both
self-review passes and their findings are in the body. This review is the one
from a context that has not seen the conversation which produced the diff,
because an author reviewing its own work shares its blind spots.

**It runs once.** One review per pull request, at PR-open, on the head the PR
opened with. What follows is at most two **validations** — a different job, with
a different brief ([`.claude/agents/validator.md`](.claude/agents/validator.md)),
asking only whether these findings were addressed and whether the commits
answering them broke anything.

That is the shape, and it replaced a loop bounded at four reviews per pull
request that routinely spent all four. Every answer to a finding was a commit,
every commit moved the head, and a head move invalidates the review that asked
for it — so the reviewer read the whole diff again and found one more thing a
level down. #86 burned four reviews without one ever judging the commit that
merged. Reviewing a branch four times is not four times the assurance; it is the
same review of four different commits.

So this review is the only one. Read this file before reviewing. If you are the
author, read it before you finish — a finding you can predict is one you can
avoid.

## The dimensions

Evaluate all seven. Report only what you found; a dimension with nothing in it
gets one line or none.

1. **Architecture and design** — separation of concerns, modularity, coupling,
   whether abstractions are at a consistent level, whether the design holds at
   the size this will actually reach.
2. **Code quality and maintainability** — readability by someone with no AI
   assistance and no context, naming, unnecessary complexity, duplication that
   should be extracted, error handling, and whether comments explain *why*.
3. **Impact and breaking changes** — every usage of a changed interface found
   and updated, backward compatibility, migrations that are safe and reversible,
   consumers of a changed API accounted for, downstream effects considered.
4. **Testing** — critical paths and edge cases covered, tests meaningful and
   independent, failure cases tested. **Is there a test that would have failed
   before this change?** Name it. Its absence is Important regardless of how
   green the suite is.
5. **Performance** — algorithmic complexity at the expected data size, query
   patterns and N+1s, resource usage, whether long-running work blocks something
   it should not.
6. **Security** — input validation, authentication and authorisation, exposure
   of sensitive data, injection, and dependencies.
7. **Project standards and spec** — the hard rules in `CLAUDE.md`; the issue's
   **Scope** and **Acceptance**, naming anything in the diff outside Scope and
   anything in Acceptance the diff does not cover; the `## Plan` section, where
   an undocumented departure from it is Important and a documented one is fine;
   and whether the work invalidated an issue — any issue — that has not been
   edited, which is Important because those bodies are the only channel between
   parallel worktrees.

**A fleet pull request carries its `fleet.sh cost` figure.** The ceilings bound
what a run reads; that number says whether it got cheaper. Missing, it is a
Suggestion.

### ...and this project's own

A host repository adds its correctness rules in **`.autofleet/review.md`**, and
they are part of this policy wherever that file exists. Read it after this one.

That seam is the point. The rules that belong there are the ones this file
cannot know — the save file that must be written atomically, the header that may
not appear in `core/`, the address a test may not reach. They were written into
this file once, and this file is **vendored into every host repository**, so
every project that installed autofleet was reviewed against another project's
save format. Nothing in the payload may know about one project; that is hard rule
2, and this file was breaking it.

## Critical, Important, Suggestion

**Critical** — security, data loss or corruption, a breaking change with no
migration, or a production failure. **A Critical finding is fixed, never argued
away.** The validator will not accept a reasoned reply in its place, because
there is no second reviewer behind it.

**Important** — a real defect or a breach of a hard rule: wrong behaviour on a
path that matters, a missing test that would have caught the bug, a broken build
on either target, or the tracker left saying something untrue. Fixed, or
disputed with a reason the validator accepts.

**Suggestion** — naming, comment wording, ordering, a clearer formulation of
something already correct. **A Suggestion is answered, not fixed**: say which you
took and which you did not. Answering costs no commit, and a commit moves the
head.

**A Suggestion never becomes its own issue.** One that does costs a whole loop —
brief, implementation, review, validation — to change a comment, and a review
that mints work every round is the most expensive thing in this system. Anything
worth keeping goes on the repository's standing nit issue, if it keeps one.

Report at most **five Suggestions**, and summarise the rest as a count. A review
whose signal is buried in twenty preferences costs more attention than it saves.

## What not to report

- **The comment density**, where a project's own rules ask for it. A diff that
  matches the code around it is correct.
- **A preference restated as a defect.** If the existing code is correct and you
  would have written it differently, that is a Suggestion at most, and it counts
  against the cap of five.
- **Anything you cannot cite.** A behaviour claim needs a `file:line` in the
  actual source, not an inference from a name. If you are unsure a finding is
  real, drop it or say you are unsure — a wrong finding costs the author a round
  trip, and there is no later round to take it back in.
- **What the author already found.** The `/mattpocock-skills:code-review`
  findings are in the PR body. Repeat one only if you think the fix was wrong.
- **A verdict GitHub will refuse.** Under `AUTOFLEET_REVIEW_MODE=local` the
  reviewer signs in as the pull request's own author, and GitHub declines
  `CHANGES_REQUESTED` on a self-authored PR — *"Review Can not request changes on
  your own pull request"*. Trying it returns a non-zero exit on the reviewer's
  last action, which is how a run ends having submitted nothing at all. Use
  `--comment` whatever you found; the counts below are what hold the branch.

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

**This file names every trailer a review may carry, and never says how many there
are anywhere else.** A count stated twice goes stale in one of them. The
validator's own trailer is named in its brief, for the same reason.

**`M` is Critical plus Important.** **`N` is `M` plus Suggestions** — every
finding across all seven dimensions, inline comments included. `0` means nothing
found.

`N` above zero holds the branch until the author has answered. `M` decides
nothing about merging; what it changes is what the author is *told*, because
`M == 0` means answering in words is a complete answer and costs no commit.
Omitting `M` reads as "did not say", never as zero, so write it even when `M`
equals `N`.

They are HTML comments, invisible in the rendered review. They exist because
`merge-gate` cannot otherwise tell five Suggestions from nothing at all: both are
a COMMENTED verdict, and both satisfy every other condition it has.
