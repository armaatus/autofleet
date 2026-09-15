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
#   test_review_mode.sh inflight  a reviewer is already being WRITTEN for this PR ->
#                                 exit 9, naming the one that holds it, and no
#                                 second reviewer. `skips` covers the other
#                                 half, "a review is already ON this head"; this
#                                 is the case that had no answer and produced
#                                 two reviews on one head (#64).
#   test_review_mode.sh lockrace  ...and two runs started at the same instant
#                                 get the same answer. The lock is claimed by
#                                 the reviewer, create-or-fail, because the
#                                 dispatcher's `[ -e ]` and its write are two
#                                 syscalls with this race between them.
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
#   test_review_mode.sh rounds     a review that SUBMITTED counts a round against
#                                 the pull request, across every head it is on,
#                                 and one that submitted nothing does not. The
#                                 two counters that already existed answer other
#                                 questions: `.tries` is per head and counts only
#                                 silence, and .autofleet/run/review-rounds is
#                                 per worktree and undercounts.
#   test_review_mode.sh roundcap   ...and at AUTOFLEET_REVIEW_MAX the dispatcher
#                                 stops starting reviewers for that PR and hands
#                                 it to the VALIDATOR instead -- on a new head
#                                 too, or the cap is one push away from not
#                                 existing.
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
#   test_review_mode.sh await_threads
#                                 await-review.sh hands back the PR's UNRESOLVED
#                                 review threads and not its resolved ones, and
#                                 never calls `pulls/<n>/comments` -- the
#                                 endpoint that cannot say which is which, and
#                                 which used to hand the agent every comment the
#                                 PR ever had, once per round.
#   test_review_mode.sh await_quiet
#                                 ...and on round two, a thread that has not
#                                 moved since the round that handed it back is
#                                 not handed back again. It is still open, so
#                                 the output names review-status.sh.
#   test_review_mode.sh await_moved
#                                 ...while a thread that HAS moved -- the agent
#                                 replied and the reviewer answered -- is. This
#                                 is the row that goes red if the dedupe above
#                                 is written as "never twice" rather than
#                                 "not unless it changed".
#   test_review_mode.sh await_own_reply
#                                 ...but the agent's OWN reply is not the thread
#                                 moving: that is the loop doing what it is told
#                                 ("reply with the reason"), and counting it as
#                                 news hands the finding back with the answer
#                                 under it. Only meaningful in `github` mode --
#                                 in `local` mode reviewer and author are one
#                                 account and the wait shows the thread rather
#                                 than guessing.
#   test_review_mode.sh await_own_reply_local
#                                 ...and the other half of that, which is the
#                                 half this repo runs: in `local` mode the two
#                                 accounts are one, so the same reply is handed
#                                 back rather than guessed at. Without this row,
#                                 deleting the `local` disjunct leaves every
#                                 other await phase green.
#   test_review_mode.sh await_cap the cap cuts BETWEEN timestamps, never inside
#                                 one. A review stamps every inline comment it
#                                 leaves with the same createdAt, so a cut
#                                 inside that run leaves the stamp unable to
#                                 advance past it and the remainder is never
#                                 handed back by any round. Three threads in one
#                                 instant against a cap of two.
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
#   test_review_mode.sh headroom  AUTOFLEET_HEADROOM -- the opt-in compression
#                                 proxy in front of the reviewer's model call.
#                                 Unset means the two variables are ABSENT from
#                                 its environment, which is the half a presence
#                                 assertion cannot cover; on with a listener
#                                 means both are set to what the knob names; and
#                                 on with NOTHING listening means the review
#                                 still runs and one line names the URL and the
#                                 knob. That last row is the one that turns a
#                                 stopped proxy into a stopped fleet if it ever
#                                 becomes a prerequisite.
#   test_review_mode.sh headroom_status
#                                 ...and which of those three states the first
#                                 screen anybody looks at reports, probing the
#                                 endpoint rather than repeating the knob.
#
# `gh` and the reviewer command are both stubbed on PATH and the fleet state dir
# is a temp dir, so nothing here touches a pull request or the machine's fleet.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "  ok: $*"; }

WORK=""
PROXY_PID=""
# ...AND THE STUB PROXY, which is the one thing here that is a PROCESS rather
# than a directory. `stub_proxy` forks a python spinning in `accept()`; any
# `fail` between it and `kill_proxy` -- including `stub_proxy`'s own -- orphaned
# one holding a listening port, forever, one per failing run. Found by the
# self-review.
cleanup() {
  [ -n "$PROXY_PID" ] && kill -9 "$PROXY_PID" 2>/dev/null
  [ -n "$WORK" ] && rm -rf "$WORK"
  return 0
}
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
  # BOTH briefs. `validate.sh` refuses to start without `validator.md` -- exit 2,
  # "no validator brief" -- and that exit deliberately leaves no `.done` record,
  # so a fixture missing the file gets a validator started on every poll forever
  # and every assertion about the second phase measures a config error instead.
  cp "$REPO_ROOT/.claude/agents/reviewer.md" \
     "$REPO_ROOT/.claude/agents/validator.md" "$WORK/repo/.claude/agents/"
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
  # await-review.sh's throttled rollup. Narrow on purpose -- the generic
  # `pr view` arm below answers with a bare sha, which is not JSON, and the
  # rollup parse would fall through to "the rollup came back empty" and blind
  # the red-build, dead-review and conflict checks the phase is not testing.
  *"--json statusCheckRollup,mergeStateStatus,baseRefName"*)
    cat "${GH_ROLLUP:-/dev/null}" 2>/dev/null
    [ -s "${GH_ROLLUP:-/dev/null}" ] \
      || echo '{"statusCheckRollup":[],"mergeStateStatus":"CLEAN","baseRefName":"main"}'
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
    # One arm for both GraphQL readers: await-review.sh's own reviews query and
    # the paged one in .github/scripts/pr_payload.sh. They ask for different
    # fields of the same pull request, so answering both from one document is
    # the fixture equivalent of the two sharing a query.
    #
    # `$GH_THREADS` names a file holding the review-thread list, in the shape
    # pr_payload.sh emits it, and is empty by default so every phase written
    # before threads existed here is unaffected. A review record may carry its
    # own `submitted_at`; without one it gets the fixed date the suite has
    # always used.
    python3 - "$GH_REVIEWS" "$(cat "$GH_HEAD")" "${GH_THREADS:-}" "${GH_COMMENTS:-}" <<'PY'
import json, sys
records = json.load(open(sys.argv[1]))
nodes = [{"state": "COMMENTED",
          "submittedAt": r.get("submitted_at") or "2026-09-10T10:00:00Z",
          "commit": {"oid": r["commit_id"]}, "author": {"login": r["user"]},
          "body": r["body"], "comments": {"totalCount": 0}} for r in records]
threads = json.load(open(sys.argv[3])) if sys.argv[3] else []
# The PR's own conversation. Empty by default, so every phase written before
# armaatus/autofleet#65 is unaffected; a delta round reads it for the answer
# comment that says what was done about the last round's findings.
comments = json.load(open(sys.argv[4])) if len(sys.argv) > 4 and sys.argv[4] else []
print(json.dumps({"data": {"repository": {"pullRequest": {
    "headRefOid": sys.argv[2],
    "body": "Closes #7\n/code-review\nmattpocock-skills:code-review",
    "author": {"login": "armaatus"},
    "reviews": {"nodes": nodes},
    "comments": {"nodes": comments},
    "reviewThreads": {"pageInfo": {"hasNextPage": False, "endCursor": None},
                      "nodes": threads}}}}}))
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
  GH_THREADS=""; export GH_THREADS
  GH_COMMENTS=""; export GH_COMMENTS
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
  # ...and the PROMPT it was handed. `review.sh` calls it as `-p "$prompt"`, so
  # `\$2` -- escaped, because this heredoc is unquoted and an unescaped `$2`
  # would be the TEST's second argument at write time -- is the whole brief plus
  # the "This run" block. Without this, what the reviewer is asked to read was
  # the one part of this script nothing could assert. armaatus/autofleet#65.
  PROMPT_FILE="$WORK/reviewer-prompt"
  : >"$PROMPT_FILE"
  export PROMPT_FILE
  # ...and the WHOLE argv. The prompt is not the only thing that decides what
  # the reviewer can read: `--add-dir` is what puts the carried-forward context
  # inside its workspace, and a review that names a file it cannot open proceeds
  # on the range alone and prints `scope: delta` either way. Found by the
  # independent review.
  ARGV_FILE="$WORK/reviewer-argv"
  : >"$ARGV_FILE"
  export ARGV_FILE
  # ...and WHICH OF THE TWO COMPRESSION VARIABLES were in its environment. The
  # knob in front of this call is the only thing that sets them, and its
  # default promises they are ABSENT -- a promise nothing could check from the
  # argv or the prompt, because an environment variable appears in neither.
  # Recorded by PRESENCE (`${VAR+x}`), not by value: an exported-but-empty
  # ANTHROPIC_BASE_URL is its own breakage, and a recording that flattened it to
  # "unset" would call that byte-identical to today.
  ENV_FILE="$WORK/reviewer-env"
  : >"$ENV_FILE"
  export ENV_FILE
  # THE WORK THE WRAPPER STARTS, as a script under $WORK rather than a bare
  # `sleep 3607`. Two phases decide whether the kill reached the reviewer's own
  # child by asking `pgrep -f "sleep 3607"` -- a question about the WHOLE
  # MACHINE. Any unrelated `sleep 3607` (another worktree, another run of this
  # suite, a stray left by a killed phase) answered for the fixture, and the
  # phase failed with "the wedged reviewer's own child outlived the kill" about
  # a process it had never started. Verified both ways in armaatus/autofleet#42:
  # green on a clean machine, red with one unrelated sleep running, and read by
  # a reviewer as pre-existing breakage rather than as contamination -- which is
  # the defect, because the phase cannot tell the two apart. $WORK is this
  # phase's own mktemp directory, so a pgrep on this path can match nothing
  # else. NOT a prefix of `fake-reviewer`, or `-f` would match the wrapper too
  # and the two assertions would answer for each other.
  # armaatus/autofleet#71.
  REVIEWER_WORK="$WORK/bin/reviewer-work"
  cat >"$REVIEWER_WORK" <<'CHILD'
#!/usr/bin/env bash
# The distinctive duration stays, so a human reading `ps` still recognises it.
sleep 3607
CHILD
  chmod +x "$REVIEWER_WORK"
  export REVIEWER_WORK
  cat >"$WORK/bin/fake-reviewer" <<STUB
#!/usr/bin/env bash
printf 'ran\n' >>"$REVIEWER_CALLS"
printf '%s' "\$2" >"$PROMPT_FILE"
printf '%s\n' "\$@" >"$ARGV_FILE"
: >"$ENV_FILE"
[ -n "\${ANTHROPIC_BASE_URL+x}" ] && printf 'ANTHROPIC_BASE_URL=%s\n' "\$ANTHROPIC_BASE_URL" >>"$ENV_FILE"
[ -n "\${ENABLE_TOOL_SEARCH+x}" ] && printf 'ENABLE_TOOL_SEARCH=%s\n' "\$ENABLE_TOOL_SEARCH" >>"$ENV_FILE"
# HOW LONG THE REVIEWER TAKES, for the one phase that needs two of them to
# overlap. Every other phase leaves it unset and the stub is as immediate as it
# was. \`hang\` is no use there: what \`lockrace\` needs is a reviewer that
# holds the lock for a few seconds and then really submits. THE BACKTICKS ARE
# ESCAPED -- this heredoc is unquoted, as the note at the bottom of it says.
[ -n "\${AUTOFLEET_TEST_REVIEWER_DELAY:-}" ] && sleep "\$AUTOFLEET_TEST_REVIEWER_DELAY"
case "$1" in
  marked|unmarked|json|text)
    trailer=""
    case "$1" in
      marked|json|text) trailer="<!-- independent-review: local \$(cat "$GH_HEAD") -->" ;;
    esac
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
    # WHAT IT PRINTS ON STDOUT, which is what \`finish_log\` in review.sh parses.
    # \`json\` is a reviewer that honours \`--output-format json\`; \`text\` is
    # the wrapper that does not, and whose output must still reach a readable
    # log with no cost row invented for it. THE BACKTICKS ARE ESCAPED -- see the
    # note at the bottom of this heredoc, which is about exactly this.
    case "$1" in
      json) printf '%s\n' '{"result":"Review submitted to PR #42 -- COMMENTED. 3 findings.","total_cost_usd":0.42,"usage":{"input_tokens":1000,"output_tokens":200},"duration_ms":1234,"num_turns":7}' ;;
      text) printf 'Review submitted to PR #42 -- COMMENTED. 3 findings.\n' ;;
    esac
    ;;
  silent) : ;;
  # SUBMITS NOTHING AND EXITS NON-ZERO, which is the ordinary shape of a real
  # failure: an agent that hit an API error, ran out of turns, or crashed. The
  # distinction from \`silent\` is the exit code, and it is the whole of what the
  # \`crash\` phase is about -- a supervisor that dies at its own \`wait\` when the
  # thing it supervises fails is a supervisor for the case that never happens.
  #
  # THE BACKTICKS ABOVE ARE ESCAPED, like every other one in this heredoc: it is
  # UNQUOTED, so a bare backtick is command substitution run at the moment the
  # stub is WRITTEN. Unescaped, this comment ran the three words it names as
  # commands and printed a "command not found" line for each into the middle of
  # the phase. The warning at the bottom of this case already said so -- and the
  # first attempt at THIS comment escaped two of the three and left the third,
  # which is the same bug one round smaller.
  crash) exit 3 ;;
  # A child, not the stub itself. AUTOFLEET_REVIEW_CMD is advertised as a
  # wrapper seam, so the process holding the gh login is routinely a CHILD of
  # what review.sh signals -- and a kill that reaps only the direct child leaves
  # it running. The sleep is given a distinctive duration so a test can tell the
  # wrapper's death from the work's.
  hang)   "$REVIEWER_WORK" ;;
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

# A listener on a free port, and the URL that reaches it. The compression proxy
# the knob points at is a HOST-LEVEL endpoint owned by nobody in this tree -- the
# fleet probes it and never spawns it -- so the only thing the suite has to
# stand up is something that accepts a TCP connection and something that does
# not. It accepts and closes: the probe asks "does anything answer here", and a
# stub that spoke HTTP would be asserting a protocol the seam deliberately does
# not name (any compressing proxy satisfies it, not headroom's).
#
# PORT 0, not a number picked here: the suite runs three worktrees deep on one
# machine and a hardcoded port is the one way two phases can fail each other.
# The port file is written with os.replace so a reader that sees the file sees
# the whole number.
stub_proxy() {
  PROXY_PORT_FILE="$WORK/proxy.port"
  rm -f "$PROXY_PORT_FILE"
  python3 - "$PROXY_PORT_FILE" <<'PROXY' &
import os, socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 0))
s.listen(8)
tmp = sys.argv[1] + ".tmp"
with open(tmp, "w") as f:
    f.write(str(s.getsockname()[1]))
os.replace(tmp, sys.argv[1])
while True:
    try:
        conn, _ = s.accept()
    except OSError:
        break
    conn.close()
PROXY
  # ASSIGNED BEFORE THE WAIT BELOW CAN `fail`, so the EXIT trap has a pid to
  # kill even when the listener never came up.
  PROXY_PID=$!
  local i=0
  while [ ! -s "$PROXY_PORT_FILE" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
  [ -s "$PROXY_PORT_FILE" ] || fail "the stub proxy never bound a port"
  PROXY_URL="http://127.0.0.1:$(cat "$PROXY_PORT_FILE")"
}

# ...and the same URL with nothing behind it. Killing the listener rather than
# guessing an unused port is what makes "nothing answers" deterministic: the
# port was ours a moment ago, so no other process on this machine is about to
# answer on it.
kill_proxy() {
  [ -n "${PROXY_PID:-}" ] || return 0
  kill "$PROXY_PID" 2>/dev/null
  wait "$PROXY_PID" 2>/dev/null
  PROXY_PID=""
}

