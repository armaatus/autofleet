#!/usr/bin/env bash
# The fleet: turn a list of issues -- or the whole backlog -- into merged PRs.
#
# Everything below this line is deterministic shell. No model runs here. The
# dispatcher's whole job is to decide WHICH issue gets a worktree and WHEN, and
# that decision has to be readable, interruptible and cheap to run for hours.
# The thinking happens inside the worktrees it opens.
#
#   ./scripts/fleet/fleet.sh run 11 12 13      # work exactly these, then hand off
#   ./scripts/fleet/fleet.sh run --auto        # keep taking `ready` issues
#   ./scripts/fleet/fleet.sh run --auto --until 08:00 --max-prs 5
#   ./scripts/fleet/fleet.sh status            # what is running, what is next
#   ./scripts/fleet/fleet.sh stop [--now]      # see "Stopping"
#   ./scripts/fleet/fleet.sh resume
#
# Run it in a terminal the runner opens in the main worktree, so the dispatcher
# is as visible as the work it starts. `fleet.sh` with no command prints the
# exact line for the configured runner -- it is the one instruction here that
# cannot be written runner-agnostically, so the driver supplies it.
#
# ## What it picks
#
# Anything `ready` and not already in flight, ordered by how many open issues
# name it in a `Blocked by #N` line. The work that frees the most other work goes
# first, which is the fastest way to turn a mostly-blocked backlog into a wide
# one. Milestones do not order it: `ready` already means every blocker is closed,
# and a milestone number is not a claim about what can be built now.
#
# Ahead of all of that: anything labelled `priority`. That is the one ordering a
# person states rather than derives, and it exists because the blocker graph
# cannot express "this one first" -- the only way to say it before was to file
# fake dependencies on issues that did not have them. It reorders the ready list
# and nothing else: a `blocked` or `needs-human-step` issue is no more startable
# for carrying it, and a foundation issue that is holding still holds. It can
# DELAY one, and the cost is bigger than "the foundation issue starts later".
# The scan BREAKS on the first foundation issue once anything is in flight, so
# every ready issue behind it in the list is skipped for that pass too --
# including issues that have nothing to do with it and are not `blocked`.
#
# Worked through, because this is the number a maintainer needs before applying
# the label. Ready list `[#151 priority, #F foundation, #A, #B]`, nothing in
# flight: pass 1 launches #151; pass 2 reaches #F, sees `live=1`, breaks, and #A
# and #B are never considered. The fleet runs at ONE worktree for #151's whole
# time-box, then at one worktree again while #F lands alone.
#
# Without the label the same backlog -- all four issues; #151 does not vanish
# when you take its label off -- sorts `[#A, #B, #151, #F]` and fills THREE,
# with #F waiting on them. An earlier version of this said `[#A, #B, #F]` fills
# three, which is wrong twice over: it drops #151, and that list fills two,
# because the scan breaks at #F with `live=2` for the very reason this passage
# exists to explain. Found by the independent review, which noted the number is
# the one the docs tell a maintainer to decide on.
#
# THAT ORDER STIPULATES A FOUNDATION ISSUE THAT FREES NOTHING, and that is the
# atypical one -- so read the comparison as a bound, not as the usual case. The
# second key is `-blocks`, so a `#F` named in even one open `Blocked by #N` line
# outranks three issues that free nothing and sorts FIRST, unlabelled. Run that
# through the same code: `[#F, #A, #B, #151]` launches #F on pass 1 and breaks on
# `is_foundation`, so the fleet is at ONE worktree while #F lands alone and fills
# three only afterwards. Labelled, the same backlog is one worktree for #151,
# then one for #F, then two.
#
# So: against a foundation issue that anything is waiting on -- the kind the
# "lands alone" rule exists for -- the label costs ONE EXTRA SOLO TIME-BOX, and
# the three-versus-one gap is the worst case, reached only when #F frees nothing.
# Either way it is time-boxes at one worktree and not a reordering, which is the
# thing to decide about. Found by the independent review, which noted the
# stipulation was doing the work the arithmetic was getting credit for.
#
# An earlier version of this comment said "nothing that depends on it could have
# started either way -- those are `blocked` -- so the rule holds", which is true
# and is the wrong reassurance: the dependants are not what stalls. Found by the
# independent review, which noted this change wrote all three copies of that
# sentence.
#
# ## Stopping
#
# The stop is a FILE, not a signal, and it lives outside every worktree
# ($HOME/.autofleet). That is deliberate: a signal only reaches a process
# that is still healthy, and the case you most need a stop in is the one where
# something is not.
#
# There are TWO of them, because "start nothing new" and "let nothing out" are
# two instructions and only one of them is the agents' (#183):
#
#   DRAIN   no new worktrees. Every stop sets it, and only this dispatcher reads
#           it. An agent mid-work carries on, pushes, opens its PR and comments
#           -- which is the point: a drain WAITS for those PRs to merge, because
#           a merged PR is what releases the worktree it is waiting on. A drain
#           that also froze them waited for what it had itself forbidden, and
#           ended only when the time-box gave each worktree up, three hours at a
#           time.
#   STOP    nothing goes out: no push, no PR, no comment, from any agent,
#           whether or not it has read the news. `stop --now` and `stop --all`
#           set it, and `.claude/hooks/guard.py`, `await-review.sh`,
#           `review-status.sh` and `resolve-thread.sh` are what make it hold
#           without cooperation.
#
# ## What it will not do
#
# It does not merge -- `merge-gate` and GitHub's auto-merge do that. It does not
# touch a worktree it did not create. And it removes one only when nothing goes
# with it: either that worktree's PR merged and the worktree is clean with
# nothing unpushed, or its issue can no longer produce a merged PR at all and the
# worktree is clean and holds no commit that is not already in origin/main. A
# removal that is REFUSED changes nothing either -- the stack comes down after
# the worktree is gone, never before.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
. ./scripts/fleet/lib.sh

# The state dir, the stop file and the owned-worktree registry come from
# lib.sh: `await-review.sh` and `guard.py` read the same paths, and a stop only
# some of them can see is not a stop.
STATE_DIR="$FLEET_DIR"
STOP_FILE="$FLEET_STOP"
DRAIN_FILE="$FLEET_DRAIN"
OWNED_DIR="$FLEET_OWNED"
STARTED_DIR="$STATE_DIR/started"
# The `Closes #N` and `Blocked by #N` patterns, shared with merge_gate.py so the
# dispatcher, the gate and GitHub cannot read the same body three ways. It sits
# under .github/scripts/ because merge-gate.yml sparse-checks out that directory
# alone; see the module's docstring.
#
# Set on each `python3` below rather than exported: the dispatcher runs for
# hours and shells out to gh, git, the Orca CLI and python constantly, and an
# exported PYTHONPATH would put this directory at the front of sys.path for
# every one of them. The first module added here whose name shadowed a stdlib
# one would then quietly change what they all import.
ISSUE_REFS="$REPO_ROOT/.github/scripts"
# One pass's worth of answers, and no longer. Emptied at the top of every poll
# by `cmd_run`, and NOWHERE ELSE -- not at startup, not by any other command.
#
# The poll cache belongs to whoever is POLLING, and until #35 every command
# emptied it at SOURCE TIME. So `status`, `stop`, `retry` and `resume` each
# deleted it out from under a live dispatcher mid-pass -- and `interrupted-$n`
# is the only thing stopping `reap_abandoned` re-interrupting an agent that
# `enforce_timebox` interrupted earlier in that same pass. docs/WORKFLOW.md
# tells you to run `status` in a loop until it says idle, so the way to hit it
# was to watch the fleet. It also dropped `issue-$n`, making every watcher
# re-issue the `gh issue view` that `poll_issue` exists to avoid.
#
# THERE IS NO CALL HERE AT ALL, which is #35's Acceptance in one line:
# "fleet.sh status leaves $STATE_DIR byte-identical". The first fix kept the
# source-time call and made it conditional on the dispatcher being dead, which
# (a) still wrote to $STATE_DIR on the ordinary idle path, and (b) had to get
# `dispatcher_alive`'s THREE answers right -- `||` collapses 2, "alive but ps
# would not say", into "no dispatcher", so on a host where ps cannot answer
# every `status` in the watch loop still wiped a live dispatcher's cache. The
# bug unfixed, in an environment this repo keeps three phases for.
#
# Deleting it removes both problems, and costs nothing: `cmd_run` empties the
# cache at the top of every pass before anything reads it, and NOTHING outSIDE
# `cmd_run` reads it. `poll_issue` and `foundation_in_flight` are called only
# from the poll body, from `launch`, and from the watchers the poll body calls.
# So a cache left behind by a dispatcher that died is never read by anyone --
# the staleness the conditional was protecting against is unobservable. Found by
# the independent review, which proposed exactly this.
POLL_CACHE="$STATE_DIR/poll-cache"
forget_poll_answers() { rm -rf "$POLL_CACHE"; mkdir -p "$POLL_CACHE"; }
LOG="$STATE_DIR/fleet.log"
PIDFILE="$STATE_DIR/fleet.pid"

# Three by default, because the ceiling is not machine capacity -- it is how
# many streams one person can review properly. AUTOFLEET_MAX in
# .autofleet/config moves it.
MAX_WORKTREES="${AUTOFLEET_MAX:-3}"
POLL_SECONDS="${AUTOFLEET_POLL:-60}"
# Long enough for a real issue including a full test run and both local review
# passes; short enough that an overnight run does not spend the night on the one
# task that was never going to work.
TIMEBOX_SECONDS="${AUTOFLEET_TIMEBOX:-10800}"
FOUNDATION_LABEL="${AUTOFLEET_FOUNDATION_LABEL:-foundation}"
# The human's thumb on the queue -- see "What it picks" above. Read in exactly one
# place that can change what STARTS (`ready_issues`, where it only sorts), plus
# `cmd_status`, which reports. That split is the point: an override that also
# decided what may start would be a second way past `blocked`, and this fleet has
# one set of rules about what is startable.
PRIORITY_LABEL="${AUTOFLEET_PRIORITY_LABEL:-priority}"
# An issue whose LAST step is outward, irreversible and the maintainer's --
# tagging a release, touching real hardware, signing something. The fleet may not
# finish one, so it does not start one, does not read an agent waiting on one as
# a stall, does not time-box it, and releases its worktree once there is nothing
# left in one (armaatus/rommsync-nx#139 needed a write guard.py refuses from a
# fleet worktree, so its agent correctly produced no PR and reap_merged would
# have waited for one forever). See docs/WORKFLOW.md, "an issue whose last step
# is a person's".
HUMAN_STEP_LABEL="${AUTOFLEET_HUMAN_STEP_LABEL:-needs-human-step}"
# unblock.yml's label, derived from the `Blocked by #N` lines below each issue's
# marker. The fleet only ever READS it, and it reads it for one thing: a
# worktree open on an issue that has SINCE gone blocked will never produce a
# merged PR, so it is holding a slot for nothing. On rommsync-nx, #148 went
# blocked with its worktree open and kept three other issues queued behind work
# that could not start.
BLOCKED_LABEL="${AUTOFLEET_BLOCKED_LABEL:-blocked}"
# poll_issue answers two questions in one string; issue_state_in and
# issue_labels_in split it here.
ANSWER_SEP="$(printf '\t')"

mkdir -p "$OWNED_DIR" "$STARTED_DIR"
# The poll cache is emptied further down, and only when nobody is using it: see
# the note above the dispatch at the end of this file. armaatus/autofleet#35.

