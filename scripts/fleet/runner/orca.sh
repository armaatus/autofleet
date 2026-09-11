#!/usr/bin/env bash
# The Orca driver: how autofleet creates worktrees, opens terminals, and reads
# the runtime. Sourced by lib.sh when AUTOFLEET_RUNNER=orca, which is the
# default and today the only driver that ships.
#
# THE CONTRACT A SECOND DRIVER HAS TO MEET is in docs/RUNNERS.md, and this file
# is now the whole of it: no code outside this directory CALLS the CLI, reads
# $ORCA_CLI, or parses a line of Orca's JSON. A tmux + `git worktree` driver is
# a second file here and nothing else. Orca is still NAMED outside it -- in
# orca.yaml, and in the comments of the hooks orca.yaml points at -- and
# docs/RUNNERS.md lists what those hooks still assume about the runtime.
#
# Two properties hold for every function below, and they are the reason the
# seam is worth having rather than a convention:
#
#   1. EVERY CALL HAS A DEADLINE. The runtime can accept a connection and then
#      never answer, and orca.yaml's `setupAgentStartupPolicy: wait-for-setup`
#      holds the agent's tab until setup.sh returns -- a hook that blocks
#      forever costs the whole worktree.
#   2. "I COULD NOT TELL" IS NOT "NOTHING". Each function distinguishes a
#      negative answer from a failed question, because conflating them is how a
#      dispatcher waits out its whole time-box and then reports that nothing
#      arrived. Where that needs more than two codes it is spelled out on the
#      function.
#
# The deadlines are the ones each callsite used before the move.
ORCA_DEADLINE=30
ORCA_SEND_DEADLINE=20
ORCA_CREATE_DEADLINE=240

# `runner_set_deadline <seconds>` -- part of the contract, because a caller that
# needs a shorter one has to be able to ask WITHOUT knowing which driver it has.
# agent-autostart.sh is that caller: it polls every three seconds, and a watcher
# that can block for thirty of them inside one poll has stopped watching. It
# used to say so by exporting a variable only this file reads, which is a caller
# outside runner/ assuming how the driver works -- the exact thing the seam
# exists to stop. Found by the independent review.
#
# Creating a worktree keeps its own, deliberately: nobody polls a create, and a
# 20-second deadline on a call that legitimately takes minutes is not a shorter
# wait, it is a failed launch.
runner_set_deadline() {
  ORCA_DEADLINE="$1"
  ORCA_SEND_DEADLINE="$1"
}

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
# The probe goes through fleet_run_with_deadline like every other CLI call. It is
# the FIRST call each hook makes, and `setupAgentStartupPolicy: wait-for-setup`
# holds the agent's tab until setup.sh returns -- so a wrapper that connects and
# then never answers would hang worktree provisioning at the one point where
# nothing has printed a reason yet.
#
# Orca-named and Orca-private. The broken symlink is Orca's own install, not any
# project's -- armaatus/rommsync-nx is only where the fleet first ran into it --
# so a second driver inherits none of this.
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
    fleet_run_with_deadline "$ORCA_CLI_PROBE_SECONDS" "$probe_out" \
      "$candidate" --version || continue
    ORCA_CLI="$candidate"
    rm -f "$probe_out"
    return 0
  done
  rm -f "$probe_out"
  return 1
}

# Every call goes through one of these two, and BOTH resolve first.
#
# A driver function is allowed to be called before `runner_available` -- the
# fleet's own scripts all probe, but the contract does not oblige a caller to,
# and `orca_cli_resolve` returns instantly once $ORCA_CLI is set. Without this
# the failure was `ORCA_CLI: unbound variable` from inside the driver on any
# script running `set -u`, which is the least useful sentence available: it
# names a variable rather than saying the app is not answering. Found by
# smoke-testing the driver from a bare shell.
orca_cli() {
  orca_cli_resolve || return 1
  fleet_run_with_deadline "$1" "$2" "$ORCA_CLI" "${@:3}"
}

# One `orca ... --json` call, its stdout in $1, on the ordinary deadline.
# Private: a caller outside this file passing its own subcommand would be the
# seam leaking through a hole in the middle of it.
orca_json() {
  local out="$1"; shift
  orca_cli "$ORCA_DEADLINE" "$out" "$@" --json
}

