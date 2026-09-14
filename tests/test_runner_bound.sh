#!/usr/bin/env bash
# Covers the per-phase bound in tests/run.sh -- the runner's own guard.
#
# The bound exists because the failure this runner is worst at reporting is the
# one that produces nothing: CI run 34658821929 printed `ok review_mode/mode`,
# then nine minutes of silence and exit 143, naming neither suite nor phase.
# A guard that silently stops guarding is worse than no guard (CLAUDE.md hard
# rule 3), and this one shipped with nothing asserting it -- which both review
# passes said, and which is how the two defects below got in.
#
#   test_runner_bound.sh bounds   a phase that blocks is killed at the bound and
#                                 reported FAIL with a BLOCKED line naming the
#                                 duration, and the output it managed to produce
#                                 before wedging is kept. Unbounded this phase
#                                 does not fail -- it hangs, and takes the run
#                                 with it. Also: the phase's descendants die with
#                                 it, including one in a process group of its own
#                                 -- a survivor fails a later, unrelated phase.
#   test_runner_bound.sh passes   ...and a phase that finishes is NOT reported
#                                 blocked. The marker is written just before the
#                                 kill, so a phase completing in that window
#                                 leaves one behind having passed: the row that
#                                 goes red if the `rc` half of the test is
#                                 dropped and BLOCKED becomes a coin flip.
#   test_runner_bound.sh skips    a phase that exits 77 is a SKIP: reported, counted
#                                 and printed with its own reason, and it does
#                                 not fail the run. test_teardown.sh has exited
#                                 77 since it was written -- when docker is down,
#                                 and when the machine carries an orphan stack a
#                                 real sweep would destroy -- and this runner
#                                 read it as FAIL, so the suite went red on a
#                                 machine detail no diff could fix. The other
#                                 half is asserted with it: 77 is the ONLY
#                                 non-zero that means skip, and only from a phase
#                                 named in SKIPPABLE -- an unlisted phase exiting
#                                 77 is the phase that BROKE into skipping, and
#                                 goes red saying which list it is missing from.
#   test_runner_bound.sh hostlint evals/lint.sh's phase-registry check decides
#                                 which repository it is running in, because it
#                                 reads tests/run.sh and tests/ is NOT vendored.
#                                 That decision was wrong twice in a row -- keyed
#                                 on the `tests/` directory, which every pytest
#                                 project has; then fixed only where the file is
#                                 missing, so a host project with its own
#                                 tests/run.sh failed on a SUITES block it had
#                                 never heard of. Both were checked by hand, and
#                                 by hand is what missed the second. The phase
#                                 drives the SHIPPED check in throwaway trees.
#
#                                 NOTE: that check keys on THIS FILE's name --
#                                 rename it and evals/lint.sh quietly decides it
#                                 is in a host repo and asserts nothing. The
#                                 phase reads the sentinel out of the lint and
#                                 checks the tree really has it, so the rename
#                                 goes red here instead of going silent there.
#   test_runner_bound.sh guards   the two guards ON the bound: a nonsense
#                                 AUTOFLEET_TEST_TIMEOUT is refused at startup
#                                 rather than reporting every phase BLOCKED with
#                                 a duration of "abc" -- `sleep abc` returns AT
#                                 ONCE, so a bad value inverts the guard instead
#                                 of stopping it -- and a run where MAX_BLOCKED
#                                 phases have blocked gives up and says so, since
#                                 no bound rescues a run whose every phase blocks
#                                 from the job's own cap. Both shipped with the
#                                 reasoning and no assertion; CLAUDE.md hard rule
#                                 3 is about that. Found by the independent
#                                 review.
#   test_runner_bound.sh interrupt a SIGINT ENDS the run rather than skipping one
#                                 phase, and leaves nothing behind.
#                                 `trap ... EXIT INT TERM` on a handler that only
#                                 returns reaped the phase and carried on: bash
#                                 resumes after a trap that returns, so Ctrl-C
#                                 stopped a PHASE and not the RUN, and finishing
#                                 needed one per phase left -- about 150.
#                                 Measured at five more phases completed after
#                                 the signal. Found by the independent review.
#
#                                 The no-stray rows are real but do NOT pin the
#                                 watchdog's INT trap: a group interrupt reaches
#                                 its sleep directly, and a runner-only one never
#                                 reaches the watchdog at all. Said here rather
#                                 than left to be assumed, because this file's
#                                 whole subject is rows that hold what they claim.
#   test_runner_bound.sh orphans  ...and the watchdog takes its `sleep` with it.
#                                 `kill` on the subshell alone reaps the subshell
#                                 and orphans the sleep, one per phase -- 58
#                                 strays were measured on the machine this was
#                                 written on, and they went on to starve the
#                                 fork the watchdog itself needs. The guard
#                                 against running out of processes cannot be the
#                                 thing consuming them.
#   test_runner_bound.sh quiet    a green run is a summary and nothing else
#                                 (#52; the reasoning is over the VERBOSE block
#                                 in tests/run.sh). The rows are about what quiet
#                                 must NOT take with it: a failing phase's whole
#                                 captured output, a skip's reason, the summary,
#                                 and the per-phase lines themselves the moment
#                                 anything asks for them.
#
# It drives a COPY of the real tests/run.sh rather than restating its logic, so
# there is no second implementation of the bound to drift from the shipped one.
# The copy gets its own throwaway suites; nothing here runs a real phase.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Every run of the runner copy IN THE `skips` PHASE, except the three that set
# the variable deliberately and say so on the line. The other phases call the
# copy directly because they need their own bound or their own backgrounding, and
# none of their fixtures can exit 77 -- if one ever does, it belongs here.
# The prefix is the point:
# AUTOFLEET_TEST_NO_SKIP is read from the environment, so `AUTOFLEET_TEST_NO_SKIP=1
# ./tests/run.sh` -- the strict form of this very suite -- otherwise reaches the
# copy and fails its skip rows on a harness artefact rather than a defect. That
# happened. One row asserts that clearing beats an outer environment, but a row
# can only see the invocations that exist: the eleventh one, written by whoever
# extends this file next, would re-break it and say so only under the strict
# form nobody runs locally. A helper makes forgetting impossible rather than
# noticed. Found by the independent review.
# AUTOFLEET_TEST_VERBOSE rides along for the same reason and with the same
# hazard: it is read from the environment, so a human debugging this suite with
# `AUTOFLEET_TEST_VERBOSE=1 ./tests/run.sh runner_bound` would otherwise reach
# the copy and turn every "nothing per phase" row red on a harness artefact.
#
# Only the calls that come THROUGH HERE, which is less than the NO_SKIP
# paragraph above promises for its own variable. Most invocations in this file
# drive the copy directly, because they need their own bound or their own
# backgrounding, and those are fine only because they do not assert that
# something is ABSENT from the output: a row added to one of them that greps for
# a MISSING `ok` or `==` line has to clear the variable on its own line, or it
# goes red on a harness artefact rather than on a defect. The rows that do clear
# it say so on their own line.
#
# No count here, deliberately -- not of the invocations and not of the rows that
# clear. Three drafts of this comment stated one, and each was wrong by the time
# it was read; the third was invalidated by a row the same commit added, in the
# paragraph declaring itself immune. A comment claiming a guarantee the code
# does not give is itself the guard that stops guarding. All three found by the
# independent review.
run_copy() {
  AUTOFLEET_TEST_NO_SKIP="${COPY_NO_SKIP-}" AUTOFLEET_TEST_VERBOSE="${COPY_VERBOSE-}" \
    AUTOFLEET_TEST_TIMEOUT=10 \
    "$WORK/tests/run.sh" "$@" >"$WORK/out" 2>&1
}
ok()   { echo "  ok: $*"; }

WORK=""
cleanup() {
  # Belt and braces. The `bounds` phase ASSERTS that the runner reaped the
  # fixture's sleep, so this should find nothing -- but a run that failed that
  # assertion, or died before reaching it, must not leave the stray behind: this
  # file would then be causing the machine-wide contamination it is here to
  # catch, and the next phase to ask `pgrep` a question would pay for it.
  # BOTH naps. $WATCH_NAP is 82 minutes and is the subject of `orphans`: when the
  # regression that phase guards against is present, the phase fails AND leaves
  # the stray -- after which every later `orphans` on this machine hard-fails at
  # its own `before` guard, so the guard is off for exactly as long as it matters
  # most. Reaping only $BLOCK_NAP left the one sleep this file is about. Found by
  # the independent review.
  [ -n "$WORK" ] && {
    pkill -9 -f "sleep $BLOCK_NAP" 2>/dev/null
    pkill -9 -f "sleep $WATCH_NAP" 2>/dev/null
    rm -rf "$WORK"
  }
  return 0
}
trap cleanup EXIT

