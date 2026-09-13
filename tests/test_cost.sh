#!/usr/bin/env bash
# Covers scripts/fleet/cost.sh -- what a worktree run cost, read back out of the
# agent CLI's own session transcripts.
#
#   test_cost.sh sums        the four figures and the session count, from a
#                            fixture transcript directory. The fixture carries
#                            every shape the reader has to survive: one assistant
#                            message written as TWO entries with the same
#                            `message.id` (which is what the CLI actually does,
#                            and what makes a naive sum report double), an entry
#                            with no `usage`, a non-assistant entry, a
#                            half-written last line, and a SUBAGENT transcript a
#                            directory deeper -- which this repo mandates four of
#                            per issue and which a top-level-only read drops.
#   test_cost.sh json        --json prints the same figures, as integers.
#   test_cost.sh empty       an empty AUTOFLEET_TRANSCRIPT_DIR is one explanatory
#                            line and exit 0, and NO table: a table of zeros is a
#                            measurement, and nothing was measured.
#   test_cost.sh attempts    an issue that ran in two worktrees (`fleet.sh retry`)
#                            has both counted, not just the last one recorded.
#   test_cost.sh long_path   a worktree path past the CLI slug cap is found by
#                            its truncated prefix. Nothing exercised that branch,
#                            and wrong it reports zeros rather than an error.
#   test_cost.sh filtered    an issue filter that matches nothing says WHICH
#                            issue it could not find and prints no table. "The
#                            fleet has run nothing" is false with three other
#                            issues recorded, and a total row of zeros is a
#                            measurement of a fleet that spent nothing.
#   test_cost.sh reaped      a recorded worktree whose transcripts are gone is
#                            named once and exits 0. A reporting command must
#                            never be the thing that fails a run.
#   test_cost.sh subcommand  `fleet.sh cost` reaches cost.sh ON A MACHINE WITH NO
#                            RUNNER. Wired wrong, every assertion above passes
#                            against a command nobody can invoke -- and the
#                            runner is the specific way it was wrong: fleet.sh
#                            probes for one at SOURCE time and dies, so `cost`
#                            answered "the orca runner is not usable here" on
#                            every machine without a runtime. That is a CI
#                            runner, and a laptop with the app shut, and the
#                            laptop is where somebody asks what last night cost.
#                            The stub driver below makes the phase assert that
#                            on a machine where the real runtime WOULD answer.
#
# The fleet state dir and the transcript root are both temp dirs, so nothing here
# reads this machine's own fleet or its own transcripts.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; return 0; }
trap cleanup EXIT

# The CLI's own naming: a transcript directory is the absolute working directory
# with every NON-ALPHANUMERIC character turned into `-`. Spelled out here rather
# than shared with the script under test, so a change to either side has to be
# made twice and deliberately -- a helper both call would agree with itself
# while agreeing with nothing the CLI writes.
#
# `tr -c`, and the fixture paths below carry an `_` ON PURPOSE. This said
# `tr '/.' '--'` while cost.sh said every non-alphanumeric, and the two agree on
# any path made only of letters, digits, `/`, `.` and `-` -- so the widening had
# NO TEST (reverting cost.sh left all seven phases green), and on a macOS
# `$TMPDIR`, whose `/var/folders/<hash>/` component routinely contains `_`, the
# fixture wrote its transcripts into a directory cost.sh would never look in and
# four phases failed on a column value for a reason unrelated to what they test.
# Found by the independent review -- the PR body reported the same class of bug
# pointed the other way, silent agreement on the sample in front of you.
transcript_slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '-'; }

# A worktree holding just the payload, and a transcript root beside it.
#
# The WHOLE of scripts/fleet, not cost.sh alone: it sources lib.sh, which sources
# config.sh and a runner driver, so a hand-picked subset is a fixture that cannot
# load.
make_fixture() {
  WORK="$(mktemp -d)"; WORK="$(cd "$WORK" && pwd -P)"
  mkdir -p "$WORK/repo/scripts/fleet"
  cp -R "$REPO_ROOT"/scripts/fleet/. "$WORK/repo/scripts/fleet/"

  export AUTOFLEET_DIR="$WORK/fleet"
  mkdir -p "$AUTOFLEET_DIR/ran" "$AUTOFLEET_DIR/worktrees"
  export AUTOFLEET_TRANSCRIPT_DIR="$WORK/transcripts"
  mkdir -p "$AUTOFLEET_TRANSCRIPT_DIR"

  # Two issues: #48 has transcripts, #49 has a recorded path and nothing behind
  # it, which is the worktree-already-reaped case.
  # The `_` is load-bearing: it is the one character in these paths where the
  # narrow `/`-and-`.` rule and the CLI rule disagree, so it is what makes the
  # four summing phases fail if cost.sh narrows again. See transcript_slug.
  WT48="$WORK/wt/48_measures-what-a-run-costs"
  WT49="$WORK/wt/49_a-worktree-that-is-gone"
  printf '%s\n' "$WT48" >"$AUTOFLEET_DIR/ran/48"
  printf '%s\n' "$WT49" >"$AUTOFLEET_DIR/ran/49"
}

