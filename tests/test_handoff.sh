#!/usr/bin/env bash
# Covers scripts/fleet/handoff.sh -- the note one attempt at an issue leaves for
# the next, and the two readers that hand it back.
#
# The defect it exists for has two ends (armaatus/autofleet#55). One session
# covers the plan, the implementation, both self-review passes, the push, the PR
# and up to three review rounds, so by round two the context still holds every
# file the implementation read. The other end is `enforce_timebox` and
# `fleet.sh retry`: an interrupted attempt threw all of that away with nothing
# written down, and the next one re-derived it from the files at full price.
#
#   test_handoff.sh write     `write` records the note under .autofleet/run/,
#                             and the print form hands it back.
#   test_handoff.sh print     ...with no argument at all, which is the form a
#                             person in the worktree types.
#   test_handoff.sh cap       over the word cap the script REFUSES, names the
#                             cap, and changes nothing. A note that is silently
#                             truncated is worse than one that was refused:
#                             something is relying on the half that went.
#   test_handoff.sh absent    no note is the ordinary state. Every reader
#                             degrades to what it printed before and exits 0.
#   test_handoff.sh resumed   a session restarted in a worktree that has one is
#                             GIVEN it by issue-command.sh, rather than starting
#                             from the issue body alone.
#   test_handoff.sh relaunch  ...and the dispatcher's opening prompt names it,
#                             by absolute path, for the attempt that starts in a
#                             worktree that is not this one.
#   test_handoff.sh refs      a .../issues/<n> URL resolves to <n>, and an
#                             ambiguous worktree is refused rather than guessed
#                             at. Both are how the number reaches the note's
#                             filename, and a wrong one writes a note nothing
#                             ever reads.
#   test_handoff.sh brief     the post-PR half of the brief is what tells an
#                             agent to write one. Nobody writes a note no
#                             document asks for.
#
# `gh` is stubbed on PATH, so nothing here reads a real issue.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; return 0; }
trap cleanup EXIT

# The WHOLE payload, not the one script under test: handoff.sh sources lib.sh,
# which sources config.sh and a runner driver, so a hand-picked subset is a
# fixture that cannot load. Same reasoning as tests/test_brief.sh.
make_fixture() {
  WORK="$(mktemp -d)"; WORK="$(cd "$WORK" && pwd -P)"
  mkdir -p "$WORK/repo/scripts/fleet" "$WORK/bin" "$WORK/fleet"
  cp -R "$REPO_ROOT"/scripts/fleet/. "$WORK/repo/scripts/fleet/"
  git -C "$WORK/repo" init -q -b work
  git -C "$WORK/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

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
  export AUTOFLEET_TEST_COMMAND="the full test suite"
  # The dispatcher's state, away from the developer's own.
  export AUTOFLEET_DIR="$WORK/fleet"
}

NOTE=".autofleet/run/handoff-42.md"

# The note a first attempt would have left. Short on purpose: the cap phase is
# where length is the subject.
sample_note() {
  cat <<'NOTE'
Chose the seam at lib.sh rather than a third copy in fleet.sh, because both
readers already source it.
Touched: scripts/fleet/handoff.sh, scripts/fleet/issue-command.sh.
Round one asked for the cap to refuse rather than truncate; it does.
Still open: whether the dispatcher should name the file relatively.
NOTE
}

in_repo() { (cd "$WORK/repo" && "$@"); }
handoff() { in_repo ./scripts/fleet/handoff.sh "$@"; }
brief()   { in_repo env GH_PAGER=cat ./scripts/fleet/issue-command.sh "$@"; }

# fleet.sh returns instead of dispatching when it is sourced, so agent_brief can
# be exercised without starting a dispatcher. Same helper shape as
# tests/test_fleet.sh's `in_fleet`.
in_fleet() { (cd "$WORK/repo" && . ./scripts/fleet/fleet.sh && "$@"); }

# What `owned_path` reads -- $FLEET_OWNED, which lib.sh puts at
# `$AUTOFLEET_DIR/worktrees`. Written directly rather than through `own`, which
# also cards the board and appends to the run list: neither is anything
# agent_brief consults, and both would need a runner here.
own_worktree() {
  local num="$1" path="$2"
  mkdir -p "$AUTOFLEET_DIR/worktrees"
  printf '%s' "$path" >"$AUTOFLEET_DIR/worktrees/$num"
}