say() { printf '%s  %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG"; }
die() { printf '%s\n' "$*" >&2; exit 1; }

# The two cases you would otherwise not learn about until morning: the fleet
# finishing, and an issue giving up. Everything else is on the runner's board.
notify() {
  command -v osascript >/dev/null 2>&1 || return 0
  osascript -e "display notification \"$(printf '%s' "$2" | sed 's/"/\\"/g')\" with title \"$AUTOFLEET_NOTIFY_TITLE\" subtitle \"$1\"" >/dev/null 2>&1 || true
}

# What every LAUNCH decision asks, and it is the drain rather than the stop: a
# hard stop sets both files, so this is true in both states and the dispatcher
# opens nothing new in either.
draining() { fleet_draining; }
# ...and what only the SCREEN asks, because the two states need different words
# on it. Nothing in here gates on this: refusing to launch under one and not the
# other is how the two would drift apart.
hard_stopped() { fleet_stopped; }
# The word for the state in force, and the file carrying it, for the two screens
# that need nothing more than the word: this one and `run`'s refusal. `status`
# and the notification say a sentence per state rather than a word, so they
# branch on `hard_stopped` themselves.
#
# Only meaningful once `draining` is true: with neither file set the state is
# empty, and the file named is the one a drain WOULD write.
stop_state() { hard_stopped && { echo stopped; return 0; }; draining && echo draining; }
stop_state_file() { hard_stopped && { printf '%s\n' "$STOP_FILE"; return 0; }; printf '%s\n' "$DRAIN_FILE"; }

# Named for what it gates rather than for the file it used to read: since the
# split it is the DRAIN that stops a launch, and `check_stop` at the call site
# read as the opposite of what it does.
check_drain() {
  draining || return 1
  say "$(stop_state) ($(stop_state_file)) -- not starting anything new"
  return 0
}

# ------------------------------------------------------------- the runner ---
# At SOURCE time, not at first use: everything below assumes a runner that
# answers, and a dispatcher that discovers otherwise three functions deep
# reports the consequence instead of the cause. The driver has already said why
# on stderr; this is the consequence.
runner_available || die "the $AUTOFLEET_RUNNER runner is not usable here, so there is nothing to dispatch with"

# The runner's board is the status surface: `in-progress` while it builds,
# `in-review` once the PR is up (the agent sets that itself), `completed` on
# merge. The comment is the one line the card shows.
#
# A failed update is SAID, not swallowed. WORKFLOW.md calls the board the status
# surface, so a card that did not update is a board showing something that is not
# true -- and the `|| true` this replaces meant the dispatcher reported nothing
# wrong while it happened. When the runner's CLI broke on 2026-09-05 (the Orca
# driver's orca_cli_resolve records it) every card in the fleet would have
# frozen in silence. Still non-fatal: the board is a display, and a display that cannot be
# written is not a reason to stop dispatching work.
#
# `key value` pairs, which is the driver's shape: a status and the comment
# explaining it go up together or the board carries one without the other.
card() {
  local path="$1" out rc; shift
  out="$(mktemp)"
  runner_worktree_set "$path" "$@" >"$out" 2>&1
  rc=$?
  if [ "$rc" != 0 ]; then
    say "  board update FAILED (rc $rc) for $path: $*"
    # The runner's own words -- the driver caps them, this only relays them.
    # They are the difference between "the app is not running" and "that
    # worktree is gone", and both look like silence.
    while IFS= read -r line; do
      [ -n "$line" ] && say "    $line"
    done <"$out"
  fi
  rm -f "$out"
  return 0
}

# Interrupt the agent in one worktree, if it has one. Both callers are about to
# take something away from it -- the time-box the rest of its hours, the release
# its whole directory -- and an agent that is not told keeps working against a rig
# that is going or already gone. `cmd_stop` spells this out for itself instead: it
# reports each interrupt it managed, which needs the exit code this swallows.
#
# A listing that could not be READ is said, once per call, rather than read as
# "there is no agent there". All three callers -- `cmd_stop`, `enforce_timebox`
# and `reap_abandoned` -- are about to take something away from that agent, and
# the two answers are opposite instructions to whoever is watching the log: one
# means nobody was working in there, the other means somebody is still working
# against a rig that is going. Design note 2, on the sibling of the `--all` path.
# Found by the independent review.
interrupt_agent_in() {
  local handle
  if ! handle="$(runner_agent_terminal "$1")"; then
    say "  the runner would not say whether an agent is in $1 -- none was interrupted"
    return 0
  fi
  [ -n "$handle" ] || return 0
  runner_terminal_interrupt "$handle"
  return 0
}

# --------------------------------------------------------------- the state ---
own() {
  printf '%s\n' "$2" >"$OWNED_DIR/$1"; date +%s >"$STARTED_DIR/$1"
  clear_issue_markers "$1"
}
owned_path()   { cat "$OWNED_DIR/$1" 2>/dev/null; }

# Every per-issue marker the dispatcher writes, in one list, because the bug
# this replaces was exactly one list drifting from another.
#
# All of these throttle a message to once per event. A marker that outlives the
# worktree that wrote it therefore does not misreport anything -- it SILENCES
# the next worktree for the same issue, which is worse, because the thing that
# goes missing is the line saying why. `own()` clears them for that reason: a
# fresh worktree starts with nothing already said on its behalf, and so does
# `disown_issue`, which is what stopped `stalled-` leaking one small file per
# issue that ever stalled. That is the root fix; the two exits in
# enforce_timebox tidying up after themselves is the belt.
#
# The `*-blind-` family is swept as a FAMILY rather than named one at a time.
# Every one of them means the same thing -- some lookup could not answer for this
# issue, said once -- and they are the markers most likely to be renamed, because
# they are named after whatever was doing the looking. `runner-blind-` was
# `orca-blind-` until the runner seam landed, and a fleet upgraded mid-flight has
# the old name on disk with nothing left that clears it. The glob also keeps a
# runner's name from having to appear here at all (hard rule 4).
clear_issue_markers() {
  rm -f "$STATE_DIR/stalled-$1" "$STATE_DIR/stall-labels-$1" \
        "$STATE_DIR/box-labels-$1" "$STATE_DIR/queue-labels-$1" \
        "$STATE_DIR/unreachable-$1" "$STATE_DIR/human-step-$1" \
        "$STATE_DIR/held-$1" "$STATE_DIR/stuck-$1" \
        "$STATE_DIR/warned-$1" "$STATE_DIR/parked-since-$1"
  # ...and the two park reasons the names above do not already cover. The
  # `*-blind-` glob below takes `git-blind-` and `merge-blind-`.
  rm -f "$STATE_DIR/merge-held-$1"
  # ONLY the `*` is unquoted. $STATE_DIR is `${AUTOFLEET_DIR:-$HOME/.autofleet}`,
  # both user-supplied paths: leaving the whole word bare word-splits a directory
  # with a space in it into two operands that match nothing, and the markers are
  # then never cleared -- silently, which is the failure this list exists to
  # prevent. Found by the independent review.
  rm -f "$STATE_DIR"/*-blind-"$1"
}

# `gaveup-` is the one per-issue marker deliberately NOT in that list, and the
# exception is load-bearing rather than an oversight. It records that this
# dispatcher stopped an agent at the time-box, and reap_abandoned then RELEASES
# that worktree -- which calls disown_issue. Clearing the record there would put
# the issue straight back at the front of a queue that has just spent three hours
# on it, once per cycle forever. It outlives the worktree on purpose, and only
# `fleet.sh retry N` clears it -- not a restart, because a crash and a reboot are
# not decisions about an issue.
gave_up_on()     { [ -e "$STATE_DIR/gaveup-$1" ]; }
gave_up_issues() { ls "$STATE_DIR" 2>/dev/null | sed -n 's/^gaveup-//p'; }

# The subset enforce_timebox owns, for its two exits.
forget_box_markers() {
  rm -f "$STATE_DIR/unreachable-$1" "$STATE_DIR/box-labels-$1" \
        "$STATE_DIR/human-step-$1"
}

disown_issue() {
  rm -f "$OWNED_DIR/$1" "$STARTED_DIR/$1"
  clear_issue_markers "$1"
}

# `issue<TAB>path`, which is the driver's `path<TAB>branch<TAB>issue` with the two
# columns this dispatcher reads brought to the front and the branch dropped: a
# column no caller reads is one the next caller reads wrong. Four callers depend
# on that order -- `waiting_worktrees`, `in_flight`, `foundation_in_flight` and
# `cmd_status` -- and it is stated here because the `awk` alone does not say it.
#
# THE PARK REASONS, in one place, with the sentence a person is told for each.
#
# There are five, and the count and the two places that REPORT them drifted
# apart the moment there were more than three: `count_parked_owned` learned
# `held-` and `git-blind-` and the farewell list and `cmd_status` did not, so a
# worktree could be counted as waiting for a person and then never named as one
# -- present in the tally, absent from the list that says what to do about it.
# That is worse than not counting it at all. One list, three readers.
#
# `why_parked <issue>` prints the reason, or nothing when that issue is not
# parked. Order is deliberate where two can coexist: a refused removal is the
# one a person acts on, so it wins over "git could not say".
# THERE IS NO `PARK_REASONS` LIST, and that is deliberate. One was added here
# under a comment promising "one list, three readers", and it had NO reader:
# `why_parked`, `how_to_release` and the phase each enumerated the five by hand,
# so the list was the drift it was added to prevent, one indirection later. An
# attempt to make it load-bearing through `clear_issue_markers` failed too --
# that function's existing `*-blind-` glob and explicit names already cover all
# five, so removing a reason from the list changed nothing.
#
# `why_parked` below IS the single source: it is the only place that knows what
# parks a worktree and what a person is told about it, and the three readers ask
# IT rather than a list beside it. Found by the independent review.
why_parked() {
  local n="$1"
  [ -e "$STATE_DIR/stuck-$n" ]       && { printf 'its removal was refused\n'; return 0; }
  [ -e "$STATE_DIR/merge-held-$n" ]  && { printf 'merged, and it holds uncommitted work\n'; return 0; }
  [ -e "$STATE_DIR/held-$n" ]        && { printf 'it holds uncommitted work\n'; return 0; }
  [ -e "$STATE_DIR/merge-blind-$n" ] && { printf 'merged, and git could not say what it holds\n'; return 0; }
  [ -e "$STATE_DIR/git-blind-$n" ]   && { printf 'git could not say what it holds\n'; return 0; }
  return 1
}

# ...and what to DO about it, which is not the same line for all five.
#
# `BY_HAND_REMOVAL` is `git worktree remove --force`, and it was printed from one
# place -- `park_worktree`, on the one path where the dispatcher had already
# established that nothing goes with the worktree. Printed for every reason it
# tells a person to discard exactly what the line above it says is in there:
# "it holds uncommitted work", then `--force`. #37's Design notes are explicit --
# "what must NOT happen is releasing the worktree to make the loop terminate:
# the whole reason it is parked is that removing it would destroy something" --
# and the dispatcher kept that promise itself while breaking it through the
# operator, two lines apart. Found by the independent review.
how_to_release() {
  local n="$1" path="$2"
  if [ -e "$STATE_DIR/stuck-$n" ]; then
    printf "$BY_HAND_REMOVAL" "$path"
    return 0
  fi
  # Everything else is "there is something in there", or "git would not say
  # whether there is". Look first; the removal is the operator's call afterwards.
  printf 'git -C %s status --short   # then commit, move or discard what is there' "$path"
}

# How many OWNED worktrees are waiting for a person rather than for an agent.
#
# EVERY reason a worktree waits for a person, and there are FIVE. `stuck-`
# is a refused removal; `merge-held-` a merged worktree still holding
# uncommitted work; `merge-blind-` one whose git could not say what it holds
# -- which the change that added this counter also made permanent, since
# nothing recreates a pruned upstream. `reap_abandoned` keeps two more, and
# an earlier version of this comment asserted they did not exist: `held-`,
# when the issue is closed, blocked or timed out and the worktree holds
# uncommitted work, and `git-blind-`, when its git state could not be read.
# Neither is exotic -- an agent whose issue goes `blocked` with one commit in
# its worktree reaches `held-` -- and uncounted, `owned` never reaches 0 and
# the drain never ends. That is #37's unbounded drain through a different
# door, in the PR that closes #37. Found by the independent review.
#
# COUNTED PER ISSUE, not per marker, which is the other half of the same
# finding. One worktree can carry two of these at once: `reap_merged` writes
# `merge-blind-42` and keeps it owned, then `reap_abandoned` runs on that
# same entry in the same pass -- its own header wrongly assumes a merged
# worktree has been disowned by now -- reads `origin/main` rather than `@{u}`
# so it CAN answer, finds nothing held, and a refused removal writes
# `stuck-42` beside it. Two markers, one worktree, `parked` over-counts by
# one, and `owned` goes to 0 with another worktree mid-work: the dispatcher
# exits, its stack up under `restart: unless-stopped`. The `-lt 0` clamp is
# what made that a silent wrong answer instead of a visible one.
  # ...and only the ones that are actually OWNED. The two counts come from
  # different directories, and a stale marker with no owned entry would make
  # `owned` under-count and the dispatcher exit with a worktree still in
  # flight -- the failure the drain bound exists to prevent, inverted.
  # `disown_issue` -> `clear_issue_markers` keeps the pair together on
  # release, and `reap_merged`'s `[ -d "$path" ] || disown_issue` self-heals
  # a missing directory, so this test is what closes the remaining gap.
# Still clamped, and now it should be unreachable: `parked` counts distinct
# owned issues, so it cannot exceed `owned`. Kept because a wrong answer here
# ends the dispatcher with work in flight, and a clamp is cheaper than that.
# Is this issue's worktree waiting for a PERSON, rather than for an agent?
#
# `why_parked` answers "does it carry a keep-marker", which is not the same
# question: the two `reap_abandoned` markers are written while the agent is
# deliberately left running. `count_parked_owned` wrapped that predicate in an
# agent gate and `cmd_status` called it raw, so a worktree the counter refused
# to call parked was printed by `status` as parked -- and told a person to go
# and discard what is in a directory somebody is writing to. Same crack,
# opposite direction. One predicate now. Found by the independent review.
#
# Prints the reason, or nothing. Non-zero when it is not waiting for a person.
# The second argument is the VOICE, and it is the difference between a poll and
# a look. `say` is `tee -a "$STATE_DIR/fleet.log"` and the `ps-blind-` latch is
# per-issue dispatcher state, so a caller that does either is WRITING to
# $STATE_DIR. #35's Acceptance -- the issue this PR closes -- is "fleet.sh
# status leaves $STATE_DIR byte-identical", and `cmd_status` reached this
# function for every live worktree. WORKFLOW.md tells an operator to run
# `status` in a loop until it says idle, so the first look created the latch and
# the dispatcher's own terminal then never printed the sentence explaining why
# the drain had become unbounded -- it survived in fleet.log alone. A read-only
# command consuming a live dispatcher's said-once marker because somebody
# looked: the same shape as the bug #35 is about, through the door #37 opened.
# Only `count_parked_owned`, which runs in the poll body, passes `say`. Found by
# the independent review.
parked_for_person() {
  local n="$1" voice="${2:-quiet}" reason listing state
  reason="$(why_parked "$n")" || return 1
  # EVERY reason that means "there is something in there" is gated, not just the
  # two `reap_abandoned` writes. The gate used to be reached only when a `held-`
  # or `git-blind-` marker was on disk, so `merge-held-` and `merge-blind-`
  # matched the pattern, failed that test, and were counted with no agent check
  # at all -- and `reap_merged`'s own comment says why the tree is dirty there:
  # "auto-merge fires the moment the last check passes, so review fixes made
  # after it sit uncommitted here". That is an agent mid-work, in the window
  # CLAUDE.md step 6 exists for. The last worktree's PR auto-merges while its
  # agent is making review fixes, and two passes later the dispatcher signs off
  # with it still writing.
  #
  # `stuck-` is the exception and stays ungated: a refused removal is the
  # dispatcher having already ASKED and been told no, and gating it on a stale
  # marker beside it is how the drain hung two rounds ago. Found by the
  # independent review.
  case "$reason" in
    *"holds uncommitted work"|*"git could not say what it holds")
      if ! listing="$(runner_agent_states)"; then
        # SAID, once per pass. Taking the safe direction silently is #37's own
        # complaint -- "nothing says the drain has become unbounded". One
        # unreadable `worktree ps` is a hiccup; a persistent one means this
        # worktree never counts, `owned` never reaches 0 and the drain never
        # ends, and the operator has no way to know why. `live_worktrees`
        # already says the equivalent for its own call. Found by the independent
        # review.
        # The `*-blind-` family idiom: one marker per issue, said once, and
        # swept with the rest when the issue is released.
        if [ "$voice" = say ] && [ ! -e "$STATE_DIR/ps-blind-$n" ]; then
          : >"$STATE_DIR/ps-blind-$n"
          say "  could not read the agent states, so whether #$n is still being"
          say "  worked in cannot be answered -- it is NOT counted as waiting for"
          say "  you, and a drain will not end while that stays true"
        fi
        return 1
      fi
      # Releasing the latch is the milder half of the same write -- it makes the
      # dispatcher re-say a line it already said -- but it is still a write, so
      # it is the poll's to make too.
      if [ "$voice" = say ]; then rm -f "$STATE_DIR/ps-blind-$n"; fi
      state="$(printf '%s' "$listing" | fleet_state_for_path "$(owned_path "$n")")"
      case "$state" in working) return 1 ;; esac ;;
  esac
  printf '%s\n' "$reason"
}

count_parked_owned() {
  local parked=0 n
  # Over OWNED issues rather than over markers: one worktree can carry two
  # reasons at once, and counting markers made `parked` exceed the worktrees it
  # described. `why_parked` is the same predicate `status` and the farewell use.
  #
  # A MARKER MUST SURVIVE A PASS BEFORE IT COUNTS, and that is the difference
  # between ending a drain and ending it too early. `stuck-` is terminal --
  # written once on a refused removal and never retried. `held-` and
  # `git-blind-` are RE-DERIVED every pass and cleared the moment the reason
  # goes away, which is routine: `unblock.yml` rewrites `blocked` on every merged
  # PR, so an issue can go blocked, be warned, come off `blocked` when its
  # dependency lands, and go blocked again. Counting those the pass they appear
  # let one transient label -- or one `worktree_holdings` hiccup -- drop `owned`
  # to 0 and sign the dispatcher off with an agent still writing in there. That
  # is #36's failure through a fifth door, opened by the fix for #37.
  #
  # Surviving a pass costs one poll of waiting on a worktree that really is
  # parked, and costs nothing at all on `stuck-`, which is still there next pass.
  for n in $(ls "$OWNED_DIR" 2>/dev/null); do
    if ! why_parked "$n" >/dev/null; then
      rm -f "$STATE_DIR/parked-since-$n"
      continue
    fi
    # ...and the agent gate, through the shared predicate so `status` cannot
    # disagree with this count about the same worktree.
    if ! parked_for_person "$n" say >/dev/null; then
      rm -f "$STATE_DIR/parked-since-$n"
      continue
    fi
    if [ -e "$STATE_DIR/parked-since-$n" ]; then
      parked=$((parked + 1))
    else
      : >"$STATE_DIR/parked-since-$n"
    fi
  done
  printf '%s\n' "$parked"
}

# NON-ZERO WHEN THE ANSWER COULD NOT BE READ, which is not the same as "nothing
# is running": reading a failed call as zero live worktrees is how one transient
# hiccup turns into three duplicate worktrees for issues that already have one,
# because `in_flight` goes blind at the same moment and from the same list.
#
# (These ten lines were removed with the selector's comment block and re-homed
# here by the independent review. The selector prose had to go -- it named a
# runner's flag in the file hard rule 2 says may not know one. This half names
# no runtime and was collateral.)
live_worktrees() {
  local list
  list="$(runner_worktree_list)" || return 1
  printf '%s' "$list" | awk -F'\t' 'NF { print $3 "\t" $1 }'
}

# Prints the count, or fails. A caller that cannot tell how many are running
# must not launch anything.
live_count() {
  local list
  list="$(live_worktrees)" || return 1
  count_worktrees "$list"
}

# How many worktrees a listing holds. Split out because the launch loop needs
# the count AND the names from ONE listing: two calls would let the count that
# shut the gate and the names printed beside it disagree.
count_worktrees() { printf '%s\n' "$1" | grep -c . || true; }

# What a held foundation issue is actually waiting for, as `#N` where the
# worktree is linked to an issue and a basename where it is not. A count alone
# names nothing a person can go and land -- and the two are not equivalent, since
# one may be this repo's in-flight work and the other a worktree nobody here can
# close. armaatus/autofleet#46 was a line that could not say which, repeating indefinitely.
#
# $1 is the listing the caller already has, for the reason above.
#
# Sorted, because the caller keys its say-once marker on this string: unsorted,
# two unchanged worktrees coming back in the other order read as news and
# reprint the line every poll. `-V` rather than a plain sort -- lexically `#42`
# comes before `#7`, which is the wrong order for the one question a person asks
# of it.
waiting_worktrees() {
  printf '%s\n' "$1" | while IFS="$(printf '\t')" read -r num path; do
    [ -n "$path" ] || continue
    if [ "$num" = "-" ]; then printf '%s\n' "$(basename "$path")"; else printf '#%s\n' "$num"; fi
  done | sort -V | tr '\n' ' ' | sed 's/ $//'
}

# --------------------------------------------------------------- the queue ---
# Every open issue, with how many other open issues are blocked BY it. That
# number is the SECOND key, not the ordering: `priority` sorts ahead of it (see
# "What it picks" above), and within one priority class the work that frees the
# most other work goes first.
# It reads the same `Blocked by #N` lines unblock.yml parses, so nothing new has
# to be maintained.
ready_issues() {
  GH_PAGER=cat gh issue list --state open --limit 200 \
    --json number,title,body,labels 2>/dev/null \
    | PYTHONPATH="$ISSUE_REFS" python3 -c '
import json, sys
from issue_refs import blocked_by
human_step, priority = sys.argv[1], sys.argv[2]
issues = json.load(sys.stdin)


def has(issue, label):
    return any(l["name"] == label for l in issue.get("labels", []))

blocks = {}
for i in issues:
    for n in blocked_by(i.get("body")):
        blocks[n] = blocks.get(n, 0) + 1
# `ready` says every blocker is closed. It does not say an agent can finish the
# work: an issue whose last step belongs to a person stays open through the PR
# that prepares it, and stays `ready` with it. #148 was picked up again 18
# seconds after its own preparatory PR merged, and would have been picked up
# once per cycle forever, each attempt further from the point.
ready = [i for i in issues if has(i, "ready") and not has(i, human_step)]
# Priority first, then most-unblocking, then oldest issue number: predictable
# inside a tie. The priority flag is a BOOLEAN in the key and not a weight -- a
# labelled issue outranks every unlabelled one whatever either unblocks, which is
# the whole of what a person applying the label is asking for. Within the
# labelled set the ordinary ordering still decides, so labelling five issues does
# not throw away what the queue itself says about which of the five goes first.
# NOTE: no apostrophes anywhere in this block -- it lives inside a single-quoted
# `python3 -c` string, and one closes it.
for i in sorted(ready, key=lambda i: (not has(i, priority),
                                      -blocks.get(i["number"], 0),
                                      i["number"])):
    labels = ",".join(l["name"] for l in i.get("labels", []))
    print(i["number"], blocks.get(i["number"], 0), labels, i["title"], sep="\t")
' "$HUMAN_STEP_LABEL" "$PRIORITY_LABEL"
}

# `ready` overstates availability: the label stays until the PR merges, so an
# issue with a PR already open still carries it.
# 0 = a PR closes it, 1 = none does, 2 = could not tell. The third answer is
# not decoration: python printing nothing is what "no PR" looks like, and it is
# also what a failed import or a malformed listing looks like. Read as "free",
# that opens a second worktree for work already in flight -- which is the whole
# failure this shared module exists to prevent.
has_open_pr() {
  local found
  # The issue number goes in as an ARGUMENT, not spliced into the source. A PR
  # body is third-party text and so, in principle, is anything that reaches the
  # pattern.
  found="$(GH_PAGER=cat gh pr list --state open --json number,body --limit 100 2>/dev/null \
    | PYTHONPATH="$ISSUE_REFS" python3 -c '
import json, sys
from issue_refs import closes_issue
try:
    prs = json.load(sys.stdin)
except ValueError:
    raise SystemExit("could not read the pull request listing")
for p in prs:
    if closes_issue(p.get("body"), sys.argv[1]):
        print(p["number"]); break
' "$1")" || return 2
  [ -n "$found" ]
}

# 0 = in flight, 1 = free, 2 = could not tell. The third answer matters: a
# caller that treats "could not tell" as "free" opens a second worktree for work
# that is already running.
in_flight() {
  local list rc
  list="$(live_worktrees)" || return 2
  printf '%s\n' "$list" | cut -f1 | grep -qx "$1" && return 0
  has_open_pr "$1"; rc=$?
  [ "$rc" = 0 ] && return 0
  [ "$rc" = 2 ] && return 2
  return 1
}

# $1 is a comma-separated label list, $2 one label. Exact matches only: `ready`
# must not answer for `ready-ish`, and `foundation` must not answer for
# `foundational`. -F and -- keep that true for a label carrying a regex
# metacharacter or a leading dash, both of which the env overrides above allow.
has_label() { printf '%s' "$1" | tr ',' '\n' | grep -qxF -- "$2"; }
is_foundation() { has_label "$1" "$FOUNDATION_LABEL"; }

FOUNDATION_HOLD_SAID="$STATE_DIR/holding-for-foundation"
# The rotation's say-once marker, named here rather than spelled out at each
# use: it was written as a bare path at three sites, and a list of literals is
# the drift `clear_issue_markers` already has a comment about. In $STATE_DIR so
# it outlives a poll, cleared when a dispatcher STARTS -- the same rule, for the
# same reason, as the one above. Found by the independent review.
ROTATE_BLIND_SAID="$STATE_DIR/rotate-blind"
# Its sibling for "the rotation could not happen at all" is a VARIABLE, not a
# file, and that is the whole point: the condition it reports is a $STATE_DIR
# nothing can write to, so a marker in $STATE_DIR cannot be created in exactly
# the case it exists for and the line repeats anyway. A variable is once per
# dispatcher, which is what the marker was reaching for -- a new process starts
# with it empty, so "cleared at dispatcher start" comes for free. Found by the
# independent review, and by the first fix for it, which used a file.
ROTATE_STUCK_SAID=""

# Hold, remember the reason, and say it if it is news. The three branches below
# were three copies of `printf hold` / `foundation_hold_say` / `return 0`, which
# is three chances to write a fourth that caches a hold and never explains it.
# NOTE the call convention: `foundation_hold ... && return 0`. A `return` in here
# returns from THIS function, not from `foundation_in_flight` -- collapsing the
# three branches into it without that dropped every hold straight through to
# "nothing in flight", which three phases caught at once.
foundation_hold() {
  local cached="$1" what="$2"; shift 2
  printf 'hold' >"$cached" 2>/dev/null || true
  foundation_hold_say "$what" "$@"
}

# How long a standing hold stays quiet before it says itself again.
#
# Without this the marker never expires: it is cleared by a launch and at
# dispatcher start, and a hold that lifts and returns hours later with nothing
# launched in between says nothing, because the marker still names it. The
# benign end of that is a label flapping; the other end is a fleet that has
# opened no worktree since morning with the explanation scrolled off the log.
# Hourly against a 60-second poll is 1 line where the bug was 180, and it is
# still an answer for somebody who runs `tail fleet.log` at noon. Found by the
# independent review.
: "${AUTOFLEET_HOLD_RESAY:=3600}"

# Say something once per reason, remembering the reason in $1.
#
# ONE MARKER PER THING BEING HELD. This took a single shared file, so two
# different holds -- a foundation issue in flight and a PR whose reviewer hit
# the cap -- overwrote each other's reason every poll and BOTH re-announced,
# once a minute, forever. That is the flooding this whole change exists to
# remove, reintroduced by the fix for it. The two holds are also evaluated in
# the same poll body, which is what made it certain rather than unlucky. Found
# by the independent review.
hold_say_into() {
  local where="$1" what="$2"; shift 2
  local said_at now stale=false
  said_at="$(fleet_mtime "$where")" || said_at=""
  now="$(date +%s)"
  # Guarded, because an mtime this could not read must degrade to "say it" and
  # never to an arithmetic error inside the dispatcher's poll.
  case "$said_at" in
    ''|*[!0-9]*) stale=true ;;
    *) [ "$(( now - said_at ))" -ge "$AUTOFLEET_HOLD_RESAY" ] && stale=true ;;
  esac
  if $stale || [ "$(cat "$where" 2>/dev/null)" != "$what" ]; then
    printf '%s' "$what" >"$where" 2>/dev/null || true
    local line
    for line in "$@"; do say "$line"; done
  fi
}

foundation_hold_say() { hold_say_into "$FOUNDATION_HOLD_SAID" "$@"; }

# Is one of the worktrees in flight working on a FOUNDATION issue?
#
# CLAUDE.md: "a foundation issue lands alone. When an issue defines an interface
# later issues include, it merges before anything that depends on it starts."
# The dispatcher enforced half of that -- a foundation issue would not JOIN
# running worktrees -- and nothing stopped others joining a foundation issue. On
# a cold start `live` is 0, so the foundation issue is picked first, `live`
# becomes 1, and every later candidate that pass is not itself a foundation
# issue and sails past the check.
#
# That is not theoretical. autofleet's own first real run, in eleven seconds:
# #1 (foundation, the runner driver), then #4 (docs/WORKFLOW.md, which describes
# the runner), then #7 (install.sh, which lists what ships and which #1 adds
# runner files to). Three worktrees on exactly the collision the rule exists to
# prevent.
#
# `live` is a COUNT, and the rule is about what those worktrees are working on --
# which is why this asks the issues rather than the number, and why it keeps
# holding across a dispatcher restart, where the count alone says nothing.
#
# 0 = yes, hold. 1 = no. Never 2: an unreadable answer HOLDS, and says so, for
# the same reason `in_flight` treats "could not tell" as in flight -- launching
# on a guess is the expensive direction, and the next pass asks again.
#
# ONE ANSWER PER POLL, cached in $POLL_CACHE like every other repeated lookup in
# this file: the launch loop asks up to MAX_WORKTREES times per pass and the
# answer cannot change in between except by this loop launching something, which
# is what `launch` invalidates it for. An earlier version of this claimed no new
# API call while making one per iteration.
#
# It is still a SECOND read of the worktree list in a pass -- `live_count` has
# one and `count_startable` takes a third -- so the "one answer per poll"
# convention this follows within itself is not yet followed across the three.
# Caching `live_worktrees` itself is the fix and it belongs to all three callers
# rather than to this one; armaatus/autofleet#30 has it. Named here rather than left as a comment
# that quietly overstates. Found by the independent review.
#
# ...and it SAYS SO ONCE, not once per poll, which is a different question from
# the cache: a three-hour foundation issue against a 60-second poll is 180
# identical lines in fleet.log. The marker in $STATE_DIR is this file's idiom for
# it -- `queue-labels-$n` and `gaveup-$n` are the same shape -- and it is cleared
# the moment the hold ends, so the next hold speaks again. Both found by the
# local review of the change that added this.
# In $STATE_DIR so it outlives a POLL, and cleared when a dispatcher STARTS --
# the same rule $POLL_CACHE follows and for the same reason. Left standing across
# a restart, a new dispatcher reads back the old one's marker and holds in total
# silence: zero worktrees opened and not one line in fleet.log saying why, which
# is precisely the case this function's own comment says it exists for. Found by
# the local review of the change that added it.
foundation_in_flight() {
  local cached="$POLL_CACHE/foundation" list n _path answer labels
  mkdir -p "$POLL_CACHE" 2>/dev/null
  # TWO VALUES, because two is all anything reads. It used to write four --
  # `no`, `unreadable`, `labels-unreadable-$n`, `$n` -- while only ever asking
  # `= no`, so three of them implied a contract nothing honoured. The REASON for
  # a hold is carried by the say-once marker, which is the thing that needs it.
  # Found by the independent review.
  if [ -e "$cached" ]; then
    [ "$(cat "$cached")" = no ] && return 1
    return 0
  fi

  if ! list="$(live_worktrees)"; then
    foundation_hold "$cached" "list-unreadable" \
      "could not read this repository's worktree list, so whether a foundation" \
      "  issue is in flight cannot be answered -- launching nothing rather than guessing"
    return 0
  fi

  # Every number below is resolved against THIS repository, which is safe only
  # because `runner_worktree_list` is scoped to it -- see the driver. It was not,
  # and an unrelated worktree whose linked number matched a `foundation` issue
  # here -- or matched nothing here at all, which fails the lookup and holds
  # fail-closed -- stopped the fleet launching anything, indefinitely, after a
  # single line in the log.
  #
  # The premise was older than this function: `in_flight` and `count_startable`
  # shared it, where it merely inflated a count. Here it was fatal rather than
  # inaccurate, which is why it is written down. Fixed in
  # armaatus/autofleet#46, in `runner_worktree_list` -- the driver scopes the
  # query, so all three callers get it at once. Found by the independent review.
  while IFS="$(printf '\t')" read -r n _path; do
    # `-` is `live_worktrees` saying this worktree has no linked issue at all,
    # which is a worktree somebody opened by hand. That is an ANSWER, not a
    # failure to answer -- a worktree on no issue is on no foundation issue --
    # so it does not hold, unlike the two lookups below that genuinely cannot
    # say. The distinction was implicit and is now written down.
    case "$n" in ''|-|*[!0-9]*) continue ;; esac
    if ! answer="$(poll_issue "$n")"; then
      foundation_hold "$cached" "labels-$n" \
        "#$n is in flight and its labels would not read, so whether it is a" \
        "  foundation issue cannot be answered -- launching nothing"
      return 0
    fi
    # The STATE half of the answer, not just the labels. A foundation issue that
    # has been closed -- merged, and its worktree not yet reaped -- is finished,
    # and holding the whole fleet for it until the reap catches up is a stall
    # with no reason left behind it. `poll_issue` returns both halves and this
    # used only one. Found by the independent review.
    case "$(issue_state_in "$answer")" in
      CLOSED|closed) continue ;;
    esac
    labels="$(issue_labels_in "$answer")"
    if is_foundation "$labels"; then
      foundation_hold "$cached" "$n" \
        "#$n is a foundation issue and is still in flight; it lands alone, so" \
        "  nothing else starts until it does"
      return 0
    fi
  done <<<"$list"

  printf 'no' >"$cached" 2>/dev/null || true
  # NOT cleared here, and that is the fix rather than an omission.
  #
  # This function runs first on every iteration, so the only way the OTHER hold
  # -- a foundation CANDIDATE declining to join ordinary worktrees -- is ever
  # reached is by this one falling through to here. Clearing the marker on the
  # way past deleted it one step before `foundation_hold_say "waiting-$n"` read
  # it, so that marker was write-only and the line it guards printed every poll:
  # exactly the 180-lines-per-three-hours the marker exists to prevent, restored
  # by the change that claimed to prevent it. Found by the independent review,
  # which also noted that no phase covered that branch -- which is why it
  # survived.
  #
  # `launch` clears it instead: a hold announcement is stale once the fleet has
  # actually moved, and until then repeating it says nothing new.
  return 1
}

# Everything the watchers ask GitHub about ONE issue, in one call and one answer
# per POLL. Prints `<state><TAB><labels>`; 0 = read it, 2 = could not tell.
#
# The third answer is the same one has_open_pr gives, for the same reason: the
# callers below interrupt an agent, comment on an issue and delete a worktree,
# and a listing that could not be read is no basis for any of those. Asked live
# rather than cached at launch, because a label is often what a person adds AFTER
# seeing the card.
#
# One answer per issue per POLL, though. reap_abandoned, enforce_timebox and
# notice_stalled all ask about the same issue in the same pass -- an issue stuck
# long enough to overrun is often also the one sitting at a prompt, and the one a
# maintainer has just blocked -- and three calls for one answer is the pattern
# count_startable exists to avoid. State and labels come back together for that
# same reason: they are one `gh issue view`, not two. The cache lives for one
# pass, so a label a person adds is still seen on the next one.
poll_issue() {
  local cached="$POLL_CACHE/issue-$1" answer
  mkdir -p "$POLL_CACHE" 2>/dev/null
  [ -e "$cached.unreadable" ] && return 2
  [ -e "$cached" ] && { cat "$cached"; return 0; }
  if answer="$(GH_PAGER=cat gh issue view "$1" --json state,labels \
                 --jq '.state + "\t" + ([.labels[].name]|join(","))' 2>/dev/null)"; then
    printf '%s' "$answer" >"$cached" 2>/dev/null || true
    printf '%s' "$answer"
    return 0
  fi
  : >"$cached.unreadable" 2>/dev/null || true
  return 2
}

# The two halves of what poll_issue prints. Split here rather than at each call
# site so a `gh` that ever answers without the separator cannot be read as a
# state that is also a label list: both print nothing at all instead.
issue_state_in()  { case "$1" in *"$ANSWER_SEP"*) printf '%s' "${1%%"$ANSWER_SEP"*}" ;; esac; }
issue_labels_in() { case "$1" in *"$ANSWER_SEP"*) printf '%s' "${1#*"$ANSWER_SEP"}" ;; esac; }

# Is this issue's last step a person's? 0 = yes, 1 = no, 2 = could not tell.
issue_needs_human_step() {
  local answer
  answer="$(poll_issue "$1")" || return 2
  has_label "$(issue_labels_in "$answer")" "$HUMAN_STEP_LABEL"
}

# Landed: the issue is closed, or a PR that closes it has merged. `ready` does
# not answer this -- unblock.yml only relabels dependants -- and neither does
# "no worktree", which is also true of work that never started.
issue_is_done() {
  local state
  state="$(GH_PAGER=cat gh issue view "$1" --json state --jq .state 2>/dev/null)"
  [ "$state" = "CLOSED" ] && return 0
  local landed
  # A failed lookup answers "not done", the same as before: an issue that stays
  # on `fleet.sh run 11 12 13` is retried, which is the harmless direction. It
  # is not silently conflated with a real answer, though -- see has_open_pr.
  landed="$(GH_PAGER=cat gh pr list --state merged --limit 50 --json body 2>/dev/null \
    | PYTHONPATH="$ISSUE_REFS" python3 -c '
import json, sys
from issue_refs import closes_issue
try:
    prs = json.load(sys.stdin)
except ValueError:
    raise SystemExit("could not read the pull request listing")
for p in prs:
    if closes_issue(p.get("body"), sys.argv[1]):
        print("done"); break
' "$1")" || return 1
  [ -n "$landed" ]
}

# How many `ready` issues could start right now, from ONE worktree list and ONE
# PR list. Zero also means "nothing to wait for" to the run loop, so it must not
# silently answer zero when a lookup failed -- it returns non-zero instead.
count_startable() {
  local live prs ready gaveup
  live="$(live_worktrees)" || return 1
  prs="$(GH_PAGER=cat gh pr list --state open --json body --limit 100 2>/dev/null)" || return 1
  ready="$(ready_issues)" || return 1
  # An issue the fleet gave up on is one it will decline every pass, so counting
  # it is the run loop polling forever for work that never starts.
  gaveup="$(gave_up_issues)"
  printf '%s\n' "$ready" | PYTHONPATH="$ISSUE_REFS" python3 -c '
import json, sys
from issue_refs import closes
running = {line.split("\t")[0] for line in sys.argv[1].splitlines() if line.strip()}
gave_up = {n for n in sys.argv[3].split() if n}
# One parse per BODY, not one over all of them joined: a keyword may be the last
# word of one body and `#12` the first token of the next, and `\s+` would span
# the join -- claiming an issue nobody is working on and hiding it from the
# count. One parse per issue would be the other way round; this is neither.
claimed = set()
for p in json.loads(sys.argv[2]):
    claimed.update(closes(p.get("body")))
n = 0
for line in sys.stdin:
    if not line.strip():
        continue
    issue = line.split("\t")[0]
    if issue in running or issue in gave_up or int(issue) in claimed:
        continue
    n += 1
print(n)
' "$live" "$prs" "$gaveup"
}

# --------------------------------------------------------------- the launch ---
slug() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | tr -cs 'a-z0-9' '-' | sed 's/^-*//;s/-*$//' | cut -c1-48
}

agent_brief() {
  cat <<BRIEF
Run \`GH_PAGER=cat ./scripts/fleet/issue-command.sh $1\` first and follow
everything it prints, including the review loop at the end. You were started by
the fleet dispatcher: work autonomously to a pull request that is waiting only on
GitHub's auto-merge, and do not stop to ask for confirmation on anything this
repo's working agreement already decides.

If \`$STOP_FILE\` appears at any point, stop: say where you got to and do nothing
further. Nothing can leave this worktree while it exists.
BRIEF
}

launch() {
  # The worktree list is about to change, and `foundation_in_flight` caches its
  # answer per poll. Dropping it here is what makes the check on the NEXT
  # iteration see the worktree this launch is about to create -- which is the
  # half of the rule that stops anything starting behind a foundation issue.
  rm -f "$POLL_CACHE/foundation"
  local num="$1" title="$2"
  local name; name="$(slug "$num-$title")"

  say "opening a worktree for #$num -- $title"
  local out; out="$(mktemp)"
  runner_worktree_create "$REPO_ROOT" "$name" "$num" claude \
    "$(agent_brief "$num")" "starting #$num" >"$out"
  if [ $? != 0 ]; then
    say "  could not create it:"
    sed 's/^/    /' "$out" | tee -a "$LOG"
    rm -f "$out"
    return 1
  fi
  local path
  path="$(cat "$out")"
  rm -f "$out"
  [ -n "$path" ] || { say "  created, but the runner reported no path; not tracking it"; return 1; }
  own "$num" "$path"
  # The announcement is stale once the fleet has actually MOVED, and this is
  # where it has: a `launch` that FAILED moved nothing and must not re-arm the
  # line, which is what clearing this at the top of the function did. See
  # foundation_in_flight for why it is cleared here rather than on its no-hold
  # path. Found by the independent review.
  rm -f "$FOUNDATION_HOLD_SAID"
  card "$path" workspace-status in-progress comment "#$num: building"
  say "  #$num is running in $path"
}

# -------------------------------------------------------------- the review ---
# In AUTOFLEET_REVIEW_MODE=local, the dispatcher is what runs the independent
# review. Nothing else can: the agent that wrote the PR must not review it
# (.claude/hooks/guard.py refuses `gh pr review` from a fleet worktree), and the
# workflow that normally does it needs a CLAUDE_CODE_OAUTH_TOKEN this repository
# does not have. Without this, every PR sits blocked on a review that cannot
# arrive and `await-review.sh` waits out its deadline three times.
#
# In the default `github` mode this returns immediately and costs nothing.
REVIEWING_DIR="$STATE_DIR/reviewing"
# WHAT IS IN THIS DIRECTORY, in one place, because a fourth consumer that had to
# work it out from three use sites is exactly how the third one came to disagree:
#
#   <pr>         the LOCK. Holds `pid head`. Its presence means a reviewer is
#                running; `review.sh` removes it on every exit path.
#   <pr>.done    a RECORD. Holds a head that has been handled, so a head with a
#                review does not get a reviewer started every poll.
#   <pr>.tries   a RECORD. Holds `head n` -- how many reviewers this head has
#                had that produced no verdict, against AUTOFLEET_REVIEW_MAX_TRIES.
#   <pr>.said    a RECORD. Which hold has already been explained for this PR, so
#                it cannot overwrite -- or be overwritten by -- the foundation
#                hold's marker.
#
# Only the first is a lock, and the three records must never be counted as one.
# `is_review_record` is the predicate; use it rather than respelling the suffix
# list. `cmd_status` respelled it as a `find ! -name` and counted all three as
# reviewers in flight, permanently, on the screen its own comment calls the
# first anybody looks at. Found by the independent review, which noted the
# comment two lines above already stated the rule this broke.
is_review_record() { case "$1" in *.done|*.tries|*.said) return 0 ;; esac; return 1; }

# Is pid $1 one of OUR reviewers, or merely a live pid?
#
# `kill -0` alone is not the question. This is the second place in the fleet that
# SIGNALS a pid it read out of a file -- `cmd_stop` is the other, and it uses
# `dispatcher_alive`, whose whole reason for existing is that a marker a `kill -9`
# left behind names whoever the OS has since given that number to. Nothing clears
# $REVIEWING_DIR across a dispatcher's death, so a stale marker outlives its
# process by hours and the number is reused: on the head-moved path that meant
# SIGTERM to a stranger, and on the unmoved path a marker nothing could ever
# reap, so that PR was never reviewed again. Both found by the independent review.
#
# Same three answers as dispatcher_alive: 0 yes, 1 no, 2 alive but ps would not
# say. On "cannot say" the caller treats it as ours -- the conservative choice
# here is to leave a possible reviewer running and its slot held, not to signal
# an unidentified process.
#
# ANCHORED, and this is the whole of it. An unanchored `review\.sh` also matches
# `await-review.sh`, `answer-review.sh` and `record-review.sh` -- and the first
# of those is where EVERY worktree agent sits for up to 45 minutes waiting for
# the very review this file starts. `stop_reviewers()` SIGTERMs what this
# matches, and it runs at every dispatcher start, so a recycled pid landing on an
# agent's wait would have killed the wait: the exact failure this whole change
# exists to remove, delivered by the machinery that removes it. Found by the
# independent review.
#
# `dispatcher_alive` anchors for the same reason and was cited as this
# function's model while not being followed. The pattern matches the path this
# file actually spawns -- `<repo>/scripts/fleet/review.sh <pr>` -- with the
# separator required on the left so `await-review.sh` cannot satisfy it.
reviewer_alive() {
  local pid="${1:-}" line
  case "$pid" in ''|*[!0-9]*|0) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  line="$(ps -o command= -p "$pid" 2>/dev/null)"
  [ -n "$line" ] || return 2
  printf '%s\n' "$line" | grep -Eq '(^|[[:space:]/])review\.sh([[:space:]]|$)'
}

# Every reviewer this dispatcher started, stopped, and their markers cleared.
#
# Called from `cmd_stop --now` and at dispatcher start. Without the first,
# `--now` -- which CLAUDE.md calls the one that "also freezes the agents" --
# left an in-flight reviewer running for up to AUTOFLEET_REVIEW_TIMEOUT more
# minutes: an agent holding this machine's gh credentials, unreaped because the
# dispatcher that would have reaped it was the thing just killed, and invisible
# to `fleet.sh status`, which counts markers. Without the second, markers from a
# dispatcher that was `kill -9`d are inherited by the next one and never cleared.
stop_reviewers() {
  local marker held stopped=0
  [ -d "$REVIEWING_DIR" ] || return 0
  for marker in "$REVIEWING_DIR"/*; do
    [ -e "$marker" ] || continue
    # The records go too: a dispatcher starting fresh re-derives what has been
    # reviewed from the pull request itself, which is the only source that
    # cannot be stale.
    is_review_record "$marker" && { rm -f "$marker"; continue; }
    held=""
    read -r held _ <"$marker" 2>/dev/null || true
    if reviewer_alive "$held"; then
      kill "$held" 2>/dev/null && stopped=$((stopped + 1))
    fi
    rm -f "$marker"
  done
  [ "$stopped" -gt 0 ] && echo "  stopped $stopped local reviewer(s)."
  return 0
}

# ----------------------------------------------------------- what is KEPT ---
#
# Nothing here deletes anything an agent or a person still needs. It deletes
# what has stopped being about anything: a transcript of a review that was
# answered three heads ago, on a pull request that merged yesterday.
#
# WHY THIS IS NOT JUST TIDINESS. Every one of these stores only ever grew --
# reviewer transcripts reached 184K across 46 files in under two days on the
# machine this was written on, 65% of them belonging to merged PRs -- and the
# cost is not the bytes. It is that stale state is read as current: a `reviewed-`
# record for a sha on no branch, or a transcript named for a head nobody is
# reviewing, answers a question nobody should be asking. See
# armaatus/autofleet#70.

# Reviewer transcripts. Keeps the newest AUTOFLEET_KEEP_REVIEWS per OPEN pull
# request and drops the rest, including every transcript of a PR that is no
# longer open. `$1` is the space-separated list of open PR numbers, which
# `review_open_prs` already has in hand, so deciding WHICH PRs to look at costs
# nothing. One `gh pr view <n> --json state` is then spent per candidate pull
# request per pass, and only after a grace pass -- see the comment at that call
# for why absence from `$1` is not an answer on its own.
#
# `$2` is whether that list is an ANSWER, and an empty list with `$2` = yes
# sweeps everything: that is a drained fleet, which is the peak of the pile this
# exists for. An empty list that is a FAILURE is `$2` = no and does nothing.
#
# This header used to say "costs no API call" and "with no list it does nothing",
# and both stopped being true when the confirmation call and the two-valued `$2`
# arrived. Found by the independent review -- the same class of stale claim this
# branch had already fixed once.
prune_review_logs() {
  local open_prs="$1" dir="$FLEET_DIR/reviews" f base num kept
  [ "${AUTOFLEET_KEEP_REVIEWS:-0}" -gt 0 ] 2>/dev/null || return 0
  # `$2` is whether the caller COULD ANSWER, and it is separate from the list
  # because an empty list has two meanings and they are opposite instructions.
  #
  # A drained fleet whose last PR merged is a real empty answer, and the peak of
  # the pile this sweep exists for. But three things produce a wrongly-empty
  # list, and each would delete every transcript on the machine: the `python3`
  # parse between `gh` and here swallows everything (`except: pass`, and a
  # missing python3 or a `--json` shape change is indistinguishable from `[]`);
  # `--limit 50` pages, so an open PR past the page reads as closed; and
  # `--author "@me"` is right for deciding whom to REVIEW and wrong for "is this
  # PR still open", so a host whose worktrees open PRs under a different account
  # than the dispatcher's `gh` login loses everything.
  #
  # A blip self-heals through the grace pass. A systematic failure empties the
  # store, once, permanently. Found by the independent review -- and the header
  # of this function had promised this behaviour while the code did the reverse.
  local answered="${2:-no}"
  [ "$answered" = yes ] || return 0
  [ -d "$dir" ] || return 0
  # WHICH PRs ARE ELIGIBLE, decided per PULL REQUEST and in two steps, because
  # one step has the bug twice over: collect the closed numbers FIRST, then ask
  # about each one's marker. Done in a single pass, the first transcript of a PR
  # creates `.closed-N` and the second finds it already there -- so the PR is
  # "graced" on the same pass it was recorded, and every transcript but the
  # first goes in the same breath as the merge. That is the failure the grace
  # exists to prevent, and it survived one attempt at fixing it. Found by the
  # independent review.
  local removed=0 graced="" closed="" num_seen
  for f in "$dir"/pr-*.log; do
    [ -e "$f" ] || continue
    num_seen="$(basename "$f")"; num_seen="${num_seen#pr-}"; num_seen="${num_seen%%-*}"
    case " $open_prs " in *" $num_seen "*) continue ;; esac
    # A PR with a reviewer still writing is not eligible for anything: the
    # deleting loop skips it, and granting grace here would mean the pass after
    # the reviewer finishes deletes with no grace at all.
    if [ -e "$REVIEWING_DIR/$num_seen" ]; then
      local held_seen=""
      read -r held_seen _ <"$REVIEWING_DIR/$num_seen" 2>/dev/null || true
      reviewer_alive "$held_seen" && continue
    fi
    case " $closed " in *" $num_seen "*) ;; *) closed="$closed$num_seen " ;; esac
  done
  for num_seen in $closed; do
    if [ ! -e "$dir/.closed-$num_seen" ]; then
      : >"$dir/.closed-$num_seen"       # first pass seeing it closed: grace it
      continue
    fi
    # CONFIRMED CLOSED, not merely absent from an author-scoped list -- and
    # asked ONCE PER PULL REQUEST, here, rather than once per transcript in the
    # loop below. The open list comes from `gh pr list --author "@me"`, which is
    # right for deciding whom to REVIEW and wrong for "is this PR still open":
    # on a host where the worktrees open PRs under a different account than the
    # dispatcher's `gh` login, every one of them reads as closed and loses its
    # transcripts. The comment above named that hazard among three and the code
    # guarded the other two.
    #
    # The call used to sit in the deleting loop, so the PR with thirteen
    # transcripts #70 measured cost thirteen identical calls -- every poll,
    # forever, because a PR that answers OPEN is never deleted and so never
    # stops being a candidate. At the default 60s poll that is ~18,700 calls a
    # day against the same budget `next_issue` and `review_open_prs` spend, and
    # gh's secondary rate limit is how this dispatcher breaks. Found by the
    # independent review.
    #
    # An OPEN answer puts the PR BACK ON THE OPEN LIST for the rest of this
    # sweep, which is what it is. Leaving it a permanent candidate meant its
    # transcripts were never swept AND never trimmed either -- the newest-N cap
    # below iterates `$open_prs`, which by construction did not contain it -- so
    # the one case this call exists to protect was the one case that grew
    # without bound. Anything but a confident answer keeps the files and keeps
    # the grace, so a `gh` blip costs a pass rather than a store.
    #
    # THE QUESTION RECURS, and that is chosen rather than overlooked. Dropping
    # the marker on OPEN means the next pass is a grace pass that asks nothing,
    # so such a PR costs one call every SECOND poll for as long as it stays open
    # and absent from the author-scoped list. Keeping the marker instead would
    # ask on every poll; caching the answer for good would mean never noticing
    # it had closed, and its transcripts would outlive it. Halved and alternating
    # is the bound, not "asked once" -- the cap reaches it on the passes it
    # answers, which is enough to bound the store. Found by the independent
    # review, which read the paragraph above as claiming more than the code does.
    case "$(GH_PAGER=cat gh pr view "$num_seen" --json state --jq .state 2>/dev/null)" in
      CLOSED|MERGED) graced="$graced$num_seen " ;;
      OPEN) open_prs="$open_prs $num_seen"; rm -f "$dir/.closed-$num_seen" ;;
      *) ;;
    esac
  done

  for f in "$dir"/pr-*.log; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"; num="${base#pr-}"; num="${num%%-*}"
    # NOT WHILE A REVIEWER FOR THAT PR IS RUNNING. `review.sh` holds its
    # transcript open with `>"$log"` for the whole run -- up to
    # AUTOFLEET_REVIEW_TIMEOUT, thirty minutes -- while the grace is one pass, a
    # minute. A PR that auto-merges two minutes into its own review would have
    # had that review's output unlinked under the agent still writing it, and
    # the sweep would have SAID it swept it. `rotate_fleet_log` was given this
    # guard for the sibling file; this sweep was not. Found by `/code-review`.
    # A LIVE reviewer, asked the same way the rotation asks -- the comment
    # claimed parity and the code tested mere existence, so a marker left by a
    # SIGKILL blocked this PR's transcripts from ever being swept. Only a
    # definite 0 blocks, for the same reason as there: a 2-marker is never
    # cleared, so blocking on it is permanent. Found by the independent review.
    if [ -e "$REVIEWING_DIR/$num" ]; then
      local held_by=""
      read -r held_by _ <"$REVIEWING_DIR/$num" 2>/dev/null || true
      reviewer_alive "$held_by" && continue
    fi
    case " $open_prs " in
      *" $num "*) rm -f "$dir/.closed-$num"; continue ;;   # still open
    esac
    # PER PR, DECIDED BEFORE THIS LOOP. The marker used to be created inside it:
    # iteration one for a PR made `.closed-N` and continued, and iteration two
    # onward found it already there and deleted immediately -- so on the very
    # pass a PR dropped off the open list, ALL BUT ONE of its transcripts went,
    # and the survivor was whichever head-sha sorted first. #70 measured
    # thirteen transcripts on one PR; twelve would have gone in the same breath
    # as the merge, which is exactly what the grace exists to prevent and what
    # its own comment claimed it did. The `sweeps` phase could not catch it
    # because no PR there ever had two transcripts alive at once. Found by the
    # independent review.
    # `$graced` is "past its grace pass AND confirmed closed by gh", both
    # decided per pull request above. Everything else keeps its transcripts.
    case " $graced " in
      *" $num "*) ;;                # eligible since a previous pass: sweep it
      *) continue ;;                # first pass seeing it closed: keep them all
    esac
    rm -f "$f" && removed=$((removed + 1))
  done
  # ...and the newest N for each PR that IS open. `ls -t` is mtime order, which
  # is the order they were written.
  for num in $open_prs; do
    kept=0
    # `ls -t` through a `while read`, not a `for` over an unquoted substitution:
    # $FLEET_DIR is a documented knob and a space in it word-split the cap into
    # `rm -f` on fragments, so it silently stopped enforcing. Hard rule 3.
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      kept=$((kept + 1))
      [ "$kept" -le "$AUTOFLEET_KEEP_REVIEWS" ] && continue
      rm -f "$f" && removed=$((removed + 1))
    done <<EOF
$(ls -t "$dir"/pr-"$num"-*.log 2>/dev/null)
EOF
  done
  # ...and the grace markers of PRs whose transcripts are all gone, so the
  # directory does not trade one kind of growth for another.
  for f in "$dir"/.closed-*; do
    [ -e "$f" ] || continue
    num="$(basename "$f")"; num="${num#.closed-}"
    ls "$dir"/pr-"$num"-*.log >/dev/null 2>&1 || rm -f "$f"
  done
  # SAID, not silent. A sweep nobody can see is one nobody can debug, and the
  # first question about a missing transcript is whether this took it. The
  # comment sat two blocks above the line it describes, which is the same drift
  # as a stale one. Found by the independent review.
  [ "$removed" -gt 0 ] && say "swept $removed reviewer transcript(s) no longer being answered"
  return 0
}

# fleet.log, at AUTOFLEET_LOG_MAX_BYTES. ONE generation: the point is a bound,
# and two files at the cap is twice the cap.
#
# NOT WHILE A REVIEWER IS RUNNING, and that is the whole of the care here. The
# dispatcher's own writes are `tee -a`, fresh per call, so they follow a rename
# without noticing -- but `review_open_prs` spawns `review.sh ... >>"$LOG"`, and
# that redirect holds the INODE for up to AUTOFLEET_REVIEW_TIMEOUT, which is
# thirty minutes by default and many polls. Rotate under it and its output goes
# to `fleet.log.1`, invisible in the log anybody is reading; the next rotation
# then `mv -f`s over `fleet.log.1` and unlinks the file it is still writing to.
# The output is gone and nothing errors. An earlier version of this comment
# named the dispatcher as the long-lived holder; it is not. Found by the
# independent review.
#
# Waiting costs nothing: the cap is a bound on a log, not a deadline, and the
# reviewer that blocks the rotation is the thing writing most of what is in it.
rotate_fleet_log() {
  local max="${AUTOFLEET_LOG_MAX_BYTES:-0}" size live blind=""
  [ "$max" -gt 0 ] 2>/dev/null || return 0
  [ -f "$LOG" ] || return 0
  # UNDER THE CAP IS THE ANSWER FOR ALMOST EVERY POLL, so it is decided FIRST.
  # The size check used to run after the loop below, which meant a poll that was
  # never going to rotate anything still burned the say-once marker: an rc-2
  # holder plus a log at half the cap wrote `rotate-blind`, said the warning, and
  # then returned without renaming a thing. The real blind rotation, whenever it
  # came, was then silent -- the marker having been spent on a rotation that did
  # not happen. Found by the independent review.
  size="$(wc -c <"$LOG" 2>/dev/null | tr -d ' ')"
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  [ "$size" -gt "$max" ] || return 0
  # A LIVE REVIEWER, asked properly. Two things were wrong here and both were
  # silent. It called `is_review_record` when that predicate did not yet exist on
  # this branch, so `command not found` was swallowed by `2>/dev/null`, the
  # `&& continue` never fired, and EVERY file in the directory blocked rotation
  # while the dispatcher ran a nonexistent command once per file per poll. And
  # blocking on any marker rather than a live pid means rotation starves:
  # `fleet.sh` deliberately keeps a marker whose pid `ps` cannot identify, and
  # that one survives for the dispatcher's life, after which
  # AUTOFLEET_LOG_MAX_BYTES is not a bound at all. Found by `/code-review`, which
  # reproduced the 127.
  #
  # The predicate DOES exist now -- merging main brought it -- so this loop uses
  # it rather than leaning on a record's first field being a sha that
  # `reviewer_alive` happens to reject. That is the rule stated where
  # `is_review_record` is defined: use the predicate, do not respell the suffix
  # list or rely on what the contents happen to look like. This was the one loop
  # over the directory still doing neither, and the comment above it still said
  # the predicate was unavailable. Found by the independent review.
  if [ -d "$REVIEWING_DIR" ]; then
    for live in "$REVIEWING_DIR"/*; do
      [ -e "$live" ] || continue
      is_review_record "$live" && continue
      local held=""
      read -r held _ <"$live" 2>/dev/null || true
      # `reviewer_alive` is the fleet's own three-way answer: 0 ours, 1 dead,
      # 2 alive-but-ps-would-not-say. ONLY 0 BLOCKS.
      #
      # An earlier version blocked on 2 as well -- "the whole point is not to
      # rename an inode somebody still has open" -- and that reinstated exactly
      # the starvation the comment above names. A 2-marker is never cleared:
      # `live_reviewers` keeps it deliberately ("only a definite 1 clears it")
      # and `stop_reviewers` runs at dispatcher start, so one SIGKILLed reviewer
      # whose pid the OS reuses for something `ps` will not name blocks every
      # rotation for the life of the dispatcher, silently -- the `say` below is
      # never reached, because the function returned before the `mv`. The cap
      # stops being a bound at all.
      #
      # Weighing the two: blocking on 2 risks an unbounded log, forever, with no
      # message. Not blocking risks ONE rename under a writer nobody can
      # identify -- one generation, the file still on disk as fleet.log.1, and
      # the writer's fd still valid. The second is recoverable and the first is
      # not. It is said once, because rotating out from under something is worth
      # knowing about even when it is the better answer. Found by the
      # independent review, which noted the two comments contradicted and the
      # code implemented the losing one.
      reviewer_alive "$held"; local is=$?
      [ "$is" = 0 ] && return 0
      [ "$is" = 2 ] && blind="$held"
    done
  fi
  mv -f "$LOG" "$LOG.1" 2>/dev/null || {
    # SAID, AND SAID ONCE. A read-only state dir or an undeletable fleet.log.1
    # made this fail on every poll forever with nothing logged -- the opposite
    # of the rule stated forty lines above. Ungated, it then did the opposite of
    # the rule this whole function is: a directory `mv` cannot write to is still
    # a file `tee -a` can append to, so the one state where the cap CANNOT hold
    # was the one writing ~1440 lines a day into the log it is failing to bound.
    # Same shape and same marker rule as the warning below. Found by the
    # independent review.
    if [ -z "$ROTATE_STUCK_SAID" ]; then
      ROTATE_STUCK_SAID=1
      say "could not rotate $LOG past $max bytes; it will keep growing"
    fi
    return 0; }
  # ...and cleared by a rotation that works, so the next time it sticks it says
  # so. The condition is a directory permission somebody fixes while the fleet
  # runs, so "once per dispatcher" would otherwise be once per dispatcher even
  # after the operator had fixed and re-broken it.
  ROTATE_STUCK_SAID=""
  # SAID AFTER THE RENAME, into the file people read. `say` is `tee -a "$LOG"`,
  # so a warning printed before the `mv` was appended to the inode that became
  # `fleet.log.1` -- the one this very line says nobody reads. Found by the
  # independent review.
  if [ -n "$blind" ] && [ ! -e "$ROTATE_BLIND_SAID" ]; then
    : >"$ROTATE_BLIND_SAID"
    say "  rotated fleet.log with pid $blind holding it and ps unable to name it;"
    say "  its output may land in fleet.log.1 -- the alternative is never rotating"
  fi
  say "fleet.log passed $max bytes; the previous one is $LOG.1"
  return 0
}

# `.autofleet/run/reviewed-<sha>` records, which guard.py reads as "the local
# review for this commit is recorded". A sha that is on no branch is a commit
# that was amended or rebased away, and its record can only ever answer for a
# commit nobody will push again.
prune_reviewed_markers() {
  # The same off switch the other two have, because config.sh promises one --
  # "set either to 0 to keep everything" -- and this sweep was governed by
  # neither knob. A host project that sets AUTOFLEET_KEEP_REVIEWS=0 to stop the
  # dispatcher deleting review state still had these deleted every 60 seconds.
  # Found by `/code-review`.
  [ "${AUTOFLEET_KEEP_REVIEWS:-0}" -gt 0 ] 2>/dev/null || return 0
  # EVERY CHECKOUT THAT HAS ONE, not just the dispatcher's. `REPO_ROOT` here is
  # the main worktree, and that is not where the push gate reads: `guard.py`
  # builds its path from `git rev-parse --show-toplevel`, the WORKTREE root, and
  # `record-review.sh` sets its own REPO_ROOT from `BASH_SOURCE` and writes
  # `<worktree>/.autofleet/run/reviewed-<sha>`. So this swept a directory the
  # gate never reads and never reached the markers that answer it -- while the
  # comment and #74's Scope both claimed otherwise. The phase could not catch it
  # either: it built markers under the same path the code used. Found by the
  # independent review.
  # NEWLINE-DELIMITED, and read as lines. A space-joined list word-splits, and
  # `$FLEET_DIR` and the worktree paths are both things a host sets -- so a
  # worktree under `/Users/me/my projects/...` was silently skipped, which is the
  # same shape as the `$STATE_DIR`-with-a-space glob this file already guards.
  # Found by the independent review.
  local roots w
  roots="$REPO_ROOT"
  for w in "$OWNED_DIR"/*; do
    [ -e "$w" ] || continue
    w="$(cat "$w" 2>/dev/null)"
    [ -d "$w/.autofleet/run" ] && roots="$roots
$w"
  done
  local dir f sha removed=0 root
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    dir="$root/.autofleet/run"
    # `continue`, NOT `return 0`. This was left over from the single-root version,
    # where returning was right. Multi-root it exits the whole function on the
    # FIRST root -- the dispatcher checkout -- and that is the one most likely to
    # lack the directory: `.autofleet/run/` is gitignored and created on demand by
    # `record-review.sh` in the checkout that records a review, which is a
    # WORKTREE. So on any host where no review was ever recorded from the main
    # checkout, the sweep returned on iteration one every poll and examined
    # nothing at all. Found by the independent review.
    [ -d "$dir" ] || continue
    for f in "$dir"/reviewed-*; do
      [ -e "$f" ] || continue
      sha="$(basename "$f")"; sha="${sha#reviewed-}"
      case "$sha" in *[!0-9a-f]*|"") continue ;; esac
      # `cat-file -e` first: a sha git has never heard of is not ours to judge.
      git -C "$root" cat-file -e "$sha^{commit}" 2>/dev/null || continue
      # NO PIPE. `git branch -a --contains "$sha" | grep -q .` exits after the
      # first line, git dies of SIGPIPE, and `set -o pipefail` makes the pipeline
      # 141 -- so past a few hundred refs this said "on no branch" about a commit
      # that is on a thousand of them, and deleted the record. Measured: 500 refs
      # exits 0, 1000 exits 141. guard.py then refuses the push with "record the
      # local review first" and both passes have to be run again.
      #
      # It fails SAFE now, like the `cat-file -e` above it: anything other than a
      # confidently empty answer keeps the record.
      local on_branch
      on_branch="$(git -C "$root" branch -a --contains "$sha" --format='%(refname)' 2>/dev/null)" \
        || continue
      [ -n "$on_branch" ] && continue
      rm -f "$f" && removed=$((removed + 1))
    done
  done <<EOF
$roots
EOF
  [ "$removed" -gt 0 ] && say "swept $removed review marker(s) for commits on no branch"
  return 0
}

review_open_prs() {
  fleet_review_is_local || return 0
  # A stopped fleet writes nothing to a pull request, and `review.sh` knows that
  # -- it exits 3. But it exits 3 AFTER being spawned, once per open PR, every
  # poll: churn with an answer already known here. A DRAIN deliberately does not
  # stop reviews, because a drain lets the work in flight finish and a PR waiting
  # on a verdict is exactly that work.
  fleet_stopped && return 0
  mkdir -p "$REVIEWING_DIR"

  # OUR OWN PULL REQUESTS, and this is a limit rather than an oversight. The
  # reviewer is an agent with this machine's credentials reading a diff written
  # by somebody else; starting one unattended on every PR a repository receives
  # is a thing to opt into deliberately, not a side effect of turning on local
  # review. `@me` is the account gh is logged in as, which in the fleet's case
  # is also the account every worktree opens PRs with.
  # ONE NUMBER, because the guard below only guards while it equals the limit.
  # Both were literal `50`, and a page size changed in one place would have left
  # the guard passing a truncated listing through as an answer -- which empties
  # the transcript store once, permanently, and that is the single failure the
  # `prs_answered` split exists to prevent. Hard rule 3. Found by the
  # independent review.
  local listing pr_page=50
  listing="$(GH_PAGER=cat gh pr list --state open --author "@me" \
               --json number,isDraft,headRefOid --limit "$pr_page" 2>/dev/null)" || {
    say "could not list the open PRs; skipping the review pass"
    return 0; }

  # The open numbers, drafts included, from the listing already in hand -- no
  # second API call. The transcripts of pull requests that are no longer open go
  # here, because this is the one place that knows which those are, and because
  # a review of a closed PR is answering a question nobody is asking.
  #
  # Drafts count as open: sweeping a draft's transcripts out from under it while
  # somebody is still reading them is the failure this sweep must not have.
  # TWO ANSWERS, not one: the numbers, and whether the parse worked at all.
  # `except: pass` with `2>/dev/null` made a missing python3 and a real `[]`
  # the same string, and the sweep below treats them oppositely.
  local open_prs prs_answered=no
  open_prs="$(printf '%s' "$listing" | python3 -c '
import json, sys
print(" ".join(str(p["number"]) for p in json.load(sys.stdin)))
' 2>/dev/null)" && prs_answered=yes
  # ...and a listing that came back truncated is not an answer either: at the
  # page limit we cannot tell an absent PR from one on the next page.
  if [ "$(printf '%s' "$listing" | python3 -c '
import json, sys
print(len(json.load(sys.stdin)))
' 2>/dev/null)" = "$pr_page" ]; then
    prs_answered=no
  fi
  # `yes` only when the parse produced something we can trust: `gh` succeeding
  # is not enough, because the parse below it can fail silently.
  prune_review_logs "$open_prs" "$prs_answered"

  # `kill`/`kill -0` with a pid this could not read must never fall back to `0`,
  # which is not "no process" but THIS PROCESS GROUP -- the dispatcher and every
  # child it has. A marker truncated by a crash between the `>` and the write is
  # enough to reach it. `kill -0 0` also SUCCEEDS, so the same default on the
  # reaping path below made an empty marker immortal and its PR never reviewed
  # again. Both found by the local review of the change that added this.
  #
  # A marker whose first field is not a number is treated as gone, which is what
  # it is: nothing here can signal a process it cannot name.
  local marker held

  # Forget the reviewers that have finished, and count what is left. Both in one
  # function, because the count has to be RE-TAKEN inside the loop below and a
  # count that is only taken once is what starved the fourth pull request.
  #
  # A `review.sh` that finds a counting review already on the head exits 8 in
  # about two API calls -- but it had claimed a slot, and the sweep that frees it
  # ran only at the top of the pass. With three such PRs and MAX_WORKTREES=3, the
  # first three took every slot every pass, the fourth hit `continue`, and it was
  # never reviewed at all: it waited out await-review.sh three times, which is
  # verbatim the failure #20 exists to remove. Reachable today -- a PR touching
  # HUMAN_ONLY_PREFIXES sits open waiting for a person, and this one does. Found
  # by the independent review.
  live_reviewers() {
    local m p n=0
    for m in "$REVIEWING_DIR"/*; do
      [ -e "$m" ] || continue
      # `<pr>.done` is a record, not a lock: it holds a head, not a pid, and
      # reaping it as a dead reviewer would put the re-spawn loop straight back.
      is_review_record "$m" && continue
      p=""
      read -r p _ <"$m" 2>/dev/null || true
      reviewer_alive "$p"; local is=$?
      # 0 is ours; 2 is "alive, but ps would not say", which reviewer_alive
      # documents as treat-it-as-ours, so it keeps both its marker and its slot.
      # Only a definite 1 clears it.
      if [ "$is" != 1 ]; then n=$((n + 1)); else rm -f "$m"; fi
    done
    printf '%s\n' "$n"
  }

  local running; running="$(live_reviewers)"

  printf '%s' "$listing" | python3 -c '
import json, sys
try:
    prs = json.load(sys.stdin)
except ValueError:
    raise SystemExit(0)
for p in prs:
    # A draft is not asking for a verdict yet -- the same condition
    # claude-review.yml puts in its own `if`.
    if p.get("isDraft"):
        continue
    print(p["number"], p.get("headRefOid") or "-", sep="\t")
' | while IFS="$(printf '\t')" read -r pr head; do
    [ -n "$pr" ] || continue
    marker="$REVIEWING_DIR/$pr"
    # ...and the record of a head already handled, which is not the same
    # question as "is a reviewer running". Without it, a head that HAS its
    # review had a reviewer started for it every poll -- each exiting 8 two API
    # calls later, once a minute, until the agent pushed. Per head, so a push
    # invalidates it. armaatus/autofleet#33.
    if [ "$(cat "$marker.done" 2>/dev/null)" = "$head" ]; then
      continue
    fi
    rm -f "$marker.done"

    # ...and a head that has had its attempts. A reviewer that submits nothing
    # is retried -- that is usually transient -- but not forever: unbounded, it
    # is a full-budget reviewer started every poll against a head that will
    # never get a verdict. claude-review.yml bounds the same case at one more
    # attempt and then says a person decides; this says the same thing.
    local tries_head tries_n
    tries_head=""; tries_n=0
    read -r tries_head tries_n <"$marker.tries" 2>/dev/null || true
    [ "${tries_head:-}" = "$head" ] || tries_n=0
    if [ -e "$marker" ]; then
      local for_head
      held=""; for_head=""
      read -r held for_head <"$marker" 2>/dev/null || true
      if [ "${for_head:-}" = "$head" ]; then
        continue                      # one is running, on this very commit
      fi
      # The head moved under a running reviewer. Its verdict would carry a
      # marker for a commit that is no longer current, so merge_gate would
      # ignore it and the round would be spent for nothing. Kill it and let the
      # next pass start one on what is there now.
      reviewer_alive "$held"; local is=$?
      # Said only where it is true: the `2)` branch below declines to restart.
      [ "$is" = 0 ] && say "PR #$pr moved to ${head:0:8} mid-review; restarting the reviewer"
      case "$is" in
        0) kill "$held" 2>/dev/null; rm -f "$marker" ;;
        # "Alive, but ps would not say." Removing the marker here declined to
        # kill it AND freed its slot, which is an orphan nothing can ever reap --
        # the opposite of the documented contract two lines up. Keep the marker;
        # the next pass asks again, and if ps has an answer by then it is either
        # killed or reaped normally. Found by the independent review.
        2) say "  (ps would not say what pid $held is; leaving it and its slot alone)"
           continue ;;
        *) rm -f "$marker" ;;
      esac
      # ...and it is no longer running, so it must not keep occupying a slot.
      # Without this, three reviewers whose heads all moved in one pass are all
      # killed and none replaced, costing a whole poll interval out of the
      # time-box of the very agents that are waiting on them.
      [ "${running:-0}" -gt 0 ] && running=$((running - 1))
    fi
    # THE CAP IS CHECKED AFTER THE LOCK, and the order is the finding. Checked
    # before it, the branch was taken while the LAST reviewer was still running:
    # the count is incremented before the spawn, so with a cap of 3 the third
    # spawn leaves `.tries` at 3 and every poll for the rest of that reviewer's
    # timeout announced "3 reviewers submitted nothing, which is the cap". Only
    # two had. The third might still submit -- and a person acting on the line
    # starts a second full-budget reviewer on a head that already has one, while
    # `.said` keeps the claim unrepeated and uncorrected even after the running
    # one succeeds. Below the lock check the message is true whenever it prints.
    # Found by the independent review.
    if [ "${tries_n:-0}" -ge "$AUTOFLEET_REVIEW_MAX_TRIES" ]; then
      # Its OWN marker, per pull request: sharing the foundation one made the
      # two holds overwrite each other every poll.
      hold_say_into "$REVIEWING_DIR/$pr.said" "gaveup-$head" \
        "PR #$pr: $tries_n reviewers on ${head:0:8} submitted nothing, which is the cap." \
        "  Not starting more. Read $FLEET_DIR/reviews/pr-$pr-${head:0:8}.log, then either" \
        "  ./scripts/fleet/review.sh $pr by hand, or push -- a new head starts the count again."
      continue
    fi
    # Bounded by the same number as the worktrees. NOT the same pool, and the
    # difference is worth knowing before you raise either: at the cap this is
    # three worktree agents plus three reviewers, six agents at once. Three
    # apiece is still what a person can read the output of, and a reviewer is
    # short-lived where a worktree agent is not -- but an earlier version of this
    # comment implied one pool of three. Found by the independent review.
    #
    # RE-COUNTED, not carried: the reviewers this pass started for PRs that
    # needed none have already exited by now, and a stale count is what let three
    # two-second exits hold every slot for the whole pass, forever.
    running="$(live_reviewers)"
    if [ "${running:-0}" -ge "$MAX_WORKTREES" ]; then
      continue
    fi
    # `review.sh` is what decides whether this PR actually needs a review -- it
    # asks merge_gate.py, which is the one place that answer lives (#114). This
    # only decides whether to ASK, so a PR already reviewed costs one cheap exit
    # 8 rather than a second review.
    # `</dev/null`, and it is load-bearing: this loop's stdin IS the pipe
    # carrying the remaining PRs, and a background child inheriting it can eat
    # them. The second PR in a two-PR pass then silently never gets reviewed.
    # `review.sh` removes this marker itself on every exit path, so a reviewer
    # that decides there is nothing to do frees its slot at once rather than at
    # the top of the next pass. AUTOFLEET_REVIEW_MARKER is how it knows which
    # file is its own.
    #
    # WRITTEN AFTER THE SPAWN, because the pid is what goes in it and there is no
    # pid until the job exists. The race that opens is benign, and it is named
    # here so the next reader need not work it out: a `review.sh` that exits
    # before this `printf` runs -- the exit-8 path is two API calls -- removes a
    # marker that does not exist yet, and the `printf` then recreates it holding
    # a dead pid. `live_reviewers` reaps that on its next call, which is the very
    # next candidate in this loop, so the slot is held for one iteration rather
    # than leaked. An earlier version of this comment claimed the marker was
    # written first; found by the independent review.
    printf '%s %s\n' "$head" "$(( ${tries_n:-0} + 1 ))" >"$marker.tries"
    AUTOFLEET_REVIEW_MARKER="$marker" \
      "$REPO_ROOT/scripts/fleet/review.sh" "$pr" >>"$LOG" 2>&1 </dev/null &
    printf '%s %s\n' "$!" "$head" >"$marker"
    say "reviewing PR #$pr at ${head:0:8} (pid $!)"
  done

  # ...and the records of pull requests that are no longer open. They were
  # pruned ONLY by `stop_reviewers`, so a merged PR's `.done`, `.tries` and
  # `.said` sat here until the next dispatcher start -- days, on a fleet that
  # stays up. Harmless in size, and it was the input to the count `cmd_status`
  # got wrong, which is reason enough to keep the directory honest. A LOCK is
  # never pruned here: a reviewer running on a PR that just merged still owns its
  # pid and its slot, and `live_reviewers` is what reaps it.
  #
  # The open list is the one already in hand from the query above, so this costs
  # no API call. `$open_prs` carries every number the query returned INCLUDING
  # drafts, which the loop skips -- a draft's records must not be swept out from
  # under it while it is still open. Found by the independent review.
  # NOT on an empty answer. `open_prs` is empty both when no PR is open and when
  # the parse above failed, and those are opposite instructions: the first means
  # sweep everything, the second means sweep nothing. A repository with no open
  # PRs has no records worth keeping anyway, so refusing to sweep on empty costs
  # nothing and cannot delete a live PR's attempt count on a bad parse.
  [ -n "${open_prs:-}" ] || return 0
  # ...and NOT on a truncated one either. #72 added `prs_answered` because a
  # listing at the page limit cannot tell an absent PR from one on the next page,
  # and there `open_prs` is non-empty and still not an answer -- the emptiness
  # guard above does not see it. The records this sweeps are a live PR's attempt
  # count and its say-once marker, so the same listing that is too weak to prune
  # a transcript is too weak to prune these. Both readers of `open_prs` honour
  # the one signal, which is the point of #72 having made it a signal.
  [ "${prs_answered:-no}" = yes ] || return 0
  local rec base num
  for rec in "$REVIEWING_DIR"/*; do
    [ -e "$rec" ] || continue
    is_review_record "$rec" || continue
    base="$(basename "$rec")"; num="${base%%.*}"
    case " ${open_prs:-} " in
      *" $num "*) continue ;;
    esac
    rm -f "$rec"
  done
}

# ---------------------------------------------------------------- the reap ---
# A worktree whose PR is merged has done its job and is holding a slot. Only ones
# this dispatcher created are touched, and only when nothing goes with them:
# nothing unpushed, and a clean working tree. Its docker stack has to come down
# with it, or it survives under `restart: unless-stopped` holding two ports
# forever with nothing left on disk to identify it by -- but AFTER the removal,
# not before it. See remove_worktree.
# Remove a worktree and, only if it really went, sweep what it left behind.
#
# The three answers -- gone, refused, no answer -- come from the driver, which is
# where the how of a removal now lives: the force retry, and the reason the
# runner's own archive hook is never asked for. What is left here is the ORDER,
# which is this dispatcher's decision rather than the runner's.
#
# armaatus/rommsync-nx#27 logged "could not remove it" at 02:08 and kept the
# slot; the very same
# command, run again by hand, removed it and printed
# `warning: local branch "..." was kept because Git could not safely delete it`.
# A non-zero exit has meant both "nothing happened" and "it worked, with a
# caveat", and the fleet cannot tell those apart from the code alone -- which is
# why `runner_worktree_remove` answers on the filesystem instead.
#
# This matters more than one stuck worktree. The fleet runs at a cap of three,
# and a slot held by a worktree whose work is already merged is a slot that never
# starts the next issue -- the loop quietly runs at two, then one.
#
# The teardown runs AFTER the removal, never before it
# (armaatus/rommsync-nx#163): a hook run first takes the stack down and then
# leaves it down when the removal refuses, and armaatus/rommsync-nx#122 lost its
# RomM mid-ctest exactly that way. A refusal here changes nothing. Spelled with
# the repository because both numbers resolve to unrelated issues in autofleet,
# which is what CLAUDE.md's citation rule is for -- and a bare `(#163)` was
# already corrected once on this branch.
#
# The sweep is reap.sh, which is exactly the tool for "a stack whose worktree no
# longer exists" and needs no worktree to run -- the README names it as the manual
# counterpart of this same trade. Scoped with `--only` to the names read off the
# worktree before it went, so releasing one worktree does not also delete the
# database of an orphan somebody is still looking at; `--only` narrows reap.sh's
# stale set and can never widen it.
#
# The autostart watcher is the hook's other half, and it does not survive
# dropping --run-hooks by itself: its pidfile lives INSIDE the worktree, so it is
# read before the removal and signalled after one that worked. A watcher left
# behind polls the runtime for a directory that is gone, forever.
#
# Returns 0 when the worktree is gone, 2 when the runner never answered, and 1
# when it answered and refused. The caller acts on the difference: a refusal is a
# decision about THIS worktree and is not worth retrying, while a deadline is the
# runtime restarting and says nothing about the worktree at all.
remove_worktree() {
  local path="$1" out watcher projects env_project rc
  # The deadline the removal gets, LOCAL rather than a constant beside the other
  # tunables: armaatus/rommsync-nx exercises this function by extracting it with
  # `sed` and sourcing it alone, so anything it reads from the file around it
  # arrives empty -- and an empty deadline is not 180, it is zero.
  local deadline="${AUTOFLEET_RM_DEADLINE:-180}"
  # Pure reads, before anything can be destroyed. All three live INSIDE the
  # worktree and the sweep below needs them after it is gone.
  watcher="$(fleet_read_autostart_watcher "$path")"
  # Both names archive.sh would have used. The derived one is what setup.sh
  # would have called this worktree; the one in .env is what its stack was
  # actually created under, and after a directory rename the two disagree with
  # the containers still running under the older name.
  projects=""
  fleet_derive_env "$path" && projects="$fleet_project"
  env_project="$(sed -n 's/^COMPOSE_PROJECT_NAME=//p' "$path/.env" 2>/dev/null | tail -1)"
  case " $projects " in
    *" $env_project "*) ;;
    *) [ -n "$env_project" ] && projects="$projects $env_project" ;;
  esac
  out="$(mktemp)"
  runner_worktree_remove "$path" "$deadline" >"$out" 2>&1
  rc=$?
  if [ "$rc" = 0 ]; then rm -f "$out"; finish_removal "$path" "$watcher" "$projects"; return 0; fi
  if [ "$rc" = 2 ]; then
    rm -f "$out"
    # No "in ${deadline}s": rc 2 is also a runner that could not be reached at
    # all, which returns immediately. Naming seconds never spent is worst on the
    # one path where a person is being asked to tell a restarting app from a
    # wedged one. Found by the independent review.
    say "  the runner did not answer -- nothing was torn down, and this is not a refusal"
    return 2
  fi
  # Labelled, because the caller's "could not remove it" comes after these and
  # an unlabelled fatal: line above it reads like the fleet's own.
  while IFS= read -r line; do
    [ -n "$line" ] && say "  the removal refused: $line"
  done <"$out"
  # The line #122 needed and did not get. Not "the worktree is still usable":
  # reap_abandoned interrupts the agent immediately before calling this, so on
  # that path somebody has just been stopped. What is true on both paths is that
  # the removal changed nothing, which is the fact that saves the next test run.
  say "  nothing was torn down -- its stack is still up, so whatever is in there still has its rig"
  rm -f "$out"
  return 1
}

