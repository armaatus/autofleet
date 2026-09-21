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
# the opening brief is written. orca.yaml and the dispatcher both only point
# at it -- neither restates the workflow, so neither can drift from it.
#
# THERE IS ONE STAGE. There were two: the spec and steps 1-3 here, and a
# `--after-pr` half carrying steps 4 through 6 -- arm auto-merge, wait out the
# review rounds, answer the findings, resolve the threads, triage
# BLOCKED/DIRTY/BEHIND. That half was 1,272 of the brief's 1,521 words, and it
# was fetched separately because all of it arriving before the agent had read a
# file meant it rode in the prompt prefix of every request for the rest of the
# session (armaatus/autofleet#49).
#
# armaatus/autofleet#152 deleted it instead. THE AGENT'S JOB ENDS AT AN OPEN
# PULL REQUEST CARRYING `Closes #N`. Everything the second stage described is
# the dispatcher's now -- `scripts/fleet/after-pr.sh` arms the merge, runs one
# review, buys at most one fix session, re-reviews it once, and then either
# GitHub merges on its own rules or a person is told why not. A brief that told
# an agent to wait for a verdict was a brief that spent the agent's budget
# waiting.
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

# `--after-pr` IS AN ERROR, NOT A NO-OP. The flag fetched a second half of this
# brief that no longer exists, and an agent resumed in a worktree opened before
# the change types it because the copy of stage 1 in its context still says to.
# Printing stage 1 again for it would answer a question about what to do next
# with the instructions for what it has already done. armaatus/autofleet#152.
for arg in "$@"; do
  [ "$arg" = --after-pr ] || continue
  echo "issue-command: there is no --after-pr brief any more." >&2
  echo "  Your job ends at an open pull request carrying 'Closes #N'. The" >&2
  echo "  dispatcher runs the review, buys at most one fix session if it asks" >&2
  echo "  for changes, and GitHub merges on its own rules. Nothing is waiting" >&2
  echo "  on you: say the PR is open and stop." >&2
  exit 2
done

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
  # nor an assertion.
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

# Accept a bare number or any .../issues/<n>[...] URL. lib.sh holds the parse,
# because the copy that lived here carried a BSD-sed defect that turned
# `/issues/42` into `4242` -- see fleet_issue_number.
num="$(fleet_issue_number "$ref")" \
  || { echo "issue-command: could not resolve an issue from '${ref}'" >&2; exit 1; }

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

# THE NOTE THE LAST ATTEMPT LEFT, if there is one, between the spec and the
# brief. This is the "read at the start of a resumed session" half of
# armaatus/autofleet#55: a session restarted in this worktree -- because the
# time-box interrupted the one before it, or because the process died -- starts
# from the issue body alone otherwise, and re-derives from the files every
# decision the first attempt already made.
#
# ONE BRIEF, ONE TEXT, AND IT IS UNDER 400 WORDS -- evals/lint.sh holds it
# there. Everything in it is actionable in the first hour, which is now the
# whole of the agent's job: the post-PR half that used to sit below a
# `@@AFTER-PR@@` cut in this same heredoc is gone with armaatus/autofleet#152,
# because the dispatcher does what it described.
#
# STILL ONE HEREDOC, and that matters even with nothing to cut. `agent-config.yml`
# re-runs main's `evals/lint.sh` against this branch, and main's extraction is
# the range from the `sed` line to `BRIEF` -- so a second heredoc here leaves it
# reading an empty brief and reporting that every script of the loop has fallen
# out of it. The property that check defends is that the brief is one text.
#
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
  BEGIN { cmd = "`" ENVIRON["tc"] "`" }
  { i = index($0, "__TEST_COMMAND__")
    if (i) $0 = substr($0, 1, i - 1) cmd substr($0, i + length("__TEST_COMMAND__"))
    print }
'
sed -e "s/__ISSUE__/$num/" <<'BRIEF' | tc="$test_command" awk "$brief_filter"

---

Implement the issue above, end to end. CLAUDE.md and this brief carry your
instructions and name anything else. Work autonomously; do not stop for
confirmation on anything CLAUDE.md decides. A genuinely open question goes in
the PR body, and you carry on with the rest of the scope.

**1. Build it.** The issue above IS the plan -- Goal, Scope, Design notes and
Acceptance are meant to be sufficient, and there is no planning phase before you
edit. Type this and nothing else, naming the issue above as the input:

    /implement

It drives `/mattpocock-skills:tdd` at the seams, runs __TEST_COMMAND__ once at
the end, and commits. For a bug the failing test is committed before the fix.
Read the suite output: a phase reporting `skip` judged nothing.

**2. Push, open the pull request, and STOP THERE.** The body carries `## Plan`
-- what the issue asked for, and where you departed from it and why -- any issue
you edited, and `Closes #__ISSUE__` on a line of its own. Departing is normal;
departing silently is not, and the review checks that section against the diff.
The merge-gate check refuses a body with no closing line.

Do not queue the merge, wait for a review, or answer one. The dispatcher arms
auto-merge, runs one review, buys one fix session if it asks for changes,
re-reviews that once, and then GitHub merges or a person is told why not. The
guard hook refuses all of it from here. Say the PR is open and stop.

A PR touching `.github/workflows/`, `.github/scripts/`, `.claude/`, or
the files in `.autofleet/` that set the rules, never merges itself -- and
that is not a failure: a change that could rewrite the rules is not merged
by them.

**The `researcher` subagent** (`.claude/agents/`) answers "where is this
handled" with the answer rather than the files it read.

**This run is bounded by turns and dollars**: `gh pr diff --stat` before
`gh pr diff`, `sed -n '120,180p'` not a whole file, `researcher` before a wide
search.

**Commit as you go.** If this run stops at its limit a second one starts in the
same worktree, from the branch and the pull request -- nothing else crosses, so
uncommitted work is work nobody sees again.

If `~/.autofleet/STOP` exists, stop: say where you got to and do nothing
further. Nothing can go out while it exists.

BRIEF
