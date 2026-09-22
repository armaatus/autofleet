#!/usr/bin/env bash
# The lint. Four checks, and every one of them runs something rather than
# reading prose.
#
#   ./evals/run.sh
#
# There used to be a fifth kind: ~3,000 lines asserting that one document agreed
# with another -- that CLAUDE.md restated a rule the brief also stated, that a
# page printing a pipeline printed the one that ran, that the reading an agent
# does before its first edit stayed under a word ceiling. 43 of 63 open issues
# were about those assertions rather than about the loop. They are gone with
# armaatus/autofleet#153. A document that drifts is a review finding on the pull
# request that drifted it; a guard that stops guarding is not, which is why the
# selftests below stay.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fails=0
step() { printf '== %s\n' "$1"; }
bad() { printf '   FAIL: %s\n' "$1" >&2; fails=$((fails + 1)); }

# The payload's shell, this repo's own suite, and the seam answers in
# `.autofleet/` -- which are both this repo's configuration and the template
# `install.sh` seeds into a host, and which nothing else parses.
scripts=()
while IFS= read -r f; do scripts+=("$f"); done < <(
  ls scripts/fleet/*.sh scripts/fleet/runner/*.sh .claude/hooks/*.sh \
     .github/scripts/*.sh evals/*.sh tests/*.sh .autofleet/*.sh install.sh \
     2>/dev/null
)
# An empty list is a lint that checked NOTHING and said it was well-formed,
# which is hard rule 3 wearing a green tick. It is also the one shape that
# cannot be expanded: under `set -u` the bash macOS ships treats `"${a[@]}"` on
# an empty array as an unbound variable, so this would die with a message about
# a variable rather than about a payload that is not there.
[ "${#scripts[@]}" -gt 0 ] || {
  echo "evals/run.sh found no scripts to check. It expects to run from the root" >&2
  echo "of a repository the autofleet payload is installed in." >&2
  exit 2
}

step "every script parses"
for f in "${scripts[@]}"; do
  out="$(bash -n "$f" 2>&1)" || bad "$f does not parse: $out"
done

# The linter, at severity=error, over the same list. It is what replaced four
# hand-written scanners in this directory: SC2181 for `$?`, SC2086 for an
# unquoted expansion, SC1073 for the continuation comment that comments out the
# rest of a command. A tool with a changelog beats a regex somebody has to
# maintain here.
#
# A suppression must carry a reason on the same line, after a second `#`, and a
# bare one is not an answer (armaatus/autofleet#17).
step "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck --severity=error --format=gcc "${scripts[@]}" || bad "shellcheck found errors"
else
  # Not a silent pass: a lint that quietly stops linting is the failure hard
  # rule 3 is about. It is not fatal either, because a laptop without it should
  # still be able to run the rest -- CI installs it.
  printf '   shellcheck is not installed; this check did not run.\n' >&2
  printf '   brew install shellcheck / apt-get install shellcheck\n' >&2
fi

# The two guards that decide things, each asked to prove it still does. Both
# print their own assertion count, and both are the reason hard rule 3 exists:
# a rule that stops matching stops blocking, in silence.
step "the guard still guards"
python3 .claude/hooks/guard.py --selftest >/dev/null || bad "guard.py --selftest"

step "the merge gate still gates"
python3 .github/scripts/merge_gate.py --selftest >/dev/null || bad "merge_gate.py --selftest"

# ...and the two readers of `Blocked by #N` still agree. `unblock.yml` is
# JavaScript inside YAML and cannot import the module `fleet.sh` uses, so the
# module's own selftest compares the literals. A drift between them is the fleet
# opening a worktree for an issue whose foundation is still open.
step "the blocker patterns still agree"
python3 .github/scripts/issue_refs.py --selftest >/dev/null || bad "issue_refs.py --selftest"

echo
[ "$fails" = 0 ] || { echo "$fails check(s) failed" >&2; exit 1; }
echo "the payload is well-formed."
