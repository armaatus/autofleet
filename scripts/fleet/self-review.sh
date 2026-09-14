#!/usr/bin/env bash
# The two mandatory self-review passes, run OUTSIDE the session that wrote the
# diff.
#
#   ./scripts/fleet/self-review.sh            # both passes; findings on stdout
#   ./scripts/fleet/self-review.sh <base-ref> # ...against an explicit base
#
# WHY THIS EXISTS. Step 3 of the brief used to say "run `/code-review high` and
# `/mattpocock-skills:code-review`", and the agent ran both inside its own
# session. Both read the whole diff and the files around it, and they did it at
# the worst possible moment: immediately before the phase that has to survive
# longest -- the push, the pull request, and up to three review rounds, all
# inside one AUTOFLEET_TIMEBOX and one context window. The findings are a page.
# Everything the passes read to produce them is not, and none of it is needed
# afterwards. armaatus/autofleet#51.
#
# So the passes move to where `review.sh` already puts the independent one: a
# separate process with a fixed tool allowlist, a turn budget and a wall clock,
# whose caller receives a verdict rather than a transcript.
#
# THIS IS THE FLEET'S PATH, NOT A BAN ON THE SLASH COMMANDS. A person in a
# worktree runs `/code-review` directly and always could, and
# `record-review.sh --stdin` is still there for the findings that come out of it.
#
# MODEL-AGNOSTIC IN EXACTLY THE WAY `review.sh` IS, which is to say: not yet.
# The flags below -- `-p`, `--allowed-tools`, `--max-turns`,
# `--append-system-prompt` -- are Claude Code's, and AUTOFLEET_SELF_REVIEW_CMD is
# advertised as a seam the way AUTOFLEET_REVIEW_CMD is. That gap is
# armaatus/autofleet#27, which is open against `review.sh`; this file is
# deliberately a SECOND consumer of the same shape rather than a third
# convention, so #27 fixes both at once. Do not invent a different spawn here.
#
# Exit codes, so a caller can tell the cases apart:
#   0  both passes produced findings, and the push marker is recorded
#   2  could not work out what to review, or .github/scripts/merge_gate.py does
#      not import, or record-review.sh refused the findings
#   3  the fleet is stopped
#   5  a pass ran and produced nothing -- named, and NOTHING recorded
#   6  AUTOFLEET_SELF_REVIEW_CMD is not on PATH
#   7  a pass ran past AUTOFLEET_SELF_REVIEW_TIMEOUT and was killed -- named,
#      and nothing recorded
#
# 5 and 7 are the ones this script exists to make loud. `review.sh` exit 5 is the
# precedent -- a reviewer that submitted nothing is a failure, not a clean review
# -- and here the stake is higher: recording an empty marker satisfies the push
# gate, and a pull request then goes out claiming two reviews that never ran.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
. ./scripts/fleet/lib.sh

# The stop is a stop. Nothing here goes out -- the marker is local and
# gitignored -- but `stop.sh --now` promises the agents are FROZEN, and starting
# two full-budget agents is the opposite of that.
fleet_stopped && { echo "STOPPED: $FLEET_STOP exists; no pass was started." >&2; exit 3; }

command -v "$AUTOFLEET_SELF_REVIEW_CMD" >/dev/null 2>&1 || {
  echo "AUTOFLEET_SELF_REVIEW_CMD is '$AUTOFLEET_SELF_REVIEW_CMD', which is not on PATH." >&2
  echo "Set it in .autofleet/config, or run the two passes by hand and use" >&2
  echo "  ./scripts/fleet/record-review.sh findings.md" >&2
  exit 6; }

# WHAT THE PASSES ARE POINTED AT, resolved here rather than left to each pass's
# own idea of "the current diff". A fleet worktree reaching this point has its
# work COMMITTED and a clean tree, so "the current diff" is empty and a pass
# given nothing else to go on reviews nothing and says so at length. The range
# is stated in the prompt instead, which works whatever argument grammar a
# particular skill has.
base="${1:-}"
if [ -z "$base" ]; then
  for candidate in "$(git rev-parse --abbrev-ref origin/HEAD 2>/dev/null)" origin/main main; do
    [ -n "$candidate" ] || continue
    git rev-parse --verify -q "$candidate" >/dev/null 2>&1 && { base="$candidate"; break; }
  done
fi
merge_base="$(git merge-base HEAD "$base" 2>/dev/null)" || merge_base=""
[ -n "$merge_base" ] || {
  echo "could not work out what this branch changed: no merge base with '${base:-origin/HEAD}'." >&2
  echo "Pass one: ./scripts/fleet/self-review.sh <base-ref>" >&2
  exit 2; }

