#!/usr/bin/env bash
# autofleet's own suite.
#
#   ./tests/run.sh                 # everything
#   ./tests/run.sh fleet           # one suite
#   ./tests/run.sh fleet card_says # one phase of one suite
#
# The suites are shell, and several of them dispatch on a PHASE argument: one
# process per case, so a case that wedges cannot take the rest of the file with
# it and a failure names itself. That is why the phase lists live here as data
# rather than being discovered -- a registry something else can read is what
# lets evals/lint.sh assert that every phase a script defines is actually run.
# A phase defined in the script and missing from this list never executes, in
# this runner or in CI, and is indistinguishable from a phase that passes.
#
# A phase exits 0 for pass and any non-zero for fail, with ONE exception: exit 77
# means "this phase could not judge anything" and is reported as a skip. It is
# the autotools convention. A phase may only use it if it is named in SKIPPABLE
# below -- see the comment there for why a skip is a registry entry and not a
# decision the phase gets to make alone. AUTOFLEET_TEST_NO_SKIP=1 refuses even
# those, for a place where judging nothing is not an acceptable answer -- which
# is what a CI runner is, though nothing sets it there yet (#80), so do not read
# a green CI run as having been strict.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# `suite:phase phase ...`, or `suite:` for a script that runs whole.
SUITES=(
"lint:"
"env:concurrent readable python venv setup_fails_fast"
"teardown:derives reap watcher profiles mtime"
"runner_bound:bounds passes skips guards interrupt orphans"
"resolve_thread:last more partial green stopped"
"answer_review:posts thin unpushed behind no_review flight stopped gate"
"review_mode:sweeps mode refuses stopped submits unmarked silent skips stale midstop reaper timeout queue records status_count holds once retries capped stubwrite"
"fleet:foundation_holds foundation_break_is_local foundation_resays foundation_waiting_once foundation_closed_frees foundation_cold_start foundation_restart_speaks foundation_launch_held foundation_said_once foundation_one_lookup foundation_frees foundation_none foundation_blind foundation_cli_blind create_says create_warns card_says card_quiet remove_forces remove_advice remove_keeps_stack remove_sweeps_stack merged_keeps_dirty merged_keeps_owned merged_unknown_git merged_cli_silent remove_scoped_sweep stall_expected stall_reports timebox_waits timebox_stops queue_skips list_declines timebox_rearms labels_unknown outage_once one_lookup timebox_clears stop_clears own_clears one_card abandon_blocked abandon_closed abandon_human_step abandon_keeps_dirty abandon_keeps_commits abandon_unknown_git abandon_leaves_working abandon_timebox gaveup_not_restarted gaveup_retry abandon_warns_first abandon_warned_saved abandon_two_keeps gaveup_pruned list_says_declined abandon_reason_flickers abandon_lookup_blind status_stale status_current status_unrecorded status_from_worktree status_draining status_stopped status_drained status_behind status_behind_revert status_unreadable status_names_root run_refuses run_stale_recycled run_stale_gone status_recycled stop_spares_stranger stop_stops_dispatcher run_blind_ps status_blind_ps stop_blind_ps drain_ends_on_merge drain_after_stop stop_writes_drain stop_now_writes_both drain_lets_agents_finish stop_freezes_agents drain_launches_nothing resume_clears_both stop_drain_blind_dispatcher runner_stub runner_unresolved selector_git_unusable create_scoped live_scoped foundation_foreign status_worktree_scope reap_blind_upstream poll_empties_cache restart_after_parked_drain drain_parked_counted_once drain_ends_with_parked status_keeps_cache cap_ends_on_merge priority_first status_priority priority_renamed"
)

# The one suite that is not a tests/test_*.sh file: it is the vendored lint, and
# it is here so `./tests/run.sh` is the whole answer to "is this repo healthy".
suite_command() {
  case "$1" in
    lint) printf '%s\n' "./evals/lint.sh" ;;
    *)    printf '%s\n' "bash tests/test_$1.sh" ;;
  esac
}

