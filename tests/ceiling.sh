#!/usr/bin/env bash
# The ceilings table has ONE home -- `CEILINGS` at the top of evals/lint.sh --
# and this is how the phases that measure a row read it.
#
# Three of the rows bound the OUTPUT of a script rather than the contents of a
# file, so the only honest place to measure them is a phase that runs the script
# and counts what an agent would have received. That puts the measurement in
# tests/ and the number in evals/lint.sh, which is two files -- and two files is
# exactly how a limit and its membership drifted apart before
# (armaatus/autofleet#54: this suite hardcoded the set of documents it summed
# while the lint derived the same set from its reading table). So nothing here
# restates a number: the row is read out of the shipped file, and
# `evals/lint.sh`'s `== the ceilings` check fails the build if a suite named by
# a row stops calling `ceiling`.
#
# Sourced, not run:  . "$REPO_ROOT/tests/ceiling.sh"
#
# armaatus/autofleet#56.

# The table is a quoted heredoc between two `CEILINGS` lines. Anchored on the
# assignment rather than on the first row, so a row added at the top is inside
# the range and a comment mentioning the word is not.
ceiling_rows() {
  sed -n "/^CEILINGS=\"\$(cat <<'CEILINGS'\$/,/^CEILINGS\$/p" \
    "$REPO_ROOT/evals/lint.sh" | sed '1d;$d'
}

# One field of one row. Non-zero when the row is absent, and every caller reads
# it through a command substitution -- so the caller writes `|| exit 1`. An
# `exit` in here would kill only the substitution's subshell: `[ "$n" -le "" ]`
# is then a bash error, `[` returns 2, `if` reads 2 as false, and the ceiling
# passes everything forever with a green line under it. Found by the local
# /mattpocock-skills:code-review standards pass, which reproduced exactly that.
ceiling_field() {
  local name="$1" field="$2" rows
  rows="$(ceiling_rows)"
  [ -n "$rows" ] || {
    echo "FAIL: no ceilings table found in evals/lint.sh, so this phase has no limit to measure against" >&2
    return 1
  }
  awk -F'|' -v n="$name" -v f="$field" '$1 == n { print $f; found = 1 } END { exit !found }' <<<"$rows" || {
    echo "FAIL: no ceiling named '$name' in evals/lint.sh's ceilings table" >&2
    return 1
  }
}
ceiling()       { ceiling_field "$1" 2; }
ceiling_issue() { ceiling_field "$1" 3; }
ceiling_what()  { ceiling_field "$1" 4; }

# The failure a breached ceiling prints, in ONE place on this side of the table
# as `over_ceiling` is on the other. armaatus/autofleet#56's acceptance is a
# message naming four things -- what was measured, the limit, the figure, and
# where the limit is changed -- and five phases restating it by hand is five
# chances to carry three of them. Found by the local /code-review pass.
ceiling_over() {
  local name="$1" figure="$2" limit what issue
  # A row that does not resolve says so ON STDOUT as well. Every caller is
  # `fail "$(ceiling_over ...)"`, and a helper that returns empty there prints a
  # bare `FAIL:` with the real reason on a stream nobody is reading. Found by
  # the local /code-review pass.
  limit="$(ceiling "$name")"      || { echo "no ceiling named '$name' in evals/lint.sh's ceilings table"; return 1; }
  what="$(ceiling_what "$name")"  || { echo "no ceiling named '$name' in evals/lint.sh's ceilings table"; return 1; }
  issue="$(ceiling_issue "$name")" || { echo "no ceiling named '$name' in evals/lint.sh's ceilings table"; return 1; }
  echo "$what: $figure, over the ceiling of $limit set by $issue. Raise the \`$name\` row in the ceilings table at the top of evals/lint.sh, deliberately, or spend fewer"
}