# How many review records the PR has. Six copies of this one-liner is five too
# many, and the copies were what made it easy to assert the wrong thing.
n_reviews() { python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$GH_REVIEWS"; }
# How many times a reviewer was actually started. `n_reviews` cannot answer that
# -- a reviewer can run and submit nothing -- and "was one started at all" is the
# question the queue phase is really asking.
# The `|| echo 0` this used to carry ran IN ADDITION to grep's own output, not
# instead of it: `grep -c` on an empty file prints `0` and exits 1, so the
# function answered "0\n0" and every numeric comparison against it died with
# "integer expression expected" -- a `[` that returns 2, so the test is FALSE
# and the assertion passes for the wrong reason. The string comparisons already
# in this file were unaffected, which is why it stood.
n_started() {
  local n; n="$(grep -c . "$REVIEWER_CALLS" 2>/dev/null)"
  printf '%s\n' "${n:-0}"
}
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
# ...and the same question about the VALIDATOR, which is what a head move buys
# now that the reviewer runs once. `grep -c` on "validating", which cannot match
# "reviewing" -- the two say-lines were deliberately given different verbs so a
# counter for one cannot silently count the other.
n_validated() { local n; n="$(grep -c "validating PR #42 at .* (pid" "$AUTOFLEET_DIR/fleet.log" 2>/dev/null || true)"; printf '%s\n' "${n:-0}"; }

# `await`, for a counter that may legitimately OVERSHOOT. `await` waits for an
# exact value and gives up when the number sails past it, which is right for a
# lock and wrong for a spawn count whose race is documented as benign: the phase
# then fails saying "waited for 1; it is 4", which reads as a defect and is not
# one. Same bound and same failure text, `-ge` instead of `=`.
await_min() {
  local what="$1" want="$2" limit="${3:-120}" waited=0 got
  while [ "$waited" -lt "$limit" ]; do
    got="$($what)"
    case "$got" in (*[!0-9]*) got=0 ;; esac
    [ "$got" -ge "$want" ] && return 0
    sleep 1; waited=$((waited + 1))
  done
  echo "         (waited ${limit}s for $what to be at least $want; it is $($what))" >&2
  return 1
}

# ...and for a file a background process writes. Same bound, same shape.
await_file() {
  local path="$1" limit="${2:-120}" waited=0
  while [ "$waited" -lt "$limit" ]; do
    [ -e "$path" ] && return 0
    sleep 1; waited=$((waited + 1))
  done
  echo "         (waited ${limit}s for $path to appear)" >&2
  return 1
}
# Whether a reviewer still holds PR 42's lock. A poll taken while one is running
# is CORRECTLY skipped, so a phase that polls again immediately is testing the
# dedup rather than the thing it means to.
lock_held() { [ -e "$AUTOFLEET_DIR/reviewing/42" ] && echo yes || echo no; }
# ...and the validator's, which is a different file. A poll taken while one is
# running is correctly skipped, so a phase that polls again immediately is
# testing the dedup rather than the cap it means to.
vlock_held() { [ -e "$AUTOFLEET_DIR/reviewing/v-42" ] && echo yes || echo no; }

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

# ------------------------------------------------ the delta-scope helpers (#65)
#
# What a round-N review needs that round one does not: a history with more than
# one commit in it, an `origin` holding `refs/pull/42/head` so `review.sh`'s
# fetch resolves, and a review record on the head that was reviewed LAST.
#
# The origin is a real bare repository rather than a stub, because the thing
# under test is a `git fetch` and a `git merge-base --is-ancestor`, and both are
# git answering about objects it has. A stubbed `git` would assert the shape of
# the command and not the fact it depends on.
make_origin() {
  git init -q --bare "$WORK/origin.git"
  git -C "$WORK/repo" remote add origin "$WORK/origin.git"
  git -C "$WORK/repo" push -q origin "HEAD:refs/pull/42/head"
}

# One more commit, published as the PR's head. `$1` names the file it touches,
# so the delta has something in it -- an empty commit makes `git diff a..b`
# empty, which is the one shape that cannot tell a range apart from no range.
advance_head() {
  printf '%s\n' "$2" >"$WORK/repo/$1"
  git -C "$WORK/repo" add "$1"
  git -C "$WORK/repo" -c user.email=t@t -c user.name=t commit -q -m "touch $1"
  PR_HEAD="$(git -C "$WORK/repo" rev-parse HEAD)"
  printf '%s' "$PR_HEAD" >"$GH_HEAD"
  git -C "$WORK/repo" push -q --force origin "HEAD:refs/pull/42/head"
}

# The same, without an origin to publish to. `advance_head` pushes, which needs
# `make_origin`; the phases that only need the head to MOVE -- so the next run
# is not answered by the review already on the old one -- should not have to
# stand up a bare repository to say so.
advance_head_simple() {
  git -C "$WORK/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m next
  PR_HEAD="$(git -C "$WORK/repo" rev-parse HEAD)"
  printf '%s' "$PR_HEAD" >"$GH_HEAD"
}

# A round that has already happened: a counting review on `$1`, declaring `$2`
# findings. Its author IS the PR's, so this also exercises the `local`-mode
# marker rule -- the same rule `merge_gate.independent_reviews` applies, asked
# about a head that is not the current one.
plant_round() {
  python3 - "$GH_REVIEWS" "$1" "$2" "${3:-2026-09-10T09:00:00Z}" <<'XX'
import json, sys
path, oid, n, when = sys.argv[1:5]
records = json.load(open(path))
records.append({"commit_id": oid, "user": "armaatus", "submitted_at": when,
                "body": "PREVIOUS ROUND FINDING: scripts/fleet/fleet.sh:12 is "
                        "wrong and review.sh:3 names a file that is not there.\n"
                        f"<!-- review-findings: {n} -->\n"
                        f"<!-- independent-review: local {oid} -->"})
json.dump(records, open(path, "w"))
XX
}

# What the reviewer was actually asked to read.
prompt_has() { grep -qF "$1" "$PROMPT_FILE"; }


# ---------------------------------------------------------------- await-review
#
# The three helpers the `await_*` phases share. They plant what a PR carries --
# a review record and its review THREADS -- and run the wait against it.
#
# One blocking call with a three-second deadline, because everything these
# phases assert happens on the FIRST poll: the review is already there. A phase
# that reaches the deadline has failed, and does so in three seconds rather than
# in the script's default forty-five minutes.
await_it() {
  (cd "$WORK/repo" \
     && AWAIT_REVIEW_POLL=1 AWAIT_REVIEW_DEADLINE=3 ./scripts/fleet/await-review.sh 42)
}

# A review on the current head, submitted at `$1`. Its author is NOT the PR's,
# so `independent_reviews` counts it whatever the review mode is -- these phases
# are about what the wait hands back, not about who may review.
plant_review() {
  python3 - "$GH_REVIEWS" "$(cat "$GH_HEAD")" "$1" <<'XX'
import json, sys
path, oid, at = sys.argv[1:4]
records = json.load(open(path))
records.append({"commit_id": oid, "user": "reviewer", "submitted_at": at,
                "body": "A real review body, long enough to be worth reading "
                        "and to clear MIN_REVIEW_BODY.\n"
                        "<!-- review-findings: 1 -->"})
json.dump(records, open(path, "w"))
XX
}

# One review thread, replacing any already planted under the same id:
#   plant_thread <id> <resolved 0|1> <first comment> <newest comment createdAt>
#                [<newest comment body> [<newest comment author>]]
#
# The fifth argument is what makes a thread MOVE. Without it the thread is one
# comment and the timestamp is that comment's; with it the thread has gained a
# reply, which is the shape of a reviewer answering an agent -- and the only
# thing that separates "still open" from "something new to read".
#
# The sixth says WHO replied, defaulting to the reviewer. `armaatus` is the
# fixture PR's own author, which is how a phase plants the agent replying to
# itself.
plant_thread() {
  GH_THREADS="$WORK/threads"; export GH_THREADS
  [ -s "$GH_THREADS" ] || printf '[]' >"$GH_THREADS"
  python3 - "$GH_THREADS" "$@" <<'XX'
import json, sys
path, tid, resolved, body, at = sys.argv[1:6]
reply = sys.argv[6] if len(sys.argv) > 6 else ""
who = sys.argv[7] if len(sys.argv) > 7 else "reviewer"
threads = [t for t in json.load(open(path)) if t["id"] != tid]
threads.append({
    "id": tid, "isResolved": resolved == "1", "isOutdated": False,
    "path": "scripts/fleet/await-review.sh", "line": 42,
    "comments": {"totalCount": 2 if reply else 1,
                 "nodes": [{"author": {"login": "reviewer"}, "body": body}]},
    "latestComment": {"nodes": [{"author": {"login": who},
                                 "body": reply or body, "createdAt": at}]}})
json.dump(threads, open(path, "w"))
XX
}

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
  # ...AND IT SAYS WHICH REVIEW. "Already reviewed" is true and tells a person
  # nothing: with two reviewers able to land on one head (#64) the next question
  # is always which review this run is standing down for. The answer is in the
  # payload the idempotence check has already fetched, so it costs no API call
  # -- and a message that silently stopped naming it would leave nothing to
  # read but the exit code.
  grep -q "held by" "$WORK/out" \
    || { cat "$WORK/out" >&2; fail "exit 8 did not name the review that holds the head"; }
  ok "...and it names the review that holds the head"
  [ "$(n_reviews)" = 1 ] \
    || fail "a second review was submitted on the same head"
  ok "...and no second review is submitted"
  [ "$before" -gt 0 ] || fail "the stub was never called"
  ;;

# ------------------------------------------------------------------ inflight
  inflight)
  # A REVIEWER IS ALREADY BEING WRITTEN, which is not the same question as "a
  # review is already on this head" and had no answer at all. `review.sh` run by
  # hand read no lock and wrote none, so a maintainer clearing a backlog beside
  # a running dispatcher got a second reviewer on the same head -- and two
  # reviews on one head is armaatus/autofleet#64, where the second was never
  # answered and its ten findings went unread.
  make_fixture; stub_reviewer marked
  mkdir -p "$AUTOFLEET_DIR/reviewing"
  # A live process that looks like a reviewer to `fleet_agent_alive`, which is
  # what a dispatcher-started one is: `ps` says `review.sh`. A bare `sleep`
  # would be read as a recycled pid and the lock stolen -- correctly, and it
  # would make this phase pass for the wrong reason.
  cat >"$WORK/bin/review.sh" <<'HOLDER'
#!/usr/bin/env bash
sleep 120
HOLDER
  chmod +x "$WORK/bin/review.sh"
  "$WORK/bin/review.sh" & holder=$!
  printf '%s %s\n' "$holder" "$(cat "$GH_HEAD")" >"$AUTOFLEET_DIR/reviewing/42"
  run_it 42 >"$WORK/out" 2>&1; rc=$?
  [ "$rc" = 9 ] || { cat "$WORK/out" >&2; kill "$holder" 2>/dev/null; \
    fail "a hand-run beside a reviewer in flight did not exit 9 (got $rc)"; }
  ok "a reviewer already in flight on this PR is exit 9, not a second reviewer"
  grep -q "$holder" "$WORK/out" \
    || { cat "$WORK/out" >&2; kill "$holder" 2>/dev/null; \
         fail "the refusal did not say which reviewer holds the PR"; }
  ok "...and it says which one holds it"
  [ "$(n_started)" = 0 ] \
    || { kill "$holder" 2>/dev/null; fail "a second reviewer was started anyway"; }
  ok "...and no reviewer ran"
  # THE LOCK IS NOT THIS RUN'S TO DROP. review.sh removes the marker on every
  # exit path, and an exit-9 that took that path with it would free the running
  # reviewer's slot and invite the next poll to start the second one it just
  # refused -- the refusal undoing itself one second later.
  [ -e "$AUTOFLEET_DIR/reviewing/42" ] \
    || { kill "$holder" 2>/dev/null; fail "the refusal removed the other reviewer's lock"; }
  ok "...and the lock it refused on is still the other reviewer's"
  # ...and a run that stands down BEFORE it ever claims must not drop a lock it
  # does not own either. `LOCK` is set from the dispatcher's marker at the top
  # of the file -- it has to be, the trap is installed above the first exit that
  # can take it -- so every path between there and the claim names a file this
  # run may not own. The stop path is one of them, and an unconditional `rm`
  # there deleted the hand-run's lock and let a second reviewer follow.
  : >"$AUTOFLEET_DIR/STOP"
  ( cd "$WORK/repo" && AUTOFLEET_REVIEW_MARKER="$AUTOFLEET_DIR/reviewing/42" \
      ./scripts/fleet/review.sh 42 ) >"$WORK/out3" 2>&1; rc=$?
  rm -f "$AUTOFLEET_DIR/STOP"
  [ "$rc" = 3 ] || { cat "$WORK/out3" >&2; kill "$holder" 2>/dev/null; \
    fail "the stopped run exited $rc rather than 3"; }
  [ -e "$AUTOFLEET_DIR/reviewing/42" ] \
    || { kill "$holder" 2>/dev/null; fail "a run that exited before claiming deleted somebody else's lock"; }
  ok "...and a run that exits before it claims drops no lock it does not hold"
  kill "$holder" 2>/dev/null

  # A LOCK NAMING NOTHING READABLE is neither contention nor a stale lock. One
  # with a reviewer behind it and one with nothing behind it are the same file,
  # so this declines and says which file rather than guessing -- guessing wrong
  # is two reviews on one head, which is the whole of #64.
  : >"$AUTOFLEET_DIR/reviewing/42"
  run_it 42 >"$WORK/out4" 2>&1; rc=$?
  [ "$rc" = 2 ] || { cat "$WORK/out4" >&2; fail "an unreadable lock exited $rc rather than 2"; }
  grep -q "names nothing this can read" "$WORK/out4" \
    || { cat "$WORK/out4" >&2; fail "it did not say the lock was unreadable"; }
  ok "...and a lock naming nothing readable is declined, not stolen"
  [ "$(n_started)" = 0 ] || fail "a reviewer ran against an unreadable lock"

  # ...and a lock whose process is GONE is not a permanent refusal. Nothing
  # clears $REVIEWING_DIR across a dispatcher's death, so a stale marker
  # outlives its process; read as "one is running" forever, that PR is never
  # reviewed again and nothing says why.
  sleep 0 & dead=$!; wait "$dead" 2>/dev/null
  printf '%s %s\n' "$dead" "$(cat "$GH_HEAD")" >"$AUTOFLEET_DIR/reviewing/42"
  run_it 42 >"$WORK/out2" 2>&1; rc=$?
  [ "$rc" = 0 ] || { cat "$WORK/out2" >&2; fail "a stale lock refused a review (got $rc)"; }
  ok "...while a lock naming a dead pid is taken over, not obeyed"
  ;;

# ------------------------------------------------------------------ lockrace
  lockrace)
  # TWO OVERLAPPING POLLS, which is the half of armaatus/autofleet#64 that
  # produces the two reviews in the first place. The dispatcher checks for the
  # lock and writes it AFTER the spawn, so two passes -- or a hand-run beside a
  # dispatcher -- both saw no lock and both started a reviewer. The claim is
  # made by the reviewer itself now, and it is a create-or-fail rather than a
  # test followed by a write: `[ -e ] || printf >` is two syscalls with exactly
  # this race between them.
  make_fixture; stub_reviewer marked
  export AUTOFLEET_TEST_REVIEWER_DELAY=5
  run_it 42 >"$WORK/out1" 2>&1 & a=$!
  run_it 42 >"$WORK/out2" 2>&1 & b=$!
  wait "$a"; rc1=$?
  wait "$b"; rc2=$?
  case "$rc1 $rc2" in
    "0 9"|"9 0") ok "one of two concurrent reviewers wins the lock; the other exits 9" ;;
    *) cat "$WORK/out1" "$WORK/out2" >&2
       fail "two concurrent runs exited $rc1 and $rc2, not one 0 and one 9" ;;
  esac
  [ "$(n_reviews)" = 1 ] || fail "$(n_reviews) reviews were submitted against one head"
  ok "...and exactly one review is on the head"
  [ "$(n_started)" = 1 ] || fail "$(n_started) reviewers ran, not one"
  ok "...and only one reviewer ever ran"
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
  pgrep -f "$REVIEWER_WORK" >/dev/null 2>&1 \
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

    # A PUSH DOES NOT BUY ANOTHER REVIEW, and that is the change. It used to:
    # `merge-gate` wants a verdict on the CURRENT head, so every fix started a
    # full re-review of the whole diff, which found one more thing a level down,
    # which bought another push. #86 spent four reviews without one ever judging
    # the commit that merged.
    #
    # What judges the fix now is the VALIDATOR -- a narrower question, bounded at
    # two, and `merge_gate.py` reads its `pass` as standing in for the review.
    (cd "$WORK/repo" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m push)
    git -C "$WORK/repo" rev-parse HEAD >"$GH_HEAD"
    printf '[{"number":42,"isDraft":false,"headRefOid":"%s"}]\n' "$(cat "$GH_HEAD")" >"$GH_PRLIST"
    poll_review_open_prs
    await n_spawned 2 10 >/dev/null 2>&1 || true
    [ "$(n_spawned)" = 1 ] \
      || fail "a push started a $(n_spawned)th reviewer; the review runs once per pull request"
    ok "...and a push does not buy another review"

    # ...but it IS handed to a validator. `validate.sh` decides for itself
    # whether one is due -- the stub's review reports `review-findings: 0`, so
    # there is nothing to check and it exits 8 without spawning an agent -- and
    # what this asserts is that the DISPATCHER offered it the pull request at
    # all. Without that line the second phase is unreachable and every PR with
    # findings blocks forever on a validation nothing starts.
    # AT LEAST ONE, not exactly one. `start_validator` writes its lock AFTER the
    # spawn -- the pid is what goes in it -- so back-to-back polls can each start
    # one before the first has written anything, which is the same benign race
    # review.sh documents at its own `printf`. What settles it is the `.done`
    # record, asserted next.
    await_min n_validated 1 || fail "a new head was offered to no validator, so nothing can ever judge a fix"
    ok "...it is handed to the validator instead"

    # ...and it STOPS. `validate.sh` writes `v-42.done` on the exit-8 path -- the
    # stub's review reports `review-findings: 0`, so there is nothing to check --
    # and `start_validator` reads it before spawning. Without that record a
    # validator is started every poll for the life of the pull request, which is
    # armaatus/autofleet#33 in the second phase: fourteen spawns in thirteen
    # minutes, each exiting two API calls later, burying the dispatcher log.
    await_file "$AUTOFLEET_DIR/reviewing/v-42.done" 30 \
      || fail "the validator left no done-record, so every poll starts another one: $(tail -30 "$AUTOFLEET_DIR/fleet.log" 2>/dev/null)"
    settled="$(n_validated)"
    for _ in 1 2 3; do poll_review_open_prs; done
    await n_validated "$(( settled + 1 ))" 10 >/dev/null 2>&1 || true
    [ "$(n_validated)" = "$settled" ] \
      || fail "three further polls started $(( $(n_validated) - settled )) more validators on a head already handled"
    ok "...and a handled head is not handed to another one"
    ;;