# Distinctive durations, so `pgrep` cannot match some unrelated process on the
# machine and answer a question this test did not ask. The `timeout` phase in
# test_review_mode.sh greps for a bare `sleep 3607` machine-wide and does fail
# when an unrelated one is running; that is armaatus/autofleet#71's territory,
# not something to reproduce here.
BLOCK_NAP=5507   # what the blocking fixture waits on
WATCH_NAP=4931   # what the watchdog waits on, i.e. the bound itself

# A copy of the real runner, registering ONLY the throwaway suites named in "$@".
#
# The registry is REPLACED rather than added to. Splicing fixtures in front of
# the real SUITES left the copy still registering every real suite, so an inner
# run with no argument ran the whole repo's suite from a temp directory holding
# none of its scripts -- 145 phases failing for want of a file, and a give-up
# assertion that only passed because the fixtures happened to sort first.
#
# Each name gets tests/test_<name>.sh next to the copy: anything starting
# `blocker` blocks forever, `quick` returns at once. run.sh derives its own
# REPO_ROOT from its path, so the copy looks there and finds only these.
make_runner() {
  # The previous one first. `guards` calls this twice and `cleanup` only ever saw
  # the last $WORK, so every run of that phase left a temp directory holding a
  # copy of run.sh behind. Found by the independent review.
  [ -n "$WORK" ] && rm -rf "$WORK"
  WORK="$(mktemp -d)"; WORK="$(cd "$WORK" && pwd -P)"
  mkdir -p "$WORK/tests"
  python3 - "$REPO_ROOT/tests/run.sh" "$WORK/tests/run.sh" "$@" <<'PY2'
import re, sys
src, dst, names = sys.argv[1], sys.argv[2], sys.argv[3:]
s = open(src).read()
# A name carrying a dot registers as a suite WITH a phase -- `skipperd.one`
# becomes the entry `"skipperd:one"` and the label `skipperd/one`. That shape is
# the one that actually ships (SKIPPABLE holds `teardown/reap`), and with only
# bare suite names here `may_skip` was never asked about a `suite/phase` label at
# all. Found by the independent review.
def split(n):
    suite, _, phase = n.partition(".")
    return suite, phase

block = "SUITES=(\n" + "\n".join('"%s:%s"' % split(n) for n in names) + "\n)"
s, n = re.subn(r"SUITES=\(.*?\n\)", lambda m: block, s, count=1, flags=re.S)
if n != 1:
    sys.exit("could not find the SUITES registry in %s" % src)
# The copy gets its own allowlist for the same reason it gets its own suites:
# the fixtures are throwaway names the real one has never heard of. `skipper*`
# and `marker*` fixtures are listed, `rogue*` fixtures deliberately are NOT --
# that pair is what the `skips` phase uses to tell an agreed skip from an
# unlisted one.
allowed = " ".join("/".join(p for p in split(n) if p)
                   for n in names if n.startswith(("skipper", "marker")))
s, n = re.subn(r'SKIPPABLE="[^"]*"', 'SKIPPABLE="%s"' % allowed, s, count=1)
if n != 1:
    sys.exit("could not find the SKIPPABLE registry in %s" % src)
open(dst, "w").write(s)
PY2
  [ -s "$WORK/tests/run.sh" ] || fail "the runner copy was not written"
  chmod +x "$WORK/tests/run.sh"

  local name suite phase
  for name in "$@"; do
    suite="${name%%.*}"; phase="${name#*.}"
    [ "$phase" = "$name" ] && phase=""
    case "$name" in
      blocker*)
        # Blocks forever, after saying something first: the partial output is
        # half of what a BLOCKED report is for.
        #
        # `set -m` puts the sleep in its OWN process group, which is what
        # `review.sh` does with the reviewer so it can signal it. That is the
        # hard case: a group kill aimed at the phase does not reach it, and only
        # walking the descendant tree does. Measured -- a group kill alone left
        # one stray here.
        cat >"$WORK/tests/test_$name.sh" <<EOF
#!/usr/bin/env bash
echo "got this far before wedging"
set -m
sleep $BLOCK_NAP &
wait
EOF
        ;;
      skipperbad*)
        # Allow-listed by the prefix rule above, and exits 1. The one mutation
        # the phase could not see: relax the `rc = 77` test in the runner to
        # `rc != 0` and every other row here stays green, because no fixture was
        # ever both listed AND failing for an ordinary reason. A skip code that
        # swallows real failures is the thing this change exists to prevent.
        # Found by the independent review.
        cat >"$WORK/tests/test_$name.sh" <<'EOF'
#!/usr/bin/env bash
echo "this is an ordinary failure from a phase that is allowed to skip"
exit 1
EOF
        ;;
      skipper*)
        # Declines to judge, the way test_teardown.sh does when docker is down or
        # when the machine already carries an orphan stack. 77 is the autotools
        # convention and the number that file has always exited with.
        cat >"$WORK/tests/test_$name.sh" <<'EOF'
#!/usr/bin/env bash
echo "SKIP: nothing here to judge"
exit 77
EOF
        ;;
      marker*)
        # The marker race, made deterministic. The watchdog writes the marker and
        # THEN kills, so a phase that exits on its own in that window leaves one
        # behind having exited. Rather than time it, the fixture writes the
        # marker itself: it is started by the runner as a background job, so its
        # $PPID is the runner pid the marker is named after. Then it exits 77 --
        # marker present, rc=77, which is exactly the state the BLOCKED branch
        # has to read as a skip and not as a kill.
        cat >"$WORK/tests/test_$name.sh" <<'EOF'
#!/usr/bin/env bash
echo "SKIP: declined, and the marker is there too"
: >"/tmp/autofleet-suite.$PPID.blocked"
exit 77
EOF
        ;;
      rogue*)
        # Exits 77 without being in SKIPPABLE: the phase that broke into
        # skipping, which is the whole reason the allowlist exists.
        cat >"$WORK/tests/test_$name.sh" <<'EOF'
#!/usr/bin/env bash
echo "SKIP: nobody agreed to this"
exit 77
EOF
        ;;
      failer*)
        cat >"$WORK/tests/test_$name.sh" <<'EOF'
#!/usr/bin/env bash
echo "this is a real failure"
exit 1
EOF
        ;;
      *)
        cat >"$WORK/tests/test_$name.sh" <<'EOF'
#!/usr/bin/env bash
echo "finished on time"
exit 0
EOF
        ;;
    esac
    # A dotted name is one suite with one phase, so the SCRIPT is named after the
    # suite half -- the runner invokes `test_<suite>.sh <phase>`, and the fixture
    # ignores the argument it is handed.
    [ -n "$phase" ] && mv "$WORK/tests/test_$name.sh" "$WORK/tests/test_$suite.sh"
    chmod +x "$WORK/tests/test_$suite.sh"
  done
}

case "${1:-}" in

# ----------------------------------------------------------------- bounds
  bounds)
  make_runner blocker
  started="$(date +%s)"
  AUTOFLEET_TEST_TIMEOUT=3 "$WORK/tests/run.sh" blocker >"$WORK/out" 2>&1
  rc=$?
  # Unquoted, and the substitution read into a variable first: bash 3.2 -- which
  # is the /bin/bash every macOS ships, and what `bash tests/test_*.sh` gets
  # whenever brew's is not first on PATH -- refuses a quoted operand inside
  # $(( )) outright. The phase died on a syntax error before it judged anything,
  # which is a red that says nothing about the timeout it exists to assert.
  now="$(date +%s)"
  elapsed=$(( now - started ))

  [ "$rc" = 0 ] && fail "a phase that never returned was reported as a pass"
  ok "a blocked phase fails the run"

  grep -q "FAIL blocker" "$WORK/out" \
    || fail "the blocked phase was not named: $(cat "$WORK/out")"
  ok "...and the phase is named, which is what nine minutes of silence was not"

  grep -q "BLOCKED: produced no result in 3s" "$WORK/out" \
    || fail "no BLOCKED line naming the bound: $(cat "$WORK/out")"
  ok "...with a BLOCKED line that says how long it sat there"

  # Without the bound this is not a slower failure, it is no failure at all.
  # Ten seconds of slack over a three-second bound, so a loaded runner does not
  # turn a real assertion into a flake.
  [ "$elapsed" -lt 13 ] \
    || fail "the bound did not fire: ${elapsed}s for a 3s bound"
  ok "...and it fired at the bound rather than running to the job's limit"

  grep -q "got this far before wedging" "$WORK/out" \
    || fail "the output the phase produced before wedging was thrown away"
  ok "...keeping what the phase managed to say, which is the diagnosis"

  # The descendants die with it. `timeout` and `midstop` in test_review_mode.sh
  # ask `pgrep` a machine-wide question about a `sleep 3607`, so a descendant of
  # one bounded phase surviving fails a later, unrelated phase -- measured, with
  # "the wedged reviewer's own child outlived the kill". A bound that creates the
  # misattribution it exists to remove is the worst of the two.
  sleep 2
  strays="$(pgrep -f "sleep $BLOCK_NAP" 2>/dev/null | grep -c . || true)"
  [ "${strays:-0}" = 0 ] \
    || fail "the bound left ${strays} descendant(s) of the killed phase running"
  ok "...and takes the phase's descendants with it, own process group or not"
  ;;

