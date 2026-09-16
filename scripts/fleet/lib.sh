#!/usr/bin/env bash
# Shared helpers for the autofleet hooks. Sourced, never executed.
#
# Every caller sets REPO_ROOT and cds to it before sourcing this, because the
# config below is read relative to the repo being driven, not to autofleet.

# The knobs and their defaults, and then the host repo's overrides. First,
# because everything under it reads them.
. "$(dirname "${BASH_SOURCE[0]}")/config.sh"

# The agent autostart watcher, which outlives setup.sh and is the one thing a
# worktree removal has to stop that is not a container. Two callers with opposite
# timing: archive.sh runs INSIDE the worktree and reads the pidfile as it goes,
# while fleet.sh has to read it before a removal it may not get and signal only
# after one it did -- so reading and stopping are separate.
#
# The identity check is why this is shared rather than copied: a pidfile outlives
# a `kill -9` and a reboot, and signalling a recycled pid means signalling an
# unrelated process of the user's. One copy of that reasoning, not two.
#
# Non-zero means nothing was signalled, so a caller can report only a real stop.
fleet_read_autostart_watcher() {
  cat "$1/.autofleet/run/agent-autostart.pid" 2>/dev/null || true
}
fleet_stop_autostart_watcher() {
  local pid="${1:-}"
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  # `grep` without `-q`: every caller of this sources lib.sh under `pipefail`
  # (fleet.sh, issue-command.sh), and `-q` exits on the first match, so `ps` can
  # write into a closed pipe and the pipeline is 141 for a probe that MATCHED.
  # `|| return 1` then reads that as "this pid is not the watcher", the watcher
  # is never signalled, and `|| true` at the callsite hides it. CLAUDE.md carries
  # the rule. Found by the independent review, which also pointed out that the
  # sourced file is the one the detector could not see.
  ps -o command= -p "$pid" 2>/dev/null | grep 'agent-autostart' >/dev/null || return 1
  kill "$pid" 2>/dev/null || true
  return 0
}

# A worktree's identity -- its compose project name and its port offset -- is a
# pure function of its absolute path. env.sh writes the result to .env when the
# worktree is created; teardown recomputes it instead of reading .env back.
#
# That asymmetry is deliberate. .env is generated, gitignored, and written by a
# hook that can itself fail half way, so teardown must not depend on it: an
# absent or truncated COMPOSE_PROJECT_NAME sends `docker compose down` to the
# compose default and leaves this worktree's containers, volumes and network
# running under `restart: unless-stopped`, holding its ports, with nothing left
# on disk to identify them by. Observed on rommsync-nx, which is where this
# framework came from (armaatus/rommsync-nx#163).
#
# Returns non-zero rather than exiting if no SHA-1 tool is available: under
# `set -e` an aborting derivation would guarantee the very leak it exists to
# prevent, so callers get to fall back on .env instead.
fleet_derive_env() {
  local root="$1" hex=""

  # sha1 of the path, first two bytes, mod 2000 -- kept bit-for-bit compatible
  # with the python implementation this replaces, because changing it would
  # rename every existing stack out from under the worktree that created it.
  # Shelling out to a hash tool rather than python3 keeps teardown working on a
  # machine where the interpreter has gone away.
  if command -v shasum >/dev/null 2>&1; then
    hex="$(printf %s "$root" | shasum -a 1 | cut -c1-4)"
  elif command -v sha1sum >/dev/null 2>&1; then
    hex="$(printf %s "$root" | sha1sum | cut -c1-4)"
  elif command -v python3 >/dev/null 2>&1; then
    hex="$(python3 -c "
import hashlib,sys
print(hashlib.sha1(sys.argv[1].encode()).hexdigest()[:4])
" "$root")"
  fi
  case "$hex" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;; *) return 1 ;; esac

  fleet_slug="$(basename "$root" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//;s/-$//')"
  fleet_offset=$(( 0x$hex % ${AUTOFLEET_PORT_SPAN:-2000} ))
  # The offset is part of the name, not just the ports: two worktrees whose leaf
  # directory names collide (a checkout and a worktree of the same repo) would
  # otherwise share a compose project, and the second `up -d` would adopt and
  # recreate the first's containers and database.
  fleet_project="${AUTOFLEET_PROJECT_PREFIX:-af}-${fleet_slug}-${fleet_offset}"
}

# The ports this worktree owns, as `NAME=PORT` lines.
#
# autofleet does not know what a project's rig listens on, so it hands out an
# OFFSET and lets the project name its own ports. `AUTOFLEET_PORTS` is a
# space-separated list of `name:base` pairs, and each port is `base + offset`:
#
#   AUTOFLEET_PORTS="API:21000 PROXY:23000 TLS:25000"
#
# Derived rather than picked at run time, for the same reason the project name
# is: teardown recomputes instead of reading .env back, and a port nothing can
# re-derive is a port nothing can release. Needs fleet_derive_env to have run.
fleet_ports() {
  local pair name base
  for pair in ${AUTOFLEET_PORTS:-}; do
    name="${pair%%:*}"; base="${pair##*:}"
    case "$base" in ''|*[!0-9]*) continue ;; esac
    printf '%s=%s\n' "$name" "$((base + fleet_offset))"
  done
}