# -------------------------------------------------------------------- rounds
  rounds)
    # The counter nothing had. `.tries` is per HEAD and counts reviewers that
    # submitted NOTHING -- so a PR whose every round produces findings is
    # bounded by nothing at all. `.autofleet/run/review-rounds` is per WORKTREE
    # and increments only where a round was read back, and it undercounts:
    # measured at 3 against 4 real reviews on #85, 2 against 4 on #86, 1 against
    # 3 on #88. `.rounds` counts reviews SUBMITTED, on this pull request, across
    # every head it has been on.
    make_fixture; stub_reviewer marked
    printf '[{"number":42,"isDraft":false,"headRefOid":"%s"}]\n' "$(cat "$GH_HEAD")" >"$GH_PRLIST"
    poll_review_open_prs
    await n_reviews 1 || fail "the first reviewer submitted nothing"
    await lock_held no || fail "the first reviewer never released its lock"
    [ "$(cat "$AUTOFLEET_DIR/reviewing/42.rounds" 2>/dev/null)" = 1 ] \
      || fail "a submitted review did not count a round (got '$(cat "$AUTOFLEET_DIR/reviewing/42.rounds" 2>/dev/null)')"
    ok "a submitted review counts one round"

    # ACROSS A HEAD MOVE, which is the whole reason this is not another column
    # in `.tries`. Every measured PR was stuck because the head kept moving; a
    # counter that resets on a push counts nothing about that.
    (cd "$WORK/repo" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m push)
    git -C "$WORK/repo" rev-parse HEAD >"$GH_HEAD"
    printf '[{"number":42,"isDraft":false,"headRefOid":"%s"}]\n' "$(cat "$GH_HEAD")" >"$GH_PRLIST"
    poll_review_open_prs
    # The count SURVIVES the head move -- which is the whole reason it is not
    # another column in `.tries` -- and it does not grow, because with
    # AUTOFLEET_REVIEW_MAX at 1 the pull request has had its review.
    await_min n_validated 1 || fail "the new head was offered to no validator"
    [ "$(n_reviews)" = 1 ] \
      || fail "a push bought a $(n_reviews)th review; the reviewer runs once per pull request"
    [ "$(cat "$AUTOFLEET_DIR/reviewing/42.rounds" 2>/dev/null)" = 1 ] \
      || fail "the round count changed across a push (got '$(cat "$AUTOFLEET_DIR/reviewing/42.rounds" 2>/dev/null)')"
    ok "...and a push neither resets it nor adds to it"

    # A reviewer that submits NOTHING is not a round. It burns a try, which is a
    # different cap for a different population, and counting it here would
    # retire a pull request nobody reviewed.
    #
    # ON A FRESH FIXTURE, with the review cap RAISED. At the default of 1 the
    # pull request above is past its cap and no second reviewer starts at all,
    # so the phase would assert the property on a reviewer that never ran --
    # green, and measuring nothing. The `.rounds`/`.tries` asymmetry is not about
    # the cap's value, so driving it at 2 is the honest way to reach it.
    make_fixture; stub_reviewer silent
    export AUTOFLEET_REVIEW_MAX=2
    printf '[{"number":42,"isDraft":false,"headRefOid":"%s"}]\n' "$(cat "$GH_HEAD")" >"$GH_PRLIST"
    poll_review_open_prs
    await lock_held no || fail "the silent reviewer never released its lock"
    [ ! -e "$AUTOFLEET_DIR/reviewing/42.rounds" ] \
      || fail "a reviewer that submitted nothing was counted as a round (got '$(cat "$AUTOFLEET_DIR/reviewing/42.rounds" 2>/dev/null)')"
    ok "...and a reviewer that submitted nothing is not one"
    ;;

# ------------------------------------------------------------------ roundcap
  roundcap)
    # The backstop. Nothing bounded the NUMBER of reviews a pull request could
    # accrue: fleet.sh started one for every new head, forever, and #86 had four
    # with none of them ever judging its current head. The agent-side cap
    # (AWAIT_REVIEW_MAX_ROUNDS) only binds while the agent is alive -- #85's
    # stopped at its cap and a fourth review landed with nobody left to answer.
    make_fixture; stub_reviewer marked
    export AUTOFLEET_REVIEW_MAX=2
    mkdir -p "$AUTOFLEET_DIR/reviewing"
    printf '2\n' >"$AUTOFLEET_DIR/reviewing/42.rounds"
    printf '[{"number":42,"isDraft":false,"headRefOid":"%s"}]\n' "$(cat "$GH_HEAD")" >"$GH_PRLIST"
    poll_review_open_prs
    await n_spawned 1 10 >/dev/null 2>&1 || true
    [ "$(n_spawned)" = 0 ] \
      || fail "a PR at the review cap was handed to another reviewer anyway"
    ok "at the cap, no further reviewer is started"

    # ...AND IT IS HANDED TO THE VALIDATOR, which is what reaching the cap means
    # now. With AUTOFLEET_REVIEW_MAX at its default of 1 every healthy pull
    # request reaches this branch on its second poll, so a `continue` here would
    # not be "this PR has failed to converge" -- it would be the second phase
    # never starting on any pull request at all, and every PR with findings
    # blocking forever on a validation nothing writes.
    #
    # The old assertion here was for a message ("which is the cap. Needs you")
    # that has correctly gone: a hold announcing a person is due is false on the
    # path every PR takes. The hold that still means something is the VALIDATION
    # cap, and `validate.sh` prints it where the number lives.
    await_min n_validated 1 \
      || fail "a PR past the review cap was handed to no validator, so the second phase never starts"
    ok "...it is handed to the validator instead"

    # AND ON A NEW HEAD TOO. This is what separates it from the per-head cap: a
    # push must not buy a fresh set of rounds, or the cap is only ever one push
    # away from not existing.
    (cd "$WORK/repo" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m push)
    git -C "$WORK/repo" rev-parse HEAD >"$GH_HEAD"
    printf '[{"number":42,"isDraft":false,"headRefOid":"%s"}]\n' "$(cat "$GH_HEAD")" >"$GH_PRLIST"
    poll_review_open_prs
    await n_spawned 1 10 >/dev/null 2>&1 || true
    [ "$(n_spawned)" = 0 ] \
      || fail "a push past the review cap started a reviewer, so the cap is one push from nothing"
    ok "...and a push does not buy a fresh set of rounds"

    # The knob is validated the way its neighbour is, and for the same reason:
    # `[ 2 -ge abc ]` returns 2, which is FALSE, so the cap silently does not
    # exist and fleet.sh runs without `-e` to notice.
    for bad in abc 0 2x -1; do
      cfg_out="$( (cd "$WORK/repo" \
        && AUTOFLEET_REVIEW_MAX="$bad" bash -c '. ./scripts/fleet/config.sh') 2>&1 )"
      cfg_rc=$?
      [ "$cfg_rc" = 2 ] \
        || fail "AUTOFLEET_REVIEW_MAX='$bad' was accepted (rc=$cfg_rc): $cfg_out"
      grep -q "must be a positive whole number" <<<"$cfg_out" \
        || fail "AUTOFLEET_REVIEW_MAX='$bad' failed without saying why: $cfg_out"
    done
    ok "...and a cap that is not a positive number is refused, not ignored"

    # ...AND THE SHARED READER OF THAT FILE HAS ITS OWN ASSERTIONS. The knob is
    # validated above; `<pr>.tries` is a file on disk and nothing validates it,
    # so `fleet_tries_count` is where "what if it is junk" is answered -- once,
    # for the dispatcher's two spawn paths, review.sh and validate.sh. It
    # replaced four hand-written copies of the read, two of which normalised a
    # non-numeric count and two of which compared it directly. Whether that
    # difference was ever reachable is not asserted here and was not
    # reproduced; what is asserted is that the one reader left cannot hand a
    # caller anything but a number.
    m="$AUTOFLEET_DIR/reviewing/tries-probe"
    printf 'abc123 two\n' >"$m"
    [ "$(in_fleet_fn fleet_tries_count "$m" abc123)" = 0 ] \
      || fail "a non-numeric count did not read as zero: $(in_fleet_fn fleet_tries_count "$m" abc123)"
    printf 'abc123 3\n' >"$m"
    [ "$(in_fleet_fn fleet_tries_count "$m" abc123)" = 3 ] \
      || fail "the count for the head the marker names was not read back"
    [ "$(in_fleet_fn fleet_tries_count "$m" deadbee)" = 0 ] \
      || fail "a count was charged to a head the marker does not name"
    : >"$m"
    [ "$(in_fleet_fn fleet_tries_count "$m" abc123)" = 0 ] \
      || fail "an empty marker did not read as zero, so the cap compares against nothing"
    [ "$(in_fleet_fn fleet_tries_count "$m.absent" abc123)" = 0 ] \
      || fail "an absent marker did not read as zero"
    rm -f "$m"
    ok "...and fleet_tries_count answers with a number for junk, empty, absent and another head"

    # THE KNOB THAT WAS REPLACED IS AN ERROR, NOT AN ALIAS. A host project that
    # tuned `AUTOFLEET_REVIEW_MAX_ROUNDS` meant "give this repository more
    # rounds", which maps onto neither of the two knobs that replaced it --
    # aliasing it would keep the file working and quietly change what it asks
    # for. Empty as well as set, because a half-edited config leaves `KNOB=` and
    # that is still someone who thinks they have configured the cap.
    for dead in 4 ""; do
      cfg_out="$( (cd "$WORK/repo" \
        && AUTOFLEET_REVIEW_MAX_ROUNDS="$dead" bash -c '. ./scripts/fleet/config.sh') 2>&1 )"
      cfg_rc=$?
      [ "$cfg_rc" = 2 ] \
        || fail "the replaced knob AUTOFLEET_REVIEW_MAX_ROUNDS='$dead' was accepted (rc=$cfg_rc): $cfg_out"
      grep -q 'AUTOFLEET_VALIDATE_MAX' <<<"$cfg_out" \
        || fail "it refused the replaced knob without naming what replaced it: $cfg_out"
    done
    ok "...and the knob it replaced is refused, naming both of its successors"

    # Through .autofleet/config, which is sourced LAST and is the route a host
    # project actually uses. Its neighbour's check sat with the defaults and was
    # decorative for every real user of the knob until that was found.
    hostcfg="$WORK/hostcfg"
    for bad in three 0 ""; do
      printf 'AUTOFLEET_REVIEW_MAX=%s\n' "$bad" >"$hostcfg"
      cfg_out="$( (cd "$WORK/repo" \
        && env -u AUTOFLEET_REVIEW_MAX AUTOFLEET_CONFIG="$hostcfg" \
             bash -c '. ./scripts/fleet/config.sh') 2>&1 )"
      cfg_rc=$?
      [ "$cfg_rc" = 2 ] \
        || fail "a config file setting the round cap to '$bad' was accepted (rc=$cfg_rc): $cfg_out"
    done
    ok "...including when it arrives through .autofleet/config, which is read last"
    ;;

# --------------------------------------------------------------------- crash
  crash)
  # A VALIDATOR THAT EXITS NON-ZERO MUST STILL BE REPORTED, and for one round it
  # was not. `validate.sh` ran under `set -euo pipefail` where `review.sh`
  # deliberately runs under `set -uo pipefail` -- no `-e` -- and the difference
  # lands on one line:
  #
  #     wait "$validator"; rc=$?
  #
  # Under `-e` a non-zero exit from the supervised process terminates the script
  # AT the `wait`. Everything after it is skipped: the "did it leave a verdict"
  # check, `record_done`, the `.tries` burn, and the diagnostic naming the log.
  # The EXIT trap still drops the lock, so the dispatcher starts another
  # validator on the next poll, and the one after that -- which is
  # armaatus/autofleet#33's spawn loop arriving through the guard written to
  # prevent it.
  #
  # The failing case is the one this phase drives, and it is not exotic: an agent
  # that hits an API error or runs out of turns exits non-zero and submits
  # nothing.
  make_fixture; stub_reviewer marked
  printf '[{"number":42,"isDraft":false,"headRefOid":"%s"}]\n' "$(cat "$GH_HEAD")" >"$GH_PRLIST"
  # A finding to check, so `validate.sh` gets past its exit-8 branch and actually
  # starts an agent. Without this the phase passes against a script that never
  # reaches `wait` at all.
  python3 - "$GH_REVIEWS" "$(cat "$GH_HEAD")" <<'PY_SEED'