# ----------------------------------------------------------------- passes
  passes)
  make_runner quick
  # `--verbose`, because the ok line this phase reads is verbose-only since #52:
  # a green run says `1 passed.` and nothing per phase. The row below is about
  # the marker race, not about the default, and `quiet` owns the default.
  AUTOFLEET_TEST_VERBOSE="" AUTOFLEET_TEST_TIMEOUT=3 \
    "$WORK/tests/run.sh" --verbose quick >"$WORK/out" 2>&1
  rc=$?

  [ "$rc" = 0 ] || fail "a phase that finished in time failed: $(cat "$WORK/out")"
  ok "a phase that finishes is a pass"

  grep -q "ok   quick" "$WORK/out" \
    || fail "the passing phase was not reported ok: $(cat "$WORK/out")"
  ok "...reported as ok"

  grep -q "BLOCKED" "$WORK/out" \
    && fail "a phase that passed was reported BLOCKED: $(cat "$WORK/out")"
  ok "...and never reported BLOCKED, whatever the marker raced to"
  ;;

# ----------------------------------------------------------------- skips
  skips)
  make_runner skipper quick

  run_copy
  rc=$?

  # The whole of it: a phase that could not judge anything must not turn the run
  # red. It did, and on a machine detail no diff can fix -- docker not running,
  # or an orphan stack from somebody else's crashed run. An agent reading that
  # red row either chases a defect that is not there or learns to ignore the
  # suite, and the second one is how a real failure ships.
  [ "$rc" = 0 ] || fail "a skipped phase failed the run (rc=$rc): $(cat "$WORK/out")"
  ok "a phase that exits 77 does not fail the run"

  grep -q "FAIL skipper" "$WORK/out" \
    && fail "the skipped phase was reported FAIL: $(cat "$WORK/out")"
  grep -q "skip skipper" "$WORK/out" \
    || fail "the skipped phase was not reported as a skip: $(cat "$WORK/out")"
  ok "...and is reported as a skip"

  # Silent is no better than red: a phase that stopped running has to say why, or
  # it is indistinguishable from one that quietly opted out months ago.
  grep -q "SKIP: nothing here to judge" "$WORK/out" \
    || fail "the skip was reported without the phase's reason: $(cat "$WORK/out")"
  ok "...with the reason the phase gave"

  grep -q "1 passed, 1 skipped (skipper)." "$WORK/out" \
    || fail "the green summary did not count the skip by name: $(cat "$WORK/out")"
  ok "...and counted in the summary line"

  # A run that is ALL skips ran nothing, but it is not the mistyped suite name
  # that exit 2 is for: the phase was found, it declined.
  make_runner skipper
  run_copy
  rc=$?
  [ "$rc" = 2 ] \
    && fail "an all-skips run was reported as a mistyped suite name: $(cat "$WORK/out")"
  [ "$rc" = 0 ] \
    || fail "an all-skips run exited $rc: $(cat "$WORK/out")"
  ok "...and a run that is nothing but skips is not 'nothing ran'"

  # The half that matters more: 77 is a skip and every OTHER non-zero is still a
  # failure. A skip code that swallowed failures would be the guard that stops
  # guarding.
  make_runner skipper failer
  run_copy
  rc=$?
  [ "$rc" = 1 ] || fail "a failing phase beside a skip did not fail the run (rc=$rc): $(cat "$WORK/out")"
  grep -q "FAIL failer" "$WORK/out" \
    || fail "the failing phase was not named: $(cat "$WORK/out")"
  grep -q "1 failed" "$WORK/out" \
    || fail "the summary did not count the failure: $(cat "$WORK/out")"
  ok "...while any other non-zero is still a failure"

  # The RED summary line, whole. It is the line somebody reads at a glance to
  # learn what happened, and it carried both defects the review passes found: the
  # skip was not counted on this path at all, and the two name lists sat behind
  # two bare colons -- `1 failed, 0 passed, 1 skipped: skipper: failer`, in which
  # `skipper` reads as a phase that failed. Grepping `1 failed` could not see
  # either, so the line is pinned in full. Found by the independent review.
  grep -q "1 failed, 0 passed, 1 skipped (skipper). failed: failer" "$WORK/out" \
    || fail "the red summary line does not separate the skipped from the failed: $(cat "$WORK/out")"
  ok "...and the red summary says which name is which"

  # The marker race: a phase that exits 77 in the window between the watchdog
  # writing the marker and its kill landing. It EXITED, so it was not blocked --
  # a killed phase comes back 137 -- and reporting it BLOCKED both misnames it
  # and counts it toward MAX_BLOCKED, which can end the whole run early. The
  # fixture writes the marker itself rather than racing for it, so this is a
  # state assertion and not a flake. Found by the independent review.
  make_runner marker
  run_copy
  rc=$?
  grep -q "BLOCKED" "$WORK/out" \
    && fail "a phase that exited 77 with the marker present was reported BLOCKED: $(cat "$WORK/out")"
  grep -q "skip marker" "$WORK/out" \
    || fail "a phase that exited 77 with the marker present was not a skip: $(cat "$WORK/out")"
  [ "$rc" = 0 ] || fail "the marker made a skip fail the run (rc=$rc): $(cat "$WORK/out")"
  ok "a skip that leaves the blocked marker behind is still a skip"

  # AUTOFLEET_TEST_NO_SKIP: the allowlist bounds WHICH phase may decline, this
  # bounds WHERE. On a runner a missing docker is an infrastructure regression,
  # not a local detail, and a green run with a count in it is how that goes
  # unnoticed. Found by the independent review.
  make_runner skipper
  COPY_NO_SKIP=1 run_copy
  rc=$?
  [ "$rc" = 1 ] \
    || fail "AUTOFLEET_TEST_NO_SKIP let a skip pass (rc=$rc): $(cat "$WORK/out")"
  grep -q "FAIL skipper" "$WORK/out" \
    || fail "AUTOFLEET_TEST_NO_SKIP did not report the skip as a failure: $(cat "$WORK/out")"
  grep -q "AUTOFLEET_TEST_NO_SKIP is set" "$WORK/out" \
    || fail "the refusal did not name what refused it: $(cat "$WORK/out")"
  grep -q "SKIPPABLE" "$WORK/out" \
    && fail "the refusal sent the reader to edit a list that did not refuse them: $(cat "$WORK/out")"
  ok "AUTOFLEET_TEST_NO_SKIP makes an allowed skip a failure, and says so"

  # The outer environment does not reach the copy. AUTOFLEET_TEST_NO_SKIP is read
  # from the environment, so `AUTOFLEET_TEST_NO_SKIP=1 ./tests/run.sh` -- the
  # strict form this change documents in CLAUDE.md -- is inherited all the way
  # down into the runner copies these fixtures drive, and turns every skip row
  # here red on a harness artefact rather than on a defect. That is the failure
  # class #78 exists to remove, reintroduced by the fix for it. Every invocation
  # in this phase clears it; this row is what notices if one stops.
  # Found by the independent review.
  ( export AUTOFLEET_TEST_NO_SKIP=1
    run_copy )
  rc=$?
  [ "$rc" = 0 ] \
    || fail "an outer AUTOFLEET_TEST_NO_SKIP reached the runner copy anyway (rc=$rc): $(cat "$WORK/out")"
  grep -q "skip skipper" "$WORK/out" \
    || fail "the cleared value did not restore the skip: $(cat "$WORK/out")"
  ok "...and clearing it on the invocation beats an outer environment that set it"

  # ...and an empty value is not "set". The obvious way to write the guard reads
  # a cleared variable as a request for strictness, which is the opposite of the
  # normal shell reading of one.
  # UNSET, not "the helper's default with an empty value" -- run_copy assigns the
  # variable either way, so `COPY_NO_SKIP="" run_copy` is byte-identical to the
  # plain call above and reds only under mutations that red five earlier rows.
  # The distinction being asserted is a shell one: `${X:-}` reads a cleared
  # variable as unset, which is the normal reading of one somebody emptied.
  # Found by the independent review.
  env -u AUTOFLEET_TEST_NO_SKIP AUTOFLEET_TEST_TIMEOUT=10 \
    "$WORK/tests/run.sh" >"$WORK/out" 2>&1
  rc=$?
  [ "$rc" = 0 ] \
    || fail "an empty AUTOFLEET_TEST_NO_SKIP was read as strict (rc=$rc): $(cat "$WORK/out")"
  ok "...and an empty value leaves the skip alone"

  # ...and the half that keeps 77 from becoming a way to go green quietly. A
  # phase that exits it without being in SKIPPABLE is the phase that BROKE into
  # skipping, and an allowlist nothing asserts is hard rule 3 all over again.
  make_runner rogue
  run_copy
  rc=$?
  [ "$rc" = 1 ] \
    || fail "an unlisted phase exiting 77 did not fail the run (rc=$rc): $(cat "$WORK/out")"
  grep -q "skip rogue" "$WORK/out" \
    && fail "an unlisted phase was allowed to skip: $(cat "$WORK/out")"
  grep -q "FAIL rogue" "$WORK/out" \
    || fail "the unlisted skip was not reported FAIL: $(cat "$WORK/out")"
  ok "an unlisted phase exiting 77 is a failure, not a skip"

  # Named, and told which of the two answers it is: add it to the list, or fix
  # the phase. A bare FAIL sends the reader to the wrong one.
  grep -q "SKIPPABLE" "$WORK/out" \
    || fail "the unlisted skip did not say what to do about it: $(cat "$WORK/out")"
  ok "...and says which list it is missing from"

  # The real runner ships with the one phase that is meant to use it. Asserted
  # here so an allowlist emptied by a bad edit is caught by this file rather than
  # by a red teardown/reap on somebody with no docker.
  # CONTAINS, not equals. Pinning the whole string turns a legitimate second
  # skippable phase into a red row saying teardown/reap was dropped, which is
  # false and sends the reader to the wrong fix. Found by /code-review.
  grep -qE '^SKIPPABLE="([^"]* )?teardown/reap( [^"]*)?"' "$REPO_ROOT/tests/run.sh" \
    || fail "the shipped SKIPPABLE no longer lists teardown/reap"
  ok "...and the shipped list still names the phase that needs it"

  # The label shape that actually ships. Everything above is a bare suite name;
  # SKIPPABLE holds `teardown/reap`, so without this row `may_skip` is never
  # asked about a `suite/phase` label at all. Found by the independent review.
  make_runner skipperd.one
  run_copy
  rc=$?
  [ "$rc" = 0 ] || fail "a suite/phase label could not skip (rc=$rc): $(cat "$WORK/out")"
  grep -q "skip skipperd/one" "$WORK/out" \
    || fail "the suite/phase label was not reported as a skip: $(cat "$WORK/out")"
  ok "...and a suite/phase label is matched the same way a bare suite name is"

  # Listed, and failing for an ordinary reason. SKIPPABLE says this phase may
  # DECLINE; it does not say its failures stop counting. Without this row the
  # runner could treat every non-zero from a listed phase as a skip and nothing
  # here would notice. Found by the independent review.
  make_runner skipperbad
  run_copy
  rc=$?
  [ "$rc" = 1 ] \
    || fail "a listed phase exiting 1 did not fail the run (rc=$rc): $(cat "$WORK/out")"
  grep -q "skip skipperbad" "$WORK/out" \
    && fail "a listed phase exiting 1 was reported as a skip: $(cat "$WORK/out")"
  grep -q "FAIL skipperbad" "$WORK/out" \
    || fail "a listed phase exiting 1 was not reported FAIL: $(cat "$WORK/out")"
  ok "being on the list buys a phase 77 and nothing else"

  # The two refusals stay apart. A phase that BROKE into exiting 77 needs to hear
  # about SKIPPABLE even in a run where nothing may skip -- under a shared status
  # it heard about the variable instead, in CI, which is the hardest place to
  # diagnose from. Found by the independent review.
  make_runner rogue
  COPY_NO_SKIP=1 run_copy
  rc=$?
  [ "$rc" = 1 ] \
    || fail "an unlisted phase under NO_SKIP did not fail the run (rc=$rc): $(cat "$WORK/out")"
  grep -q "is not in SKIPPABLE" "$WORK/out" \
    || fail "an unlisted phase under NO_SKIP was told the wrong thing: $(cat "$WORK/out")"
  ok "...and an unlisted phase is told so even where nothing may skip"
  ;;