# What --run-hooks used to do, run only once the worktree is established to be
# gone: stop its autostart watcher, and take down the stack it left behind.
# Named for the moment rather than for the hook, because it is no longer a hook
# and no longer runs inside the worktree it is tearing down.
#
# Never fatal: the worktree IS removed by the time this is called, so a docker
# that is down or a sweep that half-finished is a stack to collect later, not a
# removal to report as failed.
finish_removal() {
  local path="$1" watcher="$2" projects="$3" name out rc only=""
  fleet_stop_autostart_watcher "$watcher" || true
  # Scoped to the names read off this worktree before it went, so releasing ONE
  # worktree does not also delete the database of an orphan somebody is still
  # looking at. Unscoped only when neither name could be read at all -- an
  # unswept stack comes back on every `docker start` holding two ports, with
  # nothing left on disk to identify it by, so that failure resolves towards
  # sweeping rather than towards leaking.
  for name in $projects; do only="$only --only $name"; done
  [ -n "$only" ] \
    || say "  could not name $path's stack; sweeping every rmx-* stack with no worktree"
  # On a deadline, and this is the reason the sweep is not simply run inline: the
  # archive hook used to be Orca's problem and inherited the 180s above, while a
  # `docker compose down` against a wedged daemon has no timeout of its own. The
  # dispatcher polls every minute and would otherwise stop polling for as long as
  # docker stayed stuck.
  out="$(mktemp)"
  # $only is a list of `--only <project>` pairs this function built itself, and a
  # project name is [a-z0-9-] by construction, so the split is the point.
  # shellcheck disable=SC2086
  FLEET_RUN_CAPTURE_STDERR=1 fleet_run_with_deadline 180 "$out" \
    "$REPO_ROOT/scripts/fleet/reap.sh" --yes $only
  rc=$?
  cat "$out" >>"$LOG"
  rm -f "$out"
  # Said rather than swallowed, because a sweep that did not finish is two ports
  # and four volumes coming back on every `docker start`, with no worktree left
  # on disk to identify them by.
  [ "$rc" = 0 ] \
    || say "  $path is gone, but the stack sweep did not finish (rc $rc) -- see $LOG, then ./scripts/fleet/reap.sh"
  return 0
}