import json, sys
path, oid = sys.argv[1], sys.argv[2]
records = json.load(open(path))
records.append({"commit_id": oid, "user": "armaatus",
                "body": "Important: the retry has no backoff.\n"
                        "<!-- review-important: 1 -->\n<!-- review-findings: 1 -->"})
json.dump(records, open(path, "w"))
PY_SEED
  stub_reviewer crash
  out="$( (cd "$WORK/repo" && AUTOFLEET_VALIDATE_MARKER="$AUTOFLEET_DIR/reviewing/v-42" \
            ./scripts/fleet/validate.sh 42) 2>&1 )"; rc=$?
  # Exit 5 is "ran, submitted nothing" -- the documented answer. Anything else,
  # and in particular the validator's own exit code leaking through, means the
  # script died at `wait` instead of judging.
  [ "$rc" = 5 ] \
    || { echo "$out" >&2; fail "a validator that exited non-zero was not reported as having submitted nothing (got rc=$rc)"; }
  grep -q 'left NO verdict' <<<"$out" \
    || { echo "$out" >&2; fail "it died at the wait instead of saying no verdict arrived: $out"; }
  grep -q 'validated:' <<<"$out" \
    || { echo "$out" >&2; fail "the diagnostic does not name the trailer that is missing, which is the usual cause"; }
  ok "a validator that exits non-zero is reported, not silently fatal"
  ;;

# ------------------------------------------------------------------- vcapped
  vcapped)
  # A VALIDATOR THAT SUBMITS NOTHING IS RETRIED -- AND NOT FOREVER.
  #
  # `validate.sh` exit 5 writes no `.done` record, correctly: retrying is usually
  # right. Unbounded, that is a full-budget agent started every poll against a
  # head that will never get a verdict, for the life of the pull request. For one
  # round nothing bounded it at all -- the refund helpers in `validate.sh` were
  # decrementing a `v-<pr>.tries` file the dispatcher never wrote.
  #
  # Not the same counter as AUTOFLEET_VALIDATE_MAX, which counts verdicts this
  # PR has HAD. This counts attempts on ONE head that produced nothing.
  make_fixture; stub_reviewer marked
  export AUTOFLEET_REVIEW_MAX_TRIES=2
  printf '[{"number":42,"isDraft":false,"headRefOid":"%s"}]\n' "$(cat "$GH_HEAD")" >"$GH_PRLIST"
  poll_review_open_prs
  await n_reviews 1 || fail "the first reviewer submitted nothing"
  await lock_held no || fail "the first reviewer never released its lock"
  # A finding, so a validation is genuinely due on every later poll.
  python3 - "$GH_REVIEWS" "$(cat "$GH_HEAD")" <<'PY_SEED'
import json, sys
path, oid = sys.argv[1], sys.argv[2]
records = json.load(open(path))
records.append({"commit_id": oid, "user": "armaatus",
                "body": "Important: the retry has no backoff.\n"
                        "<!-- review-important: 1 -->\n<!-- review-findings: 1 -->"})
json.dump(records, open(path, "w"))
PY_SEED
  # ...and a validator that runs and submits nothing, every time.
  stub_reviewer silent
  for _ in 1 2 3 4 5; do
    poll_review_open_prs
    await vlock_held no 60 >/dev/null 2>&1 || true
  done
  out="$(cat "$AUTOFLEET_DIR/fleet.log" 2>/dev/null)"
  started="$(n_validated)"
  [ "$started" -le 2 ] \
    || { echo "$out" >&2; fail "five polls started $started validators on one head; the cap is 2"; }
  ok "a validator that submits nothing is retried, and bounded"
  grep -q "submitted nothing, which is the cap" <<<"$out" \
    || { echo "$out" >&2; fail "it stopped at the cap without saying so"; }
  grep -q "a missing verdict is not a passing one" <<<"$out" \
    || { echo "$out" >&2; fail "it stopped without saying the PR stays HELD, which is the half a reader needs"; }
  ok "...and says so once, naming the log and the safe direction"
  ;;

# ------------------------------------------------------------------ validate
  validate)
  # `validate.sh`'s OWN behaviour, driven directly rather than through the
  # dispatcher. The `once` and `roundcap` phases assert that a pull request gets
  # handed to it; this asserts what it does when it is.
  make_fixture; stub_reviewer marked
  printf '[{"number":42,"isDraft":false,"headRefOid":"%s"}]\n' "$(cat "$GH_HEAD")" >"$GH_PRLIST"

  run_validate() { (cd "$WORK/repo" && ./scripts/fleet/validate.sh 42 2>&1); }

  # NOTHING TO VALIDATE is exit 8, and it is the common answer. The stub's
  # review declares `review-findings: 0`, so no finding was ever left to check
  # and starting a full-budget agent to say so would cost more than the phase
  # saves. `merge_gate.needs_validation` is the one definition of this and
  # `validate.sh` asks it rather than deciding for itself -- three paraphrases of
  # "what counts" drifted apart once already (#114), always permissively, and
  # permissive here is a branch merging on a validation nobody asked for.
  out="$(run_validate)"; rc=$?
  [ "$rc" = 8 ] || { echo "$out" >&2; fail "a PR with no findings did not exit 8 (got $rc)"; }
  grep -q 'wants no validation' <<<"$out" \
    || { echo "$out" >&2; fail "it declined without saying why"; }
  ok "a PR whose review found nothing wants no validation"

  # THE MODE GATE. A `github`-mode repository reaching this script is not an
  # error -- the dispatcher never calls it there, `validate.yml` does the job --
  # so it is a quiet 4 rather than a failure.
  printf 'AUTOFLEET_REVIEW_MODE=github\n' >"$WORK/repo/.autofleet/config"
  out="$(run_validate)"; rc=$?
  [ "$rc" = 4 ] || { echo "$out" >&2; fail "github mode did not exit 4 (got $rc)"; }
  grep -q 'validate.yml' <<<"$out" \
    || { echo "$out" >&2; fail "it declined without naming the workflow that does the job there"; }
  ok "...and in github mode it declines quietly, naming validate.yml"
  printf 'AUTOFLEET_REVIEW_MODE=local\n' >"$WORK/repo/.autofleet/config"

  # THE STOP IS A STOP. This submits a review to a pull request, which is
  # exactly what nothing may do while that file exists.
  : >"$AUTOFLEET_DIR/STOP"
  out="$(run_validate)"; rc=$?
  [ "$rc" = 3 ] || { echo "$out" >&2; fail "a stopped fleet did not exit 3 (got $rc)"; }
  ok "...and a stopped fleet stops it"
  rm -f "$AUTOFLEET_DIR/STOP"

  # NO BRIEF IS A REFUSAL, NOT A GUESS. Without `.claude/agents/validator.md`
  # there is no scope, and a validator with no scope re-reviews the whole branch
  # -- which is the behaviour this entire phase exists to remove.
  mv "$WORK/repo/.claude/agents/validator.md" "$WORK/repo/.claude/agents/validator.md.away"
  out="$(run_validate)"; rc=$?
  [ "$rc" = 2 ] || { echo "$out" >&2; fail "a missing validator brief did not exit 2 (got $rc)"; }
  ok "...and it refuses to run with no brief rather than improvising a scope"
  mv "$WORK/repo/.claude/agents/validator.md.away" "$WORK/repo/.claude/agents/validator.md"

  # THE CAP, exit 9, and the message that names a person. Past
  # AUTOFLEET_VALIDATE_MAX this is not a failure -- it is the design, and a PR
  # quietly held with nothing explaining it is the failure.
  #
  # `.rounds` primed directly: what the cap counts is validations this pull
  # request has had, and reaching it by running two real ones would make this
  # phase a test of the agent stub rather than of the cap.
  export AUTOFLEET_VALIDATE_MAX=2
  mkdir -p "$AUTOFLEET_DIR/reviewing"
  printf '2\n' >"$AUTOFLEET_DIR/reviewing/v-42.rounds"
  # ...and a finding to check, so it gets past the exit-8 branch above and
  # reaches the cap at all. Without this the phase would pass against a script
  # that has no cap, because it would never look for one.
  python3 - "$GH_REVIEWS" "$(cat "$GH_HEAD")" <<'PY_FIX'
import json, sys
path, oid = sys.argv[1], sys.argv[2]
records = json.load(open(path))
records.append({"commit_id": oid, "user": "armaatus",
                "body": "Important: the retry has no backoff.\n"
                        "<!-- review-important: 1 -->\n<!-- review-findings: 1 -->"})
json.dump(records, open(path, "w"))
PY_FIX
  out="$(AUTOFLEET_VALIDATE_MARKER="$AUTOFLEET_DIR/reviewing/v-42" run_validate)"; rc=$?
  [ "$rc" = 9 ] || { echo "$out" >&2; fail "a PR at the validation cap did not exit 9 (got $rc)"; }
  grep -q 'a person decides' <<<"$out" \
    || { echo "$out" >&2; fail "it stopped at the cap without saying a person is due: $out"; }
  ok "at AUTOFLEET_VALIDATE_MAX it stops and says a person decides"
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
    # ...and let the SECOND reviewer finish first. `n_started` counts the stub,
    # which runs before review.sh's post-check -- so the count reaches two while
    # the second run still holds the PR's lock, and the hand-run below then
    # correctly refuses with exit 9 rather than reaching the deadline it is
    # about. The phase measured the lock it had left held itself.
    await lock_held no || fail "the second reviewer never released its lock"
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
  # `.rounds` in the list too. It is the ONE record `stop_reviewers` keeps, and
  # a reader who knows that could reasonably think the sweep keeps it as well --
  # it does not, and must not: what it counts belongs to a pull request, and
  # this pull request is closed. The two halves of that rule are asserted in the
  # two places they differ. Found by the independent review.
  printf '3\n' >"$AUTOFLEET_DIR/reviewing/99.rounds"
  poll_review_open_prs
  for f in 99.done 99.said 99.tries 99.rounds; do
    [ -e "$AUTOFLEET_DIR/reviewing/$f" ] \
      && fail "a closed PR's $f survived the pass, so the directory grows for as long as the dispatcher lives -- and these are the files the count above reads"
  done
  ok "...and a closed PR's records are swept, .rounds included"

  # `stop_reviewers` clears all three. NOT asserted: that it does not SIGNAL
  # them. Treated as locks, their first field is a head sha, `kill` is handed a
  # non-number and fails, and `rm -f` follows on both paths -- so the two
  # spellings are indistinguishable from outside. The branch still belongs
  # there for `reviewer_alive`'s own reason: a numeric-looking first field WOULD
  # be signalled, and nothing guarantees a future record's first field is not
  # numeric. Said rather than asserted, because a phase claiming to pin it would
  # be the inert kind this suite has shipped twice.
  printf '3\n' >"$AUTOFLEET_DIR/reviewing/43.rounds"
  in_poll stop_reviewers >/dev/null 2>&1
  [ -e "$AUTOFLEET_DIR/reviewing/43.done" ] \
    && fail "stop_reviewers left 43.done behind, so the next dispatcher inherits a stale record"
  ok "...and a stop clears the records"

  # ...EXCEPT `.rounds`, and this is the assertion that rule did not have. The
  # exemption is one `case ... continue` inside a loop whose stated purpose is
  # "the records go too", so it reads as a special case somebody could tidy
  # away -- and every phase in this suite would stay green. What breaks is
  # invisible until it matters: AUTOFLEET_REVIEW_MAX_ROUNDS resets on every
  # `stop.sh` and every dispatcher restart, both routine and both in CLAUDE.md's
  # Environment block, so the PR-level cap is one drain from not existing.
  # docs/CONFIGURATION.md and docs/WORKFLOW.md both promise it survives.
  # Found by the independent review, which called it hard rule 3, and it is.
  [ -e "$AUTOFLEET_DIR/reviewing/43.rounds" ] \
    || fail "stop_reviewers cleared 43.rounds, so every drain hands each open PR a fresh set of rounds and the cap is one stop.sh from nothing"
  [ "$(cat "$AUTOFLEET_DIR/reviewing/43.rounds")" = 3 ] \
    || fail "stop_reviewers changed the round count rather than leaving it alone"
  ok "...except .rounds, which counts the pull request and not this dispatcher's run"

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
  # A DELTA ROUND'S CONTEXT FILE goes with its log, and an orphan goes on its
  # own. Neither is a `.log`, so the sweep's glob cannot see them: unswept, the
  # reviews directory trades one kind of growth for another, which is the thing
  # armaatus/autofleet#70 measured and #65 must not undo.
  : >"$AUTOFLEET_DIR/reviews/pr-42-aaaaaaaa.context.md"
  : >"$AUTOFLEET_DIR/reviews/pr-97-77777777.context.md"
  AUTOFLEET_KEEP_REVIEWS=2 poll_review_open_prs
  AUTOFLEET_KEEP_REVIEWS=2 poll_review_open_prs
  [ -e "$AUTOFLEET_DIR/reviews/pr-98-99999999.log" ] \
    || fail "a transcript was swept while a reviewer for that PR was still writing to it"
  [ -e "$AUTOFLEET_DIR/reviews/pr-42-aaaaaaaa.context.md" ] \
    && fail "a context file outlived the transcript it belongs to"
  ok "...and a delta round's context file is swept with its own transcript"
  [ -e "$AUTOFLEET_DIR/reviews/pr-97-77777777.context.md" ] \
    && fail "a context file with no transcript beside it was never swept at all"
  ok "...and one orphaned by a reviewer that never wrote a log goes too"

  # THE FETCHED PR REFS. `review.sh` drops its own in an EXIT trap that a
  # SIGTERM taken before the reviewer is spawned, a SIGKILL, or an OOM all skip
  # -- and a ref left behind pins every object that pull request ever had
  # against `git gc`, forever. Nothing else in the fleet looks at them. 42 is
  # open and must be spared, because a reviewer running right now resolves its
  # range against that very ref; 96 is not open and must go. Found by the local
  # review of armaatus/autofleet#65.
  git -C "$WORK/repo" update-ref "refs/autofleet/review/42" "$PR_HEAD"
  git -C "$WORK/repo" update-ref "refs/autofleet/review/96" "$PR_HEAD"
  printf '[{"number":42,"isDraft":false,"headRefOid":"%s"}]\n' "$PR_HEAD" >"$GH_PRLIST"
  AUTOFLEET_KEEP_REVIEWS=2 poll_review_open_prs
  git -C "$WORK/repo" rev-parse --verify -q "refs/autofleet/review/42" >/dev/null \
    || fail "the sweep took an OPEN pull request's fetched ref, so a running delta review's range stops resolving"
  ok "an open PR's fetched review ref is left alone"
  git -C "$WORK/repo" rev-parse --verify -q "refs/autofleet/review/96" >/dev/null \
    && fail "a closed PR's fetched ref survived, so its objects are pinned against git gc forever"
  ok "...while one belonging to a PR that is gone is dropped"
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
    pgrep -f "$REVIEWER_WORK" >/dev/null 2>&1 \
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