# The fixture transcripts for #48. Two sessions, and between them every entry
# shape the reader is asked to survive.
#
# Expected, and asserted below: 2 sessions, 116 input, 1122 output, 11503 cache
# read, 579 cache write.
#
# Two ways to get that wrong, and both look like an answer rather than an error:
# a reader that does not de-duplicate on `message.id` reports 126/1222/12503/629,
# and one that reads only the top level of the project directory drops the
# subagent entirely and reports 16/122/1503/79. The subagent is the bigger of the
# two here on purpose -- so is it in a real worktree.
make_transcripts() {
  local dir="$AUTOFLEET_TRANSCRIPT_DIR/$(transcript_slug "$WT48")"
  mkdir -p "$dir"
  cat >"$dir/session-one.jsonl" <<'JSONL'
{"type":"user","message":{"role":"user","content":"go"}}
{"type":"assistant","message":{"id":"msg_a","usage":{"input_tokens":10,"output_tokens":100,"cache_read_input_tokens":1000,"cache_creation_input_tokens":50}}}
{"type":"assistant","message":{"id":"msg_a","usage":{"input_tokens":10,"output_tokens":100,"cache_read_input_tokens":1000,"cache_creation_input_tokens":50}}}
{"type":"assistant","message":{"id":"msg_b","usage":{"input_tokens":5,"output_tokens":20,"cache_read_input_tokens":500,"cache_creation_input_tokens":25}}}
{"type":"assistant","message":{"id":"msg_c"}}
JSONL
  # ...and a half-written last line, with no trailing newline, exactly as a live
  # agent's transcript looks while it is being appended to.
  printf '%s' '{"type":"assistant","message":{"id":"msg_d","usa' >>"$dir/session-one.jsonl"

  cat >"$dir/session-two.jsonl" <<'JSONL'
{"type":"assistant","message":{"id":"msg_e","usage":{"input_tokens":1,"output_tokens":2,"cache_read_input_tokens":3,"cache_creation_input_tokens":4}}}
JSONL

  # The subagent, a directory deeper. A session that spawns agents writes them
  # under `<session-id>/subagents/`, and an agent that spawns an agent nests
  # further still, so the fixture nests too.
  mkdir -p "$dir/session-one/subagents"
  cat >"$dir/session-one/subagents/agent-reviewer.jsonl" <<'JSONL'
{"type":"assistant","message":{"id":"msg_sub","usage":{"input_tokens":100,"output_tokens":1000,"cache_read_input_tokens":10000,"cache_creation_input_tokens":500}}}
JSONL

  # A file that is not a transcript, and a transcript with no usage in it at all:
  # neither is a session that cost anything, and neither may inflate the count.
  printf 'not json\n' >"$dir/notes.txt"
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"hi"}}' \
    >"$dir/session-three.jsonl"
}

cost() { (cd "$WORK/repo" && ./scripts/fleet/cost.sh "$@"); }

case "${1:-}" in
  sums)
    make_fixture
    make_transcripts
    out="$(cost 48 2>/dev/null)" || fail "cost.sh exited non-zero: $out"
    row="$(printf '%s\n' "$out" | awk '$1 == 48')"
    [ -n "$row" ] || fail "no row for #48 in:
$out"
    # Field by field rather than one string match, so a failure says WHICH
    # column is wrong instead of printing two lines that differ somewhere.
    set -- $row
    [ "$2" = 2 ]      || fail "sessions: expected 2, got $2 (a file with no usage is not a session, and a subagent is not one either)"
    [ "$3" = 116 ]    || fail "input: expected 116, got $3 (16 means the subagent transcript was never read)"
    [ "$4" = 1,122 ]  || fail "output: expected 1,122, got $4 (122 = no subagent; 1,222 = the duplicate entry counted twice)"
    [ "$5" = 11,503 ] || fail "cache read: expected 11,503, got $5"
    [ "$6" = 579 ]    || fail "cache write: expected 579, got $6"
    printf '%s\n' "$out" | grep -q '^ *total' \
      || fail "there is no total row:
$out"
    echo "ok: the four figures are summed per issue, de-duplicated by message id"
    ;;

  json)
    make_fixture
    make_transcripts
    out="$(cost --json 48 2>/dev/null)" || fail "cost.sh --json exited non-zero: $out"
    printf '%s' "$out" | python3 -c '
import json, sys
report = json.load(sys.stdin)
issues = report["issues"]
if len(issues) != 1:
    sys.exit("expected one issue in the report, got %d" % len(issues))
