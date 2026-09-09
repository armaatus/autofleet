#!/usr/bin/env bash
# The Orca driver: how autofleet creates worktrees, opens terminals, and reads
# the runtime. Sourced by lib.sh when AUTOFLEET_RUNNER=orca, which is the
# default and today the only driver that ships.
#
# THE CONTRACT A SECOND DRIVER HAS TO MEET is in fleet/runner/README.md. Right
# now this file holds the CLI plumbing only -- resolving the binary and calling
# it with a deadline -- while fleet.sh, agent-autostart.sh and issue-command.sh
# still invoke `$ORCA_CLI` directly. Moving those callsites behind the driver
# API is what makes a tmux or plain-git-worktree driver possible; until then,
# autofleet needs Orca.

# The Orca CLI this machine can actually run, in $ORCA_CLI.
#
# `orca` on PATH is a wrapper that locates Orca.app by reading its own symlink.
# A macOS install has shipped that symlink mode 0700 root:wheel, so the readlink
# fails for the user Orca runs these hooks as and every call dies with "Unable to
# determine Orca.app path from symlink". Nothing here notices a broken CLI as
# such -- the JSON never parses -- so it surfaces one layer up as an answer:
# `agent-autostart.sh` reports "this worktree has no linked issue", stops
# watching, and leaves a fully provisioned worktree whose agent sits on an unsent
# prompt forever. That is how three worktrees went idle on 2026-09-05.
#
# So the wrapper is verified rather than assumed, and the app's own binary is the
# fallback. `--version` is the probe because it is the one call that needs no
# runtime: a wrapper that cannot find Orca.app fails it, and a reachable CLI
# answers it whether or not the app is running.
#
# The probe goes through orca_run_with_deadline like every other CLI call. It is
# the FIRST call each hook makes, and `setupAgentStartupPolicy: wait-for-setup`
# holds the agent's tab until setup.sh returns -- so a wrapper that connects and
# then never answers would hang worktree provisioning at the one point where
# nothing has printed a reason yet.
#
# Returns non-zero when nothing answers, so a caller can say so in one line
# instead of making its first real call and reading the silence as data.
ORCA_CLI_PROBE_SECONDS="${ORCA_CLI_PROBE_SECONDS:-10}"
orca_cli_resolve() {
  [ -n "${ORCA_CLI:-}" ] && return 0
  local candidate probe_out
  probe_out="$(mktemp)"
  for candidate in ${ORCA_CLI_COMMAND:-} orca orca-dev orca-ide \
      /Applications/Orca.app/Contents/Resources/bin/orca; do
    command -v "$candidate" >/dev/null 2>&1 || continue
    orca_run_with_deadline "$ORCA_CLI_PROBE_SECONDS" "$probe_out" \
      "$candidate" --version || continue
    ORCA_CLI="$candidate"
    rm -f "$probe_out"
    return 0
  done
  rm -f "$probe_out"
  return 1
}

# Run an `orca` CLI call with a hard deadline, capturing its stdout in $2.
#
# Every hook that talks to the Orca runtime needs this. The runtime can accept a
# connection and then never answer, and `setupAgentStartupPolicy: wait-for-setup`
# in orca.yaml holds the agent's tab until setup.sh returns -- so a hook that
# blocks forever on the CLI costs the whole worktree, which is strictly worse
# than whatever it was trying to arrange. macOS ships no `timeout`, hence the
# manual watchdog.
#
# Polled in 50ms ticks rather than whole seconds, which is not a micro-
# optimisation: a child that has already exited is a zombie until bash reaps it,
# and `kill -0` succeeds on a zombie. With a one-second sleep every call
# therefore cost a full second even when the CLI answered instantly. setup.sh
# makes dozens of these, and `agent-autostart.sh --watch` alone makes two per
# poll -- which is what turned a test of it into a 21-second one, close enough
# to its 60s ctest timeout to go red on a loaded machine.
#
# Returns the command's status, or 124 when the deadline was hit.
# $2 gets stdout only, unless ORCA_RUN_CAPTURE_STDERR=1 is set for the call --
# `VAR=1 orca_run_with_deadline ...`, which bash scopes to that call alone.
#
# Off by default because most callers parse $2 as JSON, and a warning landing in
# it is a parse error. On for the two that report a FAILURE: a CLI says why on
# stderr, so dropping it leaves "it failed" with nothing after it -- and "the
# app is not running" and "that worktree is gone" then look identical.
orca_run_with_deadline() {
  local seconds="$1" out="$2"; shift 2
  if [ "${ORCA_RUN_CAPTURE_STDERR:-0}" = 1 ]; then
    "$@" >"$out" 2>&1 &
  else
    "$@" >"$out" 2>/dev/null &
  fi
  local cli=$! ticks=0 limit=$((seconds * 20))
  while kill -0 "$cli" 2>/dev/null; do
    if [ "$ticks" -ge "$limit" ]; then
      kill "$cli" 2>/dev/null
      wait "$cli" 2>/dev/null
      return 124
    fi
    sleep 0.05
    ticks=$((ticks + 1))
  done
  wait "$cli"
}
