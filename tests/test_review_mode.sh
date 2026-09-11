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
#   test_review_mode.sh midstop   the stop file appears WHILE a reviewer runs ->
#                                 the reviewer is killed and review.sh exits 3.
#                                 `stop --now` promises the agents are frozen,
#                                 and a reviewer reading the stop once at the top
#                                 kept its credentials for the rest of its budget.
#   test_review_mode.sh reaper    a marker naming a live process that is NOT one
#                                 of ours is never signalled, and a marker naming
#                                 a dead pid is cleared. This is the second place
#                                 the fleet signals a pid it read out of a file.
#   test_review_mode.sh once       a head that already has a counting review is
#                                 not handed to a second reviewer, on this poll
#                                 or any later one -- and a push invalidates
#                                 that. Fourteen spawns in thirteen minutes on
#                                 PR #32's first head is what this stops.
#   test_review_mode.sh retries    ...while a reviewer that submitted NOTHING is
#                                 tried again. The asymmetry is the whole fix:
#                                 backwards, it is the silent block the mode
#                                 exists to remove.
#   test_review_mode.sh capped     ...and not forever: AUTOFLEET_REVIEW_MAX_TRIES
#                                 reviewers on one head that submit nothing, then
#                                 a hold that says so ONCE and points at the log.
#                                 Unbounded, this is a full-budget reviewer
#                                 started every poll against a head that will
#                                 never get a verdict.
#   test_review_mode.sh holds      TWO holds in one poll body -- a foundation
#                                 issue in flight and a PR at the cap. They
#                                 shared one say-once marker, so each overwrote
#                                 the other's reason and both re-announced every
#                                 poll: verbatim the flooding this change
#                                 removes. `capped` runs with no foundation issue
#                                 and stayed green against the shared marker.
#   test_review_mode.sh status_count
#                                 `fleet.sh status` counts the LOCK and not the
#                                 three records beside it. Counting them made a
#                                 reviewed PR read as a slot taken forever, on
#                                 the first screen anybody looks at -- and it is
#                                 where the third spelling of the suffix list
#                                 came to disagree with the other two. Also: a
#                                 poll leaves an open PR's records alone and
#                                 sweeps a closed PR's.
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

  # ------------------------------------------------------------- the orca stub
  #
  # `fleet.sh` resolves the runner AT SOURCE TIME and `die`s if nothing answers
  # (fleet.sh: `orca_cli_resolve || die "no orca CLI answers here"`). This file
  # sources it -- `in_poll` does -- so on a machine with no Orca the subshell
  # exited before running the function under test, and the phases that hid that
  # behind `>/dev/null 2>&1` reported the CONSEQUENCE instead: "the stale marker
  # was not cleared", "local mode did not review the open PR". Both passed on a
  # laptop with Orca installed and failed in CI, where I first mistook the second
  # for a timing flake and widened its timeout.
  #
  # Answers only what sourcing needs: a version, and an empty worktree list.
  cat >"$WORK/bin/orca-stub" <<'OSTUB'
#!/usr/bin/env bash
case "$1" in
  --version) echo "orca 0.0.0-test"; exit 0 ;;
esac
case "$1 ${2:-}" in
  "worktree list") echo '{"result":{"worktrees":[]}}'; exit 0 ;;
esac
echo '{"ok":true,"result":{}}'
exit 0
OSTUB
  chmod +x "$WORK/bin/orca-stub"
  export ORCA_CLI_COMMAND="$WORK/bin/orca-stub"

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
  # BEFORE the heredoc, which is unquoted: `$REVIEWER_CALLS` in the stub body is
  # expanded as the stub is written, so setting it afterwards is an unbound
  # variable under `set -u` and the stub never gets written at all.
  REVIEWER_CALLS="$WORK/reviewer-calls"
  [ -e "$REVIEWER_CALLS" ] || : >"$REVIEWER_CALLS"
  export REVIEWER_CALLS
  cat >"$WORK/bin/fake-reviewer" <<STUB
