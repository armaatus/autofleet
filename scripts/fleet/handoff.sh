#!/usr/bin/env bash
# The note one attempt at an issue leaves for the next.
#
#   ./scripts/fleet/handoff.sh                   print this worktree's note
#   ./scripts/fleet/handoff.sh 42                print #42's
#   ./scripts/fleet/handoff.sh write 42 note.md  record it, replacing what was there
#   ./scripts/fleet/handoff.sh write 42 --stdin  ...from stdin
#   ./scripts/fleet/handoff.sh path 42           where it would be
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
  handoff.sh path <issue>      where it would be
USAGE
  exit 2
}

path_for() { printf '%s/handoff-%s.md' "$RUN_DIR" "$1"; }

# The issue number, from the argument if there is one.
#
# It does NOT repeat issue-command.sh's three-way read of the runner, and that
# is deliberate rather than an oversight: every automatic caller -- the brief,
# which has `__ISSUE__` substituted, and fleet.sh, which is iterating issue
# numbers -- already knows the number and passes it. The only caller that does
# not is a person standing in the worktree typing the bare form, and a worktree
# holds one issue's note, so the glob answers them without a CLI call that can
# hang. Ambiguity is refused rather than guessed at.
resolve_issue() {
  local ref="${1:-}" num
  if [ -n "$ref" ]; then
    num="$(printf '%s' "$ref" | sed -nE 's#.*/issues/([0-9]+).*#\1#p; s#^([0-9]+)$#\1#p' | head -1)"
    [ -n "$num" ] || { echo "handoff: could not resolve an issue from '$ref'" >&2; exit 2; }
    printf '%s' "$num"
    return 0
  fi
  local found n=0 f
  for f in "$RUN_DIR"/handoff-*.md; do
    [ -e "$f" ] || continue
    n=$((n + 1)); found="$f"
  done
  case "$n" in
    # No note is a normal state, and the caller decides what that means: the
    # print form says nothing and exits 0, `write` says it needs a number.
    0) return 1 ;;
    1) found="$(basename "$found" .md)"; printf '%s' "${found#handoff-}" ;;
    *) echo "handoff: this worktree holds $n notes; name the issue" >&2; exit 2 ;;
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
refuse_if_over_cap() {
  local candidate="$1" cap="${AUTOFLEET_HANDOFF_MAX_WORDS}" words
  # `if`, not `[ ... ] && return 0`. `set -e` is on, and an AND-list whose left
  # half is false is the shape issue-command.sh already carries a comment about
  # having been bitten by; a guard that exits the script on the ordinary path is
  # not a guard.
  if [ "$cap" = 0 ]; then return 0; fi
  words="$(wc -w <"$candidate" | tr -d ' ')"
  if [ "$words" -le "$cap" ]; then return 0; fi
  echo "handoff: that note is $words words and the cap is $cap." >&2
  echo "  Nothing was written. The note holds the decisions and why, the files" >&2
  echo "  touched, what each review round said and how it was answered, and what" >&2
  echo "  is still open -- not the plan, which is in the PR body, and not the" >&2
  echo "  diff. Cut it to $cap words, or raise AUTOFLEET_HANDOFF_MAX_WORDS in" >&2
  echo "  .autofleet/config deliberately." >&2
  # RETURN, not exit: the candidate is a temp file beside the note and the
  # caller is the only thing that knows to remove it. An `exit` here left one
  # `.handoff-<n>.XXXXXX` in `.autofleet/run/` for every refused write.
  return 1
}

cmd_write() {
  local num="$1" src="${2:-}" target tmp
  target="$(path_for "$num")"
  mkdir -p "$RUN_DIR"
  # A temp file in the same directory, so the cap is measured on exactly the
  # bytes that would land and the landing itself is one `mv`. A reader that
  # opens the note while it is being replaced sees the old one or the new one,
  # never half of each.
  tmp="$(mktemp "$RUN_DIR/.handoff-$num.XXXXXX")"
  # No trap: `set -e` is on and the only exit before the `mv` is the refusal
  # below, which removes this itself. A trap here would also have to survive the
  # refusal's exit code, which is the thing the caller reads.
  case "$src" in
    --stdin|"") cat >"$tmp" ;;
    *) [ -f "$src" ] || { rm -f "$tmp"; echo "handoff: no such file: $src" >&2; exit 2; }
       cat "$src" >"$tmp" ;;
  esac
  refuse_if_over_cap "$tmp" || { rm -f "$tmp"; exit 3; }
  # Below this line nothing may fail on the note's account: the cap is the only
  # refusal, and it has already been made.
  mv "$tmp" "$target"
  echo "recorded: .autofleet/run/handoff-$num.md"
  echo "  $(wc -w <"$target" | tr -d ' ') words. It goes with this worktree --"
  echo "  a session that restarts here is given it; nothing outside reads it."
}

cmd_print() {
  local target; target="$(path_for "$1")"
  [ -f "$target" ] || return 0
  cat "$target"
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
    case "${1:-}" in
      */issues/[0-9]*) ref="$1"; shift ;;
    esac
    num="$(resolve_issue "$ref")" || {
      echo "handoff: this worktree holds no note yet, so name the issue --" >&2
      echo "  ./scripts/fleet/handoff.sh write <issue> [file|--stdin]" >&2
      exit 2; }
    cmd_write "$num" "${1:-}"
    ;;
  path)
    shift
    num="$(resolve_issue "${1:-}")" || { echo "handoff: name the issue" >&2; exit 2; }
    path_for "$num"
    ;;
  -h|--help|help) usage ;;
  # The print form, which is also the no-argument form. Absent, it says nothing
  # and exits 0: no note is the ordinary state, and a reader that treated it as
  # an error would make every fresh worktree look broken.
  ''|*)
    num="$(resolve_issue "${1:-}")" || exit 0
    cmd_print "$num"
    ;;
esac