# ----------------------------------------------------------------- hostlint
  hostlint)
  # evals/lint.sh is VENDORED and tests/ is not, so its phase-registry check has
  # to decide which repository it is running in. That decision has now been wrong
  # in two consecutive commits -- first keyed on the `tests/` directory, which
  # every pytest project has; then fixed only on the branch where the file is
  # missing, leaving a host project with its own tests/run.sh to fail on a SUITES
  # block it has never heard of. Both were verified by hand, and hand-verifying
  # is what missed the second. So it gets a row. Found by the independent review.
  #
  # The check is driven out of the SHIPPED file rather than restated: the python
  # block is extracted from evals/lint.sh and run in a throwaway tree, the same
  # way make_runner drives a copy of the real runner.
  WORK="$(mktemp -d)"; WORK="$(cd "$WORK" && pwd -P)"
  python3 - "$REPO_ROOT/evals/lint.sh" "$WORK/check.py" <<'PY2'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
marker = "if python3 - <<'PHASES'\n"
if marker not in s:
    sys.exit("evals/lint.sh no longer runs the phase check as an inline python block")
block = s.split(marker, 1)[1].split("\nPHASES", 1)[0]
if "SKIPPABLE" not in block:
    sys.exit("the extracted block is not the phase-registry check")
open(dst, "w").write(block)
PY2
  [ -s "$WORK/check.py" ] || fail "the phase-registry check could not be extracted"

  # A host installation: no autofleet suite, and a tests/run.sh of its own --
  # which is a common shell-project convention, and the case the second wrong
  # discriminator failed on.
  mkdir -p "$WORK/host/tests"
  printf '#!/usr/bin/env bash\necho some other project\n' >"$WORK/host/tests/run.sh"
  : >"$WORK/host/tests/test_something.py"
  out="$(cd "$WORK/host" && python3 "$WORK/check.py" 2>&1)"; rc=$?
  [ "$rc" = 77 ] \
    || fail "a host repo with its own tests/run.sh was not skipped (rc=$rc): $out"
  grep -q "no phase registry" <<<"$out" \
    || fail "the host repo was skipped without saying why: $out"
  ok "a host installation is told the check does not apply, not that it failed"

  # ...and the PLAIN host shape, with no tests/run.sh at all. Both shapes share
  # one path today, since the discriminator answers before anything is opened --
  # but that is an argument from the current implementation, and round 5 is what
  # arguing from the implementation cost: the discriminator then guarded one of
  # its two branches. Found by the independent review.
  mkdir -p "$WORK/bare/tests"
  : >"$WORK/bare/tests/test_something.py"
  out="$(cd "$WORK/bare" && python3 "$WORK/check.py" 2>&1)"; rc=$?
  [ "$rc" = 77 ] \
    || fail "a host repo with no tests/run.sh at all was not skipped (rc=$rc): $out"
  ok "...whether or not it has a tests/run.sh of its own"

  # ...and the caller turns that into silence rather than a green line.
  # By behaviour, not by assertion-on-spelling: grepping for the `elif` line reds
  # this row for a reformat that changes nothing. The shell fragment around the
  # check is extracted and driven with a stub that exits 77 in its place.
  #
  # The EXTRACTION still anchors on text -- the `ok` line's opening words, and the
  # second of this file's three then/fi ranges. That is a spelling, and it is one
  # that fails LOUDLY: a missed match leaves caller.sh with an unterminated `if`,
  # a syntax error and a red row, rather than a row that quietly stops asserting.
  # Said here because that distinction is this phase's whole subject. Found by
  # the independent review.
  cat >"$WORK/caller.sh" <<EOF
ok()   { echo "OK: \$*"; }
fail() { echo "FAIL: \$*"; exit 1; }
if python3 -c 'import sys; sys.exit(77)'; then
$(sed -n '/^then$/,/^fi$/p' "$REPO_ROOT/evals/lint.sh" \
   | sed -n '/^  ok "every phase-dispatching suite agrees/,/^fi$/p')
