#!/usr/bin/env bash
# The headless runner: a plain `git worktree` and one non-interactive
# `claude -p` per build. No app, no terminal, no tab, nothing that can sit
# waiting for input.
#
# This is the default driver (scripts/fleet/config.sh) and the one CI runs. It
# needs `git`, `gh` and the build command on PATH and nothing else, which is the
# whole point of armaatus/autofleet#151: the fleet had never run anywhere but
# one macOS desk because the runtime it drove only exists there.
#
# WHAT IT REPLACED, so the shape below reads as a decision rather than a
# reduction. The interactive runner needed five subsystems to keep one session
# alive -- an autostart watcher that pressed Return on a drafted prompt, a
# "waiting for input" detector, a time-box that interrupted with a turn, a
# context recycle, and a handoff note the agent wrote before being cleared.
# Every one of them existed because a session that is never allowed to END has
# to be managed. `claude -p` ends: at the PR, at `--max-turns`, or at
# `--max-budget-usd`. The branch and the PR are the state, so a resume is a
# second `claude -p` in the same worktree and there is nothing to hand off.
#
# WHERE THE STATE LIVES. Under `$(fleet_build_dir <issue>)`, NOT inside the
# worktree: `self-review.sh` refuses a dirty tree, and a build log written next
# to the code is either a dirty tree or a .gitignore entry every host repo would
# have to vendor. It also has to outlive the worktree -- `cost.sh` reports on
# issues whose worktree was removed hours ago.

# The per-call deadline, for the git and gh calls below.
#
# Not for the BUILD: a build runs for hours and is not a call anyone waits on.
# `runner_build_start` returns as soon as the child is spawned, and
# `runner_build_state` answers from a pid file, so neither of them can block.
# That is the contract's "every call has a deadline" honoured by having no call
# that could take one.
runner_set_deadline() { HEADLESS_DEADLINE="$1"; }
: "${HEADLESS_DEADLINE:=60}"

# Where worktrees are created. One directory per repository leaf, so two host
# projects on one machine do not collide, and under $FLEET_DIR rather than
# beside the checkout because a sibling directory full of worktrees is a thing
# people commit by accident.
headless_tree_root() {
  printf '%s\n' "${AUTOFLEET_WORKTREE_ROOT:-$FLEET_DIR/trees}"
}

# THE ISSUE A WORKTREE BELONGS TO, kept by the driver.
#
# docs/RUNNERS.md names this as one of the two things a git-worktree driver has
# to answer for itself: the app-backed runner recorded the issue on the worktree
# object, and git has nowhere to put it. Not `git config --worktree` -- that
# needs `extensions.worktreeConfig`, which is a repository-wide flag this driver
# would be turning on in somebody else's repo. Not a file inside the worktree:
# see the header on why nothing is written in there.
#
# So: one file per worktree, named by the path with `/` folded to `%`, holding
# the issue number. `%` because it cannot appear in a path component that git
# would accept as a branch name and, unlike a hash, the directory is readable
# when something has gone wrong.
headless_link_dir() { printf '%s\n' "$FLEET_DIR/headless/links"; }
headless_link_file() {
  printf '%s/%s\n' "$(headless_link_dir)" "$(printf '%s' "$1" | tr '/' '%')"
}

# Is this driver usable at all, and SAY WHY when it is not.
#
# All three are named in one line rather than stopping at the first, because the
# person reading it is setting a machine up and "install gh" followed by
# "install claude" is two round trips for one answer. The contract requires the
# reason on stderr; `runner_available` returning 1 in silence is the failure
# mode docs/RUNNERS.md's `orca_unavailable_says` exists to prevent.
runner_available() {
  local missing=""
  local build; build="$(fleet_build_cmd)"
  for tool in git gh "$build"; do
    command -v "$tool" >/dev/null 2>&1 || missing="${missing:+$missing, }$tool"
  done
  [ -z "$missing" ] && return 0
  echo "headless: not on PATH: $missing" >&2
  return 1
}

runner_dispatcher_hint() {
  printf 'run `./scripts/fleet/fleet.sh run --auto` in a terminal, or under nohup\n'
}

