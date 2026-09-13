# Local review — #54

Two passes on this branch, as CLAUDE.md requires. Both found the same
hard-rule-1 breach independently, which is the finding that mattered.

## `/code-review high` — defects

| # | Where | Finding | Done |
|---|---|---|---|
| 1 | `evals/lint.sh` | **HIGH.** The vendored lint made a *positive* assertion about the host's own `CLAUDE.md` — a file `install.sh` deliberately does not ship. A host linking `CONTRIBUTING.md` got a red required check about a document autofleet never heard of, and the remedy in the message was to edit a vendored file the next `install.sh` overwrites. | Fixed. Everything reading `CLAUDE.md` is gated on the same `IN_AUTOFLEET` probe the phase-registry check uses. Host fixture verified: 1,664 words, passes. |
| 2 | `evals/lint.sh` | **HIGH.** `WORD_CEILING` charged the host's `CLAUDE.md`, leaving a host ~1,836 words against a number stored in a vendored file. | Fixed with 1: outside autofleet the sum is the brief + `REVIEW.md` + whatever the brief names — text autofleet ships, which is what a vendored ceiling may bound. |
| 3 | `evals/lint.sh` | **MEDIUM.** `NAMED = r"[A-Za-z0-9_./-]*\.md"` has a zero-length prefix, so the bare word `.md` in prose matched as a path. | Fixed: `+`, not `*`. |
| 4 | `.claude/hooks/guard.py`, `REVIEW.md` | **MEDIUM.** Three deny messages and `REVIEW.md` cite `CLAUDE.md, "Finishing a task"` as the home of the no-merge rule, which this change moved. | `REVIEW.md` fixed here. `guard.py` **not** fixed here and filed as **#92**: it is under `.claude/`, so folding it in would cost this PR its auto-merge for a one-line message change. |
| 5 | `evals/lint.sh` | **LOW.** The "no runnable copy" check scanned ``` fences only, and the four-space indented block is what the brief itself uses; a ` ```Bash ` opener also shifted the non-greedy pairing so prose got scanned and the block did not. | Fixed: both forms, case-insensitive tag. Proved by appending an indented `record-review.sh findings.md` to the page and watching the check go red. |
| 6 | `tests/test_brief.sh` | **LOW.** The `reading` phase forbade only `docs/*.md` and hard-coded the two files it summed, so a brief that grew "read `README.md` first" passed at an unchanged total. | Fixed: every `.md`, and one `COUNTED` list drives both the allowance and the sum. |
| 7 | `evals/lint.sh` | **LOW.** Unguarded `open()` surfaced a traceback under "the loop is written more than once". | Fixed: `read()` helper exits with the reason. |
| 8 | `CLAUDE.md` | **LOW.** The prose called `REVIEW.md` "consulted, never read through" while the ceiling charged all 1,272 of its words, and "asserts both, against a word ceiling" over-claimed — stage 2 is not in the sum. | Fixed: the paragraph now says what is measured. |

## `/mattpocock-skills:code-review` — standards and spec

**Standards.** Its finding 1 is `/code-review`'s 1 and 2 — same breach, found
independently — and is fixed. Its finding 3 (the "roughly 10,000 words" figure
contradicting 13,425) was already corrected before the pass returned. Its
finding 2 claims `evals/lint.sh` has no check 4e; **this is wrong** — 4e is at
`evals/lint.sh:758` ("…and CLAUDE.md does not restate it"), which the other pass
cites by line number. The cross-reference stands. Its remaining calls (existence
guards, the duplicated ceiling constant) overlap 6 and 7 above.

**Spec.** All six Acceptance bullets met; it replayed `05ea697` against a
read-only `main` worktree and confirmed the failure.

| # | Finding | Done |
|---|---|---|
| a | The acceptance says the audience goes in the **opening paragraph**; it was in the second, and the lint accepted anything above the first `##`. | Fixed both: the paragraph and the assertion. |
| b | The one-home check covers four texts; `docs/WORKFLOW.md` is checked for *fences* only, so prose restatements survive. | **Acted on, and it found a real defect.** Stage 5 still ended "when it is green the agent runs `gh pr merge --auto --squash`" — a second copy of the rule saying the *opposite* of it, since the rule is to arm at PR creation (#90). Removed, along with stage 4's restatement of what the PR body must carry. The structural gap is accepted: `docs/WORKFLOW.md` is the explanation, and deleting prose for restating a rule is what the design note forbids. |
| c | `evals/lint.sh`'s one-home block had no `else`, so a broken extraction asserted nothing silently. | Fixed: `else fail`. Hard rule 3. |
| d | CLAUDE.md losing steps 4–6 is larger than the scope line "one line saying which document is whose", and a non-fleet reader now gets the merge rules only by running the brief. | **Not changed** — the one-home acceptance forces it, and step 4 points at the command that prints them. Called out in the PR body as a maintainer decision. |
| e | The ceiling margin is thin, and `WORD_CEILING`/`READING_CEILING` are one concept under two names. | **Not changed.** The margin is the guard working; #25 and #56 have been told the figure. The two names are the vendored/not-vendored split, documented in both, and #56 folds them into one table. |

## Regressions caught by the suite, not by either pass

`tests/test_runner_bound.sh hostlint` went red: this change introduced a second
`os.path.exists` sentinel and the phase read both as one string. The assertion is
now **every block that asks which repository this is gets the same answer**,
rather than *exactly one block asks* — which is the property it was always for.

## Proof

- `./tests/run.sh` — 158 passed, no skips. `AUTOFLEET_TEST_NO_SKIP=1` likewise.
- `./evals/lint.sh` green; `main`'s copy green against this tree.
- `guard.py --selftest` 122 assertions; `merge_gate.py --selftest` 35.
- Host fixture (host-written `CLAUDE.md`, vendored payload): passes, 1,664 words.