# Run a command with a hard deadline, capturing its stdout in $2.
#
# Runner-agnostic on purpose, and NOT part of the driver contract: the drivers
# are its heaviest user, but `finish_removal` runs `reap.sh` through it too, and
# a `docker compose down` against a wedged daemon has no timeout of its own
# either. It lived in the Orca driver while it was the only caller, which made
# every non-Orca use of it read like a layering violation.
#
# Why any of this exists: a runtime can accept a connection and then never
# answer, and orca.yaml's `setupAgentStartupPolicy: wait-for-setup` holds the
# agent's tab until setup.sh returns -- so a hook that blocks forever costs the
# whole worktree, which is strictly worse than whatever it was trying to
# arrange. macOS ships no `timeout`, hence the manual watchdog.
#
# Polled in 50ms ticks rather than whole seconds, which is not a micro-
# optimisation: a child that has already exited is a zombie until bash reaps it,
# and `kill -0` succeeds on a zombie. With a one-second sleep every call
# therefore cost a full second even when the command answered instantly.
# setup.sh makes dozens of these, and `agent-autostart.sh --watch` alone makes
# two per poll -- which is what turned a test of it into a 21-second one, close
# enough to its 60s ctest timeout to go red on a loaded machine.
#
# Returns the command's status, or 124 when the deadline was hit.
#
# $2 gets stdout only. Two variables change that, both scoped to one call by
# `VAR=1 fleet_run_with_deadline ...`:
#
#   FLEET_RUN_CAPTURE_STDERR=1  merge stderr into $2
#   FLEET_RUN_STDERR=<file>     put stderr in a SEPARATE file
#
# Off by default because most callers parse $2 as JSON, and a warning landing in
# it is a parse error. Merging is on for the ones that report a FAILURE and
# nothing else: a CLI says why on stderr, so dropping it leaves "it failed" with
# nothing after it -- and "the app is not running" and "that worktree is gone"
# then look identical.
#
# The separate file exists for the ONE caller that needs both: `worktree create`
# reports a failure in the runtime's own words AND parses its success. Merging
# there meant a CLI that succeeded while writing anything at all to stderr -- a
# relayed `Preparing worktree (new branch ...)`, a keychain warning -- broke the
# parse, and the fleet then had a worktree it had created, that counted against
# its cap, that nothing owned and neither reap could ever see. Found by the
# independent review, which also noted `main` did not have this shape: the
# capture prefix arrived when the callsite moved into the driver.
fleet_run_with_deadline() {
  local seconds="$1" out="$2"; shift 2
  if [ -n "${FLEET_RUN_STDERR:-}" ]; then
    "$@" >"$out" 2>"$FLEET_RUN_STDERR" &
  elif [ "${FLEET_RUN_CAPTURE_STDERR:-0}" = 1 ]; then
    "$@" >"$out" 2>&1 &
  else
    "$@" >"$out" 2>/dev/null &
  fi
  local child=$! ticks=0 limit=$((seconds * 20))
  while kill -0 "$child" 2>/dev/null; do
    if [ "$ticks" -ge "$limit" ]; then
      kill "$child" 2>/dev/null
      wait "$child" 2>/dev/null
      return 124
    fi
    sleep 0.05
    ticks=$((ticks + 1))
  done
  wait "$child"
}

# SIGNAL A SPAWNED AGENT AND EVERYTHING IT STARTED, not just the process this
# shell forked.
#
# `AUTOFLEET_REVIEW_CMD` and `AUTOFLEET_SELF_REVIEW_CMD` are both advertised as
# WRAPPER seams -- point them at a different model, a different account, an `ssh`
# to the machine that holds the subscription -- so the process actually holding
# this machine's credentials is routinely a CHILD of what we forked. Signalling
# the direct child reaps the wrapper and orphans the agent: a full-budget run
# nobody is counting, with nothing left to enforce its deadline because the loop
# that enforced it was in the process that just died.
#
# So the caller runs `set -m` before the spawn, which gives the job its own
# PROCESS GROUP, and these signal the group. The bare pid is tried as well, for
# the case where job control was unavailable and no group was created --
# signalling a group that does not exist is an error, not a kill.
#
# ONE copy, because there were two: review.sh grew this pair first and
# self-review.sh needs exactly it (armaatus/autofleet#51). The grace period
# before the KILL is part of the shape -- an agent that is mid-write gets a
# chance to finish -- and two copies is two places for that 2 to drift.
fleet_signal_group() {
  kill "-$1" -- "-$2" 2>/dev/null || kill "-$1" "$2" 2>/dev/null
}
fleet_kill_group() {
  fleet_signal_group TERM "$1"
  sleep 2
  fleet_signal_group KILL "$1"
}

# One row out of a `path`-keyed TSV, by path: the $2 column of the first line
# whose $1 column equals $3, reading the table on stdin.
#
# ONE copy of it, because the same lookup exists twice -- the agent terminal in a
# worktree, and that worktree's agent state -- and it had the SAME BUG in both,
# fixed in both at once. `awk -v` REINTERPRETS what it assigns, so a worktree
# path containing a backslash arrived as `/Users/joe/mydir` when it was
# `/Users/joe/my\dir`, the comparison went false, and the caller was told there
# is no agent there. That is `stop` never interrupting an agent, and
# `agent-autostart.sh` giving up after two minutes with the prompt unsent -- both
# silent, because "no agent in that worktree" is indistinguishable from the
# truth. The python these replaced took the path as `sys.argv` and were immune;
# `ENVIRON[]` is awk's equivalent.
#
# The COLUMN numbers still go through `-v`, and that is safe: they are integers
# this file writes. Only the path is attacker-shaped. Merging the two copies was
# the independent review's suggestion, so the next such lookup cannot
# reintroduce it.
# `fleet_field_for_path <match-column> <print-column> <path>`. The two callers
# pass `2 1` and `1 2` -- opposite orders over the same helper, because their
# listings put the path in different columns -- and bare integers carry no clue
# which is which, so swapping them is silent and the answer becomes "there is
# nothing there". The two wrappers below are what the callers use; this stays
# private to them. Found by the independent review.
fleet_field_for_path() {
  AUTOFLEET_AWK_PATH="$3" awk -F'\t' -v k="$1" -v v="$2" \
    '$k == ENVIRON["AUTOFLEET_AWK_PATH"] { print $v; exit }'
}
# `handle<TAB>path` -- match column 2, print column 1.
fleet_handle_for_path() { fleet_field_for_path 2 1 "$1"; }
# `path<TAB>state` -- match column 1, print column 2.
fleet_state_for_path()  { fleet_field_for_path 1 2 "$1"; }