want_suite="${1:-}"
want_phase="${2:-}"
pass=0; fail=0; failed=""
# A phase that could not judge anything is not a phase that judged and found
# nothing wrong, and it is not a failure either. `teardown/reap` says so twice:
# once when docker is not running, and once when the machine already carries an
# orphan stack, where sweeping for real would delete somebody else's work rather
# than the fixture. Both exit 77 -- the autotools convention, and the number
# test_teardown.sh has always used -- and this runner counted both as FAIL,
# because it read every non-zero the same way. That is the reading that teaches
# an agent its suite is red for a reason it cannot fix, on a machine detail that
# has nothing to do with its diff. Skips are reported, counted and printed with
# the phase's own reason, and they do not fail the run.
SKIP_RC=77
skipped=0; skips=""
# WHICH phases may say it. A skip code with no allowlist is hard rule 3 arriving
# through the door marked "not a failure": any phase that broke into exiting 77
# -- a bad `docker info` probe, a fixture guard inverted, an `exit $SKIP` written
# where `exit 1` was meant -- would be green in CI forever, visible only as a
# count in a line nobody greps. So the runner, not the phase, decides that a skip
# is legitimate here: an unlisted phase exiting 77 is a FAIL that says so.
#
# A registry rather than a label on the phase, for the same reason SUITES is a
# registry: a list something else can read is what lets a reviewer see, in one
# place, every phase that is allowed to judge nothing. ONE entry today, with two
# reasons behind it: test_teardown.sh reap declines when docker is not running,
# and again when the machine already carries an orphan stack a real sweep would
# destroy.
SKIPPABLE="teardown/reap"
# 0 = allowed. 1 = this phase is not on the list. 2 = skips are refused here,
# whatever the list says.
#
# A REASON, not a bare status, because the two refusals need different words and
# the caller cannot tell them apart from a shared 1: under AUTOFLEET_TEST_NO_SKIP
# a phase that genuinely BROKE into exiting 77 would be told "this run does not
# accept a phase that judged nothing" and never that it is missing from
# SKIPPABLE -- erasing the distinction in CI, which is the one place the variable
# is for and the hardest place to diagnose from. It also stops a third refusal
# reason inheriting whichever message was written last. Found by the independent
# review.
may_skip() {
  printf '%s\n' $SKIPPABLE | grep -qxF -- "$1" || return 1
  # Listed, and still refused HERE. "Machine state, not diff state" is true of a
  # laptop and false of a runner, where a missing docker is an infrastructure
  # regression and a green run with a count in it is how that goes unnoticed for
  # a month. The allowlist bounds WHICH phase may decline; this bounds WHERE. Off
  # by default: the local ergonomics are what #78 was about.
  [ -z "${AUTOFLEET_TEST_NO_SKIP:-}" ] || return 2
  return 0
}

# Every phase runs under a bound, because the failure this runner is worst at
# reporting is the one that produces nothing. CI run 34658821929 printed
# `ok review_mode/mode`, then nine minutes of silence, then exit 143 when the
# runner killed the job: no suite named, no phase named, and nothing in the log
# to read. A phase blocks on what a laptop has and a runner does not -- a tty, a
# login, an `orca` binary, a `read` with no input, a poll with no deadline -- or,
# as it turned out that time, on itself. Bounded, that is a FAIL that says which
# phase and how long it sat there.
#
# `timeout(1)` is coreutils and is not on macOS, and this suite has to run in
# both places, so the bound is built here out of a background job and a watcher.
# Generous on purpose: the phases wait on real background processes and their own
# `await` helpers already allow up to 120s, so this is the runner giving up, not
# a deadline anything is expected to meet. AUTOFLEET_TEST_TIMEOUT overrides it.
#
# What this does NOT rescue is a phase that forks rather than blocks: the one
# that caused run 34658821929 recursed through a command substitution, and by the
# time it mattered the machine had no process left to fork the watcher with. The
# bound catches a phase WAITING on something CI does not have; it is not a
# sandbox. Keep the phases from forking unboundedly on their own account.
PHASE_TIMEOUT="${AUTOFLEET_TEST_TIMEOUT:-180}"

