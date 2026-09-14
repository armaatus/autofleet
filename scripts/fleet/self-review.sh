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
# WHAT WAS TRIED, because armaatus/autofleet#51 asks for it in writing. The
# issue records two spellings that produced NOTHING on this machine -- exit 0
# with 446 bytes of output, all of it permission warnings about
# `.claude/settings.json`:
#
#     claude -p "/code-review high" --allowed-tools "..." --max-turns 80
#     claude -p "/code-review high" --max-turns 80
#
# The spelling below does produce a review, and three things are load-bearing in
# it. STDOUT AND STDERR GO TO DIFFERENT FILES: the 446 bytes were on stderr, and
# merging the two streams is what made a working run look like a silent one. THE
# COMMIT RANGE IS STATED: a fleet worktree reaching step 3 has its work
# committed and a clean tree, so "the current diff" is empty and the pass
# reviews nothing -- and #51 also records a run that derived the diff from the
# WORKING DIRECTORY and reviewed a different repository's last commit, which is
# why this pins the repo with `cd "$REPO_ROOT"` before the spawn. AND THE PASS
# IS MADE TO DECLARE ITSELF: it must end with a findings trailer, which is the
# only thing here that can tell a review from a page of warnings.
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
#   2  could not work out what to review, the tree is dirty, or
#      record-review.sh refused the findings
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

# A DIRTY TREE IS REFUSED RATHER THAN REVIEWED. The marker `record-review.sh`
# writes is keyed on HEAD, and what `git push` sends is HEAD -- so uncommitted
# work is neither reviewed nor pushed, and a pass told "the tree is clean" while
# it is not has been lied to about the one thing it cannot check cheaply. Commit
# first; that is also what makes the per-commit marker mean what it says.
# Found by the local /code-review pass.
dirty="$(git status --porcelain 2>/dev/null)"
[ -z "$dirty" ] || {
  echo "the working tree is not clean, so the passes would review a commit that" >&2
  echo "is not what you are about to push. Commit first, then run this again:" >&2
  printf '%s\n' "$dirty" | sed -n '1,10p' >&2
  exit 2; }

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