# An issue number out of a bare number or any `.../issues/<n>[...]` URL. Empty
# on stdout and rc 1 for anything that is neither, including the empty string,
# so a caller with a fallback can take it and a caller without one can refuse.
#
# SHARED, because it was written twice and both copies had the same defect. The
# `sed` form -- `s#.*/issues/([0-9]+).*#\1#p; s#^([0-9]+)$#\1#p` -- runs BOTH
# substitutions over the same pattern space: the first rewrites the URL to the
# number and prints it, and the second then matches that number and prints it
# again. On GNU sed those are two lines and `head -1` hid it. On BSD sed, which
# is what every macOS ships and therefore what the fleet runs on, the input was
# fed by `printf '%s'` with no trailing newline, the last `p` does not add one,
# and the two prints landed on ONE line: `/issues/42` resolved to `4242`.
# issue-command.sh then looked up an issue that does not exist and handoff.sh
# wrote a note under a filename nothing would ever read -- green in CI, wrong on
# the machine.
#
# PARAMETER EXPANSION rather than a fixed `sed`, and that is the second half of
# the lesson. The obvious fix is `t` to end the script after a substitution that
# took; BSD sed reads the rest of a `;`-separated line as that `t`'s LABEL and
# dies with "undefined label", so the portable spelling needs three `-e`s and a
# reader who knows why. There is no regex engine in the version below and
# nothing to be portable about.
fleet_issue_number() {
  local ref="${1:-}" num
  [ -n "$ref" ] || return 1
  case "$ref" in
    # `##`, the greedy strip, so a path with more than one `/issues/` in it
    # resolves the same way the `.*` it replaces did -- on the last.
    */issues/*) num="${ref##*/issues/}"; num="${num%%[!0-9]*}" ;;
    *)          num="$ref" ;;
  esac
  case "$num" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s' "$num"
}

# Where a worktree keeps the note one attempt at an issue leaves the next.
#
# The ROOT is a parameter and not $REPO_ROOT, because the dispatcher is the one
# caller that asks about a tree other than its own: `.autofleet/run/` is per
# worktree, so fleet.sh has to name the worktree that HOLDS the note, not the
# one it is standing in. The other two callers pass their own root and get the
# path they would have spelled by hand -- which is what this exists to stop them
# spelling three different ways.
fleet_handoff_path() { printf '%s/.autofleet/run/handoff-%s.md' "$1" "$2"; }

# The one contract function with no runner in it: the agent terminal in ONE
# worktree, filtered out of the machine-wide listing the driver does provide.
# Defined HERE, above the driver source, so a driver whose runtime can answer it
# directly still wins by defining its own -- and so that every driver does not
# ship the same filter. The stub driver in tests/test_fleet.sh carried a
# verbatim copy of it until the independent review said so.
#
# Non-zero only when the listing could not be read; no output means there is no
# agent there, which is a real answer.
runner_agent_terminal() {
  local list
  list="$(runner_agent_terminals)" || return 1
  printf '%s\n' "$list" | fleet_handle_for_path "$1"
}

# The runner driver: everything about creating a worktree, opening a terminal
# in it, and asking the runtime what it is doing. `orca` is the only one that
# ships, and it is the WHOLE of the dependency -- nothing outside
# scripts/fleet/runner/ names it. See docs/RUNNERS.md for the contract a second
# one has to meet.
#
# Sourced here rather than by each script because every hook needs it and a
# hook that silently has no driver looks exactly like a hook whose driver
# answered "nothing".
# The path once, above the branch, because THREE arms now need it: the source,
# the driver that sources and defines nothing, and the file that is not there.
FLEET_RUNNER_DRIVER="$(dirname "${BASH_SOURCE[0]}")/runner/${AUTOFLEET_RUNNER}.sh"
if [ -f "$FLEET_RUNNER_DRIVER" ]; then
  # `if !`, because `setup.sh` runs `set -e` and a driver that RETURNS non-zero
  # -- the documented shape for one that bails when a dependency it needs is
  # absent -- makes the `.` non-zero too. Errexit then killed the hook before
  # the check below could say anything, on the one path where the runner is
  # holding an agent's tab. A condition context is exempt from errexit, so the
  # status arrives here instead of ending the script. Measured, so the limit is
  # recorded with it: a driver with a SYNTAX ERROR is not reachable this way at
  # all -- bash aborts a non-interactive shell on a parse error in a sourced
  # file, `if !` or not -- and bash's own parser error naming the file and line
  # is what the reader gets. Found by the self-review, which had the syntax case
  # as the example; the early return is the half that is actually catchable.
  fleet_runner_source_rc=0
  . "$FLEET_RUNNER_DRIVER" || fleet_runner_source_rc=$?
  # A DRIVER THAT SOURCED AND DEFINED NOTHING is the same failure as no driver
  # at all, and it was landing as the one this issue exists to remove: a host
  # driver with a syntax error, or one that `return`s early when a dependency it
  # needs is absent, leaves every `runner_*` undefined, and the first call is
  # `command not found` -- rc 127 through `runner_available ||`, which reports
  # "the <name> runner is not usable here". The name is the one thing that is
  # right. `runner_available` is the probe every guarded caller reaches first
  # and the function docs/RUNNERS.md requires first, so it is the one tested
  # for. Found by the self-review.
  # THE STATUS IS KEPT, not just the probe. A driver is free to define
  # `runner_available` and THEN bail -- define the probe, discover the helper
  # file it needs is absent, `return 1` -- and `command -v` alone called that
  # working: the first real call was `command not found`, and `launch` relayed
  # "could not create it:" with nothing under it. docs/RUNNERS.md imposes no
  # ordering on a driver, so the source's own status is the only thing that
  # knows. Found by the self-review, which also had the earlier half of this.
  if [ "$fleet_runner_source_rc" = 0 ] \
    && command -v runner_available >/dev/null 2>&1; then
    # Set on BOTH arms, never defaulted from the environment. An exported
    # FLEET_RUNNER_MISSING=0 from the invoking shell would otherwise disarm the
    # refusal below, which is the same hole `evals/lint.sh` 4g closes with
    # `env -u` for AUTOFLEET_RUNNER. Found by the local review, on the variable
    # this one replaced.
    FLEET_RUNNER_MISSING=0
    # CLEARED, for the same reason FLEET_RUNNER_MISSING is set on both arms: it
    # is exported to cross an exec, so an inherited value from a shell that
    # sourced this file under a different AUTOFLEET_RUNNER would have
    # `fleet_require_runner` name THAT driver -- a confidently wrong filename,
    # which is the failure class this issue removes, one branch over. Found by
    # the self-review, on both axes.
    unset FLEET_RUNNER_MISSING_SAYS
    unset fleet_runner_source_rc
  else
    [ "${FLEET_RUNNER_REPORTED_FOR+set}" = set ] \
      && [ "$FLEET_RUNNER_REPORTED_FOR" = "$AUTOFLEET_RUNNER" ] || {
      echo "autofleet: $FLEET_RUNNER_DRIVER is there and did not finish implementing the runner_* contract"
      echo "     it sourced with status $fleet_runner_source_rc and $(command -v runner_available >/dev/null 2>&1 && echo "returned before it finished" || echo "defined no runner_available"); the contract is in docs/RUNNERS.md"
      echo "     check it for an early return when something it needs is missing, and for names that match the contract"
    } >&2
    # WHAT IS WRONG WITH IT, carried to `fleet_require_runner`, because the two
    # arms are not the same sentence: here the file EXISTS. "no <path>" sent the
    # reader to create a file that is right there -- and in a descendant shell,
    # where the block above is suppressed, that line is the only thing printed.
    # Exported for exactly that case. Found by the self-review, on both axes.
    export FLEET_RUNNER_MISSING_SAYS="$FLEET_RUNNER_DRIVER did not finish implementing the runner_* contract"
    export FLEET_RUNNER_REPORTED_FOR="$AUTOFLEET_RUNNER" FLEET_RUNNER_DRIVER
    FLEET_RUNNER_MISSING=1
    unset fleet_runner_source_rc
  fi