EOF
  out="$(bash "$WORK/caller.sh" 2>&1)"; rc=$?
  [ "$rc" = 0 ] || fail "the lint's 77 branch is not a clean exit: $out"
  grep -q "OK:" <<<"$out" \
    && fail "the lint prints a green line for a check that did not run: $out"
  grep -q "FAIL:" <<<"$out" \
    && fail "the lint fails a host installation: $out"
  ok "...and the lint neither passes nor fails a check it did not run"

  # ...and the same caller with a REAL failure. Without this row, relaxing the
  # caller's `= 77` to `!= 0` -- the same one-character-class mutation round 6
  # found in the runner -- leaves every genuine registry mismatch green, on a
  # check that runs for every PR. The row above cannot see it: it only ever
  # drives the caller with a skip. Found by the independent review.
  sed 's|sys.exit(77)|sys.exit(1)|' "$WORK/caller.sh" >"$WORK/caller-fail.sh"
  out="$(bash "$WORK/caller-fail.sh" 2>&1)"; rc=$?
  [ "$rc" = 0 ] && fail "the lint passed a genuine registry mismatch: $out"
  grep -q "FAIL:" <<<"$out" \
    || fail "a genuine registry mismatch did not reach the lint's fail branch: $out"
  ok "...while a real mismatch still reaches fail"

  # The sentinel, read out of the shipped lint rather than restated, and asserted
  # against the REAL tree. Rename this file and update SUITES in the same change
  # -- the ordinary way a suite gets renamed, and the suite stays green through
  # it -- and inside autofleet the check would decide it was a host installation,
  # exit 77 and assert nothing, on a lint that runs for every PR. The rows below
  # cannot see that: they fabricate the filename inside their own trees.
  # Found by the independent review.
  # `sort -u`, because there is now more than one block asking the question --
  # armaatus/autofleet#54's reading ceiling has to know whose CLAUDE.md it is
  # looking at, for the same hard-rule-1 reason the registry check does. Reading
  # them as one string made this row fail on a two-line `[ -e ]`, which is the
  # phase doing its job: the property is not "exactly one block asks" but "every
  # block that asks gets the same answer". Two different sentinels is two places
  # the lint can be wrong about which repository it is in.
  sentinels="$(sed -n 's/^[A-Z_]* = os.path.exists("\(.*\)")$/\1/p' "$REPO_ROOT/evals/lint.sh" | sort -u)"
  [ -n "$sentinels" ] \
    || fail "evals/lint.sh no longer decides which repository it is in with an os.path.exists"
  [ "$(printf '%s\n' "$sentinels" | wc -l | tr -d ' ')" = 1 ] \
    || fail "evals/lint.sh decides which repository it is in from more than one file: $(tr '\n' ' ' <<<"$sentinels")"
  [ -e "$REPO_ROOT/$sentinels" ] \
    || fail "evals/lint.sh keys on $sentinels, which is not in this tree: the phase check now asserts nothing here"
  ok "every block of evals/lint.sh that asks which repository this is keys on the same file, and this tree has it"

  # A tree that reaches the cross-check itself. Neither tree above does: one
  # exits at the discriminator, the other at the missing registry, so the loop
  # that compares SKIPPABLE against the registered labels was driven red by hand
  # once and by nothing since -- the same gap as the branch this phase exists
  # for, one function lower. Found by the independent review.
  mkdir -p "$WORK/stale/tests"
  : >"$WORK/stale/tests/test_runner_bound.sh"
  cat >"$WORK/stale/tests/run.sh" <<'EOF'
SUITES=(
"runner_bound:bounds"
)
SKIPPABLE="runner_bound/nosuch"
EOF
  # A HEREDOC, not printf. evals/lint.sh strips heredoc bodies and nothing else
  # before looking for phase arms, so a `  bounds)` spelled outside one is a
  # phase this file appears to define -- agreeing with the real arm today, and
  # becoming a phantom the moment that arm is renamed together with its SUITES
  # entry. The lint would then report a file that is correct. Found by the
  # independent review.
  cat >"$WORK/stale/tests/test_runner_bound.sh" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  bounds)
  ;;
esac
EOF
  out="$(cd "$WORK/stale" && python3 "$WORK/check.py" 2>&1)"; rc=$?
  [ "$rc" = 0 ] && fail "a SKIPPABLE entry naming no registered phase was accepted: $out"
  grep -q "runner_bound/nosuch: allowed to skip" <<<"$out" \
    || fail "the stale SKIPPABLE entry was not named: $out"
  ok "...and a SKIPPABLE entry naming no registered phase is caught"

  # ...while the entry that DOES name one is left alone, so the row above is not
  # passing because the check rejects everything.
  sed -i.bak 's|SKIPPABLE="runner_bound/nosuch"|SKIPPABLE="runner_bound/bounds"|' \
    "$WORK/stale/tests/run.sh"
  out="$(cd "$WORK/stale" && python3 "$WORK/check.py" 2>&1)"; rc=$?
  [ "$rc" = 0 ] || fail "a SKIPPABLE entry naming a registered phase was rejected: $out"
  ok "...and one that names a registered phase is not"

  # HERE, with the registry gone: the check silently stopping, which is the one
  # case that must still be loud.
  mkdir -p "$WORK/mine/tests"
  : >"$WORK/mine/tests/test_runner_bound.sh"
  out="$(cd "$WORK/mine" && python3 "$WORK/check.py" 2>&1)"; rc=$?
  [ "$rc" = 0 ] && fail "autofleet without tests/run.sh was waved through: $out"
  [ "$rc" = 77 ] && fail "autofleet without tests/run.sh was read as a host repo: $out"
  grep -q "asserts nothing" <<<"$out" \
    || fail "the missing registry was not reported as the check stopping: $out"
  ok "...while the registry going missing HERE is still the check stopping"
  ;;

# ----------------------------------------------------------------- guards
  guards)
  make_runner quick

  # A bad bound is refused, rather than reporting every phase blocked. This is
  # the inverted-guard case: `sleep abc` fails instantly, so without the check
  # the watchdog falls straight through to the kill.
  for bad in abc 0 00 12x -5 " "; do
    out="$(AUTOFLEET_TEST_TIMEOUT="$bad" "$WORK/tests/run.sh" quick 2>&1)"
    rc=$?
    [ "$rc" = 2 ] \
      || fail "AUTOFLEET_TEST_TIMEOUT='$bad' was accepted (rc=$rc): $out"
    grep -q "must be a positive whole number" <<<"$out" \
      || fail "AUTOFLEET_TEST_TIMEOUT='$bad' failed without saying why: $out"
    grep -q "BLOCKED" <<<"$out" \
      && fail "AUTOFLEET_TEST_TIMEOUT='$bad' reported a phase BLOCKED: $out"
  done
  ok "a nonsense bound is refused at startup, not turned into BLOCKED reports"

  # ...and a good one is not.
  AUTOFLEET_TEST_TIMEOUT=3 "$WORK/tests/run.sh" quick >"$WORK/out" 2>&1 \
    || fail "a valid bound was refused: $(cat "$WORK/out")"
  ok "...while a whole number is accepted"

  # An EMPTY value is not a bad one: `${AUTOFLEET_TEST_TIMEOUT:-180}` reads it as
  # unset and takes the default, which is the normal shell reading of an env var
  # someone cleared. Asserted rather than assumed, because the obvious way to
  # write the row above is to put "" in the bad list and watch it pass for the
  # wrong reason -- which is what it did on the first run of this phase.
  AUTOFLEET_TEST_TIMEOUT="" "$WORK/tests/run.sh" quick >"$WORK/out" 2>&1 \
    || fail "an empty bound was refused instead of falling back: $(cat "$WORK/out")"
  ok "...and an empty one means unset, so the default applies"

  # The give-up. MAX_BLOCKED blocking phases and the run stops, saying so --
  # otherwise ~130 of them at the bound outlast the 20-minute cap on the job
  # that runs this, and the log ends in exit 143 with most of it unreported,
  # which is where this started.
  # Four blocking suites and nothing else registered, so a cap of 3 has a fourth
  # left to skip and the run has no real phase to wander into.
  make_runner blocker blocker2 blocker3 blocker4

  AUTOFLEET_TEST_TIMEOUT=3 "$WORK/tests/run.sh" >"$WORK/out" 2>&1
  [ "$?" = 0 ] && fail "a run with four blocked phases passed: $(cat "$WORK/out")"

  grep -q "giving up: 3 phases blocked" "$WORK/out" \
    || fail "the run did not give up at the cap: $(cat "$WORK/out")"
  ok "a run gives up once MAX_BLOCKED phases have blocked, and says so"

  blocked_lines="$(grep -c "BLOCKED: produced no result" "$WORK/out" || true)"
  [ "${blocked_lines:-0}" = 3 ] \
    || fail "expected 3 BLOCKED reports before giving up, got ${blocked_lines}"
  ok "...after reporting each of them, so the log names what blocked"

  grep -q "blocker4" "$WORK/out" \
    && fail "the run continued past the cap into a fourth blocked suite"
  ok "...and does not go on to sit out the bound for every phase left"
  ;;