row = issues[0]
want = {"issue": "48", "sessions": 2, "input_tokens": 116, "output_tokens": 1122,
        "cache_read_input_tokens": 11503, "cache_creation_input_tokens": 579}
for key, value in want.items():
    if row.get(key) != value:
        sys.exit("%s: expected %r, got %r" % (key, value, row.get(key)))
    # `.get(key, value)` defaulted to the expected answer, so a total that had
    # LOST a key passed, and "issue" -- which a total never has -- was checked
    # on every run. Found by the independent review.
    if key == "issue":
        continue
    if key not in report["total"]:
        sys.exit("the total block has no %s at all" % key)
    if report["total"][key] != value:
        sys.exit("total %s: expected %r, got %r" % (key, value, report["total"][key]))
if not report["transcript_dir"]:
    sys.exit("the report does not say which transcript root it read")
' || fail "the JSON does not carry the same figures as the table"
    echo "ok: --json prints the same figures, as integers"
    ;;

  empty)
    make_fixture
    make_transcripts
    # A root that is THERE but names nothing is a second line of explanation on
    # top of the first, and the Acceptance of #48 asks for one. Asserted for the
    # missing root as well as the empty one, because they take different
    # branches and only the empty one was covered.
    out="$(AUTOFLEET_TRANSCRIPT_DIR=/nope/not/here cost 999 2>&1)"
    rc=$?
    [ "$rc" = 0 ] || fail "a missing transcript root exited $rc; cost must never fail a run"
    [ "$(printf '%s\n' "$out" | grep -c .)" = 1 ] \
      || fail "a missing transcript root printed more than one line:
$out"
    grep -q 'is not there' <<<"$out" \
      || fail "the one line it printed was not about the missing root: $out"

    out="$(AUTOFLEET_TRANSCRIPT_DIR= cost 2>&1)"
    rc=$?
    [ "$rc" = 0 ] || fail "an empty transcript root exited $rc; cost must never fail a run"
    grep -qi 'AUTOFLEET_TRANSCRIPT_DIR' <<<"$out" \
      || fail "it did not say which knob turned the report off: $out"
    [ "$(printf '%s\n' "$out" | grep -c .)" = 1 ] \
      || fail "an empty transcript root printed more than one line:
$out"
    printf '%s\n' "$out" | grep -q 'total' \
      && fail "it printed a table of zeros, which reads as a measurement of nothing spent"
    echo "ok: an empty transcript root is one line and exit 0"
    ;;

  attempts)
    make_fixture
    make_transcripts
    # A second worktree for the same issue, as `fleet.sh retry 48` opens: the
    # record APPENDS rather than replacing, so both attempts are still findable.
    second="$WORK/wt/48_measures-what-a-run-costs-2"
    printf '%s\n' "$second" >>"$AUTOFLEET_DIR/ran/48"
    dir="$AUTOFLEET_TRANSCRIPT_DIR/$(transcript_slug "$second")"
    mkdir -p "$dir"
    cat >"$dir/session-retry.jsonl" <<'JSONL'
{"type":"assistant","message":{"id":"msg_r","usage":{"input_tokens":7,"output_tokens":8,"cache_read_input_tokens":9,"cache_creation_input_tokens":11}}}
JSONL
    out="$(cost 48 2>/dev/null)" || fail "cost.sh exited non-zero: $out"
    row="$(printf '%s\n' "$out" | awk '$1 == 48')"
    # Guarded like `sums` is: under `set -u` a missing row dies on `$2: unbound
    # variable` three lines down, which is not this phase saying what went
    # wrong. Found by the independent review.
    [ -n "$row" ] || fail "no row for #48 in:
$out"
    set -- $row
    [ "$2" = 3 ]      || fail "sessions: expected 3 across both attempts, got $2"
    [ "$3" = 123 ]    || fail "input: expected 123 across both attempts, got $3"
    [ "$4" = 1,130 ]  || fail "output: expected 1,130 across both attempts, got $4"
    [ "$5" = 11,512 ] || fail "cache read: expected 11,512 across both attempts, got $5"
    [ "$6" = 590 ]    || fail "cache write: expected 590 across both attempts, got $6"
    echo "ok: an issue that ran twice is measured across both worktrees"
    ;;

  long_path)
    make_fixture
    # A worktree path past the 200-character cap. The CLI keeps the first 200
    # characters of the slug and appends `-` plus a hash of the path, which is
    # not reproducible here -- so cost.sh matches on the prefix, and NOTHING
    # exercised that branch: get the constant, the separator or the premise
    # wrong and the issue silently reports zeros, which is round one`s bug
    # pointed at a rarer input. Found by the independent review.
    deep="$WORK/wt"
    while [ "${#deep}" -lt 210 ]; do deep="$deep/a-directory-with-a-long-name"; done
    printf '%s\n' "$deep" >"$AUTOFLEET_DIR/ran/71"
    slug="$(transcript_slug "$deep")"
    [ "${#slug}" -gt 200 ] \
      || fail "the fixture path is only ${#slug} characters, so this asserts nothing"
    truncated="$AUTOFLEET_TRANSCRIPT_DIR/$(printf %s "$slug" | cut -c1-200)-1a2b3c"
    mkdir -p "$truncated"
    cat >"$truncated/session.jsonl" <<'JSONL'
{"type":"assistant","message":{"id":"msg_long","usage":{"input_tokens":3,"output_tokens":4,"cache_read_input_tokens":5,"cache_creation_input_tokens":6}}}
JSONL
    out="$(cost 71 2>/dev/null)" || fail "cost.sh exited non-zero: $out"
    row="$(printf '%s\n' "$out" | awk '$1 == 71')"
    [ -n "$row" ] || fail "no row for #71 in:
