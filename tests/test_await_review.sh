#!/usr/bin/env bash
# Covers scripts/fleet/await-review.sh -- one question, asked of GitHub until it
# answers: is there a verdict for the commit this pull request is on now.
#
#   test_await_review.sh verdict   an approve marker for the current head ends
#                                  the wait, exit 0.
#   test_await_review.sh refusal   ...and so does a request-changes marker. The
#                                  gate's own `approved()` says no to it, and a
#                                  caller waiting for "has anyone judged this"
#                                  must not go on waiting through a refusal --
#                                  which is the one way this script can differ
#                                  from the gate and still be right.
#   test_await_review.sh moved     the head moving under the wait ends it with
#                                  exit 4, rather than silently re-targeting:
#                                  the answer would then be about a commit the
#                                  caller never named.
#   test_await_review.sh stopped   ~/.autofleet/STOP means nothing is coming.
#   test_await_review.sh quiet     what one clean round COSTS the reader, against
#                                  the `round` row of evals/lint.sh's ceilings.
#
# `gh` is stubbed on PATH and the fleet state dir is a temp dir, so nothing here
# touches a pull request or the machine's fleet.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The `round` row of evals/lint.sh's ceilings table, read rather than restated.
. "$REPO_ROOT/tests/ceiling.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "ok: $*"; }

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; return 0; }
trap cleanup EXIT