# -------------------------------------------------------------------- reap
  reap)
  # THE SWEEP DELETES BY CONTENT, not by path. `live_reviewers` reads the pid,
  # asks `ps` whether it is alive -- the slow part -- and only then removes the
  # marker. A hand-run `review.sh` that takes the same stale lock over in that
  # window recreates the marker under its OWN pid, and a path-keyed `rm -f`
  # deleted that live claim; the same pass then spawned a second reviewer on the
  # head, which is armaatus/autofleet#64 through the half of the lock that
  # stayed unconditional. The window cannot be staged deterministically from
  # out here, so what is asserted is the primitive that closes it and that the
  # sweep still reaps what it should. Found by both self-review passes.
  make_fixture
  mkdir -p "$AUTOFLEET_DIR/reviewing"

  # A marker whose content has MOVED ON since the sweep read it: the pid the
  # sweep is about to reap is not the pid in the file any more.
  sleep 120 & taker=$!
  printf '%s %s\n' "$taker" "deadbeef" >"$AUTOFLEET_DIR/reviewing/77"
  ( cd "$WORK/repo" && . ./scripts/fleet/lib.sh \
      && fleet_lock_reap "$AUTOFLEET_DIR/reviewing/77" 999999 )
  if [ -e "$AUTOFLEET_DIR/reviewing/77" ]; then
    ok "a lock taken over since the sweep read it is not reaped"
  else
    kill "$taker" 2>/dev/null
    fail "fleet_lock_reap deleted a marker that names a different pid"
  fi
  ( cd "$WORK/repo" && . ./scripts/fleet/lib.sh \
      && fleet_lock_reap "$AUTOFLEET_DIR/reviewing/77" "$taker" )
  [ -e "$AUTOFLEET_DIR/reviewing/77" ] \
    && { kill "$taker" 2>/dev/null; fail "the marker it does name was not reaped"; }
  kill "$taker" 2>/dev/null
  ok "...and the one it does name is"

  # A ZERO-BYTE MARKER, which is the `set -C` window in `fleet_lock_publish`,
  # a crash between create and write, or `fleet_lock_claim` restoring a stolen
  # file that was empty. The sweeps used to `rm -f` this unconditionally; the
  # by-content guard has to keep reaping it or it becomes immortal. `read`
  # fails at EOF exactly as it fails on an open error, so leaning on its status
  # turned "the file is empty" into "the file is gone" and returned early --
  # and then every poll found a marker with no head, spawned a reviewer whose
  # `fleet_lock_claim` returned 3, and `review.sh` exited 2 saying "the
  # dispatcher clears it on its next poll", which it never did. That PR is
  # never reviewed again. Found by the self-review of the merge.
  : >"$AUTOFLEET_DIR/reviewing/76"
  ( cd "$WORK/repo" && . ./scripts/fleet/lib.sh \
      && fleet_lock_reap "$AUTOFLEET_DIR/reviewing/76" "" )
  [ -e "$AUTOFLEET_DIR/reviewing/76" ] \
    && fail "a zero-byte marker is never reaped, so that PR is wedged forever"
  ok "...and a marker holding no pid at all is reaped, not left immortal"

  # ...but NOT under a caller that names a pid: an empty marker does not name
  # 4242, and reaping it here would be the path-keyed `rm -f` coming back in
  # through the guard that replaced it.
  : >"$AUTOFLEET_DIR/reviewing/75"
  ( cd "$WORK/repo" && . ./scripts/fleet/lib.sh \
      && fleet_lock_reap "$AUTOFLEET_DIR/reviewing/75" 4242 )
  [ -e "$AUTOFLEET_DIR/reviewing/75" ] \
    || fail "an empty marker was reaped by a sweeper that named a live pid"
  ok "...and only for the sweeper that read that same emptiness"
  rm -f "$AUTOFLEET_DIR/reviewing/75"

  # ...AND THE SWEEPS ACTUALLY CALL IT. `live_reviewers` is nested inside
  # `review_open_prs` and cannot be invoked on its own, so the wiring is
  # asserted where it lives: no sweep in fleet.sh may remove a reviewer marker
  # by path. Without this the primitive above can sit unused and every
  # assertion here stays green -- which is hard rule 3's case exactly. The
  # `.done` record at :1710 is not a lock (it holds a head, not a pid) and the
  # drain at :1716 removes every marker on purpose, so both are named rather
  # than matched loosely.
  # Scoped to `review_open_prs`, which is where both sweeps live. The drain in
  # `stop_reviewers` is deliberately unconditional -- it has just killed
  # whatever held each marker -- and `$marker` names an unrelated handoff-ask
  # file elsewhere in this script, so a file-wide grep would report both.
  bad="$(cd "$WORK/repo" \
         && awk '/^review_open_prs\(\) \{/,/^\}/' scripts/fleet/fleet.sh \
          | grep -nE 'rm -f "\$(marker|m)"( |;|$)' || true)"
  [ -z "$bad" ] \
    || fail "a sweep in review_open_prs still removes a reviewer marker by path:
$bad"
  ok "...and no sweep in review_open_prs removes a marker by path"
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
  # The four rows below catch two SHAPES -- a write-time expansion that writes to
  # stderr, and the loss of one named line. They never caught the class: an
  # expansion that succeeds SILENTLY and eats text they do not name -- `\`date\``,
  # `$HOME` -- passed all four. The last row of this phase is the general
  # assertion and is what the rest of it is now a cheap prefix of: the written
  # file compared against the heredoc body in this file, byte for byte.
  # armaatus/autofleet#71.
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

  # The same two halves for what armaatus/autofleet#65 added, which is the block
  # that reproduced this bug a second time: four backticks in a comment about
  # `finish_log`, and four `command not found` lines on stderr.
  grep -qF 'finish_log' "$WORK/bin/fake-reviewer" \
    || fail "the cost-row prose was consumed as a command substitution"
  ok "...and the same holds for the prose about the JSON output mode"
  grep -qF "$PROMPT_FILE" "$WORK/bin/fake-reviewer" \
    || fail "the stub cannot record the prompt; \$PROMPT_FILE did not expand"
  grep -qF "$ARGV_FILE" "$WORK/bin/fake-reviewer" \
    || fail "the stub cannot record the argv; \$ARGV_FILE did not expand"
  ok "...and the prompt- and argv-capture paths are baked in, so both are assertable"

  # THE CLASS, not two shapes of it. Reconstruct the stub from the heredoc body
  # in THIS file and require the written stub to equal it byte for byte.
  #
  # The reconstruction is deliberately narrow, which is where the assertion
  # comes from: an ALLOWLIST of the five paths plus `$1` -- what the heredoc is
  # unquoted FOR -- and nothing else. Any other unescaped `$NAME`, any `$(`, any
  # backtick is a failure by NAME rather than by its effect, so `$HOME` eating
  # half a comment fails here whether or not it happens to be quiet, and so does
  # the next construct nobody has thought of. The backtick that hung CI for nine
  # minutes fails on row one of this check rather than by the suite going
  # silent.
  #
  # `\$1` is an expansion too, and it is the stub's MODE: this phase wrote the
  # stub with `marked`, so that is what the reconstruction substitutes.
  STUB_SRC="${BASH_SOURCE[0]}" STUB_OUT="$WORK/bin/fake-reviewer" STUB_MODE=marked \
  REVIEWER_CALLS="$REVIEWER_CALLS" PROMPT_FILE="$PROMPT_FILE" ARGV_FILE="$ARGV_FILE" \
  GH_HEAD="$GH_HEAD" GH_REVIEWS="$GH_REVIEWS" REVIEWER_WORK="$REVIEWER_WORK" \
  python3 - <<'RECONSTRUCT' || fail "the written reviewer stub is not the heredoc body in $(basename "${BASH_SOURCE[0]}")"
import os, re, sys

src = open(os.environ["STUB_SRC"]).read()
m = re.search(r'cat >"\$WORK/bin/fake-reviewer" <<STUB\n(.*?)\nSTUB\n', src, re.S)
if not m:
    sys.exit("could not find the stub heredoc in the source; this phase asserts nothing")
body = m.group(1)

# The paths the heredoc is unquoted for, and the mode. Adding a name here is a
# deliberate act; anything not on the list is the failure.
allowed = {n: os.environ[n] for n in
           ("REVIEWER_CALLS", "PROMPT_FILE", "ARGV_FILE", "GH_HEAD", "GH_REVIEWS",
            "REVIEWER_WORK")}
allowed["1"] = os.environ["STUB_MODE"]

out, i = [], 0
while i < len(body):
    c = body[i]
    # An unquoted heredoc's backslash escapes `$`, backtick, backslash and a
    # newline, and is literal before anything else. Escaped text is text.
    if c == "\\" and i + 1 < len(body):
        nxt = body[i + 1]
        out.append(nxt if nxt in "$`\\\n" else c + nxt)
        i += 2
        continue
    if c == "`":
        sys.exit("an unescaped backtick in the stub heredoc: it runs as the stub "
                 "is written. That is the nine-minute CI hang, at line %d"
                 % (body[:i].count("\n") + 1))
    if c == "$":
        mm = re.match(r"\$\{?([A-Za-z_][A-Za-z0-9_]*|[0-9])\}?", body[i:])
        if not mm:
            sys.exit("an unescaped `$` the allowlist cannot name at line %d: %r"
                     % (body[:i].count("\n") + 1, body[i:i + 24]))
        name = mm.group(1)
        if name not in allowed:
            sys.exit("`$%s` expands as the stub is written and is not one of the "
                     "paths this heredoc is unquoted for (line %d). Escape it, or "
                     "add it to the allowlist in the stubwrite phase."
                     % (name, body[:i].count("\n") + 1))
        out.append(allowed[name])
        i += mm.end()
        continue
    out.append(c)
    i += 1

expected = "".join(out) + "\n"
written = open(os.environ["STUB_OUT"]).read()
if written != expected:
    import difflib
    diff = "".join(difflib.unified_diff(expected.splitlines(True),
                                        written.splitlines(True),
                                        "the heredoc body", "what reached the file"))
    sys.exit("text was consumed on the way to the stub:\n" + diff[:2000])
RECONSTRUCT
  ok "...and the written stub IS the heredoc body: nothing expanded that was not meant to"
  ;;

# -------------------------------------------------------------- await_threads
  await_threads)
  make_fixture
  plant_review "2026-09-10T10:00:00Z"
  plant_thread T_OPEN 0 "the open finding" "2026-09-10T10:00:01Z"
  plant_thread T_DONE 1 "the finding round one already fixed" "2026-09-10T10:00:01Z"
  await_it >"$WORK/out" 2>&1; rc=$?
  [ "$rc" = 0 ] || { cat "$WORK/out" >&2; fail "the wait did not end on a review (got $rc)"; }

  grep -qF "the open finding" "$WORK/out" \
    || { cat "$WORK/out" >&2; fail "the unresolved thread was not handed back"; }
  ok "an unresolved thread is handed back, with the comment that opened it"
  grep -qF "T_OPEN" "$WORK/out" \
    || fail "the thread id resolve-thread.sh takes is not in the output"
  ok "...and the id resolve-thread.sh takes, so nothing is looked up twice"

  # The whole point. A resolved thread is a finding already dealt with, and
  # handing it back is what made round two a re-read of round one.
  grep -qF "round one already fixed" "$WORK/out" \
    && { cat "$WORK/out" >&2; fail "a RESOLVED thread was handed back"; }
  ok "a resolved thread is not handed back at all"

  # Asked of the CALL LOG rather than of the output: the endpoint is what cannot
  # answer "is this resolved", so the fix is that it is never asked, not that
  # its answer is filtered afterwards.
  grep -qF "pulls/42/comments" "$GH_CALLS" \
    && fail "the wait still calls the endpoint that cannot report isResolved"
  ok "...and pulls/42/comments, which cannot report isResolved, is never called"
  ;;

# ---------------------------------------------------------------- await_quiet
  await_quiet)
  make_fixture
  plant_review "2026-09-10T10:00:00Z"
  plant_thread T_OPEN 0 "the open finding" "2026-09-10T10:00:01Z"
  await_it >"$WORK/round1" 2>&1 \
    || { cat "$WORK/round1" >&2; fail "round one did not end on a review"; }
  grep -qF "the open finding" "$WORK/round1" \
    || fail "round one did not hand the thread back, so round two proves nothing"

  # A SECOND review on the SAME head, which is what `review_requested` produces
  # -- otherwise the wait stops on "you have already seen this one" and never
  # reaches the threads at all.
  plant_review "2026-09-10T11:00:00Z"
  await_it >"$WORK/out" 2>&1; rc=$?
  [ "$rc" = 0 ] || { cat "$WORK/out" >&2; fail "round two did not end on the new review (got $rc)"; }

  grep -qF "the open finding" "$WORK/out" \
    && { cat "$WORK/out" >&2; fail "round two handed back a thread that has not moved"; }
  ok "a thread unchanged since the round that handed it back is not handed back again"

  # Not printing it is only half right: the thread is still open and still
  # blocks the merge, so something has to say where to find it. Asserted on the
  # sentence that BRANCH emits, not on `review-status.sh`, which the closing
  # prose prints unconditionally -- a grep for the script name matches on every
  # run that reaches exit 0 and so cannot fail. Found by round 2 of the
  # independent review.
  grep -qF "unresolved thread(s) not printed" "$WORK/out" \
    || { cat "$WORK/out" >&2; fail "the still-open thread was not counted"; }
  grep -qF "Every open thread, with its id:" "$WORK/out" \
    || fail "the count did not say where the rest is"
  ok "...and it is counted, with review-status.sh named beside the count"
  ;;

# ---------------------------------------------------------------- await_moved
  await_moved)
  make_fixture
  plant_review "2026-09-10T10:00:00Z"
  plant_thread T_OPEN 0 "the open finding" "2026-09-10T10:00:01Z"
  await_it >"$WORK/round1" 2>&1 \
    || { cat "$WORK/round1" >&2; fail "round one did not end on a review"; }

  # The agent replied and the reviewer answered: same thread, still unresolved,
  # newest comment newer than the round that handed it back. That is the case
  # the timestamp exists to keep -- suppressing it would be the old bug with the
  # sign flipped, and a live disagreement lost.
  plant_review "2026-09-10T11:00:00Z"
  plant_thread T_OPEN 0 "the open finding" "2026-09-10T11:00:01Z" \
    "not convinced -- the guard still fires on the empty case"
  await_it >"$WORK/out" 2>&1; rc=$?
  [ "$rc" = 0 ] || { cat "$WORK/out" >&2; fail "round two did not end on the new review (got $rc)"; }

  grep -qF "the guard still fires on the empty case" "$WORK/out" \
    || { cat "$WORK/out" >&2; fail "a thread that MOVED was not handed back"; }
  ok "a thread whose newest comment is newer than the last round is handed back"
  ;;

# ------------------------------------------------------------ await_own_reply
  await_own_reply)
  # The agent replying to a thread is not the thread MOVING. It is the loop this
  # script prints doing what it says -- "reply on the thread with the reason" --
  # and counting it as news hands the original finding straight back, with the
  # agent's own answer under it. That is round two re-reading round one by
  # another route, which is the whole defect this file is closing.
  #
  # `github` mode, because the distinction only exists there: in `local` mode the
  # reviewer and the PR author are ONE account (merge_gate.review_mode), nothing
  # in the payload can tell the two apart, and the wait prints the thread rather
  # than guessing -- showing a finding twice beats hiding one.
  make_fixture
  printf 'AUTOFLEET_REVIEW_MODE=github\n' >"$WORK/repo/.autofleet/config"
  plant_review "2026-09-10T10:00:00Z"
  plant_thread T_OPEN 0 "the open finding" "2026-09-10T10:00:01Z"
  await_it >"$WORK/round1" 2>&1 \
    || { cat "$WORK/round1" >&2; fail "round one did not end on a review"; }
  grep -qF "the open finding" "$WORK/round1" \
    || fail "round one did not hand the thread back, so round two proves nothing"

  plant_review "2026-09-10T11:00:00Z"
  plant_thread T_OPEN 0 "the open finding" "2026-09-10T11:00:01Z" \
    "disagree -- the guard already covers the empty case" armaatus
  await_it >"$WORK/out" 2>&1; rc=$?
  [ "$rc" = 0 ] || { cat "$WORK/out" >&2; fail "round two did not end on the new review (got $rc)"; }

  grep -qF "the open finding" "$WORK/out" \
    && { cat "$WORK/out" >&2; fail "the agent's own reply counted as the thread moving"; }
  ok "a thread whose newest comment is the agent's own reply has not moved"
  # The branch's own sentence, for the reason `await_quiet` gives.
  grep -qF "unresolved thread(s) not printed" "$WORK/out" \
    || { cat "$WORK/out" >&2; fail "the still-open thread was not counted"; }
  ok "...and it is still counted as open, with review-status.sh named beside it"
  ;;