#!/usr/bin/env bash
printf 'ran\n' >>"$REVIEWER_CALLS"
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
  # A child, not the stub itself. AUTOFLEET_REVIEW_CMD is advertised as a
  # wrapper seam, so the process holding the gh login is routinely a CHILD of
  # what review.sh signals -- and a kill that reaps only the direct child leaves
  # it running. The sleep is given a distinctive duration so a test can tell the
  # wrapper's death from the work's.
  hang)   sleep 3607 ;;
esac
exit 0
STUB
  chmod +x "$WORK/bin/fake-reviewer"
  export AUTOFLEET_REVIEW_CMD=fake-reviewer
}

# How many review records the PR has. Six copies of this one-liner is five too
# many, and the copies were what made it easy to assert the wrong thing.
n_reviews() { python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$GH_REVIEWS"; }
# How many times a reviewer was actually started. `n_reviews` cannot answer that
# -- a reviewer can run and submit nothing -- and "was one started at all" is the
# question the queue phase is really asking.
n_started() { grep -c . "$REVIEWER_CALLS" 2>/dev/null || echo 0; }
# How many times the DISPATCHER started review.sh -- which is what the re-spawn
# bug is about, and is not the same as how many times a reviewer ran.
#
# `n_started` counts the stub, and the exit-8 path returns before the stub is
# ever invoked. So on the base code the extra spawns happened, produced no stub
# call, and a phase asserting `n_started` was satisfied: it passed before the fix
# as well as after, measuring model calls where the issue is about spawns. The
# dispatcher says "reviewing PR #N at <head> (pid ...)" once per spawn, and that
# is the line to count. Found by the independent review -- the sixth phase on
# this project to pass for a reason other than the one it claimed, in the change
# whose own body reports the fifth.
# The DISPATCHER's line, which carries a pid -- not `review.sh`'s own
# `==> reviewing PR #42 at <head> with <cmd>`, which lands in the same file
# because the dispatcher redirects the child's output into it. Counting both
# doubled every spawn.
#
# `|| true` inside the substitution, not `|| echo 0`: `grep -c` PRINTS 0 and
# exits 1 when it finds nothing, so `|| echo 0` appends a second line and the
# caller compares "0\n0" against a number. That has now cost time twice in this
# file.
n_spawned() { local n; n="$(grep -c "reviewing PR #42 at .* (pid" "$AUTOFLEET_DIR/fleet.log" 2>/dev/null || true)"; printf '%s\n' "${n:-0}"; }
# Whether a reviewer still holds PR 42's lock. A poll taken while one is running
# is CORRECTLY skipped, so a phase that polls again immediately is testing the
# dedup rather than the thing it means to.
lock_held() { [ -e "$AUTOFLEET_DIR/reviewing/42" ] && echo yes || echo no; }

# Wait until `$1` prints `$2`, or give up after `$3` seconds and say what it was.
#
# GENEROUSLY BOUNDED, because the thing being waited for is a background process
# on a machine this test does not own. Ten seconds passed on a laptop and failed
# on a CI runner where the same phase's own reviewer took five -- a flake in the
# suite that guards the reviewer is worse than no assertion, because it teaches
# people to re-run rather than read.
await() {
  local what="$1" want="$2" bound="${3:-120}" waited=0 got
  while [ "$waited" -lt "$bound" ]; do
    got="$($what)"
    [ "$got" = "$want" ] && return 0
    sleep 1
    waited=$((waited + 1))
  done
  echo "  (waited ${bound}s for $what to be $want; it is ${got:-?})" >&2
  return 1
}

run_it() { (cd "$WORK/repo" && ./scripts/fleet/review.sh "$@"); }

# `review_open_prs`, with the reason kept rather than piped away.
#
# `fleet.sh` resolves the runner at SOURCE TIME and `die`s without one, so a
# bare `>/dev/null 2>&1` here turns "nothing under test ran" into "local mode
# did not review the open PR" -- which is the diagnosis this file cost once
# already. The `reaper` phase was un-silenced when that was found and this one
# was not; the lesson belongs to both.
poll_review_open_prs() {
  local out; out="$(in_poll review_open_prs 2>&1)"
  grep -q "no orca CLI answers" <<<"$out" \
    && fail "fleet.sh would not source, so nothing under test ran: $out"
  return 0
}
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

  # The shape scripts/fleet/config.sh writes its own defaults in -- and the one
  # a host config CANNOT use, because config.sh's default runs first and leaves
  # the variable already set. This row used to assert the opposite, on the
  # reasoning that a host copying that style must not silently get `github`.
  # They do get `github`, from the shell, and the gate agreeing with them is the
  # only thing that stops the two readers disagreeing in the blocking direction:
  # a gate in local mode waiting for a review no dispatcher will start. Found by
  # the independent review of the change that added the row.
  printf ': "${AUTOFLEET_REVIEW_MODE:=local}"\n' >"$cfg"
  [ "$(ask)" = github ] || fail "the gate reads a \`:=\` the shell ignores"
  ok "the \`: \${X:=local}\` shape sets nothing, and the gate agrees"

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
  # ...and the reviewer is actually DEAD. The exit code and the elapsed time are
  # both satisfied by a run that gave up on a wedged agent and left it holding
  # this machine's gh credentials -- delete kill_reviewer from the deadline
  # branch and everything above stays green. The midstop phase checks this; the
  # phase whose whole subject is the kill did not. Found by the independent
  # review.
  pgrep -f "$WORK/bin/fake-reviewer" >/dev/null 2>&1 \
    && fail "the wedged reviewer is still running after the deadline"
  ok "...and the reviewer is gone, not merely given up on"
  # THE WORK, not the wrapper. Signalling the direct child reaps the stub and
  # orphans what it started -- which with any AUTOFLEET_REVIEW_CMD wrapper is the
  # agent holding this machine's gh login. Both this phase and midstop checked
  # only the wrapper. Found by the independent review.
  pgrep -f "sleep 3607" >/dev/null 2>&1 \
    && fail "the wedged reviewer's own child outlived the kill"
  ok "...and so is what it had started"
  ;;

# ---------------------------------------------------------------------- once
  once)
    make_fixture; stub_reviewer marked
    printf '[{"number":42,"isDraft":false,"headRefOid":"%s"}]\n' "$(cat "$GH_HEAD")" >"$GH_PRLIST"
    poll_review_open_prs
    await n_spawned 1 || fail "the first pass started no reviewer"
    await n_reviews 1 || fail "the first reviewer submitted nothing"
    await lock_held no || fail "the first reviewer never released its lock"
    # ...and now every later poll must start nothing, because the head is done.
    for _ in 1 2 3; do poll_review_open_prs; done
    # On SPAWNS. Asserting on stub calls passed against the base code too,
    # because the spawns it should have counted all exited before reaching the
    # stub. `await`, not a fixed sleep, so a loaded machine does not decide it.
    await n_spawned 2 10 >/dev/null 2>&1 || true
    [ "$(n_spawned)" = 1 ] \
      || fail "three further polls started $(n_spawned) reviewers on a head that already has one"
    ok "a head with a counting review is not handed to another reviewer"

    # A push invalidates it: new head, new review.
    (cd "$WORK/repo" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m push)
    git -C "$WORK/repo" rev-parse HEAD >"$GH_HEAD"
    printf '[{"number":42,"isDraft":false,"headRefOid":"%s"}]\n' "$(cat "$GH_HEAD")" >"$GH_PRLIST"
    poll_review_open_prs
    await n_spawned 2 || fail "a new head did not get a reviewer"
    ok "...and a push starts one again"
    ;;

# ------------------------------------------------------------------- retries
  retries)
    # The asymmetry. A reviewer that submitted NOTHING must be tried again --
    # exit 5 is a transient failure, and recording it as handled would turn this
    # fix into a PR nobody ever reviews, which is the failure local mode exists
    # to remove.
    make_fixture; stub_reviewer silent
    printf '[{"number":42,"isDraft":false,"headRefOid":"%s"}]\n' "$(cat "$GH_HEAD")" >"$GH_PRLIST"
    poll_review_open_prs
    await n_started 1 || fail "the first pass started no reviewer"
    # ...and let it finish. Polling while it runs is correctly skipped, which is
    # a different property and one the `once` phase already covers.
    await lock_held no || fail "the first reviewer never released its lock"
    # It submitted nothing. The next pass must try again.
    poll_review_open_prs
    await n_started 2 \
      || fail "a reviewer that submitted nothing was recorded as done; that PR is never reviewed"
    ok "a reviewer that submitted nothing is tried again"
    [ -e "$AUTOFLEET_DIR/reviewing/42.done" ] \
      && fail "exit 5 wrote the done record, which is the silent-block direction"
    ok "...and no done record was written for it"
    ;;

