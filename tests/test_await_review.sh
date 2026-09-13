#!/usr/bin/env bash
# Covers scripts/fleet/await-review.sh -- the half of the loop that decides what
# an agent does about a review, which until now was one sentence regardless of
# what the review said.
#
#   test_await_review.sh nitonly      a review declaring no Important findings ->
#                                     the agent is told to answer, and told that
#                                     answering costs no commit. It is NOT told
#                                     to fix, because a fix moves the head, a
#                                     moved head invalidates the review, and the
#                                     next round starts. Measured on #85/#86/#88:
#                                     three PRs stuck in exactly that cycle with
#                                     answer-review.sh never once run.
#   test_await_review.sh threads      ...and the same review with an open inline
#                                     thread still says to resolve it. The answer
#                                     does not close threads and merge_gate blocks
#                                     on an open one whatever the counts say, so
#                                     "answering alone clears the hold" was false
#                                     in the case the reviewer's brief PREFERS.
#   test_await_review.sh important    the same review with an Important finding ->
#                                     the old instruction, unchanged. The floor is
#                                     for nits; a data-loss bug still costs a
#                                     round and should.
#   test_await_review.sh untrailered  a review from before the trailer existed ->
#                                     also the old instruction. Absent is not
#                                     zero, and the direction that must not fail
#                                     open is "said nothing" read as "said none".
#
# `gh` is stubbed on PATH and the fleet state dir is a temp dir, so nothing here
# touches a pull request or the machine's fleet.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok: $*"; }

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; return 0; }
trap cleanup EXIT

