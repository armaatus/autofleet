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
run_copy() {
  AUTOFLEET_TEST_NO_SKIP= AUTOFLEET_TEST_TIMEOUT=10 \
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
  make_runner quick
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

  grep -q "1 skipped" "$WORK/out" \
    || fail "the summary did not count the skip: $(cat "$WORK/out")"
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
  AUTOFLEET_TEST_NO_SKIP=1 AUTOFLEET_TEST_TIMEOUT=10 "$WORK/tests/run.sh" >"$WORK/out" 2>&1
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
  AUTOFLEET_TEST_NO_SKIP="" AUTOFLEET_TEST_TIMEOUT=10 "$WORK/tests/run.sh" >"$WORK/out" 2>&1
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
  AUTOFLEET_TEST_NO_SKIP=1 AUTOFLEET_TEST_TIMEOUT=10 "$WORK/tests/run.sh" >"$WORK/out" 2>&1
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

  # ...and the caller turns that into silence rather than a green line.
  grep -q 'elif \[ "\$?" = 77 \]' "$REPO_ROOT/evals/lint.sh" \
    || fail "evals/lint.sh no longer gives the skip its own branch; a host repo now gets ok or FAIL"
  ok "...and the lint gives that its own branch rather than an ok"

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

  *)
  echo "usage: $0 bounds|passes|skips|hostlint|guards|interrupt|orphans" >&2
  exit 2 ;;
esac