# THE BAR FOR "PRODUCED NOTHING": a trailer the pass has to write, and a body
# besides it.
#
# The first version of this asked `merge_gate.py` whether the output cleared
# MIN_REVIEW_BODY, on the argument that "did a review actually happen" is a
# question that file already answers. Both self-review passes said that is the
# wrong bar here, in two directions. Too PERMISSIVE: forty characters of
# anything clears it, and #51's own record of this failure is 446 bytes of
# permission warnings -- a length test cannot tell a review from noise. Too
# STRICT: a pass that honestly found nothing writes `No findings.`, which is
# twelve characters, so the one clean diff in the backlog could never be pushed.
#
# A TRAILER separates the two, and it is the shape REVIEW.md already uses on the
# independent review for exactly this reason: only a pass that ran to a verdict
# writes one. The body check underneath it stops a pass answering with the
# trailer alone.
TRAILER='<!-- self-review-findings:'
declared() {
  grep -qF -- "$TRAILER" "$1" || return 1
  # Non-blank once the trailer lines are taken out. `grep -c .` rather than a
  # pipe into `grep -q`: `-q` exits on the first match, the producer dies of
  # EPIPE, and with `pipefail` a check that HELD reports as failed -- on large
  # input only, so it is green here and red in CI. CLAUDE.md carries the rule.
  local rest
  rest="$(grep -vF -- "$TRAILER" "$1")"
  [ -n "${rest//[[:space:]]/}" ]
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
  # The slash command IS the prompt -- one argument, not two. A third parameter
  # that was always equal to the second is a seam with nothing behind it, and
  # the next caller gets to pass them differently. Found by the local
  # /mattpocock-skills:code-review pass.
  local slug="$1" label="$2"
  local out="$LOG_DIR/$slug-${sha:0:8}.md" err="$LOG_DIR/$slug-${sha:0:8}.log"

  echo "==> $label  (${AUTOFLEET_SELF_REVIEW_TIMEOUT}s, ${AUTOFLEET_SELF_REVIEW_MAX_TURNS} turns, $AUTOFLEET_SELF_REVIEW_CMD)" >&2
  set -m
  "$AUTOFLEET_SELF_REVIEW_CMD" -p "$label" \
    --allowed-tools "$TOOLS" \
    --max-turns "$AUTOFLEET_SELF_REVIEW_MAX_TURNS" \
    --append-system-prompt "$SYSTEM" \
    >"$out" 2>"$err" &
  local child=$! waited=0
  set +m

  # THE GROUP, then the bare pid, then a grace period before the KILL -- all of
  # it in `fleet_kill_group`, which `review.sh` uses for the same wrapper-seam
  # reason. lib.sh carries the reasoning.
  kill_pass() { fleet_kill_group "$child"; }
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

  # THE EXIT STATUS IS PART OF THE ANSWER, and leaving it out was the bug this
  # whole script exists to prevent, reintroduced one level down: a pass that
  # crashed, or ran out of `--max-turns`, having printed enough text to look like
  # a review was recorded as one. Both conditions, or nothing is recorded.
  # Found by the local /mattpocock-skills:code-review pass.
  if [ "$rc" = 0 ] && declared "$out"; then
    # THE HEADING IS LOAD-BEARING. `merge_gate.py` reads the pull request body
    # for the literal words `/code-review` and `mattpocock-skills:code-review`,
    # and what the agent pastes into that body is what this prints. Label the
    # sets and the gate is satisfied by the paste; leave them unlabelled and the
    # agent has to remember to write them, which is the step that gets forgotten.
    { printf '### %s\n\n' "$label"; cat "$out"; printf '\n\n'; } >>"$FINDINGS"
    return 0
  fi
  echo "$label exited $rc and left NO findings this can use." >&2
  echo "A pass that says nothing is a failure, not a clean review: nothing was" >&2
  echo "recorded, so the push gate is still closed. What it wrote is in" >&2
  echo "  $out   (its findings)" >&2
  echo "  $err   (why it stopped)" >&2
  echo "Run this again, or run the pass by hand and record what it found with" >&2
  echo "  ./scripts/fleet/record-review.sh findings.md" >&2
  echo "  ./scripts/fleet/record-review.sh --none   # it ran, and found nothing" >&2
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
line, and END IT with this line, verbatim, with the count filled in:

<!-- self-review-findings: N -->

That line is what tells the caller a pass RAN. Without it the run is recorded as
a FAILURE and the pull request does not go out -- so write it even when N is 0,
and when it is 0 say in a sentence what you checked, so the author can tell a
clean diff from a pass that gave up."

# Both passes run even when the first one fails, because the caller is an agent
# on a time-box: one invocation that names both outcomes beats two rounds of
# fix-and-rerun discovering them one at a time. Nothing is recorded unless both
# succeeded -- the findings are built up in a file that is only handed to
# `record-review.sh` at the end.
#
FINDINGS=".autofleet/run/self-review-$sha.md"
: >"$FINDINGS"
# `failed` IS A STRING, NOT AN ARRAY. macOS ships bash 3.2, where `${#arr[@]}`
# on an array that was never appended to is an unbound variable under `set -u`
# -- so the happy path works and the path that REPORTS a failure dies with a
# different error than the one it was written to report.
failed=""
# The FIRST non-zero, which is not the same as the worst and is not claimed to
# be: the exits are kinds, not severities, and 5 after a 7 is not milder. The
# name said `worst` and the code kept the first. Found by the local
# /mattpocock-skills:code-review pass.
rc_first=0

for pass in "code-review|/code-review high" "mattpocock|/mattpocock-skills:code-review"; do
  slug="${pass%%|*}"; label="${pass#*|}"
  run_pass "$slug" "$label"; rc=$?
  case $rc in
    0) ;;
    # A stop is not a silent pass, and saying so at the bottom would name the
    # wrong failure. Out here, immediately.
    3) rm -f "$FINDINGS"; exit 3 ;;
    *) failed="${failed:+$failed, }$label"
       [ "$rc_first" = 0 ] && rc_first=$rc ;;
  esac
done

if [ -n "$failed" ]; then
  rm -f "$FINDINGS"
  echo >&2
  echo "NOT RECORDED. These passes left no findings this can use: $failed" >&2
  echo "The push gate is still closed, which is correct -- a pull request that" >&2
  echo "names two reviews must have had two." >&2
  exit "$rc_first"
fi

./scripts/fleet/record-review.sh "$FINDINGS" >&2 || {
  echo "record-review.sh refused the findings; the push gate is still closed." >&2
  exit 2; }

cat "$FINDINGS"