# A worktree holding just the scripts under test, as its own git repo so the
# branch and head lookups answer. Same shape as test_answer_review.sh's, and for
# the same reason: await-review.sh imports merge_gate.py rather than
# paraphrasing what counts as a review, so the whole .py set has to be here.
make_fixture() {
  WORK="$(mktemp -d)"; WORK="$(cd "$WORK" && pwd -P)"
  mkdir -p "$WORK/repo/scripts/fleet" "$WORK/repo/.github/scripts" "$WORK/bin"
  cp -R "$REPO_ROOT"/scripts/fleet/. "$WORK/repo/scripts/fleet/"
  cp "$REPO_ROOT"/.github/scripts/*.py \
     "$REPO_ROOT/.github/scripts/pr_payload.sh" "$WORK/repo/.github/scripts/"
  git -C "$WORK/repo" init -q -b work
  git -C "$WORK/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  PR_HEAD="$(git -C "$WORK/repo" rev-parse HEAD)"

  # Which trailers the stubbed review carries. Written to a file rather than
  # exported into the stub's text, so the stub stays one string for every phase
  # and a phase cannot silently test a stub it did not mean to write.
  GH_TRAILERS="$WORK/trailers"; printf '%s' "${1:-}" >"$GH_TRAILERS"
  GH_HEAD="$WORK/head"; printf '%s' "$PR_HEAD" >"$GH_HEAD"
  GH_CALLS="$WORK/calls"; : >"$GH_CALLS"
  # Non-empty means the stubbed PR carries one UNRESOLVED review thread.
  GH_THREADS="$WORK/threads"; printf '%s' "${2:-}" >"$GH_THREADS"
  # Non-empty means a SECOND, older reviewer left an Important finding.
  GH_SECOND="$WORK/second"; printf '%s' "${3:-}" >"$GH_SECOND"

  cat >"$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALLS"
case "$*" in
  *"repo view"*) echo "armaatus/autofleet"; exit 0 ;;
  *"pr list"*)   echo 42; exit 0 ;;
  # The rollup, which gates the red-build, dead-review and conflict paths. Green
  # and MERGEABLE, so none of them fires and the wait reaches the review.
  *statusCheckRollup*)
    echo '{"statusCheckRollup":[{"name":"suite","status":"COMPLETED","conclusion":"SUCCESS"}],"mergeStateStatus":"BLOCKED","baseRefName":"main"}'
    exit 0 ;;
  # The inline comments await-review.sh prints. This is what an open review
  # thread LOOKS LIKE to the agent, so the threads phase drives it from here
  # rather than from reviewThreads alone -- reviewThreads is what merge_gate
  # reads, and the agent never sees it.
  *"pulls/42/comments"*)
    [ -s "$GH_THREADS" ] || exit 0
    printf 'src/app.c:12  claude\nNit: name this for what it returns.\n\n'
    exit 0 ;;
  *graphql*)
    python3 - "$(cat "$GH_HEAD")" "$(cat "$GH_TRAILERS")" "$(cat "$GH_THREADS")" "$(cat "$GH_SECOND")" <<'PY'
import json, sys
oid, trailers = sys.argv[1], sys.argv[2]
body = ("Nit: the comment above sync_tick() says what, not why.\n"
        "Nit: the helper below it could be named for what it returns.\n"
        + trailers)
print(json.dumps({"data": {"repository": {"pullRequest": {
    "headRefOid": oid,
    "body": "Closes #7\n/code-review\nmattpocock-skills:code-review",
    "author": {"login": "armaatus"},
    "reviews": {"nodes": (
        # An OLDER review by a DIFFERENT author, declaring an Important finding.
        # merge_gate holds on the latest unanswered review of each author, so
        # this one keeps refusing however clean the newer one is.
        ([{"state": "COMMENTED", "submittedAt": "2026-09-06T01:00:00Z",
           "commit": {"oid": oid}, "author": {"login": "someone-else"},
           "body": "Important: the retry has no backoff and will spin.\n"
                   "<!-- review-important: 1 -->\n<!-- review-findings: 1 -->",
           "comments": {"totalCount": 0}}]
         if len(sys.argv) > 4 and sys.argv[4] else [])
        + [{"state": "COMMENTED", "submittedAt": "2026-09-06T02:00:00Z",
            "commit": {"oid": oid}, "author": {"login": "claude"},
            "body": body, "comments": {"totalCount": 0}}])},
    "comments": {"nodes": []},
    "reviewThreads": {"pageInfo": {"hasNextPage": False, "endCursor": None},
                      "nodes": ([{"isResolved": False, "isOutdated": False,
                                  "path": "src/app.c", "line": 12,
                                  "comments": {"nodes": [{"author": {"login": "claude"},
                                                          "body": "Nit: name."}]}}]
                                if len(sys.argv) > 3 and sys.argv[3] else [])
                      }}}}}))
PY
    exit 0 ;;
esac
exit 0
STUB
  chmod +x "$WORK/bin/gh"
  export GH_CALLS GH_HEAD GH_TRAILERS GH_THREADS GH_SECOND
  # One poll, and a deadline it cannot reach: every phase here ends on the first
  # payload, and a phase that does not should say so as a hang, not as a pass.
  export AWAIT_REVIEW_POLL=1 AWAIT_REVIEW_DEADLINE=30
  export AUTOFLEET_DIR="$WORK/fleet"
  mkdir -p "$AUTOFLEET_DIR"
  PATH="$WORK/bin:$PATH"
}

# No `timeout` wrapper: macOS does not ship one, and tests/run.sh already bounds
# every phase (PHASE_TIMEOUT) and reaps the process group. A hang here is a phase
# timeout, which is the report it should be.
run_it() { (cd "$WORK/repo" && ./scripts/fleet/await-review.sh 42 2>&1); }

NIT_ONLY='<!-- review-important: 0 -->
<!-- review-findings: 2 -->'
IMPORTANT='<!-- review-important: 1 -->
<!-- review-findings: 2 -->'
UNTRAILERED='<!-- review-findings: 2 -->'

# The sentence the old path prints unconditionally, and the one the new path
# prints instead. Matched on a fragment rather than the whole line so a reflow
# does not turn a real regression into a passing test.
FIX_LINE='Fix what is real'
ANSWER_LINE='not a commit'

case "${1:-}" in
# ------------------------------------------------------------------- nitonly
  nitonly)
  make_fixture "$NIT_ONLY"
  out="$(run_it)"; rc=$?
  [ "$rc" = 0 ] || { echo "$out" >&2; fail "a review in hand did not exit 0 (got $rc)"; }
  grep -qF "$ANSWER_LINE" <<<"$out" \
    || { echo "$out" >&2; fail "a nit-only review did not say the answer is a comment, so the agent pushes and buys a round"; }
  grep -qF "$FIX_LINE" <<<"$out" \
    && { echo "$out" >&2; fail "a nit-only review still leads with 'Fix what is real', which is the instruction that costs the round"; }
  grep -q 'answer-review.sh' <<<"$out" \
    || fail "the one command that clears the hold was not named"
  ok "a nit-only review sends the agent to answer-review.sh, not to a commit"
  # The findings themselves are not suppressed -- this is a floor on what a
  # round costs, not on what a reviewer may say.
  grep -q 'sync_tick' <<<"$out" || fail "the nits were not printed; the floor is on the round, not on the findings"
  ok "...and the nits are still printed in full"
  ;;
# ------------------------------------------------------------------- threads
  threads)
  # The nit-only branch used to say the answer "alone clears the hold". That is
  # false the moment the reviewer left an inline finding: merge_gate blocks on
  # an unresolved thread whatever the counts say, and `answer-review.sh` does
  # not touch threads. The brief the reviewer runs under PREFERS inline comments
  # for line-specific findings, so this is the common case, not the corner --
  # and the agent would have been told it was done with the gate still red.
  # Found by the independent review of this change.
  make_fixture "$NIT_ONLY" open
  out="$(run_it)"; rc=$?
  [ "$rc" = 0 ] || { echo "$out" >&2; fail "a review in hand did not exit 0 (got $rc)"; }
  grep -q 'resolve-thread.sh' <<<"$out" \
    || { echo "$out" >&2; fail "the nit-only path does not mention resolving threads, and an open thread holds the branch"; }
  grep -qi 'resolve every thread' <<<"$out" \
    || { echo "$out" >&2; fail "it names the script without saying every thread has to close"; }
  ok "the nit-only path still says to resolve the threads the answer does not touch"
  # AND THE FIXTURE HAS TO MATTER. The first version of this phase passed
  # identically with and without its open thread, because the wording it greps
  # for is unconditional -- so it guarded the sentence and tested nothing about
  # threads, under a name that says otherwise. `nitonly` already guards the
  # sentence. What is this phase's own is that the script SAW the thread.
  # Found by the independent review.
  grep -q 'src/app.c' <<<"$out" \
    || { echo "$out" >&2; fail "the open thread was never printed, so this phase's fixture is inert and it is testing nothing"; }
  ok "...and the open thread itself is printed, so the fixture is load-bearing"
  ;;
# --------------------------------------------------------------- tworeviewers
  tworeviewers)
  # merge_gate holds on the latest unanswered review of EVERY author, not just
  # the newest overall. Reading severity from the newest alone is right for one
  # reviewer and wrong for two: an older Important review from a second account
  # keeps the gate refusing while the newest declares nothing Important, and the
  # cheap remedy would be printed for a branch blocked on something the remedy
  # does not touch. Found by the independent review.
  make_fixture "$NIT_ONLY" "" second
  out="$(run_it)"; rc=$?
  [ "$rc" = 0 ] || { echo "$out" >&2; fail "a review in hand did not exit 0 (got $rc)"; }
  grep -qF "$ANSWER_LINE" <<<"$out" \
    && { echo "$out" >&2; fail "an unanswered Important review from a second author was offered the nit remedy"; }
  grep -qF "$FIX_LINE" <<<"$out" \
    || { echo "$out" >&2; fail "with one Important review still standing it did not print the fix instruction"; }
  ok "one Important review among two is enough to decline the nit remedy"
  ;;
# ----------------------------------------------------------------- important
  important)
  make_fixture "$IMPORTANT"
  out="$(run_it)"; rc=$?
  [ "$rc" = 0 ] || { echo "$out" >&2; fail "a review in hand did not exit 0 (got $rc)"; }
  grep -qF "$FIX_LINE" <<<"$out" \
    || { echo "$out" >&2; fail "an Important finding no longer tells the agent to fix it"; }
  grep -qF "$ANSWER_LINE" <<<"$out" \
    && { echo "$out" >&2; fail "an Important finding was offered the nit remedy"; }
  ok "an Important finding still costs a fix and a round"
  ;;
# --------------------------------------------------------------- untrailered
  untrailered)
  make_fixture "$UNTRAILERED"
  out="$(run_it)"; rc=$?
  [ "$rc" = 0 ] || { echo "$out" >&2; fail "a review in hand did not exit 0 (got $rc)"; }
  grep -qF "$FIX_LINE" <<<"$out" \
    || { echo "$out" >&2; fail "a review with no severity trailer stopped behaving as it did before the trailer existed"; }
  grep -qF "$ANSWER_LINE" <<<"$out" \
    && { echo "$out" >&2; fail "a MISSING review-important was read as zero -- this is the failure that fails open"; }
  ok "no severity trailer means not said, not none"
  ;;
  *)
  echo "usage: $0 {nitonly|threads|tworeviewers|important|untrailered}" >&2; exit 2 ;;
esac
