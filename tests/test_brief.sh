#!/usr/bin/env bash
# Covers scripts/fleet/issue-command.sh -- the opening brief, which since #49
# arrives in TWO stages out of the one file.
#
#   test_brief.sh stage1  the bare form -> the spec, steps 1-3, and a pointer at
#                         stage 2. Under the `brief` ceiling with the spec
#                         excluded, and
#                         carrying NONE of the post-PR contract: the whole point
#                         is that an agent does not pay for 1,272 words of review
#                         loop in the prompt prefix of every request it makes
#                         before the PR exists.
#   test_brief.sh stage2  `--after-pr` -> the post-PR contract and nothing else.
#                         No spec, no steps 1-3, and the issue number still
#                         substituted, because `Closes #N` and the board line
#                         live in this half.
#   test_brief.sh reading what the brief costs an agent BEFORE its first edit:
#                         the rendered brief plus every document it is told to
#                         read. #54 measured 13,425 words there, because the
#                         first sentence sent the agent to docs/WORKFLOW.md and
#                         that page is 10,036 words of a loop the brief had just
#                         given it. evals/lint.sh asserts the same ceiling from
#                         the heredoc; this phase asserts it on what the script
#                         actually prints. One number, in that file's ceilings
#                         table, read here through tests/ceiling.sh.
#
# The union of the two -- every instruction landing in exactly one stage -- is
# asserted by evals/lint.sh, which reads the heredocs rather than running the
# script. This file asserts what the agent actually receives.
#
# `gh` is stubbed on PATH, so nothing here reads a real issue.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The `brief` and `reading` rows of evals/lint.sh's ceilings table.
. "$REPO_ROOT/tests/ceiling.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; return 0; }
trap cleanup EXIT

# The WHOLE payload, not the one script under test: issue-command.sh sources
# lib.sh, which sources config.sh and a runner driver, so a hand-picked subset is
# a fixture that cannot load.
make_fixture() {
  WORK="$(mktemp -d)"; WORK="$(cd "$WORK" && pwd -P)"
  mkdir -p "$WORK/repo/scripts/fleet" "$WORK/bin"
  cp -R "$REPO_ROOT"/scripts/fleet/. "$WORK/repo/scripts/fleet/"
  git -C "$WORK/repo" init -q -b work
  git -C "$WORK/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

  # gh applies --template itself, so the stub answers what the template would
  # have produced. The marker is what tells the spec apart from the brief.
  cat >"$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"issue view"*)
    echo "# 42: a fixture issue"
    echo "SPEC-BODY-MARKER"
    exit 0 ;;
esac
exit 0
STUB
  chmod +x "$WORK/bin/gh"
  PATH="$WORK/bin:$PATH"
  # PINNED, because the word budget is measured on what the script RENDERS and
  # __TEST_COMMAND__ is substituted from the environment. Left ambient, a host
  # project's longer command spends the brief's margin: a seven-word
  # `docker compose run --rm app pytest -q` lands at 398 of 400 and an
  # eight-word one fails this phase for a reason that has nothing to do with the
  # brief. evals/lint.sh substitutes the same default for the same reason.
  # Found by the local /code-review pass.
  export AUTOFLEET_TEST_COMMAND="the full test suite"
}

# Set by #49 and, since armaatus/autofleet#56, stated once: the `brief` row of
# evals/lint.sh's ceilings table. That file is the vendored copy, so a host
# project gets the ceiling even though tests/ is not vendored, and this phase
# measures the same row on what the script PRINTS rather than on the heredoc.
#
# Raising it on the branch alone is not raising it: `agent-config.yml` re-runs
# MAIN's lint against the branch, so a number that moved here and not on main is
# a red check, not a raised budget. #55 is where that was learned.
BRIEF_WORD_BUDGET="$(ceiling brief)"

run_it() { (cd "$WORK/repo" && GH_PAGER=cat ./scripts/fleet/issue-command.sh "$@"); }

# Everything from the `---` separator down: the brief, with the issue body that
# precedes it left out. The acceptance is about what the brief costs, and a spec
# is as long as whoever wrote the issue made it.
brief_only() { sed -n '/^---$/,$p'; }

has() {
  local what="$1" out="$2"; shift 2
  local want
  for want in "$@"; do
    grep -qF -- "$want" <<<"$out" || fail "$what does not mention '$want'"
  done
}
lacks() {
  local what="$1" out="$2"; shift 2
  local unwanted
  for unwanted in "$@"; do
    grep -qF -- "$unwanted" <<<"$out" \
      && fail "$what still carries '$unwanted', so the split did not move it"
  done
  return 0
}