else
  # IT NAMES THE FILE, and lists the drivers that do ship.
  #
  # "no runner driver for AUTOFLEET_RUNNER=tmux" alone sends the reader to
  # `.autofleet/config`, where the name is the one thing that is not wrong --
  # what is wrong is that nothing implements it, and the remedy is either a
  # different name or a new file at a path only this line knows. The shape is
  # `fleet_python_rejections`: what was looked for, where, and what to do
  # instead. armaatus/autofleet#13.
  fleet_runner_dir="$(dirname "${BASH_SOURCE[0]}")/runner"
  fleet_runner_ships=""
  for fleet_runner_f in "$fleet_runner_dir"/*.sh; do
    # The glob is unquoted so it expands, which means it stays literal when it
    # matches nothing -- hence the test rather than trusting the loop.
    [ -f "$fleet_runner_f" ] || continue
    fleet_runner_f="${fleet_runner_f##*/}"
    fleet_runner_ships="${fleet_runner_ships:+$fleet_runner_ships }${fleet_runner_f%.sh}"
  done
  # SET-ness FIRST, not emptiness, and neither is belt-and-braces:
  # `.autofleet/config` is sourced after config.sh's `:=orca` default, so
  # `AUTOFLEET_RUNNER=` in that file reaches here EMPTY. On a fresh shell the
  # bare comparison is then `"" = ""` -- true -- and the whole remedy was
  # skipped, leaving `fleet.sh: no .../runner/.sh, so it stops here`: the
  # consequence with the cause suppressed, by the line whose job is the cause.
  # `-n` fixed that and broke the other half, because the sentinel this exports
  # for an empty name is itself empty and never matched again: `fleet.sh cost`
  # execs `cost.sh`, both source this file, and the four lines printed TWICE for
  # one command -- the "once" in the issue's title. `+set` tells unset from
  # empty, which is the distinction both halves actually need. Both found by the
  # self-review.
  [ "${FLEET_RUNNER_REPORTED_FOR+set}" = set ] \
    && [ "$FLEET_RUNNER_REPORTED_FOR" = "$AUTOFLEET_RUNNER" ] || {
    echo "autofleet: no runner driver for AUTOFLEET_RUNNER=$AUTOFLEET_RUNNER"
    echo "     looked for: $FLEET_RUNNER_DRIVER (no such file)"
    echo "     drivers here: ${fleet_runner_ships:-none -- $fleet_runner_dir is empty}"
    echo "     set AUTOFLEET_RUNNER in .autofleet/config to one of those, or write that file against the contract in docs/RUNNERS.md"
  } >&2
  # ONCE PER ENVIRONMENT TREE, which is what the issue's title needs and is
  # wider than "per command": `fleet.sh cost` execs `cost.sh` and both source
  # this file, so the block above had two chances to print for one command. A
  # later descendant of that same environment -- an agent shell running
  # `board.sh` -- gets `fleet_require_runner`'s line rather than the block, and
  # that line names the file, which is the part it needs. Exported so it
  # survives the exec; the driver path goes with it so `fleet_require_runner`
  # can still name the file in the process that did not print the block. Found
  # by the local review.
  #
  # Named for what it holds, so nothing has to say it is not a boolean. The
  # hazard is the environment, not the name: this is compared against the runner
  # it reports, so only a stray value EQUAL TO that name can swallow the four
  # lines the remedy lives in -- which is why the empty case above is tested
  # separately. The boolean this replaced could be swallowed by any `=1`. Renamed
  # by the independent review; the claim corrected by the self-review, which
  # caught it surviving the rename with the old variable's hazard attached.
  #
  # The runner NAME, not the driver path: the path is built from
  # `dirname "${BASH_SOURCE[0]}"`, and this file is sourced as
  # `./scripts/fleet/lib.sh` by sixteen scripts and as `$REPO_ROOT/...` by
  # `handoff.sh` and `issue-command.sh`. Keyed on the path, the block printed
  # again the first time it crossed that spelling boundary. Both found by the
  # local review.
  export FLEET_RUNNER_REPORTED_FOR="$AUTOFLEET_RUNNER" FLEET_RUNNER_DRIVER
  # ...and the other arm's sentence goes with it. `fleet_require_runner` falls
  # back to "no <driver path>" when this is unset, which is exactly this arm's
  # case; an inherited "<other driver> defines no runner_available" would
  # override it with a file that is not the one missing. Found by the
  # self-review.
  unset FLEET_RUNNER_MISSING_SAYS
  # SAID here, ACTED ON by `fleet_require_runner` below -- and this file neither
  # `return`s nor `exit`s on it. Three attempts, and each one was worse than the
  # last for a reason worth keeping:
  #
  #   `return 1`, which is what shipped before, leaves the library HALF SOURCED:
  #   FLEET_DIR and the stop files are defined below this line, so fleet.sh's
  #   first statement after the source died on `FLEET_DIR: unbound variable`.
  #   Most callers here run `set -uo pipefail` WITHOUT `-e`, so the status was
  #   discarded and they sailed on into that.
  #
  #   `exit 1` fixed the message and took seven scripts with it. `await-review`,
  #   `answer-review`, `review-status`, `resolve-thread`, `self-review`, `review`
  #   and `validate` source this file, call no `runner_*` at all, and would have
  #   refused to answer a review comment for want of a driver none of them uses
  #   -- printing "write that file against the contract in docs/RUNNERS.md" at
  #   somebody trying to reply on a pull request. `cost` was the eighth, and
  #   exempting it by name was the tell that the line was drawn in the wrong
  #   place. Found by the local review.
  #
  # So: say it once at source time, finish sourcing, and let the four scripts
  # that call `fleet_require_runner` stop on it -- the dispatcher, the setup
  # hook, the board and the autostart watcher. A fifth NAMES a `runner_*` and is
  # deliberately unguarded: `issue-command.sh` prints an agent's brief, which
  # needs no runtime, and asks `runner_available` only behind an `&&` that rc
  # 127 makes false. docs/RUNNERS.md carries the reason. `evals/lint.sh` check 4h
  # fails one that forgets to. armaatus/autofleet#13.
  #
  # ...and the scratch is cleared. These are the only lowercase globals this
  # file would leave in a caller's shell, and every other global it sets is
  # FLEET_*. Found by the local review.
  unset fleet_runner_dir fleet_runner_ships fleet_runner_f
  FLEET_RUNNER_MISSING=1
