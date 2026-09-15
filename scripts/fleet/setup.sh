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
# autofleet's own half is small: derive the worktree's identity, initialise
# submodules, and start the watcher that submits the agent's prompt. Everything
# that is about THIS project -- containers, fixtures, a build, a venv -- lives
# in `.autofleet/setup.sh` in the host repo, which this calls with .env already
# exported.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
. ./scripts/fleet/lib.sh

echo "==> deriving isolated worktree environment"
./scripts/fleet/env.sh
set -a; . ./.env; set +a

# BEFORE anything expensive, and before the watcher.
#
# `fleet.sh` and `agent-autostart.sh` both probe; this hook ran earliest of the
# three and probed last, which is the worst order available -- the runner holds
# the agent's tab until this returns (`setupAgentStartupPolicy: wait-for-setup`),
# so a runtime that is not answering surfaced as: submodules initialised,
# containers built, a watcher started, and then an agent tab that never receives
# a prompt, with the only explanation in a log nobody opens. The driver has
# already said what it tried and what to install; this adds the consequence.
# armaatus/autofleet#13.
#
# AFTER env.sh, not before it, and that order is the finding rather than a
# convenience. env.sh is milliseconds and it is where a machine that is missing
# its basic tools says so -- `no sha1 tool (shasum/sha1sum/python3)`. Probing
# first on such a machine answers with the runner instead: the deadline wrapper
# needs `mktemp`, every candidate fails for want of it, and a person is told to
# install Orca when what is actually wrong is their PATH. That is the same
# consequence-reported-as-cause this issue exists to remove, reintroduced by
# the fix for it. `tests/test_env.sh setup_fails_fast` is the phase that caught
# it. Everything the probe still guards -- submodules, the project hook, the
# watcher -- is below.
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

# Before the watcher, not after it. The project hook is the step that fails on a
# bad day -- an image pull with no network, a scan that never finishes -- and
# `set -e` means a failure here must not leave a watcher polling the runtime
# from a worktree nobody will ever work in.
if [ -n "${AUTOFLEET_SETUP_HOOK:-}" ] && [ -x "$AUTOFLEET_SETUP_HOOK" ]; then
  echo "==> $AUTOFLEET_SETUP_HOOK"
  "./$AUTOFLEET_SETUP_HOOK"
elif [ -n "${AUTOFLEET_SETUP_HOOK:-}" ] && [ -f "$AUTOFLEET_SETUP_HOOK" ]; then
  echo "!! $AUTOFLEET_SETUP_HOOK exists but is not executable; chmod +x it" >&2
  exit 1
else
  echo "==> no project setup hook ($AUTOFLEET_SETUP_HOOK); nothing project-specific to provision"
fi

# Detached, and last: the runner holds the agent's tab until this script
# returns, so the draft this watches for cannot exist yet. `nohup` with HUP
# ignored because the watcher has to outlive the hook that started it -- that is
# the whole point of it.
if [ "${AUTOFLEET_AGENT_AUTOSTART:-1}" != "0" ]; then
  ( trap "" HUP
    nohup ./scripts/fleet/agent-autostart.sh --watch \
      >>"$REPO_ROOT/.autofleet/run/agent-autostart.log" 2>&1 & ) &
  echo "==> watching for the agent's issue prompt to submit it"
fi

echo
echo "worktree ready."
echo "  project     $FLEET_PROJECT"
fleet_ports | sed 's/^/  port        /'
[ -n "${AUTOFLEET_TEST_COMMAND:-}" ] && echo "  tests       $AUTOFLEET_TEST_COMMAND"
exit 0
