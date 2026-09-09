#!/usr/bin/env bash
# What a worktree of THIS repo needs before an agent can work in it.
#
# The project half of the setup hook: scripts/fleet/setup.sh has already derived
# the worktree's identity and exported .env by the time this runs, and its exit
# status is provisioning's exit status. autofleet itself needs almost nothing --
# which is the point of the seam. A project with containers, fixtures and a
# build puts all of that here, and scripts/fleet/ never learns about it.
set -euo pipefail

echo "==> checking the tools the suite needs"
missing=""
for tool in git gh python3; do
  command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
if [ -n "$missing" ]; then
  echo "!! missing:$missing -- the suite cannot run without them" >&2
  exit 1
fi

# Cheap, and it is the check that catches a broken vendored payload before an
# agent spends an hour on top of it.
echo "==> shell payload parses"
for script in scripts/fleet/*.sh scripts/fleet/runner/*.sh; do
  bash -n "$script" || { echo "!! $script does not parse" >&2; exit 1; }
done
