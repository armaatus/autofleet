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
