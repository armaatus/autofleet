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
#   test_handoff.sh empty     a write with nothing in it is refused, and the
#                             previous round's note survives. `write --stdin`
#                             is what the brief tells an agent to run, and an
#                             agent that runs it as a bare tool call gets EOF.
#   test_handoff.sh refs      a .../issues/<n> URL resolves to <n>, and an
#                             ambiguous worktree is refused rather than guessed
#                             at. Both are how the number reaches the note's
#                             filename, and a wrong one writes a note nothing
#                             ever reads.
#   test_handoff.sh retry     `fleet.sh retry N` names the note, which is the
#                             one place on the retry path that is certainly
#                             reached: the dispatcher's prompt only names it in
#                             the narrow state where the old worktree's
#                             directory outlives the runner's listing of it.
#   test_handoff.sh ships     install.sh puts handoff.sh in a host repo AND
#                             gets `.autofleet/run/` into that repo's
#                             .gitignore. The note is the first file with
#                             content to land there, and untracked content in a
#                             repo an agent drives is what `git add -A` sweeps
#                             into a commit.
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

  # A runner that answers, because `fleet.sh` refuses to be sourced at all
  # without one -- `runner_available || die "the $AUTOFLEET_RUNNER runner is not
  # usable here"`. On this laptop the orca driver answers and the three phases
  # that source fleet.sh passed; in CI there is no Orca app and they failed on
  # a line that has nothing to do with what they assert. tests/test_fleet.sh
  # carries the same stub for the same reason.
  #
  # MINIMAL, and deliberately so: neither `agent_brief` nor `cmd_retry` reaches
  # the runner, so a fuller stub would be a fixture asserting itself. It lives
  # in the FIXTURE's scripts/fleet/runner/, never in the source tree, so
  # evals/lint.sh check 4b does not read its functions as contract phantoms.
  cat >"$WORK/repo/scripts/fleet/runner/stub.sh" <<'STUBDRIVER'
#!/usr/bin/env bash
runner_available() { return 0; }
STUBDRIVER
  export AUTOFLEET_RUNNER=stub
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

# The record `launch` reads the note out of: $RAN_DIR, which `own` appends to
# and which OUTLIVES the worktree. Written through `own` itself rather than by
# hand, so the phase asserts against the record the dispatcher actually writes
# -- keyed on $OWNED_DIR this branch was unreachable on the `retry` path it
# exists for, and a fixture that wrote ownership by hand hid that.
ran_in() {
  local num="$1" path="$2"
  in_fleet own "$num" "$path" >/dev/null 2>&1
}

