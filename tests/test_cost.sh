#!/usr/bin/env bash
# Covers scripts/fleet/cost.sh -- what a build cost, read back out of the build's
# own result JSON.
#
#   test_cost.sh sums        the figures, from a fixture build directory. It
#                            carries every shape the reader has to survive: a
#                            finished run moved into `runs/`, the current run's
#                            `result.json`, a `stream-json` list whose last
#                            element is the result object, a result with no
#                            `usage`, and a file that does not parse at all.
#   test_cost.sh json        --json prints the same figures, as numbers.
#   test_cost.sh empty       no builds directory at all is one explanatory line
#                            and exit 0, and NO table: a table of zeros is a
#                            measurement, and nothing was measured.
#   test_cost.sh attempts    an issue that was RESUMED has every run counted,
#                            not just the last one -- which is the question the
#                            report exists to answer, and the one a
#                            `result.json` overwritten in place cannot.
#   test_cost.sh degrades    a result a wrapper seam wrote in some other shape
#                            costs one line on stderr and contributes no
#                            figures, and the run still counts. A reporting
#                            command must never be the thing that fails a run.
#   test_cost.sh filtered    an issue filter that matches nothing says WHICH
#                            issue it could not find and prints no table. "The
#                            fleet has run nothing" is false with another issue
#                            recorded, and a total row of zeros is a measurement
#                            of a fleet that spent nothing.
#   test_cost.sh reaped      an issue whose WORKTREE is gone still reports. The
#                            build directory is under $AUTOFLEET_DIR and outlives
#                            the worktree on purpose -- the old report read the
#                            agent CLI's session transcripts by slugging the
#                            worktree path, and a reaped worktree was a row of
#                            zeros indistinguishable from a run that spent
#                            nothing.
#   test_cost.sh subcommand  `fleet.sh cost` reaches cost.sh ON A MACHINE WITH NO
#                            RUNNER. Wired wrong, every assertion above passes
#                            against a command nobody can invoke -- and the
#                            runner is the specific way it was wrong: fleet.sh
#                            probes for one at SOURCE time and dies, so `cost`
#                            answered "the runner is not usable here" on every
#                            machine without one. That is a CI runner, and a
#                            laptop with the app shut, and the laptop is where
#                            somebody asks what last night cost.
#
# The fleet state dir is a temp dir, so nothing here reads this machine's own
# fleet.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; return 0; }
trap cleanup EXIT

# A worktree holding just the payload, and a fleet state dir beside it.
#
# The WHOLE of scripts/fleet, not cost.sh alone: it sources lib.sh, which sources
# config.sh and a runner driver, so a hand-picked subset is a fixture that cannot
# load.
make_fixture() {
  WORK="$(mktemp -d)"; WORK="$(cd "$WORK" && pwd -P)"
  mkdir -p "$WORK/repo/scripts/fleet"
  cp -R "$REPO_ROOT"/scripts/fleet/. "$WORK/repo/scripts/fleet/"

  export AUTOFLEET_DIR="$WORK/fleet"
  mkdir -p "$AUTOFLEET_DIR/builds"
}

# The fixture builds for #48: two runs, and between them every result shape the
# reader is asked to survive.
#
# Expected, and asserted below: 2 runs, $1.75, 37 turns, 110 input, 22 output,
# 5900 cache read, 330 cache write.
#
# Two ways to get that wrong, and both look like an answer rather than an error:
# a reader that takes only `result.json` reports the resume alone -- 1 run, $0.25
# -- and one that cannot read the `stream-json` list shape drops the first run
# the same way.
make_builds() {
  local dir="$AUTOFLEET_DIR/builds/48"
  mkdir -p "$dir/runs"
  # The finished run, in the list shape `--output-format stream-json` emits:
  # the LAST element is the result object, and everything before it is the
  # conversation.
  cat >"$dir/runs/0.json" <<'JSON'
[{"type":"assistant"},
 {"subtype":"error_max_turns","num_turns":30,"total_cost_usd":1.5,
  "usage":{"input_tokens":100,"output_tokens":20,
           "cache_read_input_tokens":5000,"cache_creation_input_tokens":300}}]
JSON
  # The run that is current, in the bare-object shape `--output-format json`
  # emits.
  cat >"$dir/result.json" <<'JSON'
{"subtype":"success","num_turns":7,"total_cost_usd":0.25,
 "usage":{"input_tokens":10,"output_tokens":2,
          "cache_read_input_tokens":900,"cache_creation_input_tokens":30}}
JSON
}

cost() { (cd "$WORK/repo" && ./scripts/fleet/cost.sh "$@"); }