# --------------------------------------------------------------------- capped
  capped)
    # ...and the retry is bounded. Unbounded, a head that never gets a verdict
    # gets a full-budget reviewer every poll until the agent's three-hour
    # time-box expires. claude-review.yml bounds the same case at one more
    # attempt and then says a person decides.
    make_fixture; stub_reviewer silent
    export AUTOFLEET_REVIEW_MAX_TRIES=2
    printf '[{"number":42,"isDraft":false,"headRefOid":"%s"}]\n' "$(cat "$GH_HEAD")" >"$GH_PRLIST"
    n=0
    while [ "$n" -lt 5 ]; do
      poll_review_open_prs
      await lock_held no >/dev/null 2>&1 || true
      n=$((n + 1))
    done
    [ "$(n_started)" = 2 ] \
      || fail "five polls started $(n_started) reviewers against a cap of 2"
    ok "a head that never gets a verdict stops being retried at the cap"
    out="$(poll_review_open_prs 2>&1; cat "$AUTOFLEET_DIR/fleet.log" 2>/dev/null)"
    grep -q "submitted nothing, which is the cap" <<<"$out" \
      || fail "it stopped retrying without saying so: $out"
    ok "...and says so, rather than going quiet"
    ;;

# --------------------------------------------------------------------- holds
  status_count)
  # `fleet.sh status` counts REVIEWERS IN FLIGHT, and the three record files
  # beside the lock are not reviewers. Counting them made a PR whose head has
  # been reviewed read as one in flight for as long as that head stands -- which
  # is the entire point of `<pr>.done` -- and a PR at the cap read as two
  # (`.tries` plus `.said`). Three reviewed PRs open and `status` says 3: exactly
  # the number that reads as "every slot is taken", on the screen its own comment
  # calls the first anybody looks at, permanently rather than transiently.
  #
  # Nothing asserted the count, which is how the third spelling of the suffix
  # list came to disagree with the other two. Found by the independent review,
  # which found it on both axes independently.
  make_fixture
  mkdir -p "$AUTOFLEET_DIR/reviewing"
  # One real lock: a reviewer running on PR 42. `$$` is this shell, which IS
  # alive, so `live_reviewers` cannot reap it mid-phase.
  printf '%s %s\n' "$$" "$PR_HEAD" >"$AUTOFLEET_DIR/reviewing/42"
  # ...and every record, for three other PRs, so a miscount cannot be read as
  # the lock being counted twice.
  printf '%s\n' "$PR_HEAD"   >"$AUTOFLEET_DIR/reviewing/43.done"
  printf '%s 2\n' "$PR_HEAD" >"$AUTOFLEET_DIR/reviewing/44.tries"
  : >"$AUTOFLEET_DIR/reviewing/45.said"
  out="$( cd "$WORK/repo" && . ./scripts/fleet/fleet.sh && cmd_status 2>&1 )"
  line="$(printf '%s\n' "$out" | grep '^review:' || true)"
  [ -n "$line" ] || fail "status printed no review line at all: $out"
  grep -q "1 in flight" <<<"$line" \
    || fail "status counted the record files as reviewers, so a reviewed PR reads as a slot taken forever: $line"
  ok "status counts the lock and not the three records"

  # ...and the OTHER two consumers, asserted by consequence rather than by
  # grepping for the predicate's name -- `live_reviewers` is nested inside
  # `review_open_prs`, so there is no function to inspect, and a text assertion
  # would pass on a file that merely mentions it.
  #
  # `live_reviewers`'s half is not the COUNT -- a record's first field is a head
  # sha, so `reviewer_alive` answers 1 and the count stays right either way. It
  # is that a record counted as a dead reviewer gets DELETED, and `<pr>.done` is
  # the only thing stopping a reviewed head being handed a reviewer every poll.
  # Deleting it puts the re-spawn loop this PR removes straight back.
  #
  # On an OPEN pull request, because the sweep below legitimately removes the
  # records of closed ones -- which is why the first version of this assertion
  # failed against its own fix. Two PRs open: 42 needs a review, 43 already has
  # one on its head.
  rm -f "$AUTOFLEET_DIR/reviewing/42" "$AUTOFLEET_DIR/reviewing"/4[345].*
  printf '[{"number":42,"isDraft":false,"headRefOid":"%s"},{"number":43,"isDraft":false,"headRefOid":"%s"}]\n' \
    "$PR_HEAD" "$PR_HEAD" >"$GH_PRLIST"
  printf '%s\n' "$PR_HEAD"   >"$AUTOFLEET_DIR/reviewing/43.done"
  printf '%s 1\n' "$PR_HEAD" >"$AUTOFLEET_DIR/reviewing/43.tries"
  stub_reviewer submits
  poll_review_open_prs
  [ -e "$AUTOFLEET_DIR/reviewing/43.done" ] \
    || fail "a poll reaped 43.done, so PR 43's reviewed head gets a reviewer again every minute -- the loop this PR exists to remove"
  [ -e "$AUTOFLEET_DIR/reviewing/43.tries" ] \
    || fail "a poll reaped 43.tries, so the attempt count restarts every pass and the cap can never be reached"
  ok "...and a poll leaves an OPEN PR's records alone"

  # ...while the records of a pull request that is no longer open DO go. They
  # were pruned only by `stop_reviewers`, so on a fleet that stays up a merged
  # PR's three files sat here for days -- and they were the input to the count
  # above.
  #
  # RECORDS ONLY, and the lock is out of the sweep's scope by construction --
  # `is_review_record "$rec" || continue`. Not asserted here, and the first
  # version of this phase tried: a lock naming a pid that is not one of our
  # reviewers is reaped by `live_reviewers` in the same pass, correctly, which
  # is the `reaper` phase's whole subject. A phase that planted such a lock and
  # expected it to survive was asserting the opposite of the fleet's own rule.
  printf '%s\n' "$PR_HEAD" >"$AUTOFLEET_DIR/reviewing/99.done"
  : >"$AUTOFLEET_DIR/reviewing/99.said"
  printf '%s 2\n' "$PR_HEAD" >"$AUTOFLEET_DIR/reviewing/99.tries"
  poll_review_open_prs
  for f in 99.done 99.said 99.tries; do
    [ -e "$AUTOFLEET_DIR/reviewing/$f" ] \
      && fail "a closed PR's $f survived the pass, so the directory grows for as long as the dispatcher lives -- and these are the files the count above reads"
  done
  ok "...and a closed PR's records are swept"

  # `stop_reviewers` clears all three. NOT asserted: that it does not SIGNAL
  # them. Treated as locks, their first field is a head sha, `kill` is handed a
  # non-number and fails, and `rm -f` follows on both paths -- so the two
  # spellings are indistinguishable from outside. The branch still belongs
  # there for `reviewer_alive`'s own reason: a numeric-looking first field WOULD
  # be signalled, and nothing guarantees a future record's first field is not
  # numeric. Said rather than asserted, because a phase claiming to pin it would
  # be the inert kind this suite has shipped twice.
  in_poll stop_reviewers >/dev/null 2>&1
  [ -e "$AUTOFLEET_DIR/reviewing/43.done" ] \
    && fail "stop_reviewers left 43.done behind, so the next dispatcher inherits a stale record"
  ok "...and a stop clears the records"
  ;;

  holds)
    # TWO HOLDS AT ONCE, which is the state the shared say-once marker broke.
    # A foundation issue in flight and a PR whose reviewer hit the cap are
    # evaluated in the same poll body; sharing one file meant each overwrote the
    # other's reason and BOTH re-announced every poll -- the flooding this whole
    # change removes. `capped` runs with no foundation issue, so it stayed green
    # against the shared marker. Found by the independent review.
    make_fixture; stub_reviewer silent
    export AUTOFLEET_REVIEW_MAX_TRIES=1
    printf '[{"number":42,"isDraft":false,"headRefOid":"%s"}]\n' "$(cat "$GH_HEAD")" >"$GH_PRLIST"
    # Spend the one try, so the next pass holds on the cap.
    poll_review_open_prs
    await lock_held no || fail "the first reviewer never released its lock"

    # ...and a foundation hold standing at the same time.
    mkdir -p "$AUTOFLEET_DIR"
    (cd "$WORK/repo" && . ./scripts/fleet/fleet.sh >/dev/null 2>&1
     foundation_hold_say "1" "#1 is a foundation issue and is still in flight; it lands alone, so") \
      >/dev/null 2>&1

    n_cap()   { local n; n="$(grep -c "which is the cap" "$AUTOFLEET_DIR/fleet.log" 2>/dev/null || true)"; printf '%s' "${n:-0}"; }
    n_found() { local n; n="$(grep -c "lands alone" "$AUTOFLEET_DIR/fleet.log" 2>/dev/null || true)"; printf '%s' "${n:-0}"; }
    # Let each hold speak ONCE first. The baseline is "both have been
    # announced"; what this phase is about is whether they then stay quiet with
    # the other one standing. Taken before the first announcement, the cap's own
    # correct first line read as a repeat.
    poll_review_open_prs
    (cd "$WORK/repo" && . ./scripts/fleet/fleet.sh >/dev/null 2>&1
     foundation_hold_say "1" "#1 is a foundation issue and is still in flight; it lands alone, so") \
      >/dev/null 2>&1
    before_cap="$(n_cap)"
    before_found="$(n_found)"
    [ "$before_cap" -ge 1 ] || fail "the cap hold never announced at all, so this asserts nothing"
    [ "$before_found" -ge 1 ] || fail "the foundation hold never announced at all"
    for _ in 1 2 3; do
      poll_review_open_prs
      (cd "$WORK/repo" && . ./scripts/fleet/fleet.sh >/dev/null 2>&1
       foundation_hold_say "1" "#1 is a foundation issue and is still in flight; it lands alone, so") \
        >/dev/null 2>&1
    done
    after_cap="$(n_cap)"
    after_found="$(n_found)"
    [ "$before_cap" = "$after_cap" ] \
      || fail "the cap hold re-announced while a foundation hold stood ($before_cap then $after_cap)"
    [ "$before_found" = "$after_found" ] \
      || fail "the foundation hold re-announced while a cap hold stood ($before_found then $after_found)"
    ok "two holds at once each stay quiet; neither overwrites the other's reason"
    ;;

