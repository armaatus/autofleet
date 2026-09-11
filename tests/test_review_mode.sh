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
#   test_review_mode.sh records   record-review.sh writes the marker guard.py's
#                                 push gate reads, on a worktree with no
#                                 `.autofleet/run` yet -- and it is asked of the
#                                 HOOK rather than restated here. It was making
#                                 `.orca`, the directory the marker lived in
#                                 before it moved, so every way in other than a
#                                 fleet-provisioned worktree answered "I have
#                                 reviewed, let me push" with a redirect error.
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
  # (fleet.sh: `runner_available || die ...`, and the Orca driver is what prints
  # "no orca CLI answers here" underneath it -- which is what the two phases
  # below grep for as a canary that fleet.sh sourced at all). This file
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

# ------------------------------------------------------------------- records
  records)
  # The OTHER half of local review mode, and the one with no pull request in it:
  # guard.py refuses a push from a fleet worktree until
  # `.autofleet/run/reviewed-<sha>` exists, and record-review.sh is the only
  # thing that writes it. It was making `.orca` -- the directory the marker lived
  # in before it moved -- and then writing into `.autofleet/run`, which
  # .gitignore keeps out of the tree, so the redirect failed and the marker never
  # appeared.
  #
  # NOT on a worktree the fleet opened, and the first version of this comment
  # claimed otherwise: `env.sh` and `agent-autostart.sh` both `mkdir -p
  # .autofleet/run`, and `setup.sh` runs `env.sh`, so a fleet-provisioned
  # worktree had the directory before any agent reached this script. What it
  # breaks is every other way in -- a fresh clone, a worktree made by hand, a
  # host project running this before its first fleet pass -- where the answer to
  # "I have reviewed, let me push" is a redirect error. The correction came from
  # the review of the fix. Nothing asserted any of it because nothing ran this
  # script at all; the `.orca` itself was found by widening the runner-seam grep.
  make_fixture
  [ -e "$WORK/repo/.autofleet/run" ] \
    && fail "the fixture already has the directory under test, so this asserts nothing"
  out="$( cd "$WORK/repo" && ./scripts/fleet/record-review.sh --none 2>&1 )"; rc=$?
  [ "$rc" = 0 ] || fail "record-review.sh could not record a review on a fresh worktree (rc $rc): $out"
  marker="$WORK/repo/.autofleet/run/reviewed-$PR_HEAD"
  [ -s "$marker" ] \
    || fail "the marker guard.py reads was not written, so an agent that HAS reviewed still cannot push: $out"
  [ -e "$WORK/repo/.orca" ] \
    && fail "it still makes the directory the marker moved out of"
  ok "record-review.sh writes the push gate's marker on a worktree that has no run dir yet"

  # ...and the marker is the one the HOOK reads, asked of the hook rather than
  # restated here -- the whole of #183 was two programs disagreeing about one
  # directory.
  owned="$WORK/fleet/worktrees"
  mkdir -p "$owned"
  printf '%s\n' "$WORK/repo" >"$owned/7"
  asks() {
    ( cd "$WORK/repo" \
        && printf '%s' "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"git push origin HEAD\"}}" \
        | AUTOFLEET_DIR="$WORK/fleet" python3 "$REPO_ROOT/.claude/hooks/guard.py" >/dev/null 2>&1 )
    printf '%s' "$?"
  }
  [ "$(asks)" = 0 ] \
    || fail "the hook still refuses the push with the review recorded, so the two disagree about the marker"
  mv "$marker" "$marker.parked"
  [ "$(asks)" = 2 ] \
    || fail "the hook allows the push with no marker at all, so the gate this records for is off"
  ok "...and it is the marker the push gate actually reads"
  ;;

  *)
  echo "usage: $0 mode|refuses|stopped|submits|unmarked|silent|skips|stale|midstop|reaper|timeout|queue|records" >&2
  exit 2 ;;
esac
