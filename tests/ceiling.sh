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
  local lint="${1:-$REPO_ROOT/evals/lint.sh}"
  sed -n "/^CEILINGS=\"\$(cat <<'CEILINGS'\$/,/^CEILINGS\$/p" "$lint" | sed '1d;$d'
}

# The limit for one row. Fatal when the row is absent: an empty limit turns
# `[ "$n" -le "" ]` into a bash error at best and a check that stopped checking
# at worst, and a phase that asserts nothing is the thing hard rule 3 is about.
ceiling() {
  local name="$1" value rows
  rows="$(ceiling_rows)"
  [ -n "$rows" ] || {
    echo "FAIL: no ceilings table found in evals/lint.sh, so this phase has no limit to measure against" >&2
    exit 1
  }
  value="$(awk -F'|' -v n="$name" '$1 == n { print $2; found = 1 } END { exit !found }' <<<"$rows")" || {
    echo "FAIL: no ceiling named '$name' in evals/lint.sh's ceilings table" >&2
    exit 1
  }
  printf '%s\n' "$value"
}