# A worktree holding just the scripts under test, as its own git repo so the
# branch and head lookups answer. The whole `.github/scripts` set has to be
# here: await-review.sh IMPORTS `merge_gate.approved` rather than paraphrasing
# what counts as a verdict, which is the property the `verdict` phase is about.
#
# $1 is the marker the stubbed review carries -- `approve`, `request-changes`,
# or empty for a review that judged nothing. $2, when set, is the head the stub
# reports AFTER the first poll, which is how the `moved` phase moves it.
make_fixture() {
  WORK="$(mktemp -d)"; WORK="$(cd "$WORK" && pwd -P)"
  mkdir -p "$WORK/repo/scripts/fleet" "$WORK/repo/.github/scripts" "$WORK/bin"
  cp -R "$REPO_ROOT"/scripts/fleet/. "$WORK/repo/scripts/fleet/"
  cp "$REPO_ROOT"/.github/scripts/*.py \
     "$REPO_ROOT/.github/scripts/pr_payload.sh" "$WORK/repo/.github/scripts/"
  git -C "$WORK/repo" init -q -b work
  git -C "$WORK/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  PR_HEAD="$(git -C "$WORK/repo" rev-parse HEAD)"

  GH_VERDICT="$WORK/verdict"; printf '%s' "${1:-}" >"$GH_VERDICT"
  GH_HEAD="$WORK/head";       printf '%s' "$PR_HEAD" >"$GH_HEAD"
  GH_MOVED="$WORK/moved";     printf '%s' "${2:-}" >"$GH_MOVED"
  GH_CALLS="$WORK/calls";     : >"$GH_CALLS"

  cat >"$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALLS"
case "$*" in
  *"repo view"*) echo "armaatus/autofleet"; exit 0 ;;
  *headRefOid*)
    # The head MOVES on the second read, and only when a phase asked it to:
    # `moved` needs the first poll to see the old head and the check after it to
    # see the new one, or it is testing a head that was never this PR's.
    if [ -s "$GH_MOVED" ] && [ "$(grep -c headRefOid "$GH_CALLS")" -gt 1 ]; then
      cat "$GH_MOVED"; echo
    else
      cat "$GH_HEAD"; echo
    fi
    exit 0 ;;
  *"pr list"*)   echo 42; exit 0 ;;
  *graphql*)
    python3 - "$(cat "$GH_HEAD")" "$(cat "$GH_VERDICT")" <<'PY'
import json, sys
oid, verdict = sys.argv[1], sys.argv[2]
body = "## Independent review\n\nNothing Critical or Important.\n"
if verdict:
    body += "\n<!-- autofleet-verdict: %s %s -->" % (verdict, oid)
print(json.dumps({"data": {"repository": {"pullRequest": {
    "body": "Closes #7",
    "reviews": {"nodes": [
        {"state": "COMMENTED", "submittedAt": "2026-09-21T02:00:00Z",
         "commit": {"oid": oid}, "author": {"login": "armaatus"},
         "body": body}]}}}}}))
PY
    exit 0 ;;
esac
exit 0
STUB
  chmod +x "$WORK/bin/gh"
  export GH_CALLS GH_HEAD GH_VERDICT GH_MOVED
  export AUTOFLEET_DIR="$WORK/fleet"
  mkdir -p "$AUTOFLEET_DIR"
  # One poll, and a deadline it cannot reach: every phase here ends on the first
  # or second payload, and a phase that does not should say so as a hang rather
  # than as a pass.
  export AUTOFLEET_POLL=1 AUTOFLEET_REVIEW_TIMEOUT=30
  PATH="$WORK/bin:$PATH"
}

# No `timeout` wrapper: macOS does not ship one, and tests/run.sh already bounds
# every phase (PHASE_TIMEOUT) and reaps the process group. A hang here is a
# phase timeout, which is the report it should be.
run_it() { (cd "$WORK/repo" && ./scripts/fleet/await-review.sh 42 2>&1); }

case "${1:-}" in
# -------------------------------------------------------------------- verdict
  verdict)
  make_fixture approve
  out="$(run_it)"; rc=$?
  [ "$rc" = 0 ] || { echo "$out" >&2; fail "an approve marker on the head did not end the wait (rc $rc)"; }
  grep -q 'has a verdict' <<<"$out" \
    || { echo "$out" >&2; fail "the wait ended without saying what it found"; }
  ok "an approving verdict on the current head ends the wait"
  ;;
# -------------------------------------------------------------------- refusal
  refusal)
  # THE ONE PLACE THIS SCRIPT IS DELIBERATELY WIDER THAN THE GATE.
  # `merge_gate.approved()` answers "may this merge", and a request-changes is a
  # no. This asks "has anyone judged this commit", and a request-changes is a
  # yes. Read through `approved()` alone, a refused pull request waits out its
  # whole deadline and then reports that nothing arrived -- which is
  # indistinguishable from a reviewer that never ran.
  make_fixture request-changes
  out="$(run_it)"; rc=$?
  [ "$rc" = 0 ] || { echo "$out" >&2; fail "a request-changes verdict left the wait running (rc $rc)"; }
  ok "a refusal is a verdict too, and ends the wait"
  ;;
# ---------------------------------------------------------------------- moved
  moved)
  make_fixture "" 0123456789abcdef0123456789abcdef01234567
  out="$(run_it)"; rc=$?
  [ "$rc" = 4 ] || { echo "$out" >&2; fail "a head move under the wait did not exit 4 (got $rc)"; }
  grep -q 'moved to' <<<"$out" \
    || { echo "$out" >&2; fail "the wait ended on a head move without saying so"; }
  ok "a head move ends the wait rather than re-targeting it"
  ;;
# -------------------------------------------------------------------- stopped
  stopped)
  make_fixture approve
  : >"$AUTOFLEET_DIR/STOP"
  out="$(run_it)"; rc=$?
  [ "$rc" = 3 ] || { echo "$out" >&2; fail "a stopped fleet did not exit 3 (got $rc)"; }
  ok "a stopped fleet is told nothing is coming"
  ;;
# ---------------------------------------------------------------------- quiet
  quiet)
  # What one clean round COSTS the reader.
  #
  # This output lands in a context that has to survive an implementation and a
  # review round, and every sentence in it was added because something failed
  # once -- which is exactly the shape armaatus/autofleet#56 is about: prose
  # grows back one useful paragraph at a time and nothing objects at any single
  # step. So the round has a ceiling, and it is the `round` row of
  # evals/lint.sh's ceilings table.
  #
  # A ceiling on lines rather than words: this is output a reader skims for the
  # next command, and the cost of it is screen, not vocabulary.
  make_fixture approve
  out="$(run_it)"; rc=$?
  [ "$rc" = 0 ] || { echo "$out" >&2; fail "a verdict in hand did not exit 0 (got $rc)"; }
  # The fixture has to be load-bearing, or this measures a round that never
  # reached the review -- which is a short output and a green row.
  grep -q 'has a verdict' <<<"$out" \
    || { echo "$out" >&2; fail "the round never reached a verdict, so its length proves nothing"; }
  lines="$(wc -l <<<"$out" | tr -d ' ')"
  limit="$(ceiling round)" || exit 1
  [ "$lines" -le "$limit" ] \
    || { echo "$out" >&2; fail "$(ceiling_over round "$lines")"; }
  ok "one clean round is $lines lines, ceiling $limit"
  ;;
  *)
  echo "usage: $0 {verdict|refusal|moved|stopped|quiet}" >&2; exit 2 ;;
esac