# ...and the state `launch` would actually be in when it opens a SECOND worktree
# for an issue: the first one removed from $OWNED_DIR, its $RAN_DIR line kept.
disowned() {
  rm -f "$AUTOFLEET_DIR/worktrees/$1" "$AUTOFLEET_DIR/started/$1"
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
    # ...and `00`, which config.sh accepts because it is all digits and which a
    # string compare against the literal `0` reads as a cap of "00" -- every
    # note over it, the off switch inverted into "refuse everything". One spare
    # zero is what made AUTOFLEET_REVIEW_MAX_TRIES' guard the failure.
    printf '%s\n' "$over" | in_repo env AUTOFLEET_HANDOFF_MAX_WORDS=00 \
      ./scripts/fleet/handoff.sh write 42 --stdin >/dev/null 2>&1 \
      || fail "AUTOFLEET_HANDOFF_MAX_WORDS=00 refused, so the off switch reads as a cap of nothing"
    # THE GUARD ON THE KNOB, which is a separate thing from the cap it guards.
    # config.sh's own comment names hard rule 3 for it: a non-number makes
    # `[ "$words" -le "$cap" ]` return 2, so the test is false,
    # `refuse_if_over_cap` returns early, and a note of any length is accepted
    # with nothing on screen saying the cap is gone. The knob one block above it
    # has had exactly this assertion since the independent review asked for it
    # (tests/test_review_mode.sh); this one shipped with the reasoning and no
    # check, which is the same finding one knob later. Found by the independent
    # review of #55.
    #
    # BOTH ROUTES. The host config is sourced LAST so it can override the
    # defaults, so a check that only ever saw the environment would pass while a
    # project writing `AUTOFLEET_HANDOFF_MAX_WORDS=lots` into the file this knob
    # is documented in reached the cap unchecked.
    # NOT the empty string through the environment: the default is `:=`, which
    # substitutes on unset OR NULL, so empty there means "unset" and 300 is the
    # right answer. Through the config file it is a plain assignment read after
    # the default, where it IS a value, and the `''` arm of the case refuses it.
    for bad in abc 3x -1; do
      cfg_out="$( (cd "$WORK/repo" \
        && AUTOFLEET_HANDOFF_MAX_WORDS="$bad" bash -c '. ./scripts/fleet/config.sh') 2>&1 )"
      cfg_rc=$?
      [ "$cfg_rc" = 2 ] \
        || fail "AUTOFLEET_HANDOFF_MAX_WORDS='$bad' was accepted (rc=$cfg_rc): $cfg_out"
      grep -q "must be a whole number" <<<"$cfg_out" \
        || fail "AUTOFLEET_HANDOFF_MAX_WORDS='$bad' failed without saying why: $cfg_out"
    done
    # $AUTOFLEET_CONFIG, the way tests/test_review_mode.sh drives the same route:
    # config.sh reads `${AUTOFLEET_CONFIG:-$REPO_ROOT/.autofleet/config}`, and
    # $REPO_ROOT belongs to the script that SOURCES it, so a bare `. config.sh`
    # looks for `/.autofleet/config` and finds nothing -- a phase that wrote the
    # file into the fixture and passed would have asserted nothing at all.
    hostcfg="$WORK/hostcfg"
    for bad in lots ""; do
      printf 'AUTOFLEET_HANDOFF_MAX_WORDS=%s\n' "$bad" >"$hostcfg"
      cfg_out="$( (cd "$WORK/repo" \
        && env -u AUTOFLEET_HANDOFF_MAX_WORDS AUTOFLEET_CONFIG="$hostcfg" \
             bash -c '. ./scripts/fleet/config.sh') 2>&1 )"
      cfg_rc=$?
      [ "$cfg_rc" = 2 ] \
        || fail "a config file setting the cap to '$bad' was accepted (rc=$cfg_rc): $cfg_out"
      grep -q "must be a whole number" <<<"$cfg_out" \
        || fail "a config file setting the cap to '$bad' failed without saying why: $cfg_out"
    done

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
    # The brief still ASKS for a note -- that instruction is stage 1's -- but it
    # must not announce one that was never written.
    grep -qF -- 'What the last attempt on this issue left' <<<"$out" \
      && fail "the opening brief announces a note that does not exist: $out"

    ran_in 42 "$WORK/repo"
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
    # The `fleet.sh retry` state, exactly: this worktree ran the issue and holds
    # the note, it is no longer OWNED -- which is the only way the dispatcher
    # would be launching a second one -- and its directory is still there.
    ran_in 42 "$WORK/repo"
    disowned 42
    [ -e "$AUTOFLEET_DIR/worktrees/42" ] \
      && fail "the fixture still owns #42, so this asserts the case that cannot happen"
    out="$(in_fleet agent_brief 42 2>&1)" \
      || fail "agent_brief exited non-zero: $out"
    # ABSOLUTE, because the attempt that reads this prompt IS starting in a
    # different worktree from the one holding the note -- which is the whole of
    # the `fleet.sh retry` case.
    grep -qF -- "$WORK/repo/$NOTE" <<<"$out" \
      || fail "the dispatcher's opening prompt does not name the note: $out"
    grep -qF -- 'issue-command.sh 42' <<<"$out" \
      || fail "agent_brief stopped naming the opening command: $out"
    # A worktree that is gone takes its note with it, and the prompt must not
    # name a path nothing can read.
    rm -rf "$WORK/repo/.autofleet/run"
    out="$(in_fleet agent_brief 42 2>&1)" \
      || fail "agent_brief exited non-zero once the note was gone: $out"
    grep -qiF -- 'handoff' <<<"$out" \
      && fail "the prompt still names a note that is gone: $out"
    echo "ok: a relaunched issue's opening prompt names the note by absolute path"
    ;;

  empty)
    make_fixture
    sample_note | handoff write 42 --stdin >/dev/null 2>&1 \
      || fail "could not record the note the empty write must leave alone"
    before="$(cat "$WORK/repo/$NOTE")"

    out="$(handoff write 42 --stdin </dev/null 2>&1)" \
      && fail "an empty write was accepted, so round one's note is gone: $out"
    [ "$(cat "$WORK/repo/$NOTE")" = "$before" ] \
      || fail "the empty write replaced the note it was refused for"
    # Whitespace is empty too: a heredoc that delivered only its own newline is
    # the same accident with a byte in it.
    printf '   \n\n' | handoff write 42 --stdin >/dev/null 2>&1 \
      && fail "a note of nothing but whitespace was accepted"
    [ "$(cat "$WORK/repo/$NOTE")" = "$before" ] \
      || fail "the whitespace-only write replaced the note"

    # ...and with no note there yet, nothing is created.
    rm -f "$WORK/repo/$NOTE"
    handoff write 42 --stdin </dev/null >/dev/null 2>&1 \
      && fail "an empty write was accepted when there was no note to keep"
    [ -e "$WORK/repo/$NOTE" ] && fail "a refused empty write created $NOTE anyway"

    # The header issue-command.sh prints must never stand over an empty body.
    out="$(brief 42 2>&1)" || fail "issue-command.sh exited non-zero: $out"
    grep -qiF -- 'What the last attempt' <<<"$out" \
      && fail "the brief announces a note that was never written: $out"
    echo "ok: an empty note is refused and the round before it survives"
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

    # The issue is decided before the source is read, and only while it is still
    # unknown: a source path that happens to carry `/issues/<n>` is a FILE.
    mkdir -p "$WORK/repo/docs/issues"
    printf 'from a file under docs/issues\n' >"$WORK/repo/docs/issues/7-notes.md"
    handoff write 42 docs/issues/7-notes.md >/dev/null 2>&1 \
      || fail "a source path containing /issues/ was refused"
    [ -e "$WORK/repo/.autofleet/run/handoff-7.md" ] \
      && fail "the source path was read as the issue: the note went to #7"
    grep -qF -- 'from a file under docs/issues' "$WORK/repo/$NOTE" \
      || fail "the file was not read; #42's note holds $(cat "$WORK/repo/$NOTE")"

    # ...and with the issue LEFT OFF, that same path is still the source. It
    # became the ref, resolved to issue 7, and the command then sat on stdin
    # with the file unopened -- the same class as the case above, from the other
    # side. A URL is what carries a scheme; this does not.
    rm -f "$WORK/repo/.autofleet/run/handoff-43.md"
    printf 'still the file\n' >"$WORK/repo/docs/issues/7-notes.md"
    handoff write docs/issues/7-notes.md >/dev/null 2>&1 \
      || fail "with the issue left off, a source path under docs/issues was not read as a file"
    grep -qF -- 'still the file' "$WORK/repo/$NOTE" \
      || fail "the path was read as the issue again; #42's note holds $(cat "$WORK/repo/$NOTE")"

    # ...and the REPO-ROOT half of that fallback, which had no phase at all:
    # every other assertion here runs with the caller standing in the repo root
    # or with the file under it. This is the one path where the `[ -f
    # "$CALLER_PWD/$src" ] &&` AND-list is false, in a file with `set -e`.
    printf 'from the repo root\n' >"$WORK/repo/root-note.md"
    (cd "$WORK" && "$WORK/repo/scripts/fleet/handoff.sh" write 42 root-note.md) >/dev/null 2>&1 \
      || fail "a source that is relative to the repo root, and absent from the caller's directory, was refused"
    grep -qF -- 'from the repo root' "$WORK/repo/$NOTE" \
      || fail "the repo-root fallback did not read the file; #42's note holds $(cat "$WORK/repo/$NOTE")"

    # ...and a relative source is the caller's, not the repo root's. The usage
    # advertises `write 42 note.md` unqualified, and from a subdirectory that
    # looked for it beside the repo root and said there was no such file.
    mkdir -p "$WORK/repo/sub"
    printf 'from the subdirectory\n' >"$WORK/repo/sub/note.md"
    (cd "$WORK/repo/sub" && ../scripts/fleet/handoff.sh write 42 note.md) >/dev/null 2>&1 \
      || fail "a relative source resolved against the repo root rather than the caller"
    grep -qF -- 'from the subdirectory' "$WORK/repo/$NOTE" \
      || fail "the subdirectory's file was not the one read"
    echo "ok: an issue URL resolves to its number, and an ambiguous worktree is refused"
    ;;

  retry)
    make_fixture
    sample_note | handoff write 42 --stdin >/dev/null 2>&1 \
      || fail "could not record the note retry has to name"
    ran_in 42 "$WORK/repo"
    disowned 42
    mkdir -p "$AUTOFLEET_DIR"
    : >"$AUTOFLEET_DIR/gaveup-42"

    out="$(in_fleet cmd_retry 42 2>&1)" || fail "fleet.sh retry exited non-zero: $out"
    grep -qF -- 'is startable again' <<<"$out" \
      || fail "retry stopped saying the issue is startable: $out"
    grep -qF -- "$WORK/repo/$NOTE" <<<"$out" \
      || fail "retry does not name the note the stopped attempt left: $out"

    # An issue with no note gets the line it always got, and nothing else.
    rm -f "$WORK/repo/$NOTE"
    : >"$AUTOFLEET_DIR/gaveup-42"
    out="$(in_fleet cmd_retry 42 2>&1)" || fail "fleet.sh retry exited non-zero: $out"
    grep -qiF -- 'note' <<<"$out" \
      && fail "retry names a note that does not exist: $out"
    echo "ok: fleet.sh retry names the note the stopped attempt left"
    ;;

  ships)
    make_fixture
    host="$WORK/host"; mkdir -p "$host"; git -C "$host" init -q -b main
    ( cd "$REPO_ROOT" && ./install.sh --force "$host" ) >/dev/null 2>&1 \
      || fail "install.sh would not install into a fresh repo"
    [ -x "$host/scripts/fleet/handoff.sh" ] \
      || fail "handoff.sh did not ship, or did not ship executable"
    grep -qxF -- '.autofleet/run/' "$host/.gitignore" \
      || fail "the host's .gitignore does not cover .autofleet/run/, so the note is sweepable by git add -A"

    # A re-run adds nothing. An installer that stacks a block per run is a
    # .gitignore nobody reads after the third upgrade.
    before="$(cat "$host/.gitignore")"
    ( cd "$REPO_ROOT" && ./install.sh --force "$host" ) >/dev/null 2>&1 \
      || fail "a second install.sh run failed"
    [ "$(cat "$host/.gitignore")" = "$before" ] \
      || fail "a second run changed the .gitignore again"

    # A host that already ignores it keeps its own file untouched, and one with
    # no trailing newline does not get its last line joined to the new block.
    host2="$WORK/host2"; mkdir -p "$host2"; git -C "$host2" init -q -b main
    printf 'node_modules/' >"$host2/.gitignore"
    ( cd "$REPO_ROOT" && ./install.sh --force "$host2" ) >/dev/null 2>&1 \
      || fail "install.sh would not install over an existing .gitignore"
    grep -qxF -- 'node_modules/' "$host2/.gitignore" \
      || fail "the host's own .gitignore line was lost or joined to the payload's block"
    grep -qxF -- '.autofleet/run/' "$host2/.gitignore" \
      || fail "the payload's entry was not added to an existing .gitignore"
    echo "ok: handoff.sh ships, and the host ignores what the payload writes"
    ;;

  brief)
    make_fixture
    out="$(brief --after-pr 42 2>&1)" || fail "--after-pr exited non-zero: $out"
    grep -qF -- './scripts/fleet/handoff.sh write 42' <<<"$out" \
      || fail "the post-PR half never tells an agent to write the note: $out"

    # BOTH stages ask for it, and that is the one instruction here which
    # deliberately is in both. #55's other half is the attempt the time-box
    # INTERRUPTS -- which happens before a PR exists, so an instruction that
    # arrives only with `--after-pr` cannot serve it. The independent review is
    # where that was measured: `gaveup-<n>` is written on the "no PR" path
    # alone, so both dispatcher-side readers could only ever fire for an issue
    # that had never been asked for a note.
    out="$(brief 42 2>&1)" || fail "issue-command.sh exited non-zero: $out"
    grep -qF -- './scripts/fleet/handoff.sh write 42' <<<"$out" \
      || fail "stage 1 never tells an interrupted agent to write the note: $out"
    grep -qiF -- 'nterrupted' <<<"$out" \
      || fail "stage 1 names the script but not the case it is for: $out"

    # ...and stage 1 still carries none of the post-PR contract around it.
    grep -qF -- 'after every round' <<<"$out" \
      && fail "stage 1 carries the after-every-round instruction, which is stage 2's"
    echo "ok: stage 1 asks for the note when the work is put down, stage 2 at the push"
    ;;
  *)
    echo "usage: $0 {write|print|cap|absent|resumed|relaunch|empty|refs|retry|ships|brief}" >&2; exit 2 ;;
esac