# Create the worktree. Prints its path on success, the reason on STDOUT on
# failure -- stdout because `launch` captures stdout only, and a reason on
# stderr never reaches fleet.log. Same rule as the app-backed driver, and the
# same reason: "could not create it" with nothing after it reads identically
# whether the branch already exists or the disk is full.
runner_worktree_create() {
  local repo="$1" name="$2" issue="$3"
  local root path out rc
  root="$(headless_tree_root)/$(basename "$repo")"
  path="$root/$name"
  mkdir -p "$root" "$(headless_link_dir)" || { echo "could not create $root"; return 1; }
  [ -e "$path" ] && { echo "$path already exists"; return 1; }
  out="$(mktemp)"
  # `git worktree add -b` from the repo's default branch's remote tip rather
  # than from whatever HEAD happens to be: the dispatcher runs for hours and a
  # build that branched off a stale local main re-does merged work. The fetch is
  # inside the deadline with everything else.
  FLEET_RUN_CAPTURE_STDERR=1 fleet_run_with_deadline "$HEADLESS_DEADLINE" "$out" \
    git -C "$repo" worktree add -b "$name" "$path" HEAD
  rc=$?
  if [ "$rc" -ne 0 ]; then
    # AT MOST THREE LINES of the runtime's own words -- the driver's bound, not
    # the caller's, so a verbose git cannot flood fleet.log.
    head -3 "$out"; rm -f "$out"; return 1
  fi
  rm -f "$out"
  printf '%s\n' "$issue" >"$(headless_link_file "$path")"
  printf '%s\n' "$path"
}

# `path<TAB>branch<TAB>issue` for every worktree of THIS repository.
#
# SCOPED to the repo, like the app-backed driver's listing, for the reason
# recorded there: a machine-wide listing put a foreign worktree in `live`, and
# the foundation hold then waited on an issue number that does not exist here.
# `git worktree list` is already repo-scoped, which is one whole class of bug
# this driver does not have.
runner_worktree_list() {
  local out rc; out="$(mktemp)"
  fleet_run_with_deadline "$HEADLESS_DEADLINE" "$out" \
    git -C "$REPO_ROOT" worktree list --porcelain
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "headless: could not list worktrees in $REPO_ROOT" >&2
    rm -f "$out"; return 1
  fi
  # The main worktree is skipped: the fleet owns the ones it opened, and the
  # checkout the dispatcher itself runs in is not one of them.
  local main; main="$(git -C "$REPO_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  main="${main%/.git}"
  local path="" branch=""
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        path="${line#worktree }"; branch="" ;;
      "branch "*)
        branch="${line#branch }"; branch="${branch#refs/heads/}" ;;
      "")
        headless_emit_row "$path" "$branch" "$main"; path=""; branch="" ;;
    esac
  done <"$out"
  headless_emit_row "$path" "$branch" "$main"
  rm -f "$out"
}

headless_emit_row() {
  local path="$1" branch="$2" main="$3" issue
  [ -n "$path" ] || return 0
  [ "$path" = "$main" ] && return 0
  issue="$(cat "$(headless_link_file "$path")" 2>/dev/null)"
  printf '%s\t%s\t%s\n' "$path" "${branch:--}" "${issue:--}"
}

# THIS worktree's linked issue. Three answers, and the middle one is why this is
# not a boolean: 0 with the number, 2 for "this worktree has no linked issue",
# 1 for "could not tell". A caller that reads 1 as 2 announces that a worktree
# the fleet linked has none, which is how a provisioned worktree sat idle.
runner_worktree_issue() {
  local top issue
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
  issue="$(cat "$(headless_link_file "$top")" 2>/dev/null)" || return 2
  [ -n "$issue" ] || return 2
  printf '%s\n' "$issue"
}

# The app-backed driver writes a card; there is no card here. A no-op that
# SUCCEEDS is the honest answer -- the contract's callers use this to show a
# person what is happening, and failing it would make the dispatcher log a
# problem that does not exist.
runner_worktree_set() { return 0; }

