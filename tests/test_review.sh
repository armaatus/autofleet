#!/usr/bin/env bash
# Covers the post-PR loop: review.sh, fix.sh and after-pr.sh.
#
# ONE REVIEW, AT MOST ONE FIX, AND A SECOND REVIEW THAT IS FINAL. What this
# suite is really defending is that the ceiling is enforced by state on disk
# rather than by the shape of a script -- a dispatcher restart, a second machine
# or a person running after-pr.sh by hand would otherwise each get their own
# two. armaatus/autofleet#152.
#
#   approve      a reviewer that finds nothing posts an approving verdict and
#                exits 0.
#   changes      an Important finding posts a refusal, exits 4, and puts the
#                Suggestions in a SEPARATE comment that blocks nothing.
#   nits         Suggestions alone are an approve. This is the phase that costs
#                money when it regresses: a nit read as a blocker buys a fix
#                session, a re-review and a park, to change a comment.
#   judged       a verdict already on this head exits 8 WITHOUT starting a
#                reviewer -- the dispatcher polls, and a poll that spawned a
#                second reviewer per head is how PR #32 collected fourteen.
#   stopped      ~/.autofleet/STOP stops it before the model, not after.
#   silent       a reviewer that answers nothing this can read exits 5 and posts
#                nothing at all. Posting on a guess is the one failure a
#                deterministic verdict is supposed to remove.
#   costrow      every round leaves a row in cost.tsv, including one that
#                produced no verdict.
#   fixpush      fix.sh exits 0 when the head moved.
#   fixnopush    ...and 5 when it did not: the re-review would otherwise judge
#                the very commit that was refused, and then park the PR blaming
#                the fix.
#   arms         after-pr.sh queues auto-merge before it reviews, and only when
#                it is not queued already.
#   ceiling      after-pr.sh refuses a third review on a pull request, whatever
#                it is asked.
#   parks        a second request-changes parks the PR with a comment and stops.
#   bigdiff      a diff past AUTOFLEET_REVIEW_DIFF_MAX is NOT inlined and NOT
#                truncated: the reviewer gets the stat and reads the hunks
#                itself. PR #158 is 1.3MB, about 328k tokens, so an uncapped
#                inline is a review that fails before it reads anything -- on
#                exactly the change too big to review by eye.
#   refund       ...and a review that never started a model does NOT spend one
#                of the two. Exit 8 is the ordinary case -- a dispatcher that
#                lost its `.done` record, a second machine, a PR a person
#                reviewed by hand -- and counted, two of those exhaust the
#                ceiling before a single model call.
#
# `gh` and the reviewer command are stubbed on PATH; the fleet state dir is a
# temp dir. Nothing here touches a pull request or the machine's fleet.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok: $*"; }

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; return 0; }
trap cleanup EXIT