sha="$(git rev-parse HEAD)"
mkdir -p .autofleet/run
LOG_DIR=".autofleet/run/self-review"
mkdir -p "$LOG_DIR"

# THE BAR FOR "PRODUCED NOTHING" IS ASKED OF `merge_gate.py`, not restated here.
#
# "Did a review actually happen, or is this a record with nothing in it" is the
# question that file already answers for review bodies -- MIN_REVIEW_BODY, added
# after PR #95 merged on a review whose entire body was the word "test". A second
# paraphrase of it drifts, always in the permissive direction, and the permissive
# direction here is a marker that satisfies the push gate for a pass that said
# nothing. One definition, asked in both places.
substantive() {
  python3 - "$1" <<'PY'
import sys
sys.path.insert(0, ".github/scripts")
try:
    from merge_gate import is_substantive
except Exception as exc:
    # Not ImportError alone: merge_gate.py is a file agents in this repo edit,
    # and a SyntaxError in it must not read as "this pass was silent".
    print(f"could not load .github/scripts/merge_gate.py ({exc})", file=sys.stderr)
    raise SystemExit(2)
raise SystemExit(0 if is_substantive({"body": open(sys.argv[1]).read()}) else 1)
PY
}

# A DEADLINE AND A PROCESS GROUP, the same shape as `review.sh` and for the same
# two reasons stated there: `timeout` is GNU coreutils and this repo runs on
# macOS, and AUTOFLEET_SELF_REVIEW_CMD is advertised as a WRAPPER seam, so
# signalling the direct child reaps the wrapper and orphans the agent it started.
# `set -m` gives the job its own process group; `kill -- -N` reaches everything
# in it.
#
# Not shared with `review.sh`: that copy also polls the dispatcher's stop file,
# refunds a try against AUTOFLEET_REVIEW_MAX_TRIES and drops a slot marker, none
# of which exist here. What IS shared is the reasoning, which is why this comment
# points at it rather than restating it.
run_pass() {
  local slug="$1" label="$2" prompt="$3"
  local out="$LOG_DIR/$slug-${sha:0:8}.md" err="$LOG_DIR/$slug-${sha:0:8}.log"

  echo "==> $label  (${AUTOFLEET_SELF_REVIEW_TIMEOUT}s, ${AUTOFLEET_SELF_REVIEW_MAX_TURNS} turns, $AUTOFLEET_SELF_REVIEW_CMD)" >&2
  set -m
  "$AUTOFLEET_SELF_REVIEW_CMD" -p "$prompt" \
    --allowed-tools "$TOOLS" \
    --max-turns "$AUTOFLEET_SELF_REVIEW_MAX_TURNS" \
    --append-system-prompt "$SYSTEM" \
    >"$out" 2>"$err" &
  local child=$! waited=0
  set +m

  # THE GROUP, then the bare pid for the case where job control was unavailable
  # and no group was created -- signalling a group that does not exist is an
  # error, not a kill.
  signal_pass() {
    kill "-$1" -- "-$child" 2>/dev/null || kill "-$1" "$child" 2>/dev/null
  }
  kill_pass() { signal_pass TERM; sleep 2; signal_pass KILL; }
  # An unexpected exit anywhere below must not leave a full-budget agent behind.
  trap 'kill_pass' EXIT
  trap 'kill_pass; exit 143' TERM INT

  while kill -0 "$child" 2>/dev/null; do
    if [ "$waited" -ge "$AUTOFLEET_SELF_REVIEW_TIMEOUT" ]; then
      kill_pass
      trap - EXIT TERM INT
      echo "$label ran past ${AUTOFLEET_SELF_REVIEW_TIMEOUT}s and was killed; see $err" >&2
      return 7
    fi
    # ...and the stop is RE-READ rather than read once at the top, because
    # `stop.sh --now` freezes the agents and one of them is this pass.
    if fleet_stopped; then
      kill_pass
      trap - EXIT TERM INT
      echo "STOPPED mid-pass: $FLEET_STOP appeared; $label was killed." >&2
      return 3
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$child"; local rc=$?
  trap - EXIT TERM INT

  substantive "$out"; local bar=$?
  case $bar in
    # THE HEADING IS LOAD-BEARING. `merge_gate.py` reads the pull request body
    # for the literal words `/code-review` and `mattpocock-skills:code-review`,
    # and what the agent pastes into that body is what this prints. Label the
    # sets and the gate is satisfied by the paste; leave them unlabelled and the
    # agent has to remember to write them, which is the step that gets forgotten.
    0) { printf '### %s\n\n' "$label"; cat "$out"; printf '\n\n'; } >>"$FINDINGS"
       return 0 ;;
    2) echo "Fix .github/scripts/merge_gate.py, then run this again." >&2; return 2 ;;
  esac
  echo "$label exited $rc and produced NO findings." >&2
  echo "A pass that says nothing is a failure, not a clean review: nothing was" >&2
  echo "recorded, so the push gate is still closed. Read $err, then run this" >&2
  echo "again or run the pass by hand." >&2
  return 5
}