# One column of the row for one issue, by header name. The table is
# right-aligned and space-separated, so the header row is what says which column
# is which -- reading by position would pass against a table whose columns had
# been reordered under it.
column() {
  local table="$1" issue="$2" want="$3"
  printf '%s' "$table" | ISSUE="$issue" WANT="$want" python3 -c '
import os, sys
# THE HEADER IS FOUND, not assumed to be the first line: every caller captures
# stderr too, and cost.sh says a line there whenever a result could not be read
# -- which is the one phase where getting this wrong reads a diagnostic as the
# table and answers about the wrong column.
rows = [r.split() for r in sys.stdin.read().splitlines() if r.strip()]
head = next((r for r in rows if r and r[0] == "issue"), None)
if head is None or os.environ["WANT"] not in head:
    raise SystemExit(1)
i = head.index(os.environ["WANT"])
for r in rows[rows.index(head) + 1:]:
    if r and r[0] == os.environ["ISSUE"]:
        print(r[i])
        break
'
}

case "${1:-}" in
  sums)
    make_fixture
    make_builds
    out="$(cost 2>&1)" || fail "cost.sh exited non-zero: $out"
    [ "$(column "$out" 48 runs)" = 2 ] \
      || fail "an issue that ran twice was not counted as two runs: $out"
    [ "$(column "$out" 48 usd)" = 1.75 ] \
      || fail "the two runs' dollars were not summed: $out"
    [ "$(column "$out" 48 turns)" = 37 ] \
      || fail "the two runs' turns were not summed: $out"
    [ "$(column "$out" 48 input)" = 110 ] \
      || fail "input tokens: $out"
    [ "$(column "$out" 48 output)" = 22 ] \
      || fail "output tokens: $out"
    [ "$(column "$out" 48 cache-read)" = 5,900 ] \
      || fail "cache-read tokens: $out"
    [ "$(column "$out" 48 cache-write)" = 330 ] \
      || fail "cache-write tokens: $out"
    echo "ok: every run of an issue is read, in both result shapes, and summed"
    ;;

  json)
    make_fixture
    make_builds
    out="$(cost --json 2>&1)" || fail "cost.sh --json exited non-zero: $out"
    printf '%s' "$out" | python3 -c '
