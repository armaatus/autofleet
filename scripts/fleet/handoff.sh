#!/usr/bin/env bash
# The note one attempt at an issue leaves for the next.
#
#   ./scripts/fleet/handoff.sh                   print this worktree's note
#   ./scripts/fleet/handoff.sh 42                print #42's
#   ./scripts/fleet/handoff.sh write 42 note.md  record it, replacing what was there
#   ./scripts/fleet/handoff.sh write 42 --stdin  ...from stdin
#
# WHY THIS EXISTS (armaatus/autofleet#55). One session covers the plan, the
# implementation, both self-review passes, the push, the PR and up to three
# review rounds, inside one AUTOFLEET_TIMEBOX and one context window. By round
# two that window still holds every file the implementation read, every approach
# it abandoned and every test run it triggered -- none of which is needed once
# the PR exists, because the plan is in the PR body, the code is in the diff and
# the findings are on GitHub. The other end of the same window is
# `enforce_timebox`: when the dispatcher interrupts a worktree, or `fleet.sh
# retry` hands an issue back, the next attempt began from the issue body alone
# and re-derived every decision the first one made, from the files, at full
# price.
#
# So this is docs/WORKFLOW.md's own principle -- each stage ends by committing an
# artifact, and the next stage begins by reading it -- applied to context rather
# than to code.
#
# WHAT GOES IN IT, and nothing else: the decisions taken and why, the files
# touched, what each review round said and how it was answered, and what is
# still open. Not the plan, which is in the PR body. Not the diff. Not a
# narrative of the session.
#
# WHERE IT LIVES. `.autofleet/run/handoff-<issue>.md`, beside the `reviewed-<sha>`
# markers record-review.sh writes, for the same reasons: gitignored, per
# worktree, and never shared. It survives a session restart INSIDE the worktree,
# which is the case that matters, and it DIES WITH THE WORKTREE. That is not a
# durability bug to be fixed later -- a note that outlived its worktree would be
# read by an attempt working from a different tree, saying files were touched
# that are not touched here. docs/CONFIGURATION.md says so in the same words.
#
# BOUNDED, or it becomes a second spec. AUTOFLEET_HANDOFF_MAX_WORDS is the cap
# and the script REFUSES over it rather than truncating: a note somebody is
# relying on, silently cut off at the sentence that said what is still open, is
# worse than one that was never written -- the reader cannot tell the difference
# between "nothing else was open" and "the rest did not fit".
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# BEFORE the cd, because a relative source path on the command line means what
# the person typing it meant -- `cd sub && ../scripts/fleet/handoff.sh write 42
# note.md` looked for `<repo>/note.md` and said there was no such file, while
# advertising that exact form in its own usage.
CALLER_PWD="$PWD"
cd "$REPO_ROOT"
# For AUTOFLEET_HANDOFF_MAX_WORDS, which is a knob a host project sets and not a
# constant this script owns. lib.sh is the route every other script takes to
# config.sh, and it is what validates the cap before anything here reads it.
. "$REPO_ROOT/scripts/fleet/lib.sh"

RUN_DIR="$REPO_ROOT/.autofleet/run"

usage() {
  cat >&2 <<'USAGE'
usage:
  handoff.sh                   print this worktree's note
  handoff.sh <issue>           print that issue's
  handoff.sh write <issue> FILE
  handoff.sh write <issue> --stdin

exits 2 on a reference that is not an issue, on a worktree holding more than one
note with no issue named, and on a source file that is not there. 3 when the
note is EMPTY -- the one an agent hits by accident, running the --stdin form
with nothing on stdin -- or over AUTOFLEET_HANDOFF_MAX_WORDS.

A relative FILE is resolved against the directory you ran this from, then
against the repo root.
USAGE
  # The caller decides the status: `usage 0` for an explicit `--help`, `usage 2`
  # for the misuse paths. A script the brief names by path is one a person runs
  # `--help` on, and a non-zero there trips whatever is wrapping it.
  exit "${1:-2}"
}