# ------------------------------------------------------------ the contract ---

# 0 if this runner can be used at all.
#
# It SAYS why on stderr when it cannot, because only the driver knows what to
# check next -- "is the Orca app running?" is not a sentence the dispatcher can
# write for an arbitrary runner. The caller adds the consequence.
# The sentence, once. It was written three times in three separate review rounds
# -- and on two different streams, which is precisely what the last of those
# rounds had to fix -- so the third copy was a fourth chance to pick the wrong
# one. WHICH STREAM stays with the callsite, because that is genuinely per-caller:
# `runner_available` is a probe nobody captures, while `runner_worktree_create`
# and `runner_worktree_set` print where their callers read. Found by the
# independent review.
orca_unavailable_says() { printf 'no orca CLI answers here; is the Orca app running?\n'; }

runner_available() {
  orca_cli_resolve && return 0
  orca_unavailable_says >&2
  return 1
}

# How a person starts the dispatcher somewhere it stays visible. One line, and
# the only human-facing string that is runner-specific: `fleet.sh --help` prints
# it rather than hardcoding a command that is wrong for every other driver.
runner_dispatcher_hint() {
  printf 'orca terminal create --worktree active --title fleet --command "%s"\n' \
    "./scripts/fleet/fleet.sh run --auto"
}

# Open a worktree for one issue, printing its path.
#
# On failure, prints the runtime's own words instead -- capped at three lines
# like every other relay -- because "could not create it" with nothing after it
# is the same message whether the app is down or the branch already exists.
#
# stderr goes to its OWN file, not merged into $out. This is the one driver
# function that both relays a failure and parses a success, and merging broke the
# parse for any CLI that succeeded while writing anything at all to stderr: the
# worktree existed, counted against the cap, and nothing owned it -- no card, no
# time-box, and neither reap iterates it, because both walk OWNED_DIR. A slot
# held forever by a worktree the fleet cannot see. Found by the independent
# review; lib.sh states the rule this broke, in this change's own words.
runner_worktree_create() {
  local repo="$1" name="$2" issue="$3" agent="$4" prompt="$5" comment="$6"
  # Resolved explicitly, and SAID, because `orca_cli` answers a failed resolve
  # with `orca_cli_resolve || return 1` BEFORE anything is written to $err or
  # $out -- so the relay below had nothing to relay and `launch` printed
  # "  could not create it:" followed by nothing. Word for word the message
  # `create_says` exists to prevent, on the one path that phase did not cover.
  # Both neighbours already do this: `runner_worktree_remove` resolves for its
  # own three-way answer, `runner_available` says why on stderr. docs/RUNNERS.md
  # is explicit that a caller is not obliged to probe first. Found by the
  # independent review.
  orca_cli_resolve || {
    # STDOUT, not stderr, and that distinction is the whole of the fix. `launch`
    # captures stdout only -- `fleet.sh:702` is `runner_worktree_create ... >"$out"`
    # -- and it has to, because stdout is where the worktree path comes back. A
    # reason on stderr goes to the terminal and never into `$out`, so
    # "  could not create it:" printed nothing, which is what round five thought
    # it had fixed. docs/RUNNERS.md says this function prints "the runtime's own
    # words on failure", and the CLI-failure branch below already relays them on
    # stdout. Found by the review OF the round-five fix.
    orca_unavailable_says
    return 1
  }
  local out err rc; out="$(mktemp)"; err="$(mktemp)"
  FLEET_RUN_STDERR="$err" orca_cli "$ORCA_CREATE_DEADLINE" "$out" worktree create \
    --repo "path:$repo" \
    --name "$name" \
    --issue "$issue" \
    --no-parent \
    --agent "$agent" \
    --prompt "$prompt" \
    --comment "$comment" \
    --json
  rc=$?
  if [ "$rc" != 0 ]; then
    # stderr FIRST. The three-line budget is the contract's, written for drivers
    # that do not exist yet, and a runtime that prints an error object on stdout
    # would push the actual reason off the end -- reintroducing the empty
    # "could not create it:" against a driver that is obeying the page. Orca
    # writes nothing to stdout on a failed --json call, so this costs nothing
    # here and is the whole fix elsewhere. Found by the independent review.
    cat "$err" "$out" | sed -n '1,3p'
    rm -f "$out" "$err"
    return "$rc"
  fi
  python3 -c '
import json,sys
try:
    print(json.load(sys.stdin)["result"]["worktree"]["path"])
except Exception:
    print("")
' <"$out"
  rm -f "$out" "$err"
  return 0
}