# ------------------------------------------------------ await_own_reply_local
  await_own_reply_local)
  # The other half of `await_own_reply`, and the half this repo itself runs. In
  # `local` mode the reviewer and the PR author are ONE GitHub account
  # (merge_gate.review_mode), so an author-authored newest comment is as likely
  # to be the reviewer answering as the agent replying -- and the wait prints it
  # rather than guessing, because hiding a live finding is the worse of the two
  # mistakes. Without this row, deleting `local or` from `moved()` leaves every
  # other await phase green: they all plant `reviewer` as the replier, so the
  # author test is never the thing that decides.
  make_fixture
  plant_review "2026-09-10T10:00:00Z"
  plant_thread T_OPEN 0 "the open finding" "2026-09-10T10:00:01Z"
  await_it >"$WORK/round1" 2>&1 \
    || { cat "$WORK/round1" >&2; fail "round one did not end on a review"; }

  plant_review "2026-09-10T11:00:00Z"
  plant_thread T_OPEN 0 "the open finding" "2026-09-10T11:00:01Z" \
    "and here is the answer, from the account that is also the author" armaatus
  await_it >"$WORK/out" 2>&1; rc=$?
  [ "$rc" = 0 ] || { cat "$WORK/out" >&2; fail "round two did not end on the new review (got $rc)"; }

  grep -qF "from the account that is also the author" "$WORK/out" \
    || { cat "$WORK/out" >&2; fail "local mode suppressed a comment it cannot attribute"; }
  ok "in local mode an author-authored reply is handed back, not guessed at"
  ;;

# ------------------------------------------------------------------ await_cap
  await_cap)
  # The cap cuts BETWEEN timestamps, never inside one. GitHub stamps every
  # inline comment of a single submitted review with the same `createdAt`, so a
  # review leaving more than AWAIT_REVIEW_MAX_THREADS inline findings gives them
  # all ONE. Cut inside that run and every printed thread carries the oldest
  # withheld one's timestamp: the stamp cannot advance past it, the next round
  # computes the identical split, and the remainder is never handed back at all
  # -- `head -200`'s silent cut, moved one layer down and made permanent.
  #
  # Three threads in one instant against a cap of two, so the group can only be
  # printed whole or cut wrong. Found by round 2 of the independent review, on
  # the fix for the same defect one step earlier.
  make_fixture
  export AWAIT_REVIEW_MAX_THREADS=2
  plant_review "2026-09-10T10:00:00Z"
  plant_thread T_ONE   0 "the first finding"  "2026-09-10T10:00:01Z"
  plant_thread T_TWO   0 "the second finding" "2026-09-10T10:00:01Z"
  plant_thread T_THREE 0 "the third finding"  "2026-09-10T10:00:01Z"
  await_it >"$WORK/out" 2>&1; rc=$?
  [ "$rc" = 0 ] || { cat "$WORK/out" >&2; fail "the wait did not end on a review (got $rc)"; }

  for finding in "the first finding" "the second finding" "the third finding"; do
    grep -qF "$finding" "$WORK/out" \
      || { cat "$WORK/out" >&2
           fail "the cap cut inside one timestamp and lost: $finding"; }
  done
  ok "a tie group larger than the cap is printed whole rather than cut inside"

  # ...and the next round agrees there is nothing new, which is what says the
  # first round really handed all three back rather than merely printing them.
  plant_review "2026-09-10T11:00:00Z"
  await_it >"$WORK/round2" 2>&1; rc=$?
  [ "$rc" = 0 ] || { cat "$WORK/round2" >&2; fail "round two did not end on the new review (got $rc)"; }
  grep -qF "the first finding" "$WORK/round2" \
    && { cat "$WORK/round2" >&2; fail "round two re-read what round one handed back"; }
  ok "...and round two treats all three as already handed back"
  ;;


# --------------------------------------------------------------- scope_full
  scope_full)
  # ROUND ONE IS ALWAYS FULL, even with the knob turned on: there is no earlier
  # reviewed head to take a range from. The failure this guards is a range
  # against nothing -- `git diff ..HEAD` -- which resolves and is not the diff
  # anybody meant.
  make_fixture; stub_reviewer marked; make_origin
  export AUTOFLEET_REVIEW_SCOPE=delta
  run_it 42 >"$WORK/out" 2>&1; rc=$?
  [ "$rc" = 0 ] || { cat "$WORK/out" >&2; fail "round one did not submit (got $rc)"; }
  grep -q "scope: full" "$WORK/out" || { cat "$WORK/out" >&2; fail "round one did not say it read the whole branch"; }
  ok "round one is a full review and says so"
  prompt_has "gh pr diff 42" || fail "round one was not pointed at the whole diff"
  ok "...and is pointed at the whole diff"
  prompt_has "Previously reviewed at:" && fail "round one was handed a range anyway"
  ok "...and at no range, because there is no earlier head to range from"
  [ -e "$AUTOFLEET_DIR/reviews/pr-42-${PR_HEAD:0:8}.context.md" ] \
    && fail "round one wrote a carried-forward context with nothing to carry"
  ok "...and wrote no context file"
  ;;

# -------------------------------------------------------------- scope_delta
  scope_delta)
  # THE WHOLE POINT. Round two reads the delta since round one's head, and is
  # handed what round one found and how it was answered. Before this, round
  # thirteen of PR #32 read 2,633 changed lines and a 65 KB body to judge 39
  # lines in 2 files.
  make_fixture; stub_reviewer marked; make_origin
  first="$PR_HEAD"
  plant_round "$first" 2
  # An answer comment on that head, which is how `answer-review.sh` records what
  # was done about the findings.
  GH_COMMENTS="$WORK/comments"
  python3 - "$GH_COMMENTS" "$first" <<'XX'
import json, sys
json.dump([{"author": {"login": "armaatus"}, "createdAt": "2026-09-10T09:30:00Z",
            "body": f"<!-- review-answered {sys.argv[2]} -->\nFixed both: the line "
                    "number was stale and the file has been renamed."}],
          open(sys.argv[1], "w"))
XX
  export GH_COMMENTS
  advance_head second.txt hello
  export AUTOFLEET_REVIEW_SCOPE=delta
  run_it 42 >"$WORK/out" 2>&1; rc=$?
  [ "$rc" = 0 ] || { cat "$WORK/out" >&2; fail "round two did not submit (got $rc)"; }
  grep -q "scope: delta" "$WORK/out" || { cat "$WORK/out" >&2; fail "round two did not scope to the delta"; }
  ok "round two scopes to the delta and says so"
  prompt_has "git diff $first..$PR_HEAD" \
    || { cat "$PROMPT_FILE" >&2; fail "the reviewer was not given the range"; }
  ok "...and the range is <last reviewed head>..<head>"
  # The three clauses. A range alone is a strictly weaker review: a round-five
  # commit can break something round one approved and not appear in the delta.
  prompt_has "The surroundings of every change" || fail "clause 2 (the surroundings) is missing"
  prompt_has "roughly under 500 lines" \
    || fail "clause 2 is not size-aware, so a delta round reads more than the full diff it replaces"
  # THE CLAUSES NAME THE COMMIT. `Read` and `Grep` resolve against this
  # checkout, which is the repository root on the base branch -- the head under
  # review is not checked out anywhere, it is a fetched object. A clause saying
  # `Read <path>` hands the reviewer the BASE's copy with the delta's additions
  # absent and the hunk line numbers on unrelated code; a clause saying `Grep`
  # searches the base, so a caller this PR added is invisible and one it deleted
  # still appears -- inverting the case clause 3 exists for. Found by the
  # independent review.
  prompt_has "git show $PR_HEAD:" \
    || { cat "$PROMPT_FILE" >&2; fail "clause 2 reads the working tree, not the head under review"; }
  prompt_has "git grep -n <name> $PR_HEAD" \
    || { cat "$PROMPT_FILE" >&2; fail "clause 3 greps the working tree, not the head under review"; }
  ok "...and both name the head under review, not this checkout"
  grep -q 'Bash(git grep' "$ARGV_FILE" \
    || { cat "$ARGV_FILE" >&2; fail "clause 3 asks for git grep and the reviewer is not granted it"; }
  ok "...and the reviewer is granted the one tool those clauses need"
  prompt_has "whose CONTRACT the" || fail "clause 3 (the callers) is missing"
  ok "...and carries the two clauses that keep a narrower read from being a weaker one"

  ctx="$AUTOFLEET_DIR/reviews/pr-42-${PR_HEAD:0:8}.context.md"
  [ -s "$ctx" ] || fail "no carried-forward context file at $ctx"
  prompt_has "$ctx" || fail "the prompt does not name the context file"
  ok "...and the prompt names a FILE, not third-party text spliced into itself"
  # ...and the reviewer can actually open it. `$LOG_DIR` is outside the
  # repository root the reviewer runs from, and `--allowed-tools Read` grants
  # the tool, not the workspace: a headless `claude -p` denies a read outside
  # its directories rather than asking. Without the grant every delta round
  # named a path it could not open and said `scope: delta` regardless. Found by
  # the independent review.
  grep -qxF -- "--add-dir" "$ARGV_FILE"     || { cat "$ARGV_FILE" >&2; fail "the reviewer was not granted the directory the context file is in"; }
  grep -qxF -- "$AUTOFLEET_DIR/reviews" "$ARGV_FILE"     || { cat "$ARGV_FILE" >&2; fail "--add-dir does not name the log directory"; }
  ok "...and the reviewer is granted the directory that file is in"
  grep -q "It declared 2 findings" "$ctx" || { cat "$ctx" >&2; fail "the previous round's count was not carried"; }
  grep -q "PREVIOUS ROUND FINDING" "$ctx" || { cat "$ctx" >&2; fail "the previous round's findings were not carried"; }
  ok "...and the file carries what the last round found, by its declared count"
  grep -q "the line number was stale" "$ctx" || { cat "$ctx" >&2; fail "the answer was not carried"; }
  ok "...and how it was answered"
  # THE OLD TRAILERS COME OFF. `plant_round` writes a body ending in
  # `<!-- review-findings: N -->` and `<!-- independent-review: local <sha> -->`;
  # carried through verbatim, in front of a reviewer whose own last two lines
  # must be exactly those, an echoed stale sha makes `merge_gate` ignore the
  # review and the PR blocks on one that was submitted. The count survives as a
  # NUMBER, which is the honest form of it. Found by the independent review.
  grep -q "independent-review: local" "$ctx" \
    && { cat "$ctx" >&2; fail "the previous round's head marker was carried into the file the reviewer reads"; }
  grep -q "review-findings:" "$ctx" \
    && { cat "$ctx" >&2; fail "the previous round's findings trailer was carried verbatim"; }
  ok "...with the previous round's trailers stripped, so none can be echoed back"
  grep -q "touch second.txt" "$ctx" || { cat "$ctx" >&2; fail "the commits between the heads were not carried"; }
  ok "...and the commits that stood between the two heads"
  ;;

# ------------------------------------------------------------- scope_orphan
  scope_orphan)
  # A FORCE-PUSH ORPHANS THE LAST REVIEWED HEAD. `git diff <orphan>..<head>`
  # still resolves -- it just describes a range nobody worked in -- so the
  # ancestry test is the only thing between a delta review and a fiction.
  make_fixture; stub_reviewer marked; make_origin
  orphan="$(git -C "$WORK/repo" -c user.email=t@t -c user.name=t commit-tree \
              "$(git -C "$WORK/repo" rev-parse HEAD^{tree})" -m orphan)"
  plant_round "$orphan" 3
  advance_head second.txt hello
  export AUTOFLEET_REVIEW_SCOPE=delta
  run_it 42 >"$WORK/out" 2>&1; rc=$?
  [ "$rc" = 0 ] || { cat "$WORK/out" >&2; fail "the orphan case did not submit (got $rc)"; }
  grep -q "scope: full" "$WORK/out" || { cat "$WORK/out" >&2; fail "a review on an orphaned head was used as the range"; }
  ok "a reviewed head that is no longer an ancestor falls back to full"
  prompt_has "$orphan" && fail "the orphaned sha reached the reviewer anyway"
  ok "...and the orphaned sha never reaches the reviewer"
  ;;

# ---------------------------------------------------------------- scope_kth
  scope_kth)
  # EVERY Kth ROUND IS FULL, so no pull request is judged by an unbroken chain
  # of deltas. With AUTOFLEET_REVIEW_FULL_EVERY=2 the second round is the one.
  make_fixture; stub_reviewer silent; make_origin
  first="$PR_HEAD"
  plant_round "$first" 1
  advance_head a.txt one
  plant_round "$PR_HEAD" 1 "2026-09-10T09:10:00Z"
  advance_head b.txt two
  export AUTOFLEET_REVIEW_SCOPE=delta AUTOFLEET_REVIEW_FULL_EVERY=2
  run_it 42 >"$WORK/out" 2>&1; rc=$?
  [ "$rc" = 5 ] || { cat "$WORK/out" >&2; fail "the silent stub did not exit 5 (got $rc)"; }
  grep -q "scope: full" "$WORK/out" \
    || { cat "$WORK/out" >&2; fail "two rounds of review did not trip FULL_EVERY=2"; }
  ok "the Kth round reverts to a full review"
  # ...and the SAME ROUND COUNT with a wider K is a delta, which is what says K
  # decided. ONE variable changes between the two runs: the stub submits
  # nothing, so the head does not move and the derived count is 2 both times.
  # The earlier version of this row advanced the head AND widened K together,
  # so it established neither. Found by the independent review.
  export AUTOFLEET_REVIEW_FULL_EVERY=4
  run_it 42 >"$WORK/out2" 2>&1
  grep -q "scope: delta" "$WORK/out2" \
    || { cat "$WORK/out2" >&2; fail "the same round count with FULL_EVERY=4 was not a delta"; }
  ok "...and the same round count with a wider K is a delta, so K is what decided"
  ;;

# ----------------------------------------------------------------- cost_row
  cost_row)
  # PER-ROUND COST, which was not recoverable from anything on disk: the log
  # held the reviewer's final message and nothing else -- no tokens, no cost, no
  # turns -- so the issue about cost could not measure its own before and after.
  make_fixture; stub_reviewer json
  run_it 42 >"$WORK/out" 2>&1; rc=$?
  [ "$rc" = 0 ] || { cat "$WORK/out" >&2; fail "the json reviewer did not submit (got $rc)"; }
  log="$AUTOFLEET_DIR/reviews/pr-42-${PR_HEAD:0:8}.log"
  grep -q "3 findings" "$log" || { cat "$log" >&2; fail "the reviewer's own words did not survive"; }
  grep -q "total_cost_usd" "$log" && { cat "$log" >&2; fail "the raw JSON was left in the log a person reads"; }
  ok "the log keeps the reviewer's words and not the envelope"
  tsv="$AUTOFLEET_DIR/reviews/cost.tsv"
  [ -s "$tsv" ] || fail "no cost row at $tsv"
  grep -q "0.42" "$tsv" || { cat "$tsv" >&2; fail "the cost did not reach the row"; }
  grep -q "1000" "$tsv" || { cat "$tsv" >&2; fail "the input tokens did not reach the row"; }
  ok "...and one row per round carries the tokens, the cost and the turns"
  [ -e "$log.raw" ] && fail "the raw stdout was left behind"
  ok "...and the scratch streams are cleaned up"

  # AND IT DEGRADES. AUTOFLEET_REVIEW_CMD is a documented wrapper seam and a
  # wrapper need not honour --output-format; output that does not parse must
  # still reach a readable log, with no cost row invented for it.
  rows_before="$(grep -c . "$tsv")"
  stub_reviewer text
  advance_head_simple
  run_it 42 >"$WORK/out2" 2>&1; rc=$?
  [ "$rc" = 0 ] || { cat "$WORK/out2" >&2; fail "the text reviewer did not submit (got $rc)"; }
  log2="$AUTOFLEET_DIR/reviews/pr-42-${PR_HEAD:0:8}.log"
  grep -q "3 findings" "$log2" || { cat "$log2" >&2; fail "a non-JSON reviewer lost its log"; }
  ok "a reviewer that does not speak JSON still leaves a readable log"
  [ "$(grep -c . "$tsv")" = "$rows_before" ] \
    || { cat "$tsv" >&2; fail "a cost row was invented for output that carried no cost"; }
  ok "...and no cost row is invented for it"
  ;;