# -------------------------------------------------------------- interrupt
  interrupt)
  make_runner blocker blocker2 blocker3

  # A long bound, so nothing here finishes on its own: what ends the run must be
  # the signal. $WATCH_NAP doubles as the watchdog's sleep, which is what the
  # leak half of this phase counts.
  [ "$(pgrep -f "sleep $WATCH_NAP" 2>/dev/null | grep -c . || true)" = 0 ] \
    || fail "a sleep $WATCH_NAP was already running; this phase cannot answer"

  # `set -m` around the launch, and it is not incidental. A command started with
  # `&` from a NON-INTERACTIVE shell has SIGINT set to ignored on entry, and a
  # signal ignored on entry cannot be trapped afterwards -- so the runner would
  # survive the INT below no matter what its trap said, and this phase would
  # "fail" against correct code and "pass" against nothing. Job control gives the
  # runner its own process group with default dispositions, which is what a
  # terminal Ctrl-C actually delivers to.
  set -m
  AUTOFLEET_TEST_TIMEOUT="$WATCH_NAP" "$WORK/tests/run.sh" >"$WORK/out" 2>&1 &
  runner=$!
  set +m
  # Long enough for the first phase and its watchdog to be up, short enough that
  # nothing has finished.
  sleep 4
  # The process GROUP, which is what a terminal Ctrl-C delivers to -- not the
  # runner alone. The difference is the whole second half of this phase: the
  # watchdog is forked after `set +m`, so it is IN that group and takes the INT
  # directly. Signalling only the runner, its watchdog is reached a moment later
  # by the cleanup's own TERM, and a watchdog trapping TERM alone looks fine.
  # Measured: this phase passed against the TERM-only watchdog until it signalled
  # the group. `set -m` above makes the runner its own group leader, so the
  # negative pid is its pgid.
  kill -INT -"$runner" 2>/dev/null

  # It must END. Ten seconds is far longer than the handler needs and far shorter
  # than $WATCH_NAP, so surviving this means it carried on rather than ran slow.
  waited=0
  while kill -0 "$runner" 2>/dev/null && [ "$waited" -lt 10 ]; do
    sleep 1; waited=$((waited + 1))
  done
  if kill -0 "$runner" 2>/dev/null; then
    kill -9 "$runner" 2>/dev/null
    pkill -9 -f "sleep $BLOCK_NAP" 2>/dev/null; pkill -9 -f "sleep $WATCH_NAP" 2>/dev/null
    fail "the runner survived SIGINT, so Ctrl-C stops a phase and not the run"
  fi
  ok "a SIGINT ends the run rather than skipping one phase"

  wait "$runner" 2>/dev/null; rc=$?
  [ "$rc" = 0 ] \
    && fail "an interrupted run exited 0, so a cancelled job reads as a pass"
  ok "...and does not exit 0"

  # Nothing left behind. The watchdog's sleep is the one the round-one leak was
  # about, and the INT path is where it came back.
  sleep 2
  strays="$(pgrep -f "sleep $WATCH_NAP" 2>/dev/null | grep -c . || true)"
  [ "${strays:-0}" = 0 ] \
    || fail "SIGINT orphaned ${strays} watchdog sleep(s); the trap does not cover INT"
  ok "...and the watchdog takes its sleep with it on INT, not only on TERM"

  phase_strays="$(pgrep -f "sleep $BLOCK_NAP" 2>/dev/null | grep -c . || true)"
  [ "${phase_strays:-0}" = 0 ] \
    || fail "SIGINT left ${phase_strays} descendant(s) of the running phase behind"
  ok "...and the running phase is reaped with its descendants"
  ;;

# ---------------------------------------------------------------- orphans
  orphans)
  make_runner quick
  before="$(pgrep -f "sleep $WATCH_NAP" 2>/dev/null | grep -c . || true)"
  [ "${before:-0}" = 0 ] \
    || fail "a sleep $WATCH_NAP was already running; this phase cannot answer"

  # The phase finishes at once, so every watchdog is cancelled rather than
  # firing -- which is exactly the path that leaked.
  AUTOFLEET_TEST_TIMEOUT="$WATCH_NAP" "$WORK/tests/run.sh" quick >"$WORK/out" 2>&1 \
    || fail "the fixture run did not pass: $(cat "$WORK/out")"

  # The watchdog is signalled after the phase is reaped; give the trap a moment
  # to run before counting, so this measures a leak rather than a schedule.
  sleep 2
  after="$(pgrep -f "sleep $WATCH_NAP" 2>/dev/null | grep -c . || true)"
  [ "${after:-0}" = 0 ] \
    || fail "the watchdog orphaned ${after} sleep(s); killing the subshell does not reap its sleep"
  ok "a cancelled watchdog takes its sleep with it, leaving nothing behind"
  ;;