fi

# The consequence of a driver that is missing OR does not implement anything,
# for the callers that need one. Called
# before the first `runner_*`, because without a driver that call is
# `command not found` -- rc 127, which fleet.sh's `runner_available || die`
# reported as "the tmux runner is not usable here": the consequence named as
# the cause, with the real message four lines up the screen.
fleet_require_runner() {
  [ "${FLEET_RUNNER_MISSING:-0}" = 1 ] || return 0
  # NAMES THE FILE again rather than saying "one". The block above is printed at
  # source time and this line can be hundreds of lines of output later --
  # `setup.sh` runs the whole of env.sh in between -- so an indented
  # continuation with no antecedent lands under unrelated output. Found by the
  # local review.
  echo "${0##*/}: ${FLEET_RUNNER_MISSING_SAYS:-no $FLEET_RUNNER_DRIVER}, so it stops here" >&2
  exit 1
}

# Whether the daemon is actually answering.
#
# Every query below reports "nothing found" when it cannot reach docker, which
# reads identically to "nothing is left". Teardown must not confuse the two: a
# stack that survived because the daemon was down is exactly the one that needs
# reporting, and calling it removed is worse than not checking at all.
fleet_docker_ready() { docker info >/dev/null 2>&1; }

# Everything docker holds for one compose project, as `kind<TAB>name` lines.
# Only meaningful once fleet_docker_ready succeeds.
fleet_project_remnants() {
  local filter="label=com.docker.compose.project=$1" tab
  tab="$(printf '\t')"
  docker ps -a      --filter "$filter" --format "container${tab}{{.Names}}" 2>/dev/null || true
  docker volume ls  --filter "$filter" --format "volume${tab}{{.Name}}"     2>/dev/null || true
  docker network ls --filter "$filter" --format "network${tab}{{.Name}}"    2>/dev/null || true
}

# Where the fleet keeps its state, and the two files that stop it.
#
# Here rather than in each script because several of them need the same paths
# and a stop that only some of them can see is not a stop. See
# scripts/fleet/fleet.sh for what each of the two actually does.
#
# They are two files because "start nothing new" and "let nothing out" are two
# different instructions and only one of them belongs to the agents (#183):
#
#   DRAIN  no new worktrees. Every stop sets it. NOTHING outside fleet.sh reads
#          it -- an agent mid-work carries on, pushes, opens its PR and comments,
#          because a PR that merges is what RELEASES the worktree the drain is
#          waiting on.
#   STOP   nothing goes out: no push, no PR, no comment, from any agent, whether
#          or not it has read the news. Only `stop --now` and `stop --all` set
#          it, and guard.py, await-review.sh, review-status.sh and
#          resolve-thread.sh are the ones that read it.
FLEET_DIR="${AUTOFLEET_DIR:-$HOME/.autofleet}"
FLEET_STOP="$FLEET_DIR/STOP"
FLEET_DRAIN="$FLEET_DIR/DRAIN"
FLEET_OWNED="$FLEET_DIR/worktrees"
# ...and what it HAS run, which is a different question. `own()` writes an
# issue's worktree path here and `disown_issue` does NOT take it away, so the
# record outlives the worktree -- `cost.sh` is built on it, and on $FLEET_OWNED
# alone that report emptied itself exactly when a run finished.
#
# HERE, beside the others, for the reason stated above them: the writer is
# fleet.sh and the reader is cost.sh, and two spellings of one path is one
# chance for the reader to look somewhere the writer never wrote. Found by the
# standards review, which pointed at this very paragraph as the rule it broke.
FLEET_RAN="$FLEET_DIR/ran"

