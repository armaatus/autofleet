#!/usr/bin/env bash
# Covers the ceilings table at the top of evals/lint.sh -- armaatus/autofleet#56.
#
#   test_ceilings.sh over        a tree driven OVER a ceiling fails the lint, and
#                                the failure names the four things an agent needs
#                                to act on it: what was measured, the limit, the
#                                figure, and where the limit is changed. Without
#                                this row the whole table is a number nobody has
#                                ever seen refuse anything -- which is how a
#                                ceiling stops holding without going red.
#   test_ceilings.sh wellformed  ...and the table's own rules: a row with no
#                                issue, a row measured by a phase that does not
#                                run, and a row nothing reads. Each is a ceiling
#                                that would sit in the table looking enforced.
#
# The lint is run against a THROWAWAY TREE rather than this one, because what is
# asserted is a failure and the repository has to stay green. The tree is this
# repository with everything symlinked except the file under test, so the lint
# under test is the shipped one and not a paraphrase of it.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

. "$REPO_ROOT/tests/ceiling.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok: $*"; }

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; return 0; }
trap cleanup EXIT

# A tree the lint will read as this repository.
#
# Every top-level entry is a SYMLINK to the real one, so nothing is copied that
# the phase does not mean to change and a payload that grows a file stays
# covered without this fixture knowing about it. `.git` is left out: the lint
# does not read it, and linking it would let a bloated fixture look like a dirty
# working tree to anything that did.
#
# evals/ is copied rather than linked, because the `wellformed` rows edit the
# table itself -- and a symlinked directory would put those edits in the real
# file. That is the one mistake this fixture must not be able to make.
mk_tree() {
  local dst="$1" entry base
  mkdir -p "$dst"
  for entry in "$REPO_ROOT"/* "$REPO_ROOT"/.[!.]*; do
    [ -e "$entry" ] || continue
    base="$(basename "$entry")"
    [ "$base" = ".git" ] && continue
    # A symlink is recreated with the SAME target, not pointed at the original.
    # AGENTS.md -> CLAUDE.md is asserted by the lint, and a link to the real
    # AGENTS.md reads back as an absolute path into this repository -- so the
    # fixture failed a check that has nothing to do with any ceiling, and every
    # row below would then have been measuring that failure.
    if [ -L "$entry" ]; then
      ln -s "$(readlink "$entry")" "$dst/$base"
    else
      ln -s "$entry" "$dst/$base"
    fi
  done
  rm -f "$dst/evals"
  cp -R "$REPO_ROOT/evals" "$dst/evals"
}

# The lint, in that tree. `cd` into the tree rather than passing a path: the
# script derives its own root from `BASH_SOURCE` and then `cd`s there.
lint_in() { (cd "$1" && ./evals/lint.sh 2>&1); }

# The fixture has to be GREEN before it is broken, or a row below proves nothing:
# a lint that was already failing for an unrelated reason fails again afterwards
# and every assertion here passes on the wrong failure.
assert_green() {
  local out; out="$(lint_in "$1")"; local rc=$?
  [ "$rc" = 0 ] || { echo "$out" >&2; fail "the fixture tree is not green before it is broken (rc=$rc), so nothing below is measuring what it claims"; }
}

# The four things armaatus/autofleet#56's acceptance asks every ceiling failure
# to name. Asserted together, because three of four is a message an agent cannot
# act on and it is the fourth that is always the one dropped.
says_all_four() {
  local what="$1" out="$2" measured="$3" limit="$4" figure="$5"
  grep -qF -- "$measured" <<<"$out" \
    || { echo "$out" >&2; fail "$what does not say WHAT was measured (looked for '$measured')"; }
  grep -qF -- "$limit" <<<"$out" \
    || { echo "$out" >&2; fail "$what does not name the limit ($limit)"; }
  grep -qF -- "$figure" <<<"$out" \
    || { echo "$out" >&2; fail "$what does not say what the figure actually was ($figure)"; }
  grep -qF -- "ceilings table at the top of evals/lint.sh" <<<"$out" \
    || { echo "$out" >&2; fail "$what does not say where the limit is changed, so the remedy is a hunt"; }
}

# One row of the table, rewritten in the fixture's copy of the lint.
set_row() {
  local tree="$1" name="$2" row="$3"
  python3 - "$tree/evals/lint.sh" "$name" "$row" <<'PY'
import sys
path, name, row = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(path).read().splitlines(True)
for i, line in enumerate(lines):
    if line.startswith(name + "|"):
        lines[i] = row + "\n"
        break
else:
    sys.exit(f"no `{name}` row in the fixture's ceilings table; this phase would assert nothing")
open(path, "w").writelines(lines)
PY
}

case "${1:-}" in
# ------------------------------------------------------------------- over
  over)
  WORK="$(mktemp -d)"; WORK="$(cd "$WORK" && pwd -P)"
  mk_tree "$WORK/tree"
  assert_green "$WORK/tree"

  # The `reading` row: a required document grows, and the sum of what an agent
  # is told to read before its first edit goes over. This is the exact shape the
  # whole issue is about -- REVIEW.md is 1,300-odd words and every one of them
  # arrived as a useful paragraph -- so it is the row driven with real text
  # rather than with a synthetic file.
  limit="$(ceiling reading)"
  rm -f "$WORK/tree/REVIEW.md"
  cp "$REPO_ROOT/REVIEW.md" "$WORK/tree/REVIEW.md"
  before="$(wc -w <"$WORK/tree/REVIEW.md" | tr -d ' ')"
  awk -v n=200 'BEGIN { for (i = 0; i < n; i++) printf "word " }' >>"$WORK/tree/REVIEW.md"
  out="$(lint_in "$WORK/tree")"; rc=$?
  [ "$rc" = 0 ] && { echo "$out" >&2; fail "200 words added to a required document did not fail the lint; the reading ceiling is not holding"; }
  says_all_four "the reading ceiling's failure" "$out" \
    "before its first edit" "$limit" "$((before + 200))"
  ok "a required document grown past the reading ceiling fails the lint, and the failure says all four things"

  # ...and the row is the thing that decides it: raise the ceiling in the table
  # and the same tree is green again. That is the whole design -- a ceiling that
  # cannot be raised gets deleted the first time it is inconvenient -- and
  # without this row the phase above would also pass against a check that had
  # simply hardcoded a smaller number somewhere else.
  raised=$((limit + 500))
  set_row "$WORK/tree" reading \
    "reading|$raised|armaatus/autofleet#54|words a fleet agent is told to read before its first edit: the brief's stage 1, plus every \"count\" row of the reading table below|evals/lint.sh"
  out="$(lint_in "$WORK/tree")"; rc=$?
  [ "$rc" = 0 ] \
    || { echo "$out" >&2; fail "raising the row in the ceilings table did not raise the ceiling (rc=$rc)"; }
  grep -qF "ceiling $raised" <<<"$out" \
    || { echo "$out" >&2; fail "the lint reports a ceiling that is not the one in the table"; }
  ok "...and raising that row, and only that row, is what raises it"

  # A second row, measured a different way, so the phase is not asserting one
  # check twice: `claude-md` counts LINES of a file the session reads whole.
  rm -rf "$WORK/tree2"; mk_tree "$WORK/tree2"
  limit="$(ceiling claude-md)"
  rm -f "$WORK/tree2/CLAUDE.md"
  cp "$REPO_ROOT/CLAUDE.md" "$WORK/tree2/CLAUDE.md"
  was="$(wc -l <"$WORK/tree2/CLAUDE.md" | tr -d ' ')"
  awk -v n=$((limit + 1 - was)) 'BEGIN { for (i = 0; i < n; i++) print "<!-- a line -->" }' \
    >>"$WORK/tree2/CLAUDE.md"
  out="$(lint_in "$WORK/tree2")"; rc=$?
  [ "$rc" = 0 ] && { echo "$out" >&2; fail "CLAUDE.md one line over its ceiling did not fail the lint"; }
  says_all_four "the CLAUDE.md ceiling's failure" "$out" \
    "lines of CLAUDE.md" "$limit" "$((limit + 1))"
  ok "...and a second row, measured in lines rather than words, fails the same way"
  ;;
# ------------------------------------------------------------- wellformed
  wellformed)
  WORK="$(mktemp -d)"; WORK="$(cd "$WORK" && pwd -P)"
  mk_tree "$WORK/tree"
  assert_green "$WORK/tree"

  # A row with no issue. Every row cites one so a ceiling with no reason cannot
  # be added: a bare number a year from now cannot be told apart from a number
  # somebody raised to make a red build go away.
  set_row "$WORK/tree" testrun \
    "testrun|5|because it felt about right|lines a fully green ./tests/run.sh prints|tests/test_runner_bound.sh quiet"
  out="$(lint_in "$WORK/tree")"; rc=$?
  [ "$rc" = 0 ] && { echo "$out" >&2; fail "a ceiling citing no issue was accepted"; }
  grep -qF "not an issue" <<<"$out" \
    || { echo "$out" >&2; fail "the uncited row failed without saying that the citation is what is missing"; }
  ok "a ceiling with no issue behind it is refused"

  # A row measured by a phase that is not in the registry: the ceiling exists,
  # the phase exists, and nothing ever runs it. This is hard rule 3 in the
  # table's own shape -- the row looks enforced in every reading of the file.
  mk_tree "$WORK/tree2"
  set_row "$WORK/tree2" round \
    "round|45|armaatus/autofleet#53|lines one clean round of ./scripts/fleet/await-review.sh prints|tests/test_await_review.sh nosuchphase"
  out="$(lint_in "$WORK/tree2")"; rc=$?
  [ "$rc" = 0 ] && { echo "$out" >&2; fail "a ceiling measured by a phase the runner never calls was accepted"; }
  grep -qF "never runs" <<<"$out" \
    || { echo "$out" >&2; fail "the unregistered phase failed without saying the phase never runs: $out"; }
  ok "...and one measured by a phase the runner never calls"

  # A row nothing reads: renaming it leaves the suite measuring against a number
  # of its own, which is the drift between a limit and its membership that
  # armaatus/autofleet#54 found in the other direction.
  mk_tree "$WORK/tree3"
  set_row "$WORK/tree3" round \
    "roundabout|45|armaatus/autofleet#53|lines one clean round of ./scripts/fleet/await-review.sh prints|tests/test_await_review.sh quiet"
  out="$(lint_in "$WORK/tree3")"; rc=$?
  [ "$rc" = 0 ] && { echo "$out" >&2; fail "a ceiling nothing reads was accepted, so the number in the table is not the one in force"; }
  grep -qF "ceiling roundabout" <<<"$out" \
    || { echo "$out" >&2; fail "the unread row failed without naming the row nobody calls: $out"; }
  ok "...and one that no check reads, so the table's number is not the one in force"
  ;;
  *)
  echo "usage: $0 {over|wellformed}" >&2; exit 2 ;;
esac
