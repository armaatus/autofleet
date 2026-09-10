#!/usr/bin/env bash
# Covers AUTOFLEET_REVIEW_MODE -- where the INDEPENDENT review runs.
#
# The failure this whole mode exists to prevent is silent and total: a repository
# with no CLAUDE_CODE_OAUTH_TOKEN gets a review workflow that no-ops with a green
# check, merge_gate.py requires an independent review on the head, and every PR
# the fleet opens blocks forever on one that cannot arrive. So the assertions
# here are mostly about the two ways this can go quietly wrong -- a mode nobody
# chose, and a review nobody submitted.
#
#   test_review_mode.sh mode      merge_gate.review_mode() reads .autofleet/config:
#                                 both shell shapes, last assignment wins, a
#                                 missing file is `github`, and an unknown value
#                                 is `github` rather than a third mode.
#   test_review_mode.sh refuses   `github` mode -> review.sh exits 4 and runs no
#                                 reviewer. The dispatcher never calls it there,
#                                 and a hand-run must not review anyway.
#   test_review_mode.sh stopped   the fleet stop file exists -> exit 3, nothing
#                                 submitted. This writes to a pull request.
#   test_review_mode.sh submits   the reviewer submits -> exit 0, and the review
#                                 it wrote is one merge_gate.py COUNTS. The two
#                                 halves checked against each other rather than
#                                 each against its own idea of the marker.
#   test_review_mode.sh unmarked  ...and a reviewer that submits WITHOUT the
#                                 marker leaves merge_gate refusing the PR, and
#                                 review.sh reports 5 rather than success. This
#                                 is the row that would go green if the marker
#                                 became decorative.
#   test_review_mode.sh silent    the reviewer runs, exits 0, submits nothing ->
#                                 exit 5. claude-review.yml burned 35 turns on
#                                 this shape and went green; here it is loud.
#   test_review_mode.sh skips     a review is already on this head -> exit 8, no
#                                 second reviewer. Idempotence comes from asking
#                                 merge_gate, not from a marker file.
#   test_review_mode.sh stale     a stale review that does NOT count is on the
#                                 head and the next reviewer is silent -> still
#                                 exit 5. The post-check asks merge_gate the same
#                                 question the pre-check did, not a weaker one.
#   test_review_mode.sh timeout   the reviewer wedges -> killed at
#                                 AUTOFLEET_REVIEW_TIMEOUT and exit 7, rather
#                                 than holding the worktree until the time-box.
#   test_review_mode.sh queue     review_open_prs(): nothing in `github` mode; in
#                                 `local` mode one reviewer per open non-draft PR
#                                 of our own, and never two on one PR.
#
# `gh` and the reviewer command are both stubbed on PATH and the fleet state dir
# is a temp dir, so nothing here touches a pull request or the machine's fleet.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "  ok: $*"; }

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; return 0; }
trap cleanup EXIT