case "${1:-}" in
  write)
    make_fixture
    sample_note >"$WORK/note.md"
    out="$(handoff write 42 "$WORK/note.md" 2>&1)" \
      || fail "handoff.sh write exited non-zero: $out"
    [ -f "$WORK/repo/$NOTE" ] || fail "write recorded nothing at $NOTE: $out"
    grep -qF -- 'Chose the seam at lib.sh' "$WORK/repo/$NOTE" \
      || fail "the recorded note is not what was written: $(cat "$WORK/repo/$NOTE")"
    grep -qF -- "$NOTE" <<<"$out" \
      || fail "write does not say where it put the note, so nobody can go and read it: $out"

    # The stdin form, because that is what an agent with the note in its head
    # rather than in a file will reach for -- and it must REPLACE, not append.
    printf 'a second attempt overwrote it\n' | handoff write 42 --stdin >/dev/null 2>&1 \
      || fail "handoff.sh write --stdin exited non-zero"
    grep -qF -- 'a second attempt overwrote it' "$WORK/repo/$NOTE" \
      || fail "--stdin did not record what it was given"
    grep -qF -- 'Chose the seam at lib.sh' "$WORK/repo/$NOTE" \
      && fail "--stdin appended to the old note instead of replacing it"

    back="$(handoff 42 2>&1)" || fail "the print form exited non-zero: $back"
    grep -qF -- 'a second attempt overwrote it' <<<"$back" \
      || fail "the print form did not hand the note back: $back"
    echo "ok: write records the note and the print form hands it back"
    ;;

  print)
    make_fixture
    sample_note | handoff write 42 --stdin >/dev/null 2>&1 \
      || fail "could not record the note, so the assertion below would be vacuous"
    # No argument at all: the form a person standing in the worktree types.
    # There is exactly one note here, and it is this worktree's.
    out="$(handoff 2>&1)" || fail "the no-argument form exited non-zero: $out"
    grep -qF -- 'Chose the seam at lib.sh' <<<"$out" \
      || fail "the no-argument form did not find this worktree's only note: $out"
    echo "ok: the no-argument form prints this worktree's note"
    ;;

  cap)
    make_fixture
    sample_note | handoff write 42 --stdin >/dev/null 2>&1 \
      || fail "could not record the note the refusal must leave alone"
    before="$(cat "$WORK/repo/$NOTE")"

    # One word over. The cap is a starting point and the number may move; the
    # phase reads it out of config.sh rather than restating it, so raising the
    # default does not silently stop this from testing anything.
    cap="$(sed -n 's/^: "${AUTOFLEET_HANDOFF_MAX_WORDS:=\([0-9]*\)}"$/\1/p' \
           "$REPO_ROOT/scripts/fleet/config.sh")"
    case "$cap" in ''|*[!0-9]*) fail "could not read AUTOFLEET_HANDOFF_MAX_WORDS out of config.sh; this phase would assert nothing" ;; esac
    over="$(awk -v n=$((cap + 1)) 'BEGIN { for (i = 0; i < n; i++) printf "word " }')"

    out="$(printf '%s\n' "$over" | handoff write 42 --stdin 2>&1)" \
      && fail "handoff.sh accepted $((cap + 1)) words against a cap of $cap"
    grep -qF -- "$cap" <<<"$out" \
      || fail "the refusal does not name the cap, so nobody knows what to cut to: $out"
    grep -qF -- "$((cap + 1))" <<<"$out" \
      || fail "the refusal does not say how long the note was: $out"
    [ "$(cat "$WORK/repo/$NOTE")" = "$before" ] \
      || fail "the refusal changed the note anyway, so the previous round's answer is gone"

    # ...and with no note there yet, a refusal must not leave a half-written one.
    rm -f "$WORK/repo/$NOTE"
    printf '%s\n' "$over" | handoff write 42 --stdin >/dev/null 2>&1 \
      && fail "handoff.sh accepted an over-cap note when there was none to keep"
    [ -e "$WORK/repo/$NOTE" ] \
      && fail "a refused write created $NOTE anyway"

    # 0 is the documented off switch, and it has to actually be off.
    printf '%s\n' "$over" | in_repo env AUTOFLEET_HANDOFF_MAX_WORDS=0 \
      ./scripts/fleet/handoff.sh write 42 --stdin >/dev/null 2>&1 \
      || fail "AUTOFLEET_HANDOFF_MAX_WORDS=0 still refused, so the off switch is decorative"
    echo "ok: over the cap it refuses, names the cap, and changes nothing"
    ;;

  absent)
    make_fixture
    # Every reader, and all three degrade to what they printed before #55.
    out="$(handoff 2>&1)" || fail "the print form exited non-zero with no note: $out"
    [ -z "$out" ] || fail "with no note the print form said something: $out"

    out="$(brief 42 2>&1)" || fail "issue-command.sh exited non-zero with no note: $out"
    grep -q 'SPEC-BODY-MARKER' <<<"$out" \
      || fail "the spec stopped being printed when there is no note: $out"
    grep -qiF -- 'handoff' <<<"$out" \
      && fail "the opening brief talks about a handoff that does not exist: $out"

    own_worktree 42 "$WORK/repo"
    out="$(in_fleet agent_brief 42 2>&1)" \
      || fail "agent_brief exited non-zero with no note: $out"
    grep -qF -- 'issue-command.sh 42' <<<"$out" \
      || fail "agent_brief stopped naming the opening command: $out"
    grep -qiF -- 'handoff' <<<"$out" \
      && fail "the dispatcher's prompt names a note that does not exist: $out"
    echo "ok: no note is a normal state for all three readers"
    ;;

  resumed)
    make_fixture
    sample_note | handoff write 42 --stdin >/dev/null 2>&1 \
      || fail "could not record the note the resumed session has to be given"
    out="$(brief 42 2>&1)" || fail "issue-command.sh exited non-zero: $out"
    grep -qF -- 'Chose the seam at lib.sh' <<<"$out" \
      || fail "a session resuming in this worktree is not given the note: $out"
    grep -qF -- 'Still open: whether the dispatcher' <<<"$out" \
      || fail "the note is printed but truncated, so what is still open is not: $out"
    grep -q 'SPEC-BODY-MARKER' <<<"$out" \
      || fail "the note displaced the spec instead of preceding it: $out"

    # The note is stage 1's. An agent running `--after-pr` has it in context
    # already, and reprinting it is the duplication the two-stage split exists
    # to stop (armaatus/autofleet#49).
    out="$(brief --after-pr 42 2>&1)" || fail "--after-pr exited non-zero: $out"
    grep -qF -- 'Chose the seam at lib.sh' <<<"$out" \
      && fail "--after-pr reprints the note the resumed session already has"
    echo "ok: a resumed session is given the note, once"
    ;;

  relaunch)
    make_fixture
    sample_note | handoff write 42 --stdin >/dev/null 2>&1 \
      || fail "could not record the note the dispatcher has to name"
    own_worktree 42 "$WORK/repo"
    out="$(in_fleet agent_brief 42 2>&1)" \
      || fail "agent_brief exited non-zero: $out"
    # ABSOLUTE, because the attempt that reads this prompt may be starting in a
    # different worktree from the one holding the note -- which is the whole of
    # the `fleet.sh retry` case.
    grep -qF -- "$WORK/repo/$NOTE" <<<"$out" \
      || fail "the dispatcher's opening prompt does not name the note: $out"
    grep -qF -- 'issue-command.sh 42' <<<"$out" \
      || fail "agent_brief stopped naming the opening command: $out"
    echo "ok: a relaunched issue's opening prompt names the note by absolute path"
    ;;

  refs)
    make_fixture
    # A URL, which is what a person pastes. On BSD sed -- the one every macOS
    # ships -- the two-expression form both scripts used printed the number
    # TWICE with no separator between them, because the input carried no
    # trailing newline and `p` does not add one to the last line: `/issues/999`
    # resolved to 999999, and the note was written under an issue that does not
    # exist. GNU sed prints it as two lines and `head -1` hid it, so it was
    # green in CI and wrong on the machine the fleet runs on.
    printf 'from a url\n' | handoff write https://github.com/armaatus/autofleet/issues/42 --stdin >/dev/null 2>&1 \
      || fail "handoff.sh would not take an issue URL"
    [ -f "$WORK/repo/$NOTE" ] \
      || fail "an issue URL resolved to something other than 42: $(ls "$WORK/repo/.autofleet/run")"
    # ...and issue-command.sh, which is where the same two lines came from.
    out="$(brief https://github.com/armaatus/autofleet/issues/42 2>&1)" \
      || fail "issue-command.sh would not take an issue URL: $out"
    grep -qF -- 'from a url' <<<"$out" \
      || fail "issue-command.sh resolved the URL to a different issue, so it printed no note: $out"

    # Two notes and no argument is not something to guess at: the glob exists
    # for the worktree that holds exactly one.
    printf 'another\n' | handoff write 43 --stdin >/dev/null 2>&1 \
      || fail "could not record the second note"
    out="$(handoff 2>&1)" \
      && fail "the print form picked one of two notes rather than refusing: $out"
    grep -qF -- 'name the issue' <<<"$out" \
      || fail "the refusal does not say what to do about it: $out"
    out="$(printf 'x\n' | handoff write --stdin 2>&1)" \
      && fail "write picked one of two notes rather than refusing: $out"
    echo "ok: an issue URL resolves to its number, and an ambiguous worktree is refused"
    ;;

  brief)
    make_fixture
    out="$(brief --after-pr 42 2>&1)" || fail "--after-pr exited non-zero: $out"
    grep -qF -- './scripts/fleet/handoff.sh write 42' <<<"$out" \
      || fail "the post-PR half never tells an agent to write the note: $out"

    # Stage 1 must not carry it. It is 394 of its 400 words already, and the
    # instruction does not apply until the PR exists.
    out="$(brief 42 2>&1)" || fail "issue-command.sh exited non-zero: $out"
    grep -qF -- 'handoff.sh write' <<<"$out" \
      && fail "stage 1 carries an instruction that belongs to --after-pr"
    echo "ok: the post-PR half is what asks for the note"
    ;;
  *)
    echo "usage: $0 {write|print|cap|absent|resumed|relaunch|refs|brief}" >&2; exit 2 ;;
esac