import json, sys
doc = json.load(sys.stdin)
row = doc["issues"][0]
assert row["issue"] == "48", row
assert row["runs"] == 2, row
assert abs(row["usd"] - 1.75) < 1e-9, row
assert row["turns"] == 37, row
assert row["input_tokens"] == 110, row
assert row["cache_read_input_tokens"] == 5900, row
assert doc["total"]["runs"] == 2, doc["total"]
' || fail "--json did not carry the same figures as the table: $out"
    echo "ok: --json carries the same figures, as numbers"
    ;;

  empty)
    make_fixture
    rm -rf "$AUTOFLEET_DIR/builds"
    out="$(cost 2>&1)"; rc=$?
    [ "$rc" = 0 ] || fail "a fleet that has built nothing failed the command (rc $rc): $out"
    grep -q "no builds under" <<<"$out" \
      || fail "it did not say why there is nothing to report: $out"
    grep -q "^issue" <<<"$out" \
      && fail "it printed a table of zeros, which is a measurement of a fleet that spent nothing: $out"
    echo "ok: nothing to measure is one line and no table"
    ;;

  attempts)
    make_fixture
    # THE RESUME IS THE CASE. `fleet_build_started` moves a finished result into
    # `runs/` rather than overwriting it, so "did the resume cost more than the
    # build" is answerable. Driven through that function rather than by placing
    # the files, or this asserts against a layout the code may never produce.
    dir="$AUTOFLEET_DIR/builds/48"
    mkdir -p "$dir"
    printf '{"num_turns":30,"total_cost_usd":1.5}\n' >"$dir/result.json"
    ( cd "$WORK/repo" && bash -c '
        set -uo pipefail
        REPO_ROOT="$PWD"
        . ./scripts/fleet/lib.sh
        fleet_build_started "$(fleet_build_dir 48)" /tmp/wt 48' ) \
      || fail "fleet_build_started refused to start a second run"
    [ -f "$dir/runs/0.json" ] \
      || fail "the first run's result was overwritten, so what an issue cost is unanswerable: $(ls -R "$dir")"
    printf '{"num_turns":7,"total_cost_usd":0.25}\n' >"$dir/result.json"
    out="$(cost 2>&1)"
    [ "$(column "$out" 48 runs)" = 2 ] \
      || fail "a resumed issue reported one run: $out"
    [ "$(column "$out" 48 usd)" = 1.75 ] \
      || fail "a resumed issue reported only its last run's cost: $out"
    echo "ok: a resumed issue reports every run it had"
    ;;

  degrades)
    make_fixture
    make_builds
    # AUTOFLEET_BUILD_CMD is advertised as a wrapper seam, and a wrapper need not
    # honour `--output-format json`. What comes back is then anything at all.
    printf 'this is not json\n' >"$AUTOFLEET_DIR/builds/48/result.json"
    out="$(cost 2>&1)"; rc=$?
    [ "$rc" = 0 ] || fail "an unreadable result failed the report (rc $rc): $out"
    grep -q "could not read" <<<"$out" \
      || fail "it read past an unreadable result in silence, so the row is short with nothing saying so: $out"
    [ "$(column "$out" 48 runs)" = 2 ] \
      || fail "the run that produced an unreadable result was not counted as a run: $out"
    [ "$(column "$out" 48 usd)" = 1.50 ] \
      || fail "an unreadable result contributed figures it does not have: $out"
    echo "ok: a result nothing can parse costs a line on stderr, not the report"
    ;;

  filtered)
    make_fixture
    make_builds
    out="$(cost 999 2>&1)"; rc=$?
    [ "$rc" = 0 ] || fail "a filter that matched nothing failed the command (rc $rc): $out"
    grep -q "no build recorded for #999" <<<"$out" \
      || fail "it did not say which issue it could not find: $out"
    grep -q "^issue" <<<"$out" \
      && fail "it printed a table for a filter that matched nothing: $out"
    # ...and the filter accepts the form the report itself prints.
    out="$(cost '#48' 2>&1)"
    [ "$(column "$out" 48 runs)" = 2 ] \
      || fail "the '#48' form the report teaches was refused by the parser: $out"
    echo "ok: a filter that matches nothing names it, and '#48' is accepted"
    ;;

  reaped)
    make_fixture
    make_builds
    # The worktree is gone -- reaped hours ago -- and the build directory is not.
    # That is the whole reason it lives under $AUTOFLEET_DIR: the report used to
    # find an issue's cost by slugging its WORKTREE PATH into the agent CLI's
    # transcript root, so a reaped worktree was a row of zeros that could not be
    # told from a run that spent nothing.
    rm -rf "$WORK/wt"
    out="$(cost 2>&1)"; rc=$?
    [ "$rc" = 0 ] || fail "a reaped worktree failed the report (rc $rc): $out"
    [ "$(column "$out" 48 usd)" = 1.75 ] \
      || fail "an issue whose worktree is gone lost its figures with it: $out"
    echo "ok: what a build cost outlives the worktree it ran in"
    ;;

  subcommand)
    make_fixture
    make_builds
    # A DRIVER THAT REFUSES, so this asserts what it says it does. `fleet.sh`
    # probes for a runner at source time and dies on a no -- so `cost` used to
    # answer "the runner is not usable here" on every machine without one, which
    # is every CI runner and every laptop with the app shut.
    cat >"$WORK/repo/scripts/fleet/runner/nothing.sh" <<'DRIVER'
#!/usr/bin/env bash
runner_available()       { echo "no runtime here" >&2; return 1; }
runner_dispatcher_hint() { echo "there is no dispatcher here"; }
runner_set_deadline()    { return 0; }
runner_worktree_create() { echo "no"; return 1; }
runner_worktree_list()   { return 1; }
runner_worktree_issue()  { return 1; }
runner_worktree_set()    { return 1; }
runner_worktree_remove() { return 2; }
runner_build_start()     { return 1; }
runner_build_state()     { return 1; }
runner_build_stop()      { return 0; }
DRIVER
    out="$( cd "$WORK/repo" && AUTOFLEET_RUNNER=nothing ./scripts/fleet/fleet.sh cost --json 2>&1 )"; rc=$?
    [ "$rc" = 0 ] \
      || fail "fleet.sh cost does not reach cost.sh on a machine with no runner (rc $rc): $out"
    printf '%s' "$out" | python3 -c '
import json, sys
doc = json.load(sys.stdin)
assert doc["issues"][0]["issue"] == "48", doc
' || fail "fleet.sh cost does not dispatch to cost.sh: $out"
    echo "ok: fleet.sh cost answers on a machine whose runner refuses"
    ;;

  *)
    echo "usage: tests/test_cost.sh <phase>" >&2
    echo "  the phases are the \`cost:\` row of SUITES in tests/run.sh --" >&2
    echo "  one registry, which is what evals/lint.sh checks against." >&2
    exit 2 ;;
esac
