#!/usr/bin/env bash
# Covers scripts/fleet/self-review.sh -- the two mandatory self-review passes,
# run OUTSIDE the session that wrote the diff (armaatus/autofleet#51).
#
# The failure this script exists to prevent is quiet and expensive in two
# directions. One: both passes reading the whole diff inside the agent's own
# context, immediately before the phase that has to survive longest. Two -- and
# this is what most of the assertions below are about -- a pass that produces
# NOTHING and is recorded anyway. The marker satisfies `guard.py`'s push gate, so
# the pull request goes out claiming two reviews that never ran, and the only
# thing that could have said so is this file.
#
#   test_self_review.sh runs     both passes run in a separate, bounded process,
#                                the findings come back labelled with the two
#                                words `merge_gate.py` greps the body for, and
#                                the push marker is written for THIS commit.
#   test_self_review.sh silent   one pass produces nothing -> non-zero, the pass
#                                is NAMED, and no marker is written. The row that
#                                goes green if the gate ever becomes decorative.
#   test_self_review.sh thin     ...and "nothing" is merge_gate.py's bar, not a
#                                second paraphrase of it: a pass that prints two
#                                characters is silent too.
#   test_self_review.sh timeout  a wedged pass is killed at
#                                AUTOFLEET_SELF_REVIEW_TIMEOUT and reported as a
#                                FAILURE, not as no findings -- and the kill
#                                reaches what the command STARTED, because the
#                                knob is advertised as a wrapper seam.
#   test_self_review.sh missing  the command is not on PATH -> exit 6, nothing
#                                recorded, and the by-hand remedy is printed.
#   test_self_review.sh stopped  the fleet stop file exists -> exit 3 and no pass
#                                is started at all.
#
# The review command and the fleet state dir are both fakes, so nothing here
# starts an agent or touches the machine's fleet.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "  ok: $*"; }

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; return 0; }
trap cleanup EXIT