# A worktree holding the scripts under test, as its own git repo so the branch
# and head lookups answer.
make_fixture() {
  WORK="$(mktemp -d)"; WORK="$(cd "$WORK" && pwd -P)"
  mkdir -p "$WORK/repo/scripts/fleet" "$WORK/repo/.github/scripts" \
           "$WORK/repo/.claude/agents" "$WORK/repo/.autofleet" "$WORK/bin"
  cp -R "$REPO_ROOT"/scripts/fleet/. "$WORK/repo/scripts/fleet/"
  cp "$REPO_ROOT"/.github/scripts/*.py \
     "$REPO_ROOT/.github/scripts/pr_payload.sh" "$WORK/repo/.github/scripts/"
  cp "$REPO_ROOT/.claude/agents/reviewer.md" "$WORK/repo/.claude/agents/"
  git -C "$WORK/repo" init -q -b work
  git -C "$WORK/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  PR_HEAD="$(git -C "$WORK/repo" rev-parse HEAD)"

  # The mode, as a host project writes it. Overwritten per phase.
  printf 'AUTOFLEET_REVIEW_MODE=local\n' >"$WORK/repo/.autofleet/config"

  # --------------------------------------------------------------- the gh stub
  #
  # `$GH_REVIEWS` holds the review records the PR has, as JSON. The reviewer
  # stub APPENDS to it, which is what makes "did it submit?" a real question
  # here rather than a stubbed constant.
  cat >"$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALLS"
case "$*" in
  *"repo view"*) echo "armaatus/autofleet"; exit 0 ;;
  *"pr list"*)   cat "$GH_PRLIST"; exit 0 ;;
  *"pr view"*)   cat "$GH_HEAD"; exit 0 ;;
  *"api"*"/reviews"*)
    # The count review.sh asks for after the reviewer exits: reviews on the head.
    python3 -c '
import json, sys
print(len([r for r in json.load(open(sys.argv[1]))
           if r.get("commit_id") == sys.argv[2]]))' "$GH_REVIEWS" "$(cat "$GH_HEAD")"
    exit 0 ;;
  *graphql*)
    python3 - "$GH_REVIEWS" "$(cat "$GH_HEAD")" <<'PY'
import json, sys
records = json.load(open(sys.argv[1]))
nodes = [{"state": "COMMENTED", "submittedAt": "2026-09-10T10:00:00Z",
          "commit": {"oid": r["commit_id"]}, "author": {"login": r["user"]},
          "body": r["body"], "comments": {"totalCount": 0}} for r in records]
print(json.dumps({"data": {"repository": {"pullRequest": {
    "headRefOid": sys.argv[2],
    "body": "Closes #7\n/code-review\nmattpocock-skills:code-review",
    "author": {"login": "armaatus"},
    "reviews": {"nodes": nodes},
    "comments": {"nodes": []},
    "reviewThreads": {"pageInfo": {"hasNextPage": False, "endCursor": None},
                      "nodes": []}}}}}))
PY
    exit 0 ;;
esac
exit 0
STUB
  chmod +x "$WORK/bin/gh"

  GH_CALLS="$WORK/calls"; : >"$GH_CALLS"
  GH_HEAD="$WORK/head"; printf '%s' "$PR_HEAD" >"$GH_HEAD"
  GH_REVIEWS="$WORK/reviews"; printf '[]' >"$GH_REVIEWS"
  GH_PRLIST="$WORK/prlist"
  printf '[{"number":42,"isDraft":false,"headRefOid":"%s"}]\n' "$PR_HEAD" >"$GH_PRLIST"
  export GH_CALLS GH_HEAD GH_REVIEWS GH_PRLIST
  export AUTOFLEET_DIR="$WORK/fleet"
  mkdir -p "$AUTOFLEET_DIR"
  PATH="$WORK/bin:$PATH"
}

# The reviewer, stubbed. `$1` is what it does: submit a marked review, submit an
# unmarked one, submit nothing, or hang.
#
# It writes the review record DIRECTLY rather than shelling back out to the gh
# stub, because what is being tested is review.sh's reaction to a review
# existing or not -- and a stub calling a stub is one more place for the test to
# pass for its own reasons.
stub_reviewer() {
  cat >"$WORK/bin/fake-reviewer" <<STUB
#!/usr/bin/env bash
case "$1" in
  marked|unmarked)
    trailer=""
    [ "$1" = marked ] && trailer="<!-- independent-review: local \$(cat "$GH_HEAD") -->"
    python3 - "$GH_REVIEWS" "\$(cat "$GH_HEAD")" "\$trailer" <<'PY'
import json, sys
path, oid, trailer = sys.argv[1], sys.argv[2], sys.argv[3]
records = json.load(open(path))
records.append({"commit_id": oid, "user": "armaatus",
                "body": "A real review body, long enough to be worth reading and "
                        "to clear MIN_REVIEW_BODY.\n"
                        "<!-- review-findings: 0 -->\n" + trailer})
json.dump(records, open(path, "w"))
PY
    ;;
  silent) : ;;
  hang)   sleep 60 ;;
esac
exit 0
STUB
  chmod +x "$WORK/bin/fake-reviewer"
  export AUTOFLEET_REVIEW_CMD=fake-reviewer
}

# How many review records the PR has. Six copies of this one-liner is five too
# many, and the copies were what made it easy to assert the wrong thing.
n_reviews() { python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$GH_REVIEWS"; }

run_it() { (cd "$WORK/repo" && ./scripts/fleet/review.sh "$@"); }
# `review_open_prs` needs fleet.sh's own state, so it is sourced rather than run.
in_poll() { (cd "$WORK/repo" && . ./scripts/fleet/fleet.sh; for fn in "$@"; do "$fn"; done); }

# Does merge_gate.py count what is on the PR now? Asked of the gate itself, so
# the reviewer's output and the rule that judges it cannot drift apart.
gate_counts() {
  (cd "$WORK/repo" && AUTOFLEET_REVIEW_MODE="${1:-local}" python3 - "$GH_REVIEWS" "$(cat "$GH_HEAD")" <<'PY'
import json, sys
sys.path.insert(0, ".github/scripts")
from merge_gate import independent_reviews, is_substantive
records = json.load(open(sys.argv[1]))
oid = sys.argv[2]
pull = {"author": {"login": "armaatus"},
        "reviews": {"nodes": [
            {"state": "COMMENTED", "submittedAt": "2026-09-10T10:00:00Z",
             "commit": {"oid": r["commit_id"]}, "author": {"login": r["user"]},
             "body": r["body"], "comments": {"totalCount": 0}} for r in records]}}
have = [r for r in independent_reviews(pull, oid) if is_substantive(r)]
raise SystemExit(0 if have else 1)
PY
  )
}

case "${1:-}" in

# ---------------------------------------------------------------------- mode
  mode)
  make_fixture
  cfg="$WORK/repo/.autofleet/config"
  ask() { (cd "$WORK/repo" && env -u AUTOFLEET_REVIEW_MODE python3 -c '
import sys; sys.path.insert(0, ".github/scripts")
import merge_gate; print(merge_gate.review_mode())'); }

  printf 'AUTOFLEET_REVIEW_MODE=local\n' >"$cfg"
  [ "$(ask)" = local ] || fail "a plain assignment is not read"
  ok "a plain AUTOFLEET_REVIEW_MODE=local is read"

  # The shape scripts/fleet/config.sh writes its own defaults in. A host project
  # that copies that style must not silently get `github`.
  printf ': "${AUTOFLEET_REVIEW_MODE:=local}"\n' >"$cfg"
  [ "$(ask)" = local ] || fail "the \`: \${X:=v}\` shape is not read"
  ok "...and so is the \`: \${X:=local}\` shape config.sh uses"

  # Last wins, because that is what the shell would be left holding.
  printf 'AUTOFLEET_REVIEW_MODE=local\nAUTOFLEET_REVIEW_MODE=github\n' >"$cfg"
  [ "$(ask)" = github ] || fail "the last assignment does not win"
  ok "the last assignment wins, as the shell would leave it"

  # A comment is not a setting. This is the one that would turn a documented
  # example into a live mode.
  printf '# AUTOFLEET_REVIEW_MODE=local\n' >"$cfg"
  [ "$(ask)" = github ] || fail "a commented-out line was read as a setting"
  ok "a commented-out line is not a setting"

  # Both directions of "cannot tell" resolve to the STRONG mode. Failing to
  # github refuses PRs; failing to local would admit them.
  printf 'AUTOFLEET_REVIEW_MODE=whatever\n' >"$cfg"
  [ "$(ask)" = github ] || fail "an unknown value is not github"
  ok "an unknown value is github, not a third mode"
  rm -f "$cfg"
  [ "$(ask)" = github ] || fail "a missing config is not github"
  ok "...and so is a missing .autofleet/config, so a base predating this evaluates"
  ;;

# ------------------------------------------------------------------- refuses
  refuses)
  make_fixture; stub_reviewer marked
  printf 'AUTOFLEET_REVIEW_MODE=github\n' >"$WORK/repo/.autofleet/config"
  run_it 42 >"$WORK/out" 2>&1; rc=$?
  [ "$rc" = 4 ] || fail "github mode did not exit 4 (got $rc)"
  ok "github mode exits 4"
  [ "$(n_reviews)" = 0 ] \
    || fail "github mode submitted a review anyway"
  ok "...and submits nothing"
  ;;

# ------------------------------------------------------------------- stopped
  stopped)
  make_fixture; stub_reviewer marked
  : >"$AUTOFLEET_DIR/STOP"
  run_it 42 >"$WORK/out" 2>&1; rc=$?
  [ "$rc" = 3 ] || fail "a stopped fleet did not exit 3 (got $rc)"
  ok "a stopped fleet exits 3"
  [ "$(n_reviews)" = 0 ] \
    || fail "a stopped fleet submitted a review"
  ok "...and nothing goes out"
  ;;

# ------------------------------------------------------------------- submits
  submits)
  make_fixture; stub_reviewer marked
  run_it 42 >"$WORK/out" 2>&1; rc=$?
  [ "$rc" = 0 ] || { cat "$WORK/out" >&2; fail "a submitted review did not exit 0 (got $rc)"; }
  ok "a submitted review exits 0"
  gate_counts local || fail "merge_gate does not count the review review.sh just produced"
  ok "...and merge_gate counts it -- the two halves agree"
  gate_counts github && fail "github mode counted a self-review" || true
  ok "...while the same review counts for nothing in github mode"
  ;;

# ------------------------------------------------------------------ unmarked
  unmarked)
  make_fixture; stub_reviewer unmarked
  run_it 42 >"$WORK/out" 2>&1; rc=$?
  gate_counts local && fail "an unmarked self-review counted as independent" || true
  ok "an unmarked self-review does not count, so the marker is load-bearing"
  # ...and review.sh says so rather than reporting success. It asks merge_gate
  # the same question the gate will ask, so "a review record exists" is never
  # mistaken for "this PR has been reviewed". A run reporting 0 here would leave
  # the PR blocked with the dispatcher log saying it was fine.
  [ "$rc" = 5 ] || { cat "$WORK/out" >&2; fail "an unmarked review was reported as done (got $rc)"; }
  ok "...and review.sh reports 5, not a review it can count"
  ;;

# -------------------------------------------------------------------- silent
  silent)
  make_fixture; stub_reviewer silent
  run_it 42 >"$WORK/out" 2>&1; rc=$?
  [ "$rc" = 5 ] || { cat "$WORK/out" >&2; fail "a silent reviewer did not exit 5 (got $rc)"; }
  ok "a reviewer that submits nothing exits 5 rather than 0"
  grep -q "NO counting review" "$WORK/out" || fail "the silence was not named"
  ok "...and says so, because this is the failure that blocks a PR invisibly"
  ;;

# --------------------------------------------------------------------- skips
  skips)
  make_fixture; stub_reviewer marked
  run_it 42 >/dev/null 2>&1 || fail "the first review did not land"
  before="$(grep -c . "$GH_CALLS")"
  run_it 42 >"$WORK/out" 2>&1; rc=$?
  [ "$rc" = 8 ] || { cat "$WORK/out" >&2; fail "a second run did not exit 8 (got $rc)"; }
  ok "a head that already has a review exits 8"
  [ "$(n_reviews)" = 1 ] \
    || fail "a second review was submitted on the same head"
  ok "...and no second review is submitted"
  [ "$before" -gt 0 ] || fail "the stub was never called"
  ;;

# ------------------------------------------------------------------- timeout
  timeout)
  make_fixture; stub_reviewer hang
  export AUTOFLEET_REVIEW_TIMEOUT=5
  start="$(date +%s)"
  run_it 42 >"$WORK/out" 2>&1; rc=$?
  spent=$(( $(date +%s) - start ))
  [ "$rc" = 7 ] || { cat "$WORK/out" >&2; fail "a wedged reviewer did not exit 7 (got $rc)"; }
  ok "a reviewer past AUTOFLEET_REVIEW_TIMEOUT exits 7"
  [ "$spent" -lt 40 ] || fail "it waited ${spent}s, so the deadline is not enforced"
  ok "...after ${spent}s, not after the dispatcher's time-box"
  ;;

# --------------------------------------------------------------------- queue
  queue)
  make_fixture; stub_reviewer marked

  printf 'AUTOFLEET_REVIEW_MODE=github\n' >"$WORK/repo/.autofleet/config"
  in_poll review_open_prs >/dev/null 2>&1
  [ -z "$(find "$AUTOFLEET_DIR/reviewing" -type f 2>/dev/null)" ] \
    || fail "github mode started a reviewer"
  ok "review_open_prs starts nothing in github mode"

  printf 'AUTOFLEET_REVIEW_MODE=local\n' >"$WORK/repo/.autofleet/config"
  # A draft is not asking for a verdict yet.
  printf '[{"number":42,"isDraft":true,"headRefOid":"%s"}]\n' "$(cat "$GH_HEAD")" >"$GH_PRLIST"
  in_poll review_open_prs >/dev/null 2>&1
  [ -z "$(find "$AUTOFLEET_DIR/reviewing" -type f 2>/dev/null)" ] \
    || fail "a draft PR was sent for review"
  ok "...nor on a draft PR"

  printf '[{"number":42,"isDraft":false,"headRefOid":"%s"}]\n' "$(cat "$GH_HEAD")" >"$GH_PRLIST"
  in_poll review_open_prs >/dev/null 2>&1
  # The reviewer is a background child of a subshell that has since exited, so
  # wait for the review it was started to produce rather than for the pid.
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ "$(n_reviews)" = 1 ] && break
    sleep 1
  done
  [ "$(n_reviews)" = 1 ] \
    || fail "local mode did not review the open PR"
  ok "...and reviews an open non-draft PR of our own in local mode"

  # ...and never twice. review.sh's own exit 8 is what makes this true, which is
  # why the marker file is a courtesy rather than the correctness argument.
  in_poll review_open_prs >/dev/null 2>&1
  sleep 2
  [ "$(n_reviews)" = 1 ] \
    || fail "a second pass submitted a second review"
  ok "...and a second pass over the same head adds nothing"
  ;;

# ------------------------------------------------------------------- stale
  stale)
  # The silence detector's blind spot, and the reason review.sh asks
  # merge_gate the SAME question before and after the run.
  #
  # Round one submits a review with no marker: real record, real body, not a
  # review the gate counts. Round two therefore correctly starts a reviewer --
  # and that reviewer submits nothing. A post-check that counted review
  # RECORDS on the head would see the stale one, report success, and leave the
  # PR blocked with nothing anywhere saying so. Found by the local review of
  # the change that added this.
  make_fixture; stub_reviewer unmarked
  run_it 42 >/dev/null 2>&1
  [ "$(n_reviews)" = 1 ] || fail "the unmarked review was not submitted"
  stub_reviewer silent
  run_it 42 >"$WORK/out" 2>&1; rc=$?
  [ "$rc" = 5 ] || { cat "$WORK/out" >&2; fail "a stale unmarked review masked the silence (got $rc)"; }
  ok "a stale non-counting review does not make a silent run look successful"
  grep -q "independent-review: local" "$WORK/out" \
    || fail "the message does not name the likely cause"
  ok "...and the message names the missing trailer, the likely cause"
  ;;

  *)
  echo "usage: $0 mode|refuses|stopped|submits|unmarked|silent|skips|stale|timeout|queue" >&2
  exit 2 ;;
esac