# The issue number, from the argument if there is one.
#
# It does NOT repeat issue-command.sh's three-way read of the runner, and that
# is deliberate rather than an oversight: every automatic caller -- the brief,
# which has `__ISSUE__` substituted, and fleet.sh, which is iterating issue
# numbers -- already knows the number and passes it. The only caller that does
# not is a person standing in the worktree typing the bare form, and a worktree
# holds one issue's note, so the glob answers them without a CLI call that can
# hang. Ambiguity is refused rather than guessed at.
#
# THREE ANSWERS, none of them an `exit`. This runs inside `$(...)` at every
# callsite, where `exit` ends the SUBSHELL and hands the caller a status it
# reads as "could not resolve" -- so the bare print form answered an ambiguous
# worktree with the refusal on stderr and exit 0, and `write` printed a second,
# different message over the first. The rc is what the caller branches on:
#
#   0  the number is on stdout
#   1  nothing to resolve: no argument, and no note in this worktree
#   2  a reference that is not an issue, or more than one note here. Said, once,
#      on stderr -- which is not captured by the substitution.
resolve_issue() {
  local ref="${1:-}" num found n=0 f
  if [ -n "$ref" ]; then
    num="$(fleet_issue_number "$ref")" \
      || { echo "handoff: could not resolve an issue from '$ref'" >&2; return 2; }
    printf '%s' "$num"
    return 0
  fi
  for f in "$RUN_DIR"/handoff-*.md; do
    [ -e "$f" ] || continue
    n=$((n + 1)); found="$f"
  done
  case "$n" in
    # No note is a normal state, and the caller decides what that means: the
    # print form says nothing and exits 0, `write` says it needs a number.
    0) return 1 ;;
    1) found="$(basename "$found" .md)"; printf '%s' "${found#handoff-}" ;;
    *) echo "handoff: this worktree holds $n notes; name the issue" >&2; return 2 ;;
  esac
}

# The cap, checked on the CANDIDATE and before the target is touched. Counting
# after the write would mean the refusal had already destroyed what it is
# refusing to replace -- which is the previous round's answer, and the one thing
# the note is for.
#
# 0 turns the cap off, the way AUTOFLEET_KEEP_REVIEWS=0 turns the sweep off.
# Documented, so an unbounded note is something a host asked for rather than
# something a mistyped value produced silently; config.sh refuses anything that
# is not a whole number for exactly that reason.
# ...and a note with nothing in it, which is the same refusal from the other end.
#
# `handoff.sh write <n> --stdin` is what the brief tells an agent to run, and an
# agent that runs it as a bare tool call gets EOF straight away: zero bytes, 0
# words, under any cap, and the `mv` lands over the round before it. The next
# session was then handed a "What the last attempt left" header with nothing
# under it -- which is exactly the "cannot tell 'nothing was open' from 'it did
# not fit'" failure the cap refuses rather than truncates for. Found by the
# local /code-review pass, which reproduced it.
refuse_if_empty() {
  local candidate="$1"
  [ -s "$candidate" ] && [ -n "$(tr -d '[:space:]' <"$candidate")" ] && return 0
  echo "handoff: that note is empty. Nothing was written -- the note that was" >&2
  echo "  already there is still there. If the note is on stdin, make sure it" >&2
  echo "  reaches this command; \`handoff.sh write <issue> <file>\` is the form" >&2
  echo "  that cannot arrive empty by accident." >&2
  return 1
}

refuse_if_over_cap() {
  local candidate="$1" cap="${AUTOFLEET_HANDOFF_MAX_WORDS}" words
  # `if`, not `[ ... ] && return 0`. `set -e` is on, and an AND-list whose left
  # half is false is the shape issue-command.sh already carries a comment about
  # having been bitten by; a guard that exits the script on the ordinary path is
  # not a guard.
  # `-eq`, not `= 0`. `00` is all digits, so config.sh accepts it, and it is not
  # the literal `0` -- a string compare reads it as a cap of "00", every note is
  # over it, and the off switch becomes "refuse everything". config.sh carries
  # the same story about AUTOFLEET_REVIEW_MAX_TRIES, where one spare zero made
  # the guard the failure.
  if [ "$cap" -eq 0 ]; then return 0; fi
  words="$(wc -w <"$candidate" | tr -d ' ')"
  if [ "$words" -le "$cap" ]; then return 0; fi
  # SHORT, and it does not re-list what the note holds. That definition is in
  # the brief and in docs/CONFIGURATION.md, and a third copy here is one more
  # place it can come to say something else. What a refusal owes the reader is
  # the two numbers and the two ways out.
  echo "handoff: that note is $words words and the cap is $cap. Nothing was" >&2
  echo "  written. Cut it, or raise AUTOFLEET_HANDOFF_MAX_WORDS in" >&2
  echo "  .autofleet/config deliberately." >&2
  # RETURN, not exit: the candidate is a temp file beside the note and the
  # caller is the only thing that knows to remove it. An `exit` here left one
  # `.handoff-<n>.XXXXXX` in `.autofleet/run/` for every refused write.
  return 1
}