# Which reviewer this repository runs, normalised -- `local` or `github`.
#
# ONE PLACE, for the same reason `independent_reviews()` is one place: three
# copies of `[ "${AUTOFLEET_REVIEW_MODE:-github}" = local ]` are three chances to
# drift, and the drift that matters is between the shell and
# `merge_gate.review_mode()`. Anything that is not exactly `local` is `github`,
# which is what every consumer already did by hand and what the gate does -- so
# a typo is the STRONG mode, refusing PRs rather than admitting them.
# evals/lint.sh drives this function against the gate, spelling for spelling.
fleet_review_mode() {
  case "${AUTOFLEET_REVIEW_MODE:-github}" in
    local) printf 'local\n' ;;
    *)     printf 'github\n' ;;
  esac
}
fleet_review_is_local() { [ "$(fleet_review_mode)" = local ]; }
# A file's mtime in epoch seconds, or non-zero if it cannot be had.
#
# GNU first, BSD second, and THE ANSWER IS VALIDATED -- which is not belt and
# braces, it is the bug. `stat -f %m` is BSD's spelling; GNU's `-f` means
# --file-system, takes no format, and therefore reads `%m` as a second FILE. It
# fails on that one and SUCCEEDS on the real one, printing a filesystem block to
# stdout on the way. The caller then did `$(( now - said_at ))` on a string
# beginning `File:`, and bash under `set -u` evaluated `File` as a variable:
#
#   ./scripts/fleet/fleet.sh: line 407: File: unbound variable
#
# So every foundation hold on Linux died where it should have re-explained
# itself, and the suite was red on `main` for it. Ordering alone would fix
# today's pair; validating the answer is what makes the next `stat` that prints
# something unexpected a "could not tell" rather than a crash three frames up.
fleet_mtime() {
  [ -e "${1:-}" ] || return 1
  local m
  # main fixed this in parallel (ac34813) by validating each answer separately
  # rather than the end of an `||` chain; that is the stronger shape and it is
  # the one kept, so the merge leaves one spelling and not two.
  m="$(stat -c %Y "$1" 2>/dev/null)"
  case "$m" in ''|*[!0-9]*) m="$(stat -f %m "$1" 2>/dev/null)" ;; esac
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$m"
}

fleet_stopped() { [ -e "$FLEET_STOP" ]; }
# A hard stop implies the drain, so this asks about both: a STOP left by a fleet
# that predates DRAIN still means "start nothing new" to the dispatcher reading
# it.
fleet_draining() { [ -e "$FLEET_DRAIN" ] || [ -e "$FLEET_STOP" ]; }

# The open PR for a branch, or nothing. Also here rather than in each script:
# two of them resolved it slightly differently, which is how "no PR for this
# branch" and "gh failed" end up looking the same in one of them.
fleet_pr_for_branch() {
  local branch="${1:-$(git rev-parse --abbrev-ref HEAD)}" pr
  pr="$(GH_PAGER=cat gh pr list --head "$branch" --state open --json number \
          --jq '.[0].number' 2>/dev/null)" || return 1
  [ -n "$pr" ] && [ "$pr" != "null" ] || return 1
  printf '%s\n' "$pr"
}

# The `owner/name` this worktree's PRs live in, split into $fleet_owner and
# $fleet_repo_name.
#
# Non-zero when gh cannot answer, and ALSO when it answers something that is not
# `owner/name`. That second case is the one worth a function: an empty owner
# builds a GraphQL query that matches nothing rather than one that errors, so a
# caller polling on it waits out its whole deadline and then reports that nothing
# arrived -- indistinguishable from the silence await-review.sh exists to
# explain.
fleet_owner_repo() {
  local answer
  answer="$(GH_PAGER=cat gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" \
    || return 1
  case "$answer" in */*) ;; *) return 1 ;; esac
  fleet_owner="${answer%%/*}"
  fleet_repo_name="${answer##*/}"
}

# The pull request, in the shape .github/scripts/merge_gate.py judges, written
# to $2. Needs fleet_owner_repo to have run.
#
# Here rather than in each caller for the reason the query itself is one file:
# `review-status.sh` and `resolve-thread.sh` both want exactly this, and "resolve
# the repo, then run the gather" written twice is two places for it to drift --
# which is how the local answer and the gate's answer came apart in #114.
# stderr is NOT swallowed. pr_payload.sh distinguishes "could not read PR #N"
# from "came back in a shape this cannot read", and a caller that turns both
# into its own one-line "could not read the PR's reviews" has thrown away the
# half that says which. That is the same silent-failure shape fleet.sh's card()
# and remove_worktree() are being fixed for in this very change; it reached one
# more place than the issue listed.
fleet_pr_payload() {
  local pr="$1" out="$2"
  bash .github/scripts/pr_payload.sh "$fleet_owner" "$fleet_repo_name" "$pr" >"$out"
}

