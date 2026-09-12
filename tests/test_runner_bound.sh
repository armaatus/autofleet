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
#   test_runner_bound.sh orphans  ...and the watchdog takes its `sleep` with it.
#                                 `kill` on the subshell alone reaps the subshell
#                                 and orphans the sleep, one per phase -- 58
#                                 strays were measured on the machine this was
#                                 written on, and they went on to starve the
#                                 fork the watchdog itself needs. The guard
#                                 against running out of processes cannot be the
#                                 thing consuming them.
#
# It drives a COPY of the real tests/run.sh rather than restating its logic, so
# there is no second implementation of the bound to drift from the shipped one.
# The copy gets its own throwaway suites; nothing here runs a real phase.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "  ok: $*"; }

WORK=""
cleanup() {
  # Belt and braces. The `bounds` phase ASSERTS that the runner reaped the
  # fixture's sleep, so this should find nothing -- but a run that failed that
  # assertion, or died before reaching it, must not leave the stray behind: this
  # file would then be causing the machine-wide contamination it is here to
  # catch, and the next phase to ask `pgrep` a question would pay for it.
  [ -n "$WORK" ] && { pkill -9 -f "sleep $BLOCK_NAP" 2>/dev/null; rm -rf "$WORK"; }
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

# A copy of the real runner, with two throwaway suites spliced into its registry.
make_runner() {
  WORK="$(mktemp -d)"; WORK="$(cd "$WORK" && pwd -P)"
  mkdir -p "$WORK/tests"
  # REPO_ROOT inside run.sh derives from its own path, so the copy looks for
  # tests/test_<suite>.sh next to itself and finds only the fixtures below.
  awk '{ print }
       /^SUITES=\(/ { print "\"blocker:\""; print "\"quick:\"" }' \
    "$REPO_ROOT/tests/run.sh" >"$WORK/tests/run.sh"
  chmod +x "$WORK/tests/run.sh"

  # Blocks forever, after saying something first: the partial output is half of
  # what a BLOCKED report is for.
  # `set -m` puts the sleep in its OWN process group, which is what `review.sh`
  # does with the reviewer so it can signal it. That is the hard case: a group
  # kill aimed at the phase does not reach it, and only walking the descendant
  # tree does. Measured -- a group kill alone left one stray here.
  cat >"$WORK/tests/test_blocker.sh" <<EOF
#!/usr/bin/env bash
echo "got this far before wedging"
set -m
sleep $BLOCK_NAP &
wait
EOF
  cat >"$WORK/tests/test_quick.sh" <<'EOF'
#!/usr/bin/env bash
echo "finished on time"
exit 0
EOF
  chmod +x "$WORK/tests/test_blocker.sh" "$WORK/tests/test_quick.sh"
}

case "${1:-}" in

# ----------------------------------------------------------------- bounds
  bounds)
  make_runner
  started="$(date +%s)"
  AUTOFLEET_TEST_TIMEOUT=3 "$WORK/tests/run.sh" blocker >"$WORK/out" 2>&1
  rc=$?
  elapsed=$(( "$(date +%s)" - started ))

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
  make_runner
  AUTOFLEET_TEST_TIMEOUT=3 "$WORK/tests/run.sh" quick >"$WORK/out" 2>&1
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

# ---------------------------------------------------------------- orphans
  orphans)
  make_runner
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

  *)
  echo "usage: $0 bounds|passes|orphans" >&2
  exit 2 ;;
esac