# ------------------------------------------------------------------ quiet
  quiet)
  # A green run is a summary and nothing else. Why that is worth a phase is
  # written once, over the VERBOSE block in tests/run.sh; what is asserted here
  # is the half a rationale cannot hold -- that quiet took the `ok` rows and
  # NOTHING else with them.
  make_runner quick quick2 quick3
  run_copy
  rc=$?
  [ "$rc" = 0 ] || fail "a green run did not pass: $(cat "$WORK/out")"
  green="$(wc -l <"$WORK/out" | tr -d " ")"
  # FIVE because that is #52's acceptance bar, not because five is the shape:
  # a green run is two lines, a blank and the summary, and stays two however
  # many suites are registered (the row below). The slack is what a phase that
  # DECLINES costs -- its label and its own reason -- which is the one thing
  # allowed to push a green run past two, and the skip row further down spends
  # it deliberately.
  [ "$green" -le 5 ] \
    || fail "a green run printed $green lines: $(cat "$WORK/out")"
  ok "a green run is at most five lines"

  grep -q "3 passed." "$WORK/out" \
    || fail "the green run printed no summary at all: $(cat "$WORK/out")"
  ok "...and the summary, which is the whole of what the ok lines said"

  grep -q "ok   quick" "$WORK/out" \
    && fail "the per-phase lines are still printed: $(cat "$WORK/out")"
  grep -q "== quick" "$WORK/out" \
    && fail "the per-suite headers are still printed: $(cat "$WORK/out")"
  ok "...with nothing per phase and nothing per suite"

  # The cost was never a fixed number of lines, it is that they GROW: every
  # phase this repo adds is another line in every run in every worktree. A
  # budget that scales with the registry is not a budget, so the assertion is
  # that the green run is the same size against twice the suites. (No count
  # here, and none over the VERBOSE block in tests/run.sh either: the one that
  # used to be there was wrong twice. Found by the independent review.)
  make_runner quick quick2 quick3 quick4 quick5 quick6
  run_copy
  [ "$?" = 0 ] || fail "a green run of six suites did not pass: $(cat "$WORK/out")"
  grew="$(wc -l <"$WORK/out" | tr -d " ")"
  # The count of what RAN as well as the count of lines. Comparing 2 against 2
  # is also what a make_runner that quietly registered a subset would produce,
  # and this row would call that "did not grow". Found by /code-review.
  grep -q "6 passed." "$WORK/out" \
    || fail "six suites did not run, so the line count proves nothing: $(cat "$WORK/out")"
  [ "$grew" = "$green" ] \
    || fail "twice the suites printed $grew lines against $green: $(cat "$WORK/out")"
  ok "...and does not grow when the registry does"

  # Quiet must never mean quieter about FAILURES. The captured output of a
  # failing phase is the only part of this runner an agent actually reads, and
  # the failure path is untouched: the whole file, indented, under a FAIL naming
  # the phase, with the summary naming it again.
  make_runner quick failer quick3
  run_copy
  rc=$?
  [ "$rc" = 1 ] \
    || fail "a failing phase did not fail the run (rc=$rc): $(cat "$WORK/out")"
  grep -q "FAIL failer" "$WORK/out" \
    || fail "the failing phase was not named: $(cat "$WORK/out")"
  grep -q "this is a real failure" "$WORK/out" \
    || fail "the failing phase's own output was dropped: $(cat "$WORK/out")"
  grep -q "failed: failer" "$WORK/out" \
    || fail "the summary did not name the failure: $(cat "$WORK/out")"
  ok "a failing phase still prints its whole output, and is named twice"

  grep -q "ok   quick" "$WORK/out" \
    && fail "a run with a failure printed the passing phases too: $(cat "$WORK/out")"
  ok "...while the phases that passed stay quiet"

  # Nor quieter about a phase that judged NOTHING. A silent skip is
  # indistinguishable from a phase that quietly opted out of running months ago,
  # which is the reading run.sh's own SKIPPABLE comment exists to prevent.
  # `quick` beside it, because on a registry of NOTHING BUT skips there is no
  # `ok` line to suppress and the assertions below are green whatever the runner
  # does -- and the shipped shape is a skip among 155 passing phases, not a run
  # that is all skip. Found by the independent review.
  #
  # What that buys, honestly: these rows are the ONLY ones shaped like the run
  # this repo actually performs, and they are regression ballast rather than the
  # last line of defence. No mutation reaches them first -- the runner has no
  # skip-specific verbosity path, so anything that puts the per-phase lines back
  # reds the five-line row at the top of this phase before it gets here. Said
  # because the previous draft of this comment claimed they closed a gap they
  # could not even see. Found by /code-review.
  make_runner skipper quick quick2
  run_copy
  [ "$?" = 0 ] || fail "a skip failed the run: $(cat "$WORK/out")"
  grep -q "skip skipper" "$WORK/out" \
    || fail "the skip went silent under the quiet default: $(cat "$WORK/out")"
  grep -q "SKIP: nothing here to judge" "$WORK/out" \
    || fail "the skip was reported without its reason: $(cat "$WORK/out")"
  ok "a phase that declined to judge still says so, and why"

  # ...and the bound survives it. This is the only tension in #52's acceptance:
  # a green run is at most five lines AND a skip prints the phase's whole reason,
  # and the shipped suite has a skippable phase (`teardown/reap`, on a machine
  # with no docker). The reason wins where they disagree -- a silent skip is the
  # failure the SKIPPABLE registry exists to prevent -- so what is asserted is
  # that a skip costs its OWN output and nothing else: still no `ok` row, still
  # no header, and the label plus one line of reason fits the bar. Found by the
  # spec review, which noticed the shipped suite can carry a skip and the row
  # above could not see it.
  skipped_lines="$(wc -l <"$WORK/out" | tr -d " ")"
  [ "$skipped_lines" -le 5 ] \
    || fail "a green run of two passes and one skip printed $skipped_lines lines: $(cat "$WORK/out")"
  grep -q "ok   " "$WORK/out" \
    && fail "a run with a skip printed the per-phase lines: $(cat "$WORK/out")"
  grep -q "== " "$WORK/out" \
    && fail "a run with a skip printed the suite headers: $(cat "$WORK/out")"
  ok "...and a skip costs its own reason and nothing else"

  # --verbose, whose purpose is over the VERBOSE block in tests/run.sh.
  make_runner quick quick2 quick3
  run_copy --verbose
  [ "$?" = 0 ] || fail "--verbose failed the run: $(cat "$WORK/out")"
  grep -q "ok   quick" "$WORK/out" \
    || fail "--verbose did not restore the per-phase lines: $(cat "$WORK/out")"
  grep -q "== quick" "$WORK/out" \
    || fail "--verbose did not restore the suite headers: $(cat "$WORK/out")"
  ok "--verbose restores the per-phase lines"

  # ...and the environment does the same, for the cases tests/run.sh lists over
  # the VERBOSE block.
  COPY_VERBOSE=1 run_copy
  [ "$?" = 0 ] || fail "AUTOFLEET_TEST_VERBOSE=1 failed the run: $(cat "$WORK/out")"
  grep -q "ok   quick" "$WORK/out" \
    || fail "AUTOFLEET_TEST_VERBOSE=1 did not restore the per-phase lines: $(cat "$WORK/out")"
  ok "...and AUTOFLEET_TEST_VERBOSE=1 does it without a flag"

  # UNSET, which is the only state `./tests/run.sh` is ever actually run in, and
  # the one no row here reached: `run_copy` puts the variable in the child
  # environment on EVERY call, assigned from COPY_VERBOSE with a default, so
  # inside the copy it is always set-and-empty. `COPY_VERBOSE="" run_copy` is
  # byte-identical to the plain call and pins nothing.
  #
  # The mutation that survived: `${AUTOFLEET_TEST_VERBOSE-1}` in place of
  # `${AUTOFLEET_TEST_VERBOSE:-}` -- a default that applies on UNSET only, so
  # set-and-empty stays quiet and unset turns verbose. Every row in this phase
  # stayed green under it while a developer's `./tests/run.sh` went back to
  # printing a line per phase, which is #52's own acceptance criterion gone. Not
  # the bare `-` form: with an empty word after the dash that is identical to
  # `:-` in every state and changes nothing, which is a swap the next reader
  # would try and then conclude this row asserts nothing. Found by the
  # independent review, twice: once for the gap and once for the wrong name.
  # `env -u` is the same answer this file already gives for COPY_NO_SKIP in the
  # `skips` phase, and for the same reason. Found by the independent review.
  env -u AUTOFLEET_TEST_VERBOSE -u AUTOFLEET_TEST_NO_SKIP AUTOFLEET_TEST_TIMEOUT=10 \
    "$WORK/tests/run.sh" >"$WORK/out" 2>&1
  [ "$?" = 0 ] || fail "the shipped invocation failed: $(cat "$WORK/out")"
  grep -q "ok   quick" "$WORK/out" \
    && fail "an UNSET AUTOFLEET_TEST_VERBOSE was read as verbose: $(cat "$WORK/out")"
  grep -q "3 passed." "$WORK/out" \
    || fail "the shipped invocation printed no summary: $(cat "$WORK/out")"
  ok "...and the state the shipped command runs in -- the variable unset -- is quiet"

  # The clearing in run_copy itself. Without it, `AUTOFLEET_TEST_VERBOSE=1
  # ./tests/run.sh runner_bound` -- one person debugging this very suite --
  # reaches every runner copy below and turns each "nothing per phase" row red
  # on a harness artefact. That is the failure the COPY_NO_SKIP helper exists to
  # remove, and this is its row: drop the clearing and the whole suite stays
  # green until somebody sets the variable. Found by /code-review.
  ( export AUTOFLEET_TEST_VERBOSE=1
    run_copy )
  [ "$?" = 0 ] || fail "an outer AUTOFLEET_TEST_VERBOSE failed the run: $(cat "$WORK/out")"
  grep -q "ok   quick" "$WORK/out" \
    && fail "an outer AUTOFLEET_TEST_VERBOSE reached the runner copy: $(cat "$WORK/out")"
  ok "...and an outer one does not reach the copy these rows drive"

  # One phase of one suite still works, and still prints its result -- which,
  # quiet, is the summary. That is the invocation CLAUDE.md tells an agent to
  # reach for when a phase goes red, so it is the one that must not need a flag.
  make_runner quickd.one
  run_copy quickd one
  [ "$?" = 0 ] || fail "one phase of one suite did not pass: $(cat "$WORK/out")"
  grep -q "1 passed." "$WORK/out" \
    || fail "one phase of one suite printed no result: $(cat "$WORK/out")"
  ok "one phase of one suite still runs, and still says so"

  # The flag is read wherever it appears, because `./tests/run.sh fleet card_says
  # --verbose` is where somebody types it. Parsing it as `${1:-}`/`${2:-}` and
  # nothing else makes that a suite named --verbose and a run that says nothing.
  run_copy quickd one --verbose
  [ "$?" = 0 ] || fail "--verbose after the names failed the run: $(cat "$WORK/out")"
  grep -q "ok   quickd/one" "$WORK/out" \
    || fail "--verbose after the names was not read as a flag: $(cat "$WORK/out")"
  ok "...and --verbose is read wherever it sits in the arguments"

  # A MISTYPED flag is refused. This is the way the change breaks CI: `--verbsoe`
  # in the workflow, read as a suite name, nothing matched, and a quiet green run
  # nobody looks at twice. Exit 2 with the word in it, the same answer a mistyped
  # suite name has always got.
  run_copy --verbsoe
  rc=$?
  [ "$rc" = 2 ] || fail "a mistyped flag was accepted (rc=$rc): $(cat "$WORK/out")"
  grep -q -- "--verbsoe" "$WORK/out" \
    || fail "the refusal did not name the argument it refused: $(cat "$WORK/out")"
  # ...and says what the arguments ARE. Both refusals share one `refuse()` in
  # the runner, so a single edit that drops the usage clause takes both of them
  # with it, and rc=2 plus the offending token stays green through that. Found
  # by /code-review, which mutated exactly that and watched this phase pass.
  grep -q "usage: " "$WORK/out" \
    || fail "the refusal did not say what the arguments are: $(cat "$WORK/out")"
  ok "a mistyped flag is refused rather than read as a quiet run"

  # ...on STDERR, which run_copy cannot see because it folds the two streams.
  # A refusal on stdout is a refusal that a caller piping the run into a log
  # reads as output of the suite -- and `refuse()` is one line, so the `>&2` is
  # one deletion away from being gone for both of them.
  env -u AUTOFLEET_TEST_VERBOSE -u AUTOFLEET_TEST_NO_SKIP \
    "$WORK/tests/run.sh" --verbsoe >"$WORK/out" 2>"$WORK/err"
  [ "$?" = 2 ] || fail "the split-stream refusal did not exit 2"
  [ -s "$WORK/err" ] || fail "the refusal said nothing on stderr"
  [ -s "$WORK/out" ] && fail "the refusal went to stdout: $(cat "$WORK/out")"
  ok "...on stderr, where a refusal belongs"

  # ...and so is a third name. The runner has only ever had two positions, and
  # silently ignoring the rest is how `./tests/run.sh fleet card_says --verbose`
  # would have been read before the flag existed: as a run of one phase that
  # said nothing about the argument it dropped. Found by the spec review, which
  # noticed the refusal arrived with no row on it.
  run_copy quickd one three
  rc=$?
  [ "$rc" = 2 ] || fail "a third argument was ignored (rc=$rc): $(cat "$WORK/out")"
  grep -q "three" "$WORK/out" \
    || fail "the refusal did not name the argument it refused: $(cat "$WORK/out")"
  ok "...and a third positional argument is refused rather than dropped"

  # CI reads logs, not a context window: a human opening a failed run wants to
  # see which phases got there before it. The workflow asks for them, and this is
  # the row that notices if it stops -- the whole point of quiet is that nothing
  # else in this repo will.
  #
  # EVERY INVOCATION, and comments do not count -- both halves asserted rather
  # than approximated, because the first two drafts of this row got each of them
  # wrong in the cheap-looking way.
  #
  # Asking whether the FILE mentions the flag anywhere passes on the strength of
  # this row's counterpart comment in ci.yml. Asking whether ANY invocation
  # carries it passes while a second job runs the suite quietly -- and ci.yml is
  # owed exactly such a job, the strict AUTOFLEET_TEST_NO_SKIP one tests/run.sh
  # names as #80. Both found by /code-review.
  #
  # Then: `grep -v "^[[:space:]]*#"` drops a line only when `#` is its first
  # non-space character, so `./tests/run.sh   # --verbose would be nice` survives
  # the filter AND matches the flag -- in the comment. And `grep -c` counts
  # LINES, so `./tests/run.sh --verbose && ./tests/run.sh` is one loud line with
  # a quiet run inside it. Both found by the independent review, which pointed at
  # evals/lint.sh's `strip_comment` and said this was that function's first draft
  # again; it is borrowed here rather than re-derived.
  #
  # A VALUE is required of the variable: `AUTOFLEET_TEST_VERBOSE= ./tests/run.sh`
  # is a quiet run that mentions it. `="1"` counts, because a pattern rejecting
  # every quote reds a CI file that is correct -- the expensive direction.
  #
  # What it cannot see, in the false-RED direction, which is the one this row is
  # willing to be wrong in: a step- or job-level `env:` block (the normal YAML
  # way to set one), and a backslash line continuation between the variable and
  # the invocation. Both mean the same thing -- the flag has to be ON the
  # invocation. That is a real constraint on how ci.yml may spell it rather than
  # an oversight, and it is written into #80 where the person who writes that
  # line will read it.
  #
  # And two in the false-GREEN direction, worth naming rather than implying this
  # row is safe there. A job that reaches the suite INDIRECTLY -- `make test`, a
  # composite action, a wrapper script -- is invisible to anything grepping
  # ci.yml. So is a DIRECT one spelled from another working directory:
  # `cd tests && ./run.sh`, or the GitHub-native `working-directory: tests` with
  # `run: ./run.sh`, neither of which contains the path this matches on. In both
  # cases the honest job satisfies the `ci_runs > 0` floor on the quiet one's
  # behalf. Reading YAML with grep is the limit being accepted here; a second
  # route into the suite needs its own row. All found by /code-review.
  #
  # NOTE FOR WHOEVER EDITS THE BLOCK BELOW: it is a heredoc inside `$( )`, and
  # bash 3.2 -- the bash macOS ships -- tracks quotes across the whole command
  # substitution, heredoc body included. So a lone apostrophe anywhere in there,
  # in prose as readily as in code, is a SYNTAX ERROR on a mac and parses fine
  # on the bash 5 in CI. Reword around it -- "the first draft" carries what the
  # possessive would have. It cost a round of this review to find, by running
  # it; nothing asserts it, because asserting it needs a bash 3.2 and the
  # `bash -n` step in CI is bash 5.
  ci="$REPO_ROOT/.github/workflows/ci.yml"
  ci_report="$(python3 - "$ci" <<'CIPY'