# A git repo holding the scripts under test, with a `main` to have a merge base
# with -- self-review.sh resolves the range itself, and a fixture with one commit
# would exercise the "could not work out what this branch changed" exit instead
# of the thing being tested.
make_fixture() {
  WORK="$(mktemp -d)"; WORK="$(cd "$WORK" && pwd -P)"
  mkdir -p "$WORK/repo/scripts/fleet" "$WORK/repo/.github/scripts" \
           "$WORK/repo/.autofleet" "$WORK/bin"
  cp -R "$REPO_ROOT"/scripts/fleet/. "$WORK/repo/scripts/fleet/"
  cp "$REPO_ROOT"/.github/scripts/*.py "$WORK/repo/.github/scripts/"
  cp "$REPO_ROOT/REVIEW.md" "$WORK/repo/"
  git -C "$WORK/repo" init -q -b main
  git -C "$WORK/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
  git -C "$WORK/repo" checkout -q -b work
  printf 'a change to review\n' >"$WORK/repo/thing.txt"
  git -C "$WORK/repo" add thing.txt
  git -C "$WORK/repo" -c user.email=t@t -c user.name=t commit -q -m work
  SHA="$(git -C "$WORK/repo" rev-parse HEAD)"
  MARKER="$WORK/repo/.autofleet/run/reviewed-$SHA"

  AUTOFLEET_DIR="$WORK/fleet"; mkdir -p "$AUTOFLEET_DIR"
  export AUTOFLEET_DIR
  PATH="$WORK/bin:$PATH"; export PATH

  # ------------------------------------------------------------- the pass stub
  #
  # It records the ARGV of every invocation, so "was this bounded and
  # allowlisted" is a real question here rather than a stubbed constant, and
  # answers according to which slash command it was handed.
  SELF_CALLS="$WORK/calls"; : >"$SELF_CALLS"; export SELF_CALLS
  SELF_ARGV="$WORK/argv";   : >"$SELF_ARGV";  export SELF_ARGV
  SELF_CHILD="$WORK/child"; : >"$SELF_CHILD"; export SELF_CHILD
  cat >"$WORK/bin/fake-pass" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SELF_ARGV"
prompt=""
while [ $# -gt 0 ]; do
  case "$1" in
    -p) prompt="${2:-}"; shift 2 ;;
    --allowed-tools|--max-turns|--append-system-prompt) shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\n' "$prompt" >>"$SELF_CALLS"
mode="$SELF_MODE"
case "$prompt" in *mattpocock*) mode="${SELF_MODE2:-$SELF_MODE}" ;; esac
case "$mode" in
  findings)
    printf 'Two findings on this branch, written out at enough length to be worth\n'
    printf 'reading, which is the bar merge_gate.py holds a review body to.\n'
    printf -- '- thing.txt:1 -- the first one, from %s\n' "$prompt" ;;
  silent) : ;;
  thin)   printf 'ok\n' ;;
  # A CHILD, not the stub itself. AUTOFLEET_SELF_REVIEW_CMD is advertised as a
  # wrapper seam, so the process doing the work is routinely a child of what
  # self-review.sh signals -- and a kill that reaps only the direct child leaves
  # a full-budget agent running with nothing left to enforce a deadline.
  hang)   sleep 3607 & printf '%s\n' "$!" >>"$SELF_CHILD"; wait ;;
esac
exit 0
STUB
  chmod +x "$WORK/bin/fake-pass"
  export AUTOFLEET_SELF_REVIEW_CMD=fake-pass
}

run_it() { (cd "$WORK/repo" && ./scripts/fleet/self-review.sh "$@"); }

# `grep -c` prints 0 AND exits 1 on an empty file, so `|| echo 0` appends a
# second zero and every comparison against "0" fails -- on the one phase that
# asserts nothing ran, which is the phase where that matters most.
n_calls() { local n; n="$(grep -c . "$SELF_CALLS" 2>/dev/null || true)"; printf '%s\n' "${n:-0}"; }

case "${1:-}" in

# ---------------------------------------------------------------------- runs
  runs)
  make_fixture
  export SELF_MODE=findings
  out="$WORK/out"; err="$WORK/err"
  run_it >"$out" 2>"$err"; rc=$?

  [ "$rc" = 0 ] || { cat "$err" >&2; fail "both passes produced findings and it exited $rc"; }
  ok "exit 0 when both passes produce findings"

  [ "$(n_calls)" = 2 ] || fail "expected two passes, the stub was called $(n_calls) times"
  grep -qF -- '/code-review high' "$SELF_CALLS" \
    || fail "no pass was handed /code-review"
  grep -qF -- '/mattpocock-skills:code-review' "$SELF_CALLS" \
    || fail "no pass was handed /mattpocock-skills:code-review"
  ok "two passes ran, one per slash command, in a process that is not the caller"

  # Bounded and allowlisted, the same way review.sh's reviewer is. A pass spawned
  # with neither is an unbounded agent with every tool, which is most of what
  # moving it out of the session was supposed to buy back.
  grep -q -- '--max-turns' "$SELF_ARGV" || fail "a pass ran with no turn budget"
  grep -q -- '--allowed-tools' "$SELF_ARGV" || fail "a pass ran with no tool allowlist"
  # Read-only over the tree: these passes report, the author fixes.
  grep -q -- 'Write' "$SELF_ARGV" && fail "the pass allowlist grants Write"
  grep -q -- 'Edit' "$SELF_ARGV" && fail "the pass allowlist grants Edit"
  ok "each pass is given a turn budget and a read-only allowlist"

  # THE TWO WORDS merge_gate.py GREPS THE BODY FOR. What the agent pastes into
  # the pull request is what this printed; unlabelled, the paste does not satisfy
  # the gate and the agent has to remember to write them itself.
  grep -qF -- '/code-review' "$out" \
    || fail "the printed findings do not name /code-review, which merge_gate.py reads the body for"
  grep -qF -- 'mattpocock-skills:code-review' "$out" \
    || fail "the printed findings do not name mattpocock-skills:code-review"
  ok "the findings come back attributed to the pass that produced each set"

  # ...and the push gate is satisfied by this alone, for THIS commit.
  [ -f "$MARKER" ] || fail "no .autofleet/run/reviewed-$SHA; the push gate is still closed"
  grep -qF -- 'mattpocock-skills:code-review' "$MARKER" \
    || fail "the marker does not hold what the passes found"
  ok "the push marker is recorded for the exact commit, holding both sets"
  ;;

# -------------------------------------------------------------------- silent
  silent)
  make_fixture
  export SELF_MODE=findings SELF_MODE2=silent
  out="$WORK/out"; err="$WORK/err"
  run_it >"$out" 2>"$err"; rc=$?

  [ "$rc" != 0 ] || fail "a pass produced nothing and it exited 0 -- the marker would satisfy the push gate"
  ok "a silent pass is a non-zero exit ($rc), not a clean review"

  [ -f "$MARKER" ] && fail "a marker was recorded for a run where one pass said nothing"
  ok "nothing is recorded, so guard.py still refuses the push"

  grep -qF -- 'mattpocock-skills:code-review' "$err" \
    || { cat "$err" >&2; fail "the failure does not name WHICH pass was silent"; }
  ok "the silent pass is named"

  # Both passes still ran: the caller is an agent on a time-box, and one
  # invocation naming both outcomes beats two rounds discovering them one at a
  # time.
  [ "$(n_calls)" = 2 ] || fail "the run stopped after the first pass; $(n_calls) ran"
  ok "the other pass still ran, so one invocation reports both outcomes"
  ;;

# ---------------------------------------------------------------------- thin
  thin)
  make_fixture
  export SELF_MODE=thin
  err="$WORK/err"
  run_it >/dev/null 2>"$err"; rc=$?

  [ "$rc" != 0 ] || fail "a two-character pass counted as findings"
  [ -f "$MARKER" ] && fail "a marker was recorded for a pass that printed 'ok'"
  ok "'produced nothing' is merge_gate.py's bar, not a second paraphrase of it"
  ;;

# ------------------------------------------------------------------- timeout
  timeout)
  make_fixture
  export SELF_MODE=hang
  export AUTOFLEET_SELF_REVIEW_TIMEOUT=2
  err="$WORK/err"
  run_it >/dev/null 2>"$err"; rc=$?

  [ "$rc" = 7 ] || { cat "$err" >&2; fail "a wedged pass exited $rc, not the documented 7"; }
  ok "a wedged pass is killed at AUTOFLEET_SELF_REVIEW_TIMEOUT and exits 7"

  grep -qi -- 'killed' "$err" \
    || fail "the timeout is reported as no findings rather than as a kill"
  ok "it is reported as a failure, naming the kill"

  [ -f "$MARKER" ] && fail "a killed pass recorded a marker"
  ok "nothing is recorded"

  # THE GRANDCHILD, not the stub. Signalling the direct child alone leaves the
  # process holding the real budget running, which is the whole reason the spawn
  # gets its own process group.
  orphan="$(head -1 "$SELF_CHILD" 2>/dev/null || true)"
  [ -n "$orphan" ] || fail "the stub never recorded the child it started"
  # A moment for the KILL after the TERM grace period to land.
  sleep 1
  kill -0 "$orphan" 2>/dev/null \
    && { kill -9 "$orphan" 2>/dev/null; fail "what the pass STARTED is still running: the kill reaped the wrapper only"; }
  ok "the kill reaches what the command started, not just the command"
  ;;

# ------------------------------------------------------------------- missing
  missing)
  make_fixture
  export AUTOFLEET_SELF_REVIEW_CMD=no-such-reviewer-anywhere
  err="$WORK/err"
  run_it >/dev/null 2>"$err"; rc=$?

  [ "$rc" = 6 ] || { cat "$err" >&2; fail "a missing command exited $rc, not the documented 6"; }
  [ -f "$MARKER" ] && fail "a marker was recorded with no command to review anything"
  grep -qF -- 'record-review.sh' "$err" \
    || fail "it does not say how to record a review run by hand"
  ok "a missing command is exit 6, records nothing, and prints the by-hand remedy"
  ;;

# ------------------------------------------------------------------- stopped
  stopped)
  make_fixture
  export SELF_MODE=findings
  : >"$AUTOFLEET_DIR/STOP"
  err="$WORK/err"
  run_it >/dev/null 2>"$err"; rc=$?

  [ "$rc" = 3 ] || { cat "$err" >&2; fail "the fleet is stopped and it exited $rc, not 3"; }
  [ "$(n_calls)" = 0 ] || fail "a pass was started while the fleet was stopped"
  [ -f "$MARKER" ] && fail "a marker was recorded while the fleet was stopped"
  ok "a stop is a stop: exit 3, no pass started, nothing recorded"
  ;;

  *) echo "usage: $0 {runs|silent|thin|timeout|missing|stopped}" >&2; exit 2 ;;
esac