# What both reaps do when a removal did not happen. `rc` is remove_worktree's:
# 2 means nobody answered, and that is not a decision about this worktree, so it
# is said once and retried on the next pass rather than parked.
#
# A parked worktree is NOT disowned. Both reaps iterate OWNED issues only, so an
# issue dropped on a failed removal is a worktree nothing ever looks at again --
# #122's stood from 16:49 until a person removed it. It keeps its slot, which is
# why both lines say so.
#
# The by-hand recovery is TWO commands, and the second is the one that is easy to
# forget: removing the directory makes the next pass disown the issue, and
# nothing then ever calls finish_removal for it. Its stack would come back on
# every `docker start` under `restart: unless-stopped`, holding two ports with no
# directory left to identify it by -- and the sweep is `--only`-scoped now, so no
# later removal collects it either.
BY_HAND_REMOVAL="git worktree remove --force '%s' && ./scripts/fleet/reap.sh --yes"
park_worktree() {
  local num="$1" path="$2" rc="$3" what="$4" byhand
  # BY_HAND_REMOVAL is this file's own format string, not anything a caller sets.
  # shellcheck disable=SC2059
  byhand="$(printf "$BY_HAND_REMOVAL" "$path")"
  if [ "$rc" = 2 ]; then
    [ -e "$STATE_DIR/runner-blind-$num" ] && return 0
    : >"$STATE_DIR/runner-blind-$num"
    say "  could not ask -- leaving it owned, and trying again next pass"
    card "$path" comment "#$num: $what, but the runner did not answer -- retrying"
    return 0
  fi
  rm -f "$STATE_DIR/runner-blind-$num"
  : >"$STATE_DIR/stuck-$num"
  # ...and the two re-derived markers go with it. After a refused removal they
  # describe a question already answered: `held-` and `git-blind-` mean "the
  # worktree holds something, or git would not say", and a removal that git
  # itself refused has settled that. Left behind they are PERMANENT -- both reaps
  # return early on `stuck-`, so nothing ever clears them -- and they then gate
  # a worktree that is plainly waiting for a person. Found by the independent
  # review.
  rm -f "$STATE_DIR/held-$num" "$STATE_DIR/git-blind-$num"
  say "  could not remove it; it keeps its slot until you do: $byhand"
  card "$path" comment "#$num: $what, but the removal refused -- still here, still counted"
  return 0
}

