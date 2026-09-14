#!/usr/bin/env bash
# Resolves a linked GitHub issue into the full brief an agent starts from.
#
# orca.yaml's `issueCommand` points the agent's opening prompt at this script, so
# an issue picked from the Tasks tab is read as its complete body rather than as
# the bare URL Orca prefills by default. Orca substitutes {{issue}} into that
# prompt, so the agent invokes this with the number; the no-argument form falls
# back to this worktree's linked issue, which is what a human running it by hand
# will want.
#
# It prints the spec AND the marching orders, so this file is the single place
# the opening brief is written. orca.yaml and agent-autostart.sh both only point
# at it -- neither restates the workflow, so neither can drift from it.
#
# THE BRIEF ARRIVES IN TWO STAGES, and both are in this file:
#
#   issue-command.sh <n>              the spec, steps 1-3, and a pointer
#   issue-command.sh --after-pr <n>   steps 4-6, the post-PR contract
#
# Whole, the brief was 1,521 words, of which 1,272 were steps 4 through 6 --
# arming auto-merge, the review rounds, the BLOCKED/DIRTY/BEHIND triage. All of
# it arrived before the agent had read a file, and then rode in the prompt prefix
# of every request for the rest of the session, to be acted on an hour later if
# at all (armaatus/autofleet#49). Stage 2 is fetched at the moment it applies,
# which is also when it is most likely to be followed.
#
# The split is WITHIN this file, and within ONE heredoc: the brief is a single
# text with a `@@AFTER-PR@@` line in it, and the stage is chosen by which side of
# that line gets printed. Not two heredocs, which was the first shape and which
# `agent-config.yml` refused -- it re-runs main's `evals/lint.sh` against this
# branch, main's extraction is the range from the `sed` line to `BRIEF`, and two
# heredocs left it reading an empty brief and reporting that every script of the
# loop had fallen out of it. The check was right: the property it is defending is
# that the brief is one text, and keeping it one is cheaper than arguing.
#
# `evals/lint.sh` here asserts each stage separately -- an instruction that fell
# out of both is a rule nobody enforces, and the failures the long tail was
# written for (armaatus/rommsync-nx#90's unqueued auto-merge, and #88 and #89
# of the same tracker sitting blocked on one unresolved thread) come straight
# back.
#
# THE BRIEF IS THE HOME OF THE LOOP, and it sends the agent to no other document.
# Its first sentence used to read "following this repo's CLAUDE.md and the loop in
# docs/WORKFLOW.md", and that page is 10,036 words -- a longer retelling of the
# brief the agent had just been handed. An agent that did as it was told read
# 13,425 words before its first edit and then carried them in the prompt prefix of
# every request for the rest of the session (armaatus/autofleet#54). WORKFLOW.md
# still explains why each of these rules exists, which is what it is for; it is
# the maintainer's page and a reference, not per-issue reading. `evals/lint.sh`
# asserts both halves of that: each enforced rule is stated in full in exactly one
# agent-facing text, and what an agent is told to read before its first edit has a
# word ceiling.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$REPO_ROOT/scripts/fleet/lib.sh"

# Stage 2 on demand. Read BEFORE the issue is resolved so `--after-pr` with no
# number still falls back to this worktree's linked issue, exactly as the bare
# form does -- an agent in a fleet worktree types the flag and nothing else.
#
# Filtered out of the arguments wherever it appears, not matched against `$1`:
# `issue-command.sh 42 --after-pr` is the order a person writes when the number
# is already on the line, and matching `$1` alone printed stage 1 for it and
# swallowed the flag as noise. Found by the local review.
after_pr=false
kept=()
for arg in "$@"; do
  if [ "$arg" = "--after-pr" ]; then after_pr=true; else kept+=("$arg"); fi
done
# `${kept[@]+...}`: `set -u` is on and bash 3.2 -- the /bin/bash every macOS
# ships -- treats an empty array as unset, so the bare expansion is an error
# here and only here.
set -- ${kept[@]+"${kept[@]}"}