# $1 the verdict already ON the pull request (empty for none), $2 the JSON the
# stubbed reviewer answers with (empty means it answers nothing readable).
make_fixture() {
  WORK="$(mktemp -d)"; WORK="$(cd "$WORK" && pwd -P)"
  mkdir -p "$WORK/repo/scripts/fleet" "$WORK/repo/.github/scripts" \
           "$WORK/repo/.claude/agents" "$WORK/repo/.autofleet" "$WORK/bin"
  cp -R "$REPO_ROOT"/scripts/fleet/. "$WORK/repo/scripts/fleet/"
  cp "$REPO_ROOT"/.github/scripts/*.py \
     "$REPO_ROOT/.github/scripts/pr_payload.sh" "$WORK/repo/.github/scripts/"
  cp "$REPO_ROOT/.claude/agents/reviewer.md" "$WORK/repo/.claude/agents/"
  cp "$REPO_ROOT/REVIEW.md" "$WORK/repo/"
  git -C "$WORK/repo" init -q -b work
  git -C "$WORK/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  PR_HEAD="$(git -C "$WORK/repo" rev-parse HEAD)"

  GH_ON_PR="$WORK/on-pr";   printf '%s' "${1:-}" >"$GH_ON_PR"
  GH_HEAD="$WORK/head";     printf '%s' "$PR_HEAD" >"$GH_HEAD"
  GH_CALLS="$WORK/calls";   : >"$GH_CALLS"
  GH_POSTS="$WORK/posts";   : >"$GH_POSTS"
  GH_ARMED="$WORK/armed";   printf 'false' >"$GH_ARMED"
  GH_REFUSE="$WORK/refuse"; : >"$GH_REFUSE"
  CLAUDE_ANSWER="$WORK/answer"; printf '%s' "${2:-}" >"$CLAUDE_ANSWER"
  CLAUDE_CALLS="$WORK/claude-calls"; : >"$CLAUDE_CALLS"

  cat >"$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALLS"
case "$*" in
  *"repo view"*)      echo "armaatus/autofleet"; exit 0 ;;
  *headRefOid*)       cat "$GH_HEAD"; echo; exit 0 ;;
  *autoMergeRequest*) cat "$GH_ARMED"; echo; exit 0 ;;
  *"pr list"*)        echo 42; exit 0 ;;
  *"pr diff"*)        echo "diff --git a/x b/x"; echo "+one line"; exit 0 ;;
  *"pr view"*--json\ body*) echo "Closes #7"; exit 0 ;;
  *"issue view"*)     echo "a title"; echo; echo "Scope: do the thing"; exit 0 ;;
  *"pr merge"*)       printf 'true' >"$GH_ARMED"; echo "queued"; exit 0 ;;
  *"pr review"*|*"pr comment"*)
    # ONE LINE PER POST. The body is multi-line, and recorded verbatim the
    # assertions below could not tell a finding in the blocking review from the
    # same words in the comment beside it -- which is the one thing this suite
    # exists to keep apart.
    printf '%s\n' "$(printf '%s' "$*" | tr '\n' ' ')" >>"$GH_POSTS"
    # THE STRONG STATE IS REFUSED, which is what GitHub does on a self-authored
    # pull request -- every review this repository has ever received is
    # COMMENTED for that reason. The fallback is the whole reason the verdict is
    # a marker, so the fixture refuses by default and the script has to cope.
    case "$*" in
      *--approve*|*--request-changes*)
        echo "GraphQL: Can not approve your own pull request" >&2; exit 1 ;;
    esac
    exit 0 ;;
  *graphql*)
    python3 - "$(cat "$GH_HEAD")" "$(cat "$GH_ON_PR")" <<'PY'
import json, sys
oid, on_pr = sys.argv[1], sys.argv[2]
reviews = []
if on_pr:
    reviews.append({"state": "COMMENTED", "submittedAt": "2026-09-21T01:00:00Z",
                    "commit": {"oid": oid}, "author": {"login": "armaatus"},
                    "body": "## Independent review\n\nsomething\n\n"
                            "<!-- autofleet-verdict: %s %s -->" % (on_pr, oid)})
print(json.dumps({"data": {"repository": {"pullRequest": {
    "body": "Closes #7", "reviews": {"nodes": reviews}}}}}))
PY
    exit 0 ;;
esac
exit 0
STUB
  chmod +x "$WORK/bin/gh"

  # The reviewer command. It records that it ran and prints the `--output-format
  # json` envelope, with `structured_output` carrying whatever the phase asked
  # for -- which is the field review.sh reads first.
  cat >"$WORK/bin/stub-reviewer" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CLAUDE_CALLS"
answer="$(cat "$CLAUDE_ANSWER")"
python3 - "$answer" <<'PY'
import json, sys
answer = sys.argv[1]
doc = {"type": "result", "total_cost_usd": 0.42, "duration_ms": 1234,
       "num_turns": 3, "usage": {"input_tokens": 100, "output_tokens": 20}}
if answer:
    doc["structured_output"] = json.loads(answer)
    doc["result"] = answer
else:
    doc["result"] = "I could not decide."
print(json.dumps(doc))
PY
STUB
  chmod +x "$WORK/bin/stub-reviewer"

  export GH_CALLS GH_POSTS GH_HEAD GH_ON_PR GH_ARMED GH_REFUSE
  export CLAUDE_ANSWER CLAUDE_CALLS
  export AUTOFLEET_DIR="$WORK/fleet"
  mkdir -p "$AUTOFLEET_DIR"
  export AUTOFLEET_REVIEW_CMD=stub-reviewer
  PATH="$WORK/bin:$PATH"
}

APPROVE='{"verdict":"approve","findings":[]}'
IMPORTANT='{"verdict":"request-changes","findings":[
  {"severity":"Important","file":"scripts/fleet/lib.sh","line":12,"text":"the retry has no backoff"},
  {"severity":"Suggestion","file":"scripts/fleet/lib.sh","line":40,"text":"name it for what it returns"}]}'
NITS='{"verdict":"approve","findings":[
  {"severity":"Suggestion","file":"scripts/fleet/lib.sh","line":40,"text":"name it for what it returns"}]}'

review_it() { (cd "$WORK/repo" && ./scripts/fleet/review.sh 42 2>&1); }

case "${1:-}" in
# -------------------------------------------------------------------- approve
  approve)
  make_fixture "" "$APPROVE"
  out="$(review_it)"; rc=$?
  [ "$rc" = 0 ] || { echo "$out" >&2; fail "an approving review did not exit 0 (got $rc)"; }
  grep -q -- '--comment' "$GH_POSTS" \
    || { cat "$GH_POSTS" >&2; fail "the verdict did not fall back to a comment when GitHub refused --approve"; }
  grep -q 'autofleet-verdict: approve' "$GH_POSTS" \
    || { cat "$GH_POSTS" >&2; fail "the posted review carries no approve marker, so merge_gate can never pass it"; }
  # Tried the STRONG state first: a repository with a separate reviewer identity
  # gets the real APPROVED badge for free, and only the refusal makes it a
  # marker.
  grep -q -- '--approve' "$GH_POSTS" \
    || { cat "$GH_POSTS" >&2; fail "review.sh never tried --approve, so a repo that would accept it never gets one"; }
  # ...AND NOTHING ELSE IS POSTED. There are no Suggestions here, so there is no
  # comment to leave -- and the first shape of the split got exactly this wrong:
  # with an empty Suggestions half the shell split matched neither side and the
  # review body was posted a SECOND time as a comment, carrying a literal record
  # separator into what merge_gate.py parses. The `nits` phase below asserts a
  # comment IS posted when there are Suggestions, which alone would never have
  # caught it.
  grep -q 'pr comment' "$GH_POSTS" \
    && { cat "$GH_POSTS" >&2; fail "a finding-free review posted a Suggestions comment as well; there were no Suggestions"; }
  grep -q "$(printf '\036')" "$GH_POSTS" \
    && { cat "$GH_POSTS" >&2; fail "the record separator reached a posted body"; }
  ok "nothing Critical or Important posts an approving verdict, and nothing else"
  ;;
# -------------------------------------------------------------------- changes
  changes)
  make_fixture "" "$IMPORTANT"
  out="$(review_it)"; rc=$?
  [ "$rc" = 4 ] || { echo "$out" >&2; fail "an Important finding did not exit 4, the fix signal (got $rc)"; }
  grep -q 'autofleet-verdict: request-changes' "$GH_POSTS" \
    || { cat "$GH_POSTS" >&2; fail "the refusal carries no marker"; }
  grep -q 'pr comment' "$GH_POSTS" \
    || { cat "$GH_POSTS" >&2; fail "the Suggestion was not posted as a plain comment"; }
  # THE SPLIT IS BY SEVERITY AND IT IS THE SCRIPT'S, not the reviewer's: the
  # blocking body carries the Important finding and the nit is somewhere that
  # gates nothing.
  grep 'pr review' "$GH_POSTS" | grep -q 'no backoff' \
    || { cat "$GH_POSTS" >&2; fail "the Important finding is not in the blocking review body"; }
  grep 'pr review' "$GH_POSTS" | grep -q 'name it for what it returns' \
    && { cat "$GH_POSTS" >&2; fail "a Suggestion reached the blocking review body"; }
  ok "an Important finding blocks, and the Suggestion beside it does not"
  ;;
# ----------------------------------------------------------------------- nits
  nits)
  make_fixture "" "$NITS"
  out="$(review_it)"; rc=$?
  [ "$rc" = 0 ] || { echo "$out" >&2; fail "a Suggestion-only review did not approve (got $rc)"; }
  grep -q 'autofleet-verdict: approve' "$GH_POSTS" \
    || { cat "$GH_POSTS" >&2; fail "Suggestions alone did not produce an approving verdict"; }
  grep -q 'pr comment' "$GH_POSTS" \
    || { cat "$GH_POSTS" >&2; fail "the Suggestion was not posted at all"; }
  ok "a nit is posted, and that is all"
  ;;
# --------------------------------------------------------------------- judged
  judged)
  make_fixture approve "$APPROVE"
  out="$(review_it)"; rc=$?
  [ "$rc" = 8 ] || { echo "$out" >&2; fail "a head that already has a verdict did not exit 8 (got $rc)"; }
  [ -s "$CLAUDE_CALLS" ] \
    && { cat "$CLAUDE_CALLS" >&2; fail "a reviewer was started on a head that already had a verdict"; }
  ok "a head with a verdict costs two API calls and no model"
  ;;
# -------------------------------------------------------------------- stopped
  stopped)
  make_fixture "" "$APPROVE"
  : >"$AUTOFLEET_DIR/STOP"
  out="$(review_it)"; rc=$?
  [ "$rc" = 3 ] || { echo "$out" >&2; fail "a stopped fleet did not exit 3 (got $rc)"; }
  [ -s "$CLAUDE_CALLS" ] \
    && { cat "$CLAUDE_CALLS" >&2; fail "a reviewer was started while the fleet was stopped"; }
  [ -s "$GH_POSTS" ] \
    && { cat "$GH_POSTS" >&2; fail "something was posted while the fleet was stopped"; }
  ok "a stop is checked before the model, not after it"
  ;;
# --------------------------------------------------------------------- silent
  silent)
  make_fixture "" ""
  out="$(review_it)"; rc=$?
  [ "$rc" = 5 ] || { echo "$out" >&2; fail "a reviewer with no readable verdict did not exit 5 (got $rc)"; }
  [ -s "$GH_POSTS" ] \
    && { cat "$GH_POSTS" >&2; fail "a verdict was posted for a reviewer that produced none"; }
  ok "no readable verdict posts nothing"
  ;;
# -------------------------------------------------------------------- costrow
  costrow)
  # THE ROUND HAPPENED AND IT COST WHAT IT COST, whatever it decided. A cost
  # ledger that records only successful rounds cannot answer "what did this pull
  # request spend", which is the question armaatus/autofleet#152 is measured by.
  make_fixture "" ""
  review_it >/dev/null 2>&1
  tsv="$AUTOFLEET_DIR/reviews/cost.tsv"
  [ -s "$tsv" ] || fail "no cost row for a round that produced no verdict"
  grep -q '^# when' "$tsv" || { cat "$tsv" >&2; fail "cost.tsv has no header"; }
  grep -q '0.42' "$tsv" || { cat "$tsv" >&2; fail "the cost row carries no dollar figure"; }
  ok "every round leaves a cost row, verdict or not"
  ;;
# -------------------------------------------------------------------- fixpush
  fixpush)
  make_fixture request-changes "$APPROVE"
  mkdir -p "$AUTOFLEET_DIR/worktrees"
  printf '%s\n' "$WORK/repo" >"$AUTOFLEET_DIR/worktrees/7"
  # The fix "pushes" by moving the head the stub reports.
  cat >"$WORK/bin/stub-reviewer" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CLAUDE_CALLS"
printf '%s' "0123456789abcdef0123456789abcdef01234567" >"$GH_HEAD"
echo '{"type":"result","result":"fixed","total_cost_usd":0.1,"num_turns":2}'
STUB
  chmod +x "$WORK/bin/stub-reviewer"
  out="$( (cd "$WORK/repo" && ./scripts/fleet/fix.sh 42 2>&1) )"; rc=$?
  [ "$rc" = 0 ] || { echo "$out" >&2; fail "a fix that moved the head did not exit 0 (got $rc)"; }
  grep -q 'is now at' <<<"$out" \
    || { echo "$out" >&2; fail "the fix did not name the head to re-review"; }
  ok "a fix that pushed is handed on for the re-review"
  ;;
# ------------------------------------------------------------------ fixnopush
  fixnopush)
  make_fixture request-changes "$APPROVE"
  mkdir -p "$AUTOFLEET_DIR/worktrees"
  printf '%s\n' "$WORK/repo" >"$AUTOFLEET_DIR/worktrees/7"
  out="$( (cd "$WORK/repo" && ./scripts/fleet/fix.sh 42 2>&1) )"; rc=$?
  [ "$rc" = 5 ] || { echo "$out" >&2; fail "a fix that pushed nothing did not exit 5 (got $rc)"; }
  ok "a fix that pushed nothing is not handed on as one that did"
  ;;
# ----------------------------------------------------------------------- arms
  arms)
  make_fixture "" "$APPROVE"
  # review.sh replaced by one that approves without a model, so this phase is
  # about the merge queue and nothing else.
  printf '#!/usr/bin/env bash\nexit 0\n' >"$WORK/repo/scripts/fleet/review.sh"
  chmod +x "$WORK/repo/scripts/fleet/review.sh"
  out="$( (cd "$WORK/repo" && ./scripts/fleet/after-pr.sh 42 2>&1) )"; rc=$?
  [ "$rc" = 0 ] || { echo "$out" >&2; fail "an approved PR did not finish (got $rc)"; }
  [ "$(grep -c 'pr merge' "$GH_CALLS")" = 1 ] \
    || { cat "$GH_CALLS" >&2; fail "auto-merge was not queued exactly once"; }
  # ...and NOT again on the next pass. `--auto` on a PR that already has it
  # queued is an error, and an error a poll is a log nobody reads.
  : >"$GH_CALLS"
  (cd "$WORK/repo" && ./scripts/fleet/after-pr.sh 42 >/dev/null 2>&1)
  grep -q 'pr merge' "$GH_CALLS" \
    && { cat "$GH_CALLS" >&2; fail "auto-merge was queued again on a PR that already had it"; }
  ok "the merge is queued once, before the review"
  ;;
# -------------------------------------------------------------------- ceiling
  ceiling)
  make_fixture "" "$APPROVE"
  printf '#!/usr/bin/env bash\nexit 4\n' >"$WORK/repo/scripts/fleet/review.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$WORK/repo/scripts/fleet/fix.sh"
  chmod +x "$WORK/repo/scripts/fleet/review.sh" "$WORK/repo/scripts/fleet/fix.sh"
  mkdir -p "$AUTOFLEET_DIR/reviewing"
  printf '2\n' >"$AUTOFLEET_DIR/reviewing/42.reviews"
  out="$( (cd "$WORK/repo" && ./scripts/fleet/after-pr.sh 42 2>&1) )"; rc=$?
  [ "$rc" = 0 ] || { echo "$out" >&2; fail "a PR at the ceiling did not finish cleanly (got $rc)"; }
  grep -q 'needs a human' "$GH_POSTS" \
    || { cat "$GH_POSTS" >&2; fail "a PR at the review ceiling was not parked with a comment"; }
  [ "$(cat "$AUTOFLEET_DIR/reviewing/42.reviews")" = 2 ] \
    || fail "the review count moved past the ceiling"
  ok "a third review is never bought, whatever it is asked"
  ;;
# --------------------------------------------------------------------- refund
  refund)
  make_fixture approve "$APPROVE"
  # `review.sh` replaced by one that exits 8 -- "a verdict for this head is
  # already posted" -- which is the exit a polling dispatcher hits most often.
  printf '#!/usr/bin/env bash\nexit 8\n' >"$WORK/repo/scripts/fleet/review.sh"
  chmod +x "$WORK/repo/scripts/fleet/review.sh"
  for _ in 1 2 3; do
    (cd "$WORK/repo" && ./scripts/fleet/after-pr.sh 42 >/dev/null 2>&1)
  done
  spent="$(cat "$AUTOFLEET_DIR/reviewing/42.reviews" 2>/dev/null || echo 0)"
  [ "$spent" = 0 ] \
    || fail "three polls that started no model spent $spent of the two reviews"
  # ...and a reviewer that RAN and produced nothing is not refunded: that costs
  # what a review costs, and retrying it forever is what the ceiling is for.
  printf '#!/usr/bin/env bash\nexit 5\n' >"$WORK/repo/scripts/fleet/review.sh"
  chmod +x "$WORK/repo/scripts/fleet/review.sh"
  (cd "$WORK/repo" && ./scripts/fleet/after-pr.sh 42 >/dev/null 2>&1)
  [ "$(cat "$AUTOFLEET_DIR/reviewing/42.reviews")" = 1 ] \
    || fail "a reviewer that ran and produced no verdict was refunded; it cost what a review costs"
  ok "a review that started no model is refunded, and one that ran is not"
  ;;
# -------------------------------------------------------------------- bigdiff
  bigdiff)
  make_fixture "" "$APPROVE"
  # A diff well past the cap, and a stat that is not. The stub answers both.
  cat >"$WORK/bin/gh" <<'BIGSTUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALLS"
case "$*" in
  *"repo view"*)      echo "armaatus/autofleet"; exit 0 ;;
  *headRefOid*)       cat "$GH_HEAD"; echo; exit 0 ;;
  *autoMergeRequest*) echo false; exit 0 ;;
  *"pr list"*)        echo 42; exit 0 ;;
  *"pr diff"*--stat*) echo " scripts/fleet/lib.sh | 4 ++--"; exit 0 ;;
  *"pr diff"*)        awk 'BEGIN{for(i=0;i<9000;i++) print "+a line of diff that is quite long indeed"}'; exit 0 ;;
  *"pr view"*--json\ body*) echo "Closes #7"; exit 0 ;;
  *"issue view"*)     echo "a title"; exit 0 ;;
  *"pr review"*|*"pr comment"*)
    printf '%s\n' "$(printf '%s' "$*" | tr '\n' ' ')" >>"$GH_POSTS"; exit 0 ;;
  *graphql*)
    echo '{"data":{"repository":{"pullRequest":{"body":"Closes #7","reviews":{"nodes":[]}}}}}'
    exit 0 ;;
esac
exit 0
BIGSTUB
  chmod +x "$WORK/bin/gh"
  # The reviewer records the prompt it was handed, so this can assert on it.
  cat >"$WORK/bin/stub-reviewer" <<'PROMPTSTUB'
#!/usr/bin/env bash
prev=""
for arg in "$@"; do
  [ "$prev" = "-p" ] && printf '%s' "$arg" >"$CLAUDE_CALLS"
  prev="$arg"
done
printf '{"type":"result","result":"x","structured_output":{"verdict":"approve","findings":[]},"total_cost_usd":0.1,"num_turns":1}\n'
PROMPTSTUB
  chmod +x "$WORK/bin/stub-reviewer"

  out="$(review_it)"; rc=$?
  [ "$rc" = 0 ] || { echo "$out" >&2; fail "the review did not finish (rc $rc)"; }
  bytes="$(wc -c <"$CLAUDE_CALLS" | tr -d ' ')"
  # The whole diff is ~370KB; the prompt must be nowhere near it.
  [ "$bytes" -lt 262144 ] \
    || fail "the prompt is $bytes bytes: the diff was inlined past the ceiling"
  grep -q 'THIS IS THE STAT, NOT THE DIFF' "$CLAUDE_CALLS" \
    || fail "the reviewer was not told the diff is not in its prompt, so it reviews what it can see and calls that the change"
  grep -q 'gh pr diff 42 -- <path>' "$CLAUDE_CALLS" \
    || fail "the reviewer was not told how to read the hunks itself"
  # ...and NOT a truncated diff, which is the shape that reports confidently on
  # half a hunk.
  grep -q 'a line of diff that is quite long indeed' "$CLAUDE_CALLS" \
    && fail "the diff was truncated into the prompt rather than replaced by the stat"
  ok "a diff past the ceiling is replaced by the stat, not truncated into the prompt"
  ;;
# ---------------------------------------------------------------------- parks
  parks)
  make_fixture "" "$APPROVE"
  # Both reviews refuse, and the fix pushes. This is the full loop: review, fix,
  # re-review, park.
  printf '#!/usr/bin/env bash\nexit 4\n' >"$WORK/repo/scripts/fleet/review.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$WORK/repo/scripts/fleet/fix.sh"
  chmod +x "$WORK/repo/scripts/fleet/review.sh" "$WORK/repo/scripts/fleet/fix.sh"
  out="$( (cd "$WORK/repo" && ./scripts/fleet/after-pr.sh 42 2>&1) )"; rc=$?
  [ "$rc" = 0 ] || { echo "$out" >&2; fail "the parked PR did not finish cleanly (got $rc)"; }
  [ "$(cat "$AUTOFLEET_DIR/reviewing/42.reviews")" = 2 ] \
    || { cat "$AUTOFLEET_DIR/reviewing/42.reviews" >&2; fail "the loop did not spend exactly two reviews"; }
  grep -q 'second and last review' "$GH_POSTS" \
    || { cat "$GH_POSTS" >&2; fail "a second request-changes did not park the PR with a reason"; }
  ok "one review, one fix, one re-review, then a person"
  ;;
  *)
  echo "usage: $0 {approve|changes|nits|judged|stopped|silent|costrow|fixpush|fixnopush|arms|ceiling|refund|bigdiff|parks}" >&2
  exit 2 ;;
esac
