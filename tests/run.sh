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
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# `suite:phase phase ...`, or `suite:` for a script that runs whole.
SUITES=(
"lint:"
"env:concurrent readable python venv setup_fails_fast"
"teardown:derives reap watcher profiles"
"resolve_thread:last more partial green stopped"
"answer_review:posts thin unpushed behind no_review flight stopped gate"
"review_mode:mode refuses stopped submits unmarked silent skips stale midstop reaper timeout queue"
"fleet:create_scoped live_scoped foundation_foreign status_worktree_scope foundation_holds foundation_break_is_local foundation_resays foundation_waiting_once foundation_closed_frees foundation_cold_start foundation_restart_speaks foundation_launch_held foundation_said_once foundation_one_lookup foundation_frees foundation_none foundation_blind foundation_cli_blind card_says card_quiet remove_forces remove_advice remove_keeps_stack remove_sweeps_stack merged_keeps_dirty merged_keeps_owned merged_unknown_git merged_cli_silent remove_scoped_sweep stall_expected stall_reports timebox_waits timebox_stops queue_skips list_declines timebox_rearms labels_unknown outage_once one_lookup timebox_clears stop_clears own_clears one_card abandon_blocked abandon_closed abandon_human_step abandon_keeps_dirty abandon_keeps_commits abandon_unknown_git abandon_leaves_working abandon_timebox gaveup_not_restarted gaveup_retry abandon_warns_first abandon_warned_saved abandon_two_keeps gaveup_pruned list_says_declined abandon_reason_flickers abandon_lookup_blind status_stale status_current status_unrecorded status_from_worktree status_draining status_stopped status_drained status_behind status_behind_revert status_unreadable status_names_root run_refuses run_stale_recycled run_stale_gone status_recycled stop_spares_stranger stop_stops_dispatcher run_blind_ps status_blind_ps stop_blind_ps drain_ends_on_merge drain_after_stop stop_writes_drain stop_now_writes_both drain_lets_agents_finish stop_freezes_agents drain_launches_nothing resume_clears_both stop_drain_blind_dispatcher"
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

run_one() {
  local label="$1"; shift
  if "$@" >/tmp/autofleet-suite.$$ 2>&1; then
    pass=$((pass + 1))
    printf '  ok   %s\n' "$label"
  else
    fail=$((fail + 1)); failed="$failed $label"
    printf '  FAIL %s\n' "$label"
    sed 's/^/       /' /tmp/autofleet-suite.$$
  fi
  rm -f /tmp/autofleet-suite.$$
}

for entry in "${SUITES[@]}"; do
  suite="${entry%%:*}"
  phases="${entry#*:}"
  [ -z "$want_suite" ] || [ "$want_suite" = "$suite" ] || continue
  echo "== $suite"
  # shellcheck disable=SC2046 -- suite_command is a deliberate word list
  if [ -z "${phases// /}" ]; then
    [ -z "$want_phase" ] || { echo "  (no phases; ignoring '$want_phase')"; }
    run_one "$suite" $(suite_command "$suite")
  else
    for phase in $phases; do
      [ -z "$want_phase" ] || [ "$want_phase" = "$phase" ] || continue
      run_one "$suite/$phase" $(suite_command "$suite") "$phase"
    done
  fi
done

echo
if [ "$fail" -gt 0 ]; then
  echo "$fail failed, $pass passed:$failed" >&2
  exit 1
fi
[ "$pass" -gt 0 ] || { echo "nothing ran; check the suite or phase name" >&2; exit 2; }
echo "$pass passed."