# Remove the worktree. Three answers, per the contract: 0 gone, 1 the runtime
# refused, 2 the runtime could not be reached at all. There is no runtime here,
# so 2 is unreachable and that is stated rather than left to be inferred.
runner_worktree_remove() {
  local path="$1" deadline="${2:-$HEADLESS_DEADLINE}" out rc
  # The build first: `git worktree remove` on a tree a `claude -p` is still
  # writing to races the agent, and the loser is the worktree.
  runner_build_stop "$path"
  out="$(mktemp)"
  FLEET_RUN_CAPTURE_STDERR=1 fleet_run_with_deadline "$deadline" "$out" \
    git -C "$REPO_ROOT" worktree remove --force "$path"
  rc=$?
  if [ "$rc" -ne 0 ] && [ -e "$path" ]; then
    head -3 "$out" >&2; rm -f "$out"; return 1
  fi
  rm -f "$out" "$(headless_link_file "$path")"
  git -C "$REPO_ROOT" worktree prune >/dev/null 2>&1
  return 0
}

# ------------------------------------------------------------------ the build

# Start the build in $1 for issue $2, and return as soon as it is running.
#
# `set -m` before the spawn, so the child gets its own PROCESS GROUP: the build
# command is advertised as a wrapper seam (AUTOFLEET_BUILD_CMD), so the process
# actually holding the credentials is routinely a CHILD of what we forked, and
# signalling the direct child orphans a full-budget run nobody is counting.
# Same shape, same reason, as review.sh and self-review.sh -- see
# `fleet_kill_group` in lib.sh.
runner_build_start() {
  local path="$1" issue="$2" dir
  dir="$(fleet_build_dir "$issue")"
  mkdir -p "$dir" || return 1
  [ -r "$dir/prompt" ] && [ -r "$dir/system.md" ] || {
    echo "headless: no prompt for #$issue in $dir" >&2; return 1; }

  # Already running is SUCCESS, not an error: the dispatcher calls this to make
  # sure a build is up, and a second `claude -p` in one worktree is two agents
  # editing one tree.
  runner_build_state "$path" | grep -qx running && return 0

  # The result is written fresh on every start, so `runner_build_state` can
  # never report the PREVIOUS run's exit as this one's.
  rm -f "$dir/result.json" "$dir/rc"

  local line; line="$(fleet_build_command_line "$dir")"
  set -m
  (
    cd "$path" || exit 127
    # The line itself writes result.json and build.log -- see
    # `fleet_build_command_line`. Stdout is discarded HERE and nowhere else:
    # the app-backed driver runs the same line in a terminal, where that same
    # stdout is what the maintainer watches.
    bash -c "$line" >/dev/null
    printf '%s\n' "$?" >"$dir/rc"
  ) &
  local pid=$!
  set +m
  printf '%s\n' "$pid" >"$dir/pid"
  printf '%s\n' "$path" >"$dir/worktree"
  return 0
}

# `running`, or `exited <rc>`, on stdout. Non-zero when it could not be told
# apart from a build that was never started -- which is a different answer from
# "not running", and conflating them is how a dispatcher waits out its whole
# time-box and then reports that nothing arrived.
runner_build_state() {
  local path="$1" dir issue pid
  issue="$(cat "$(headless_link_file "$path")" 2>/dev/null)" || return 1
  [ -n "$issue" ] || return 1
  dir="$(fleet_build_dir "$issue")"
  pid="$(cat "$dir/pid" 2>/dev/null)" || return 1
  [ -n "$pid" ] || return 1
  if kill -0 "$pid" 2>/dev/null; then printf 'running\n'; return 0; fi
  printf 'exited %s\n' "$(cat "$dir/rc" 2>/dev/null || echo '?')"
}

# Stop the build in $1, if there is one. Idempotent, and silent about a build
# that is already gone: every caller reaches here on a path where the worktree
# is going away regardless.
runner_build_stop() {
  local path="$1" dir issue pid
  issue="$(cat "$(headless_link_file "$path")" 2>/dev/null)" || return 0
  [ -n "$issue" ] || return 0
  dir="$(fleet_build_dir "$issue")"
  pid="$(cat "$dir/pid" 2>/dev/null)" || return 0
  [ -n "$pid" ] || return 0
  kill -0 "$pid" 2>/dev/null || return 0
  fleet_kill_group "$pid"
  return 0
}