# --------------------------------------------------------------------- queue
  queue)
  make_fixture; stub_reviewer marked

  printf 'AUTOFLEET_REVIEW_MODE=github\n' >"$WORK/repo/.autofleet/config"
  poll_review_open_prs
  [ -z "$(find "$AUTOFLEET_DIR/reviewing" -type f 2>/dev/null)" ] \
    || fail "github mode started a reviewer"
  ok "review_open_prs starts nothing in github mode"

  printf 'AUTOFLEET_REVIEW_MODE=local\n' >"$WORK/repo/.autofleet/config"
  # A draft is not asking for a verdict yet.
  printf '[{"number":42,"isDraft":true,"headRefOid":"%s"}]\n' "$(cat "$GH_HEAD")" >"$GH_PRLIST"
  poll_review_open_prs
  [ -z "$(find "$AUTOFLEET_DIR/reviewing" -type f 2>/dev/null)" ] \
    || fail "a draft PR was sent for review"
  ok "...nor on a draft PR"

  printf '[{"number":42,"isDraft":false,"headRefOid":"%s"}]\n' "$(cat "$GH_HEAD")" >"$GH_PRLIST"
  poll_review_open_prs
  # The reviewer is a background child of a subshell that has since exited, so
  # what is waited for is the review it was started to produce, not its pid.
  await n_reviews 1 || fail "local mode did not review the open PR"
  ok "...and reviews an open non-draft PR of our own in local mode"

  # ...and never twice. review.sh's own exit 8 is what makes that true, which is
  # why the marker file is a courtesy and not the correctness argument.
  #
  # Asserted on whether a REVIEWER WAS STARTED rather than on the review count,
  # and after waiting for the second pass's child to finish: a reviewer that
  # started and then correctly declined to submit would leave the count at 1 and
  # look identical to one that never ran.
  before="$(n_started)"
  poll_review_open_prs
  await n_reviews 1 20 >/dev/null 2>&1 || true
  [ "$(n_started)" = "$before" ] \
    || fail "a second pass started another reviewer on a head that already has one"
  [ "$(n_reviews)" = 1 ] || fail "a second pass submitted a second review"
  ok "...and a second pass over the same head starts nothing"
  ;;