# Ask merge-gate again about the head $1, and say so with $2 in front of it.
#
# NOTHING ON GITHUB DOES THIS. `merge-gate.yml` re-runs on the events that can
# change its answer, and two of the things that change it are not events it can
# subscribe to: `pull_request_review_thread` is a webhook event and not a
# workflow trigger (putting it in `on:` invalidates the whole file), and an
# issue comment -- which is what an answer to a review is -- would run against
# the default branch, so its check run would not attach to this PR's head at
# all. So the gate stays red on a condition that is already satisfied and
# `--auto` never fires.
#
# Re-running the gate's own earlier run is what asks it again, because a re-run
# updates that check run IN PLACE, which is the thing branch protection counts.
# `merge-gate.yml`'s own `clear-stale` job relies on the same mechanism.
#
# Here rather than in each caller because `resolve-thread.sh` and
# `answer-review.sh` need exactly this, down to the reasons not to do it -- and
# the one that matters is a rule, not a detail: only the NEWEST gate run on the
# head. Re-running an older failure that a newer success already superseded
# enters merge-gate's cancel-in-progress group and can kill a live run, which is
# #84's wedge inflicted from here.
#
# IT WAITS OUT A RUN IN FLIGHT rather than treating it as nothing to do. A run
# already going was once read as "it will evaluate with the new state anyway",
# which holds only if it reads the PR after the change -- and two of these
# arrive back to back. They used to be one actor's: the author resolved its own
# threads and then answered. They are now two actors' -- the author's
# `answer-review.sh` and, minutes later, the validator's `resolve-thread.sh` --
# which makes the overlap wider rather than narrower, since nothing sequences
# the two. The second
# one's newest run is the rerun the first just queued, which may well have
# fetched the pull request before the answer was posted: it concludes `failure`
# on a condition that is now satisfied, nothing asks again, and the PR sits red
# with the answer already on it. Found in review of #170.
#
# Exits 0 whether or not a re-run was needed, 2 when it could not tell.
FLEET_GATE_WAIT_SECONDS="${FLEET_GATE_WAIT_SECONDS:-180}"
FLEET_GATE_POLL_SECONDS="${FLEET_GATE_POLL_SECONDS:-10}"
fleet_reask_gate() {
  local head="$1" said="$2" listing answer state run job waited=0
  while :; do
    listing="$(GH_PAGER=cat gh run list --repo "$fleet_owner/$fleet_repo_name" \
                 --workflow merge-gate.yml --limit 40 \
                 --json databaseId,conclusion,headSha 2>/dev/null)" || {
      echo "$said, but could not list merge-gate runs; ask for the gate again with a push" >&2
      return 2; }

    # Two lines: what the newest run on this head concluded, and its id. Read
    # back from one pass so the state and the id cannot come from different runs.
    answer="$(printf '%s' "$listing" | python3 -c '
import json, sys
head = sys.argv[1]
on_head = [r for r in json.load(sys.stdin) if r.get("headSha") == head]
newest = on_head[0] if on_head else None
print((newest or {}).get("conclusion") or ("running" if newest else "none"))
print((newest or {}).get("databaseId") or "")
' "$head" 2>/dev/null)"
    state="$(printf '%s\n' "$answer" | sed -n 1p)"
    run="$(printf '%s\n' "$answer" | sed -n 2p)"

    case "$state" in
      failure|cancelled) break ;;
      running)
        if [ "$waited" -ge "$FLEET_GATE_WAIT_SECONDS" ]; then
          echo "$said, and a merge-gate run on ${head:0:8} is still going after ${waited}s." >&2
          echo "If it fails, ask it again with: gh run rerun --job <its merge-gate job id>" >&2
          return 2
        fi
        sleep "$FLEET_GATE_POLL_SECONDS"
        waited=$((waited + FLEET_GATE_POLL_SECONDS))
        continue ;;
      *)
        # Passed already, or no run on this head at all. Nothing to re-ask, and
        # re-running an older failure underneath a success is #84's wedge.
        echo "$said; the newest merge-gate run on ${head:0:8} is not one to re-ask"
        return 0 ;;
    esac
  done

  job="$(GH_PAGER=cat gh api \
           "repos/$fleet_owner/$fleet_repo_name/actions/runs/$run/jobs" \
           --jq '[.jobs[] | select(.name == "merge-gate") | .id][0]' 2>/dev/null || echo "")"
  if [ -z "$job" ] || [ "$job" = "null" ]; then
    # The gate JOB, never the whole run: `clear-stale` is `needs: gate` and
    # would run a second copy of its own rerun loop, which is the wedge it
    # exists to clear reproduced one level down (merge-gate.yml says the same).
    echo "$said, but the gate job of run $run could not be found." >&2
    echo "Ask the gate again with: gh run rerun --job <gate job id of run $run>" >&2
    return 2
  fi

  if GH_PAGER=cat gh run rerun --job "$job" --repo "$fleet_owner/$fleet_repo_name" \
       >/dev/null 2>&1; then
    echo "$said; re-ran the gate job ($job) so merge-gate is asked again"
    return 0
  fi
  echo "$said, but re-running the gate job failed." >&2
  echo "Ask it again with: gh run rerun --job $job" >&2
  return 2
}


# The Python that server/requirements.txt can actually be installed with.
#
# Not simply `python3`. This hook runs in whatever environment Orca hands it,
# and that is not an interactive shell: creating a worktree from the Orca UI on
# macOS resolves `python3` to Apple's Command Line Tools build (3.9.6), while the
# same command typed into a terminal finds Homebrew's. The difference was
# invisible until `requests` was pinned at 2.33.0, which declares
# `requires-python >=3.10` -- pip then filters out every candidate and reports
# "no matching distribution", two hundred lines long, naming neither Python nor
# the reason.
FLEET_PYTHON_MIN_MAJOR=3
FLEET_PYTHON_MIN_MINOR=10

# Usable means three things, not one: it runs, it is new enough, and it can
# actually build a venv. On Debian and Ubuntu `python3.13` and `python3.13-venv`
# are separate packages, so a version check alone can pick an interpreter whose
# `-m venv` then dies with "ensurepip is not available" -- which would be this
# same class of opaque failure, moved one step later.
#
# Sets fleet_python_reject to a one-line reason when it returns non-zero, so a
# caller can say which interpreters it turned down and why, rather than
# reporting "nothing is new enough" about one that will not start at all.
fleet_python_reject=""
fleet_python_is_usable() {
  local out
  fleet_python_reject=""
  out="$("$1" -c "
import sys
if sys.version_info < ($FLEET_PYTHON_MIN_MAJOR, $FLEET_PYTHON_MIN_MINOR):
    raise SystemExit('too old: %d.%d' % sys.version_info[:2])
import ensurepip, venv
" 2>&1)" && return 0
  # Last line only: an ImportError arrives as a traceback whose final line is
  # the part worth showing.
  fleet_python_reject="$(printf '%s' "$out" | tail -1)"
  [ -n "$fleet_python_reject" ] || fleet_python_reject="will not run"
  return 1
}

# Every python3.N on PATH, newest first, then bare `python3` as the fallback for
# a machine that has only that.
#
# Discovered rather than hardcoded: a written-out list ends at whatever was
# current the day it was written, and would tell a machine whose only new-enough
# interpreter is python3.15 to go and install a Python it already has.
fleet_python_candidates() {
  local dir name
  {
    # Split on ":" only, so a PATH entry containing a space still resolves.
    local IFS=:
    for dir in $PATH; do
      [ -n "$dir" ] || continue
      for name in "$dir"/python3.[0-9] "$dir"/python3.[0-9][0-9]; do
        [ -x "$name" ] && printf '%s\n' "${name##*/}"
      done
    done
  } | sort -t. -k2 -nr -u
  printf 'python3\n'
}