# Every worktree the runner is managing, as `path<TAB>branch<TAB>issue` lines.
# `-` where the runner has no answer for a field; nothing here may be JSON,
# because a caller that parses JSON has hardcoded this runner.
#
# The main worktree and archived ones are left out: the fleet counts these to
# decide whether it may launch, and neither of those is a slot.
#
# NON-ZERO WHEN THE ANSWER COULD NOT BE READ, which is not the same as "nothing
# is running". Reading a failed call as zero live worktrees is how one transient
# hiccup turns into three duplicate worktrees for issues that already have one.
runner_worktree_list() {
  local out rc; out="$(mktemp)"
  orca_json "$out" worktree list || { rm -f "$out"; return 1; }
  python3 -c '
import json, sys
try:
    worktrees = json.load(open(sys.argv[1]))["result"]["worktrees"]
except Exception:
    raise SystemExit(1)
for w in worktrees:
    if w.get("isMainWorktree") or w.get("isArchived"):
        continue
    print(w["path"], w.get("branch") or "-", w.get("linkedIssue") or "-", sep="\t")
' "$out"
  rc=$?
  rm -f "$out"
  return $rc
}

# This worktree's linked issue, if it has one.
#
# THREE answers, and the middle one is the whole reason this function is not a
# boolean: 0 with the issue on stdout, 2 for "there is no linked issue", 1 for
# "the runtime would not say". A hook that reads 1 as 2 announces that a
# worktree the fleet linked to an issue has none -- see orca_cli_resolve, which
# exists because that is exactly what happened.
runner_worktree_issue() {
  local out rc; out="$(mktemp)"
  orca_json "$out" worktree current || { rm -f "$out"; return 1; }
  python3 -c '
import json, sys
try:
    wt = json.load(open(sys.argv[1]))["result"]["worktree"]
except Exception:
    raise SystemExit(1)
for key in ("linkedIssue", "linkedLinearIssue", "linkedWorkItem"):
    if wt.get(key):
        print(wt[key] if isinstance(wt[key], (str, int)) else "linked")
        raise SystemExit(0)
raise SystemExit(2)
' "$out"
  rc=$?
  rm -f "$out"
  # A body that would not parse is the runtime failing to answer, not a worktree
  # without an issue: SystemExit(1) above and a dead CLI have to land together.
  return $rc
}