# Validated, because the way a bad value fails is as a guard that inverts rather
# than one that complains: `sleep abc` returns AT ONCE, so the watchdog falls
# straight through to the kill and every phase in the run is reported BLOCKED
# with a duration of "abc". A mistyped env var would turn the whole suite red
# for a reason that points at nothing. Rejected at startup instead.
# Digits first, then a NUMERIC test for positive. `''|*[!0-9]*|0` rejected the
# literal `0` and let `00` through, which is all digits and is not that literal
# -- and `sleep 00` returns at once, so the bound went straight to the kill and
# reported every phase BLOCKED. One spare zero reopened the inverted guard this
# check exists to close. Found by the independent review.
case "$PHASE_TIMEOUT" in
  ''|*[!0-9]*)
    echo "AUTOFLEET_TEST_TIMEOUT must be a positive whole number of seconds;" \
         "got '$PHASE_TIMEOUT'" >&2
    exit 2 ;;
esac
[ "$PHASE_TIMEOUT" -gt 0 ] || {
  echo "AUTOFLEET_TEST_TIMEOUT must be a positive whole number of seconds;" \
       "got '$PHASE_TIMEOUT'" >&2
  exit 2; }

# A run where phase after phase blocks cannot be rescued by any bound: at 180s
# each, thirty of them exceed the 20-minute cap on the job that runs this
# (.github/workflows/ci.yml), and the log ends in the same exit 143 with most of
# the suite unreported. So the run gives up once this many have blocked. Three
# blocked phases is not a suite that was going to be green, and a complete log
# naming three is worth more than a truncated one naming eleven.
MAX_BLOCKED=3
blocked=0

# The runner's own children, so they can be reaped if the runner itself dies.
# Without this, a Ctrl-C or a cancelled CI job leaves the phase and the watchdog
# running -- and the watchdog then waits out its bound and issues a kill against
# a pid nobody owns any more. On a busy machine PHASE_TIMEOUT is long enough for
# that pid to have been reused, which makes this runner's cleanup a signal aimed
# at an unrelated process. Found by review.
RUNNING_PID=""; RUNNING_WATCHER=""
runner_cleanup() {
  [ -n "$RUNNING_WATCHER" ] && kill -TERM "$RUNNING_WATCHER" 2>/dev/null
  [ -n "$RUNNING_PID" ] && reap_tree "$RUNNING_PID"
  return 0
}
# EXIT gets the cleanup. INT and TERM get a handler that cleans up AND EXITS,
# which is the whole difference: bash resumes after a trap that merely returns,
# so one `trap 'runner_cleanup' EXIT INT TERM` reaped the running phase and then
# carried straight on into the next one. Ctrl-C stopped a phase and not the run,
# and finishing needed one per phase left -- about 150. Measured: the runner
# survived a SIGINT and completed five more phases.
#
# It is not a pre-existing wart either, it arrived with this change. Before it
# there was no trap and no `set -m`, so the phase shared the runner's process
# group and a single Ctrl-C at the terminal ended everything at once. Putting the
# phase in its own group is what took that away, and this is the half that has to
# give it back. A cancelled CI job is the same shape through TERM. Found by the
# independent review.
runner_interrupted() {
  runner_cleanup
  echo "  (interrupted; the rest of the run is not reported)"
  exit "$1"
}
trap 'runner_cleanup' EXIT
trap 'runner_interrupted 130' INT
trap 'runner_interrupted 143' TERM