# The first usable candidate, on stdout. Non-zero when there is none, so the
# caller can say so in one line instead of leaving pip to.
fleet_pick_python() {
  local candidate
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    command -v "$candidate" >/dev/null 2>&1 || continue
    if fleet_python_is_usable "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done <<EOF
$(fleet_python_candidates)
EOF
  return 1
}

# What was tried and why each was turned down, one per line. Only ever called on
# the failure path -- fleet_pick_python runs in a command substitution, so the
# reasons it collects cannot escape the subshell, and re-deriving them here
# costs nothing when the alternative is an unexplained stop.
fleet_python_rejections() {
  local candidate
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    command -v "$candidate" >/dev/null 2>&1 || continue
    fleet_python_is_usable "$candidate" \
      || printf '     %s (%s): %s\n' "$candidate" "$(command -v "$candidate")" "$fleet_python_reject"
  done <<EOF
$(fleet_python_candidates)
EOF
}

# Whether an existing .venv can still be used.
#
# `[ -x .venv/bin/python ]` is NOT this test. A venv's bin/python is a symlink to
# the interpreter that built it, and a Homebrew minor upgrade -- or picking a
# different interpreter than last time -- leaves it dangling. `-x` is false for a
# dangling link, so the venv reads as absent, and `python -m venv` over it then
# exits 1 on the broken link rather than repairing it: setup.sh dies there under
# `set -e` and every re-run does the same thing forever. Asking the venv's own
# interpreter to answer covers missing, dangling and too-old in one question.
fleet_venv_is_usable() {
  fleet_python_is_usable "$1/bin/python" 2>/dev/null
}

# ---------------------------------------------- the reviewing phases' markers
#
# THREE FILES BESIDE A LOCK, and two scripts that keep them: `review.sh` for the
# independent review, `validate.sh` for the validation that follows it. Both
# hold a `.tries` (attempts on one head that produced nothing), a `.rounds`
# (verdicts this pull request has had) and a `.done` (the head that has been
# handled), and the dispatcher reads `.tries` again before either spawn.
#
# The arithmetic lives here because it did not, once. `validate.sh` arrived as
# ~150 lines of `review.sh` re-typed, and what came with the copy was a bug:
# `read -r h n <"$marker" 2>/dev/null` silences stderr after the open that fails
# (armaatus/autofleet#87), which had to be fixed in seventeen places because it
# had been re-typed seventeen times. Every one of those was a line somebody had
# already written correctly somewhere else.
#
# The WRAPPERS stay in each script, thin, because the two phases genuinely
# differ about when a try is refunded and about what a round is derived from --
# see the comments on their own `unspent_try` and round functions. What is
# shared is the file format and the arithmetic, which is what drifted.

# Refund one attempt. $1 the `.tries` marker, $2 the head it must name -- empty
# means "whatever head the marker names", which is the right refund for an exit
# that failed before the head was known: the dispatcher spent that try for this
# run and this run reached no agent.
#
# Silent about a missing marker on purpose: a person running either script by
# hand has no marker at all, and a refund with nothing to refund is a no-op, not
# an error.
fleet_try_refund() {
  local marker="$1" want="${2:-}" h n
  [ -n "$marker" ] || return 0
  read -r h n 2>/dev/null <"$marker" || return 0
  [ -n "${h:-}" ] || return 0
  [ -z "$want" ] || [ "$h" = "$want" ] || return 0
  n=$(( ${n:-1} - 1 ))
  if [ "$n" -le 0 ]; then rm -f "$marker" 2>/dev/null || true
  else printf '%s %s\n' "$h" "$n" >"$marker" 2>/dev/null || true
  fi
}

# How many attempts stand against $2 on the `.tries` marker $1. Zero when the
# marker names another head -- a new head is a new question -- and zero for an
# empty or corrupt one.
#
# `[ -f ]` FIRST, and the count assigned before it is tested: an empty marker
# leaves `n` empty, and `[ "" -ge 3 ]` is `integer expression expected` and exit
# 2, which a caller reads as FALSE. That is a cap that silently does not exist,
# and it is the reason this is one function rather than a shape each caller
# remembers.
fleet_tries_count() {
  local marker="$1" want="${2:-}" h n
  h=""; n=0
  [ -n "$marker" ] && [ -f "$marker" ] && read -r h n <"$marker"
  [ "${h:-}" = "$want" ] || n=0
  n="${n:-0}"
  case "$n" in (*[!0-9]*) n=0 ;; esac
  printf '%s\n' "$n"
}

# The round this run is: what the marker $1 holds, or $2 if that is larger,
# plus one. $2 is the count DERIVED from the pull request itself, which sees
# rounds this fleet never recorded; the larger of the two is taken because the
# marker is monotonic and a count that went backwards would hand a pull request
# rounds it has already spent. Empty $2 means nothing was derived.
#
# An absent marker is round 1, which is the safe direction: a person running the
# script by hand gets the first round's rules, and those suppress nothing.
fleet_round_next() {
  local marker="$1" derived="${2:-}" n=0
  [ -n "$marker" ] && [ -f "$marker" ] && read -r n <"$marker"
  n="${n:-0}"
  case "$n" in (*[!0-9]*) n=0 ;; esac
  if [ -n "$derived" ] && [ "$derived" -gt "$n" ]; then n="$derived"; fi
  printf '%s\n' "$(( n + 1 ))"
}

# This head has been handled: write it to the `.done` marker $1 and drop the
# `.tries` marker $3. The attempt count belongs to heads that got NO verdict,
# and this one got one.
fleet_record_done() {
  local done_marker="$1" head="$2" tries_marker="${3:-}"
  [ -n "$done_marker" ] || return 0
  printf '%s\n' "$head" >"$done_marker" 2>/dev/null || true
  [ -n "$tries_marker" ] && rm -f "$tries_marker" 2>/dev/null || true
  return 0
}