case "${1:-}" in
  stage1)
    make_fixture
    out="$(run_it 42 2>&1)" || fail "issue-command.sh 42 exited non-zero: $out"

    grep -q 'SPEC-BODY-MARKER' <<<"$out" \
      || fail "the spec is no longer printed, so the agent starts from a title: $out"
    has "stage 1" "$out" \
      '/code-review high' '/mattpocock-skills:code-review' \
      './scripts/fleet/record-review.sh' \
      './scripts/fleet/issue-command.sh --after-pr 42'
    # The two things the brief never said and the issue asks for. Without them
    # the fleet's own agents are the only ones that never hear that the subagents
    # exist, and nothing tells them the session has to last three review rounds.
    has "stage 1" "$out" 'researcher' 'verifier' 'gh pr diff --stat' 'sed -n'

    # ...and NONE of the post-PR contract. This is the whole issue: these words
    # ride in the prompt prefix of every request made before the PR exists.
    lacks "stage 1" "$out" \
      'await-review.sh' 'answer-review.sh' 'review-status.sh' 'resolve-thread.sh' \
      '--auto --squash' 'Closes #' './scripts/fleet/board.sh'

    words="$(brief_only <<<"$out" | wc -w | tr -d ' ')"
    [ "$words" -lt "$BRIEF_WORD_BUDGET" ] \
      || fail "the opening brief is $words words, spec excluded, over the ceiling of $BRIEF_WORD_BUDGET. Raise the \`brief\` row in evals/lint.sh's ceilings table, deliberately, or move something into --after-pr"
    echo "ok: stage 1 is the spec, steps 1-3 and a pointer, in $words words"
    ;;
  stage2)
    make_fixture
    out="$(run_it --after-pr 42 2>&1)" || fail "--after-pr exited non-zero: $out"

    has "stage 2" "$out" \
      'gh pr merge <n> --auto --squash' 'Closes #42' \
      './scripts/fleet/board.sh in-review "#42:' \
      './scripts/fleet/await-review.sh' './scripts/fleet/review-status.sh' \
      './scripts/fleet/resolve-thread.sh' './scripts/fleet/answer-review.sh' \
      'GitHub says BLOCKED' 'GitHub says DIRTY' 'GitHub says BEHIND' \
      '.github/workflows/' '.github/scripts/' '.claude/'

    # "and nothing else": an agent running this already has the spec and steps
    # 1-3 in its context, and reprinting them is the duplication #49 is about.
    lacks "stage 2" "$out" \
      'SPEC-BODY-MARKER' '**1. Plan.**' '**3. Review it yourself' \
      '/mattpocock-skills:tdd' 'record-review.sh findings.md'
    echo "ok: --after-pr is the post-PR contract alone, with the issue number in it"
    ;;
  reading)
    make_fixture
    out="$(run_it 42 2>&1)" || fail "issue-command.sh 42 exited non-zero: $out"
    brief="$(brief_only <<<"$out")"

    # The brief may not spend an agent's context on a document it does not need
    # before its first edit. EVERY `.md` it names, not just the ones under
    # `docs/`: the first spelling matched `docs/*.md` alone, so a brief that grew
    # "read README.md first" passed this phase at an unchanged word total while
    # the header above claimed to measure what the brief costs. Found by the
    # local /code-review pass.
    #
    # What it may name is exactly what is COUNTED below, plus `findings.md` --
    # a file the review WRITES rather than one it reads. One list drives both the
    # allowance and the sum, so the phase cannot forbid a document and then leave
    # its words out of the total, or allow one and never charge for it.
    #
    # And the list is READ OUT OF evals/lint.sh's reading table rather than
    # restated here. Hardcoded, this phase kept summing two files when a third
    # required document was added there -- green under an unchanged ceiling,
    # while the header above claims to measure "every document it is told to
    # read". armaatus/autofleet#56 folded the NUMBER into the ceilings table at
    # the top of that same file, and the `reading` row names this set as what it
    # measures: the two halves live in one file and neither can move alone.
    # Found by the independent review.
    COUNTED="$(sed -n 's/^ *"\([A-Za-z0-9_./-]*\)": *("count".*/\1/p' \
               "$REPO_ROOT/evals/lint.sh" | sort -u | tr '\n' ' ')"
    [ -n "${COUNTED// /}" ] \
      || fail "no \"count\" rows found in evals/lint.sh's reading table; this phase would sum nothing and pass"
    allowed="$(printf '%s\n' $COUNTED findings.md | sed 's/\./\\./g' | paste -sd'|' -)"
    named="$(grep -oE '[A-Za-z0-9_./-]+\.md' <<<"$brief" | sort -u \
             | grep -vxE "$allowed" || true)"
    [ -z "$named" ] \
      || fail "the opening brief names $(tr '\n' ' ' <<<"$named"), which an agent does not need before its first edit"

    # CLAUDE.md is read automatically, REVIEW.md is the policy the brief names
    # at step 3, and the brief is the brief. Read from the real tree rather than
    # the fixture: the fixture is scripts/fleet alone, and these are the files
    # whose size the ceiling is about.
    total=0
    # shellcheck disable=SC2086 -- COUNTED is a deliberate word list, like SUITES
    for f in $COUNTED; do
      n="$(wc -w <"$REPO_ROOT/$f" | tr -d ' ')"
      total=$((total + n))
      echo "  $f: $n"
    done
    n="$(wc -w <<<"$brief" | tr -d ' ')"
    total=$((total + n))
    echo "  the brief: $n"

    # The limit AND the membership out of the same row. evals/lint.sh is the
    # vendored copy, so a host project gets the ceiling even though tests/ is
    # not vendored, and this phase measures it on what the script prints.
    READING_CEILING="$(ceiling reading)"
    [ "$total" -lt "$READING_CEILING" ] \
      || fail "a fleet agent is told to read $total words before its first edit, over the ceiling of $READING_CEILING. Raise the \`reading\` row in evals/lint.sh's ceilings table, deliberately, or spend fewer"
    echo "ok: a fleet agent reads $total words before its first edit, ceiling $READING_CEILING"
    ;;
  *)
    echo "usage: $0 {stage1|stage2|reading}" >&2; exit 2 ;;
esac