# ------------------------------------------------------------------ midstop
  midstop)
    # `stop.sh --now` freezes the agents. A reviewer that read the stop once, at
    # the top, was not one of them: 90 seconds into a 30-minute budget it kept
    # running with this machine's gh credentials. Found by the independent
    # review of the change that added it.
    make_fixture; stub_reviewer hang
    export AUTOFLEET_REVIEW_TIMEOUT=120
    run_it 42 >"$WORK/out" 2>&1 &
    runner=$!
    # Wait until the reviewer is actually up, so this tests the mid-run path and
    # not the check at the top.
    await n_started 1 60 || fail "the reviewer never started"
    : >"$AUTOFLEET_DIR/STOP"
    waited=0
    while kill -0 "$runner" 2>/dev/null && [ "$waited" -lt 60 ]; do
      sleep 1; waited=$((waited + 1))
    done
    wait "$runner"; rc=$?
    [ "$rc" = 3 ] || { cat "$WORK/out" >&2; fail "a stop mid-review did not exit 3 (got $rc)"; }
    ok "a stop that appears mid-review kills the reviewer and exits 3"
    pgrep -f "$WORK/bin/fake-reviewer" >/dev/null 2>&1 \
      && fail "the reviewer is still running after the stop"
    ok "...and does not leave it running"
    pgrep -f "sleep 3607" >/dev/null 2>&1 \
      && fail "the reviewer's own child outlived the stop"
    ok "...nor anything it had started"
    ;;

