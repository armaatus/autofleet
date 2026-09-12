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
#   test_review_mode.sh stubwrite the reviewer stub's heredoc is unquoted, so its
#                                 body is expanded on the way to the file and a
#                                 backtick in prose is a command. One named
#                                 `stub_reviewer` itself: every phase but `mode`
#                                 then recursed forever, and the suite hung with
#                                 nothing to read (CI run 34658821929, exit 143
#                                 at nine minutes). tests/run.sh bounds each
#                                 phase now, so a wedge is a FAIL that names
#                                 itself; this catches the two shapes named in
#                                 the arm, not every write-time expansion.
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
  # The sweep asks for a PR's STATE before deleting its transcripts -- an
  # author-scoped open list cannot answer "is this still open", so absence from
  # it is not enough. Defaults to CLOSED because every PR the sweep asks about
  # has already fallen off the open list; `$GH_PR_STATE` overrides.
  *"pr view"*"--json state"*) cat "${GH_PR_STATE:-/dev/null}" 2>/dev/null || true
                              [ -s "${GH_PR_STATE:-/dev/null}" ] || echo CLOSED
                              exit 0 ;;
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
  # NOTE: no default arm, deliberately-for-now. An unknown mode falls through and
  # behaves like \`silent\`, which is how \`stub_reviewer submits\` -- a mode that
  # was never defined -- read as the opposite of what it did. Adding
  # \`*) exit 64\` is the obvious fix and it wedges the suite: several phases pass
  # modes this case does not name and rely on the fall-through. Recorded rather
  # than half-done; the callsite that was wrong is fixed, and the sharp edge is
  # in armaatus/autofleet#71 with the other guards aimed slightly off.
  #
  # THE BACKTICKS ABOVE ARE ESCAPED, and every backtick added below this line
  # must be too. This is an UNQUOTED heredoc, so it has no comment lines: a \`#\`
  # is text being written to a file, and the shell still runs command
  # substitutions on it. Unescaped, \`stub_reviewer submits\` above called this
  # very function, which rewrote the stub, which called it again -- the suite
  # hung from \`refuses\` onwards with no failure and no output, and CI killed it
  # at nine minutes (run 34658821929).
  #
  # tests/run.sh bounds each phase now, but do not read that as cover for this:
  # the bound names a phase that BLOCKS, and this one forks. Its own note says
  # so. A repeat of this exact bug still outruns the watchdog, because killing
  # the top of a recursion that is busy making more of itself is not a fix.
  # Escaping the backtick is.
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
# One function WITH ITS ARGUMENTS. `in_poll` runs each argument as a function
# name, which is right for driving several watchers in one pass and silently
# wrong for anything that takes parameters -- the arguments simply never arrive.
in_fleet_fn() { (cd "$WORK/repo" && . ./scripts/fleet/fleet.sh >/dev/null 2>&1; "$@"); }

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

  # ...AS THE DISPATCHER CALLS IT, which is the only way the refund path is
  # reached at all. `run_it` sets no AUTOFLEET_REVIEW_MARKER, so `TRIES_MARKER`
  # is empty and `unspent_try` returns at its first line -- which is why the bug
  # this asserts survived the suite: with the marker set, the same path read
  # `$head` before it was assigned, and `set -u` terminated the script with
  # `head: unbound variable` and exit 1 instead of the documented 3. The try the
  # dispatcher had already spent was then never refunded, which is the opposite
  # of what the call is there for. Found by the independent review.
  mkdir -p "$AUTOFLEET_DIR/reviewing"
  printf '%s 2\n' "$PR_HEAD" >"$AUTOFLEET_DIR/reviewing/42.tries"
  out="$( cd "$WORK/repo" && AUTOFLEET_REVIEW_MARKER="$AUTOFLEET_DIR/reviewing/42" \
            ./scripts/fleet/review.sh 42 2>&1 )"; rc=$?
  [ "$rc" = 3 ] \
    || fail "called the way the dispatcher calls it, a stopped fleet exited $rc rather than 3: $out"
  grep -q "unbound variable" <<<"$out" \
    && fail "the stopped path died on a shell variable instead of exiting 3: $out"
  read -r _h n <"$AUTOFLEET_DIR/reviewing/42.tries" 2>/dev/null || n=""
  [ "${n:-}" = 1 ] \
    || fail "a stopped run did not refund the try the dispatcher spent before the spawn (tries now ${n:-gone})"
  ok "...and refunds the try the dispatcher spent, with the marker set"

  # THE OTHER PRE-HEAD EXIT, and the one that makes the `${head:-}` guard
  # load-bearing rather than defensive: `fleet_owner_repo` failing calls
  # `unspent_try`, which matches on a head this run has not read yet. Without the
  # guard that is an unbound expansion under `set -u`, so the run dies with exit
  # 1 instead of 2 and refunds nothing.
  rm -f "$AUTOFLEET_DIR/STOP"
  printf '%s 2\n' "$PR_HEAD" >"$AUTOFLEET_DIR/reviewing/42.tries"
  # SAVED, because the restore below has to put back the real thing. The first
  # version called `make_gh_stub`, which does not exist anywhere in this
  # repository -- and `2>/dev/null || true` swallowed the 127, so the line read
  # as "put the working stub back" and put nothing back. Every assertion after
  # it would have run against a `gh` that answers nothing while claiming to test
  # something else. Found by the independent review.
  cp "$WORK/bin/gh" "$WORK/bin/gh.working"
  cat >"$WORK/bin/gh" <<'GHSTUB'
#!/usr/bin/env bash
case "$*" in
  *"repo view"*) echo "could not resolve" >&2; exit 1 ;;