reap_merged() {
  local f num path branch merged unpushed dirty holds blind rc
  for f in "$OWNED_DIR"/*; do
    [ -e "$f" ] || continue
    num="$(basename "$f")"; path="$(cat "$f")"
    [ -d "$path" ] || { disown_issue "$num"; continue; }
    # Already attempted once, and REFUSED -- a CLI that never answered does not
    # get here, see park_worktree. Not retried: a refusal is a decision about
    # this worktree, so retrying it is a board comment once a minute under
    # whoever is still working in there, and an interruption with it down
    # reap_abandoned's path.
    #
    # ONE marker shared with reap_abandoned, deliberately. It does not record
    # which reap tried; it records that a removal was attempted here and refused,
    # and the recovery is the same two commands whichever one asked. Two markers
    # would buy a worktree already waiting on a person a second card saying so.
    # Ahead of the `gh pr list` below for the same reason: nothing about the
    # answer would change what happens.
    [ -e "$STATE_DIR/stuck-$num" ] && continue
    branch="$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null)" || continue
    merged="$(GH_PAGER=cat gh pr list --head "$branch" --state merged \
                --json number --jq '.[0].number' 2>/dev/null)"
    [ -n "$merged" ] && [ "$merged" != "null" ] || continue

    # What is in there that a removal would take with it. Two questions, because
    # a merged PR answers neither on its own.
    #
    # `@{u}..HEAD` is the older one. The WORKING TREE is the half #122 fell
    # through (#163): auto-merge fires the moment the last check passes, so
    # review fixes made after it -- #122's became #160 -- sit uncommitted here
    # while `@{u}..HEAD` is empty.
    #
    # Not worktree_holdings, which reap_abandoned uses for the same job: that
    # also asks what is absent from origin/main, and a SQUASH merge leaves every
    # commit on this branch absent from it by construction. Asked here, no merged
    # worktree would ever be released again.
    #
    # And a git that cannot answer is the THIRD answer. Reading it as "clean" is
    # how this guard fails open on the one thing it exists to protect, so it is
    # refused rather than guessed -- reap_abandoned's discipline exactly.
    holds=""; blind=0
    # The EXIT STATUS, not just the count. `grep -c` prints 0 and succeeds when
    # git printed nothing -- including when it printed nothing because `@{u}`
    # does not resolve. GitHub deletes the head branch on merge, a `fetch
    # --prune` in the worktree drops `origin/<branch>`, and from then on this
    # read "holds nothing" for a worktree that may hold a commit made after
    # auto-merge fired. Clean tree plus that answer is a `--force` removal, and
    # the commit goes with the directory.
    #
    # The comment four lines up already said this is the third answer and must
    # be refused rather than guessed; the discipline was applied to
    # `worktree_dirty_count` below and skipped here. armaatus/autofleet#34.
    if unpushed="$(git -C "$path" log '@{u}..HEAD' --oneline 2>/dev/null)"; then
      unpushed="$(printf '%s' "$unpushed" | grep -c . || true)"
      [ "${unpushed:-0}" != 0 ] && holds="$unpushed unpushed commit(s)"
    else
      blind=1
    fi
    if ! dirty="$(worktree_dirty_count "$path")"; then
      blind=1
    elif [ "${dirty:-0}" != 0 ]; then
      [ -n "$holds" ] && holds="$holds and "
      holds="$holds$dirty uncommitted change(s)"
    fi

    # Two keeps, two markers, and each clears the other -- reap_abandoned's
    # `held-`/`git-blind-` pair, for the same reason: one marker for both would
    # mean whichever fired first silenced the other for good. Said once per
    # worktree rather than once per poll, because a worktree this pass decided to
    # keep is one the next pass in sixty seconds will decide to keep again, and
    # the board card carries the standing state either way.
    #
    # Their own markers rather than reap_abandoned's: that function clears
    # `held-` and `git-blind-` whenever an issue has no reason to be released,
    # which for a MERGED issue is every single pass.
    if [ "$blind" = 1 ]; then
      rm -f "$STATE_DIR/merge-held-$num"
      [ -e "$STATE_DIR/merge-blind-$num" ] && continue
      : >"$STATE_DIR/merge-blind-$num"
      say "#$num: PR #$merged merged, but git could not say what the worktree holds -- leaving it"
      card "$path" comment "#$num: PR #$merged merged; kept -- git could not say what is in it"
      continue
    fi
    if [ -n "$holds" ]; then
      rm -f "$STATE_DIR/merge-blind-$num"
      [ -e "$STATE_DIR/merge-held-$num" ] && continue
      : >"$STATE_DIR/merge-held-$num"
      say "#$num: PR #$merged merged, but the worktree holds $holds -- leaving it"
      card "$path" comment "#$num: PR #$merged merged, $holds here"
      continue
    fi
    rm -f "$STATE_DIR/merge-held-$num" "$STATE_DIR/merge-blind-$num"

    say "#$num: PR #$merged is merged; marking it done and removing the worktree"
    card "$path" workspace-status completed comment "#$num: merged in PR #$merged"
    remove_worktree "$path"; rc=$?
    if [ "$rc" = 0 ]; then
      disown_issue "$num"
    else
      park_worktree "$num" "$path" "$rc" "merged in PR #$merged"
    fi
  done
}

# ------------------------------------------------------ the other releases ---
# `reap_merged` above is the only thing that ever removed a worktree, and it
# removes one only when a PR for that branch has MERGED. Every other way an issue
# can stop being worked left the worktree standing, owned, and counted against
# the cap of three -- forever. Two were cleared by hand on 2026-09-07, each
# holding four containers, two ports and four volumes: #44, which the time-box
# stopped at three hours for correctly producing nothing, and #148, which the
# maintainer blocked with its worktree open, keeping #119, #122 and #139 queued
# behind work that could never start.
#
# The guard has to be its own, because "the issue went blocked" carries none of
# the guarantee "the PR merged and nothing is unpushed" does: a worktree
# abandoned mid-change may hold the only copy of real work. So this refuses
# rather than guesses, on exactly the pair verified by hand before each of those
# removals -- `git status --porcelain` empty AND nothing absent from origin/main.
#
# The pair answers "is anything here worth keeping". It does not answer "is
# anyone using this", and every by-hand check behind it was made on a worktree
# that was already finished -- so it was never once evaluated against a live
# agent mid-change. The working agreement is where the two come apart: an agent plans before
# it edits, so a worktree forty minutes into real work is legitimately EMPTY. And `blocked` is not a label a person types --
# unblock.yml re-derives it on every merge, so it can arrive under an agent that
# is mid-plan, as `needs-human-step` can arrive from the agent's own hand.
#
# So the first pass that finds a reason WARNS: it interrupts the agent, says on
# the board that the worktree goes next pass, and leaves it. The pass after that
# re-asks the pair -- a minute is long enough to commit, or to write a plan down
# -- and only then removes it. That is the whole guard against deleting an
# afternoon, and it needs no lookup of agent state: an agent that has nothing on
# disk after being told is one that had nothing to lose but a prompt.

# How many lines `git status --porcelain` has, which is what both reaps mean by
# "dirty". NON-ZERO when git could not answer, because zero would be the answer
# that releases a worktree -- both callers refuse instead. `|| true` after the
# count because `grep -c` exits 1 on no matches, and a clean tree is an answer.
worktree_dirty_count() {
  local out
  out="$(git -C "$1" status --porcelain 2>/dev/null)" || return 1
  printf '%s' "$out" | grep -c . || true
}

# What removing this worktree would destroy. Prints one phrase naming it, or
# nothing at all when there is nothing. Non-zero means it could not tell, which
# is NOT the same answer: a git that cannot speak is no basis for deleting
# somebody's afternoon.
#
# origin/main is read as it stands and never fetched. A stale one only ever makes
# commits look ABSENT that are in fact merged, so every error it can cause is in
# the direction of KEEPING a worktree -- and a fetch per worktree per poll is a
# network call this loop does not need.
worktree_holdings() {
  local path="$1" dirty ahead out parts=""
  git -C "$path" rev-parse --verify --quiet HEAD >/dev/null 2>&1 || return 1
  git -C "$path" rev-parse --verify --quiet origin/main >/dev/null 2>&1 || return 1
  dirty="$(worktree_dirty_count "$path")" || return 1
  out="$(git -C "$path" log --oneline origin/main..HEAD 2>/dev/null)" || return 1
  ahead="$(printf '%s' "$out" | grep -c .)"
  [ "${dirty:-0}" != 0 ] && parts="$dirty uncommitted change(s)"
  if [ "${ahead:-0}" != 0 ]; then
    [ -n "$parts" ] && parts="$parts and "
    parts="$parts$ahead commit(s) that are not in origin/main"
  fi
  printf '%s' "$parts"
}

# Runs AFTER reap_merged in every pass, and the order is not decoration: a
# worktree whose PR merged is reap_merged's, and by the time this runs it has
# already been disowned. What is left here is what will never merge.
reap_abandoned() {
  local f num path answer reason holds asked rc
  for f in "$OWNED_DIR"/*; do
    [ -e "$f" ] || continue
    num="$(basename "$f")"; path="$(cat "$f")"
    [ -d "$path" ] || { disown_issue "$num"; continue; }
    # Already tried once, and the removal refused. Not retried: the removal
    # interrupts the agent and writes to the board, so a retry loop is both, once
    # a minute, under whoever is still working in there. (It is no longer a stack
    # torn down once a minute -- that was the ordering defect, fixed in
    # remove_worktree for #163 -- but the noise alone is reason enough.)
    [ -e "$STATE_DIR/stuck-$num" ] && continue

    reason=""; asked=1
    if answer="$(poll_issue "$num")"; then
      rm -f "$STATE_DIR/reason-blind-$num"
      # "Closed", and not "closed with no merged PR": reap_merged asks that
      # question and this one does not, so the two ways it leaves a closed issue
      # owned -- unpushed commits, and a `gh pr list --head` that could not
      # answer -- would make the fuller sentence a false one in the line a person
      # reads. The release itself is unaffected: both of those leave something in
      # the worktree, or leave everything already in origin/main.
      if [ "$(issue_state_in "$answer")" = CLOSED ]; then
        reason="its issue is closed"
      elif has_label "$(issue_labels_in "$answer")" "$BLOCKED_LABEL"; then
        reason="its issue went $BLOCKED_LABEL"
      elif has_label "$(issue_labels_in "$answer")" "$HUMAN_STEP_LABEL"; then
        reason="its last step is yours ($HUMAN_STEP_LABEL)"
      fi
    else
      asked=0
    fi
    # enforce_timebox's own record, so this one still answers through a GitHub
    # outage -- and so a lookup that failed above cannot be read as "no reason".
    [ -n "$reason" ] || ! gave_up_on "$num" || reason="the time-box stopped its agent with no PR"
    # No reason today, so everything a previous poll decided goes with it. The
    # reason is re-derived from a live lookup every pass and can genuinely come
    # and go: unblock.yml re-writes `blocked` on every merged PR, so an issue can
    # go blocked, be warned, come off `blocked` when the dependency lands, and go
    # blocked again on the next one. A `warned-` left standing across that is a
    # worktree removed on the second occurrence with no notice at all -- which is
    # the one thing the warning pass exists to prevent. `stuck-` is not in this
    # list: it means a removal was attempted and refused, and it is checked above
    # this point precisely so that it is never retried.
    # A lookup that could not answer is the THIRD answer, not "no reason", and
    # the difference is the whole discipline this function is built on --
    # worktree_holdings failing gets `git-blind-` rather than being read as
    # "holds nothing". Folded into the branch below, one `gh` hiccup looks
    # exactly like the issue coming off `blocked`: the warning still owed to a
    # reason nobody could read is discarded, the next poll starts the notice
    # over, and under a flaky GitHub the release never arrives with nothing
    # anywhere saying why. So every marker stays exactly where it was, and it is
    # said once per outage rather than once per poll.
    if [ -z "$reason" ] && [ "$asked" = 0 ]; then
      [ -e "$STATE_DIR/reason-blind-$num" ] && continue
      : >"$STATE_DIR/reason-blind-$num"
      say "#$num: could not read its issue -- leaving it, and every marker on it, until GitHub answers"
      continue
    fi
    if [ -z "$reason" ]; then
      rm -f "$STATE_DIR/warned-$num" "$STATE_DIR/held-$num" "$STATE_DIR/git-blind-$num"
      continue
    fi

    # Two keeps, two markers, and each clears the other. One marker for both
    # would mean whichever fired first silenced the other for good: a transient
    # git failure on one poll, then three uncommitted files on the next, and the
    # board still saying git could not be read -- the opposite of the promise
    # that it says WHAT is in there.
    #
    # Either way it is said once per worktree, not once per poll: the dispatcher
    # polls every minute, and a worktree it decided to keep is one it will decide
    # to keep again in sixty seconds. `warned-` goes too, so a worktree that
    # becomes empty again is offered the same pass of notice as any other.
    if ! holds="$(worktree_holdings "$path")"; then
      rm -f "$STATE_DIR/held-$num" "$STATE_DIR/warned-$num"
      [ -e "$STATE_DIR/git-blind-$num" ] && continue
      : >"$STATE_DIR/git-blind-$num"
      say "#$num: $reason, but its git state could not be read -- leaving it"
      card "$path" comment "#$num: $reason; kept -- git could not say what is in it"
      continue
    fi
    if [ -n "$holds" ]; then
      # It says WHAT is in there, the way reap_merged already reports unpushed
      # commits rather than removing them.
      rm -f "$STATE_DIR/git-blind-$num" "$STATE_DIR/warned-$num"
      [ -e "$STATE_DIR/held-$num" ] && continue
      : >"$STATE_DIR/held-$num"
      say "#$num: $reason, but the worktree holds $holds -- leaving it"
      card "$path" comment "#$num: $reason; kept -- it holds $holds"
      continue
    fi
    rm -f "$STATE_DIR/held-$num" "$STATE_DIR/git-blind-$num"

    # The warning pass. One poll of notice, then the pair is asked again above --
    # so an agent that commits, or writes its plan to a file, keeps its worktree.
    if [ ! -e "$STATE_DIR/warned-$num" ]; then
      : >"$STATE_DIR/warned-$num"
      say "#$num: $reason, and the worktree holds nothing -- releasing it next pass unless something lands in it"
      # ...unless the time-box, earlier in this same pass, already interrupted it
      # and said so on the board. Scoped to the poll: this is about not saying one
      # thing twice in one minute, not about never saying it again.
      if [ ! -e "$POLL_CACHE/interrupted-$num" ]; then
        interrupt_agent_in "$path"
        card "$path" comment "#$num: $reason; this worktree is released next pass unless something lands in it"
      fi
      continue
    fi

    say "#$num: $reason, and the worktree still holds nothing -- releasing the slot"
    # Interrupted again before the removal: an agent that ignored the warning
    # would otherwise keep writing into a directory being deleted, and lose its
    # rig with it the moment the removal lands (#163).
    interrupt_agent_in "$path"
    # The comment and no status. `completed` is reap_merged's word for work that
    # landed, and this worktree is being released precisely because it did not.
    # Phrased as what it is about to do, not as done: if the removal refuses, this
    # card is still on the board and still the line a person reads.
    card "$path" comment "#$num: $reason; nothing is in it, removing the worktree"
    remove_worktree "$path"; rc=$?
    if [ "$rc" = 0 ]; then
      disown_issue "$num"
    else
      park_worktree "$num" "$path" "$rc" "$reason"
    fi
  done
}

# A give-up record for an issue that has since landed is a line in `fleet.sh
# status` about work that is done, and a file that never goes away -- the same
# leak `stalled-` had before own() started clearing it. The release path disowns
# the issue, so nothing else will ever look at it again; this is what does.
#
# One `gh issue view` per record per poll, shared with the watchers through
# $POLL_CACHE, and self-limiting: the records it can find are the ones it removes.
prune_gaveup() {
  local n answer
  for n in $(gave_up_issues); do
    answer="$(poll_issue "$n")" || continue
    [ "$(issue_state_in "$answer")" = CLOSED ] || continue
    rm -f "$STATE_DIR/gaveup-$n"
    say "#$n: closed since the fleet gave up on it -- dropping the record"
  done
}

# ---------------------------------------------------------- stalled agents ---
# An agent sitting at a confirmation prompt is not working, and nothing said so.
# #23 stopped inside two minutes on a `git submodule add` the auto-mode
# classifier wanted confirmed, while the board still read `in-progress` and the
# time-box had three hours to run. So when one asks, say so once, on the card and
# in a notification, and let a person decide. The alternative is a worktree that
# looks busy for three hours.
#
# "In auto mode nothing should be asking" was the premise, and it is false for an
# issue whose last step is outward and the maintainer's: #142 stopped before
# `git tag` and `gh release create` exactly as its issue told it to, and was
# reported at 10:19:20 as a stall for it. Both of these still reach a person --
# what changes is which signal they are. A stall means something is wrong; this
# one means the work is done as far as an agent may take it.
notice_stalled() {
  local f num path state listing rc
  # ONE listing per poll, matched against every owned worktree -- not one CLI
  # round-trip per worktree, which is three 30-second-deadline calls a minute
  # for an answer that arrives in a single response.
  listing="$(runner_agent_states 2>/dev/null)" || return 0
  for f in "$OWNED_DIR"/*; do
    [ -e "$f" ] || continue
    num="$(basename "$f")"; path="$(cat "$f")"
    [ -d "$path" ] || continue
    # lib.sh's helper rather than an awk here: this lookup and
    # runner_agent_terminal's are the same one with the columns swapped, and they
    # had the same `awk -v` defect, fixed in both at once. The reason lives on
    # the helper now, in one place.
    state="$(printf '%s' "$listing" | fleet_state_for_path "$path")"
    [ "$state" = "waiting" ] || {
      rm -f "$STATE_DIR/stalled-$num" "$STATE_DIR/stall-labels-$num"; continue; }
    # Once per stall, not once per poll -- and checked before the lookup, so a
    # settled stall costs no `gh` call at all.
    [ -e "$STATE_DIR/stalled-$num" ] && continue
    # The third answer, and it must not be frozen behind the stall marker: a
    # single `gh` blip would otherwise record a #142-style false stall and never
    # re-evaluate it, which is the exact noise this change exists to remove.
    # `stall-labels-` throttles it instead.
    #
    # Each watcher owns its own once-per-outage marker and clears only that one.
    # The branch above drops `stall-labels-` whenever the agent stops being
    # `waiting`, which is the ordinary state of a grinding overrun -- so a marker
    # shared with enforce_timebox would be deleted seconds after that function
    # set it, restoring the line-a-minute the split exists to prevent. Distinct
    # from `unreachable-` for the same reason: that one means the PR lookup
    # failed, not this one.
    #
    # The single exception is `$POLL_CACHE/carded-`, which enforce_timebox writes
    # and this function only reads, and which the next pass empties anyway.
    issue_needs_human_step "$num"; rc=$?
    if [ "$rc" = 2 ]; then
      [ -e "$STATE_DIR/stall-labels-$num" ] && continue
      : >"$STATE_DIR/stall-labels-$num"
      say "#$num is waiting for input, and its labels could not be read -- asking again next poll"
      continue
    fi
    rm -f "$STATE_DIR/stall-labels-$num"
    : >"$STATE_DIR/stalled-$num"
    if [ "$rc" = 0 ]; then
      say "#$num is waiting for you, as expected -- its last step is yours to take"
      # ...unless enforce_timebox, which runs first in this same pass, already
      # said it. Only for this pass: the board is not a log, but a stall that
      # starts later is news no earlier comment covered.
      [ -e "$POLL_CACHE/carded-$num" ] \
        || card "$path" comment "#$num: waiting for you -- as expected, not a stall"
      notify "#$num is waiting for you" "Its last step is yours to take."
    else
      say "#$num is waiting for input -- in auto mode nothing should be asking"
      card "$path" comment "#$num: waiting for input -- needs you"
      notify "#$num needs you" "It is sitting at a prompt, not working."
    fi
  done
}

# ------------------------------------------------------------- the time-box ---
# An agent that cannot get green will grind. On expiry it is interrupted and the
# issue gets a comment saying so.
#
# What becomes of the worktree is reap_abandoned's call on the next pass, and it
# turns on what is IN it. One holding uncommitted work, or commits that are not
# on main, is left standing: a stuck task is exactly the one worth looking at and
# its diff is the evidence. One holding nothing is released, because there is
# nothing to look at and a slot is one of three -- #44 ground for three hours,
# produced nothing hard rule 1 allows, and then held its slot until it was
# removed by hand.
#
# Either way the fleet does not start that issue again: `gaveup-` outlives the
# worktree deliberately, since releasing the slot would otherwise hand it straight
# back to the same three hours. `fleet.sh retry N` is how it comes back.
enforce_timebox() {
  local f num path started now
  now="$(date +%s)"
  for f in "$STARTED_DIR"/*; do
    [ -e "$f" ] || continue
    num="$(basename "$f")"; started="$(cat "$f")"
    path="$(owned_path "$num")"
    [ -d "$path" ] || continue
    [ $((now - started)) -ge "$TIMEBOX_SECONDS" ] || continue
    # A PR being up means it got where it was going; the review loop has its own
    # cap and is not this timer's business. "Could not tell" is not "no PR":
    # this branch interrupts an agent and comments on its issue, and a lookup
    # that failed is no basis for either. The started marker stays, so the next
    # pass asks again -- an agent is only ever stopped on an answer.
    has_open_pr "$num"; case $? in
      # Every marker this function owns, not only the ones it happened to set on
      # the way here.
      0) rm -f "$f"; forget_box_markers "$num"; continue ;;
      # Once per outage, not once per poll, the same way notice_stalled does it:
      # the dispatcher polls every POLL_SECONDS, and an hour of GitHub being
      # unreachable would otherwise bury the log a person scans overnight under
      # a line a minute for every issue past its box.
      2) [ -e "$STATE_DIR/unreachable-$num" ] && continue
         : >"$STATE_DIR/unreachable-$num"
         say "#$num: timed out, but could not tell whether a PR is open -- leaving it for the next pass"
         continue ;;
    esac
    # An agent that stopped because the next step is not its to take has not
    # overrun: the box exists to stop work that will not get green, and a
    # decision only the maintainer can make is not that. #44 -- hardware, which
    # hard rule 1 forbids before the v1 gate -- was stopped at three hours for
    # correctly producing nothing.
    #
    # The started marker is KEPT. Deleting it would disarm the box for good, and
    # the label is exactly the thing a person takes off again to hand the issue
    # back to an agent -- which would then run uncapped forever. Said once, by
    # its own marker, rather than once a minute for as long as the label is on.
    issue_needs_human_step "$num"; case $? in
      # Not an exit -- the issue stays owned and past its box -- so it clears
      # only what this poll just proved stale, and keeps `human-step-` because
      # that is the marker it is about to write.
      0) rm -f "$STATE_DIR/box-labels-$num" "$STATE_DIR/unreachable-$num"
         [ -e "$STATE_DIR/human-step-$num" ] && continue
         : >"$STATE_DIR/human-step-$num"
         say "#$num: past the time-box, but it is labelled $HUMAN_STEP_LABEL -- leaving it to wait for you"
         # On the board too. An agent that finished its part and exited is not
         # `waiting`, so notice_stalled never speaks for it, and this worktree
         # keeps a slot until a person looks at it -- one line in fleet.log is
         # not where WORKFLOW.md says status lives.
         card "$path" comment "#$num: waiting for you -- as expected, not a stall; past the time-box"
         # For notice_stalled, which runs later in THIS pass and would otherwise
         # repeat it. Scoped to the poll, not to the exemption: a stall that
         # begins hours from now is news, and has to reach the board.
         : >"$POLL_CACHE/carded-$num"
         continue ;;
      2) [ -e "$STATE_DIR/box-labels-$num" ] && continue
         : >"$STATE_DIR/box-labels-$num"
         say "#$num: timed out, but could not read its labels -- leaving it for the next pass"
         continue ;;
    esac
    # The other exit, and it owes the same tidiness. `unreachable-` is the one
    # this path used to drop: a PR lookup that failed on an earlier poll, then
    # answered on this one, left its marker standing for the next worktree on
    # the same issue to inherit and be silenced by.
    forget_box_markers "$num"

    say "#$num: $((TIMEBOX_SECONDS / 3600))h with no PR -- stopping it; the worktree goes if it holds nothing"
    interrupt_agent_in "$path"
    # For reap_abandoned, which runs later in THIS pass and would otherwise
    # interrupt the same agent and card the same worktree a second time. Scoped
    # to the poll, like `carded-`: it still gets its own warning next pass.
    : >"$POLL_CACHE/interrupted-$num"
    card "$path" comment "#$num: timed out after $((TIMEBOX_SECONDS / 3600))h -- needs you"
    GH_PAGER=cat gh issue comment "$num" --body "The fleet stopped work on this after $((TIMEBOX_SECONDS / 3600)) hours with no pull request opened. Its worktree at \`$path\` is kept if it holds uncommitted work or commits that are not on \`main\`, and released otherwise so the slot is free. The fleet will not start this issue again on its own; \`./scripts/fleet/fleet.sh retry $num\` hands it back." >/dev/null 2>&1 || true
    notify "#$num gave up" "$((TIMEBOX_SECONDS / 3600))h with no PR. Not starting it again."
    # Read by reap_abandoned on the next pass, and by the queue for as long as it
    # stands. Outlives the worktree on purpose -- see clear_issue_markers, which
    # deliberately does not clear it, and cmd_retry, which does.
    : >"$STATE_DIR/gaveup-$num"
    rm -f "$f"
  done
}

# ------------------------------------------------------- the running code ---
# `fleet.sh run` parses this file ONCE, at start, and never re-reads it. So a fix
# merged to `main` is live in the worktree and not live in the dispatcher that is
# running -- and the confusing half is that a change is only HALF dead: the queue
# filter kept working across four PRs because that path re-reads labels through
# `gh` every poll, while the half living in already-parsed shell functions did
# not run for 27 hours (#173).
#
# Nothing can fix that from in here; a dispatcher cannot re-read itself mid-pass
# without a claim about resumable state that is not tested. What it CAN do is
# stop being silent about it: record what it parsed, and let `status` compare.
DISPATCHER_FILE="$STATE_DIR/dispatcher"

# The content of the file that was parsed, not the commit that last touched it.
# The commit is only how the report NAMES what changed: a fix that is committed
# but not checked out, and a checkout somebody edited, are both "not what is
# running", and only the bytes say so.
#
# cksum rather than shasum: this is a change detector, not a security boundary,
# and cksum is the one that is everywhere.
#
# Both take the root to look in, and the report passes the one the DISPATCHER
# recorded rather than $REPO_ROOT. The dispatcher runs in the main worktree and
# `fleet.sh status` is run from wherever you are -- the README points agents in a
# fleet worktree at it. Hashing the caller's own copy compares a worktree
# branched before the fix against a dispatcher that predates it too, matches,
# and answers "current": #173's silence, rebuilt inside the check for it.
fleet_hash_stdin() { cksum | awk '{print $1 "-" $2}'; }
fleet_code_hash() {
  [ -r "$1/scripts/fleet/fleet.sh" ] || return 0
  fleet_hash_stdin <"$1/scripts/fleet/fleet.sh"
}
fleet_code_commit() {
  git -C "$1" log -1 --format=%H -- scripts/fleet/fleet.sh 2>/dev/null
}

# The fleet.sh commits in $2..$3, in the repo at $1, or nothing. A ref that does
# not resolve -- no `origin`, a checkout with no history in common -- is nothing
# to name rather than an error on the screen.
fleet_commits_between() {
  [ -n "$2" ] || return 0
  git -C "$1" rev-parse --verify --quiet "$3" >/dev/null 2>&1 || return 0
  git -C "$1" log --oneline "$2..$3" -- scripts/fleet/fleet.sh 2>/dev/null
}

# BSD date and GNU date spell "format this epoch" differently, and this runs on
# both -- macOS here, Linux in CI.
fmt_epoch() {
  date -r "$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
    || date -d "@$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
    || printf 'an unreadable time (%s)\n' "$1"
}

record_dispatcher() {
  mkdir -p "$STATE_DIR"
  { printf 'root=%s\n'    "$REPO_ROOT"
    printf 'started=%s\n' "$(date +%s)"
    printf 'commit=%s\n'  "$(fleet_code_commit "$REPO_ROOT")"
    printf 'hash=%s\n'    "$(fleet_code_hash "$REPO_ROOT")"
    # Not derivable from the outside, and that is why it is written: a drain
    # sets a file only a dispatcher that parsed THIS fleet.sh reads, and one
    # that started before #183 would poll straight through it, launching
    # worktrees under a stop that looked set. A running process saying what it
    # understands is the only honest answer -- the bytes on disk are the ones a
    # RESTART would parse, which is a different question.
    printf 'drain=1\n'
  } >"$DISPATCHER_FILE"
}
dispatcher_field() { sed -n "s/^$1=//p" "$DISPATCHER_FILE" 2>/dev/null | head -1; }

release_dispatcher_files() {
  [ "$(cat "$PIDFILE" 2>/dev/null)" = "$$" ] || return 0
  rm -f "$PIDFILE" "$DISPATCHER_FILE"
}

# Is $1 a pid this machine can still see running a DISPATCHER? THREE answers,
# because "ps would not say" is not "no" -- the same shape report_dispatcher_code
# already uses for a fleet.sh it cannot hash.
#
#   0  yes: alive, and its command line names a `fleet.sh run`.
#   1  no:  the process is gone, or ps named something that is not a dispatcher.
#   2  cannot say: it is alive, and ps produced no line to judge it by.
#
# The middle answer is the point. A `kill -9`'d dispatcher leaves its pidfile
# behind, the OS wraps round and hands that number to somebody else, and a check
# that asked `kill -0` alone would from then on refuse to start the fleet at all
# -- forever, on the strength of a stranger's process. lib.sh's
# fleet_stop_autostart_watcher takes the same precaution for the same reason,
# before it SIGNALS a pid it did not watch die.
#
# `run` as well as the file name, because only `fleet.sh run` is a dispatcher.
# `fleet.sh status` is run constantly and from every worktree; a recycled pid
# landing on one of those would be a refusal with nothing behind it to stop.
#
# The third answer exists because the callers want opposite things from it. A
# `ps` that cannot answer -- a container without procps, a launch shape whose
# argv does not carry the script path -- must not let `run` hold the fleet down,
# and must not stop `stop --now` SIGNALLING the dispatcher it promises to stop.
# Collapsing it into "no" would do both: `--now` would interrupt every agent,
# announce that there was no dispatcher, leave it polling, and let the next `run`
# start a second one -- #179 rebuilt inside the check for it.
dispatcher_alive() {
  local pid="${1:-}" line
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  line="$(ps -o command= -p "$pid" 2>/dev/null)"
  [ -n "$line" ] || return 2
  printf '%s\n' "$line" | grep -Eq 'fleet\.sh[[:space:]]+run([[:space:]]|$)'
}

# How to make a change live, said wherever the change is not. The cap is here
# because it has the same shape and is asked about far more often: MAX_WORKTREES
# is read once at start, so `AUTOFLEET_MAX=4` in front of `status` changes
# nothing at all.
# $2 is the pull a BEHIND checkout needs, printed in its place in the sequence
# rather than ahead of it. The steps are in the order docs/WORKFLOW.md gives
# them, and they have to stay in it: this output points the reader at that
# section, and a screen that contradicts the page it cites is worse than either
# alone.
restart_advice() {
  local root="${1:-}" pull="${2:-}"
  echo "  Restart it -- it is the only way a change to fleet.sh takes effect:"
  echo "    ./scripts/fleet/stop.sh          # drains: the agents in flight finish"
  echo "    ./scripts/fleet/fleet.sh status  # until it says idle"
  [ -n "$pull" ] && echo "    $pull"
  echo "    ./scripts/fleet/fleet.sh resume"
  # Named, not relative. This report is meant to be read from a fleet worktree,
  # and `./scripts/fleet/fleet.sh run --auto` there starts a dispatcher whose cwd
  # and checkout the fleet removes as soon as that worktree's PR merges.
  if [ -n "$root" ]; then
    echo "    cd $root && ./scripts/fleet/fleet.sh run --auto"
  else
    echo "    ./scripts/fleet/fleet.sh run --auto   # from the MAIN worktree"
  fi
  echo "  AUTOFLEET_MAX, _POLL and _TIMEBOX are read at start too, so they"
  echo "  change only across a restart. docs/WORKFLOW.md, 'Restart it'."
}

# The refusal `fleet.sh run` prints when a dispatcher is already up, and how to
# get past it. A person starting a second one is usually doing the right thing
# for the wrong reason -- the first is running stale code and a restart is the
# remedy `status` names -- so this ends with a takeover they can follow rather
# than just a no.
#
# It calls restart_advice() for the drain rather than restating it. That
# sequence is docs/WORKFLOW.md's, restart_advice's comment says it has to stay
# in that order, and a second copy here is a second place to forget -- it also
# gets the `cd $root` for free, which matters most in exactly this message: the
# refusal is read from wherever you typed `run`, and a relative `run --auto`
# there starts a dispatcher in a directory the fleet removes when that
# worktree's PR merges (status_names_root is the test for it).
#
# BOTH restarts, because they cost different things and both are in
# docs/WORKFLOW.md. A drain is safe with agents mid-work -- since #183 it sets
# DRAIN and not STOP, so the agents finish and their PRs land -- but it WAITS
# for those PRs, and that is hours. A bare `kill` takes the dispatcher over now
# and leaves the agents running; what it gives up is the reaping, so anything
# in flight is then yours with `reap.sh --yes` once it lands.
refuse_second_dispatcher() {
  local holder="$1" root
  # The dispatcher's OWN checkout, not this caller's -- the same asymmetry the
  # staleness report is built on.
  root="$(dispatcher_field root)"
  {
    cat <<REFUSED
a dispatcher is already running (pid $holder).

MAX_WORKTREES is enforced per process, so a second one would count the same
worktrees this one is counting and launch on top of them -- twice the cap
between them, and two of every reap, board comment and time-box interrupt.

  ./scripts/fleet/fleet.sh status
      what it is running, whether the fleet.sh it parsed is still current, and
      the \`git pull --ff-only\` when its checkout never pulled the fix -- a
      restart without that one starts the same bytes over.

To take over -- the usual reason to start a second one is that the first is
running stale code. Drain it, which is safe with agents mid-work but waits for
the PRs in flight to merge:

REFUSED
    # No pull argument, deliberately, and this is the one caller that omits it.
    # Whether the dispatcher's checkout is BEHIND is report_dispatcher_code's
    # answer, off an `origin/main` this function has not looked at -- and
    # re-deriving it here would be a second implementation of the one thing #173
    # exists to get right. The text above sends the reader to `status` first for
    # exactly that: it prints the `git pull --ff-only` in its place in the
    # sequence when there is one to print.
    restart_advice "$root"
    cat <<REFUSED

That drain is safe with agents mid-work -- it sets DRAIN, not STOP, so they
finish and their PRs land -- but it WAITS for those PRs, which is hours. To
take this dispatcher over NOW without interrupting anybody, kill it instead
and reap what it does not get to yourself:

  kill $holder
  ./scripts/fleet/fleet.sh status  # until it says idle
  ./scripts/fleet/reap.sh --yes    # the stacks it did not live to reap
REFUSED
    if [ -n "$root" ]; then
      echo "  cd $root && ./scripts/fleet/fleet.sh run --auto"
    else
      echo "  ./scripts/fleet/fleet.sh run --auto   # from the MAIN worktree"
    fi
    cat <<REFUSED

Both are docs/WORKFLOW.md, "Restart it". The pid above came from
$PIDFILE, and nothing here removed it: it is the running dispatcher's.
REFUSED
  } >&2
  exit 1
}

# What `status` says about the dispatcher's own code. Three answers, because
# "could not tell" is not "current": a staleness report that fails open is the
# same silence #173 was.
report_dispatcher_code() {
  local root started commit hash now log remote
  root="$(dispatcher_field root)"
  started="$(dispatcher_field started)"
  hash="$(dispatcher_field hash)"
  commit="$(dispatcher_field commit)"
  # -r, not -e: fleet_code_hash answers nothing for a file it cannot READ, and
  # nothing compares unequal to the recorded hash -- which would report a
  # dispatcher as STALE on the strength of a permission error. "Cannot say" is
  # the honest answer to every question this cannot ask.
  if [ -z "$hash" ] || [ -z "$root" ] || [ ! -r "$root/scripts/fleet/fleet.sh" ]; then
    echo "  it recorded no fleet.sh at start -- it predates this check, or the"
    echo "  checkout it started from is gone -- so this cannot say whether a"
    echo "  recent fix is live in it."
    restart_advice
    return 0
  fi
  [ -n "$started" ] && echo "  up since $(fmt_epoch "$started")${commit:+, running fleet.sh @ ${commit:0:7}}"
  now="$(fleet_code_hash "$root")"
  if [ -n "$now" ] && [ "$now" = "$hash" ]; then
    # The bytes it parsed are still the bytes on disk, which is not the end of
    # it: nothing in the fleet pulls that checkout, so a fix MERGED while it ran
    # -- #173's own case -- leaves the file untouched and the hashes equal. The
    # remote-tracking ref is shared by every worktree of this repo, so asking it
    # costs nothing and needs no network; a checkout that has genuinely never
    # fetched simply has nothing to name.
    log="$(fleet_commits_between "$root" "$commit" origin/main)"
    [ -n "$log" ] || return 0
    # ...and those commits have to leave the file actually different. A change
    # and its revert are two commits that name each other out, and telling
    # somebody to pull and restart for bytes already running is the report
    # crying wolf on its own first outing.
    remote="$(git -C "$root" show origin/main:scripts/fleet/fleet.sh 2>/dev/null | fleet_hash_stdin)"
    [ -n "$remote" ] && [ "$remote" = "$hash" ] && return 0
    echo
    echo "  BEHIND -- $root has not pulled these, so they are NOT live in the"
    echo "  dispatcher running, and a restart alone will not make them live:"
    printf '%s\n' "$log" | sed 's/^/    /'
    restart_advice "$root" "git -C $root pull --ff-only"
    return 0
  fi

  echo
  echo "  STALE -- $root/scripts/fleet/fleet.sh has changed since it started, and"
  echo "  it parses the file once. These are NOT live in the dispatcher running:"
  log="$(fleet_commits_between "$root" "$commit" HEAD)"
  if [ -n "$log" ]; then
    printf '%s\n' "$log" | sed 's/^/    /'
  else
    # The bytes differ and git cannot name the difference -- an uncommitted edit,
    # or a checkout that never had that commit. Still stale.
    echo "    (git cannot name them from ${commit:-nothing recorded}; the file on disk differs)"
  fi
  restart_advice "$root"
}

# The one case a drain can fail in silently: a dispatcher older than the file it
# writes. DRAIN is read by this dispatcher and by nothing else, so a process
# that parsed a fleet.sh from before #183 polls straight through it, launching
# worktrees while the screen says the fleet is stopping.
#
# record_dispatcher writes `drain=1` and a running process is the only thing
# that can say what it parsed -- the bytes on disk are what a RESTART would
# parse, which is a different question and the one report_dispatcher_code asks.
# So a live dispatcher without that field either predates this or recorded
# nothing at all, and both mean the same thing here: it cannot be confirmed to
# see the drain.
#
# It WARNS. It does not refuse -- `stop.sh` always doing something is the
# promise docs/WORKFLOW.md makes of it -- and it does not quietly fall back to
# writing the STOP file, which would re-arm the freeze this whole change exists
# to remove and would freeze three agents to work around one old process.
warn_blind_dispatcher() {
  local held; held="$(cat "$PIDFILE" 2>/dev/null)"
  dispatcher_alive "$held"; local held_is=$?
  # 1 is "nothing is running", and there is nothing to be blind to the file.
  # 2 -- alive, and ps would not say what it is -- warns with the rest: what
  # cannot be established is exactly what this is about.
  [ "$held_is" = 1 ] && return 0
  [ -n "$(dispatcher_field drain)" ] && return 0
  local root; root="$(dispatcher_field root)"
  echo
  echo "  WARNING: pid $held is running and did not record that it reads"
  echo "           $DRAIN_FILE."
  echo "           A dispatcher that predates that file cannot see this drain:"
  echo "           it goes on launching worktrees while this screen says the"
  echo "           fleet is stopping. Take it over instead, which leaves the"
  echo "           agents alone:"
  echo "             kill $held"
  echo "             ./scripts/fleet/fleet.sh status  # until it says idle"
  if [ -n "$root" ]; then
    echo "             cd $root && ./scripts/fleet/fleet.sh run --auto"
  else
    echo "             ./scripts/fleet/fleet.sh run --auto   # from the MAIN worktree"
  fi
  echo "           Or ./scripts/fleet/stop.sh --now, which stops it and freezes"
  echo "           every agent with it."
}

# --------------------------------------------------------------- commands ---
cmd_status() {
  echo "fleet state: $STATE_DIR"
  # Which reviewer is going to answer the agents waiting in await-review.sh, and
  # said on the FIRST screen anybody looks at. The failure this heads off is a
  # quiet one: in `github` mode with no CLAUDE_CODE_OAUTH_TOKEN the review job
  # no-ops, every PR blocks on a review that cannot arrive, and nothing anywhere
  # says which of the two reviewers this repository actually has.
  if fleet_review_is_local; then
    # LOCKS only. `stop_reviewers` and `live_reviewers` both learned to skip
    # the record files; this third reader of the directory did not -- and it is
    # the one its own comment calls the first screen anybody looks at. A `.done`
    # stands for as long as its head does, which is the point of the file, so
    # status reported a reviewer in flight permanently rather than transiently,
    # and three reviewed PRs read as every slot taken. Found by the independent
    # review, on both axes independently.
    # Through the predicate, not a fourth spelling of the suffix list: the
    # `find ! -name` this replaces WAS the drift, and it is the only one of the
    # three consumers a person reads on every `status`.
    local n=0 m
    for m in "$REVIEWING_DIR"/*; do
      [ -e "$m" ] || continue
      is_review_record "$m" && continue
      n=$((n + 1))
    done
    echo "review:      local -- the dispatcher runs it ($AUTOFLEET_REVIEW_CMD), $n in flight"
  else
    echo "review:      github -- .github/workflows/claude-review.yml, which needs"
    echo "             a CLAUDE_CODE_OAUTH_TOKEN secret on the repository"
  fi
  # A stop and a running dispatcher are not alternatives: a drain leaves the
  # dispatcher up on purpose, because it is what reaps a worktree once its PR
  # merges -- and that draining dispatcher is running whatever code it parsed.
  # Which of the two, in the word the rest of the fleet uses for it. They are
  # not the same state and the person reading this is deciding whether to wait:
  # under a drain the agents are finishing and their PRs will land, under a stop
  # nothing they do can reach GitHub at all.
  if hard_stopped; then
    echo "STOPPED  ($STOP_FILE -- nothing goes out; clear with: ./scripts/fleet/fleet.sh resume)"
  elif draining; then
    echo "DRAINING ($DRAIN_FILE -- no new worktrees; the agents in flight finish"
    echo "          and their PRs land. Clear with: ./scripts/fleet/fleet.sh resume)"
  fi
  # dispatcher_alive, not `kill -0` alone: a pidfile a `kill -9` left behind,
  # whose pid the OS has since handed to somebody else, would otherwise be
  # reported as a dispatcher that is running -- and `run` would start one
  # anyway, because it asks the stricter question. Two screens disagreeing about
  # whether the fleet is up is worse than either answer.
  local pid; pid="$(cat "$PIDFILE" 2>/dev/null)"
  dispatcher_alive "$pid"; local live=$?
  if [ "$live" != 1 ]; then
    if [ "$live" = 2 ]; then
      # Alive, unidentifiable. Not `idle` -- a report that fails open here sends
      # somebody to start a second dispatcher, which is the whole of #179.
      echo "running?  (pid $pid -- alive, but ps would not say whether it is a dispatcher)"
    else
      echo "running   (pid $pid)"
    fi
    report_dispatcher_code
  else
    # Printed while stopped too. A drain ends when the dispatcher exits, and
    # this is the line that says it has -- WORKFLOW.md's restart waits for it.
    echo "idle      (no dispatcher running)"
  fi
  echo
  echo "worktrees now:"
  # A worktree waiting for a PERSON is not a worktree working, and after the
  # drain learned to end with one outstanding, the state a reader actually meets
  # is new: the dispatcher gone, `idle` on screen, and a directory still listed
  # here with nothing saying why it survived or how to release it. Issue 37 asks
  # this line to tell the two apart; the change that fixed the drain did not.
  # Found by the independent review.
  live_worktrees | while IFS="$(printf '\t')" read -r num path; do
    # `parked_for_person`, not `why_parked`: a worktree whose agent is still
    # working is not waiting for anybody, and printing the recovery line for it
    # tells a person to discard what is being written.
    #
    # In the QUIET voice -- the default, spelled out here because this is the
    # caller that makes it matter. `status` answers from $STATE_DIR and writes
    # nothing back to it; see the note on `parked_for_person`. #35.
    why="$(parked_for_person "$num" quiet)" && why="waiting for you -- $why" || why=""
    if [ -n "$why" ]; then
      printf '  #%-5s %s\n' "$num" "$path"
      printf '         %s\n' "$why"
      printf '         %s\n' "$(how_to_release "$num" "$path")"
    else
      printf '  #%-5s %s\n' "$num" "$path"
    fi
  done
  echo
  echo "next up (ready, not in flight, not labelled $HUMAN_STEP_LABEL;"
  echo "         'unblocks' is how many issues it frees, and a row marked"
  echo "         $PRIORITY_LABEL goes ahead of that ordering):"
  # The column is HEADED with the label word and FILLED with the label word, and
  # sized to it. Heading it `ahead` and filling it with `priority` named two
  # different things in one column; and a fixed `%-9s` fits the default with one
  # character to spare, so a host renaming the label to anything longer pushed
  # that row's title past the header and only that row's -- which reads as the
  # rendering bug this marker exists to prevent. Both found by the independent
  # review. `unblocks` is 8, so 8 is the floor that keeps the columns apart.
  local col="${#PRIORITY_LABEL}"
  [ "$col" -ge 8 ] || col=8
  printf "  %-6s %-9s %-${col}s %s\n" "issue" "unblocks" "$PRIORITY_LABEL" "title"
  # The label column ready_issues already prints is what says which rows are
  # ahead of the queue: a `next up` list reordered with nothing on screen saying
  # why reads as a bug in the ordering, which is the report this marker exists
  # to prevent.
  ready_issues | while IFS="$(printf '\t')" read -r num unblocks labels title; do
    in_flight "$num" && continue
    gave_up_on "$num" && continue
    local mark=""
    has_label "$labels" "$PRIORITY_LABEL" && mark="$PRIORITY_LABEL"
    printf "  #%-5s %-9s %-${col}s %s\n" "$num" "$unblocks" "$mark" "$title"
  done | head -12

  # ...and where the ones missing from that list went, since a `ready` issue the
  # dispatcher silently declines forever is the confusing half of this.
  local gaveup; gaveup="$(gave_up_issues)"
  if [ -n "$gaveup" ]; then
    echo
    echo "gave up on (hand one back with: ./scripts/fleet/fleet.sh retry N):"
    printf '%s\n' "$gaveup" | while read -r num; do printf '  #%s\n' "$num"; done
  fi
}

cmd_stop() {
  local mode="${1:-}"
  # Validated first: `stop.sh --nwo` used to set the stop and then die with a
  # usage error, which is a confusing way to be safe.
  case "$mode" in
    ""|--now|--all) ;;
    *) die "usage: fleet.sh stop [--now|--all]" ;;
  esac
  mkdir -p "$STATE_DIR"
  # The drain, in every mode: it is the half that means "start nothing new", and
  # a hard stop is that plus a freeze.
  date '+draining since %Y-%m-%d %H:%M:%S' >"$DRAIN_FILE"
  case "$mode" in
    --now|--all)
      date '+stopped at %Y-%m-%d %H:%M:%S' >"$STOP_FILE"
      echo "stop set: $STOP_FILE (and the drain, $DRAIN_FILE)"
      echo "  no new worktrees, and no agent can push, open a PR or comment."
      # --now reaches the agents the fleet started. --all reaches every agent
      # Orca knows about, including sessions a person opened by hand -- which is
      # a bigger hammer than a fleet stop, so it has to be asked for by name.
      echo "  interrupting agents..."
      local handle path
      if [ "$mode" = "--all" ]; then
        # The listing's rc is READ, not piped away. A runtime that would not
        # answer prints the same "interrupting agents..." followed by nothing as
        # a machine with no agents on it -- and `--all` is the hammer somebody
        # reaches for when they need every agent stopped NOW. The one case where
        # a false "there were none" is worst. Found by the independent review.
        local listing
        if listing="$(runner_agent_terminals)"; then
          printf '%s\n' "$listing" | cut -f1 | while read -r handle; do
            [ -n "$handle" ] || continue
            runner_terminal_interrupt "$handle" && echo "    interrupted $handle"
          done
        else
          echo "    the runner would not list its agents -- NONE were interrupted,"
          echo "    which is not the same as there being none. Stop them by hand."
        fi
      else
        # The rc is read HERE TOO, and this is the branch `stop --now` actually
        # takes -- CLAUDE.md describes `--now` as the form that "also freezes the
        # agents". `runner_agent_terminal` is non-zero ONLY when the listing
        # could not be read; empty output means there is genuinely no agent in
        # that worktree, which is a real answer. Collapsing the two printed
        # "interrupting agents..." and then nothing: byte-for-byte what a machine
        # with no agents on it prints, while three agents kept writing against a
        # rig that was going down. Design note 2 of #1, on the third and last
        # callsite of it. Found by the independent review.
        #
        # Said ONCE, after the loop, rather than per worktree: one unreadable
        # listing is one fact about the runtime, and repeating it per owned issue
        # buries the interrupts that did land above it.
        local unreadable=0
        for f in "$OWNED_DIR"/*; do
          [ -e "$f" ] || continue
          path="$(cat "$f")"
          if ! handle="$(runner_agent_terminal "$path")"; then
            unreadable=1
            continue
          fi
          [ -n "$handle" ] || continue
          runner_terminal_interrupt "$handle" && echo "    interrupted #$(basename "$f")"
        done
        if [ "$unreadable" = 1 ]; then
          echo "    the runner would not list its agents -- some or NONE were"
          echo "    interrupted, which is not the same as there being none."
          echo "    Stop them by hand; --all reads the same listing and would"
          echo "    not do better."
        fi
      fi
      # ...and the local reviewers, which are children of the dispatcher rather
      # than agents in a worktree, so the terminal interrupts above do not reach
      # them. Before the dispatcher is killed: after it, nothing is left that
      # knows which pids they were.
      stop_reviewers

      # Only here. A drain has to leave the dispatcher alive: it is what reaps a
      # worktree once its PR merges, and killing it strands them.
      #
      # dispatcher_alive before the signal, which is the whole of lib.sh's
      # fleet_stop_autostart_watcher in one line: this is the only place the
      # fleet SIGNALS a pid it read out of a file, and a pidfile a `kill -9`
      # left behind names whoever the OS has since given that number to.
      local held; held="$(cat "$PIDFILE" 2>/dev/null)"
      dispatcher_alive "$held"; local held_is=$?
      # Signalled on "yes" AND on "cannot say". `--now` promises the dispatcher
      # is down when it returns, and a ps that would not answer is not a reason
      # to break that promise and leave it polling -- it is exactly the state
      # where a false "nothing to stop" produces the second dispatcher.
      if [ "$held_is" != 1 ]; then
        kill "$held" 2>/dev/null && echo "  dispatcher stopped."
        [ "$held_is" = 2 ] \
          && echo "  (ps would not say what pid $held was; signalled it because --now promises it is down.)"
      elif [ -e "$PIDFILE" ]; then
        echo "  no dispatcher to stop; $PIDFILE names pid ${held:-nothing}, which is not one."
      fi ;;
    "")
      echo "drain set: $DRAIN_FILE"
      # ...but a drain does not LIFT a stop, and saying "the agents are not
      # frozen" while $STOP_FILE is still there is the reassurance somebody
      # would act on: `--now` to freeze, then a plain `stop.sh` later to let the
      # work land, and the agents stay frozen with the screen saying otherwise.
      if hard_stopped; then
        echo "  ...but $STOP_FILE is STILL SET, so the agents stay frozen: no push,"
        echo "  no PR, no comment. A drain does not lift a stop. To let the work in"
        echo "  flight land, clear it and drain again:"
        echo "    ./scripts/fleet/fleet.sh resume && ./scripts/fleet/stop.sh"
      else
        echo "  no new worktrees. The agents in flight are NOT frozen: they finish,"
        echo "  push, open their PRs and comment, because a merged PR is what releases"
        echo "  the worktree this drain is waiting on."
        echo "  The dispatcher stays up to reap those worktrees as their PRs land, and"
        echo "  exits once nothing is left. Watch it with: fleet.sh status."
        echo "  Use --now to interrupt the fleet's agents and freeze every outward"
        echo "  effect, --all to interrupt every agent the runner knows about."
      fi
      # Last, because it is the line that changes what you do next.
      warn_blind_dispatcher ;;
  esac
  if hard_stopped; then
    notify "stopped" "No new work will start, and nothing goes out."
  else
    notify "draining" "No new work will start; the agents in flight finish."
  fi
}

cmd_resume() {
  # Both, always. Clearing one of the two leaves a fleet that either refuses
  # every `run` with the stop apparently lifted, or lets the agents out while
  # nothing may start -- neither is a state anybody asked for.
  rm -f "$STOP_FILE" "$DRAIN_FILE"
  echo "drain and stop cleared. Start again with: ./scripts/fleet/fleet.sh run --auto"
}

# The counterpart to the time-box, and the ONLY way back onto the queue. By name
# and on purpose: the box fired because three hours produced no PR, and an issue
# handed back unchanged spends the next three the same way. Restarting the
# dispatcher deliberately does not clear these -- a crash and a reboot are not
# decisions about an issue.
cmd_retry() {
  [ "$#" -gt 0 ] || die "usage: fleet.sh retry ISSUE [ISSUE...]"
  local n
  for n in "$@"; do
    case "$n" in ''|*[!0-9]*) die "not an issue number: $n" ;; esac
  done
  for n in "$@"; do
    if [ -e "$STATE_DIR/gaveup-$n" ]; then
      rm -f "$STATE_DIR/gaveup-$n"
      echo "#$n is startable again."
    else
      echo "#$n was not one this dispatcher gave up on; nothing to clear."
    fi
  done
}

# Accepts 08:00 (the next such time), 6h, 90m, or an epoch.
deadline_from() {
  python3 -c '
import sys, time, datetime
spec = sys.argv[1]
now = time.time()
if spec.endswith("h"):   print(int(now + float(spec[:-1]) * 3600)); raise SystemExit
if spec.endswith("m"):   print(int(now + float(spec[:-1]) * 60)); raise SystemExit
if ":" in spec:
    h, m = (int(x) for x in spec.split(":"))
    t = datetime.datetime.now().replace(hour=h, minute=m, second=0, microsecond=0)
    if t.timestamp() <= now:
        t += datetime.timedelta(days=1)
    print(int(t.timestamp())); raise SystemExit
print(int(spec))
' "$1" 2>/dev/null
}

cmd_run() {
  # THE DRAIN LATCH, once. Three stop conditions were each spelling the same
  # three lines -- set the flag, set the reason, say "-- launching nothing more,
  # still reaping what is in flight" -- and a fourth arrived with this change.
  # Three copies of a sentence are three chances for the stop conditions to stop
  # saying the same thing, which is the property #36 is about. `reason` is what
  # `fleet down: $reason` prints; `$2` is what this pass says on the way in.
  # It closes over cmd_run's locals rather than taking them, because that is the
  # whole of what it replaces. Found by the independent review.
  enter_drain() {
    drain_mode=true
    reason="$1"
    say "$2 -- launching nothing more, still reaping what is in flight"
  }
  local auto=false deadline="" max_prs="" ; local -a wanted=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --auto)     auto=true; shift ;;
      --until|--for) deadline="$(deadline_from "$2")" || die "cannot read a time from '$2'"
                  [ -n "$deadline" ] || die "cannot read a time from '$2'"; shift 2 ;;
      --max-prs)  max_prs="$2"; shift 2 ;;
      [0-9]*)     wanted+=("$1"); shift ;;
      *) die "usage: fleet.sh run [--auto] [--until HH:MM|--for 6h] [--max-prs N] [ISSUE...]" ;;
    esac
  done
  $auto || [ "${#wanted[@]}" -gt 0 ] || die "give issue numbers, or --auto"
  # The stop is checked first, and it has to say more than "stopped" when a
  # dispatcher is still draining behind it. That sentence IS the way in: a drain
  # leaves the dispatcher up on purpose, `status` says `running (pid N)`
  # throughout, and somebody who reads "stopped" as "down" runs `resume` and
  # `run --auto`. The refusal below would then catch them, but a message that
  # sends them there in the first place is a worse place to be caught.
  if draining; then
    # `held`, not `drain_mode`: cmd_run declares a `local drain_mode=false`
    # further down and RUNS it as a command (`! $drain_mode`). Both branches
    # here die, so the collision is harmless today and would not stay that way.
    local held; held="$(cat "$PIDFILE" 2>/dev/null)"
    local state; state="$(stop_state)"
    local which_file; which_file="$(stop_state_file)"
    if dispatcher_alive "$held"; then
      die "the fleet is $state ($which_file), and pid $held is still DRAINING:
launching nothing new, and reaping what is in flight until nothing it owns is
left, which is what a drain is. It exits on its own; watch it with
\`fleet.sh status\`, and only then start one.

\`fleet.sh resume\` clears the stop. It does NOT make room for a second
dispatcher -- MAX_WORKTREES is enforced per process, so \`run\` would refuse
while that one is up."
    fi
    die "the fleet is $state ($which_file). Clear it with: fleet.sh resume"
  fi

  # One dispatcher per machine, checked before the pidfile is claimed rather
  # than trusted from it: `fleet.pid` names whoever started LAST, so before this
  # the second dispatcher simply became the recorded one and the first kept
  # polling unrecorded (#179).
  #
  # The way in is ordinary rather than exotic. A drain leaves the dispatcher up
  # on purpose -- it is what reaps a worktree once its PR merges -- and `status`
  # says `running (pid N)` for as long as that lasts. And #173's staleness
  # report answers "a dispatcher older than its own fleet.sh" with "restart it",
  # so making staleness visible is also what multiplies the restarts this has to
  # catch.
  #
  # Read-then-claim, and the window between them is not closed: two dispatchers
  # started inside the same millisecond would both get past this. That is not
  # the way in -- the drain leaves the first one up for HOURS and somebody
  # resumes on top of it -- and an atomic claim wants a temp file or an
  # O_EXCL dance whose leftovers are their own failure mode in a state dir a
  # `kill -9` already litters.
  local holder; holder="$(cat "$PIDFILE" 2>/dev/null)"
  dispatcher_alive "$holder"
  case $? in
    0) refuse_second_dispatcher "$holder" ;;
    # Alive, and ps had nothing to judge it by. It starts -- a fleet one stale
    # file can hold down forever is the failure this check exists to avoid, and
    # the acceptance for #179 says so outright. But it does not start SILENTLY:
    # if that pid really is a dispatcher, this is the two-of-them case and the
    # only warning anybody gets.
    2) say "WARNING: $PIDFILE names pid $holder, which is alive, and ps would not say what it is."
       say "         Starting anyway -- one unreadable pidfile may not hold the fleet down."
       say "         But if pid $holder IS a dispatcher there are now two, each enforcing"
       say "         MAX_WORKTREES on its own. Find out before you leave this running:"
       say "           ps -p $holder" ;;
  esac

  # The record BEFORE the pidfile, and the order is the whole of it: every
  # reader of the record reaches it through the pidfile -- `status` and
  # `warn_blind_dispatcher` both ask `dispatcher_alive` first -- so a pid
  # claimed before the record exists is a window in which this dispatcher is
  # live, current, and has recorded nothing. `stop.sh` landing in it would
  # announce that a dispatcher which reads the drain file perfectly well cannot
  # see it. A record with no pidfile is inert the other way round: nothing looks
  # at it, and the next dispatcher overwrites it.
  # Markers left by a dispatcher that died without cleaning up. Their pids are
  # not ours, and after a reboot or a few hours they name strangers -- so they
  # are cleared before this dispatcher counts anything, rather than reaped
  # one-by-one against a `kill -0` that cannot tell the difference.
  stop_reviewers >/dev/null
  # ...and the "already said it" markers, so this dispatcher explains its own
  # holds rather than inheriting a previous run's silence. `rotate-blind` is the
  # same shape and was cleared by nothing at all, so "rotating with a pid ps
  # cannot name" was said once per MACHINE -- an operator debugging truncated
  # reviewer output next month got no line at all. Found by the independent
  # review.
  rm -f "$FOUNDATION_HOLD_SAID" "$ROTATE_BLIND_SAID"

  record_dispatcher
  echo $$ >"$PIDFILE"
  # ...but removed only while they still name THIS process. Nothing stops a
  # second dispatcher from starting and claiming both files, and an unconditional
  # `rm` would then have the first one's exit delete the second one's record --
  # leaving a live dispatcher reported as idle, with nothing to check its code
  # against. That is the silence this whole file's staleness report exists to end.
  trap 'release_dispatcher_files' EXIT
  say "fleet up: max $MAX_WORKTREES worktrees, polling every ${POLL_SECONDS}s, ${TIMEBOX_SECONDS}s per issue"
  $auto && say "mode: auto -- most-unblocking first, until the backlog is empty or you stop it" \
        || say "mode: list -- ${wanted[*]}"
  [ -n "$deadline" ] && say "stopping at $(date -r "$deadline" '+%Y-%m-%d %H:%M')"
  [ -n "$max_prs" ] && say "stopping after $max_prs worktree(s) opened"

  local opened=0 reason="the queue is empty"
  # Not `draining` -- that is the FUNCTION above, which asks the filesystem.
  # This is the run's own latch, and it is also set by --until and --max-prs,
  # neither of which writes a file.
  local drain_mode=false
  # An issue dropped from `wanted` did not land, and saying it did is a lie the
  # run's last line would tell every time the fleet declines one.
  local declined=false
  while true; do
    # A stop means "launch nothing more", not "abandon what is running". The
    # dispatcher is what reaps a worktree once its PR merges, so killing it here
    # would strand every in-flight stack under `restart: unless-stopped`. It
    # keeps reaping and exits when nothing it owns is left.
    if draining && ! $drain_mode; then enter_drain "you stopped it" "draining"; fi
    if [ -n "$deadline" ] && [ "$(date +%s)" -ge "$deadline" ] && ! $drain_mode; then
      enter_drain "the deadline passed" "deadline passed"
    fi

    # Between passes, before anything writes: the log rotation must not land
    # mid-pass, and the marker sweep reads git, which is cheap and local.
    rotate_fleet_log
    prune_reviewed_markers

    forget_poll_answers
    # ...here, once per pass, and nowhere else: see the note beside the
    # definition.
    #
    # The order below is load-bearing in three places. reap_merged first,
    # because a worktree whose PR merged is its business and reap_abandoned only
    # ever looks at what is left owned. enforce_timebox before notice_stalled,
    # because the
    # first writes `$POLL_CACHE/carded-` and the second reads it to avoid
    # repeating a board comment it has already made. And reap_abandoned LAST of
    # the four: it is the one that removes a worktree, and running it earlier
    # took the "waiting for you, as expected" notification away from the very
    # worktrees it exists to release -- the watchers would have found nothing
    # there to speak about.
    reap_merged
    # After reap_merged, because a PR that just merged needs no review, and
    # before the rest because it is the only one of these that UNBLOCKS a
    # worktree rather than reclaiming one: an agent sitting in await-review.sh
    # is waiting on exactly this, and every pass it waits is a pass of its
    # time-box spent.
    review_open_prs
    enforce_timebox
    notice_stalled
    reap_abandoned
    prune_gaveup

    local live live_list
    if ! live_list="$(live_worktrees)"; then
      say "could not read this repository's worktree list; skipping this pass rather than guessing"
      sleep "$POLL_SECONDS"
      continue
    fi
    live="$(count_worktrees "$live_list")"

    while ! $drain_mode && [ "$live" -lt "$MAX_WORKTREES" ]; do
      # `break`, not `break 2`: this is the drain arriving MID-PASS, after the
      # check at the top of the loop and while worktrees are still owned, which
      # is what `stop.sh` against a running fleet actually looks like. Leaving
      # the whole loop here ended the dispatcher on the spot -- nothing reaped
      # the worktrees it was holding, and their stacks stayed up under
      # `restart: unless-stopped` with nothing left to take them down. It stops
      # LAUNCHING here and keeps reaping, which is the same thing the top of the
      # loop does one pass later.
      if check_drain; then enter_drain "you stopped it" "draining"; break; fi
      # A DRAIN, not an exit. `break 2` left the launch loop AND the poll loop,
      # so the dispatcher stopped with its worktrees mid-work: nothing reaped
      # them when their PRs merged, their stacks stayed up under
      # `restart: unless-stopped`, and $OWNED_DIR kept entries the next
      # dispatcher inherited and counted against its cap. The comment a few
      # lines above records that exact bug being fixed for the drain path;
      # `--until` and `--for` set `drain_mode` and keep reaping, and
      # docs/WORKFLOW.md advertises all three as equivalent. They were not.
      # armaatus/autofleet#36.
      # No `! $drain_mode` guard: the enclosing loop is `while ! $drain_mode`,
      # and the only assignment inside it breaks out at once, so it could never
      # be false here and reading it suggested otherwise.
      if [ -n "$max_prs" ] && [ "$opened" -ge "$max_prs" ]; then
        enter_drain "it opened $opened worktree(s)" "opened $opened worktree(s)"
        break
      fi

      # EVERY ITERATION, which is what makes one check cover both halves of the
      # rule: it holds when a foundation issue was already running when this
      # dispatcher started, and it holds again on the iteration after this pass
      # launches one, because by then that worktree is in the list too.
      #
      # Cheap despite that. The whole answer is cached per poll, and `launch`
      # drops the cache -- so a pass costs one `live_worktrees` plus one more per
      # worktree it opens, not one per iteration. An earlier version of this
      # comment described the cost before that cache existed and claimed only the
      # label lookups were cached; found by the local review.
      if foundation_in_flight; then break; fi

      local picked="" title="" labels=""
      if [ "${#wanted[@]}" -gt 0 ]; then
        # An issue leaves `wanted` only when it is DONE -- merged, or its
        # worktree gone with a PR standing. An issue that is merely in flight
        # stays, so it is not re-launched when its PR merges and `in_flight`
        # goes false again, and so the termination check below can see that
        # something is still outstanding.
        local remaining=()
        local n rc
        for n in "${wanted[@]}"; do
          if issue_is_done "$n"; then
            say "#$n has landed"
            continue
          fi
          # DROPPED, not skipped, for the same reason the label decline below
          # drops one: an issue kept in `wanted` that can never be launched is a
          # run loop that never ends.
          if gave_up_on "$n"; then
            say "#$n: the fleet gave up on it -- hand it back with: fleet.sh retry $n"
            declined=true
            continue
          fi
          in_flight "$n"; rc=$?
          if [ -z "$picked" ] && [ "$rc" = 1 ]; then
            # Asked only of the one issue this pass would actually launch, not
            # of every issue in the list: count_startable exists because a `gh`
            # call per queued issue per poll is how you meet the secondary rate
            # limit. Named on the command line or picked from the queue, the
            # fleet cannot finish this one either way -- so it is DROPPED rather
            # than skipped, because an issue kept in `wanted` that can never be
            # launched is a run loop that never ends. "Could not tell" keeps it,
            # since opening a worktree for work no agent may finish is the
            # expensive direction and the next pass asks again.
            issue_needs_human_step "$n"; case $? in
              0) say "#$n is labelled $HUMAN_STEP_LABEL -- it is yours to take; remove the label to hand it to an agent"
                 rm -f "$STATE_DIR/queue-labels-$n"; declined=true; continue ;;
              2) if [ ! -e "$STATE_DIR/queue-labels-$n" ]; then
                   : >"$STATE_DIR/queue-labels-$n"
                   say "#$n: could not read its labels -- not starting it this pass"
                 fi
                 remaining+=("$n"); continue ;;
            esac
            rm -f "$STATE_DIR/queue-labels-$n"
            picked="$n"
          fi
          remaining+=("$n")
        done
        wanted=("${remaining[@]+"${remaining[@]}"}")
        [ -n "$picked" ] || break
        title="$(GH_PAGER=cat gh issue view "$picked" --json title --jq .title 2>/dev/null)"
        labels="$(GH_PAGER=cat gh issue view "$picked" --json labels --jq '[.labels[].name]|join(",")' 2>/dev/null)"
      else
        $auto || break
        while IFS="$(printf '\t')" read -r n _unblocks l t; do
          in_flight "$n"; [ "$?" = 1 ] || continue
          # Said once, when the box fired -- not once per poll for the rest of
          # the run.
          gave_up_on "$n" && continue
          # A foundation issue defines an interface later issues include, so it
          # lands alone: three worktrees each inventing their own version of a
          # shared header is the one merge conflict worth serialising to avoid.
          if is_foundation "$l" && [ "$live" -gt 0 ]; then
            # Through `foundation_hold_say`, so this door to the log is as quiet
            # as the other one. The same rule announced every poll from here
            # would have put back the 180 lines per three hours that the marker
            # exists to prevent. Found by the independent review.
            # NAMED, not counted. The marker carries the names too, so the line
            # comes back when what it waits on CHANGES -- which is news -- and
            # stays quiet while it does not.
            local waiting_on; waiting_on="$(waiting_worktrees "$live_list")"
            foundation_hold_say "waiting-$n-$waiting_on" \
              "#$n is a foundation issue; it lands alone, so it waits for $waiting_on to land"
            break
          fi
          picked="$n"; title="$t"; labels="$l"
          break
        done < <(ready_issues)
      fi
      [ -n "$picked" ] || break

      if is_foundation "$labels" && [ "$live" -gt 0 ]; then break; fi
      if launch "$picked" "$title"; then
        opened=$((opened + 1))
        # THE WITHIN-A-PASS HALF OF THE RULE, from what is already in hand.
        #
        # `foundation_in_flight` on the next iteration would also stop here --
        # `launch` drops its cache for exactly that -- but only by asking the
        # Orca CLI to tell us something we already know, and only if two things
        # hold that nothing guarantees: that `worktree list` shows a worktree
        # `worktree create` returned moments ago, and that the entry carries
        # `linkedIssue` rather than a null this function reads as "on no issue".
        # Neither is promised by a CLI backed by an index or a daemon, and the
        # stub in tests/test_fleet.sh is read-your-writes BY CONSTRUCTION -- a
        # property this very PR gave it -- so the phase for this half was
        # asserting the assumption rather than the behaviour.
        #
        # `$labels` is the labels of the issue just launched. Asking them costs
        # nothing and cannot be wrong. The per-iteration check keeps doing what
        # only it can: the across-passes half, which survives a restart.
        # Complementary, not redundant. Found by the independent review.
        if is_foundation "$labels"; then
          say "#$picked is a foundation issue; it lands alone, so nothing else starts this pass"
          break
        fi
      else
        # It stays in the queue. Dropping an issue whose worktree failed to open
        # and then reporting "every issue it was given has landed" is a lie the
        # next poll would repeat forever.
        say "  leaving #$picked in the queue to try again"
        break
      fi
      live_list="$(live_worktrees)" || break
      live="$(count_worktrees "$live_list")"
    done

    # Nothing left to launch, and nothing left to look after: done. Reaching
    # this in --auto is how it stops on an empty backlog; reaching it in list
    # mode is how it stops once every issue it was given has landed. Until then
    # it keeps polling, because reaping a merged worktree and enforcing the
    # time-box are its job in both modes.
    local owned; owned="$(ls "$OWNED_DIR" 2>/dev/null | grep -c .)"
    # ...minus the ones waiting for a PERSON. `park_worktree` keeps a worktree
    # owned when its removal was refused, which is right -- releasing it would
    # destroy what could not be removed. But the loop exits only on
    # `owned == 0`, and under a drain `queued` is forced to 0, so a parked
    # worktree made that the only exit and it never came: the dispatcher polled
    # forever, `status` never said idle, and `cmd_run` refuses a second
    # dispatcher while one is alive. `stop.sh` promises "exits once nothing is
    # left". armaatus/autofleet#37.
    local parked; parked="$(count_parked_owned)"
    [ "$parked" -gt 0 ] && owned=$(( owned - parked ))
    # Still clamped, and now it should be unreachable: `parked` counts distinct
    # owned issues, so it cannot exceed `owned`. Kept because a wrong answer here
    # ends the dispatcher with work in flight, and a clamp is cheaper than that.
    [ "${owned:-0}" -lt 0 ] && owned=0
    # THE DRAIN COMES FIRST, and in BOTH modes. Under a drain nothing launches,
    # so what is still queued cannot keep the dispatcher alive -- only what it
    # still owns can. The guard used to live on the `$auto` branch alone, and in
    # LIST mode that was the wedge this PR's own `--max-prs` fix created:
    #
    #   `wanted` is pruned only INSIDE the launch loop, and that loop is gated
    #   on `while ! $drain_mode`. So `run --max-prs 1 148` launches #148,
    #   `remaining+=("$n")` keeps it in `wanted` because it is in flight rather
    #   than done, the next iteration hits the cap, latches the drain, and the
    #   launch loop is never entered again. `queued` is stuck at 1 forever --
    #   including after #148's PR merges and `reap_merged` disowns it. `owned`
    #   reaches 0; `queued` never does.
    #
    # That is #37's wedge re-created by #36's fix, in the one mode #37's fix does
    # not cover, and `--auto --max-prs N` was fine (`wanted` is empty there),
    # which is why the suite stayed green. `--until` and `--for` in list mode had
    # the same shape already, so this fixes all three rather than `--max-prs`
    # alone -- which is what makes "equivalent to the other two" true.
    # Found by the independent review.
    local queued=0
    if $drain_mode; then
      queued=0
    elif [ "${#wanted[@]}" -gt 0 ]; then
      queued="${#wanted[@]}"
    elif $auto; then
      # Counted from the lists already in hand rather than by asking `in_flight`
      # per issue: that made two API calls each, and a 200-issue backlog on a
      # 60-second poll is how you meet gh's secondary rate limit.
      # ...and its documented non-zero kept. Discarded, `queued` was empty and
      # `[ "" -eq 0 ]` wrote a bash error to stderr every poll during a `gh`
      # outage -- exactly when the log most needs to be readable. "Could not
      # tell" is not "nothing left": it keeps polling.
      queued="$(count_startable)" || queued=1
    fi
    if [ "$queued" -eq 0 ] && [ "${owned:-0}" -eq 0 ]; then
      if [ "${parked:-0}" -gt 0 ]; then
        # Named on the way out, every time, because a worktree nobody mentions
        # is one nobody releases.
        say "$parked worktree(s) are waiting for you rather than for an agent:"
        for n in $(ls "$OWNED_DIR" 2>/dev/null); do
          why="$(why_parked "$n")" || continue
          say "  #$n -- $why"
          say "    $(how_to_release "$n" "$(owned_path "$n")")"
        done
      fi
      if $drain_mode; then
        # NOT "everything in flight has landed" when something has not: the
        # parked worktrees named just above are exactly the work that did not
        # land, and signing off with the one thing that did not happen is how a
        # reader stops reading the lines that say what to do about it. Found by
        # the independent review.
        if [ "${parked:-0}" -gt 0 ]; then
          reason="${reason:-you stopped it}; everything else in flight has landed, and $parked worktree(s) are waiting for you"
        else
          reason="${reason:-you stopped it}; everything in flight has landed"
        fi
      elif $auto && $declined; then
        reason="the backlog has nothing startable left, and what it was given was declined"
      elif $auto; then
        reason="the backlog has nothing startable left"
      elif $declined; then
        reason="every issue it was given has landed or was declined"
      else
        reason="every issue it was given has landed"
      fi
      break
    fi
    sleep "$POLL_SECONDS"
  done

  say "fleet down: $reason"
  notify "fleet down" "$reason. $opened worktree(s) opened."
}

# Sourced by tests/test_fleet.sh, which exercises one function at a time against
# a stubbed runner. Executed, it dispatches as usual. (It said
# `tests/test_orca_fleet.sh` until the independent review of #1: that file was
# renamed with the runner seam and the sweep that fixed the sibling reference in
# `remove_worktree` passed over this one.)
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0

case "${1:-}" in
  run)    shift; cmd_run "$@" ;;
  status) cmd_status ;;
  stop)   shift; cmd_stop "${1:-}" ;;
  resume) cmd_resume ;;
  retry)  shift; cmd_retry "$@" ;;
  *)
    cat >&2 <<USAGE
usage: fleet.sh <command>

  run 11 12 13                       work exactly these issues
  run --auto                         keep taking \`ready\` issues, most-unblocking first
  run --auto --until 08:00           ...and stop then
  run --auto --for 6h --max-prs 5    ...or after that long, or that many
  status                             what is running, and what is next
  stop [--now]                       drain (or interrupt the agents too)
  resume                             clear the stop
  retry 44                           hand back an issue the time-box gave up on

Run it in a terminal the runner opens, so it is as visible as the work it starts:
  $(runner_dispatcher_hint)
USAGE
    exit 2 ;;
esac
