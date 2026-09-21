#!/usr/bin/env bash
# Worktree setup hook -- runs once when a worktree is created.
#
# Prepares an isolated, ready-to-work environment so the agent's first test run
# means something. The runner holds the agent's tab until this returns (Orca:
# `setupAgentStartupPolicy: wait-for-setup`), so nothing here needs to be fast
# -- it needs to be complete. An agent that can run the tests before the rig is
# up reads the connection error as a code bug and goes chasing it; the seconds
# this costs buy away that whole failure mode.
#
# autofleet's own half is small: derive the worktree's identity and initialise
# submodules. It does NOT start the agent -- see the closing stanza for who
# does, which differs by who opened the worktree. Everything that is about THIS
# project -- containers, fixtures, a build, a venv -- lives in
# `.autofleet/setup.sh` in the host repo, which this calls with .env already
# exported.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
. ./scripts/fleet/lib.sh

echo "==> deriving isolated worktree environment"
./scripts/fleet/env.sh
set -a; . ./.env; set +a

# BEFORE anything expensive.
#
# `fleet.sh` and `board.sh` both probe; this hook ran earliest of the three and
# probed last, which is the worst order available -- the dispatcher waits for
# this to return before it starts a build, so a runtime that is not answering
# surfaced as: submodules initialised, containers built, and then a worktree
# nothing runs in, with the only explanation in a log nobody opens. The driver
# has already said what it tried and what to install; this adds the
# consequence. armaatus/autofleet#13.
#
# AFTER env.sh, not before it, and that order is the finding rather than a
# convenience. env.sh is milliseconds and it is where a machine that is missing
# its basic tools says so -- `no sha1 tool (shasum/sha1sum/python3)`. Probing
# first on such a machine answers with the runner instead: the deadline wrapper
# needs `mktemp`, every candidate fails for want of it, and a person is told to
# install Orca when what is actually wrong is their PATH. That is the same
# consequence-reported-as-cause this issue exists to remove, reintroduced by
# the fix for it. `tests/test_env.sh setup_fails_fast` is the phase that caught
# it. Everything the probe still guards -- submodules and the project hook --
# is below.
#
# It is FATAL rather than a warning: everything this hook exists to prepare is
# for an agent the runner is supposed to start, and provisioning a worktree
# whose agent cannot be reached spends the time and holds the slot for nothing.
# SAID BEFORE THE PROBE, because the probe is the one thing here that can be
# slow and silent. How slow is the driver's business and not this script's: a
# driver bounds each candidate it tries, and every candidate that is INSTALLED
# AND WEDGED costs that bound, while a candidate that is simply absent costs
# nothing. The expensive case is an app mid-start, not the common Mac with no
# Orca. That is at the exact point #13's Design notes name -- the runner holds
# the agent's tab and nothing has printed a reason yet. This does not shorten
# the wait; it stops the wait from looking like a hang. Raised by the
# independent review, and narrowed by the self-review, which caught the first
# wording asserting one driver's candidate count from a driver-agnostic file.
# WHAT A REFUSAL HERE LEAVES BEHIND, because this is where the next reader is
# standing: on this path the worktree already exists, is owned, and is carded
# `in-progress` -- `launch` created and carded it before invoking this hook and
# does not read its exit status -- so stopping here aborts provisioning of a
# worktree that is already open. #13's Acceptance carries it; this is the line
# that says so from the code. Raised by the self-review.
echo "==> checking the $AUTOFLEET_RUNNER runner"
fleet_require_runner
runner_available || {
  echo "!! the $AUTOFLEET_RUNNER runner is not usable here (why, above)" >&2
  echo "   everything below provisions a worktree for an agent the runner has to start, so setup stops here" >&2
  exit 1
}

# A git worktree does not inherit initialised submodules from the checkout it
# was made from, and CI usually checks out with `submodules: recursive` -- so a
# worktree whose issue touches a submodule would otherwise start by finding the
# dependency absent and reaching for a clone. Harmless and instant when there
# are none.
if [ -f .gitmodules ]; then
  echo "==> initialising submodules"
  git submodule update --init --recursive
fi

# LAST of the provisioning steps, and that order outlived its first reason. It
# was "before the watcher": the project hook is the step that fails on a bad
# day -- an image pull with no network, a scan that never finishes -- and under
# `set -e` a failure here must not leave a watcher polling the runtime from a
# worktree nobody will ever work in. #151 deleted the watcher; the ordering
# still holds, because the stanza below tells a person what to run and a hook
# that died owes them that line before they read it as an invitation.
if [ -n "${AUTOFLEET_SETUP_HOOK:-}" ] && [ -x "$AUTOFLEET_SETUP_HOOK" ]; then
  echo "==> $AUTOFLEET_SETUP_HOOK"
  "./$AUTOFLEET_SETUP_HOOK"
elif [ -n "${AUTOFLEET_SETUP_HOOK:-}" ] && [ -f "$AUTOFLEET_SETUP_HOOK" ]; then
  echo "!! $AUTOFLEET_SETUP_HOOK exists but is not executable; chmod +x it" >&2
  exit 1
else
  echo "==> no project setup hook ($AUTOFLEET_SETUP_HOOK); nothing project-specific to provision"
fi

# THE AGENT IS NOT STARTED HERE. It used to be: the runtime opened a tab with
# the brief drafted in it and a watcher this hook spawned pressed Return. The
# dispatcher starts the build itself now (`fleet.sh`'s `start_build`), which is
# what makes a build that will not start fail the launch out loud instead of
# leaving a provisioned worktree sitting on an unsent prompt.

echo
echo "worktree ready."
echo "  project     $FLEET_PROJECT"
fleet_ports | sed 's/^/  port        /'
[ -n "${AUTOFLEET_TEST_COMMAND:-}" ] && echo "  tests       $AUTOFLEET_TEST_COMMAND"

# WHO STARTS THE AGENT, said where the person who has to do it is looking.
#
# `start_build` covers the worktrees the dispatcher opened and nothing covers
# the rest: a person opening one through the app gets a provisioned worktree, a
# prompt drafted in a tab, and no watcher to press Return -- which is, word for
# word, the failure `runner/orca.sh` gives as the reason #151 was made, reached
# now by succeeding instead of by failing. Observed on 2026-09-21: four and a
# half hours on an unsent prompt. armaatus/autofleet#156.
#
# The MARKER IS THE DISPATCHER'S, not the runner's. Asking which driver is
# configured answers a different question -- `headless` is the default
# everywhere, including in a worktree a person opened by hand -- and asking the
# app whether it drafted anything makes this hook's output depend on a runtime
# the headless path does not have. `launch` sets the variable in the one place
# that knows a build is about to be started.
if [ -z "${AUTOFLEET_DISPATCHER_LAUNCH:-}" ]; then
  # A dispatcher-opened branch begins with its issue number, and a person's
  # does not. A PLACEHOLDER rather than a guess: the number is the one part of
  # this line a reader cannot check, and a wrong one sends them to somebody
  # else's issue with no sign anything is off.
  issue="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || issue=""
  issue="${issue##*/}"
  case "$issue" in
    [0-9]*) issue="${issue%%-*}" ;;
    *)      issue="<issue>" ;;
  esac
  echo "  agent       NOT started -- no dispatcher opened this worktree."
  echo "              Start it here, in the agent's tab:"
  echo "                GH_PAGER=cat ./scripts/fleet/issue-command.sh $issue"
  echo "              and follow what it prints. Nothing else will submit one."
fi
exit 0