esac
exit 1
GHSTUB
  chmod +x "$WORK/bin/gh"
  out="$( cd "$WORK/repo" && AUTOFLEET_REVIEW_MARKER="$AUTOFLEET_DIR/reviewing/42" \
            ./scripts/fleet/review.sh 42 2>&1 )"; rc=$?
  mv -f "$WORK/bin/gh.working" "$WORK/bin/gh"
  grep -q "unbound variable" <<<"$out" \
    && fail "a gh that could not name the repository died on a shell variable: $out"
  [ "$rc" = 2 ] \
    || fail "gh failing to name the repository exited $rc rather than 2: $out"
  # ...AND IT REFUNDED. Asserting only the exit code let the wrong refund
  # function stand: `unspent_try` matches on a head this path has not read yet,
  # so it returned without doing anything and three gh outages a poll apart
  # still retired the head -- which is the failure this whole knob exists to
  # avoid, and which docs/CONFIGURATION.md and config.sh both promise against.
  # Found by the independent review.
  read -r _h n <"$AUTOFLEET_DIR/reviewing/42.tries" 2>/dev/null || n=""
  [ "${n:-}" = 1 ] \
    || fail "a gh that cannot name the repository spent a try; three outages a poll apart retire the head (tries now ${n:-gone})"
  ok "...and a gh that cannot name the repository exits 2 and refunds"
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

    # EXIT 7 TOO, which is the other half of #33's Acceptance -- "a reviewer that
    # submitted nothing (exit 5) OR WAS KILLED (exit 7) is retried" -- and the
    # half nothing pinned. The pre-existing `timeout` phase is the only exit-7
    # coverage and it calls `run_it`, which sets no AUTOFLEET_REVIEW_MARKER: with
    # DONE_MARKER empty `record_done` returns at its first line, so that phase
    # cannot observe the record either way. Add `record_done` to the exit-7
    # branch and the whole suite stays green -- which is the silent-block
    # direction #33 calls "the whole of this issue". Found by the independent
    # review.
    rm -f "$AUTOFLEET_DIR/reviewing/42.done" "$AUTOFLEET_DIR/reviewing/42.tries"
    stub_reviewer hang
    out="$( cd "$WORK/repo" && AUTOFLEET_REVIEW_MARKER="$AUTOFLEET_DIR/reviewing/42" \
              AUTOFLEET_REVIEW_TIMEOUT=1 ./scripts/fleet/review.sh 42 2>&1 )"; rc=$?
    [ "$rc" = 7 ] \
      || fail "a reviewer past its deadline exited $rc rather than 7: $out"
    [ -e "$AUTOFLEET_DIR/reviewing/42.done" ] \
      && fail "a reviewer KILLED at the deadline wrote the done record, so that head is never reviewed again -- the silent block #33 exists to remove"
    ok "...and a reviewer killed at the deadline is not recorded as done"
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

    # ...and the cap refuses a value that would turn it off. `[ x -ge abc ]`
    # prints "integer expression expected" and returns 2, so the cap test is
    # FALSE and the unbounded behaviour this knob exists to bound is back --
    # silently, since fleet.sh runs without `-e`. 0 is refused separately: it
    # reads as "never review", and the gave-up line would announce "0 reviewers
    # submitted nothing, which is the cap", which is true of no run. The knob had
    # this reasoning written down one file over and no check of its own. Found by
    # the independent review.
    for bad in abc 0 2x -1; do
      cfg_out="$( (cd "$WORK/repo" \
        && AUTOFLEET_REVIEW_MAX_TRIES="$bad" bash -c '. ./scripts/fleet/config.sh') 2>&1 )"
      cfg_rc=$?
      [ "$cfg_rc" = 2 ] \
        || fail "AUTOFLEET_REVIEW_MAX_TRIES='$bad' was accepted (rc=$cfg_rc): $cfg_out"
      grep -q "must be a positive whole number" <<<"$cfg_out" \
        || fail "AUTOFLEET_REVIEW_MAX_TRIES='$bad' failed without saying why: $cfg_out"
    done
    ok "...and a cap that is not a positive number is refused, not ignored"

    # THROUGH THE CONFIG FILE, which is the route that matters and the one the
    # check could not see: `.autofleet/config` is sourced LAST so it can override
    # the defaults, and the check sat with the defaults. A host project writing
    # `AUTOFLEET_REVIEW_MAX_TRIES=three` into the file docs/CONFIGURATION.md
    # documents this knob in reached the cap unchecked, so the guard was
    # decorative for every real user of it and green here. The row above passes
    # either way; this one is the one that failed. Found by the independent
    # review of the change that added the check.
    hostcfg="$WORK/hostcfg"
    for bad in three 0 ""; do
      printf 'AUTOFLEET_REVIEW_MAX_TRIES=%s\n' "$bad" >"$hostcfg"
      cfg_out="$( (cd "$WORK/repo" \
        && env -u AUTOFLEET_REVIEW_MAX_TRIES AUTOFLEET_CONFIG="$hostcfg" \
             bash -c '. ./scripts/fleet/config.sh') 2>&1 )"
      cfg_rc=$?
      [ "$cfg_rc" = 2 ] \
        || fail "a config file setting the cap to '$bad' was accepted (rc=$cfg_rc): $cfg_out"
      grep -q "must be a positive whole number" <<<"$cfg_out" \
        || fail "a config file setting the cap to '$bad' failed without saying why: $cfg_out"
    done
    ok "...including when it arrives through .autofleet/config, which is read last"

    printf 'AUTOFLEET_REVIEW_MAX_TRIES=5\n' >"$hostcfg"
    ( cd "$WORK/repo" && env -u AUTOFLEET_REVIEW_MAX_TRIES AUTOFLEET_CONFIG="$hostcfg" \
        bash -c '. ./scripts/fleet/config.sh' ) >/dev/null 2>&1 \
      || fail "a valid cap in .autofleet/config was refused"
    ok "...while a whole number there is accepted"

    ( cd "$WORK/repo" && AUTOFLEET_REVIEW_MAX_TRIES=4 bash -c '. ./scripts/fleet/config.sh' ) \
      >/dev/null 2>&1 || fail "a valid cap was refused"
    ok "...while a whole number is accepted"
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
  stub_reviewer marked
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

  # --------------------------------------------- when the sweep must NOT run
  #
  # The sweep decides what is gone by ABSENCE from a listing, so it is only ever
  # as good as the listing. Both refusals below are argued at length where they
  # are written and neither was pinned: deleting either `return 0` left the whole
  # suite green, which is the shape this PR calls out twice and the standard
  # CLAUDE.md hard rule 3 sets. Found by the independent review.
  #
  # The records are a live PR's `.done` -- the one thing stopping a reviewed head
  # being handed a reviewer every poll -- and its attempt count. Sweeping them
  # for want of a readable listing puts back the loop this PR removes.
  plant_records() {
    mkdir -p "$AUTOFLEET_DIR/reviewing"
    printf '%s\n' "$PR_HEAD"   >"$AUTOFLEET_DIR/reviewing/$1.done"
    printf '%s 1\n' "$PR_HEAD" >"$AUTOFLEET_DIR/reviewing/$1.tries"
  }
  survived() { [ -e "$AUTOFLEET_DIR/reviewing/$1.done" ] && [ -e "$AUTOFLEET_DIR/reviewing/$1.tries" ]; }

  # 1. A listing that does not parse. `open_prs` comes back EMPTY, which is
  #    indistinguishable from "no PR is open" -- and those are opposite
  #    instructions. Empty means sweep nothing, not sweep everything.
  rm -f "$AUTOFLEET_DIR/reviewing"/*
  plant_records 77
  printf 'not json at all\n' >"$GH_PRLIST"
  poll_review_open_prs
  survived 77 \
    || fail "an unparseable PR listing swept a live PR's records, so its reviewed head gets a reviewer again every poll"
  ok "a listing that does not parse sweeps nothing"

  # 1b. ...and an EMPTY BUT VALID listing, which is the only case the emptiness
  #     guard still catches on its own. `[]` parses, so `prs_answered` is `yes`
  #     and the refusal above does not fire; `open_prs` is empty and means "no PR
  #     is open" rather than "could not tell", and the two reach the sweep as the
  #     same string. Written as its own row because the obvious one -- the
  #     unparseable listing above -- is pinned by `prs_answered` and leaves the
  #     emptiness guard free to be deleted with the suite still green. That is
  #     the "passes for a reason other than the one it claims" this file keeps a
  #     tally of; this is the row that actually holds it.
  rm -f "$AUTOFLEET_DIR/reviewing"/*
  plant_records 77
  printf '[]\n' >"$GH_PRLIST"
  poll_review_open_prs
  survived 77 \
    || fail "an empty PR listing swept the records, so a transient 'no PRs' answer loses a live PR's attempt count"
  ok "...and neither does an empty but valid one"

  # 2. A listing at the PAGE LIMIT. `open_prs` is NON-EMPTY here and still not an
  #    answer: an absent PR and one on the next page cannot be told apart, so the
  #    emptiness guard above does not see this case at all. #72 added
  #    `prs_answered` for its own sweep; this one reads the same signal.
  rm -f "$AUTOFLEET_DIR/reviewing"/*
  plant_records 77
  python3 - "$GH_PRLIST" "$PR_HEAD" <<'PY2'
import json, sys
# Exactly `pr_page` entries, none of them 77 -- so on a listing this size the
# sweep must refuse rather than conclude 77 is gone.
json.dump([{"number": 100 + i, "isDraft": False, "headRefOid": sys.argv[2]}
           for i in range(50)], open(sys.argv[1], "w"))
PY2
  poll_review_open_prs
  survived 77 \
    || fail "a listing at the page limit swept the records of a PR that may simply be on the next page"
  ok "...and neither does one truncated at the page limit"

  # 3. A DRAFT is open. The review loop skips drafts, and the sweep must not read
  #    that as gone: sweeping a draft's records restarts its attempt count the
  #    moment it is marked ready. The one draft fixture in this file plants no
  #    records, so the guarantee `review_open_prs` states was unasserted.
  rm -f "$AUTOFLEET_DIR/reviewing"/*
  plant_records 78
  printf '[{"number":78,"isDraft":true,"headRefOid":"%s"}]\n' "$PR_HEAD" >"$GH_PRLIST"
  poll_review_open_prs
  survived 78 \
    || fail "a poll swept an open DRAFT's records, so its attempt count restarts when it is marked ready"
  ok "...and a draft counts as open, so its records are left alone"
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
  sweeps)
  # NOTHING EVICTED ANYTHING until this change. Reviewer transcripts, fleet.log
  # and the `reviewed-<sha>` records only ever grew: 46 transcripts and 184K in
  # under two days on the machine this was written on, 65% of them belonging to
  # pull requests that had already merged. The cost is not the bytes -- it is
  # that stale state gets read as current. armaatus/autofleet#70.
  # `stub_reviewer`, NOT make_fixture alone. Without it AUTOFLEET_REVIEW_CMD
  # stays at its `claude` default, PR 42 is non-draft, the mode is local and the
  # graphql stub returns no reviews -- so `review_open_prs` launches a REAL agent
  # with an 1800s timeout, twice, orphaned past the end of the suite. `gh` is
  # stubbed so they cannot reach GitHub; they spend real budget anyway. Found by
  # the independent review.
  make_fixture; stub_reviewer silent
  mkdir -p "$AUTOFLEET_DIR/reviews"
  # Two PRs: 42 is open, 99 is not.
  for h in aaaaaaaa bbbbbbbb cccccccc dddddddd; do
    : >"$AUTOFLEET_DIR/reviews/pr-42-$h.log"; sleep 0.01
  done
  : >"$AUTOFLEET_DIR/reviews/pr-99-eeeeeeee.log"
  # ONE GRACE PASS FIRST. #70's Acceptance: "nothing is removed on the pass it
  # becomes eligible". `reap_merged` runs immediately before the sweep, so a PR
  # that merged this pass has already dropped off the open list -- and losing
  # every transcript in the same breath as the merge is exactly when somebody
  # wants them. Found by the independent review.
  # A TRANSCRIPT IS NOT SWEPT UNDER ITS OWN REVIEWER. `review.sh` holds the file
  # open for up to AUTOFLEET_REVIEW_TIMEOUT while the grace is one pass, so a PR
  # that auto-merges two minutes into its own review would have had the output
  # unlinked under the agent still writing it. Found by `/code-review`.
  : >"$AUTOFLEET_DIR/reviews/pr-98-99999999.log"
  mkdir -p "$AUTOFLEET_DIR/reviewing"
  # A pid `reviewer_alive` accepts as OURS. The sweep asks that rather than
  # testing the marker's existence -- a marker left by a SIGKILL would otherwise
  # block this PR's transcripts from ever being swept -- so the harness's own
  # `$$` is correctly rejected and would make this assert nothing.
  printf '#!/bin/sh\nsleep "$@"\n' >"$WORK/bin/review.sh"; chmod +x "$WORK/bin/review.sh"
  "$WORK/bin/review.sh" 30 & keeper=$!
  printf '%s %s\n' "$keeper" "$PR_HEAD" >"$AUTOFLEET_DIR/reviewing/98"
  AUTOFLEET_KEEP_REVIEWS=2 poll_review_open_prs
  AUTOFLEET_KEEP_REVIEWS=2 poll_review_open_prs
  [ -e "$AUTOFLEET_DIR/reviews/pr-98-99999999.log" ] \
    || fail "a transcript was swept while a reviewer for that PR was still writing to it"
  kill "$keeper" 2>/dev/null; wait "$keeper" 2>/dev/null
  rm -f "$AUTOFLEET_DIR/reviewing/98"
  ok "a transcript is not swept under its own running reviewer"

  # ...and a STALE marker does not block it forever. The sweep used to test the
  # marker's existence, so one left by a SIGKILL meant that PR's transcripts
  # were never swept again -- the same permanent block the rotation had, for the
  # same reason. Found by the independent review.
  # ...and a marker whose holder `ps` CANNOT NAME does not block it forever.
  # A dead-pid marker is not the case to worry about -- `live_reviewers` reaps
  # those in the same pass -- so the only marker that can persist is
  # `reviewer_alive`'s rc 2, which nothing ever clears. Testing the marker's
  # EXISTENCE rather than asking meant that PR's transcripts were never swept
  # again. Same permanent block as the rotation had, for the same reason, and
  # asserted the same way: the decision, not the OS condition. Found by the
  # independent review.
  : >"$AUTOFLEET_DIR/reviews/pr-98-99999999.log"
  rm -f "$AUTOFLEET_DIR/reviews/.closed-98"
  printf '%s %s\n' 999999 "$PR_HEAD" >"$AUTOFLEET_DIR/reviewing/98"
  for _ in 1 2; do
    ( cd "$WORK/repo" && . ./scripts/fleet/fleet.sh >/dev/null 2>&1
      reviewer_alive() { return 2; }
      AUTOFLEET_KEEP_REVIEWS=2 prune_review_logs "42" yes ) >/dev/null 2>&1
  done
  rm -f "$AUTOFLEET_DIR/reviewing/98"
  [ -e "$AUTOFLEET_DIR/reviews/pr-98-99999999.log" ] \
    && fail "a marker whose holder ps cannot name blocked the sweep permanently, so that PR's transcripts are never collected"
  ok "...and a marker ps cannot name does not block it forever"

  # ...and now the grace, from a clean slate: the passes above already spent
  # PR 99's, which is the rule working rather than a fixture problem.
  rm -f "$AUTOFLEET_DIR/reviews"/.closed-*
  : >"$AUTOFLEET_DIR/reviews/pr-99-eeeeeeee.log"
  AUTOFLEET_KEEP_REVIEWS=2 poll_review_open_prs
  [ -e "$AUTOFLEET_DIR/reviews/pr-99-eeeeeeee.log" ] \
    || fail "a closed PR lost its transcripts on the pass it closed, with no grace"
  ok "a closed PR keeps its transcripts for one pass"
  AUTOFLEET_KEEP_REVIEWS=2 poll_review_open_prs
  [ -e "$AUTOFLEET_DIR/reviews/pr-99-eeeeeeee.log" ] \
    && fail "a transcript for a PR that is no longer open survived the grace pass"
  ok "...and goes on the next one"

  # ...AND ONLY WHEN THE PR IS CONFIRMED CLOSED. Absence from the open list is
  # not enough: that list is `--author "@me"`, so on a host whose worktrees open
  # PRs under a different account than the dispatcher's `gh` login, every PR
  # reads as closed and loses its transcripts. Found by the independent review,
  # which noted the comment named this hazard while the code guarded the other
  # two. Here the PR answers OPEN, so nothing may go.
  : >"$AUTOFLEET_DIR/reviews/pr-95-77777777.log"
  printf 'OPEN\n' >"$WORK/pr-state"
  GH_PR_STATE="$WORK/pr-state" AUTOFLEET_KEEP_REVIEWS=5 poll_review_open_prs
  GH_PR_STATE="$WORK/pr-state" AUTOFLEET_KEEP_REVIEWS=5 poll_review_open_prs
  [ -e "$AUTOFLEET_DIR/reviews/pr-95-77777777.log" ] \
    || fail "a PR missing from the author-scoped list but still OPEN lost its transcripts"
  ok "a PR that is still open keeps its transcripts whatever the list says"
  rm -f "$AUTOFLEET_DIR/reviews/pr-95-77777777.log" "$AUTOFLEET_DIR/reviews"/.closed-95

  # ...ASKED ONCE PER PULL REQUEST, not once per transcript. The call sat in the
  # deleting loop, so the PR #70 measured with thirteen transcripts cost
  # thirteen identical calls -- every poll, forever, because a PR that answers
  # OPEN is never deleted and so never stops being a candidate. At the default
  # 60s poll that is ~18,700 calls a day against the same gh budget
  # `next_issue` and the review pass spend, and gh's secondary rate limit is how
  # this dispatcher breaks. The assertion is the CALL COUNT, because the
  # keep-it behaviour above passed either way. Found by the independent review.
  rm -f "$AUTOFLEET_DIR/reviews"/.closed-* "$AUTOFLEET_DIR/reviews"/pr-95-*.log
  for h in 11111111 22222222 33333333; do
    : >"$AUTOFLEET_DIR/reviews/pr-95-$h.log"; sleep 0.01
  done
  printf 'OPEN\n' >"$WORK/pr-state"
  GH_PR_STATE="$WORK/pr-state" AUTOFLEET_KEEP_REVIEWS=2 poll_review_open_prs
  : >"$GH_CALLS"
  GH_PR_STATE="$WORK/pr-state" AUTOFLEET_KEEP_REVIEWS=2 poll_review_open_prs
  n="$(grep -c 'pr view 95 --json state' "$GH_CALLS" 2>/dev/null || true)"
  [ "$n" = 1 ] \
    || fail "the sweep asked GitHub about PR 95 $n time(s) in one pass; it is one question per pull request, not one per transcript"
  ok "a candidate PR's state is asked once per pass, whatever its transcript count"

  # ...and an OPEN answer puts it BACK ON THE OPEN LIST, so the newest-N cap
  # applies to it. Left a permanent candidate, its transcripts were never swept
  # AND never trimmed -- the cap iterates the open list, which by construction
  # did not contain it -- so the one case that call exists to protect was the
  # one case that grew without bound.
  n="$(ls "$AUTOFLEET_DIR/reviews"/pr-95-*.log 2>/dev/null | grep -c . || true)"
  [ "$n" = 2 ] \
    || fail "$n transcripts survived AUTOFLEET_KEEP_REVIEWS=2 for a PR confirmed OPEN; the cap does not reach it and the store grows without bound"
  ok "...and is capped like any other open PR"
  rm -f "$AUTOFLEET_DIR/reviews"/pr-95-*.log "$AUTOFLEET_DIR/reviews"/.closed-95

  # THE GRACE IS PER PULL REQUEST, not per transcript. The marker used to be
  # created inside the deleting loop, so a PR's FIRST transcript bought the
  # grace and every other one was deleted on that same pass -- all but one, in
  # the same breath as the merge, which is exactly what the grace exists to
  # prevent. #70 measured thirteen transcripts on one PR. The earlier phase
  # could not catch it because no PR here ever had two alive at once. Found by
  # the independent review.
  rm -f "$AUTOFLEET_DIR/reviews"/.closed-* "$AUTOFLEET_DIR/reviews"/pr-*.log
  for h in aaaa1111 bbbb2222 cccc3333; do
    : >"$AUTOFLEET_DIR/reviews/pr-96-$h.log"
  done
  AUTOFLEET_KEEP_REVIEWS=5 poll_review_open_prs
  n="$(ls "$AUTOFLEET_DIR/reviews"/pr-96-*.log 2>/dev/null | grep -c .)"
  [ "$n" = 3 ] \
    || fail "the grace pass kept $n of 3 transcripts for a PR that just closed; it protects the pull request, not one file"
  ok "a closed PR keeps ALL its transcripts for the grace pass"
  : >"$AUTOFLEET_DIR/fleet.log"
  AUTOFLEET_KEEP_REVIEWS=5 poll_review_open_prs
  n="$(ls "$AUTOFLEET_DIR/reviews"/pr-96-*.log 2>/dev/null | grep -c .)"
  [ "$n" = 0 ] \
    || fail "$n transcripts survived the pass after the grace, so the sweep does not finish what it starts"
  ok "...and all of them go on the next pass"
  # ...AND SAYS SO. "A sweep nobody can see is one nobody can debug" is the
  # function's own comment and nothing asserted it, so the count could have
  # drifted or the line disappeared with the phase still green. Asserted
  # against fleet.log because `say` is `tee -a "$LOG"` and this pass's stdout
  # is swallowed by the poll wrapper. Found by the independent review.
  grep -q "swept 3 reviewer transcript(s)" "$AUTOFLEET_DIR/fleet.log" 2>/dev/null \
    || fail "the sweep took three transcripts and did not say so: $(cat "$AUTOFLEET_DIR/fleet.log" 2>/dev/null)"
  ok "...and says how many it took"
  # ...and hand the next assertion back the fixture it needs: this block cleared
  # the directory to get a clean per-PR grace, including PR 42's transcripts.
  for h in aaaaaaaa bbbbbbbb cccccccc dddddddd; do
    : >"$AUTOFLEET_DIR/reviews/pr-42-$h.log"; sleep 0.01
  done
  AUTOFLEET_KEEP_REVIEWS=2 poll_review_open_prs
  n="$(ls "$AUTOFLEET_DIR/reviews"/pr-42-*.log 2>/dev/null | grep -c .)"
  [ "$n" = 2 ] \
    || fail "an open PR kept $n transcripts rather than AUTOFLEET_KEEP_REVIEWS=2"
  ok "...and an open PR keeps the newest AUTOFLEET_KEEP_REVIEWS"
  [ -e "$AUTOFLEET_DIR/reviews/pr-42-dddddddd.log" ] \
    || fail "the sweep kept the OLDEST transcripts rather than the newest"
  ok "...the newest, not the oldest"

  # 0 means keep everything, which is what a host project debugging its own
  # reviewer wants. A sweep with no off switch is one somebody works around.
  : >"$AUTOFLEET_DIR/reviews/pr-99-ffffffff.log"
  AUTOFLEET_KEEP_REVIEWS=0 poll_review_open_prs
  AUTOFLEET_KEEP_REVIEWS=0 poll_review_open_prs
  [ -e "$AUTOFLEET_DIR/reviews/pr-99-ffffffff.log" ] \
    || fail "AUTOFLEET_KEEP_REVIEWS=0 still swept, so there is no way to keep them"
  ok "...and 0 keeps everything"

  # fleet.log rotates at a cap, one generation. `mv` rather than truncate: the
  # dispatcher holds it open in append mode, so truncating leaves the offset
  # where it was and the next write pads the gap with NULs.
  head -c 3000 /dev/zero | tr '\0' 'x' >"$AUTOFLEET_DIR/fleet.log"

  # NOT WHILE A REVIEWER IS RUNNING. `review.sh` is spawned with `>>"$LOG"`, and
  # that redirect holds the inode for up to AUTOFLEET_REVIEW_TIMEOUT -- thirty
  # minutes and many polls. Rotate under it and its output goes to a file nobody
  # is reading, and the NEXT rotation unlinks the file it is still writing to.
  # Found by the independent review, which also caught that the comment named
  # the dispatcher as the long-lived holder. It is not; `tee -a` is fresh per
  # call.
  mkdir -p "$AUTOFLEET_DIR/reviewing"
  # A pid `reviewer_alive` accepts as OURS. The first version of this wrote the
  # harness's own `$$`, which that function correctly reports as not a reviewer
  # -- so the assertion passed only because the guard was broken in a different
  # way, and it would have FAILED against the corrected guard. A phase that
  # passes because of a bug is worse than no phase. Found by `/code-review`.
  # `reviewer_alive` matches `review.sh` in the ps command line -- that is its
  # whole point, so a marker left by a `kill -9` cannot name a stranger the OS
  # has since reused the pid for. The stand-in has to look like one.
  # NOT `exec sleep`: that replaces the process and ps then reports `sleep`,
  # which is the thing `reviewer_alive` is looking past.
  printf '#!/bin/sh\nsleep "$@"\n' >"$WORK/bin/review.sh"
  chmod +x "$WORK/bin/review.sh"
  "$WORK/bin/review.sh" 30 &
  fake_reviewer=$!
  printf '%s %s\n' "$fake_reviewer" "$PR_HEAD" >"$AUTOFLEET_DIR/reviewing/42"
  AUTOFLEET_LOG_MAX_BYTES=1000 in_poll rotate_fleet_log >/dev/null 2>&1
  [ -e "$AUTOFLEET_DIR/fleet.log.1" ] \
    && fail "fleet.log rotated while a reviewer was writing into it; its output goes to a file nobody reads and the next rotation unlinks it"
  ok "fleet.log does not rotate under a running reviewer"

  kill "$fake_reviewer" 2>/dev/null; wait "$fake_reviewer" 2>/dev/null
  rm -f "$AUTOFLEET_DIR/reviewing/42"
  AUTOFLEET_LOG_MAX_BYTES=1000 in_poll rotate_fleet_log >/dev/null 2>&1
  [ -e "$AUTOFLEET_DIR/fleet.log.1" ] \
    || fail "fleet.log passed the cap and was not rotated"
  ok "...and rotates at AUTOFLEET_LOG_MAX_BYTES once none is"

  # RC 2 -- "alive, but ps will not name it" -- DOES NOT BLOCK. There was no row
  # for it, and blocking on it starved the rotation permanently: a 2-marker is
  # never cleared (`live_reviewers` keeps it deliberately, `stop_reviewers` runs
  # only at dispatcher start), so one SIGKILLed reviewer whose pid the OS reuses
  # blocks every rotation for the life of the dispatcher, silently. The cap
  # stops being a bound. Found by the independent review.
  #
  # A pid that is alive and is NOT one of ours gives exactly that answer: `ps`
  # names it, but not as `review.sh`... so this uses a pid that is alive and
  # unnameable by construction -- our own shell's parent is nameable, so instead
  # the marker names a pid we know is alive and let `reviewer_alive` decide.
  head -c 3000 /dev/zero | tr '\0' 'x' >"$AUTOFLEET_DIR/fleet.log"
  rm -f "$AUTOFLEET_DIR/fleet.log.1" "$AUTOFLEET_DIR/rotate-blind"
  printf '#!/bin/sh\nsleep "$@"\n' >"$WORK/bin/review.sh"; chmod +x "$WORK/bin/review.sh"
  "$WORK/bin/review.sh" 30 & blocker=$!
  printf '%s %s\n' "$blocker" "$PR_HEAD" >"$AUTOFLEET_DIR/reviewing/42"
  AUTOFLEET_LOG_MAX_BYTES=1000 in_poll rotate_fleet_log >/dev/null 2>&1
  [ -e "$AUTOFLEET_DIR/fleet.log.1" ] \
    && fail "rotation went ahead with one of OUR reviewers holding the file"
  ok "a definite 0 still blocks rotation"
  kill "$blocker" 2>/dev/null; wait "$blocker" 2>/dev/null

  # ...AND RC 2 DOES NOT BLOCK. "Alive, but ps will not name it" cannot be
  # produced reliably from a shell -- it needs `kill -0` to succeed while
  # `ps -o command=` prints nothing -- so this asserts the DECISION rather than
  # the OS condition, by answering 2 from `reviewer_alive` directly. That is the
  # right level: what was wrong was the choice, not the detection.
  #
  # Blocking on 2 starves the rotation permanently, because nothing ever clears
  # a 2-marker: `live_reviewers` keeps it deliberately and `stop_reviewers` runs
  # only at dispatcher start. One SIGKILLed reviewer whose pid the OS reuses
  # means fleet.log grows past the cap for the life of the dispatcher, and
  # silently -- the "could not rotate" line is never reached, because the
  # function returns before the `mv`. Found by the independent review.
  head -c 3000 /dev/zero | tr '\0' 'x' >"$AUTOFLEET_DIR/fleet.log"
  rm -f "$AUTOFLEET_DIR/fleet.log.1" "$AUTOFLEET_DIR/rotate-blind"
  printf '%s %s\n' 424242 "$PR_HEAD" >"$AUTOFLEET_DIR/reviewing/42"
  out="$( cd "$WORK/repo" && . ./scripts/fleet/fleet.sh >/dev/null 2>&1
          reviewer_alive() { return 2; }
          AUTOFLEET_LOG_MAX_BYTES=1000 rotate_fleet_log 2>&1 )"
  rm -f "$AUTOFLEET_DIR/reviewing/42"
  [ -e "$AUTOFLEET_DIR/fleet.log.1" ] \
    || fail "a holder ps cannot name blocked the rotation, which never clears -- the cap stops being a bound for the dispatcher's life: $out"
  ok "...and a holder ps cannot name does not block it forever"
  grep -q "ps unable to name it" <<<"$out" \
    || fail "it rotated out from under an unnameable holder and said nothing: $out"
  ok "...and says so when it does"

  # ...INTO THE FILE PEOPLE READ. `say` is `tee -a "$LOG"`, so a warning printed
  # before the `mv` was appended to the inode that became fleet.log.1 -- the
  # generation the warning itself says nobody reads. Asserted against the file
  # rather than the captured stdout, because stdout cannot tell the two apart.
  # Found by the independent review.
  grep -q "ps unable to name it" "$AUTOFLEET_DIR/fleet.log" 2>/dev/null \
    || fail "the warning about rotating blind went into the generation it warns nobody reads: $out"
  ok "...into the log that survives the rotation, not the one it warns about"

  # ...AND THE MARKER IS NOT SPENT BY A POLL THAT ROTATES NOTHING. The size
  # check ran AFTER the loop above, so an rc-2 holder and a log at a tenth of
  # the cap wrote `rotate-blind`, said the warning, and returned without
  # renaming anything -- and the real blind rotation, whenever it came, was
  # silent, the marker having been spent on one that never happened. Found by
  # the independent review.
  rm -f "$AUTOFLEET_DIR/fleet.log.1" "$AUTOFLEET_DIR/rotate-blind"
  head -c 100 /dev/zero | tr '\0' 'x' >"$AUTOFLEET_DIR/fleet.log"
  printf '%s %s\n' 424242 "$PR_HEAD" >"$AUTOFLEET_DIR/reviewing/42"
  ( cd "$WORK/repo" && . ./scripts/fleet/fleet.sh >/dev/null 2>&1
    reviewer_alive() { return 2; }
    AUTOFLEET_LOG_MAX_BYTES=1000 rotate_fleet_log ) >/dev/null 2>&1
  rm -f "$AUTOFLEET_DIR/reviewing/42"
  [ -e "$AUTOFLEET_DIR/rotate-blind" ] \
    && fail "a poll that was never going to rotate spent the say-once marker, so the rotation that does happen explains itself in silence"
  ok "...and a poll under the cap does not spend it"
  # 0 KEEPS IT, asserted rather than announced. The first version ran the
  # rotation and printed `ok` unconditionally -- and even with an assertion it
  # was vacuous, because the `mv` two steps up had left fleet.log holding one
  # line, under any cap. Refilled past the cap first. 1975460 fixed this exact
  # shape one PR over ("a lint that asserts nothing"). Found by the independent
  # review.
  head -c 3000 /dev/zero | tr '\0' 'x' >"$AUTOFLEET_DIR/fleet.log"
  before_1="$(wc -c <"$AUTOFLEET_DIR/fleet.log.1" 2>/dev/null | tr -d ' ')"
  AUTOFLEET_LOG_MAX_BYTES=0 in_poll rotate_fleet_log >/dev/null 2>&1
  [ -s "$AUTOFLEET_DIR/fleet.log" ] \
    || fail "AUTOFLEET_LOG_MAX_BYTES=0 rotated anyway, so there is no way to keep the log"
  [ "$(wc -c <"$AUTOFLEET_DIR/fleet.log.1" 2>/dev/null | tr -d ' ')" = "$before_1" ] \
    || fail "AUTOFLEET_LOG_MAX_BYTES=0 overwrote the previous generation"
  ok "...and 0 keeps it, with the cap exceeded"

  # ...AND IT SAYS SO WHEN IT CANNOT ROTATE AT ALL. #74's Acceptance ticks that
  # box and nothing asserted it: every rotation call here discarded output and
  # no `mv` failure was ever provoked. A rotation that fails silently on every
  # poll forever is the opposite of the rule stated forty lines above it. Found
  # by the independent review.
  head -c 3000 /dev/zero | tr '\0' 'x' >"$AUTOFLEET_DIR/fleet.log"
  # The STATE DIR made unwritable, which is what actually stops a rename. Two
  # earlier attempts did not: `mv -f` replaces an empty directory, and moves the
  # file INTO a non-empty one. A read-only parent is the condition an operator
  # really meets -- a state dir on a full or remounted volume.
  rm -rf "$AUTOFLEET_DIR/fleet.log.1"
  chmod a-w "$AUTOFLEET_DIR"
  out="$(AUTOFLEET_LOG_MAX_BYTES=1000 in_poll rotate_fleet_log 2>&1)"
  chmod u+w "$AUTOFLEET_DIR"
  grep -q "could not rotate" <<<"$out" \
    || fail "a rotation that could not happen said nothing, and would fail on every poll forever: $out"
  ok "...and says so when it cannot rotate at all"

  # ...ONCE PER DISPATCHER, and ONE PROCESS is the only place that can be
  # asserted. A directory `mv` cannot write to is still a file `tee -a` can
  # append to, so an ungated line here made the ONE state where the cap cannot
  # hold the one writing into the log it is failing to bound -- ~1440 lines a
  # day at the 60s default, forever. The assertion above greps the string once
  # and cannot see the repetition. Found by the independent review.
  #
  # The say-once state is a VARIABLE rather than a marker file for the same
  # reason this asserts inside one shell: the condition is a $STATE_DIR nothing
  # can write to, so the first fix -- a marker beside `rotate-blind` -- could
  # not create it in exactly the case it was for, and the line repeated anyway.
  # This phase caught that.
  head -c 3000 /dev/zero | tr '\0' 'x' >"$AUTOFLEET_DIR/fleet.log"
  rm -rf "$AUTOFLEET_DIR/fleet.log.1"
  out="$( cd "$WORK/repo" && . ./scripts/fleet/fleet.sh >/dev/null 2>&1
          chmod a-w "$AUTOFLEET_DIR"
          AUTOFLEET_LOG_MAX_BYTES=1000 rotate_fleet_log
          AUTOFLEET_LOG_MAX_BYTES=1000 rotate_fleet_log
          AUTOFLEET_LOG_MAX_BYTES=1000 rotate_fleet_log
          chmod u+w "$AUTOFLEET_DIR" )"
  chmod u+w "$AUTOFLEET_DIR" 2>/dev/null
  n="$(grep -c "could not rotate" <<<"$out" || true)"
  [ "$n" = 1 ] \
    || fail "three stuck polls said it $n time(s); the one state where the cap cannot hold is the one writing into the file it cannot bound: $out"
  ok "...and says it once per dispatcher, not once per poll"

  # ...and a rotation that WORKS lets it speak again, because the condition is a
  # directory permission somebody fixes -- and re-breaks -- while the fleet runs.
  out="$( cd "$WORK/repo" && . ./scripts/fleet/fleet.sh >/dev/null 2>&1
          chmod a-w "$AUTOFLEET_DIR"
          AUTOFLEET_LOG_MAX_BYTES=1000 rotate_fleet_log
          chmod u+w "$AUTOFLEET_DIR"
          AUTOFLEET_LOG_MAX_BYTES=1000 rotate_fleet_log
          head -c 3000 /dev/zero | tr '\0' 'x' >"$AUTOFLEET_DIR/fleet.log"
          rm -rf "$AUTOFLEET_DIR/fleet.log.1"
          chmod a-w "$AUTOFLEET_DIR"
          AUTOFLEET_LOG_MAX_BYTES=1000 rotate_fleet_log
          chmod u+w "$AUTOFLEET_DIR" )"
  chmod u+w "$AUTOFLEET_DIR" 2>/dev/null
  n="$(grep -c "could not rotate" <<<"$out" || true)"
  [ "$n" = 2 ] \
    || fail "a rotation that worked did not let the next stuck one speak (said it $n time(s), wanted 2): $out"
  ok "...and a rotation that works lets it speak again"
  rm -rf "$AUTOFLEET_DIR/fleet.log.1"

  # THE STORE THIS CHANGE INTRODUCES. `.closed-N` is a new persistent file class
  # in the reviews directory -- one per closed PR -- in a change about stores
  # that only grow. Its collector had no assertion: the phase deletes the
  # markers by hand at three points, so the collector could be a no-op and this
  # stayed green. Found by the independent review.
  rm -f "$AUTOFLEET_DIR/reviews"/.closed-* "$AUTOFLEET_DIR/reviews"/pr-*.log
  : >"$AUTOFLEET_DIR/reviews/.closed-1234"
  AUTOFLEET_KEEP_REVIEWS=3 poll_review_open_prs
  [ -e "$AUTOFLEET_DIR/reviews/.closed-1234" ] \
    && fail ".closed-1234 outlived the transcripts it was tracking, so the sweep trades one growing store for another"
  ok "a grace marker is collected once its transcripts are gone"

  # --- I1: an empty open list that is an ANSWER sweeps; one that is a FAILURE
  # to answer does not. Three things produce a wrongly-empty list -- the parse
  # swallowing an error, the page limit, and `--author` -- and each would take
  # every transcript on the machine, once, permanently.
  rm -f "$AUTOFLEET_DIR/reviews"/.closed-* "$AUTOFLEET_DIR/reviews"/pr-*.log
  : >"$AUTOFLEET_DIR/reviews/pr-77-11111111.log"
  in_fleet_fn prune_review_logs "" no >/dev/null 2>&1
  in_fleet_fn prune_review_logs "" no >/dev/null 2>&1
  [ -e "$AUTOFLEET_DIR/reviews/pr-77-11111111.log" ] \
    || fail "a list the caller could not answer for was read as 'every PR is closed', and the store was emptied"
  ok "a list nobody could answer for sweeps nothing"
  in_fleet_fn prune_review_logs "" yes >/dev/null 2>&1
  in_fleet_fn prune_review_logs "" yes >/dev/null 2>&1
  [ -e "$AUTOFLEET_DIR/reviews/pr-77-11111111.log" ] \
    && fail "a genuinely empty list -- a drained fleet -- swept nothing, which is the peak of the pile"
  ok "...and a real empty answer does sweep"

  # --- I2: the third sweep had no test at all, and it deletes the state
  # guard.py reads to permit a push.
  mkdir -p "$WORK/repo/.autofleet/run"
  live_sha="$(git -C "$WORK/repo" rev-parse HEAD 2>/dev/null)"
  : >"$WORK/repo/.autofleet/run/reviewed-$live_sha"
  AUTOFLEET_KEEP_REVIEWS=3 in_fleet_fn prune_reviewed_markers >/dev/null 2>&1
  [ -e "$WORK/repo/.autofleet/run/reviewed-$live_sha" ] \
    || fail "the marker for a commit that IS on a branch was deleted; guard.py then refuses the push and both passes must be re-run"
  ok "a reviewed- marker for a live commit survives"

  # A REAL commit on NO branch -- made, recorded, then the branch moved back off
  # it. A made-up sha is kept by the `cat-file -e` guard whatever the knob says,
  # so asserting with one proves nothing about the off switch.
  git -C "$WORK/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "orphaned" 2>/dev/null
  orphan_sha="$(git -C "$WORK/repo" rev-parse HEAD 2>/dev/null)"
  git -C "$WORK/repo" reset -q --hard "$live_sha" 2>/dev/null
  : >"$WORK/repo/.autofleet/run/reviewed-$orphan_sha"

  AUTOFLEET_KEEP_REVIEWS=0 in_fleet_fn prune_reviewed_markers >/dev/null 2>&1
  [ -e "$WORK/repo/.autofleet/run/reviewed-$orphan_sha" ] \
    || fail "AUTOFLEET_KEEP_REVIEWS=0 still swept the reviewed- markers, against what config.sh promises"
  ok "...and 0 keeps every piece of review state"

  AUTOFLEET_KEEP_REVIEWS=3 in_fleet_fn prune_reviewed_markers >/dev/null 2>&1
  [ -e "$WORK/repo/.autofleet/run/reviewed-$orphan_sha" ] \
    && fail "a marker for a commit on no branch survived the sweep, so the store still only grows"
  [ -e "$WORK/repo/.autofleet/run/reviewed-$live_sha" ] \
    || fail "the same sweep took the live commit's marker with it"
  ok "...while a commit on no branch does go"

  # ...AND A DISPATCHER CHECKOUT WITH NO `.autofleet/run` DOES NOT STOP IT.
  # `$REPO_ROOT` is prepended to the roots unconditionally while every worktree
  # root is added only after its directory has been confirmed -- so the only
  # root that can lack the directory is the first one, and a `return 0` there
  # exited the whole function. `.autofleet/run/` is gitignored and created on
  # demand by `record-review.sh` in the checkout that records a review, which is
  # a WORKTREE: on any host where no review was ever recorded from the main
  # checkout, the sweep examined nothing at all, every poll. Found by the
  # independent review.
  worktree="$WORK/wt-marker"
  mkdir -p "$worktree/.autofleet/run" "$AUTOFLEET_DIR/worktrees"
  git -C "$WORK/repo" worktree add -q --detach "$worktree" 2>/dev/null \
    || git init -q "$worktree"
  printf '%s\n' "$worktree" >"$AUTOFLEET_DIR/worktrees/77"
  git -C "$worktree" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base 2>/dev/null
  wt_base="$(git -C "$worktree" rev-parse HEAD 2>/dev/null)"
  git -C "$worktree" -c user.email=t@t -c user.name=t commit -q --allow-empty -m orphan 2>/dev/null
  wt_orphan="$(git -C "$worktree" rev-parse HEAD 2>/dev/null)"
  # Back to the base BY SHA, not `HEAD~1`: the first version used the relative
  # form and the branch did not move, so the "orphan" was still contained by
  # `master` and the assertion was testing nothing.
  git -C "$worktree" reset -q --hard "$wt_base" 2>/dev/null
  : >"$worktree/.autofleet/run/reviewed-$wt_orphan"
  # The dispatcher checkout has none, which is the normal case.
  rm -rf "$WORK/repo/.autofleet/run"
  AUTOFLEET_KEEP_REVIEWS=3 in_fleet_fn prune_reviewed_markers >/dev/null 2>&1
  [ -e "$worktree/.autofleet/run/reviewed-$wt_orphan" ] \
    && fail "a dispatcher checkout with no .autofleet/run stopped the sweep before it reached any worktree"
  ok "...and a main checkout without the directory does not stop the sweep"
  ;;

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
  # restated here -- the whole of armaatus/rommsync-nx#183 was two programs
  # disagreeing about one
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

# ---------------------------------------------------------------- stubwrite
  stubwrite)
  # The reviewer stub is written through an UNQUOTED heredoc, so its body is not
  # inert text on the way to the file: the shell expands parameters and RUNS
  # command substitutions in it, and a heredoc has no comment lines -- a `#` is
  # just more text being written. A backtick pair inside what reads like a
  # comment is therefore a command, and one of them named the function doing the
  # writing. `stub_reviewer` called `stub_reviewer`, forever.
  #
  # This is the phase that would have hung. Every phase but `mode` calls
  # `stub_reviewer`, so the suite stopped dead immediately after it with no
  # failure, no output and no name to read -- nine minutes of silence and exit
  # 143 in CI run 34658821929.
  #
  # WHAT IT DOES NOT CATCH, said plainly because this file has twice been bitten
  # by a phase that claimed more than it asserted: a write-time expansion that
  # succeeds SILENTLY and eats text this does not name -- `\`date\``, `$HOME` --
  # passes all four rows. Only two shapes are caught: one that writes to stderr,
  # and the loss of the one line named below. The general case wants the written
  # file compared against the heredoc body, which is worth doing and is not this
  # change; it is noted on armaatus/autofleet#71 with the other guards aimed
  # slightly off. Both review passes raised this, and narrowing the claim is the
  # answer rather than leaving the comment to be believed.
  make_fixture
  err="$WORK/stub-err"
  stub_reviewer marked 2>"$err"

  [ -s "$err" ] \
    && fail "writing the reviewer stub ran something: $(cat "$err")"
  ok "writing the reviewer stub executes nothing"

  bash -n "$WORK/bin/fake-reviewer" \
    || fail "the written reviewer stub does not parse"
  ok "the written reviewer stub parses"

  # The prose reached the file instead of being executed out of it. Both halves
  # matter: present means the substitution did not eat it, and a stub that still
  # says this is a stub that still carries its own warning.
  grep -qF 'stub_reviewer submits' "$WORK/bin/fake-reviewer" \
    || fail "the stub's NOTE was consumed as a command substitution, not written"
  ok "backticked prose reaches the stub as text"

  # The parts the heredoc is unquoted FOR still expand, so the fix did not buy
  # the bound by making the stub inert.
  grep -qF "$GH_REVIEWS" "$WORK/bin/fake-reviewer" \
    || fail "the stub no longer has the review path baked in; the heredoc stopped expanding"
  ok "...while the paths the heredoc is unquoted for still expand"
  ;;

  *)
  echo "usage: $0 mode|refuses|stopped|submits|unmarked|silent|skips|stale|midstop|reaper|timeout|sweeps|queue|records|status_count|holds|once|retries|capped|stubwrite" >&2
  exit 2 ;;
esac
