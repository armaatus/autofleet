#!/usr/bin/env bash
# Record that this exact commit has been reviewed locally.
#
# Writes `.autofleet/run/reviewed-<sha>` holding the findings. `.claude/hooks/guard.py`
# refuses `git push` and `gh pr create` from a fleet-owned worktree without it,
# so in the automatic flow a PR arrives already reviewed or it does not arrive.
# A worktree you opened yourself is never gated -- pushing a half-finished
# branch by hand is a normal thing to do.
#
# The marker is per-commit on purpose. Amend or add a commit and the review has
# to be re-run, because the thing that was reviewed is not the thing being
# pushed any more.
#
#   /code-review high                     # then paste or pipe the findings:
#   ./scripts/fleet/record-review.sh --stdin  < findings.md
#   ./scripts/fleet/record-review.sh findings.md
#   ./scripts/fleet/record-review.sh --none   # reviewed, nothing found
#
# It records what you give it. It cannot tell whether a review happened -- that
# is a checklist gate, not proof, and the PR body is where a human checks the
# findings are real.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
mkdir -p .autofleet/run

sha="$(git rev-parse HEAD)"
target=".autofleet/run/reviewed-$sha"

# AN EMPTY BODY IS REFUSED, and `--none` is the way to say "it ran, and found
# nothing".
#
# Without this, the bare form reads stdin, and an agent
# running it from a tool call gets EOF immediately. The marker is then written
# with nothing under its header, `guard.py` opens the push gate, and the pull
# request goes out claiming a review that produced no text at all. That is the
# same hole `self-review.sh` exits 5 to close, one file down, reachable by
# typing the command the docs tell you to type. Found by the local /code-review
# pass (armaatus/autofleet#51).
#
# ONE `case`, not two over the same value. The emptiness check lives in the arms
# that can be empty; `--none` is the arm that is allowed to be, because saying
# "it ran and found nothing" explicitly is a person's call and is exactly what
# the refusal below asks for.
# The same `case` as `not_blank` in self-review.sh, deliberately: this script does
# not source lib.sh, because it is the one a person runs by hand in a checkout
# where nothing else is set up. The 75 seconds is what must not drift.
#
# NOT the same function. That one takes a FILE and `cat`s it; this takes the
# string already in hand. A future dedupe that assumes otherwise breaks a caller
# silently, which is why the difference is written here rather than left to be
# noticed. Found by the local /mattpocock-skills:code-review pass.
refuse_empty() {
# `case`, NOT `[ -n "${body//[[:space:]]/}" ]`. That expansion builds a whole new
# string one character at a time, and bash 3.2 -- which is what macOS ships --
# takes SEVENTY-FIVE SECONDS over a 12KB findings file, measured on this branch
# while a run appeared to have wedged after both passes had already finished. It
# gets worse as the findings get longer, which is the wrong way round. `case`
# matches in place and stops at the first non-space.
  case "$1" in
    *[![:space:]]*) return 0 ;;
  esac
  echo "nothing to record: the findings are empty." >&2
  echo "A marker with no findings under it opens the push gate for a review" >&2
  echo "that produced no text. What you probably want, after a rebase:" >&2
  echo "  ./scripts/fleet/record-review.sh .autofleet/run/self-review.md" >&2
  echo "which is where ./scripts/fleet/self-review.sh leaves them. If a pass" >&2
  echo "really ran and found nothing, say that instead:" >&2
  echo "  ./scripts/fleet/record-review.sh --none" >&2
  exit 2
}
# THE BODY MAY NAME THE COMMIT IT DESCRIBES, and if it does, it has to be this
# one -- or the marker is a review of something else.
#
# `self-review.sh` stamps `<!-- self-review-head: <sha> -->` into the findings it
# writes, and every rebase remedy in the payload prints
# `record-review.sh .autofleet/run/self-review.md`. That file is deliberately
# kept across a FAILED run, so the sequence "pass on A, commit B, a pass times
# out, follow the printed remedy" stamped `reviewed-B` holding A's findings: the
# push gate open on a commit nothing read, reached by typing the command the
# docs tell you to type. That is the hole `self-review.sh` refuses to make
# itself, walked around from outside. Found by the independent review.
#
# A REBASE IS THE CASE THIS MUST NOT BREAK: same findings, new sha, and the
# remedy is correct. So it warns and records rather than refusing -- `--force`
# is not needed for the thing the docs tell you to do, and the warning is what
# a reader of the PR body has to reconcile. What it refuses is nothing; what it
# makes impossible is doing it SILENTLY.
warn_if_stale() {
  local named
  named="$(printf '%s\n' "$1" | sed -n 's/.*<!-- self-review-head: \([0-9a-f]\{7,40\}\) -->.*/\1/p' | tail -1)"
  [ -n "$named" ] || return 0
  case "$sha" in
    "$named"*) return 0 ;;
  esac
  echo "NOTE: these findings say they were produced on ${named:0:8}, and HEAD is" >&2
  echo "${sha:0:8}. That is right after a rebase -- same review, new sha -- and" >&2
  echo "WRONG if a later self-review failed and left the earlier one here. If you" >&2
  echo "have not read the findings against this commit, run the passes again:" >&2
  echo "  ./scripts/fleet/self-review.sh" >&2
}
write_marker() {
  refuse_empty "$1"
  warn_if_stale "$1"
  { printf 'reviewed %s\n\n' "$sha"; printf '%s\n' "$1"; } >"$target"
}
case "${1:-}" in
  --none)
    printf 'reviewed %s\nno findings\n' "$sha" >"$target" ;;
  --stdin|"")
    write_marker "$(cat)" ;;
  *)
    [ -f "$1" ] || { echo "no such file: $1" >&2; exit 2; }
    write_marker "$(cat "$1")" ;;
esac

echo "recorded: $target"
echo "  $(wc -l <"$target" | tr -d ' ') lines. Put these findings in the PR body too --"
echo "  this file is gitignored and the reviewer cannot see it."
