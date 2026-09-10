#!/usr/bin/env bash
# Put this worktree's card on the board: a status, and the one line it shows.
#
#   ./scripts/fleet/board.sh in-review "#12: PR #40, waiting on review"
#   ./scripts/fleet/board.sh --comment "#12: needs you -- 3 review rounds"
#
# The dispatcher cards the worktrees it owns from fleet.sh; this is the same
# thing from INSIDE one, which is the only form an agent can use -- and the
# reason it exists as a script at all. The brief in issue-command.sh used to
# hand the agent an `orca` command line, which put the runner's name in the one
# document every agent reads and made the seam a convention rather than a fact.
#
# Non-fatal by design, and it says so rather than failing the step it is part
# of: the board is a display, and a display that cannot be written is not a
# reason for an agent to stop working. It still exits non-zero, so a caller that
# does care can tell.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
. ./scripts/fleet/lib.sh

status=""
comment=""
case "${1:-}" in
  --comment) comment="${2:-}" ;;
  ""|-h|--help)
    cat >&2 <<USAGE
usage: board.sh <workspace-status> "<comment>"
       board.sh --comment "<comment>"

  workspace-status  what the card says this worktree is doing --
                    in-progress, in-review, completed
USAGE
    exit 2 ;;
  *) status="$1"; comment="${2:-}" ;;
esac

runner_available || { echo "board.sh: no runner answers here; the card is unchanged" >&2; exit 1; }

# The card is addressed by PATH, and $REPO_ROOT is bash's logical pwd -- it keeps
# whatever symlinked prefix the agent's shell had. If that differs from the path
# the runtime recorded for this worktree, every update from inside it fails. The
# assumption is not new: `agent-autostart.sh` has matched the runtime's
# `worktreePath` against this same derivation since it was written, in every
# worktree the fleet has opened. It is written down because the failure would
# otherwise look like a runner problem, and because the previous form -- the
# runner resolving "the active worktree" from the calling terminal -- could not
# be wrong. Raised by the independent review; the refusal below is loud for it.

# Status and comment in ONE call, which is why the driver takes pairs: sent
# separately, a failure between them leaves the board carrying a new status with
# the previous line under it.
args=()
[ -n "$status" ]  && args+=(workspace-status "$status")
[ -n "$comment" ] && args+=(comment "$comment")
[ "${#args[@]}" -gt 0 ] || { echo "board.sh: nothing to set" >&2; exit 2; }

if out="$(runner_worktree_set "$REPO_ROOT" "${args[@]}" 2>&1)"; then
  echo "board: ${status:+$status; }${comment}"
  exit 0
fi
echo "board.sh: the card was NOT updated -- the board is showing something older" >&2
[ -n "$out" ] && printf '  %s\n' "$out" >&2
exit 1
