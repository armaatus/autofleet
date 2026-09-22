#!/usr/bin/env bash
# Covers scripts/fleet/issue-command.sh -- the opening brief.
#
#   test_brief.sh brief  the spec is printed, the brief under it says the four
#                        things the loop depends on, names none of the post-PR
#                        loop, and fits in ONE SCREEN.
#
# The line bound replaced a word ceiling that lived in evals/lint.sh
# (armaatus/autofleet#153). A brief short enough to read does not need a table to
# keep it short; if it grows back, that is a finding on the PR that grew it, and
# this is the number that makes it visible.
#
# `gh` is stubbed on PATH, so nothing here reads a real issue.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The acceptance of armaatus/autofleet#153: under 60 lines, PLUS the issue body,
# which is as long as whoever wrote the issue made it.
BRIEF_LINE_BUDGET=60

fail() { echo "FAIL: $*" >&2; exit 1; }

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; return 0; }
trap cleanup EXIT

# The WHOLE payload, not the one script under test: issue-command.sh sources
# lib.sh, which sources config.sh and a runner driver, so a hand-picked subset
# is a fixture that cannot load.
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
  # PINNED: the brief substitutes __TEST_COMMAND__ from the environment, and a
  # host project's longer command would otherwise spend this phase's margin.
  export AUTOFLEET_TEST_COMMAND="the full test suite"
}

run_it() { (cd "$WORK/repo" && GH_PAGER=cat ./scripts/fleet/issue-command.sh "$@"); }

# Everything from the `---` separator down: the brief, with the issue body that
# precedes it left out.
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
  brief)
    make_fixture
    out="$(run_it 42 2>&1)" || fail "issue-command.sh 42 exited non-zero: $out"

    grep -q 'SPEC-BODY-MARKER' <<<"$out" \
      || fail "the spec is no longer printed, so the agent starts from a title: $out"

    # `/implement` is named because the skill ships
    # `disable-model-invocation: true`: an agent will not reach for it on its
    # own, and a brief that merely described the work would get a hand-rolled
    # build with no tdd behind it.
    has "the brief" "$out" '/implement' '/mattpocock-skills:tdd'
    # The closing line the merge gate reads. This is the only place it is
    # written -- CLAUDE.md points here rather than restating it.
    has "the brief" "$out" 'Closes #42'
    # The two bounds an agent has to know it is under.
    has "the brief" "$out" 'researcher' 'gh pr diff --stat'
    has "the brief" "$out" 'STOP'

    # THE PLANNING PHASE IS GONE. The issue body is the plan.
    lacks "the brief" "$out" 'plan mode' 'verifier'

    # ...and NONE of the post-PR loop. Every one of these is something the
    # dispatcher does, so a brief that named one would send an agent to spend
    # its budget being told no.
    lacks "the brief" "$out" \
      './scripts/fleet/await-review.sh' './scripts/fleet/review.sh' \
      './scripts/fleet/fix.sh' './scripts/fleet/after-pr.sh' \
      '--auto --squash' '--after-pr'

    lines="$(brief_only <<<"$out" | wc -l | tr -d ' ')"
    [ "$lines" -le "$BRIEF_LINE_BUDGET" ] \
      || fail "the brief is $lines lines, over the $BRIEF_LINE_BUDGET-line budget. Cut it, or move the words into the issue that needs them."
    echo "ok: the brief is the spec and $lines lines"
    ;;
  *)
    echo "usage: $0 {brief}" >&2; exit 2 ;;
esac