# Set metadata on one worktree, as `key value` PAIRS.
#
# Pairs rather than a single key because every caller sets a status and the
# comment explaining it, and two calls would put a new status on the board
# beside the previous line for as long as the second call takes -- or forever,
# if it is the one that fails. The keys the fleet uses are `workspace-status`
# and `comment`.
#
# Prints the runtime's own words on failure and nothing at all on success. The
# caller decides how loud that is; on this board it is said rather than
# swallowed, because a card that did not update is a status surface showing
# something that is not true.
#
# Any non-zero means the card was not updated. 2 specifically means the CALLER
# is malformed rather than the runtime unreachable -- see below.
#
# An odd number of arguments is REFUSED rather than rounded down. A caller that
# means `comment "..."` and passes `comment` alone would otherwise get a board
# update that silently did less than it was asked for -- and on a status surface
# that is the same failure as not updating at all, minus the message. It is also
# what keeps the expansion below safe on bash 3.2, where `"${args[@]}"` on an
# empty array under `set -u` is a fatal "unbound variable" rather than nothing.
runner_worktree_set() {
  local path="$1"; shift
  local args=() rc out
  if [ $# -lt 2 ] || [ $(($# % 2)) != 0 ]; then
    echo "runner_worktree_set: expected key/value pairs, got: $*" >&2
    return 2
  fi
  while [ $# -ge 2 ]; do
    args+=("--$1" "$2"); shift 2
  done
  # Same reason as create, one function up: `card` logs
  # "board update FAILED (rc $rc)" and then whatever this printed, so a failed
  # resolve that says nothing is a refusal with no cause under it. `orca_cli`
  # returns before it writes $out, so the relay below has nothing to relay.
  orca_cli_resolve || {
    orca_unavailable_says
    return 1
  }
  out="$(mktemp)"
  FLEET_RUN_CAPTURE_STDERR=1 orca_cli "$ORCA_DEADLINE" "$out" \
    worktree set --worktree "path:$path" "${args[@]}" --json
  rc=$?
  [ "$rc" = 0 ] || sed -n '1,3p' "$out"
  rm -f "$out"
  return $rc
}

# Remove one worktree. 0 only if it is REALLY gone, 1 if the runtime answered
# and refused, 2 if it never answered at all. The caller acts on the difference:
# a refusal is a decision about THIS worktree and is not worth retrying, while a
# deadline is Orca.app restarting and says nothing about the worktree.
#
# ## Why it forces on the second attempt
#
# A repository with a real submodule makes `git worktree remove` refuse outright:
#
#   fatal: working trees containing submodules cannot be moved or removed
#
# So the plain call fails on every worktree the fleet has ever created, every
# time, and it is not intermittent. Three accumulated in about eighteen hours on
# 2026-09-07, each holding four containers, two ports and four volumes that come
# back on every `docker start` under `restart: unless-stopped`.
#
# Forcing is safe HERE specifically: every caller checks the worktree holds
# nothing first. --force forces the worktree removal, not the branch deletion.
#
# ## Why the archive hook does not run through the CLI (armaatus/rommsync-nx#163)
#
# `orca worktree rm --run-hooks` runs orca.yaml's archive hook -- archive.sh,
# which takes the stack and its volumes down -- and it runs it BEFORE Orca
# decides whether it will remove the worktree at all. Orca then refuses (a dirty
# working tree, the submodule), and "could not remove it" has already destroyed
# the thing the worktree could not be worked in without:
#
#   16:49:15  #122: PR #159 is merged; marking it done and removing the worktree
#   16:49:32    could not remove it; sweep later with ./scripts/fleet/reap.sh
#
# That agent was mid-test-run. A suite failed after 90s with ~130 tests skipped
# behind it, and the fixture had lost its scan and its token -- none of which the
# log above suggests. So the removal is attempted with no hooks at all, and only
# a worktree that is genuinely GONE gets its stack swept, by the caller. A
# refusal now changes nothing.
#
# The second attempt is skipped after a deadline rather than after a refusal: a
# first call that hit it means nothing is answering, and a second 180s spent
# proving that doubles what a poll costs while Orca.app restarts.
runner_worktree_remove() {
  local path="$1" deadline="${2:-180}" out rc
  # A worktree that is ALREADY gone is gone, and saying so needs no runtime at
  # all. Asked before the resolve, or `reap_merged` could not release a slot with
  # nothing left in it while Orca was down -- which is the same held slot this
  # function's three-way answer exists to avoid.
  [ -d "$path" ] || return 0
  # Then resolved HERE rather than left to orca_cli, because this is the one
  # function whose rc 1 means something specific -- "answered and refused" -- and
  # orca_cli answers a failed resolve with 1 like everything else. Without this
  # line an Orca that is not running came back as a decision about THIS worktree,
  # with `the removal refused:` and nothing after it, and the dispatcher parked a
  # slot that only needed retrying. Design note 2 inverted inside the function
  # added to stop exactly that. Both found by the independent review.
  orca_cli_resolve || return 2
  out="$(mktemp)"
  FLEET_RUN_CAPTURE_STDERR=1 orca_cli "$deadline" "$out" \
    worktree rm --worktree "path:$path" --json
  rc=$?
  if [ ! -d "$path" ]; then rm -f "$out"; return 0; fi
  if [ "$rc" != 124 ]; then
    FLEET_RUN_CAPTURE_STDERR=1 orca_cli "$deadline" "$out" \
      worktree rm --worktree "path:$path" --force --json
    rc=$?
    if [ ! -d "$path" ]; then rm -f "$out"; return 0; fi
  fi
  if [ "$rc" = 124 ]; then rm -f "$out"; return 2; fi
  sed -n '1,3p' "$out"
  rm -f "$out"
  return 1
}

# What each worktree's agent is doing, as `path<TAB>state` lines.
#
# ONE listing, not one call per worktree: the dispatcher matches it against
# every owned worktree each poll, and three 30-second-deadline calls a minute
# for an answer that arrives in a single response is the shape this replaced.
#
# Non-zero when the listing could not be read. A worktree with no agent is
# simply absent, which is a real answer.
runner_agent_states() {
  local out rc; out="$(mktemp)"
  orca_json "$out" worktree ps || { rm -f "$out"; return 1; }
  python3 -c '
import json, sys
try:
    worktrees = json.load(open(sys.argv[1]))["result"]["worktrees"]
except Exception:
    raise SystemExit(1)
for w in worktrees:
    state = ((w.get("agents") or [{}])[0]).get("state") or ""
    if w.get("path") and state:
        print(w["path"], state, sep="\t")
' "$out"
  rc=$?
  rm -f "$out"
  return $rc
}

# Every live agent terminal on the machine, as `handle<TAB>worktree-path` lines.
#
# `orca terminal list` reports every terminal there is, so the worktree path is
# what keeps three parallel worktrees from sending into each other's agents;
# `agentIdentity` is what separates the agent tab from the shell and log tabs
# beside it, and `orphaned` is a handle whose terminal is already gone.
#
# Non-zero when the listing could not be read; an empty list means there are
# none, which the caller has to be able to tell apart.
runner_agent_terminals() {
  local out rc; out="$(mktemp)"
  orca_json "$out" terminal list || { rm -f "$out"; return 1; }
  python3 -c '
import json, sys
try:
    terminals = json.load(open(sys.argv[1]))["result"]["terminals"]
except Exception:
    raise SystemExit(1)
for t in terminals:
    if t.get("agentIdentity") and not t.get("orphaned"):
        print(t["handle"], t.get("worktreePath") or "-", sep="\t")
' "$out"
  rc=$?
  rm -f "$out"
  return $rc
}

# The composer text an agent has NOT sent, as a single comparable line: its
# length, a space, then the text with newlines flattened.
#
# Prints nothing when there is no draft, which is a normal answer rather than a
# failure -- non-zero means the read itself failed.
#
# Whole, not truncated: the caller reads the text back to decide whether the
# runtime drafted a real prompt or only the issue URL, and a 60-character prefix
# cannot tell a bare URL apart from one with instructions after it. The length
# prefix is what makes a paste caught half way through comparable to the same
# paste once it has landed.
runner_terminal_draft() {
  local out rc; out="$(mktemp)"
  orca_json "$out" terminal read --terminal "$1" --screen --limit 1 \
    || { rm -f "$out"; return 1; }
  python3 -c '
import json, sys
try:
    draft = json.load(open(sys.argv[1]))["result"]["terminal"].get("draft")
except Exception:
    raise SystemExit(1)
if draft and str(draft).strip():
    print(len(str(draft)), str(draft).strip().replace("\n", " "))
' "$out"
  rc=$?
  rm -f "$out"
  return $rc
}

# Type text into a terminal without submitting it.
runner_terminal_send() {
  orca_cli "$ORCA_SEND_DEADLINE" /dev/null \
    terminal send --terminal "$1" --text "$2" --json
}

# Submit whatever is in the composer.
runner_terminal_enter() {
  orca_cli "$ORCA_SEND_DEADLINE" /dev/null \
    terminal send --terminal "$1" --enter --json
}

# Interrupt the agent in a terminal. Both callers are about to take something
# away from it, and an agent that is not told keeps working against a rig that
# is going or already gone.
runner_terminal_interrupt() {
  orca_cli "$ORCA_SEND_DEADLINE" /dev/null \
    terminal send --terminal "$1" --interrupt --json >/dev/null 2>&1
}
