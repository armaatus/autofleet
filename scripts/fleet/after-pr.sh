#!/usr/bin/env bash
# Everything that happens to one pull request after it is opened.
#
#   ./scripts/fleet/after-pr.sh 42
#
# THE AGENT'S JOB ENDS AT "PR OPEN WITH `Closes #N`". This is the rest, and it
# is the dispatcher's: arm the merge, review once, buy at most one fix, review
# the fix once, and then stop -- either GitHub merges it on its own rules or a
# person is told why not.
#
#   1. `gh pr merge --auto --squash`, the moment the PR exists. The dispatcher
#      is the one identity allowed to ask; `guard.py` refuses it from a fleet
#      worktree. It does not merge -- it asks GitHub to, once the required
#      checks pass, which is what makes the RULES decide rather than an agent.
#   2. `review.sh`. Approve and there is nothing left to do.
#   3. On `request-changes`, `fix.sh`: one session, in the worktree, answering
#      the findings.
#   4. `review.sh` once more, on the head the fix pushed. THAT VERDICT IS FINAL.
#      A second `request-changes` parks the PR with a comment and the dispatcher
#      moves on.
#
# TWO REVIEWS MAXIMUM, EVER, and the ceiling is a file rather than the shape of
# this script: a dispatcher restart, a second machine or a person running this
# by hand would otherwise each get their own two. `<pr>.reviews` under
# $FLEET_REVIEWING counts them, and is written BEFORE the review runs -- a
# reviewer that crashes has still been bought.
#
# What this replaces never terminated. One review, then up to two validations
# judging the author's prose answer to it: every validation of #132 and #133
# came back `fail` for reasons unrelated to the code ("cannot get the head's
# tree", "no answer posted"), so every pull request landed on the maintainer at
# the cap having spent five model passes. armaatus/autofleet#152.
#
# Exit codes:
#   0  done with this PR: approved, or parked with a reason on it
#   2  could not tell what to do: no PR, or gh would not say the repository
#   3  the fleet is stopped; nothing goes out
#   5  something went wrong that the next poll should retry
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
. ./scripts/fleet/lib.sh

pr="${1:-}"
[ -n "$pr" ] || { echo "usage: after-pr.sh <pr>" >&2; exit 2; }

if fleet_stopped; then
  echo "after-pr.sh: ~/.autofleet/STOP exists; nothing goes out." >&2
  exit 3
fi

mkdir -p "$FLEET_REVIEWING" || {
  echo "after-pr.sh: cannot write $FLEET_REVIEWING" >&2; exit 2; }
REVIEWS="$FLEET_REVIEWING/$pr.reviews"

# THE MERGE IS QUEUED FIRST, not last.
#
# GitHub refuses to queue auto-merge on a pull request that is ALREADY
# mergeable -- "Pull request is in clean status" -- and nothing here may merge
# directly, so a PR that goes green before anything queued it has nobody left to
# merge it. It sits clean and untouched forever, which is what #90 did. Queued
# now it simply waits, and fires the moment the last required check passes.
#
# Idempotent by asking first: `--auto` on a PR that already has it queued is an
# error, and an error a poll is a log nobody reads.
armed="$(GH_PAGER=cat gh pr view "$pr" --json autoMergeRequest \
           --jq '.autoMergeRequest != null' 2>/dev/null)"
if [ "$armed" != true ]; then
  if GH_PAGER=cat gh pr merge "$pr" --auto --squash >/dev/null 2>&1; then
    echo "after-pr.sh: PR #$pr queued for auto-merge."
  else
    # NOT FATAL. A repository without auto-merge enabled, or a PR GitHub will
    # not queue yet, is a thing a person fixes -- and the review below is worth
    # having either way, on a PR somebody is going to merge by hand.
    echo "after-pr.sh: could not queue auto-merge for PR #$pr; carrying on." >&2
  fi
fi