cmd_write() {
  local num="$1" src="${2:-}" target tmp
  target="$(fleet_handoff_path "$REPO_ROOT" "$num")"
  mkdir -p "$RUN_DIR"
  # A temp file in the same directory, so the cap is measured on exactly the
  # bytes that would land and the landing itself is one `mv`. A reader that
  # opens the note while it is being replaced sees the old one or the new one,
  # never half of each.
  tmp="$(mktemp "$RUN_DIR/.handoff-$num.XXXXXX")"
  # ...and a trap, for the path neither refusal covers: a SIGNAL between here
  # and the `mv`. `enforce_timebox` interrupting a worktree is the case this
  # whole feature exists for, so an agent killed mid-write is not hypothetical,
  # and what it leaves is a `.handoff-<n>.XXXXXX` that `resolve_issue`'s
  # `handoff-*.md` glob cannot see and nothing sweeps. The earlier note here
  # said a trap "would have to survive the refusal's exit code"; it does not --
  # `trap ... EXIT` runs after the exit status is fixed and does not change it.
  # Cleared before the `mv` so it cannot remove the note it just landed. Found
  # by the independent review.
  trap 'rm -f "$tmp"' EXIT
  case "$src" in
    --stdin|"")
      # SAID when there is a person there. `handoff.sh write 42` with no source
      # is the stdin form, and on a terminal that is a script sitting silently
      # on a read nobody knows it is doing. Only on a tty: in the fleet the note
      # arrives on a pipe and a line on stderr is noise.
      [ -t 0 ] && echo "handoff: reading the note from stdin; end it with ^D" >&2
      cat >"$tmp" ;;
    *) case "$src" in
         /*) ;;
         # Relative to where the caller stood, then to the repo root -- the
         # second is what every other fleet script means by a relative path, and
         # dropping it would break `handoff.sh write 42 findings.md` run from
         # the root through a wrapper that had already cd'd.
         *) [ -f "$CALLER_PWD/$src" ] && src="$CALLER_PWD/$src" ;;
       esac
       [ -f "$src" ] || { rm -f "$tmp"; echo "handoff: no such file: $src" >&2; exit 2; }
       cat "$src" >"$tmp" ;;
  esac
  refuse_if_empty   "$tmp" || { rm -f "$tmp"; exit 3; }
  refuse_if_over_cap "$tmp" || { rm -f "$tmp"; exit 3; }
  # Below this line nothing may fail on the note's account: the cap is the only
  # refusal, and it has already been made.
  trap - EXIT
  mv "$tmp" "$target"
  echo "recorded: .autofleet/run/handoff-$num.md"
  echo "  $(wc -w <"$target" | tr -d ' ') words. It goes with this worktree --"
  echo "  a session that restarts here is given it; nothing outside reads it."
}

cmd_print() {
  local target; target="$(fleet_handoff_path "$REPO_ROOT" "$1")"
  [ -f "$target" ] || return 0
  cat "$target"
}

# The rc every dispatch below branches on. `set -e` is on, so the status has to
# be caught rather than left to kill the script on the ordinary "no note here"
# answer.
#
# NOT `resolve_or_die`, which was its name and which it is not: it dies only on
# rc 2, and hands rc 1 back so each caller can say the thing that fits -- "no
# note here yet, name the issue" for `write`, silence for the print form. A name
# that promises an exit the function does not always take is the one a reader
# stops checking. Found by the local /mattpocock-skills:code-review pass.
resolved=""
try_resolve() {
  local rc=0
  resolved="$(resolve_issue "${1:-}")" || rc=$?
  case "$rc" in
    0) return 0 ;;
    # Said already, by resolve_issue, in the words that fit the reason.
    2) exit 2 ;;
    *) return 1 ;;
  esac
}

case "${1:-}" in
  write)
    shift
    # The issue is optional and the source is optional, so which of the two the
    # first argument is has to be decided before either is read. A bare number
    # or an issue URL is the issue; anything else -- `--stdin`, `note.md`,
    # `42-notes.md` -- is the source, and the issue comes from the glob.
    # `write --stdin` with no number is the form an agent in a fleet worktree
    # types, and matching `$1` as the issue swallowed it as an unresolvable ref.
    ref=""
    case "${1:-}" in
      ''|*[!0-9]*) ;;
      *) ref="$1"; shift ;;
    esac
    # ...and only while the issue is still unknown, and only for something that
    # is actually a URL. Unguarded, this second case ran against the SOURCE
    # argument once the first had consumed the number: `handoff.sh write 42
    # docs/issues/7-notes.md` wrote an empty note under issue 7, left 42's
    # stale, and exited 0. Guarding on `$ref` alone still read the same path as
    # the ISSUE when the number was left off, so the file was never opened and
    # the command sat on stdin. `://` is what tells a URL from a path, and a
    # path is what this argument is for. Both found by review -- the first by
    # the local /code-review pass, the second by the independent one.
    if [ -z "$ref" ]; then
      case "${1:-}" in
        *://*/issues/[0-9]*) ref="$1"; shift ;;
      esac
    fi
    try_resolve "$ref" || {
      echo "handoff: this worktree holds no note yet, so name the issue --" >&2
      echo "  ./scripts/fleet/handoff.sh write <issue> [file|--stdin]" >&2
      exit 2; }
    cmd_write "$resolved" "${1:-}"
    ;;
  -h|--help|help) usage 0 ;;
  # The print form, which is also the no-argument form. Absent, it says nothing
  # and exits 0: no note is the ordinary state, and a reader that treated it as
  # an error would make every fresh worktree look broken.
  ''|*)
    try_resolve "${1:-}" || exit 0
    cmd_print "$resolved"
    ;;
esac