$out"
    set -- $row
    [ "$2" = 1 ] || fail "sessions: expected 1, got $2 -- the truncated directory was not found"
    [ "$4" = 4 ] || fail "output: expected 4, got $4"
    echo "ok: a worktree path past the slug cap is found by its truncated prefix"
    ;;

  filtered)
    make_fixture
    make_transcripts
    out="$(cost 999 2>&1)"
    rc=$?
    [ "$rc" = 0 ] || fail "an unrecorded issue exited $rc; cost must never fail a run"
    grep -q '#999' <<<"$out" || fail "it did not name the issue it could not find: $out"
    grep -q 'anything to measure' <<<"$out" \
      && fail "it reported an empty fleet while #48 and #49 are recorded: $out"
    printf '%s\n' "$out" | grep -q 'total' \
      && fail "it printed a total row of zeros, which is a measurement of nothing spent"
    # ...and a filter that matches SOME of what it was given still reports those.
    out="$(cost 48 999 2>&1)"
    grep -q '#999' <<<"$out" || fail "the unmatched issue went unmentioned: $out"
    printf '%s\n' "$out" | awk '$1 == 48' | grep -q . \
      || fail "the issue that IS recorded was dropped along with it:
$out"
    # The row is what the rest of this phase is about, so say so rather than
    # letting a later expansion die on it.
    [ -n "$(printf '%s\n' "$out" | awk '$1 == 48')" ] \
      || fail "no row for #48 in:
$out"
    echo "ok: a filter that matches nothing says so precisely, and prints no table"
    ;;

  reaped)
    make_fixture
    make_transcripts
    # #49's worktree path is recorded and its transcripts were never there.
    out="$(cost 2>&1)"
    rc=$?
    [ "$rc" = 0 ] || fail "a reaped worktree exited $rc; cost must never fail a run"
    grep -q '#49' <<<"$out" || fail "it did not say #49 has no transcripts: $out"
    printf '%s\n' "$out" | awk '$1 == 48' | grep -q . \
      || fail "the issue that DOES have transcripts was dropped along with it:
$out"
    echo "ok: a worktree already reaped costs one line and nothing else"
    ;;

  subcommand)
    make_fixture
    make_transcripts
    # A driver that answers "there is no runtime here", which is what a CI
    # runner has and what a laptop with the app shut has. Only the two functions
    # the source-time path touches; nothing here dispatches anything.
    cat >"$WORK/repo/scripts/fleet/runner/none.sh" <<'DRIVER'
#!/usr/bin/env bash
runner_available() { echo "no runtime here" >&2; return 1; }
runner_dispatcher_hint() { printf 'nothing to dispatch with
'; }
DRIVER
    export AUTOFLEET_RUNNER=none
    # ...and prove the stub really does refuse, or the assertion below passes
    # for the wrong reason on a machine where nothing was ever going to fail.
    (cd "$WORK/repo" && ./scripts/fleet/fleet.sh status >/dev/null 2>&1) \
      && fail "the stub runner did not refuse, so this phase asserts nothing"
    err="$WORK/subcommand.err"
    out="$(cd "$WORK/repo" && ./scripts/fleet/fleet.sh cost --json 48 2>"$err")" \
      || fail "fleet.sh cost exited non-zero with no runner.
stdout: $out
stderr: $(cat "$err")"
    printf '%s' "$out" | python3 -c '
import json, sys
if json.load(sys.stdin)["issues"][0]["output_tokens"] != 1122:
    sys.exit("fleet.sh cost did not reach cost.sh with its arguments intact")
' || fail "fleet.sh cost does not dispatch to cost.sh: $out"
    echo "ok: fleet.sh cost reaches cost.sh, arguments and all"
    ;;

  *)
    echo "usage: test_cost.sh sums|json|empty|attempts|long_path|filtered|reaped|subcommand" >&2; exit 2 ;;
esac