# ----------------------------------------------------------------- headroom
  headroom)
  # THE COMPRESSION SEAM in front of the model calls the fleet starts as a
  # direct child of its own scripts -- the reviewer here, and validate.sh and
  # self-review.sh through the same one writer in lib.sh, which
  # `evals/lint.sh` check 7b holds to all three. Every call this fleet makes
  # pays full price for its context and
  # nothing in the tree had ever tried a proxy in front of it -- so the seam is
  # opt-in, off by default, and the default has to be provably INERT. Which
  # means asserting an ABSENCE and not only a presence: a knob that is "off" by
  # setting two variables to nothing is not off, and no argv or prompt
  # assertion can see an environment variable either way. armaatus/autofleet#89.
  make_fixture; stub_reviewer marked
  unset AUTOFLEET_HEADROOM AUTOFLEET_HEADROOM_URL
  # ...AND THE TWO VARIABLES THEMSELVES, because this phase asserts an ABSENCE
  # and `run_it` hands review.sh the caller's whole environment. The page this
  # change adds tells a maintainer to run `headroom wrap claude`, which exports
  # ANTHROPIC_BASE_URL for their `claude` -- and the agent that then runs
  # `./tests/run.sh` inherits it. Without this the suite goes red for everybody
  # who followed the docs, reporting a leak the seam did not cause. Found by the
  # self-review.
  unset ANTHROPIC_BASE_URL ENABLE_TOOL_SEARCH
  run_it 42 >"$WORK/out" 2>&1; rc=$?
  [ "$rc" = 0 ] || { cat "$WORK/out" >&2; fail "the unconfigured review did not submit (got $rc)"; }
  [ -s "$ENV_FILE" ] \
    && { cat "$ENV_FILE" >&2; fail "an unconfigured repo put a compression variable in the reviewer's environment"; }
  ok "the knob unset leaves the reviewer's environment exactly as it was"
  grep -qiE 'headroom|ANTHROPIC_BASE_URL|compress' "$WORK/out" \
    && { cat "$WORK/out" >&2; fail "an unconfigured repo printed something about a proxy"; }
  ok "...and says nothing about a proxy it was not asked to use"

  # ...AND IT LEAVES AN OPERATOR'S OWN BASE URL ALONE. The row above clears both
  # variables first, which is right for asserting an absence and wrong for
  # asserting inertness: "off" has to mean the seam does not touch the
  # environment, not that the environment happened to be empty. Somebody with a
  # company gateway in ANTHROPIC_BASE_URL and no knob set must reach the
  # reviewer with it. Found by the self-review.
  advance_head_simple
  ANTHROPIC_BASE_URL="https://gateway.invalid" ENABLE_TOOL_SEARCH=false \
    run_it 42 >"$WORK/out1b" 2>&1; rc=$?
  [ "$rc" = 0 ] || { cat "$WORK/out1b" >&2; fail "the review did not submit (got $rc)"; }
  grep -qxF "ANTHROPIC_BASE_URL=https://gateway.invalid" "$ENV_FILE" \
    || { cat "$ENV_FILE" >&2; fail "an unconfigured repo changed a base URL the operator set"; }
  grep -qxF "ENABLE_TOOL_SEARCH=false" "$ENV_FILE" \
    || { cat "$ENV_FILE" >&2; fail "an unconfigured repo changed ENABLE_TOOL_SEARCH"; }
  ok "...and passes an operator's own values through untouched"
  unset ANTHROPIC_BASE_URL ENABLE_TOOL_SEARCH

  # ON, AND SOMETHING ANSWERS -> both variables reach the reviewer, and the base
  # URL is the one the knob names rather than a default compiled in here.
  # ENABLE_TOOL_SEARCH goes with it because `/context all` misreports without
  # it, which is a cost of the custom base URL and not a second feature.
  stub_proxy
  export AUTOFLEET_HEADROOM=1
  export AUTOFLEET_HEADROOM_URL="$PROXY_URL"
  advance_head_simple
  run_it 42 >"$WORK/out2" 2>&1; rc=$?
  [ "$rc" = 0 ] || { cat "$WORK/out2" >&2; fail "the wrapped review did not submit (got $rc)"; }
  grep -qxF "ANTHROPIC_BASE_URL=$PROXY_URL" "$ENV_FILE" \
    || { cat "$ENV_FILE" >&2; fail "the reviewer was not pointed at the proxy"; }
  grep -qxF "ENABLE_TOOL_SEARCH=true" "$ENV_FILE" \
    || { cat "$ENV_FILE" >&2; fail "ENABLE_TOOL_SEARCH did not reach the reviewer"; }
  ok "the knob on, with a listener, puts both variables in the reviewer's environment"

  # ON, AND NOTHING ANSWERS -> THE REVIEW STILL RUNS. A dispatcher that refuses
  # to dispatch because an optional optimiser is down is a worse failure than
  # paying full token price for one pass. This is the row that would have been
  # red before the change, and the one that goes quietly wrong later: a probe
  # that becomes a prerequisite turns a stopped proxy into a stopped fleet.
  #
  # The line it prints names BOTH the URL and the knob, because the person
  # reading a dispatcher log has to be able to find the thing that is off
  # without knowing this file, or scripts/fleet/lib.sh, exists.
  kill_proxy
  before="$(n_started)"
  advance_head_simple
  run_it 42 >"$WORK/out3" 2>&1; rc=$?
  [ "$rc" = 0 ] || { cat "$WORK/out3" >&2; fail "an unreachable proxy stopped the review (got $rc)"; }
  [ "$(n_started)" -gt "$before" ] \
    || { cat "$WORK/out3" >&2; fail "no reviewer was started at all"; }
  ok "an unreachable proxy does not stop the review"
  grep -qF "$AUTOFLEET_HEADROOM_URL" "$WORK/out3" \
    || { cat "$WORK/out3" >&2; fail "the degrade line does not name the URL"; }
  grep -qF "AUTOFLEET_HEADROOM" "$WORK/out3" \
    || { cat "$WORK/out3" >&2; fail "the degrade line does not name the knob"; }
  ok "...and the line it prints names both the URL and the knob"
  [ -s "$ENV_FILE" ] \
    && { cat "$ENV_FILE" >&2; fail "the reviewer was pointed at a proxy that is not there"; }
  ok "...and the reviewer is not pointed at a proxy that is not there"
  unset AUTOFLEET_HEADROOM AUTOFLEET_HEADROOM_URL

  # A SECOND CALL IN ONE PROCESS, with the proxy gone between the two.
  # `self-review.sh` calls this once per pass and runs two passes minutes apart,
  # against a daemon the fleet deliberately does not own -- so "up for pass one,
  # gone for pass two" is an ordinary Tuesday. A degrade branch that only
  # PRINTED left pass one's exports in place: the line said "running unwrapped"
  # while the pass was still pointed at a dead endpoint and failed its model
  # call outright. The one failure the seam exists to prevent, arriving through
  # the seam. Found by both self-review passes.
  #
  # Against the function rather than through a third fixture: the bug is in the
  # branch, the branch has one writer, and two more copies of a reviewer stub
  # would assert the same line three times.
  stub_proxy
  # The same script twice, once clearing the inherited variables and once
  # keeping them: the first asks what the seam SETS, the second what it gives
  # back. Building it from one string keeps the two steps -- probe, kill, probe
  # -- from drifting apart.
  inner_body='. ./scripts/fleet/lib.sh
fleet_headroom_env
printf "one=%s\n" "${ANTHROPIC_BASE_URL+set:$ANTHROPIC_BASE_URL}"
kill -9 "$1" 2>/dev/null
i=0
while fleet_headroom_up "$AUTOFLEET_HEADROOM_URL" && [ "$i" -lt 200 ]; do
  sleep 0.05; i=$((i + 1))
done
fleet_headroom_env
printf "two=%s\n" "${ANTHROPIC_BASE_URL+set:$ANTHROPIC_BASE_URL}"
printf "search=%s\n" "${ENABLE_TOOL_SEARCH+set:$ENABLE_TOOL_SEARCH}"'
  # CLEARED, for the reason the top of this phase clears them: the suite may be
  # running under an agent that followed docs/CONFIGURATION.md and wrapped its
  # own `claude`, and this half asks what the seam SETS from nothing.
  inner="unset ANTHROPIC_BASE_URL ENABLE_TOOL_SEARCH
$inner_body"
  # ...and KEPT, for the half that asks what it gives back.
  inner_keep="$inner_body"
  out="$( cd "$WORK/repo" \
          && REPO_ROOT="$WORK/repo" AUTOFLEET_HEADROOM=1 \
             AUTOFLEET_HEADROOM_URL="$PROXY_URL" \
             bash -c "$inner" _ "$PROXY_PID" 2>&1 )"
  PROXY_PID=""
  grep -qxF "one=set:$PROXY_URL" <<<"$out" \
    || fail "the first call did not point at the proxy: $out"
  # `two=` and NOT `two=unset`: the recording is `${VAR+set:$VAR}`, so an empty
  # line means genuinely unset and `two=set:` would mean exported-empty -- which
  # is the breakage lib.sh says it avoids and which a `:-unset` reading would
  # have called a pass. Found by the self-review.
  grep -qxF "two=" <<<"$out" \
    || fail "the degrade left ANTHROPIC_BASE_URL set, possibly to nothing: $out"
  grep -qxF "search=" <<<"$out" \
    || fail "the degrade left ENABLE_TOOL_SEARCH set, possibly to nothing: $out"
  ok "a proxy that dies between two calls takes both exports with it"
  grep -qF "AUTOFLEET_HEADROOM" <<<"$out" \
    || fail "the second call degraded silently: $out"
  ok "...and says so, rather than leaving the log claiming a wrap that is gone"

  # AN OPERATOR'S OWN BASE URL COMES BACK. Somebody who points
  # ANTHROPIC_BASE_URL at a company gateway and then turns the knob on had it
  # replaced by the proxy on the first call; a degrade that merely UNSET it sent
  # the next pass straight at Anthropic, past the gateway, where it can fail
  # auth -- and lib.sh claimed it left the operator alone. Found by both
  # self-review passes.
  stub_proxy
  out="$( cd "$WORK/repo" \
          && REPO_ROOT="$WORK/repo" AUTOFLEET_HEADROOM=1 \
             AUTOFLEET_HEADROOM_URL="$PROXY_URL" \
             ANTHROPIC_BASE_URL="https://gateway.invalid" \
             bash -c "$inner_keep" _ "$PROXY_PID" 2>&1 )"
  PROXY_PID=""
  grep -qxF "one=set:$PROXY_URL" <<<"$out" \
    || fail "the first call did not take the proxy over the operator value: $out"
  grep -qxF "two=set:https://gateway.invalid" <<<"$out" \
    || fail "the degrade threw away a base URL the operator set, rather than putting it back: $out"
  ok "...and a base URL the operator set themselves comes back, rather than vanishing"

  # A URL WITH NO SCHEME reads as unreachable rather than as 127.0.0.1:80.
  # `urlsplit("localhost:8787")` has no hostname, and a fallback pair turned
  # that typo -- and an empty AUTOFLEET_HEADROOM_URL, which survives config.sh's
  # `:=` -- into a probe of whatever is on port 80. Anything answering there
  # made `status` say "answering" and exported the malformed string to every
  # model call the fleet starts.
  #
  # THE POSITIVE CONTROL FIRST, and it is the whole reason these three lines are
  # in this order. `( . lib.sh && fleet_headroom_up X ) && fail` is satisfied by
  # ANY non-zero exit -- lib.sh failing to source, the function not existing,
  # python3 missing -- so on its own it was green before the fix too, which is
  # not a test. The live URL going through the same subshell is what proves the
  # subshell works, so the two refusals below mean the URL and not the harness.
  # Found by the self-review.
  stub_proxy
  probe() { ( cd "$WORK/repo" && . ./scripts/fleet/lib.sh && fleet_headroom_up "$1" ); }
  probe "$PROXY_URL" \
    || fail "the probe could not reach a listener that is there, so the refusals below prove nothing"
  probe "localhost:8787" \
    && fail "a URL with no scheme was probed as something reachable"
  probe "" \
    && fail "an empty URL was probed as something reachable"
  # THE ROW THAT IS RED WITHOUT THE FIX, and it has to be this shape. The
  # original bug was `host = u.hostname or "127.0.0.1"` turning a scheme-less
  # URL into a probe of port 80 -- which a fixture cannot reproduce, because
  # binding 80 needs root, so a no-scheme assertion is green either way. A
  # scheme that is not http or https is the same bug reachable from user space:
  # the old code took the hostname and port it parsed and connected, so a LIVE
  # listener behind `ftp://` answered and the malformed string was exported as
  # ANTHROPIC_BASE_URL. This points at the stub, which IS listening.
  probe "ftp://127.0.0.1:${PROXY_URL##*:}" \
    && fail "a non-HTTP scheme was probed as a usable proxy, and would have been exported as one"
  kill_proxy
  ok "a live URL is reachable; no scheme, no host, and a scheme that is not HTTP are not"

  # THE TOGGLE TAKES TWO VALUES AND REFUSES THE REST, LOUDLY. `fleet_headroom_on`
  # tests the literal `1`, and the two knobs above this one in config.sh take
  # `on`/`off` -- so `AUTOFLEET_HEADROOM=on` is the spelling somebody writes, and
  # before the check it read as OFF: every review paid full token price, `status`
  # said "off", and nothing named the typo. An empty value reaches the same place
  # for the reason the section is written against -- config.sh's `:=` default
  # runs BEFORE the host config is sourced, so `AUTOFLEET_HEADROOM=` survives.
  #
  # FATAL rather than a warning, and that is deliberate: this file is sourced by
  # lib.sh, so the exit takes every fleet command with it, and the message names
  # the knob, the value and the page. A knob whose wrong value is
  # indistinguishable from its default cannot be fixed by a line in a log.
  for bad in on true yes 2; do
    out="$( cd "$WORK/repo" && AUTOFLEET_HEADROOM="$bad" \
            bash -c '. ./scripts/fleet/config.sh' 2>&1 )"; rc=$?
    [ "$rc" = 2 ] \
      || fail "AUTOFLEET_HEADROOM='$bad' was accepted (exit $rc), so a typo reads as off"
    grep -qF "AUTOFLEET_HEADROOM" <<<"$out" \
      || fail "the refusal for '$bad' does not name the knob: $out"
  done
  ok "a compression knob that is neither 0 nor 1 stops the fleet and names itself"

  # THE EMPTY VALUE, AND IT HAS TO COME THROUGH THE HOST CONFIG. From the
  # ENVIRONMENT an empty value never reaches the check: `:=` substitutes on
  # unset OR NULL, so `AUTOFLEET_HEADROOM= fleet.sh` is handed the default and is
  # genuinely off. A half-edited `.autofleet/config` is the live case, and it is
  # sourced AFTER the defaults, so the empty string survives all the way to
  # `fleet_headroom_on` -- which reads it as off, with a line in the file saying
  # otherwise. The same shape as the AUTOFLEET_REVIEW_MAX_ROUNDS check above it.
  printf 'AUTOFLEET_REVIEW_MODE=local\nAUTOFLEET_HEADROOM=\n' \
    >"$WORK/repo/.autofleet/config"
  # REPO_ROOT, because that is what config.sh resolves `.autofleet/config`
  # against -- without it the file is looked for at `/.autofleet/config`, the
  # host config is never read, and the phase passes having tested nothing.
  out="$( cd "$WORK/repo" && REPO_ROOT="$WORK/repo" \
          bash -c '. ./scripts/fleet/config.sh' 2>&1 )"; rc=$?
  [ "$rc" = 2 ] \
    || fail "a half-edited '.autofleet/config' line was accepted (exit $rc): $out"
  grep -qF "AUTOFLEET_HEADROOM" <<<"$out" \
    || fail "the refusal does not name the knob: $out"
  ok "...including an empty line in .autofleet/config, which the default cannot fill"
  printf 'AUTOFLEET_REVIEW_MODE=local\n' >"$WORK/repo/.autofleet/config"
  for good in 0 1; do
    ( cd "$WORK/repo" && AUTOFLEET_HEADROOM="$good" bash -c '. ./scripts/fleet/config.sh' ) \
      || fail "AUTOFLEET_HEADROOM=$good was refused"
  done
  ok "...and both legal values are taken"
  ;;