ref="${1:-}"
# Neither half may kill the script, because `set -e` is on and BOTH "no runner"
# and "no linked issue" are ordinary answers here: the argument form is the one
# the agent uses, and this fallback exists for a person running it by hand. The
# `if` condition is what makes a failing `runner_available` harmless; what makes
# a failing `runner_worktree_issue` harmless is below, and it is no longer a
# `|| true` -- see the three-way read, which replaced it.
if [ -z "$ref" ] && runner_available 2>/dev/null; then
  # THE THREE-WAY ANSWER, kept apart here too. `|| true` mapped rc 1 ("the
  # runtime would not say") and rc 2 ("there is no linked issue") onto the same
  # empty `$ref`, and the message below then reported the same thing for both --
  # which is design note 2, at the last callsite of it that had neither a branch
  # nor an assertion. `agent-autostart.sh` got its `case` for exactly this.
  #
  # Neither answer may kill the script: `set -e` is on and BOTH are ordinary
  # here, since the argument form is what the agent uses and this fallback is for
  # a person running it by hand. So the rc is read into a variable rather than
  # left to `&&`. Found by the independent review.
  # NOT named `runner_rc`: evals/lint.sh check 4b reads every `runner_[a-z_]+`
  # token in scripts/fleet/*.sh as a contract function the drivers must define,
  # and a local variable that happens to match the pattern fails the check as a
  # phantom function. Caught by the lint the moment it was written, which is the
  # check doing its job.
  ref="$(runner_worktree_issue)" || issue_rc=$?
  case "${issue_rc:-0}" in
    0|2) ;;
    *)   echo "issue-command: the runner would not say whether this worktree has a" >&2
         echo "  linked issue -- which is not the same as it having none. Pass the" >&2
         echo "  issue number or URL as an argument." >&2 ;;
  esac
fi

# Accept a bare number or any .../issues/<n>[...] URL.
num="$(printf '%s' "$ref" | sed -nE 's#.*/issues/([0-9]+).*#\1#p; s#^([0-9]+)$#\1#p' | head -1)"
[ -n "$num" ] || { echo "issue-command: could not resolve an issue from '${ref}'" >&2; exit 1; }

# Quoted heredoc, and the number substituted afterwards: this block is full of
# backticks, and in an unquoted heredoc the shell runs every one of them -- the
# project's own test command included, which is a whole test run in the middle of
# printing a prompt.
#
# The repo's working agreement carries all of this in full; repeating the
# checkable part here is what makes the opening prompt self-contained, so an
# agent cannot start work having read only a title.
# __TEST_COMMAND__ comes from AUTOFLEET_TEST_COMMAND, so the prompt names the
# command this project actually runs rather than one autofleet guessed.
test_command="${AUTOFLEET_TEST_COMMAND:-the full test suite}"

# The spec belongs to stage 1 alone. An agent running `--after-pr` has it in
# context already, and reprinting it is the duplication this split exists to
# stop.
if ! $after_pr; then
  # GH_PAGER: Orca runs this hook on a TTY, and `gh` pages TTY output through
  # less, which then waits for a keypress no one will press -- the hook never
  # exits, Orca never gets the spec, and the agent tab sits on a bare URL forever.
  GH_PAGER=cat gh issue view "$num" --json number,title,body,labels,milestone,url \
    --template '{{printf "# %v: %v" .number .title}}
{{.url}}
Milestone: {{if .milestone}}{{.milestone.title}}{{else}}none{{end}}
Labels: {{range $i, $l := .labels}}{{if $i}}, {{end}}{{$l.name}}{{end}}

{{.body}}
'
fi

# ONE brief, cut in two. `@@AFTER-PR@@` is the cut, `awk` prints the half that is
# due, and the `sed` substitutes the placeholders for both halves at once so they
# cannot come to mean different things in the part that arrives an hour later.
#
# Stage 1 is under 400 words and evals/lint.sh holds it there. Everything in it
# is actionable in the first hour; anything that is not goes below the cut.
# `if`, not `$after_pr && stage=2`: `set -e` is on, and that AND-list returns
# non-zero on the bare form, which is the common one.
if $after_pr; then stage=2; else stage=1; fi
# The test command does NOT go through `sed`: it comes from `.autofleet/config`
# and may hold any character a `s###` delimiter could be, which would end the
# expression early and print a broken brief -- with `make check # a/b&c` in the
# config, `sed` refused outright ("bad flag in substitute command"). That is the
# same hazard evals/lint.sh cites as its reason for using `${//}`. `awk`, and
# through ENVIRON rather than `-v`, because `-v` interprets escape sequences in
# what it assigns. `__ISSUE__` stays in the `sed`: it is digits, and that line is
# also what main's copy of the lint matches on. Found by the independent review.
#
# The program is a VARIABLE so that the line feeding it the heredoc stays one
# line. Inline and wrapped, awk's own source sat between the `sed` and the text,
# where the lint's extraction counted it as part of the brief.
brief_filter='
  BEGIN { half = 1; cmd = "`" ENVIRON["tc"] "`" }
  $0 == "@@AFTER-PR@@" { half = 2; next }
  half != want { next }
  { i = index($0, "__TEST_COMMAND__")
    if (i) $0 = substr($0, 1, i - 1) cmd substr($0, i + length("__TEST_COMMAND__"))
    print }