# The watchdog behind PHASE_TIMEOUT, as a function so the `sleep` it waits on has
# a name. Killing the subshell alone reaps the subshell and ORPHANS that sleep:
# one per phase, ~135 reparented to init over a full run. Measured at 58 strays
# on the machine this was written on, where they went on to starve the fork this
# very watchdog needs -- which is the failure the note above is about, caused by
# the thing meant to catch it. Found by review.
phase_watchdog() {
  local target="$1" marker="$2" napper=

  # The trap goes in BEFORE the sleep is started, not after. The runner sends
  # TERM the moment the phase is reaped, and the phase is forked first -- so a
  # phase that dies instantly (a missing script, a syntax error) can land its
  # TERM in the gap and kill this watchdog with the default disposition, which
  # orphans the sleep for the whole bound. That is the leak this function exists
  # to close, reintroduced in the seam between two lines. Found by review.
  #
  # The sleep is backgrounded and `wait`ed on rather than run in the foreground,
  # because a foreground command defers traps until it returns -- which is the
  # whole reason for the extra process. Interrupted during `wait`, the trap runs
  # now and takes the sleep with it. `$napper` is empty until then and the kill
  # simply fails, which is the correct thing to do with a sleep never started.
  # INT as well as TERM, DEFENSIVELY -- and said plainly, because no case was
  # found where leaving it off actually leaks. The review reasoned that this
  # watchdog is forked after `set +m`, so it sits in the runner's process group
  # and a terminal Ctrl-C reaches it with the default disposition, orphaning its
  # sleep. The first half is true; the leak is not, and both ways of delivering
  # the signal say so. A GROUP interrupt reaches the sleep too -- it is a child
  # of this subshell and in the same group -- so it dies of the signal whether
  # this trap exists or not. An interrupt aimed at the runner alone never reaches
  # this process, and the runner's own cleanup TERMs it a moment later, which the
  # TERM half already handles. `interrupt` asserts no strays survive either way
  # and passes with INT removed here; it is not pinned, and it is kept because it
  # costs nothing and closes the case neither delivery covers.
  trap 'kill -9 "$napper" 2>/dev/null; exit 0' TERM INT
  sleep "$PHASE_TIMEOUT" & napper=$!
  wait "$napper" 2>/dev/null

  # The marker goes down BEFORE the kill, not after. After it, the runner's
  # `wait` returns the instant the phase dies and the runner kills this watchdog
  # -- and losing that race means a phase killed at the bound reports as an
  # ordinary FAIL with no BLOCKED line and no duration: the nameless failure the
  # bound exists to remove, back again and now intermittent. Found by review.
  : >"$marker"
  reap_tree "$target"
}

# Every process descended from `$1`, deepest first, then `$1` itself.
#
# `kill` on the phase alone leaves its children reparented to init, and two
# phases in test_review_mode.sh (`timeout`, `midstop`) ask `pgrep` a MACHINE-WIDE
# question about exactly such a child: a `sleep 3607` left by one bounded phase
# failed a later, unrelated phase with "the wedged reviewer's own child outlived
# the kill". That is the misattribution this whole change exists to remove,
# reintroduced by the thing removing it. Found by review.
#
# The process group is not enough on its own. `review.sh` deliberately puts the
# reviewer in its OWN group so it can signal it, so the descendant this most
# needs to reach is in a group of its own by design -- measured: a group kill
# still left one stray. So the tree is walked instead, and it is walked BEFORE
# anything is signalled, because after the first kill the survivors have been
# reparented to init and no longer name their real parent.
reap_tree() {
  local root="$1" queue="$1" pid kid kids all=""
  while [ -n "$queue" ]; do
    pid="${queue%% *}"
    case "$queue" in *" "*) queue="${queue#* }" ;; *) queue="" ;; esac
    kids="$(ps -A -o pid=,ppid= 2>/dev/null | awk -v p="$pid" '$2 == p { print $1 }')"
    for kid in $kids; do
      all="$kid $all"          # deepest first, so a parent cannot respawn one
      queue="$queue $kid"
    done
  done
  for pid in $all; do kill -9 "$pid" 2>/dev/null; done
  # The group too, for anything forked between the walk and here, and then the
  # phase itself. Both may fail; both failing is the normal case.
  kill -9 -- -"$root" 2>/dev/null
  kill -9 "$root" 2>/dev/null
  return 0
}