# ------------------------------------------------------------------- reaper
  reaper)
    # The second place the fleet signals a pid it read out of a file. Nothing
    # clears $REVIEWING_DIR across a dispatcher's death, so a stale marker
    # outlives its process and the number is reused -- `kill -0` cannot tell.
    make_fixture; stub_reviewer marked
    mkdir -p "$AUTOFLEET_DIR/reviewing"

    # A live pid that is NOT a reviewer, exactly as pid reuse produces.
    sleep 120 &
    stranger=$!
    printf '%s %s\n' "$stranger" "$(cat "$GH_HEAD")" >"$AUTOFLEET_DIR/reviewing/99"
    # NOT `>/dev/null 2>&1`: a source-time `die` in here is invisible that way,
    # and the phase then reports the consequence rather than the cause. That is
    # exactly how this file passed on a laptop and failed in CI.
    out="$(in_poll stop_reviewers 2>&1)"
    grep -q "no orca CLI answers" <<<"$out" \
      && fail "fleet.sh would not source, so nothing under test ran: $out"
    if kill -0 "$stranger" 2>/dev/null; then
      ok "a marker naming a live stranger is cleared without signalling it"
    else
      kill "$stranger" 2>/dev/null
      fail "stop_reviewers SIGTERMed a process that is not one of ours"
    fi
    kill "$stranger" 2>/dev/null
    [ -e "$AUTOFLEET_DIR/reviewing/99" ] && fail "the stale marker was not cleared"
    ok "...and the marker is gone, so that PR is reviewable again"

    # A marker naming nothing at all must not become `kill 0`, which is this
    # shell's own process group.
    printf 'notapid x\n' >"$AUTOFLEET_DIR/reviewing/98"
    in_poll stop_reviewers >/dev/null 2>&1
    [ -e "$AUTOFLEET_DIR/reviewing/98" ] && fail "an unreadable marker was not cleared"
    ok "...and an unreadable marker is cleared rather than signalled"
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
  echo "usage: $0 holds|once|retries|capped|mode|refuses|stopped|submits|unmarked|silent|skips|stale|midstop|reaper|timeout|queue" >&2
  exit 2 ;;
esac