import re, sys

def strip_comment(line):
    """The line with a trailing shell comment removed, quotes respected.

    Lifted from evals/lint.sh, where the docstring explains why cutting at the
    first `#` anywhere is wrong. Here the quoting matters less and the trailing
    comment matters more, but one spelling of this in the repo is worth more
    than two that drift.
    """
    out, quote = [], ""
    for ch in line:
        if not quote:
            if ch in "\"'":
                quote = ch
            elif ch == "#":
                break
        elif ch == quote:
            quote = ""
        out.append(ch)
    return "".join(out)

# The env prefix stays with its own invocation, which is the whole reason the
# line is split: `AUTOFLEET_TEST_VERBOSE=1 ./tests/run.sh && ./tests/run.sh`
# must read as one loud run and one quiet one, not as a loud line.
LOUD = re.compile(r"--verbose\b|AUTOFLEET_TEST_VERBOSE=[\"']?[^\s\"']")
# NOT `frag.count("./tests/run.sh")`. A second job spelled `bash tests/run.sh`,
# `sh tests/run.sh` or `"$GITHUB_WORKSPACE/tests/run.sh"` runs the suite just as
# quietly and was not counted at ALL -- which is the exact scenario the comment
# above claims this now catches, passing because the other job supplied the
# count. Found by /code-review.
# WHAT COUNTS AS AN INVOCATION. Two halves, and both of them were got wrong by
# describing them in prose instead of stating them:
#
#   the optional path prefix -- any run of characters ending in a slash that
#   holds no whitespace and none of `;&|`, so it may hold a command
#   substitution, a brace expansion, a quote or an equals sign. Earlier drafts
#   described it and were wrong: the spelling "$GITHUB_WORKSPACE/tests/run.sh"
#   is real and the first missed it, and excluding parentheses made
#   `$(pwd)/tests/run.sh` count ZERO.
#
#   what may precede the whole match -- a LOOKBEHIND rather than a list of
#   allowed characters, because every list written here was short. The last one
#   omitted the backtick, so `tests/run.sh` inside backticks scored zero: a
#   missed invocation raises neither counter, so the row stays green with a
#   quiet run in the file, which is the false green it exists to prevent. The
#   question is not "what may sit before a path" -- it is "is this the tail of a
#   LONGER WORD", so the class is the one a word is made of. `/` is deliberately
#   NOT in it: every legitimate prefix ends in one. Found by /code-review, in
#   four consecutive rounds, which is why neither half is described by counting
#   anything any more.
#
# It still cannot swallow mytests/run.sh: the character before is a letter. The
# cost is a false RED on prose that merely names the path inside a string, which
# is the direction this row is willing to be wrong in.
RUN = re.compile(r"(?<![A-Za-z0-9_.\-])(?:[^\s;&|]*/)?tests/run\.sh\b")
runs = quiet = 0
for line in open(sys.argv[1]):
    for frag in re.split(r"&&|\|\||;", strip_comment(line)):
        n = len(RUN.findall(frag))
        if not n:
            continue
        runs += n
        # Two invocations in one fragment with no separator between them is a
        # shape this cannot judge, so it is counted quiet: a false red that
        # names the line beats a green that assumed.
        if n > 1 or not LOUD.search(frag):
            quiet += n
print(runs, quiet)
CIPY
)"
  ci_runs="${ci_report%% *}"; ci_quiet="${ci_report##* }"
  [ "${ci_runs:-0}" -gt 0 ] \
    || fail "ci.yml no longer runs the suite; this row asserts nothing"
  [ "${ci_quiet:-1}" = 0 ] \
    || fail "$ci_quiet of ci.yml's $ci_runs suite invocations are quiet, so a failed run no longer says which phases ran"
  ok "every run of the suite in CI still asks for the per-phase lines"
  ;;

  *)
  echo "usage: $0 bounds|passes|skips|hostlint|guards|interrupt|orphans|quiet" >&2
  exit 2 ;;
esac