# What the phase printed, indented under the row that reports it. Four copies of
# one `sed` in run_one, which is three chances for the next one to indent by a
# different amount.
show_output() { sed 's/^/       /' "$1"; }

# One spelling of a failing phase. There are two ways to reach it and they were
# two copies of the same three lines.
report_fail() {
  fail=$((fail + 1)); failed="$failed $1"
  printf '  FAIL %s\n' "$1"
}

run_one() {
  local label="$1"; shift
  local out="/tmp/autofleet-suite.$$" marker="/tmp/autofleet-suite.$$.blocked"
  local rc=0 pid watcher skip_refusal=0
  rm -f "$marker"

  # The phase's output goes to a FILE, not a pipe. A pipe would keep this runner
  # waiting on any grandchild that inherited the write end -- the reviewer stubs
  # spawn `sleep`s on purpose -- so killing the phase would not end the wait.
  # `set -m` gives the phase its own process group, so the watchdog's kill can
  # take the phase's children with it. Turned straight back off: job control in a
  # non-interactive shell also prints a notice per job, which is noise about this
  # runner rather than about the phase.
  set -m
  "$@" >"$out" 2>&1 &
  pid=$!
  RUNNING_PID="$pid"
  set +m
  # The watchdog holds neither the output file nor stdin, for the same reason.
  phase_watchdog "$pid" "$marker" >/dev/null 2>&1 </dev/null &
  watcher=$!
  # Each recorded AS it is forked, not both once the pair is up: an interrupt
  # landing in that two-line window left the phase unreaped, in a process group
  # the terminal cannot reach. The same "reopened in the seam between two lines"
  # as the watchdog's own trap. Found by the independent review.
  RUNNING_WATCHER="$watcher"
  # stderr silenced only around the reap: killing the job makes the shell
  # announce it ("line NN: 1234 Killed: 9 ..."), which is noise pointing at this
  # runner rather than at the phase that blocked. The phase's own output went to
  # "$out" and is printed below.
  wait "$pid" 2>/dev/null; rc=$?
  # TERM, not KILL: the watchdog traps it and takes its sleep down with it.
  kill -TERM "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null
  RUNNING_PID=""; RUNNING_WATCHER=""

  # Both conditions, not the marker alone. The marker is written just before the
  # kill, so a phase that finished on its own in that window leaves one behind
  # having passed. A phase that exited 0 was not blocked, whatever the marker
  # says, and a false BLOCKED is the kind of flake that teaches people to re-run.
  # ...and not 77 either, for the same reason as `rc = 0`: a phase that exited
  # 77 EXITED, and a killed one comes back 137. Without this a wedged docker
  # daemon letting `docker info` return in the window where the marker is written
  # reports `teardown/reap` as BLOCKED, and counts it toward MAX_BLOCKED, for a
  # phase that was never killed. The comment above exempted the pass and stopped
  # there. Found by /code-review.
  if [ -e "$marker" ] && [ "$rc" != 0 ] && [ "$rc" != "$SKIP_RC" ]; then
    blocked=$((blocked + 1))
    report_fail "$label"
    printf '       BLOCKED: produced no result in %ss and was killed.\n' "$PHASE_TIMEOUT"
    printf '       Output up to that point:\n'
    show_output "$out"
  elif [ "$rc" = 0 ]; then
    pass=$((pass + 1))
    printf '  ok   %s\n' "$label"
  elif [ "$rc" = "$SKIP_RC" ] && { may_skip "$label"; skip_refusal=$?; [ "$skip_refusal" = 0 ]; }; then
    # The phase's own output carries WHY, and it is the half that matters: a
    # silent `skip` line is indistinguishable from a phase quietly opting out of
    # ever running again.
    skipped=$((skipped + 1)); skips="$skips $label"
    printf '  skip %s\n' "$label"
    show_output "$out"
  elif [ "$rc" = "$SKIP_RC" ]; then
    # 77 from a phase that was not allowed to say it. Which refusal it was decides
    # the words: "add it to SKIPPABLE" and "nothing may skip here" send the reader
    # to different places, and a phase that BROKE into exiting 77 needs the first
    # one even under the second.
    report_fail "$label"
    if [ "$skip_refusal" = 1 ]; then
      printf '       exited %s (skip), but %s is not in SKIPPABLE in tests/run.sh.\n' \
        "$SKIP_RC" "$label"
      printf '       Either the phase is broken, or the skip is legitimate and belongs\n'
      printf '       in that list where a reviewer can see it.\n'
    else
      # Nothing to add to a list here: the run was told that skipping is not an
      # acceptable answer in this place, and a message about SKIPPABLE would send
      # the reader to edit a list that is not what refused them.
      printf '       exited %s (skip), and AUTOFLEET_TEST_NO_SKIP is set: this run\n' "$SKIP_RC"
      printf '       does not accept a phase that judged nothing.\n'
    fi
    show_output "$out"
  else
    report_fail "$label"
    show_output "$out"
  fi
  rm -f "$out" "$marker"
}