# ---------------------------------------------------------- headroom_status
  headroom_status)
  # WHICH STATE IT IS IN, on the first screen anybody looks at -- the same place
  # and for the same reason `review:` is there. A seam whose whole point is that
  # it changes nothing when off is a seam nobody can tell is on, and "is the
  # proxy up" is not answerable from a dispatcher that never says.
  make_fixture; stub_reviewer marked
  unset AUTOFLEET_HEADROOM AUTOFLEET_HEADROOM_URL
  # One spelling of "source fleet.sh and run the screen", because three copies is
  # two too many and the copies are what let an assertion read a stale one.
  status_out() { ( cd "$WORK/repo" && . ./scripts/fleet/fleet.sh && cmd_status 2>&1 ); }
  out="$(status_out)"
  grep -qi "headroom:.*off" <<<"$out" \
    || fail "status does not say the compression seam is off: $out"
  ok "status names the seam and says it is off"

  # ON AND ANSWERING. The probe on this screen is the same one the review path
  # makes, which is the point: a screen that reported the KNOB rather than the
  # endpoint would say "on" for a proxy that has been dead since Tuesday.
  stub_proxy
  export AUTOFLEET_HEADROOM=1
  export AUTOFLEET_HEADROOM_URL="$PROXY_URL"
  out="$(status_out)"
  grep -qF "$PROXY_URL" <<<"$out" || fail "status does not name the URL: $out"
  grep -qi "answering" <<<"$out" || fail "status does not say the proxy answers: $out"
  grep -qi "NOT ANSWERING" <<<"$out" \
    && fail "status called a live proxy dead: $out"
  ok "...and on, with a listener, names the URL and says it answers"

  kill_proxy
  out="$(status_out)"
  grep -qi "NOT ANSWERING" <<<"$out" \
    || fail "status did not notice the proxy is gone: $out"
  grep -qi "unwrapped" <<<"$out" \
    || fail "status does not say what happens instead: $out"
  ok "...and on, with nothing there, says so and says what happens instead"
  unset AUTOFLEET_HEADROOM AUTOFLEET_HEADROOM_URL
  ;;


# ------------------------------------------------------------ scope_noplaceholder
  scope_noplaceholder)
  # THE PLACEHOLDER `$log` IS WRITTEN BEFORE THE FETCH, so a run that never
  # reaches a reviewer must take it back. Left, it is a transcript by
  # `prune_review_logs`'s reckoning -- one line saying a reviewer is running,
  # naming two stream files that were never created. The `stopped` path is the
  # one that reaches it deterministically: `review.sh` writes the placeholder,
  # then finds the stop file on its next look. Found by the independent review.
  make_fixture; stub_reviewer marked
  # Not on PATH, so the run exits 6 after the log path is decided.
  export AUTOFLEET_REVIEW_CMD=no-such-reviewer-anywhere
  run_it 42 >"$WORK/out" 2>&1; rc=$?
  [ "$rc" = 6 ] || { cat "$WORK/out" >&2; fail "a missing reviewer command did not exit 6 (got $rc)"; }
  [ -e "$AUTOFLEET_DIR/reviews/pr-42-${PR_HEAD:0:8}.log" ] \
    && fail "a run that never started a reviewer left a placeholder transcript behind"
  ok "a run that never reaches a reviewer leaves no placeholder transcript"
  # ...while a run that DID start one keeps its log, which is the half that
  # matters: the placeholder exists so `$log` is there for the whole run.
  stub_reviewer text
  run_it 42 >"$WORK/out2" 2>&1
  [ -s "$AUTOFLEET_DIR/reviews/pr-42-${PR_HEAD:0:8}.log" ] \
    || fail "the cleanup took a real transcript"
  ok "...while a run that started one keeps its transcript"
  ;;

# -------------------------------------------------------------- scope_nofetch
  scope_nofetch)
  # THE FETCH IS WHAT MAKES A RANGE RESOLVE, and it is one network round trip
  # against a repository this machine does not always reach. It must cost the
  # delta and not the review: a round that cannot fetch reads the whole branch,
  # like every round did before this existed, and says so.
  #
  # No `make_origin`, so `git fetch origin` has no remote to reach -- which is
  # the same failure as a network that is down, arriving faster.
  make_fixture; stub_reviewer marked
  first="$PR_HEAD"
  plant_round "$first" 2
  git -C "$WORK/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m next
  PR_HEAD="$(git -C "$WORK/repo" rev-parse HEAD)"
  printf '%s' "$PR_HEAD" >"$GH_HEAD"
  export AUTOFLEET_REVIEW_SCOPE=delta
  run_it 42 >"$WORK/out" 2>&1; rc=$?
  [ "$rc" = 0 ] || { cat "$WORK/out" >&2; fail "a failed fetch cost the review, not just the delta (got $rc)"; }
  ok "a round whose fetch fails still submits"
  grep -q "scope: full" "$WORK/out" \
    || { cat "$WORK/out" >&2; fail "it handed out a range it had not fetched the objects for"; }
  ok "...and falls back to a full review"
  prompt_has "Previously reviewed at:" \
    && { cat "$PROMPT_FILE" >&2; fail "the reviewer was given a range anyway"; }
  ok "...and the reviewer is told to read the whole diff, as it always was"
  ;;

# -------------------------------------------------------------- scope_ctxcap
  scope_ctxcap)
  # THE CAP ON THE CARRIED-FORWARD FILE. The whole complaint this answers is a
  # prompt that grows with the rounds; an uncapped context file is that growth
  # wearing a different hat, and the previous round's body is written by an
  # agent with no length budget of its own.
  make_fixture; stub_reviewer marked; make_origin
  first="$PR_HEAD"
  python3 - "$GH_REVIEWS" "$first" <<'XX'
import json, sys
path, oid = sys.argv[1], sys.argv[2]
records = json.load(open(path))
records.append({"commit_id": oid, "user": "armaatus",
                "submitted_at": "2026-09-10T09:00:00Z",
                "body": "PADDING " * 4000 + "\n<!-- review-findings: 1 -->\n"
                        f"<!-- independent-review: local {oid} -->"})
json.dump(records, open(path, "w"))
XX
  advance_head second.txt hello
  export AUTOFLEET_REVIEW_SCOPE=delta AUTOFLEET_REVIEW_CONTEXT_MAX=2048
  run_it 42 >"$WORK/out" 2>&1; rc=$?
  [ "$rc" = 0 ] || { cat "$WORK/out" >&2; fail "the run did not submit (got $rc)"; }
  ctx="$AUTOFLEET_DIR/reviews/pr-42-${PR_HEAD:0:8}.context.md"
  [ -s "$ctx" ] || fail "no context file at $ctx"
  size="$(wc -c <"$ctx" | tr -d ' ')"
  # The whole-file cap plus the truncation note it appends, and nothing like the
  # 32 KB body it was handed.
  [ "$size" -lt 2400 ] \
    || { fail "the context file is ${size} bytes against a 2048-byte cap"; }
  ok "a review body far over the cap produces a context file inside it (${size}B)"
  grep -q "truncated at AUTOFLEET_REVIEW_CONTEXT_MAX" "$ctx" \
    || { fail "it was cut without saying so, so a reviewer cannot tell a short round from a clipped one"; }
  ok "...and says it was cut, rather than looking like a short round"
  # The MECHANICAL sections survive the clip: the per-section share is what
  # stops one enormous body pushing the commits out of the file entirely.
  grep -q "touch second.txt" "$ctx" \
    || { cat "$ctx" >&2; fail "the commits were pushed out of the file by the padded body"; }
  ok "...while the commits between the heads still survive it"

  # `0` IS "CARRY NOTHING", not "carry a truncation notice". The prompt tells
  # the reviewer the file holds what the last round found; at 0 the file held
  # one line saying it had been cut. Found by the independent review.
  advance_head third.txt again
  export AUTOFLEET_REVIEW_CONTEXT_MAX=0
  run_it 42 >"$WORK/out0" 2>&1
  [ -e "$AUTOFLEET_DIR/reviews/pr-42-${PR_HEAD:0:8}.context.md" ] \
    && fail "a cap of 0 still wrote a context file"
  ok "a cap of 0 writes no context file at all"
  prompt_has "Carried forward:" \
    && { cat "$PROMPT_FILE" >&2; fail "the prompt still told the reviewer to read a file that does not exist"; }
  ok "...and the prompt does not name one"
  prompt_has "Previously reviewed at:" \
    || { cat "$PROMPT_FILE" >&2; fail "the range went with it; 0 caps the context, not the scope"; }
  ok "...while the range is still handed over, because 0 caps the context and not the scope"
  ;;

# ------------------------------------------------------------ scope_ctxbroken
  scope_ctxbroken)
  # A CONTEXT BUILD THAT CANNOT RUN must not report `delta`. The python that
  # writes the findings, the answer and the threads imports from `merge_gate.py`
  # -- a file agents in this repository edit, which is why `counting_review`
  # wraps its own import in a `try`. This block is `>"$ctx" 2>/dev/null` in a
  # script with no `-e`, so a raise left the file holding the header and the
  # commit list, printed `scope: delta`, and said nothing: a narrower read that
  # really was a weaker read. Found by the independent review.
  make_fixture; stub_reviewer marked; make_origin
  first="$PR_HEAD"
  plant_round "$first" 2
  advance_head second.txt hello
  # The one failure mode the comment above names, reproduced the way it happens:
  # merge_gate.py does not import.
  printf 'def broken(:
' >>"$WORK/repo/.github/scripts/merge_gate.py"
  export AUTOFLEET_REVIEW_SCOPE=delta
  run_it 42 >"$WORK/out" 2>&1; rc=$?
  # Exit 2 is also acceptable here -- `counting_review` refuses a gate it cannot
  # load, which is the older and stronger guard. What must NOT happen is a run
  # that reports `delta` while carrying nothing.
  grep -q "scope: delta" "$WORK/out" \
    && { cat "$WORK/out" >&2; fail "it reported a delta review whose carried context could not be built"; }
  ok "a context build that cannot run does not report a delta review (exit $rc)"
  ;;

# ------------------------------------------------------------- status_rounds
  status_rounds)
  # TWO THINGS #91 left. The count it keeps is invisible -- `fleet.sh status` is
  # the first screen anybody looks at and a PR quietly on its fourth round does
  # not appear on it -- and the count itself undercounts, by its own comment:
  # three kinds of review it cannot see, each a real review a real PR had.
  make_fixture; stub_reviewer marked; make_origin
  # The knob is AUTOFLEET_REVIEW_MAX, and set to 4 here rather than left at the
  # shipped 1: at a cap of one there is no "below the cap" to show, so the
  # phase could not tell a screen that names the cap from one that names it
  # always. The number is the old default on purpose -- it is what this phase
  # measured while reviews were the thing being counted.
  export AUTOFLEET_REVIEW_MAX=4
  mkdir -p "$AUTOFLEET_DIR/reviewing"
  printf '4\n' >"$AUTOFLEET_DIR/reviewing/42.rounds"
  printf '2\n' >"$AUTOFLEET_DIR/reviewing/43.rounds"
  # A VALIDATOR'S RECORD, in the same directory, which is the shape that made
  # this screen print `PR #v-44` at the reviewer's cap.
  printf '2\n' >"$AUTOFLEET_DIR/reviewing/v-44.rounds"
  out="$( cd "$WORK/repo" && . ./scripts/fleet/fleet.sh && cmd_status 2>&1 )"
  grep -q "PR #42: 4/4 reviews" <<<"$out" \
    || fail "fleet.sh status does not show the review count: $out"
  grep -q "AT THE CAP" <<<"$out" || fail "status does not say PR #42 is held: $out"
  ok "fleet.sh status shows each PR's review count and names the cap"
  grep -q "PR #43: 2/4 reviews" <<<"$out" \
    || fail "status showed only the capped PR: $out"
  grep -q "#43.*AT THE CAP" <<<"$out" \
    && fail "a PR below the cap was reported as held: $out"
  ok "...and a PR below it is shown without the hold"
  grep -q "PR #v-44" <<<"$out" \
    && fail "a validator's record was printed as a pull request number: $out"
  grep -q "PR #44: 2/2 validations -- AT THE CAP" <<<"$out" \
    || fail "the validator's count is not shown against its own cap: $out"
  ok "...and a validation count is its own line, at its own cap"
  # `.rounds` is a RECORD, not a lock. Counted as a reviewer it would read as a
  # slot taken for as long as the PR is open -- the exact miscount `.done`,
  # `.tries` and `.said` each caused in turn.
  grep -q "0 in flight" <<<"$out" \
    || fail "the round record was counted as a reviewer in flight: $out"
  ok "...while counting as a record and not as a reviewer in flight"

  # THE UNDERCOUNT. `.rounds` says 1; the pull request carries counting reviews
  # on three distinct heads, none of which this fleet's increment saw. The round
  # recorded after this run must be 4, not 2.
  rm -f "$AUTOFLEET_DIR/reviewing"/*
  export AUTOFLEET_REVIEW_MARKER="$AUTOFLEET_DIR/reviewing/42"
  printf '1\n' >"$AUTOFLEET_REVIEW_MARKER.rounds"
  first="$PR_HEAD"
  plant_round "$first" 1
  advance_head a.txt one
  plant_round "$PR_HEAD" 1 "2026-09-10T09:10:00Z"
  advance_head b.txt two
  plant_round "$PR_HEAD" 1 "2026-09-10T09:20:00Z"
  advance_head c.txt three
  run_it 42 >"$WORK/out" 2>&1; rc=$?
  [ "$rc" = 0 ] || { cat "$WORK/out" >&2; fail "the run did not submit (got $rc)"; }
  got="$(cat "$AUTOFLEET_REVIEW_MARKER.rounds")"
  [ "$got" = 4 ] \
    || fail "the round count is $got: the three reviews this fleet did not submit are still invisible to the cap"
  ok "a round count below what the PR actually carries is corrected upward"
  grep -q "round 4" "$WORK/out" \
    || { cat "$WORK/out" >&2; fail "the reviewer was told the wrong round"; }
  ok "...and the reviewer is told the corrected round, which its late-round rule keys on"

  # ...and NEVER downward. A force-push that orphans every earlier review drops
  # the derived count to zero; a cap that went backwards there would reopen the
  # loop it had just closed.
  printf '9\n' >"$AUTOFLEET_REVIEW_MARKER.rounds"
  advance_head d.txt four
  run_it 42 >"$WORK/out2" 2>&1
  got="$(cat "$AUTOFLEET_REVIEW_MARKER.rounds")"
  [ "$got" = 10 ] \
    || fail "the count went to $got, so a PR gets rounds it has already spent"
  ok "...and never downward, whatever the pull request has lost"
  ;;

  *)
  echo "usage: $0 mode|refuses|stopped|submits|unmarked|silent|skips|stale|midstop|reaper|timeout|sweeps|queue|records|status_count|holds|once|rounds|roundcap|retries|capped|stubwrite|await_threads|await_quiet|await_moved|await_own_reply|await_own_reply_local|await_cap|scope_full|scope_delta|scope_orphan|scope_kth|scope_noplaceholder|scope_nofetch|scope_ctxcap|scope_ctxbroken|status_rounds|cost_row|headroom|headroom_status" >&2
  exit 2 ;;
esac