'
sed -e "s/__ISSUE__/$num/" <<'BRIEF' | tc="$test_command" awk -v want="$stage" "$brief_filter"

---

Implement the issue above, end to end. CLAUDE.md and this brief carry your
instructions, and name anything else. Work autonomously: do not stop to ask for confirmation on
anything CLAUDE.md already decides. If a question is genuinely open, write it in
the PR body and carry on with the rest of the scope.

**1. Plan.** Stay in plan mode until the plan is right: Files that change, Order
of work, Risks, Proof. The bar is that someone who never saw this conversation
could implement it from the plan alone. It goes in the PR body under `## Plan`,
not in a file.

**2. Build it, test-first where the issue is a bug.** Reproduce the bug as a
failing test, watch it fail for the reason you expect, commit that test, and only
then fix the code -- `/mattpocock-skills:tdd` is that loop.
__TEST_COMMAND__ green, with a test that would have
failed before your change. Run it and read the output.

**3. Review it yourself, before anything leaves this worktree.** One command. It
runs both passes outside this session and records the marker:

    ./scripts/fleet/self-review.sh

**It runs for ~20 minutes -- longer than one tool call. Start it in the
background.** `/code-review high` finds defects,
`/mattpocock-skills:code-review` finds conformance, REVIEW.md is the policy. Fix
what is real, re-run the tests, run it again -- the marker is per-commit. Until
it exists for the commit you are pushing, the guard hook refuses `git push` and
`gh pr create`. A PR from the fleet arrives already reviewed or it does not
arrive.

**Steps 4 to 6 -- the post-PR contract -- arrive when they apply.** Once that
marker exists, run:

    ./scripts/fleet/issue-command.sh --after-pr __ISSUE__

It is what the body must carry, how the merge is queued, and the review loop.
Skip it and the PR sits green forever, or merges over a review.

**Two subagents in `.claude/agents/` keep reading out of this context.**
`researcher` answers "where is this handled" with the answer, not the files it
read; `verifier` gives an independent build-and-test verdict before the PR.

**This context has to last** the plan, the build and three review rounds in one
time-box: `gh pr diff --stat` before `gh pr diff`, `sed -n '120,180p'` over a
range rather than a whole file, `researcher` before a wide search.

At any point, if `~/.autofleet/STOP` exists, put the work down: say where you
got to and do nothing further. Nothing can go out while it exists.

@@AFTER-PR@@

**4. Push, open the PR, and queue the merge -- in that order, now.**

    gh pr merge <n> --auto --squash

Run it the moment the PR exists. Not at the end, not after the review: GitHub
refuses to queue auto-merge on a pull request that is ALREADY mergeable (`Pull
request is in clean status`), and you are forbidden from merging directly, so a
PR that goes green before anything queued it has nobody left to merge it. It sits
clean and untouched forever, which is what #90 did. Queued here it simply waits,
and fires the moment the last required check passes. Step 6 is only the check
that you did it.

The body must carry `## Plan`, BOTH sets of findings
and what you did about them, any issue you edited and why, and `Closes #__ISSUE__`.
The `merge-gate` check reads that body: it looks for the words `/code-review`,
`mattpocock-skills:code-review` and a closing line, and without any one of them
the PR cannot merge. The closing line is the one the PR template leaves as a
placeholder -- fill it in. Then tell the board where the work is:

    ./scripts/fleet/board.sh in-review "#__ISSUE__: PR #<n>, waiting on review"

**If your issue's scope is `.github/workflows/`, `.github/scripts/` or
`.claude/`, this PR will never merge itself, and that is not a failure.**
`merge-gate` refuses those paths on purpose: a PR that could rewrite the rules
judging PRs is not merged by the machinery those rules govern. Take it to a
reviewed, green PR with every thread resolved, set the board comment to
"#__ISSUE__: ready, needs a human merge -- touches <path>", and stop there.
Do not spend review rounds trying to turn that gate green.

**5. Wait for the independent review.** One blocking call, which costs nothing
while it waits:

    ./scripts/fleet/await-review.sh

It returns when the review lands -- or early, without one, when nothing a review
could say would help: exit 7 for a red build, and exit 8 when GitHub says `DIRTY`
because something merged underneath your branch. Exit 8 wants a rebase, a fresh
`./scripts/fleet/record-review.sh .autofleet/run/self-review.md` for the new head, and `git push
--force-with-lease`; it prints all three. Do not come back here until it is
rebased.