# Asked after EVERY run_one, in both branches. Checking it only inside the phase
# loop left a whole-suite entry (`lint:`) able to block, increment the counter
# and never trigger the give-up -- so the note above overstated what it covered.
# Harmless at one whole-suite entry against a cap of 3, and still wrong. Found by
# the independent review.
give_up_if_blocked() {
  [ "$blocked" -ge "$MAX_BLOCKED" ] || return 1
  echo "  (giving up: $blocked phases blocked at ${PHASE_TIMEOUT}s each."
  echo "   The rest of the run is not reported. See the BLOCKED lines above.)"
  return 0
}

# Said once, where the run stops, rather than per phase.
gave_up=0
for entry in "${SUITES[@]}"; do
  [ "$gave_up" = 0 ] || break
  suite="${entry%%:*}"
  phases="${entry#*:}"
  [ -z "$want_suite" ] || [ "$want_suite" = "$suite" ] || continue
  echo "== $suite"
  # shellcheck disable=SC2046 -- suite_command is a deliberate word list
  if [ -z "${phases// /}" ]; then
    [ -z "$want_phase" ] || { echo "  (no phases; ignoring '$want_phase')"; }
    run_one "$suite" $(suite_command "$suite")
    give_up_if_blocked && gave_up=1
  else
    for phase in $phases; do
      [ -z "$want_phase" ] || [ "$want_phase" = "$phase" ] || continue
      run_one "$suite/$phase" $(suite_command "$suite") "$phase"
      give_up_if_blocked && { gave_up=1; break; }
    done
  fi
done

echo
# Named in both summaries. A count of skips in the green line is what makes a
# phase that stopped running visible without reading the whole log for it.
# Each list behind the name of what it lists. Two lists behind two bare colons
# read as one run of names and the reader cannot tell which is which -- found by
# the standards review, which reproduced `1 failed, 0 passed, 1 skipped: skipper:
# failer` and could not say which name had failed.
skip_note=""
[ "$skipped" -gt 0 ] && skip_note=", $skipped skipped (${skips# })"
if [ "$fail" -gt 0 ]; then
  echo "$fail failed, $pass passed$skip_note. failed:$failed" >&2
  exit 1
fi
# A run that is ALL skips still ran nothing worth trusting, but it is not the
# "check the suite or phase name" typo this is here to catch -- the phases were
# found, they declined. Both are reported; only the typo is exit 2.
[ "$pass" -gt 0 ] || [ "$skipped" -gt 0 ] \
  || { echo "nothing ran; check the suite or phase name" >&2; exit 2; }
echo "$pass passed$skip_note."