# Read-only over the tree: these passes REPORT, they do not fix. That is the
# author's job, back in the session, with the findings in front of it -- which is
# the whole point of moving the reading out of there.
#
# `Skill`, `Task` and `Agent` because both passes ARE skills and both fan out
# into sub-agents of their own; without them each silently reviews with most of
# what it is for switched off. `gh issue view` because the second pass's
# spec-vs-diff axis has to read the issue the diff claims to close.
#
# NOT `Bash(gh api:*)`, and nothing that writes: the same reasoning
# `review.sh` spells out, with the extra point that this one runs INSIDE a
# fleet-owned worktree, where an agent that could edit files could edit
# `.claude/hooks/guard.py` on its way past.
TOOLS='Read,Grep,Glob,Skill,Task,Agent'
TOOLS="$TOOLS,Bash(git diff:*),Bash(git log:*),Bash(git show:*)"
TOOLS="$TOOLS,Bash(git status:*),Bash(git merge-base:*),Bash(git rev-parse:*)"
TOOLS="$TOOLS,Bash(gh issue view:*)"

# The range is in the SYSTEM prompt rather than appended to the slash command,
# because a slash command's arguments are whatever follows it on the line and
# these two passes do not share an argument grammar. Said once, it reaches both.
SYSTEM="You are one of two mandatory self-review passes the autofleet fleet runs
before a pull request is opened. The policy is REVIEW.md at the repository root;
read it.

The change under review is every commit on this branch since $merge_base --
\`git diff $merge_base...HEAD\` is its whole extent, and the working tree is
clean, so there is no uncommitted diff to look at.

REPORT ONLY. Do not edit, stage, commit, push or open anything: the author fixes
what you find, and you have no tools to do it with.

Your FINAL MESSAGE is the entirety of what the caller receives -- nothing else
you print is read. Put the findings there, in markdown, each naming the file and
line. Say so plainly if there are none. A pass whose final message is empty is
recorded as a FAILURE and the pull request does not go out."

# Both passes run even when the first one fails, because the caller is an agent
# on a time-box: one invocation that names both outcomes beats two rounds of
# fix-and-rerun discovering them one at a time. Nothing is recorded unless both
# succeeded -- the findings are built up in a file that is only handed to
# `record-review.sh` at the end.
#
# A STRING, not an array. macOS ships bash 3.2, where `${#arr[@]}` on an array
# that was never appended to is an unbound variable under `set -u` -- so the
# happy path works and the path that reports a failure dies with a different
# error than the one it was written to report.
FINDINGS=".autofleet/run/self-review-$sha.md"
: >"$FINDINGS"
failed=""
rc_worst=0

for pass in "code-review|/code-review high" "mattpocock|/mattpocock-skills:code-review"; do
  slug="${pass%%|*}"; label="${pass#*|}"
  run_pass "$slug" "$label" "$label"; rc=$?
  case $rc in
    0) ;;
    # A merge_gate.py that will not import is not a silent pass, and saying it
    # twice at the bottom would name the wrong failure. Out here, immediately.
    2) rm -f "$FINDINGS"; exit 2 ;;
    3) rm -f "$FINDINGS"; exit 3 ;;
    *) failed="${failed:+$failed, }$label"
       [ "$rc_worst" = 0 ] && rc_worst=$rc ;;
  esac
done

if [ -n "$failed" ]; then
  rm -f "$FINDINGS"
  echo >&2
  echo "NOT RECORDED. These passes produced nothing: $failed" >&2
  echo "The push gate is still closed, which is correct -- a pull request that" >&2
  echo "names two reviews must have had two." >&2
  exit "$rc_worst"
fi

./scripts/fleet/record-review.sh "$FINDINGS" >&2 || {
  echo "record-review.sh refused the findings; the push gate is still closed." >&2
  exit 2; }

cat "$FINDINGS"