# `review.sh`, with the ceiling counted first. Prints its own reasoning; this
# only decides what the exit code means.
bought() {
  local n; n="$(cat "$REVIEWS" 2>/dev/null)"
  case "${n:-}" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s\n' "$n"
}
review_once() {
  local n rc; n="$(bought)"
  if [ "$n" -ge 2 ]; then
    echo "after-pr.sh: PR #$pr has had its two reviews; not buying a third." >&2
    return 9
  fi
  # Written BEFORE the run. A reviewer that crashes has still been bought, and
  # the alternative -- counting on success -- is a crash loop that re-reviews
  # every poll at full budget, which is the failure this ceiling exists for.
  printf '%s\n' "$((n + 1))" >"$REVIEWS" \
    || echo "after-pr.sh: could not write $REVIEWS; the review cap is not counting" >&2
  ./scripts/fleet/review.sh "$pr"; rc=$?
  # ...AND REFUNDED WHEN NO MODEL RAN. `review.sh` has four exits that spend
  # nothing: 2 (it could not tell what to review), 3 (the fleet is stopped), 6
  # (its command is not on PATH) and 8 (a verdict for this head is already
  # posted). Counted, they exhaust the ceiling of two without a single model
  # call -- and 8 is the ORDINARY one: a dispatcher that lost its `<pr>.done`
  # record, a second machine, or a pull request a person reviewed by hand all
  # reach it, twice, and then the next real review is refused with "it has had
  # its two". What is NOT refunded is 5 and 7, where a reviewer ran and produced
  # nothing or was killed at the deadline: those cost what a review costs, and
  # the whole point of the ceiling is that they cannot be retried forever.
  case "$rc" in
    2|3|6|8) printf '%s\n' "$n" >"$REVIEWS" \
               || echo "after-pr.sh: could not refund $REVIEWS" >&2 ;;
  esac
  return "$rc"
}

park() {
  GH_PAGER=cat gh pr comment "$pr" --body "$1" >/dev/null 2>&1 \
    || echo "after-pr.sh: could not comment on PR #$pr." >&2
  echo "after-pr.sh: PR #$pr parked -- $2"
}

review_once; rc=$?
case "$rc" in
  0) echo "after-pr.sh: PR #$pr approved; GitHub decides the rest."; exit 0 ;;
  4) ;;                       # changes requested -- the fix is below
  3) exit 3 ;;
  8) # A verdict for this head already exists and it was not this run's. Whoever
     # posted it decided; re-reading it here to find out which way would be a
     # third opinion on a two-opinion budget.
     echo "after-pr.sh: PR #$pr already judged at its current head."; exit 0 ;;
  9) park "**autofleet: needs a human.** This pull request has had the two
reviews the loop allows and is still not approved. Nothing further is
automatic: read the reviews above, or close this and re-open the issue with
what the reviews found written into its Scope." "at the review ceiling"
     exit 0 ;;
  *) echo "after-pr.sh: review.sh exited $rc; leaving PR #$pr for the next poll." >&2
     exit 5 ;;
esac

./scripts/fleet/fix.sh "$pr"; rc=$?
case "$rc" in
  0) ;;
  3) exit 3 ;;
  5) park "**autofleet: needs a human.** The review asked for changes, the one
fix session this pull request gets ran, and nothing was pushed. The findings
are in the review above." "the fix pushed nothing"
     exit 0 ;;
  *) park "**autofleet: needs a human.** The review asked for changes and the
fix session could not run (\`fix.sh\` exited $rc). The findings are in the
review above." "the fix could not run"
     exit 0 ;;
esac

# THE SECOND REVIEW, AND THE LAST. Its verdict is final in both directions:
# approve and GitHub merges, request-changes and a person takes it.
review_once; rc=$?
case "$rc" in
  0) echo "after-pr.sh: PR #$pr approved after one fix; GitHub decides the rest."
     exit 0 ;;
  3) exit 3 ;;
  4|9) park "**autofleet: needs a human.** The fix answering the first review
was reviewed and still asks for changes. That is the second and last review this
pull request gets -- another lap is not what a disagreement needs. Both reviews
are above." "a second request-changes"
     exit 0 ;;
  *) echo "after-pr.sh: the re-review exited $rc on PR #$pr." >&2; exit 5 ;;
esac