**A clean verdict is not the same as no findings.** A review can come back
COMMENTED and still carry inline comments, each of which is a THREAD, and
`merge-gate` refuses to merge while any thread is unresolved. #88 and #89 both
sat blocked on exactly one unresolved thread with every check green.

So after every review, whatever its verdict:

    ./scripts/fleet/review-status.sh

It prints every thread that is still UNRESOLVED -- where it is, what it says,
and the thread ID `resolveReviewThread` wants -- along with anything else
keeping the PR from merging. Do NOT reach for
`gh api repos/{owner}/{repo}/pulls/<n>/comments` instead: that endpoint cannot
say whether a thread is resolved, so on round two it hands you every comment
ever left with the live ones buried among them.

Fix what is real; where you disagree, reply on the thread with your reasoning --
both are acceptable, silence is not. Then RESOLVE each thread:

    ./scripts/fleet/resolve-thread.sh <thread-id> [<thread-id>...]

Use that, not the `resolveReviewThread` mutation by hand. NOTHING on GitHub
re-runs `merge-gate` when a thread is resolved -- `pull_request_review_thread`
is a webhook event, not a workflow trigger -- so the gate stays red on a thread
you already closed, and auto-merge never fires. That script resolves the
threads and, once the last one is shut, asks the gate again.

IF YOU CHANGED ANYTHING, PUSH IT and go back to `await-review.sh`. The push
re-runs the reviewer, and the review of what you actually sent is the next
round's. Do NOT answer a review you have just pushed over: there is no review on
the new head yet, an answer written before one arrives is discarded by it, and
`answer-review.sh` refuses for exactly that reason.

When a review arrives that you are NOT going to change anything for -- because
nothing needed changing, or because you disagree and said so on the thread --
ANSWER IT:

    ./scripts/fleet/answer-review.sh "<what you did, or why you did not>"

That is the one thing standing between the review's findings and a merge. You
armed auto-merge back at step 4 -- correctly, that is what stops a finished PR
sitting green forever -- so the moment the review lands, every check is
satisfiable and the branch can go in while you are still editing. It has, four
times: #146, #154, #159, #168, and #154's took a real defect to main. The window
is not the life of the PR, it is one test run, which is exactly what you do
between reading the findings and pushing them.

"I am not doing this, because" is as good an answer as a fix; silence is not an
answer. A review that reported nothing needs none, and `merge-gate` will say so
rather than making you guess. Then run it again:

    ./scripts/fleet/review-status.sh

Exit 0 means every thread is resolved and every check is green, and exit 4 means
the same on a PR only a person can merge -- both are done, stop there. Exit 1
prints the reasons; go back to `await-review.sh` for the ones a review can
answer.

Three of those reasons are NOT waiting for a review, and it says so in the output:

- **`GitHub says BLOCKED`** with every check green is #84 -- branch protection is
  still counting a stale run whose newer run passed. Run the `gh run rerun --job`
  it prints, then run `review-status.sh` again. Waiting for another review here
  costs 45 minutes and changes nothing.
- **`GitHub says DIRTY`** is a conflict with the base. Rebase, re-run
  `record-review.sh .autofleet/run/self-review.md` for the new head, and
  `git push --force-with-lease` -- the
  same three things `await-review.sh` exit 8 prints, for the same reason.
- **`GitHub says BEHIND`** means the base moved and the branch has to catch up.
  Rebase and push.

**At most THREE rounds of this.** If a third round still leaves something
unresolved, stop: comment on the PR saying exactly what is unresolved and why you
disagree, set the board comment to "#__ISSUE__: needs you -- 3 review rounds", and
stop. Another lap is not what a disagreement needs.

**6. Confirm the merge is queued.** You ran `gh pr merge <n> --auto --squash`
back at step 4; this is only the check that it took:

    gh pr view <n> --json autoMergeRequest --jq '.autoMergeRequest != null'

`true` and you are done -- GitHub merges it when the last required check passes.
`false` means the queue did not take: read what `gh pr merge <n> --auto --squash`
says now rather than merging by hand, which the guard hook refuses anyway.

That does NOT merge. It asks GitHub to merge once the required checks pass, and
`merge-gate` is one of them -- so the rules decide, not you. You may not merge
directly; the hook will not let you, and that is the one review control this
project has. Say the PR is queued and stop.

A PR that touches `.claude/`, `.github/workflows/` or `.github/scripts/` never
auto-merges: those are the paths that can disable or rewrite the checks gating
their own PR, and a person merges them. All three, and the same three named
above -- `merge_gate.py` refuses exactly this list, and a brief that named fewer
would send an agent to spend its review rounds turning green a gate that never
will. `merge-gate` will say so.
BRIEF
