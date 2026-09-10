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
  ps -o command= -p "$pid" 2>/dev/null | grep -q 'agent-autostart' || return 1
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
# $2 gets stdout only, unless FLEET_RUN_CAPTURE_STDERR=1 is set for the call --
# `VAR=1 fleet_run_with_deadline ...`, which bash scopes to that call alone.
#
# Off by default because most callers parse $2 as JSON, and a warning landing in
# it is a parse error. On for the ones that report a FAILURE: a CLI says why on
# stderr, so dropping it leaves "it failed" with nothing after it -- and "the
# app is not running" and "that worktree is gone" then look identical.
fleet_run_with_deadline() {
  local seconds="$1" out="$2"; shift 2
  if [ "${FLEET_RUN_CAPTURE_STDERR:-0}" = 1 ]; then
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

# The runner driver: everything about creating a worktree, opening a terminal
# in it, and asking the runtime what it is doing. `orca` is the only one that
# ships, and it is the WHOLE of the dependency -- nothing outside
# scripts/fleet/runner/ names it. See docs/RUNNERS.md for the contract a second
# one has to meet.
#
# Sourced here rather than by each script because every hook needs it and a
# hook that silently has no driver looks exactly like a hook whose driver
# answered "nothing".
if [ -f "$(dirname "${BASH_SOURCE[0]}")/runner/${AUTOFLEET_RUNNER}.sh" ]; then
  . "$(dirname "${BASH_SOURCE[0]}")/runner/${AUTOFLEET_RUNNER}.sh"
else
  echo "autofleet: no runner driver for AUTOFLEET_RUNNER=$AUTOFLEET_RUNNER" >&2
  return 1 2>/dev/null || exit 1
fi

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

# A file's mtime in epoch seconds, or nothing. BSD stat and GNU stat take
# different flags and neither is present everywhere, so both are tried -- this
# repo runs on macOS and its CI runs on Linux, and a helper that works on one is
# a helper that silently returns empty on the other.
fleet_mtime() {
  [ -e "${1:-}" ] || return 1
  stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null
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
# which holds only if it reads the PR after the change -- and the loop does two
# of these back to back, `resolve-thread.sh` then `answer-review.sh`. The second
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
