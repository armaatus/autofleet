#!/usr/bin/env bash
# Covers the two places scripts/fleet/fleet.sh used to report a state it had not
# established: the board update, and the worktree removal.
#
#   test_orca_fleet.sh card_says      the Orca CLI refuses -> the dispatcher log
#                                     says the board update failed, and carries
#                                     the CLI's own words. WORKFLOW.md calls the
#                                     board THE status surface, so a silent
#                                     failure freezes it with nothing anywhere
#                                     saying it froze.
#   test_orca_fleet.sh card_quiet     it worked -> nothing is said. A warning per
#                                     poll would be its own kind of noise.
#   test_orca_fleet.sh remove_forces  `worktree rm` fails and `--force` works ->
#                                     the worktree is removed. This repo has a
#                                     submodule and git refuses the plain
#                                     removal outright, so without the retry
#                                     EVERY merged worktree leaks.
#   test_orca_fleet.sh remove_advice  both fail -> reap_merged says how to remove
#                                     it by hand, BOTH halves and in order: the
#                                     directory first, because reap.sh alone
#                                     skips a worktree that is still there and
#                                     prints "nothing to reap"; then reap.sh,
#                                     because once the directory goes the next
#                                     pass disowns the issue and nothing ever
#                                     tears that stack down (#163).
#
# ...and the removal's ORDER, because "could not remove it" used to mean the
# stack had already been torn down anyway (#163): `--run-hooks` ran archive.sh
# BEFORE Orca refused the removal, so a worktree that was still there, still
# owned and still being worked in lost its RomM mid-ctest.
#
#   test_orca_fleet.sh remove_keeps_stack   the removal refuses -> the hook was
#                                           never asked for, the sweep never ran,
#                                           and it says the stack is still up.
#   test_orca_fleet.sh remove_sweeps_stack  it worked -> the stack is swept only
#                                           NOW. Dropping --run-hooks without
#                                           this would leak two ports and four
#                                           volumes per merged worktree.
#   test_orca_fleet.sh merged_keeps_dirty   reap_merged leaves a dirty worktree
#                                           and says what it holds, exactly as it
#                                           already does for unpushed commits --
#                                           #122's held two review fixes.
#   test_orca_fleet.sh merged_keeps_owned   a refused removal keeps the issue
#                                           OWNED and is said once, the way
#                                           reap_abandoned already does. Disowned,
#                                           nothing ever looks at that worktree
#                                           again.
#   test_orca_fleet.sh merged_unknown_git   ...and a git that cannot say what is
#                                           in there is "could not tell", not
#                                           "clean". A guard that fails open on
#                                           its own error is not a guard.
#   test_orca_fleet.sh merged_cli_silent    a CLI that never ANSWERED is not a
#                                           refusal: retried next pass rather
#                                           than parked, or Orca.app restarting
#                                           costs the fleet a slot for good.
#   test_orca_fleet.sh remove_scoped_sweep  the sweep names THIS worktree's stack.
#                                           Unscoped, releasing one worktree also
#                                           deletes the database of an orphan
#                                           somebody is still looking at.
#
# ...and the three places `needs-human-step` has to be honoured, because an
# issue whose last step is outward and the maintainer's is not a stalled one:
#
#   test_orca_fleet.sh stall_expected an agent `waiting` on a labelled issue ->
#                                     reported as waiting for you AS EXPECTED,
#                                     and never as "nothing should be asking".
#   test_orca_fleet.sh stall_reports  an agent `waiting` on an ordinary issue ->
#                                     still the stall it always was. The whole
#                                     point of the exemption is that the signal
#                                     keeps meaning something.
#   test_orca_fleet.sh timebox_waits  past the box, no PR, labelled -> NOT
#                                     interrupted, no "gave up" comment on the
#                                     issue, said once rather than once a
#                                     minute, and on the board rather than only
#                                     in the log.
#   test_orca_fleet.sh timebox_stops  past the box, no PR, unlabelled -> still
#                                     interrupted and still commented on.
#   test_orca_fleet.sh queue_skips    a labelled issue is not startable: the
#                                     dispatcher must not open a worktree for
#                                     work no agent may finish, or it opens one
#                                     per cycle forever (#148).
#   test_orca_fleet.sh list_declines  ...and `fleet.sh run 148` declines it too,
#                                     dropping it rather than skipping it: an
#                                     issue kept in `wanted` that can never be
#                                     launched is a run loop that never ends.
#   test_orca_fleet.sh timebox_rearms the label comes off -> the box fires. The
#                                     exemption keeps the started marker for
#                                     exactly this: deleting it would leave a
#                                     handed-back agent running uncapped.
#   test_orca_fleet.sh labels_unknown the label lookup FAILS -> the agent is not
#                                     stopped and the stall is not decided.
#                                     Every lookup here has a third answer, and
#                                     an agent is only ever stopped on an answer.
#   test_orca_fleet.sh outage_once    ...and it is said ONCE across a real poll:
#                                     notice_stalled must not clear the marker
#                                     enforce_timebox set moments earlier, which
#                                     is the line-a-minute the markers prevent.
#   test_orca_fleet.sh one_lookup     every watcher in one poll -> one `gh` call
#                                     for that issue's state and labels, not one
#                                     each.
#   test_orca_fleet.sh own_clears     a fresh worktree for an issue that had one
#                                     before starts with NO markers. They only
#                                     ever throttle a message to once, so an
#                                     inherited one silences the new worktree --
#                                     a `stalled-42` left behind makes
#                                     notice_stalled say nothing at all.
#   test_orca_fleet.sh timebox_clears both exits from enforce_timebox clear
#   test_orca_fleet.sh stop_clears    every marker it owns, not only the ones it
#                                     set on the way in.
#   test_orca_fleet.sh one_card       exempt, waiting and past the box -> ONE
#                                     board comment in the poll, not two, and it
#                                     still says both things a person needs.
#
# ...and the other half of the reap: a worktree whose issue will never produce a
# merged PR held one of three slots forever, because `reap_merged` is keyed on a
# PR that merged and nothing else ever removed one (#153).
#
#   test_orca_fleet.sh abandon_blocked      the issue went `blocked` -> released.
#   test_orca_fleet.sh abandon_closed       the issue closed with no merged PR
#                                           for this branch -> released.
#   test_orca_fleet.sh abandon_human_step   labelled `needs-human-step` -> released.
#                                           #139's agent correctly produced no PR
#                                           and stopped; reap_merged would wait
#                                           for a merged PR forever.
#   test_orca_fleet.sh abandon_keeps_dirty  ...unless the working tree is dirty,
#   test_orca_fleet.sh abandon_keeps_commits or carries commits that are not in
#                                           origin/main. Kept, and it SAYS what
#                                           is in there -- that pair is the whole
#                                           safety argument, verified by hand
#                                           before every removal on 2026-09-07.
#   test_orca_fleet.sh abandon_unknown_git  ...and a git that cannot answer is
#                                           "could not tell", not "nothing".
#   test_orca_fleet.sh abandon_leaves_working the control: an open issue with no
#                                           reason to release -> untouched. An
#                                           agent mid-task must not lose its
#                                           worktree.
#   test_orca_fleet.sh abandon_timebox      the box stopped the agent -> released,
#                                           and the record of it OUTLIVES the
#                                           worktree.
#   test_orca_fleet.sh gaveup_not_restarted ...so the freed slot does not go
#                                           straight back to the same three
#                                           hours, which is what releasing it
#                                           without the record would do.
#   test_orca_fleet.sh gaveup_retry         `fleet.sh retry 42` is how it comes
#                                           back, and it is the only way.
#   test_orca_fleet.sh abandon_warns_first  the first pass that finds a reason
#                                           WARNS and removes nothing. An agent
#                                           plans before it edits (CLAUDE.md), so
#                                           a worktree forty minutes into real
#                                           work is legitimately empty -- and
#                                           `blocked` is re-derived by
#                                           unblock.yml on every merge, so it
#                                           lands under one that is mid-plan.
#   test_orca_fleet.sh abandon_warned_saved ...and a minute is enough: something
#                                           committed after the warning keeps the
#                                           worktree.
#   test_orca_fleet.sh abandon_two_keeps    the two keeps do not share one
#                                           marker. A transient git failure must
#                                           not silence the line that says what
#                                           is actually in there.
#   test_orca_fleet.sh gaveup_pruned        the record is dropped once the issue
#                                           lands, or `fleet.sh status` lists
#                                           finished work forever and the files
#                                           never go away.
#   test_orca_fleet.sh list_says_declined   a run that declined every issue it was
#                                           given does not report that they landed.
#   test_orca_fleet.sh abandon_reason_flickers
#                                           the reason goes away and comes back ->
#                                           a FRESH pass of notice. unblock.yml
#                                           re-derives `blocked` on every merge,
#                                           so a label that flickers is the
#                                           ordinary case, and a warning spent on
#                                           the first occurrence must not be
#                                           inherited by the second -- that is a
#                                           worktree removed with no notice at all.
#   test_orca_fleet.sh abandon_lookup_blind a lookup that FAILED is not "no
#                                           reason". Folded into one, it wipes a
#                                           warning still owed to a reason nobody
#                                           could read, and the notice starts over
#                                           every time GitHub hiccups -- silently.
#
# ...and the one thing the dispatcher cannot re-read: itself. `fleet.sh run`
# parses its functions once, at start, so a fix merged to `main` is live in the
# worktree and NOT live in the dispatcher that is running -- for 27 hours, over
# four PRs, with nothing anywhere saying so (#173).
#
#   test_orca_fleet.sh status_stale       fleet.sh moved on since the dispatcher
#                                         started -> status says when it started,
#                                         NAMES the commits that are not live in
#                                         it, and says a restart is what fixes
#                                         it, the cap included.
#   test_orca_fleet.sh status_current     it is running the file on disk ->
#                                         still says when it started, and does
#                                         not cry stale. A warning every poll on
#                                         a current dispatcher teaches you to
#                                         ignore the one that matters.
#   test_orca_fleet.sh status_unrecorded  a dispatcher from before this check ->
#                                         "cannot say", not "current". A staleness
#                                         report that fails open is the silence
#                                         #173 already was.
#   test_orca_fleet.sh status_from_worktree
#                                         `status` run from a FLEET worktree,
#                                         branched before the fix, about the
#                                         dispatcher in the main one -> still
#                                         stale. This is the case that actually
#                                         happens: CLAUDE.md points agents in a
#                                         worktree at `fleet.sh status`, and
#                                         comparing the caller's own copy makes
#                                         two old files agree and reports
#                                         "current" -- #173 rebuilt inside the
#                                         check for it.
#   test_orca_fleet.sh status_draining    stopped but still up -> BOTH lines. A
#                                         drain leaves the dispatcher running on
#                                         purpose, and the code it is draining
#                                         with is the stale code.
#   test_orca_fleet.sh status_drained     ...and once it exits, `idle` prints
#                                         WHILE stopped. That line is what the
#                                         documented restart waits for, and the
#                                         stop file used to swallow it.
#   test_orca_fleet.sh status_behind      the checkout it started from never
#                                         pulled the fix -> BEHIND, naming it and
#                                         the pull. Nothing in the fleet updates
#                                         that checkout, so "the bytes on disk
#                                         are the bytes it parsed" is true of the
#                                         exact 27 hours #173 is about.
#   test_orca_fleet.sh status_behind_revert
#                                         ...but a commit and its revert leave
#                                         `origin/main` byte-identical to what
#                                         the dispatcher parsed -> NOT behind.
#                                         The commits are how the report names
#                                         what changed; the bytes are what
#                                         decides that anything did.
#   test_orca_fleet.sh status_unreadable  the dispatcher's own fleet.sh cannot be
#                                         READ -> "cannot say", not STALE. A hash
#                                         nobody could take compares unequal to
#                                         every recorded one, so a permission
#                                         error would otherwise be reported as a
#                                         change.
#   test_orca_fleet.sh status_names_root  the restart it prints names the
#                                         dispatcher's OWN checkout. This report
#                                         is read from a fleet worktree, and a
#                                         relative `run --auto` there starts a
#                                         dispatcher in a directory the fleet
#                                         removes when that PR merges.
#
# ...and the other half of that: nothing stopped the restart it advises from
# landing on top of a dispatcher that never went away. `MAX_WORKTREES` is
# enforced per PROCESS, so two dispatchers open twice the cap between them,
# reap, card and interrupt the same worktrees, and say so nowhere (#179).
#
#   test_orca_fleet.sh run_refuses        a dispatcher is up -> `run` refuses,
#                                         NAMES its pid, and says how to take
#                                         over. The pidfile is left naming the
#                                         one that is running: a refusal that
#                                         claimed it would leave the live
#                                         dispatcher's own exit unable to
#                                         release it.
#   test_orca_fleet.sh run_stale_recycled the pid is alive and is somebody
#                                         else's -- a `kill -9` left the pidfile
#                                         and the OS wrapped round -> it starts.
#                                         `kill -0` alone would refuse to start
#                                         the fleet at all, forever, on the
#                                         strength of a stranger.
#   test_orca_fleet.sh run_stale_gone     the process is simply gone -> it
#                                         starts.
#
# ...and the same question asked in the two other places this file reads that
# pidfile, because a `status` that says `running` while `run` starts anyway is
# two screens disagreeing about whether the fleet is up -- and `stop --now` is
# the one place the fleet SIGNALS a pid it read out of a file.
#
#   test_orca_fleet.sh status_recycled    the pid is a stranger's -> `idle`.
#   test_orca_fleet.sh stop_spares_stranger
#                                         ...and `stop --now` does not signal
#                                         it, and says why.
#   test_orca_fleet.sh stop_stops_dispatcher
#                                         the control: a real one still goes.
#
# ...and the THIRD answer, which is not "no": a `ps` that will not answer at all
# -- no procps in the container, a launch shape whose argv never carried the
# script path. The two callers want opposite things from it, and collapsing it
# into "no" rebuilds #179 inside the check for it: `--now` would interrupt every
# agent, announce there was no dispatcher, leave it polling, and let the next
# `run` start a second one.
#
#   test_orca_fleet.sh run_blind_ps       it starts -- one stale file may not
#                                         hold the fleet down -- and WARNS,
#                                         naming the pid.
#   test_orca_fleet.sh status_blind_ps    ...and `status` says so rather than
#                                         `idle`, which is the line that sends
#                                         somebody to start the second one.
#   test_orca_fleet.sh stop_blind_ps      ...and `--now` signals it anyway,
#                                         because it promises the dispatcher is
#                                         down when it returns.
#
# ...and the two states a stop can be in, which used to be one (#183). A drain
# waits for the PRs in flight to merge, and the file it wrote was the same file
# guard.py reads before it lets an agent push -- so it waited for PRs it had
# itself forbidden, and ended only when the time-box gave three worktrees up.
# `DRAIN` and `STOP` are now different files with different readers.
#
#   test_orca_fleet.sh drain_ends_on_merge
#                                         the acceptance, end to end and against
#                                         a real dispatcher: one worktree past
#                                         its time-box, kept because its PR is
#                                         open, a drain set WHILE it runs, and
#                                         then that PR merges -> the run ends on
#                                         the work landing, nothing is given up,
#                                         and no agent is interrupted. It used to
#                                         `break 2` out of the whole loop the
#                                         moment the file appeared mid-pass,
#                                         leaving the worktrees it held unreaped.
#   test_orca_fleet.sh drain_after_stop   a drain asked for while STOP is still
#                                         set changes nothing about the agents,
#                                         and says so. It used to print the full
#                                         "they are NOT frozen" reassurance over
#                                         a stop that had them frozen.
#   test_orca_fleet.sh stop_writes_drain  a drain writes DRAIN and NOT STOP.
#   test_orca_fleet.sh stop_now_writes_both
#                                         `--now` writes both: a hard stop is a
#                                         drain plus a freeze.
#   test_orca_fleet.sh drain_lets_agents_finish
#                                         THE issue, asserted against the real
#                                         .claude/hooks/guard.py: after a drain
#                                         that hook allows `git push` and
#                                         `gh pr create`, so the PRs the drain is
#                                         waiting on can actually land.
#   test_orca_fleet.sh stop_freezes_agents
#                                         ...and after `--now` it still refuses
#                                         both. The escape hatch is unchanged.
#   test_orca_fleet.sh drain_launches_nothing
#                                         the half a drain must KEEP: `run`
#                                         refuses with only DRAIN set.
#   test_orca_fleet.sh status_stopped     a hard stop says STOPPED, and does not
#                                         call itself a drain.
#   test_orca_fleet.sh resume_clears_both a resume that cleared one of the two
#                                         would leave a fleet nothing can start.
#   test_orca_fleet.sh stop_drain_blind_dispatcher
#                                         a dispatcher that predates DRAIN cannot
#                                         see one -> the drain WARNS and names
#                                         the pid, rather than looking set while
#                                         that dispatcher keeps launching.
#
# The Orca CLI and gh are stubbed on PATH; the fleet state dir is a temp dir.
# Nothing here touches a real worktree, docker, or GitHub.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }

WORK=""
# Whatever process the pidfile points at in the run_* phases -- a stand-in
# dispatcher, or the unrelated process a recycled pid lands on. Killed here so a
# failed assertion does not leave a `sleep` behind for half a minute.
HELD_PID=""
cleanup() {
  # The GROUP first: a backgrounded dispatcher is a subshell whose child is the
  # thing actually polling, and killing only the subshell leaves that child
  # orphaned with the suite waiting on its pipe.
  [ -n "$HELD_PID" ] && { kill -- -"$HELD_PID" 2>/dev/null || kill "$HELD_PID" 2>/dev/null; }
  [ -n "$WORK" ] && rm -rf "$WORK"
  return 0
}
trap cleanup EXIT

# $1 is the CLI stub's mode: ok, set_fails, set_noisy, rm_needs_force, rm_never_works,
# rm_hangs.
make_fixture() {
  WORK="$(mktemp -d)"; WORK="$(cd "$WORK" && pwd -P)"
  mkdir -p "$WORK/repo/scripts/fleet" "$WORK/bin"
  # The WHOLE payload: lib.sh sources config.sh and a runner driver.
  cp -R "$REPO_ROOT"/scripts/fleet/. "$WORK/repo/scripts/fleet/"
  # ready_issues imports it, and $ISSUE_REFS is derived from the repo root.
  mkdir -p "$WORK/repo/.github/scripts"
  cp "$REPO_ROOT/.github/scripts/issue_refs.py" "$WORK/repo/.github/scripts/"

  cat >"$WORK/bin/orca-stub" <<'STUB'
#!/usr/bin/env bash
mode="$(cat "$ORCA_MODE")"
printf '%s\n' "$*" >>"$ORCA_CALLS"
case "$1" in
  --version) echo "orca 0.0.0-test"; exit 0 ;;
esac
# Matched on the pair, because `list` alone is both `worktree list` and
# `terminal list` and the dispatcher asks for both.
case "$1 ${2:-}" in
  "worktree list")
    # The real CLI takes `--repo <selector>` and answers only that repo's
    # worktrees; without it the answer is machine-wide (#46). The fixture
    # carries a `repoPath` per entry so a phase can say "this one belongs to
    # some other repo", and this reproduces the filter rather than restating
    # its outcome. An entry with no `repoPath` belongs to whatever was asked
    # for, so every fixture written before the scope existed still answers.
    sel=""
    for arg in "$@"; do
      case "$arg" in path:*) sel="${arg#path:}" ;; esac
    done
    # A `path:` that is not a repo ROOT -- a worktree of it, say -- is what the
    # real CLI refuses, and refusing it here is what lets a phase catch a caller
    # that passes the wrong one. $ORCA_REPO_ROOTS lists the paths that resolve;
    # empty means every selector does, which is what fixtures written before
    # this arm existed assume.
    if [ -n "$sel" ] && [ -s "${ORCA_REPO_ROOTS:-/dev/null}" ] \
       && ! grep -qxF "$sel" "$ORCA_REPO_ROOTS"; then
      echo '{"ok": false, "error": {"code": "repo_not_found", "message": "repo_not_found"}}'
      exit 1
    fi
    ORCA_REPO_SELECTOR="$sel" python3 -c '
import json, os, sys
doc = json.load(open(sys.argv[1]))
sel = os.environ.get("ORCA_REPO_SELECTOR", "")
if sel:
    doc["result"]["worktrees"] = [
        w for w in doc["result"]["worktrees"] if w.get("repoPath", sel) == sel]
print(json.dumps(doc))
' "$ORCA_WORKTREES"
    exit 0 ;;
  # A create that SUCCEEDS, so the negative case terminates on --max-prs rather
  # than looping on "leaving it in the queue to try again".
  #
  # ...and that APPEARS IN THE LIST afterwards, which a real one does. While it
  # did not, no test could reach the cache invalidation in `launch` -- the line
  # carrying the whole within-a-pass half of "a foundation issue lands alone" --
  # because the worktree a pass opened was invisible to the next `live_worktrees`
  # in that same pass. Delete that line and the suite stayed green while the
  # dispatcher went back to opening #1, #4 and #7 in eleven seconds. Found by the
  # independent review of the change that added it.
  "worktree create")
    # On STDERR, where a CLI actually reports a failure -- a stub that printed it
    # on stdout would pass a driver that drops stderr on the floor, which is the
    # regression this mode exists for. Same reasoning as the `set` branch below.
    [ "$mode" = create_fails ] && {
      echo "fatal: a branch named '44-a-second-issue' already exists" >&2; exit 1; }
    # A create that SUCCEEDS and is chatty on stderr -- a relayed git
    # `Preparing worktree`, a keychain warning. The JSON still has to parse.
    [ "$mode" = create_warns ] && echo "Preparing worktree (new branch '44-x')" >&2
    for a in "$@"; do case "$prev" in --issue) created_issue="$a" ;; esac; prev="$a"; done
    python3 - "$ORCA_WORKTREES" "${created_issue:-}" "$WORK_FOR_STUB/created" <<'PYWT'
import json, os, sys
path, issue, where = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    doc = json.load(open(path))
except Exception:
    doc = {"result": {"worktrees": []}}
doc.setdefault("result", {}).setdefault("worktrees", []).append(
    {"linkedIssue": (None if os.environ.get("ORCA_CREATE_UNLINKED") else issue),
     "path": where + "-" + (issue or "x")})
json.dump(doc, open(path, "w"))
PYWT
    echo "{\"result\":{\"worktree\":{\"path\":\"$WORK_FOR_STUB/created\"}}}"; exit 0 ;;
  "worktree ps")   cat "$ORCA_PS"; exit 0 ;;
  "terminal list") cat "$ORCA_TERMINALS"; exit 0 ;;
  "terminal send") echo '{"ok":true}'; exit 0 ;;
esac
target=""
for arg in "$@"; do
  case "$arg" in path:*) target="${arg#path:}" ;; esac
done
case "$2" in
  set)
    # On STDERR, where a CLI actually reports a failure. The point of the check
    # under test is that the reason reaches the log, and a stub that printed it
    # on stdout would pass a card() that drops stderr on the floor.
    [ "$mode" = set_fails ] && { echo "Unable to determine Orca.app path from symlink" >&2; exit 1; }
    # BOTH STREAMS, so the ORDER is testable. A CLI that prints an error object
    # on stdout and its reason on stderr is exactly the case the three-line bound
    # exists for: merged, the stdout object arrives first and pushes the reason
    # past line three. `runner_worktree_create` was given a separate `$err` and a
    # stderr-first relay for that; `runner_worktree_set` was given the same
    # shape, and nothing drove it -- the stub above writes to stderr ONLY, so
    # merged and stderr-first were indistinguishable and reverting the hunk left
    # the suite green. Found by the independent review.
    [ "$mode" = set_noisy ] && {
      echo '{"error":{"code":1,'
      echo '  "detail": "a runtime that narrates on stdout",'
      echo '  "more": "three lines of it, which is the whole budget",'
      echo '  "and": "a fourth"}'
      echo "the real reason: worktree is not registered" >&2
      exit 1; }
    echo '{"ok":true}'; exit 0 ;;
  rm)
    # A CLI that is there but never answers -- Orca.app restarting. The
    # dispatcher's deadline is what ends this, and the result is "could not ask",
    # which is not a decision about the worktree.
    [ "$mode" = rm_hangs ] && { sleep 30; exit 1; }
    case " $* " in *" --force "*) forced=1 ;; *) forced=0 ;; esac
    if [ "$mode" = rm_never_works ] || { [ "$mode" = rm_needs_force ] && [ "$forced" = 0 ]; }; then
      echo "fatal: working trees containing submodules cannot be moved or removed" >&2
      exit 1
    fi
    rm -rf "$target"; echo '{"ok":true}'; exit 0 ;;
esac
echo '{"ok":true}'
STUB
  chmod +x "$WORK/bin/orca-stub"

  cat >"$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALLS"
case "$*" in
  # reap_merged asking whether this branch's PR merged. The other `pr list` is
  # has_open_pr, which parses JSON -- answering `7` there is a parse failure,
  # which the dispatcher reads as "could not tell" rather than as "no PR".
  *"pr list --head"*) cat "$GH_MERGED"; exit 0 ;;
  *"pr list"*)        cat "$GH_PRS"; exit 0 ;;
  *"issue list"*)     cat "$GH_ISSUES"; exit 0 ;;
  # gh applies --jq itself, so the stub answers what the filter would produce.
  # The literal FAIL stands for a gh that could not answer at all -- the third
  # answer the dispatcher is built around.
  #
  # State and labels come back from ONE call, so this branch has to sit above the
  # `--json state` one below: `--json state,labels` matches both patterns, and
  # the wrong one would answer a bare OPEN with no labels in it at all.
  *"issue view"*"--json state,labels"*)
    [ "$(cat "$GH_LABELS")" = FAIL ] && { echo "gh: could not connect" >&2; exit 1; }
    printf '%s\t%s\n' "$(cat "$GH_STATE")" "$(cat "$GH_LABELS")"; exit 0 ;;
  *"issue view"*"--json state"*) cat "$GH_STATE"; exit 0 ;;
  *"issue comment"*)  exit 0 ;;
esac
echo ""
STUB
  chmod +x "$WORK/bin/gh"

  # A `ps` that can be blinded. Not "ps says this is not a dispatcher" -- ps says
  # NOTHING, which is what a container without procps, or a launch shape whose
  # argv never carried the script path, actually looks like. dispatcher_alive
  # has to keep that apart from a definite no, because `run` and `stop --now`
  # want opposite things from it.
  cat >"$WORK/bin/ps" <<'STUB'
#!/usr/bin/env bash
[ -s "$PS_BLIND" ] && exit 1
exec /bin/ps "$@"
STUB
  chmod +x "$WORK/bin/ps"
  PS_BLIND="$WORK/ps-blind"; : >"$PS_BLIND"
  export PS_BLIND

  # cmd_run ends in notify(); a test suite must not put banners on the screen.
  printf '#!/usr/bin/env bash\nexit 0\n' >"$WORK/bin/osascript"
  chmod +x "$WORK/bin/osascript"

  # The sweep the removal now runs ITSELF, because it no longer asks the Orca CLI
  # to run the archive hook (#163). Stubbed rather than real: the real one talks
  # to docker, and what these tests are about is WHEN it is called, not what it
  # tears down.
  cat >"$WORK/repo/scripts/fleet/reap.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$REAP_CALLS"
exit 0
STUB
  chmod +x "$WORK/repo/scripts/fleet/reap.sh"

  ORCA_CALLS="$WORK/calls"; : >"$ORCA_CALLS"
  REAP_CALLS="$WORK/reap-calls"; : >"$REAP_CALLS"
  ORCA_MODE="$WORK/mode"; printf '%s' "${1:-ok}" >"$ORCA_MODE"
  GH_CALLS="$WORK/gh-calls"; : >"$GH_CALLS"
  # The defaults are the quiet answers: no agent running, no terminal, no open
  # PR, no labels. Each test overrides only the one it is about.
  ORCA_PS="$WORK/ps";               echo '{"result":{"worktrees":[]}}' >"$ORCA_PS"
  ORCA_WORKTREES="$WORK/wtlist";    echo '{"result":{"worktrees":[]}}' >"$ORCA_WORKTREES"
  # Which `path:` selectors the stub CLI resolves. Empty is "all of them", so
  # only a phase that is ABOUT the selector has to say anything.
  ORCA_REPO_ROOTS="$WORK/repo-roots"; : >"$ORCA_REPO_ROOTS"
  ORCA_TERMINALS="$WORK/terminals"; echo '{"result":{"terminals":[]}}' >"$ORCA_TERMINALS"
  GH_PRS="$WORK/prs";               echo '[]' >"$GH_PRS"
  GH_ISSUES="$WORK/issues";         echo '[]' >"$GH_ISSUES"
  GH_LABELS="$WORK/labels";         : >"$GH_LABELS"
  GH_STATE="$WORK/state";           echo OPEN >"$GH_STATE"
  # What `gh pr list --head <branch> --state merged` finds. `7` is the answer
  # reap_merged acts on, and the default the removal tests are written against;
  # a test about the OTHER reap empties it, or reap_merged gets there first.
  GH_MERGED="$WORK/merged";         echo 7 >"$GH_MERGED"
  WORK_FOR_STUB="$WORK"; mkdir -p "$WORK/created"
  export ORCA_CALLS ORCA_MODE GH_CALLS ORCA_PS ORCA_WORKTREES ORCA_TERMINALS \
         ORCA_REPO_ROOTS \
         GH_PRS GH_ISSUES GH_LABELS GH_STATE GH_MERGED WORK_FOR_STUB REAP_CALLS
  # cmd_run sleeps between passes; a test that reached one would otherwise sit
  # for a minute before failing.
  export AUTOFLEET_POLL=1
  export ORCA_CLI_COMMAND="$WORK/bin/orca-stub"
  export AUTOFLEET_DIR="$WORK/fleet"
  PATH="$WORK/bin:$PATH"
  export PATH
}

# A worktree the fleet would own: a git repo with one commit, and an owned-file
# naming it.
make_worktree() {
  mkdir -p "$WORK/wt"
  git -C "$WORK/wt" init -q -b work
  git -C "$WORK/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  mkdir -p "$AUTOFLEET_DIR/worktrees"
  printf '%s\n' "$WORK/wt" >"$AUTOFLEET_DIR/worktrees/42"
}

# The agent Orca reports for the worktree, and the terminal the time-box would
# interrupt. Written as files so the stub answers the same thing every call.
agent_state() {
  python3 -c '
import json, sys
print(json.dumps({"result": {"worktrees": [
    {"path": sys.argv[1], "agents": [{"state": sys.argv[2]}]}]}}))
' "$WORK/wt" "$1" >"$ORCA_PS"
  python3 -c '
import json, sys
print(json.dumps({"result": {"terminals": [
    {"handle": "t1", "worktreePath": sys.argv[1], "agentIdentity": "claude"}]}}))
' "$WORK/wt" >"$ORCA_TERMINALS"
}

# A live worktree the dispatcher owns, linked to issue $1, at the path every
# other helper here calls `$WORK/wt`. `live_worktrees` reads `linkedIssue`,
# which is the field the foundation check keys on -- a fixture that set only
# `path` would make every issue answer "-" and the check vacuously true.
#
# Delegated rather than written out: two writers disagreed on the TYPE of
# `linkedIssue` (a string here, an int there), and a fixture that differs from
# the one every other phase uses can hide a real parsing bug. Found by the local
# review.
worktree_on_issue() { worktree_list "$1:wt"; }

# The worktree listing Orca answers, from `issue:path-suffix` pairs -- `-` for a
# worktree linked to no issue, and a third field naming a repo other than the
# fixture's. `worktree_on_issue` is the one-entry form and stays; this is what a
# machine running two fleets looks like, which is the case #46 is about.
worktree_list() {
  local spec; spec="$(printf '%s\n' "$@")"
  WORKTREE_SPEC="$spec" WORKTREE_WORK="$WORK" python3 -c '
import json, os
out = []
for line in os.environ["WORKTREE_SPEC"].splitlines():
    if not line.strip():
        continue
    parts = line.split(":")
    num, suffix = parts[0], parts[1]
    repo = parts[2] if len(parts) > 2 else "repo"
    work = os.environ["WORKTREE_WORK"]
    out.append({"path": work + "/" + suffix,
                "linkedIssue": None if num == "-" else int(num),
                "repoPath": work + "/" + repo,
                "isMainWorktree": False, "isArchived": False})
print(json.dumps({"result": {"worktrees": out}}))
' >"$ORCA_WORKTREES"
}

# The two halves of what one `gh issue view N --json state,labels` would print.
issue_labels() { printf '%s' "$1" >"$GH_LABELS"; }
issue_state()  { printf '%s' "$1" >"$GH_STATE"; }

# An `origin` whose `main` is this worktree's HEAD, and a `work` branch tracking
# it. The release check asks what the worktree holds that origin/main does not,
# so a worktree with no origin at all is the "could not tell" case rather than
# the empty one -- which is why every test that expects a removal sets this up.
add_origin() {
  git init -q --bare "$WORK/origin.git"
  git -C "$WORK/wt" remote add origin "$WORK/origin.git"
  git -C "$WORK/wt" push -q origin work:main
  git -C "$WORK/wt" push -q -u origin work
}

# The same thing for a worktree the run itself opened, whose path the phase does
# not know until the log says so. `add_origin` is hardcoded to $WORK/wt, and
# `reap_merged` gives up at `rev-parse --abbrev-ref HEAD` on a directory that is
# not a git repo -- so a launched worktree was unreapable and any phase that
# waited for one to land waited forever, for a reason that had nothing to do with
# what it was testing.
reapable_worktree_at() {
  local path="$1" bare="$WORK/origin-$(basename "$path").git"
  git init -q -b work "$path"
  git -C "$path" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git init -q --bare "$bare"
  git -C "$path" remote add origin "$bare"
  git -C "$path" push -q origin work:main
  git -C "$path" push -q -u origin work
}

# Nothing this dispatcher may throw away: an untracked file, or a commit that is
# nowhere but here.
dirty_worktree()  { echo scratch >"$WORK/wt/notes.txt"; }
commit_ahead()    { git -C "$WORK/wt" -c user.email=t@t -c user.name=t \
                        commit -q --allow-empty -m "work in progress"; }

# No reason to release, and the reap must find none: an open issue, no merged PR
# for the branch, and nothing the fleet has given up on.
quiet_issue() { issue_state OPEN; issue_labels "ready"; : >"$GH_MERGED"; }

# A release takes TWO passes on purpose: the first warns and interrupts, the
# second re-asks what the worktree holds and only then removes it. Tests about
# the removal drive both; tests about the warning, or about a worktree that is
# kept, drive one.
release_pass()      { in_fleet reap_abandoned 2>&1; }
warn_then_release() { release_pass >/dev/null 2>&1; release_pass; }

# An issue that is past its box with no PR open: the started marker is old, and
# the PR listing is empty.
make_overdue() { mkdir -p "$AUTOFLEET_DIR/started"; echo 0 >"$AUTOFLEET_DIR/started/42"; }

# All three markers enforce_timebox owns, set the way the dispatcher sets them
# -- by driving it through the polls that write each one. Setting them by hand
# would assert against a state the code may never produce.
BOX_MARKERS="unreachable box-labels human-step"
# The order is forced: the exemption branch clears `unreachable-` and
# `box-labels-` on its way past, so `human-step-` has to be armed before them.
arm_box_markers() {
  # No PR, and the label says the last step is a person's -> `human-step-`.
  echo '[]' >"$GH_PRS"; issue_labels "ready,needs-human-step"
  in_fleet enforce_timebox >/dev/null 2>&1
  # A PR lookup that cannot answer -> `unreachable-`.
  echo 'not json' >"$GH_PRS"
  in_fleet enforce_timebox >/dev/null 2>&1
  # It answers again, and now the LABEL lookup cannot -> `box-labels-`.
  echo '[]' >"$GH_PRS"; issue_labels FAIL
  in_fleet enforce_timebox >/dev/null 2>&1
  local m
  for m in $BOX_MARKERS; do
    [ -e "$AUTOFLEET_DIR/$m-42" ] \
      || fail "could not arm $m-42, so the assertion that follows would be vacuous"
  done
}
assert_no_box_markers() {
  local m
  for m in $BOX_MARKERS; do
    [ -e "$AUTOFLEET_DIR/$m-42" ] \
      && fail "$m-42 survives $1, and it silences the next worktree for this issue"
  done
  return 0
}

# fleet.sh returns instead of dispatching when it is sourced, so one function can
# be exercised without starting a dispatcher.
#
# ONE CALL IS ONE PASS, which is why the poll cache is emptied first. `cmd_run`
# empties it at the top of every pass and nothing else does -- sourcing fleet.sh
# used to empty it too, and #35 is the bug that was: `status`, `stop`, `retry`
# and `resume` each wiped a live dispatcher's cache mid-pass. Removing that
# source-time call left this helper carrying a cache from one `in_fleet` to the
# next, so a phase that changed an issue's labels between two calls read the
# first call's answer and seven of them failed for a reason that had nothing to
# do with what they were testing.
#
# `in_poll` below deliberately does NOT do this: its whole point is several
# watchers inside ONE pass, sharing the per-poll answers the way a real poll
# does. The two helpers model the two scopes, and that distinction is now what
# the cache's lifetime means.
in_fleet() {
  rm -rf "$AUTOFLEET_DIR/poll-cache"
  in_fleet_keeping_cache "$@"
}

# ...and the raw form, for the one phase whose subject IS the cache's survival.
# `status_keeps_cache` asserts that `cmd_status` leaves the poll cache alone, so
# running it through a helper that empties the cache first would assert nothing
# at all.
in_fleet_keeping_cache() { (cd "$WORK/repo" && . ./scripts/fleet/fleet.sh && "$@"); }

# A runner driver that is NOT Orca: plain files, no CLI, nothing that could
# reach the app even if it were running. Everything the fleet knows about
# worktrees, agents and terminals has to arrive through the functions below, so
# a callsite that still reaches for `orca` produces a dispatcher that
# cannot see its own worktrees -- or, with the `orca` planted on PATH beside it,
# a recorded call that was not supposed to happen.
#
# Deliberately the shape a tmux + `git worktree` driver would have, down to the
# three-way answers: `could not tell` here is a missing backing file rather than
# a deadline, but the codes the dispatcher reads are the same ones.
stub_runner() {
  STUB_DIR="$WORK/stub"
  mkdir -p "$STUB_DIR"
  : >"$STUB_DIR/worktrees"; : >"$STUB_DIR/states"; : >"$STUB_DIR/terminals"
  STUB_CALLS="$STUB_DIR/calls"; : >"$STUB_CALLS"
  export STUB_DIR STUB_CALLS
  cat >"$WORK/repo/scripts/fleet/runner/stub.sh" <<'STUBDRIVER'
#!/usr/bin/env bash
# A runner backed by text files. Records every call it is asked to make.
#
# runner_agent_terminal is NOT here: lib.sh provides it over
# runner_agent_terminals, and a copy would test the copy.
stub_say() { printf '%s\n' "$*" >>"$STUB_CALLS"; }

runner_available()       { stub_say available; return 0; }
runner_dispatcher_hint() { echo "tmux new-session -s fleet"; }
runner_set_deadline()    { stub_say "set deadline $1"; return 0; }

runner_worktree_create() {
  local name="$2" issue="$3" path="$STUB_DIR/wt-$3"
  stub_say "worktree create $name $issue"
  # A failure path, which this stub did not have -- so the contract's "the
  # runtime's own words on failure, on STDOUT" was asserted only against the
  # Orca CLI stub, by `create_says`. On stdout deliberately: `launch` captures
  # stdout only, and a driver that answers on stderr reproduces "could not
  # create it:" followed by nothing. Found by the independent review.
  [ -e "$STUB_DIR/create-fails" ] && { echo "the stub refuses to create"; return 1; }
  mkdir -p "$path"
  printf '%s\t%s\t%s\n' "$path" "$name" "$issue" >>"$STUB_DIR/worktrees"
  printf '%s\n' "$path"
}
runner_worktree_list()  { stub_say "worktree list"; cat "$STUB_DIR/worktrees"; }
runner_worktree_issue() {
  stub_say "worktree issue"
  # 1 is "the runtime would not say", 2 is "there is no linked issue". Three
  # answers, because a caller that reads 1 as 2 announces that a worktree the
  # fleet linked to an issue has none.
  [ -e "$STUB_DIR/blind" ] && return 1
  [ -s "$STUB_DIR/issue" ] || return 2
  cat "$STUB_DIR/issue"
}
runner_worktree_set() {
  stub_say "worktree set $*"
  # Answered and REFUSED, which is the branch board.sh's loud refusal is for.
  [ -e "$STUB_DIR/set-fails" ] && { echo "the stub refuses"; return 1; }
  return 0
}
runner_worktree_remove() {
  stub_say "worktree remove $1"
  # 2 is "nobody answered", 1 is "answered and refused". The dispatcher parks a
  # slot on 1 and retries on 2, so a driver that returns the wrong one costs a
  # worktree for good.
  [ -e "$STUB_DIR/rm-blind" ]   && return 2
  [ -e "$STUB_DIR/rm-refuses" ] && { echo "the stub refuses"; return 1; }
  rm -rf "$1"
  [ -d "$1" ] && return 1
  return 0
}
runner_agent_states()    { stub_say "agent states";    cat "$STUB_DIR/states"; }
runner_agent_terminals() {
  stub_say "agent terminals"
  # Non-zero is "the listing could not be READ", which is not the same answer as
  # an empty listing -- and every caller of it has to keep them apart.
  [ -e "$STUB_DIR/term-blind" ] && return 1
  cat "$STUB_DIR/terminals"
}
runner_terminal_draft() {
  stub_say "terminal draft $1"
  [ -s "$STUB_DIR/draft" ] || return 0
  printf '%s %s\n' "$(wc -c <"$STUB_DIR/draft" | tr -d ' ')" "$(cat "$STUB_DIR/draft")"
}
runner_terminal_send()      { stub_say "terminal send $1";      return 0; }
runner_terminal_enter()     { stub_say "terminal enter $1";     return 0; }
runner_terminal_interrupt() { stub_say "terminal interrupt $1"; return 0; }
STUBDRIVER
  export AUTOFLEET_RUNNER=stub
}

# What .claude/hooks/guard.py answers about one command, against THIS phase's
# fleet dir: 0 allowed, 2 blocked.
#
# The real hook, not a copy of its rule. The whole of #183 is what TWO programs
# do with the same directory -- fleet.sh writes, guard.py reads -- and a test
# that restated guard.py's rule here would have gone on passing through the
# entire bug. Run from $WORK, which is not a git repo and so is not a worktree
# the fleet owns: the review-marker gate is a different rule and would otherwise
# answer for this one.
guard_says() {
  local payload
  payload="$(python3 -c '
import json, sys
print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}}))
' "$1")"
  ( cd "$WORK" && printf '%s' "$payload" \
      | AUTOFLEET_DIR="$AUTOFLEET_DIR" \
        python3 "$REPO_ROOT/.claude/hooks/guard.py" >/dev/null 2>&1 )
  printf '%s' "$?"
}

# Both watchers in ONE process, which is what a real poll is: they share the
# per-poll answer cache and the state dir, and only there can one of them undo
# what the other just wrote.
in_poll() { (cd "$WORK/repo" && . ./scripts/fleet/fleet.sh; for fn in "$@"; do "$fn"; done); }

# The fixture repo under git, because "which fixes are not live in the running
# dispatcher" is answered in commits and cannot be faked with a hash alone.
make_repo_git() {
  git -C "$WORK/repo" init -q -b main
  git -C "$WORK/repo" -c user.email=t@t -c user.name=t add -A
  git -C "$WORK/repo" -c user.email=t@t -c user.name=t commit -q -m "the fleet as the dispatcher parsed it"
}

# A commit that changes fleet.sh under a dispatcher that is already up. A
# trailing comment, so the file the test itself sources still behaves.
merge_fleet_fix() {
  printf '# %s\n' "$1" >>"$WORK/repo/scripts/fleet/fleet.sh"
  git -C "$WORK/repo" -c user.email=t@t -c user.name=t commit -q -am "$1"
}

# The pidfile, naming whatever pid the phase wants it to name.
hold_pidfile() { mkdir -p "$AUTOFLEET_DIR"; printf '%s\n' "$1" >"$AUTOFLEET_DIR/fleet.pid"; }

# A live process that LOOKS like a dispatcher, and a pidfile naming it. The
# fleet asks `ps -o command=` as well as `kill -0` before it believes a pidfile
# -- before it refuses a second `run`, before `status` says `running`, and
# before `stop --now` SIGNALs -- so a stand-in needs a real command line and not
# just a pid. `bash <path>/fleet.sh run --auto` is what ps prints for the
# dispatcher this machine is running now.
hold_pidfile_with_dispatcher() {
  mkdir -p "$WORK/other/scripts/fleet"
  # A loop of short sleeps rather than one long one: cleanup kills this bash,
  # and whatever it is blocked in is orphaned rather than killed with it. A
  # `sleep 30` left holding the inherited stdout is 30 seconds ctest spends
  # waiting for a test that finished -- which is also why it is redirected.
  printf '#!/usr/bin/env bash\nfor _ in $(seq 60); do sleep 1; done\n' \
    >"$WORK/other/scripts/fleet/fleet.sh"
  chmod +x "$WORK/other/scripts/fleet/fleet.sh"
  bash "$WORK/other/scripts/fleet/fleet.sh" run --auto >/dev/null 2>&1 &
  HELD_PID=$!
  # Off the job table, or bash announces "Terminated" on stderr when cleanup
  # kills it and a passing test looks like a broken one.
  disown "$HELD_PID" 2>/dev/null
  hold_pidfile "$HELD_PID"
  # A stand-in ps would not recognise makes every assertion after it vacuous --
  # the fleet would answer "no dispatcher" for the ordinary reason and the
  # phases that assert a refusal would pass without one.
  ps -o command= -p "$HELD_PID" 2>/dev/null | grep -q 'fleet\.sh run' \
    || fail "the stand-in dispatcher does not look like one to ps; every assertion below would be vacuous"
}

# What the status_ phases mean by "a dispatcher is up". It is the real thing
# now, and it has to be: `status` no longer believes a pid it cannot also see
# running a dispatcher, so a bare `echo $$` here would report `idle` and every
# staleness assertion would be about a screen that never printed.
dispatcher_running() { hold_pidfile_with_dispatcher; }

# A pid that is alive and is NOT a dispatcher: what a pidfile a `kill -9` left
# behind turns into once the OS wraps round and hands the number to somebody
# else. Killing THIS is the thing `stop --now` must not do.
hold_pidfile_with_stranger() {
  sleep 30 &
  HELD_PID=$!
  disown "$HELD_PID" 2>/dev/null
  hold_pidfile "$HELD_PID"
  ps -o command= -p "$HELD_PID" 2>/dev/null | grep -q 'fleet\.sh' \
    && fail "the stranger looks like a dispatcher; the phase would assert nothing"
  return 0
}

# ...and a pid nothing holds at all: started, reaped, and gone before it is used.
hold_pidfile_with_ghost() {
  sleep 0 &
  local gone=$!
  wait "$gone" 2>/dev/null
  kill -0 "$gone" 2>/dev/null && fail "the ghost pid is still alive; the phase would assert nothing"
  hold_pidfile "$gone"
}

# `cmd_run` in list mode against an issue that has already landed: one pass, no
# sleep, and it comes back. Every run_ phase goes through this, the refusing one
# included -- `--auto` would sit polling until CTest's timeout if the refusal
# ever regressed, and a phase that fails by hanging says far less than one that
# fails by returning.
run_one_pass() { issue_state CLOSED; in_fleet cmd_run 42 2>&1; }

# ...from here on. Armed AFTER the stand-in dispatcher is made, because making
# one asserts that ps can see it.
blind_ps() { printf '1\n' >"$PS_BLIND"; }

# `kill` returns once the signal is delivered, not once the target is gone, so
# the assertion that it went waits rather than races it.
pid_gone() {
  local i=0
  while [ "$i" -lt 50 ]; do
    kill -0 "$1" 2>/dev/null || return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

# A line the running dispatcher has printed, waited for rather than raced. Ten
# seconds against a one-second poll: the phases that use it drive a real
# dispatcher through two passes, and a fixed sleep would either be flaky or be
# most of the suite's runtime.
wait_for_log() {
  local i=0
  while [ "$i" -lt 100 ]; do
    grep -q "$1" "$WORK/run.log" 2>/dev/null && return 0
    sleep 0.1; i=$((i + 1))
  done
  fail "the dispatcher never said '$1': $(cat "$WORK/run.log" 2>/dev/null)"
}

# A real dispatcher in its OWN PROCESS GROUP, and the way to stop it again.
#
# `cmd_stop` cannot: the dispatcher records `$$`, and inside the subshell
# `in_fleet` runs that is the PHASE's pid, not the dispatcher's -- so a phase
# that stops it by the book kills something else and leaves an orphan polling
# forever. Harmless to the phase, which has already asserted and exited 0, and
# not harmless to `./tests/run.sh`, which then waits on a pipe nothing will
# close. Two phases hung the suite that way before this existed.
#
# `set -m` puts the job in its own group so `kill -- -PID` reaches every process
# in it. Only phases that let the dispatcher LAUNCH something need this; a drain
# that owns nothing still ends on its own, which is what `run_ended` is for.
start_dispatcher() {
  set -m
  in_fleet cmd_run "$@" >"$WORK/run.log" 2>&1 &
  HELD_PID=$!
  set +m
}

stop_dispatcher() {
  [ -n "$HELD_PID" ] || return 0
  kill -- -"$HELD_PID" 2>/dev/null || kill "$HELD_PID" 2>/dev/null
  HELD_PID=""
}

# ...and its exit, which is the thing a drain is supposed to reach on its own.
run_ended() {
  local i=0
  while [ "$i" -lt 200 ]; do
    kill -0 "$1" 2>/dev/null || return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

# fleet.sh sourced from somewhere OTHER than the dispatcher's own checkout --
# what an agent in a fleet worktree runs.
in_fleet_at() { local at="$1"; shift; (cd "$at" && . ./scripts/fleet/fleet.sh && "$@"); }

# A second checkout of the fixture repo, pinned to the commit the dispatcher
# started from: a worktree branched before the fix landed.
older_checkout() {
  git -C "$WORK/repo" worktree add -q --detach "$WORK/wt2" "$1"
}

# The fix merged and pushed, with the dispatcher's own checkout left exactly
# where it was: `origin/main` moves, the file on disk does not. Nothing in the
# fleet pulls it, so this is what a merge during a run actually looks like.
merged_but_not_pulled() {
  local parked; parked="$(git -C "$WORK/repo" rev-parse HEAD)"
  git -C "$WORK/repo" init -q --bare "$WORK/repo-origin.git" 2>/dev/null
  git -C "$WORK/repo" remote add origin "$WORK/repo-origin.git" 2>/dev/null
  git -C "$WORK/repo" push -q origin HEAD:main
  merge_fleet_fix "$1"
  git -C "$WORK/repo" push -q origin HEAD:main
  git -C "$WORK/repo" reset -q --hard "$parked"
}

# ...and then taken back out again, so `origin/main` holds two commits and the
# same bytes the dispatcher parsed.
revert_on_origin() {
  git -C "$WORK/repo" reset -q --hard origin/main
  git -C "$WORK/repo" -c user.email=t@t -c user.name=t revert --no-edit HEAD >/dev/null
  git -C "$WORK/repo" push -q origin HEAD:main
  git -C "$WORK/repo" reset -q --hard "$1"
}

case "${1:-}" in
  runner_unresolved)
    # A driver function called before anything probed the runtime. The fleet's
    # own scripts all call runner_available first, but the CONTRACT does not
    # oblige a caller to, and the driver used to answer that with
    # `ORCA_CLI: unbound variable` from four frames down -- which names a shell
    # variable rather than saying the app is not answering, and only on a script
    # running `set -u`, which is most of them. Found by smoke-testing the driver
    # from a bare shell.
    #
    # lib.sh rather than fleet.sh, and deliberately: fleet.sh resolves the runner
    # at source time, so through it this call can never be the first one. The
    # hooks that source lib.sh alone are where it can.
    make_fixture ok
    out="$( cd "$WORK/repo" && bash -c '
      set -uo pipefail
      REPO_ROOT="$PWD"
      . ./scripts/fleet/lib.sh
      runner_worktree_list >/dev/null; echo "list rc=$?"
      runner_agent_states  >/dev/null; echo "states rc=$?"
    ' 2>&1 )"
    grep -q "unbound variable" <<<"$out" \
      && fail "the driver died on a shell variable instead of answering: $out"
    grep -q "list rc=0" <<<"$out" \
      || fail "a driver call that resolved its own CLI still did not answer: $out"
    grep -q "states rc=0" <<<"$out" \
      || fail "a driver call that resolved its own CLI still did not answer: $out"

    # ...and the ONE function whose rc is not a plain yes/no. `orca_cli` answers
    # a failed resolve with 1 like every other call, and 1 through
    # `runner_worktree_remove` is the documented "answered and REFUSED" -- a
    # decision about this worktree, which the dispatcher parks a slot on rather
    # than retrying. So an Orca that is not running cost a worktree for good, in
    # the function added to stop exactly that kind of blindness.
    #
    # The resolve is stubbed out rather than starved: whether it can find a CLI
    # depends on the machine, and what is under test here is the MAPPING.
    mkdir -p "$WORK/still-here"
    out="$( cd "$WORK/repo" && bash -c '
      set -uo pipefail
      REPO_ROOT="$PWD"
      . ./scripts/fleet/lib.sh
      orca_cli_resolve() { return 1; }
      runner_worktree_remove "$1" 1; echo "here rc=$?"
      runner_worktree_remove "$2" 1; echo "gone rc=$?"
    ' _ "$WORK/still-here" "$WORK/never-existed" 2>&1 )"
    grep -q "^here rc=2$" <<<"$out" \
      || fail "a runner that could not be reached at all was reported as a refusal to remove this worktree, which parks its slot for good: $out"
    # ...and the other way: a worktree that is already gone IS gone, and saying
    # so needs no runtime. Answered 2 here and the reap cannot release a slot
    # with nothing left in it for as long as the app is down.
    grep -q "^gone rc=0$" <<<"$out" \
      || fail "a worktree that no longer exists was not reported as removed while the runner was unreachable: $out"

    # The arity refusal, which docs/RUNNERS.md promotes to the contract -- rc 2
    # means the CALLER is malformed -- and which nothing asserted in either
    # place. Delete the guard and `args` is empty; `"${args[@]}"` under `set -u`
    # on bash 3.2 is a fatal unbound variable INSIDE the driver, so the whole
    # `card` call dies differently and the suite stays green either way. Found by
    # the independent review.
    out="$( cd "$WORK/repo" && bash -c '
      set -uo pipefail
      REPO_ROOT="$PWD"
      . ./scripts/fleet/lib.sh
      orca_cli_resolve() { return 1; }
      runner_worktree_set /some/worktree;         echo "none rc=$?"
      runner_worktree_set /some/worktree comment; echo "odd rc=$?"
    ' 2>&1 )"
    grep -q "unbound variable" <<<"$out" \
      && fail "a malformed pair list killed the caller from inside the driver instead of being refused: $out"
    grep -q "^none rc=2$" <<<"$out" \
      || fail "a board update with no key/value pairs at all was not refused: $out"
    grep -q "^odd rc=2$" <<<"$out" \
      || fail "a key with no value was rounded down instead of refused, so the update silently did less than it was asked: $out"

    # ...and the one function that answered an unresolved CLI with a bare rc and
    # NO WORDS. `orca_cli` returns 1 from `orca_cli_resolve || return 1` before
    # anything is written to the stdout or stderr files the relay reads, so
    # `launch` printed "  could not create it:" and then nothing -- word for word
    # the message `create_says` exists to prevent, on the one path that phase
    # does not cover. Both neighbours already said why. Found by the independent
    # review.
    # STDERR IS DISCARDED, and that is the assertion rather than an accident:
    # `launch` captures stdout only (`fleet.sh:702`, `... >"$out"`), because
    # stdout is where the worktree path comes back. Capturing `2>&1` here passes
    # with the reason on either stream and pins nothing -- which is how the first
    # attempt at this fix shipped with the `echo` still going to stderr, and
    # `launch` still printing "could not create it:" and then nothing. Found by
    # the review of that fix; the same shape is asserted for
    # `runner_worktree_set`, whose caller `card` reads the same way.
    out="$( cd "$WORK/repo" && bash -c '
      set -uo pipefail
      REPO_ROOT="$PWD"
      . ./scripts/fleet/lib.sh
      orca_cli_resolve() { return 1; }
      runner_worktree_create "$PWD" name 42 agent prompt comment; echo "create rc=$?"
      runner_worktree_set "$PWD" workspace-status in-review;      echo "set rc=$?"
    ' 2>/dev/null )"
    grep -q "^create rc=1$" <<<"$out" \
      || fail "a create against an unreachable runner did not answer 1, which is what launch leaves the issue queued on: $out"
    grep -q "orca CLI" <<<"$out" \
      || fail "launch would print 'could not create it:' and then nothing: the driver's reason never reached the one stream launch captures: $out"
    grep -q "^set rc=1$" <<<"$out" \
      || fail "a board update against an unreachable runner did not answer 1: $out"
    [ "$(grep -c "orca CLI" <<<"$out")" = 2 ] \
      || fail "card would log 'board update FAILED' with no cause under it, for the same reason create did: $out"

    echo "ok: a driver call with nothing resolved answers, rather than dying on \$ORCA_CLI"
    ;;
  runner_stub)
    # THE acceptance for #1, and the only assertion that keeps holding once the
    # move has been made: with a driver that is not Orca, a dispatcher, a
    # worktree hook and the brief resolver all do their whole job, and the CLI
    # is never touched. Every callsite that regressed out from behind the driver
    # would show up here as a recorded `orca` call.
    make_fixture ok
    make_worktree
    add_origin
    stub_runner
    # An `orca` ON PATH as well as the one the fixture exports: the claim is that
    # nothing reaches for the CLI, not that nothing reaches for it by the one
    # name a test happened to set. Both record into $ORCA_CALLS.
    cp "$WORK/bin/orca-stub" "$WORK/bin/orca"

    printf '%s\t%s\t%s\n' "$WORK/wt" work 42 >"$STUB_DIR/worktrees"
    printf '%s\t%s\n' "$WORK/wt" waiting >"$STUB_DIR/states"
    printf '%s\t%s\n' t1 "$WORK/wt" >"$STUB_DIR/terminals"
    printf '%s\t%s\n' t2 "$WORK/repo" >>"$STUB_DIR/terminals"
    printf '42' >"$STUB_DIR/issue"
    printf 'read the issue and get to work' >"$STUB_DIR/draft"

    [ "$(in_fleet live_count)" = 1 ] \
      || fail "the dispatcher could not count its own worktrees through a non-Orca driver"

    # The stall watcher: the agent state and the board, one poll of each.
    issue_labels "ready"
    out="$(in_fleet notice_stalled 2>&1)"
    grep -q "waiting for input" <<<"$out" \
      || fail "the agent state never arrived through the driver: $out"
    grep -q "worktree set" "$STUB_CALLS" \
      || fail "the board update did not go through the driver: $(cat "$STUB_CALLS")"

    # The launch, and then the release: create, set, remove, sweep.
    in_fleet launch 44 "a second issue" >/dev/null 2>&1 \
      || fail "launch failed against a driver that answers everything"
    grep -q "worktree create" "$STUB_CALLS" \
      || fail "the worktree was not created through the driver: $(cat "$STUB_CALLS")"
    in_fleet interrupt_agent_in "$WORK/wt" >/dev/null 2>&1
    grep -q "terminal interrupt t1" "$STUB_CALLS" \
      || fail "the interrupt did not find this worktree's agent through the driver: $(cat "$STUB_CALLS")"
    out="$(in_fleet reap_merged 2>&1)"
    [ -d "$WORK/wt" ] && fail "the merged worktree was not removed through the driver: $out"
    grep -q -- "--yes" "$REAP_CALLS" \
      || fail "the stack of a worktree the driver really removed was never swept: $out"

    # ...and the two hooks that run INSIDE a worktree, which reach the runtime
    # by a different path and were the other half of the grep.
    out="$( cd "$WORK/repo" && GH_PAGER=cat ./scripts/fleet/issue-command.sh 2>&1 )"
    grep -q "Closes #42" <<<"$out" \
      || fail "issue-command.sh could not resolve this worktree's issue through the driver: $out"

    # ...and its THREE-WAY read, which is the branch this change added and the
    # one branch it did not assert. `|| true` mapped rc 1 ("the runtime would not
    # say") and rc 2 ("there is no linked issue") onto one empty `$ref`, so the
    # by-hand path reported the same thing for both. The stub answers 1 on
    # demand, and `agent-autostart.sh`'s sibling branch is already driven through
    # that same knob in both directions. Found by the independent review, whose
    # point was that this PR had fixed the same class twice already.
    : >"$STUB_DIR/blind"
    out="$( cd "$WORK/repo" && GH_PAGER=cat ./scripts/fleet/issue-command.sh 2>&1 )"; rc=$?
    rm -f "$STUB_DIR/blind"
    [ "$rc" != 0 ] \
      || fail "issue-command.sh claimed success with no issue resolved at all: $out"
    grep -q "would not say" <<<"$out" \
      || fail "a runner that could not answer was reported as a worktree with no linked issue, which is the conflation design note 2 is about: $out"
    # ...and the other answer still reads as itself.
    printf '' >"$STUB_DIR/issue"
    out="$( cd "$WORK/repo" && GH_PAGER=cat ./scripts/fleet/issue-command.sh 2>&1 )"
    printf '42' >"$STUB_DIR/issue"
    grep -q "would not say" <<<"$out" \
      && fail "a worktree that really has no linked issue was reported as a runner that would not answer: $out"
    out="$( cd "$WORK/repo" && AGENT_AUTOSTART_POLL_SECONDS=0 \
              ./scripts/fleet/agent-autostart.sh --once 2>&1 )"
    grep -q "sent." <<<"$out" \
      || fail "agent-autostart.sh could not read or submit the draft through the driver: $out"
    grep -q "terminal enter t2" "$STUB_CALLS" \
      || fail "the prompt was not submitted through the driver: $(cat "$STUB_CALLS")"
    grep -q "set deadline 20" "$STUB_CALLS" \
      || fail "the watcher's shorter deadline was not asked for through the contract, so only an Orca driver would honour it: $(cat "$STUB_CALLS")"

    # A worktree path with a BACKSLASH in it. `awk -v` reinterprets what it
    # assigns, so the comparison went false and the answer came back "there is no
    # agent in that worktree" -- which is indistinguishable from the truth, and
    # is `stop` never interrupting an agent plus a watcher that gives up with the
    # prompt unsent. Found by the independent review.
    weird="$STUB_DIR/we\\ird"
    printf '%s\t%s\n' t3 "$weird" >>"$STUB_DIR/terminals"
    [ "$(in_fleet runner_agent_terminal "$weird")" = t3 ] \
      || fail "a worktree path with a backslash in it has no agent, as far as the fleet can tell"
    # ...and the SAME filter in notice_stalled, which had the same defect and
    # would otherwise be a fix with no assertion. A worktree whose agent is
    # `waiting` is reported as not waiting, forever.
    printf '%s\t%s\n' "$weird" waiting >>"$STUB_DIR/states"
    mkdir -p "$weird"
    printf '%s\n' "$weird" >"$AUTOFLEET_DIR/worktrees/43"
    out="$(in_fleet notice_stalled 2>&1)"
    rm -f "$AUTOFLEET_DIR/worktrees/43"
    grep -q "#43 is waiting" <<<"$out" \
      || fail "an agent waiting in a worktree whose path has a backslash was reported as not waiting: $out"

    # Design note 2 of the issue, on the one function that has THREE answers:
    # "could not tell" and "there is none" must not reach a person as the same
    # sentence. They did for a year, and it cost three worktrees a night.
    : >"$STUB_DIR/blind"
    out="$( cd "$WORK/repo" && ./scripts/fleet/agent-autostart.sh --watch 2>&1 )"
    grep -q "would not say" <<<"$out" \
      || fail "a runner that could not answer was reported as a worktree with no linked issue: $out"
    rm -f "$STUB_DIR/blind"
    printf '' >"$STUB_DIR/issue"
    out="$( cd "$WORK/repo" && ./scripts/fleet/agent-autostart.sh --watch 2>&1 )"
    grep -q "no linked issue" <<<"$out" \
      || fail "a worktree that really has no linked issue stopped saying so: $out"
    printf '42' >"$STUB_DIR/issue"

    # A removal nobody answered is NOT a refusal. The dispatcher parks a slot for
    # good on a refusal and retries on silence, so this is a worktree lost per
    # runtime restart if the driver conflates them -- and `orca_cli` answering a
    # failed resolve with 1, like every other call, is exactly how it did.
    mkdir -p "$STUB_DIR/wt-blind"
    printf '%s\n' "$STUB_DIR/wt-blind" >"$AUTOFLEET_DIR/worktrees/44"
    : >"$STUB_DIR/rm-blind"
    out="$(in_fleet remove_worktree "$STUB_DIR/wt-blind" 2>&1)"; rc=$?
    rm -f "$STUB_DIR/rm-blind" "$AUTOFLEET_DIR/worktrees/44"
    [ "$rc" = 2 ] || fail "a removal nobody answered was not reported as 'could not ask' (rc $rc): $out"
    grep -q "not a refusal" <<<"$out" \
      || fail "it did not say the difference, which is the whole of it: $out"

    # Every `*-blind-` marker for an issue goes when a fresh worktree takes it,
    # whatever it is called -- including the name the marker had before the
    # runner seam, which a fleet upgraded mid-flight still has on disk.
    # Through a fleet directory with a SPACE in it, which is the whole reason the
    # glob line quotes everything except the `*`: bare, the path word-splits into
    # two operands that match nothing and every marker survives, silently.
    spaced="$WORK/my fleet"
    mkdir -p "$spaced"
    : >"$spaced/orca-blind-77"
    : >"$spaced/runner-blind-77"
    : >"$spaced/git-blind-77"
    ( cd "$WORK/repo" && AUTOFLEET_DIR="$spaced" bash -c \
        '. ./scripts/fleet/fleet.sh && clear_issue_markers 77' ) >/dev/null 2>&1
    for legacy in orca-blind-77 runner-blind-77 git-blind-77; do
      [ -e "$spaced/$legacy" ] \
        && fail "$legacy outlived the worktree that wrote it, and nothing will ever clear it"
    done

    # board.sh is the line issue-command.sh hands EVERY agent, so it is where the
    # seam is asserted by the brief rather than by the dispatcher.
    out="$( cd "$WORK/repo" && ./scripts/fleet/board.sh in-review "#42: PR #7" 2>&1 )" \
      || fail "board.sh could not set this worktree's card through the driver: $out"
    grep -q "worktree set $WORK/repo workspace-status in-review comment #42: PR #7" "$STUB_CALLS" \
      || fail "board.sh did not send the status and the comment in ONE call: $(cat "$STUB_CALLS")"

    # ...and the REFUSAL, which is the whole of what makes board.sh's written-down
    # $REPO_ROOT assumption acceptable rather than quiet: if the path the agent's
    # shell has does not match the one the runtime recorded, every update from
    # inside that worktree fails, and the answer to that is a card named as stale
    # rather than a board update reported and not made. Nothing drove this branch
    # -- the stub returned 0 unconditionally, so only board.sh:65 was ever
    # reached. Hard rule 3. Found by the independent review.
    : >"$STUB_DIR/set-fails"
    out="$( cd "$WORK/repo" && ./scripts/fleet/board.sh in-review "#42: PR #7" 2>&1 )" \
      && fail "a board update the runner REFUSED was reported as done, so the card is stale and nobody knows: $out"
    rm -f "$STUB_DIR/set-fails"
    grep -q "the card was NOT updated" <<<"$out" \
      || fail "board.sh did not name the card as stale, which is the only thing bounding the cost of its path assumption: $out"

    # Design note 2 again, on the callsite `stop --now` actually takes. An
    # unreadable listing and a machine with no agents on it printed the same
    # thing: "interrupting agents..." and then nothing. CLAUDE.md calls --now the
    # form that "also freezes the agents", so this is the log an operator reads
    # while three agents keep writing against a rig that is going down.
    printf '%s\n' "$WORK/wt" >"$AUTOFLEET_DIR/worktrees/42"
    : >"$STUB_DIR/term-blind"
    out="$(in_fleet cmd_stop --now 2>&1)"
    rm -f "$STUB_DIR/term-blind"
    grep -q "not the same as there being none" <<<"$out" \
      || fail "stop --now read a listing it could not read as 'there are no agents', so nobody was told none were interrupted: $out"
    in_fleet cmd_resume >/dev/null 2>&1
    # ...and the other way, so the message is not simply always printed: the same
    # stop with a listing that answers says nothing of the sort, and interrupts.
    out="$(in_fleet cmd_stop --now 2>&1)"
    in_fleet cmd_resume >/dev/null 2>&1
    rm -f "$AUTOFLEET_DIR/worktrees/42"
    grep -q "not the same as there being none" <<<"$out" \
      && fail "a listing that answered perfectly well was reported as unreadable: $out"
    grep -q "interrupted #42" <<<"$out" \
      || fail "stop --now did not interrupt the agent the listing names: $out"

    # ...and the contract's STREAM, against a driver that is not Orca. `launch`
    # captures stdout only, so a driver obeying docs/RUNNERS.md must answer
    # there; `create_says` asserts this against the Orca CLI stub, which leaves
    # the page's claim untested for everyone the page is written for.
    : >"$STUB_DIR/create-fails"
    out="$(in_fleet launch 45 "a third issue" 2>/dev/null)"
    rm -f "$STUB_DIR/create-fails"
    grep -q "could not create it" <<<"$out" \
      || fail "a create the driver refused was not reported as one: $out"
    grep -q "the stub refuses to create" <<<"$out" \
      || fail "launch printed 'could not create it:' and then nothing -- the driver's reason never reached the one stream launch captures: $out"
    [ -e "$AUTOFLEET_DIR/worktrees/45" ] \
      && fail "a refused create left the issue owned, so its slot is held by a worktree that does not exist"

    # The whole point. Not "the fleet still works" -- the fleet works and the CLI
    # was never asked anything.
    [ -s "$ORCA_CALLS" ] \
      && fail "something outside scripts/fleet/runner/ still reaches for the orca CLI: $(cat "$ORCA_CALLS")"
    echo "ok: dispatcher, reap and both worktree hooks run on a driver that is not Orca"
    ;;
  create_says)
    # `launch` printing "could not create it:" and then nothing is the same line
    # whether the app is down or the branch already exists, and it repeats every
    # pass with the issue left in the queue. The driver has to relay the
    # runtime's stderr for that line to be worth anything -- docs/RUNNERS.md says
    # so, and until the independent review said otherwise nothing asserted it.
    make_fixture create_fails
    out="$(in_fleet launch 44 "a second issue" 2>&1)"
    grep -q "could not create it" <<<"$out" \
      || fail "a refused worktree creation was not reported at all: $out"
    grep -q "already exists" <<<"$out" \
      || fail "the runtime said why on stderr and the driver dropped it, so the log cannot tell a refused branch name from an app that is not running: $out"
    echo "ok: a refused worktree creation carries the runtime's own reason"
    ;;
  create_warns)
    # The other half of create_says, and the one the fix for it introduced: the
    # driver relays the runtime's own words on failure AND parses its JSON on
    # success, so a merged stderr broke every create by a CLI that says anything
    # at all while succeeding. The worktree exists either way -- it is on the
    # runner's list, it counts against the cap of three, and `in_flight` believes
    # the issue is running -- but a `launch` that could not read the path back
    # owns nothing: no card, no started marker, no time-box, and neither reap
    # iterates it because both walk OWNED_DIR. A slot held forever by a worktree
    # the fleet cannot see. Found by the independent review.
    make_fixture create_warns
    out="$(in_fleet launch 44 "a second issue" 2>&1)"
    grep -q "reported no path" <<<"$out" \
      && fail "a warning on stderr broke the JSON parse, so the fleet created a worktree it does not own and cannot reap: $out"
    grep -q "#44 is running in" <<<"$out" \
      || fail "the created worktree was not tracked: $out"
    [ -e "$AUTOFLEET_DIR/worktrees/44" ] \
      || fail "nothing owns the worktree that was just created, so no reap will ever look at it: $out"
    echo "ok: a create that warns on stderr is still parsed, owned and carded"
    ;;
  card_says)
    make_fixture set_fails
    out="$(in_fleet card "/some/worktree" workspace-status in-progress comment "#42: building" 2>&1)"
    grep -qi "board update FAILED" <<<"$out" \
      || fail "a refused board update said nothing: $out"
    grep -q "Unable to determine Orca.app path" <<<"$out" \
      || fail "the CLI's own reason was dropped: $out"
    grep -q "in-progress" <<<"$out" \
      || fail "the log does not say which update was lost: $out"
    echo "ok: a board update that failed is in the dispatcher log"

    # ...and STDERR FIRST within the three-line bound, which is what
    # docs/RUNNERS.md publishes for this function as of this PR. The CLI here
    # prints two lines on stdout before the reason reaches stderr, so a merged
    # stream puts the reason on line three at best and past it at worst. This
    # fails against the `FLEET_RUN_CAPTURE_STDERR=1` form the separate `$err`
    # replaced.
    make_fixture set_noisy
    out="$(in_fleet card "/some/worktree" workspace-status in-progress comment "#42: building" 2>&1)"
    grep -q "the real reason: worktree is not registered" <<<"$out" \
      || fail "the runtime's reason was pushed past the three-line bound by its own stdout, which is what relaying stderr first prevents: $out"
    echo "ok: ...and the reason is relayed before the runtime's stdout, inside the bound"
    ;;
  card_quiet)
    make_fixture ok
    out="$(in_fleet card "/some/worktree" comment "#42: building" 2>&1)"
    grep -qi "fail" <<<"$out" && fail "a successful board update complained: $out"
    echo "ok: a board update that worked says nothing"
    ;;
  remove_forces)
    make_fixture rm_needs_force
    make_worktree
    in_fleet remove_worktree "$WORK/wt" >/dev/null 2>&1 \
      || fail "remove_worktree gave up on a worktree --force would have removed"
    [ -d "$WORK/wt" ] && fail "it reported success and the worktree is still there"
    grep -q -- "--force" "$ORCA_CALLS" \
      || fail "the retry did not pass --force, so the submodule refusal stands"
    echo "ok: a worktree git refuses to remove is removed with --force"
    ;;
  reap_blind_upstream)
    # The worktree whose branch GitHub deleted on merge. `@{u}` stops resolving,
    # git prints nothing, and `grep -c` prints 0 -- so the release check read
    # "holds nothing" for a worktree that may hold a commit made after
    # auto-merge fired, and a clean tree then made it a `--force` removal. The
    # commit went with the directory. armaatus/autofleet#34.
    make_fixture ok
    make_worktree
    # No origin at all: `@{u}` cannot resolve, which is the state a pruned
    # upstream leaves behind.
    out="$(in_fleet reap_merged 2>&1)"
    [ -d "$WORK/wt" ] \
      || fail "a worktree whose upstream will not resolve was removed: $out"
    echo "ok: a git that cannot say what a worktree holds keeps it"
    grep -qi "could not say what the worktree holds" <<<"$out" \
      || fail "it kept the worktree without saying why: $out"
    echo "ok: ...and says so, rather than keeping it silently"
    ;;

  poll_empties_cache)
    # #35's third Acceptance bullet: "the poll cache is still emptied once per
    # pass, so a dispatcher never trusts the previous pass' answers."
    #
    # After the source-time call was deleted, `forget_poll_answers` inside
    # `cmd_run`'s poll is the ONLY emptier left in production -- and every phase
    # that touches the cache goes around it: the `in_poll` ones call it by hand,
    # `in_fleet` empties the cache itself so that one call models one pass, and
    # `status_keeps_cache` asserts the opposite property. The one line whose
    # survival that bullet is about was the one line nothing was aimed at. Hard
    # rule 3, in the suite for the issue that created it. Found by the
    # independent review.
    make_fixture ok
    make_repo_git
    add_origin
    mkdir -p "$AUTOFLEET_DIR/poll-cache"
    : >"$AUTOFLEET_DIR/poll-cache/stale-from-the-last-pass"
    issue_state CLOSED; issue_labels "ready"
    ( in_fleet_keeping_cache cmd_run --max-prs 1 148 >"$WORK/run.log" 2>&1 ) &
    HELD_PID=$!
    wait_for_log "fleet up" \
      || fail "the dispatcher never started: $(cat "$WORK/run.log" 2>/dev/null)"
    run_ended "$HELD_PID" >/dev/null 2>&1
    HELD_PID=""
    [ -e "$AUTOFLEET_DIR/poll-cache/stale-from-the-last-pass" ] \
      && fail "a poll ran and the previous pass' cached answers survived it, so the dispatcher trusts them"
    echo "ok: a poll empties the cache, which is the only emptier left in production"
    ;;
  restart_after_parked_drain)
    # #37's "A second dispatcher can start afterwards", which is the sentence
    # that issue opens with -- "the fleet cannot be restarted either" -- and the
    # bullet with the most behind it: the parked entry stays in $OWNED_DIR,
    # which is exactly what #36 warns the next dispatcher inherits.
    #
    # `drain_ends_with_parked` ends at "the drain ended, it named #42, the
    # worktree survives" and never asks whether anything can start again. The
    # behaviour looks right -- `release_dispatcher_files` is on the EXIT trap --
    # but nothing proved it. Found by the independent review.
    #
    # Asserted through what `cmd_run` ACTUALLY CHECKS rather than by starting a
    # second dispatcher: `run_refuses` is the sibling that drives the refusal,
    # and a real second run here would poll until its own drain, which is a
    # minute of suite time to re-test what that phase already covers.
    make_fixture ok
    make_repo_git
    mkdir -p "$AUTOFLEET_DIR/worktrees"
    printf '%s\n' "$WORK/wt" >"$AUTOFLEET_DIR/worktrees/42"
    : >"$AUTOFLEET_DIR/stuck-42"
    in_fleet cmd_stop >/dev/null 2>&1
    ( in_fleet cmd_run --auto >"$WORK/run.log" 2>&1 ) &
    HELD_PID=$!
    run_ended "$HELD_PID" \
      || fail "the drain never ended with a parked worktree owned: $(cat "$WORK/run.log" 2>/dev/null)"
    HELD_PID=""
    [ -e "$AUTOFLEET_DIR/worktrees/42" ] \
      || fail "the drain released a parked worktree to make itself terminate, which is what #37 says must not happen"
    echo "ok: the drain ends with the parked worktree still owned"

    # THE ASSERTION. `cmd_run` refuses while a dispatcher is alive, and it reads
    # the pidfile to decide -- so a pidfile left behind is a fleet that cannot be
    # restarted, with the parked entry still in $OWNED_DIR.
    held="$(cat "$AUTOFLEET_DIR/fleet.pid" 2>/dev/null || true)"
    if [ -n "$held" ]; then
      in_fleet dispatcher_alive "$held" \
        && fail "the dispatcher exited leaving a pidfile that still reads as alive; a second one cannot start and the parked worktree is stranded"
    fi
    in_fleet cmd_resume >/dev/null 2>&1
    out="$(run_one_pass)"; rc=$?
    grep -qi "already running" <<<"$out" \
      && fail "a second dispatcher was refused after a drain that ended with a parked worktree: $out"
    echo "ok: ...and a second dispatcher is not refused afterwards"
    ;;
  drain_parked_counted_once)
    # Two markers, ONE worktree. `reap_merged` keeps a merged worktree owned as
    # `merge-blind-42` when its upstream was pruned, and `reap_abandoned` can
    # then write `stuck-42` beside it in the same pass. Counting markers rather
    # than issues made `parked` 2 for one worktree, so `owned` dropped to 0 with
    # #99 still mid-work and the dispatcher exited -- #36's failure, re-created
    # by the fix for #37. The `-lt 0` clamp turned it from a visible wrong answer
    # into a silent one. Found by the independent review.
    make_fixture ok
    mkdir -p "$AUTOFLEET_DIR/worktrees" "$AUTOFLEET_DIR"
    printf '%s\n' "$WORK/wt" >"$AUTOFLEET_DIR/worktrees/42"
    printf '%s\n' "$WORK/wt99" >"$AUTOFLEET_DIR/worktrees/99"
    : >"$AUTOFLEET_DIR/merge-blind-42"
    : >"$AUTOFLEET_DIR/stuck-42"
    # TWO passes, because a marker must survive one before it counts -- the
    # first pass records it, the second counts it. See count_parked_owned.
    [ "$(in_fleet count_parked_owned 2>&1)" = 0 ] \
      || fail "a marker counted on the pass it appeared; a transient one would end the drain with an agent still working"
    echo "ok: a marker does not count on the pass it appears"
    out="$(in_fleet count_parked_owned 2>&1)"
    [ "$out" = 1 ] \
      || fail "two markers on one worktree counted as $out parked; #99 is still in flight and the drain would exit: $out"
    echo "ok: a worktree with two keep-markers is one parked worktree"

    # ...and a marker that goes away before the next pass never counts, which is
    # the failure this rule exists for: `held-` and `git-blind-` are re-derived
    # every pass, and one transient `blocked` label would otherwise sign the
    # dispatcher off with an agent still writing.
    rm -f "$AUTOFLEET_DIR/merge-blind-42" "$AUTOFLEET_DIR/stuck-42"
    [ "$(in_fleet count_parked_owned 2>&1)" = 0 ] \
      || fail "a marker that cleared still counted as a worktree waiting for a person"
    : >"$AUTOFLEET_DIR/held-42"
    [ "$(in_fleet count_parked_owned 2>&1)" = 0 ] \
      || fail "a transient held- counted on its first pass"
    rm -f "$AUTOFLEET_DIR/held-42"
    [ "$(in_fleet count_parked_owned 2>&1)" = 0 ] \
      || fail "a held- that came and went across two passes was counted"
    echo "ok: ...and a marker that comes and goes never counts"

    # ...AND THE TWO RE-DERIVED MARKERS NEED THE AGENT TO BE GONE. `held-` and
    # `git-blind-` are written by `reap_abandoned`, which deliberately leaves the
    # agent alone -- so the worktree is not waiting for a person, somebody is
    # still working in it. Counted, the dispatcher exits with an agent mid-write
    # and the farewell tells a person to discard what is in there. Found by the
    # independent review.
    agent_state working
    : >"$AUTOFLEET_DIR/held-42"
    in_fleet count_parked_owned >/dev/null 2>&1
    [ "$(in_fleet count_parked_owned 2>&1)" = 0 ] \
      || fail "held-42 counted as waiting for a person while an agent is still working in that worktree"
    echo "ok: a worktree with a live agent is not waiting for a person"

    # ...and once the agent is gone it does count, or the drain never ends --
    # which is the opposite failure, and the reason these two are counted at all.
    printf '{"result":{"terminals":[]}}' >"$ORCA_TERMINALS"
    in_fleet count_parked_owned >/dev/null 2>&1
    [ "$(in_fleet count_parked_owned 2>&1)" = 1 ] \
      || fail "held-42 with no agent left did not count, so the drain waits on it forever"
    echo "ok: ...and it does once the agent is gone"

    # "Could not tell" is not "no agent": a listing that would not read leaves
    # the worktree uncounted, because somebody may still be in there.
    printf 'not json' >"$ORCA_TERMINALS"
    in_fleet count_parked_owned >/dev/null 2>&1
    [ "$(in_fleet count_parked_owned 2>&1)" = 0 ] \
      || fail "a terminal listing that could not be read was treated as 'no agent there'"
    echo "ok: ...and an unreadable listing is not an empty one"

    # CASE (a): `stuck-` plus a stale `held-`, which nothing could ever clear.
    # The gate keyed on marker PRESENCE, so a worktree whose reason is "its
    # removal was refused" -- needing no agent check at all -- was still gated
    # on a `held-` beside it. And `held-` outlived everything: `park_worktree`
    # wrote `stuck-` without clearing it, after which both reaps return early.
    # `parked` 0, `owned` 1, the drain polls forever: #37 verbatim, in the PR
    # that closes #37. Found by the independent review.
    agent_state working
    : >"$AUTOFLEET_DIR/stuck-42"
    : >"$AUTOFLEET_DIR/held-42"
    in_fleet count_parked_owned >/dev/null 2>&1
    [ "$(in_fleet count_parked_owned 2>&1)" = 1 ] \
      || fail "a refused removal was gated on a stale held- beside it, so the drain never ends"
    echo "ok: a refused removal counts whatever else is beside it"

    # ...and `park_worktree` clears the pair when it writes `stuck-`, so the
    # stale marker cannot arise in the first place.
    rm -f "$AUTOFLEET_DIR"/stuck-42 "$AUTOFLEET_DIR"/held-42
    : >"$AUTOFLEET_DIR/held-42"
    in_fleet park_worktree 42 "$WORK/wt" 1 "the stub refuses" >/dev/null 2>&1
    [ -e "$AUTOFLEET_DIR/held-42" ] \
      && fail "park_worktree left held-42 behind; nothing else ever clears it and it gates the worktree forever"
    echo "ok: ...and parking clears the markers a refusal has answered"
    rm -f "$AUTOFLEET_DIR"/stuck-42
    printf '{"result":{"terminals":[]}}' >"$ORCA_TERMINALS"
    # ...and put the listing back, or every assertion after this one is testing
    # a runner that cannot answer rather than the thing it is about.
    printf '{"result":{"terminals":[]}}' >"$ORCA_TERMINALS"
    rm -f "$AUTOFLEET_DIR/held-42"

    # ...and the two reap_abandoned keeps, which an earlier comment asserted did
    # not exist. Uncounted, `owned` never reaches 0 and the drain never ends --
    # #37's unbounded drain through a different door, in the PR that closes #37.
    rm -f "$AUTOFLEET_DIR/merge-blind-42" "$AUTOFLEET_DIR/stuck-42"
    : >"$AUTOFLEET_DIR/held-42"
    : >"$AUTOFLEET_DIR/git-blind-99"
    in_fleet count_parked_owned >/dev/null 2>&1   # the pass that records them
    out="$(in_fleet count_parked_owned 2>&1)"
    [ "$out" = 2 ] \
      || fail "held- and git-blind- are not counted as waiting for a person, so the drain waits on them forever: $out"
    echo "ok: ...and all five keep-markers count"

    # ...AND THE TWO PLACES THAT TELL A PERSON know the same five. Counting a
    # worktree as waiting for someone and then never naming it is worse than not
    # counting it: it is present in the tally and absent from the list that says
    # what to do about it. `cmd_status` and the farewell both drifted the moment
    # there were more than three reasons, and `cmd_status`'s block had no test at
    # all -- delete it and the suite stayed green. Found by the independent
    # review, which called all three findings one crack.
    # `cmd_status` lists through `live_worktrees`, so the runner has to report
    # #42 as well as the fleet owning it.
    python3 -c '
import json, sys
print(json.dumps({"result": {"worktrees": [
  {"path": sys.argv[1], "isMainWorktree": False, "linkedIssue": 42},
]}}))' "$WORK/wt" >"$ORCA_WORKTREES"
    for reason in stuck merge-held merge-blind held git-blind; do
      rm -f "$AUTOFLEET_DIR"/stuck-* "$AUTOFLEET_DIR"/merge-held-* \
            "$AUTOFLEET_DIR"/merge-blind-* "$AUTOFLEET_DIR"/held-* \
            "$AUTOFLEET_DIR"/git-blind-*
      : >"$AUTOFLEET_DIR/$reason-42"
      out="$(in_fleet why_parked 42 2>&1)"
      [ -n "$out" ] \
        || fail "$reason-42 is counted as parked and why_parked says nothing, so status and the farewell cannot name it"
      status_out="$(in_fleet cmd_status 2>&1)"
      grep -q "waiting for you" <<<"$status_out" \
        || fail "status did not name #42 as waiting for a person with $reason-42 set: $status_out"
    done
    echo "ok: ...and status names every one of the five"

    # ...and the RECOVERY LINE is not `--force` for the reasons where forcing
    # destroys exactly what the line above says is in there. #37: "what must NOT
    # happen is releasing the worktree to make the loop terminate: the whole
    # reason it is parked is that removing it would destroy something." The
    # dispatcher kept that promise and broke it through the operator, two lines
    # apart. Found by the independent review.
    for reason in merge-held held merge-blind git-blind; do
      rm -f "$AUTOFLEET_DIR"/stuck-* "$AUTOFLEET_DIR"/merge-held-* \
            "$AUTOFLEET_DIR"/merge-blind-* "$AUTOFLEET_DIR"/held-* \
            "$AUTOFLEET_DIR"/git-blind-*
      : >"$AUTOFLEET_DIR/$reason-42"
      advice="$(in_fleet how_to_release 42 /some/worktree 2>&1)"
      grep -q -- "--force" <<<"$advice" \
        && fail "$reason-42 says the worktree holds something and then tells a person to --force it away: $advice"
    done
    echo "ok: ...and only a refused removal is answered with --force"

    # ...while the one path where the dispatcher HAS established that nothing
    # goes with the worktree still gets the removal.
    rm -f "$AUTOFLEET_DIR"/merge-held-* "$AUTOFLEET_DIR"/held-* \
          "$AUTOFLEET_DIR"/merge-blind-* "$AUTOFLEET_DIR"/git-blind-*
    : >"$AUTOFLEET_DIR/stuck-42"
    advice="$(in_fleet how_to_release 42 /some/worktree 2>&1)"
    grep -q -- "--force" <<<"$advice" \
      || fail "a refused removal no longer tells a person how to remove it: $advice"
    echo "ok: ...and a refused removal still does"
    ;;
  drain_ends_with_parked)
    # `park_worktree` keeps a worktree owned when its removal was refused, which
    # is right. But the run loop exits only on `owned == 0`, and under a drain
    # `queued` is forced to 0 -- so a parked worktree made that the only exit
    # and it never came. The dispatcher polled forever, `status` never said
    # idle, and no second dispatcher could start. armaatus/autofleet#37.
    # A RUNNING dispatcher, stopped -- `cmd_run` refuses to start under a drain,
    # so the state has to be reached the way a real one reaches it.
    # DRIVEN, not hand-written. Writing `stuck-42` by hand meant the phase
    # passed while `park_worktree` could be renamed out from under production --
    # the same green-for-the-wrong-reason this branch keeps finding -- and it is
    # now load-bearing too, since only holds with an OWNED entry are counted.
    # `rm_never_works` plus a merged PR reaches the park the way `remove_advice`
    # does.
    make_fixture rm_never_works
    make_worktree
    add_origin
    ( in_fleet cmd_run --auto >"$WORK/run.log" 2>&1 ) &
    HELD_PID=$!
    wait_for_log "fleet up"
    wait_for_log "could not remove it"
    [ -e "$AUTOFLEET_DIR/stuck-42" ] \
      || fail "park_worktree did not park it, so this phase would assert nothing"
    in_fleet cmd_stop >/dev/null 2>&1
    run_ended "$HELD_PID" \
      || fail "the drain never ended with a worktree parked: $(cat "$WORK/run.log")"
    HELD_PID=""
    echo "ok: a drain ends even with a worktree waiting for a person"
    grep -q "waiting for you" "$WORK/run.log" \
      || fail "it ended without naming what is parked: $(cat "$WORK/run.log")"
    grep -q "#42" "$WORK/run.log" || fail "it did not name which: $(cat "$WORK/run.log")"
    echo "ok: ...and names it on the way out"
    [ -d "$WORK/wt" ] \
      || fail "it released the parked worktree, which is what parking exists to prevent"
    echo "ok: ...and leaves it alone"
    ;;

  remove_advice)
    make_fixture rm_never_works
    make_worktree
    # An upstream, because this phase drives `reap_merged` and therefore has to
    # get PAST the holds check to reach the removal it is about. It did not have
    # one, and passed anyway: `@{u}` did not resolve, git printed nothing, and
    # the count read as "holds nothing". That is the bug armaatus/autofleet#34
    # fixes, and this phase was standing on it -- `make_fixture`'s own comment
    # says a worktree with no origin is the "could not tell" case and that every
    # test expecting a removal sets one up.
    add_origin
    out="$(in_fleet reap_merged 2>&1)"
    grep -q "could not remove it" <<<"$out" \
      || fail "a failed removal was not reported: $out"
    grep -q "git worktree remove --force" <<<"$out" \
      || fail "it did not say how to remove it by hand: $out"
    grep -q "git worktree remove --force.*&&.*reap.sh --yes" <<<"$out" \
      || fail "the advice is not both halves in order -- reap.sh alone skips a worktree that is still there, and the directory alone leaks its stack: $out"
    grep -q "containing submodules" <<<"$out" \
      || fail "the reason git gave was dropped; it is the difference between this and a hung CLI: $out"
    echo "ok: a failed removal says something that would actually clean it up"
    ;;
  remove_keeps_stack)
    make_fixture rm_never_works
    make_worktree
    out="$(in_fleet remove_worktree "$WORK/wt" 2>&1)"
    grep -q -- "--run-hooks" "$ORCA_CALLS" \
      && fail "the removal still asks Orca to run the archive hook, so a refusal tears the stack down anyway: $(cat "$ORCA_CALLS")"
    [ -s "$REAP_CALLS" ] \
      && fail "it swept the stack of a worktree it did not remove: $(cat "$REAP_CALLS")"
    grep -q "still up" <<<"$out" \
      || fail "it did not say the stack survived, which is the whole difference: $out"
    echo "ok: a refused removal leaves that worktree's stack running"
    ;;
  remove_sweeps_stack)
    make_fixture rm_needs_force
    make_worktree
    out="$(in_fleet remove_worktree "$WORK/wt" 2>&1)" \
      || fail "remove_worktree gave up on a worktree --force would have removed: $out"
    [ -d "$WORK/wt" ] && fail "it reported success and the worktree is still there"
    grep -q -- "--yes" "$REAP_CALLS" \
      || fail "the stack was never swept, so every merged worktree leaks it: $(cat "$REAP_CALLS")"
    echo "ok: the stack is torn down once the worktree is actually gone"
    ;;
  merged_keeps_dirty)
    make_fixture ok
    make_worktree
    add_origin
    dirty_worktree
    out="$(in_fleet reap_merged 2>&1)"
    grep -q "worktree rm" "$ORCA_CALLS" \
      && fail "a dirty worktree reached the removal: $(cat "$ORCA_CALLS")"
    [ -d "$WORK/wt" ] || fail "it removed a worktree holding uncommitted work: $out"
    [ -e "$AUTOFLEET_DIR/worktrees/42" ] \
      || fail "it disowned a worktree it kept, so nothing looks at it again: $out"
    grep -q "uncommitted" <<<"$out" \
      || fail "it did not say WHAT the worktree holds: $out"
    # Once per worktree, not once per poll: the dispatcher polls every minute.
    again="$(in_fleet reap_merged 2>&1)"
    grep -q "uncommitted" <<<"$again" && fail "it says so every poll: $again"
    echo "ok: reap_merged leaves a dirty worktree and says what is in it"
    ;;
  merged_unknown_git)
    make_fixture ok
    make_worktree
    add_origin
    # HEAD still reads, so the branch and the merged-PR lookup both answer; the
    # index does not, so `git status` cannot say whether anything is uncommitted.
    printf 'not an index' >"$WORK/wt/.git/index"
    out="$(in_fleet reap_merged 2>&1)"
    grep -q "worktree rm" "$ORCA_CALLS" \
      && fail "it removed a worktree on a git that never answered: $(cat "$ORCA_CALLS")"
    [ -d "$WORK/wt" ] || fail "the worktree is gone: $out"
    grep -q "could not say" <<<"$out" \
      || fail "it treated a git error as a clean working tree, in silence: $out"
    again="$(in_fleet reap_merged 2>&1)"
    grep -q "could not say" <<<"$again" && fail "it says so every poll: $again"
    echo "ok: a git that cannot answer keeps the worktree"
    ;;
  merged_cli_silent)
    make_fixture rm_hangs
    make_worktree
    add_origin
    # The dispatcher's own deadline, shortened so the phase fits its 60s timeout.
    out="$(AUTOFLEET_RM_DEADLINE=1 in_fleet reap_merged 2>&1)"
    [ -d "$WORK/wt" ] || fail "the worktree went on a call that never answered: $out"
    [ -e "$AUTOFLEET_DIR/stuck-42" ] \
      && fail "a CLI that never answered was recorded as a refusal, so the slot is held for good: $out"
    grep -q "did not answer" <<<"$out" || fail "it did not say what actually happened: $out"
    # ONE attempt, not two: a second 180s proving nothing answers doubles what a
    # poll costs while Orca.app restarts.
    [ "$(grep -c "worktree rm" "$ORCA_CALLS")" = 1 ] \
      || fail "it spent a second deadline on a CLI that had already timed out: $(cat "$ORCA_CALLS")"
    # The COUNT, not its presence: $ORCA_CALLS is never truncated between the two
    # passes, so `grep -q` would find the first call's line and pass even if the
    # second pass made no call at all -- which is the regression this pins.
    again="$(AUTOFLEET_RM_DEADLINE=1 in_fleet reap_merged 2>&1)"
    [ "$(grep -c "worktree rm" "$ORCA_CALLS")" = 2 ] \
      || fail "the next pass did not retry, so an Orca restart costs the slot permanently: $again"
    echo "ok: a CLI that never answered is retried, not parked"
    ;;
  remove_scoped_sweep)
    make_fixture rm_needs_force
    make_worktree
    # The name the stack was really created under, which after a directory rename
    # is NOT the one the path derives -- archive.sh removed both, so must this.
    echo "COMPOSE_PROJECT_NAME=rmx-renamed-1" >"$WORK/wt/.env"
    in_fleet remove_worktree "$WORK/wt" >/dev/null 2>&1 \
      || fail "the worktree was not removed, so the sweep assertion is vacuous"
    grep -q -- "--only" "$REAP_CALLS" \
      || fail "the sweep was unscoped, so releasing one worktree reaps every orphan on the machine: $(cat "$REAP_CALLS")"
    grep -q -- "--only rmx-renamed-1" "$REAP_CALLS" \
      || fail "the name the stack was actually created under was not swept: $(cat "$REAP_CALLS")"
    echo "ok: the sweep names the stack of the worktree it removed"
    ;;
  merged_keeps_owned)
    make_fixture rm_never_works
    make_worktree
    add_origin
    out="$(in_fleet reap_merged 2>&1)"
    grep -q "could not remove it" <<<"$out" \
      || fail "a failed removal was not reported: $out"
    [ -e "$AUTOFLEET_DIR/worktrees/42" ] \
      || fail "the issue was disowned on a removal that refused, so that worktree is one nothing ever looks at again: $out"
    [ -e "$AUTOFLEET_DIR/stuck-42" ] \
      || fail "nothing recorded the refusal, so the next poll retries it: $out"
    again="$(in_fleet reap_merged 2>&1)"
    grep -q "could not remove it" <<<"$again" \
      && fail "it says so again every poll, and retries the removal with it: $again"
    echo "ok: a refused removal keeps its issue owned, and is said once"
    ;;
  stall_expected)
    make_fixture ok
    make_worktree
    agent_state waiting
    issue_labels "ready,needs-human-step"
    out="$(in_fleet notice_stalled 2>&1)"
    grep -q "nothing should be asking" <<<"$out" \
      && fail "a correct refusal to act alone was called a stall: $out"
    grep -qi "as expected" <<<"$out" \
      || fail "it did not say the wait was the expected one: $out"
    echo "ok: an issue whose last step is yours is reported as waiting for you"
    ;;
  stall_reports)
    make_fixture ok
    make_worktree
    agent_state waiting
    issue_labels "ready"
    out="$(in_fleet notice_stalled 2>&1)"
    grep -q "nothing should be asking" <<<"$out" \
      || fail "an ordinary agent sitting at a prompt was not reported: $out"
    echo "ok: an ordinary waiting agent is still a stall"
    ;;
  timebox_waits)
    make_fixture ok
    make_worktree
    make_overdue
    agent_state waiting
    issue_labels "ready,needs-human-step"
    out="$(in_fleet enforce_timebox 2>&1)"
    grep -q -- "--interrupt" "$ORCA_CALLS" \
      && fail "the time-box interrupted an agent that was correctly waiting: $out"
    grep -q "issue comment" "$GH_CALLS" \
      && fail "it told the issue the fleet gave up on work that is waiting on a person"
    grep -q "needs-human-step" <<<"$out" \
      || fail "the log does not say why it was left alone: $out"
    grep -q "waiting for you" "$ORCA_CALLS" \
      || fail "nothing reached the board, and one line in fleet.log is not the status surface"
    [ -e "$AUTOFLEET_DIR/started/42" ] \
      || fail "the timer was disarmed for good, so removing the label leaves the agent uncapped"
    # Once per exemption, not once per poll: the dispatcher polls every minute.
    again="$(in_fleet enforce_timebox 2>&1)"
    grep -q "needs-human-step" <<<"$again" \
      && fail "it says so again every poll: $again"
    echo "ok: the time-box exempts an issue whose last step is yours"
    ;;
  timebox_stops)
    make_fixture ok
    make_worktree
    make_overdue
    agent_state working
    issue_labels "ready"
    out="$(in_fleet enforce_timebox 2>&1)"
    grep -q -- "--interrupt" "$ORCA_CALLS" \
      || fail "an ordinary overrun was not stopped: $out"
    grep -q "issue comment" "$GH_CALLS" \
      || fail "an ordinary overrun left nothing on the issue: $out"
    echo "ok: an ordinary overrun is still stopped"
    ;;
  foundation_holds)
    # CLAUDE.md: "a foundation issue lands alone." The dispatcher enforced only
    # half of it -- a foundation issue would not JOIN running worktrees, and
    # nothing stopped others joining a foundation issue. On a cold start `live`
    # is 0, the foundation issue is picked first, and every later candidate that
    # pass sails past a check that only asks about ITSELF. autofleet's own first
    # run opened #1 (foundation), #4 and #7 in eleven seconds.
    make_fixture ok
    worktree_on_issue 1
    issue_labels "ready,foundation"
    out="$(in_fleet foundation_in_flight 2>&1)"; rc=$?
    [ "$rc" = 0 ] || fail "a foundation issue in flight did not hold the launch loop (rc=$rc): $out"
    echo "ok: a foundation issue in flight holds the launch loop"
    grep -q "lands alone" <<<"$out" \
      || fail "the hold did not say why: $out"
    grep -q "#1" <<<"$out" || fail "the hold did not name the issue: $out"
    echo "ok: ...and says which issue it is holding for"
    ;;

  foundation_launch_held)
    # THE CALL SITE, not the function. Every other phase here calls
    # `foundation_in_flight` directly, so deleting the one line that uses it --
    # `if foundation_in_flight; then break; fi` in the launch loop -- left all of
    # them green while the fleet went back to opening three worktrees on a
    # foundation issue. That is hard rule 3's shape exactly, and the local review
    # of this change found it.
    #
    # This drives cmd_run and asserts on what reached the CLI, which is the only
    # thing that says whether a worktree would have been opened.
    make_fixture ok
    worktree_on_issue 1
    issue_labels "ready,foundation"
    cat >"$GH_ISSUES" <<'JSON'
[{"number":4,"title":"an ordinary one","body":"","labels":[{"name":"ready"}]}]
JSON
    # A REAL DISPATCHER, backgrounded and then stopped. `--max-prs` bounds only
    # the FAILURE path here -- when the hold works nothing is launched, `opened`
    # stays 0, #4 stays startable, and the run polls forever. A `--until`
    # deadline does not save it either: a drain keeps polling until nothing it
    # owns is left. Both bounded versions hung the suite, and the second one hung
    # it after the first review had already found the first.
    start_dispatcher --auto
    wait_for_log "lands alone"
    grep -q "^worktree create" "$ORCA_CALLS" \
      && fail "the launch loop opened a worktree with a foundation issue in flight: $(cat "$WORK/run.log")"
    echo "ok: the launch loop opens nothing while a foundation issue is in flight"
    stop_dispatcher
    ;;

  foundation_cold_start)
    # THE INCIDENT, reproduced. A cold start with a foundation issue and an
    # ordinary one both startable is exactly what opened #1, #4 and #7 in eleven
    # seconds: `live` is 0, the foundation issue goes first, and every later
    # candidate that pass is not itself a foundation issue.
    #
    # This is the phase that reaches `rm -f "$POLL_CACHE/foundation"` in
    # `launch` -- the one line carrying the whole within-a-pass half of the rule,
    # and the line no phase could reach while the stub's created worktree stayed
    # invisible to the next `live_worktrees`. Delete it and the suite was green
    # while the bug came straight back. Found by the independent review.
    make_fixture ok
    issue_labels "ready,foundation"
    cat >"$GH_ISSUES" <<'JSON'
[{"number":1,"title":"the foundation one","body":"","labels":[{"name":"ready"},{"name":"foundation"}]},
 {"number":4,"title":"an ordinary one","body":"","labels":[{"name":"ready"}]}]
JSON
    # A REAL DISPATCHER, backgrounded and then stopped -- not a bounded
    # `in_fleet cmd_run`. A run that launches something cannot come back on its
    # own here: a drain keeps polling until nothing it owns is left, and this
    # suite has no way to make a launched worktree reapable. Both bounded
    # attempts hung the suite before this one.
    start_dispatcher --auto
    wait_for_log "lands alone"
    # It launched the foundation issue and then held. One create, no more,
    # however many passes it has managed by the time this reads.
    n="$(grep -c "^worktree create" "$ORCA_CALLS" || true)"
    [ "${n:-0}" = 1 ] \
      || fail "a cold start opened $n worktrees with a foundation issue among them: $(cat "$WORK/run.log")"
    echo "ok: a cold start opens the foundation issue and then nothing else"
    echo "ok: ...and says why it stopped"
    stop_dispatcher
    ;;

  foundation_restart_speaks)
    # The say-once marker lives in $STATE_DIR so it outlives a POLL. It must not
    # outlive a DISPATCHER: one restarted while a foundation issue is still in
    # flight would read back the previous run's marker and hold in total silence
    # -- zero worktrees and not one line saying why, which is the exact case the
    # function exists for. `rm -f "$FOUNDATION_HOLD_SAID"` at startup is the fix
    # and nothing reached it. Found by the independent review.
    make_fixture ok
    worktree_on_issue 1
    issue_labels "ready,foundation"
    cat >"$GH_ISSUES" <<'JSON'
[{"number":4,"title":"an ordinary one","body":"","labels":[{"name":"ready"}]}]
JSON
    # As a previous dispatcher left it: the hold already announced.
    #
    # `mkdir -p` first, and then CHECKED. The state dir does not exist until a
    # dispatcher makes one, so this write silently failed and the phase passed
    # for the wrong reason -- it was asserting that a fleet with no marker speaks,
    # which every other phase already covers.
    mkdir -p "$AUTOFLEET_DIR"
    printf '1' >"$AUTOFLEET_DIR/holding-for-foundation"
    [ -s "$AUTOFLEET_DIR/holding-for-foundation" ] \
      || fail "could not seed the marker, so what follows would assert nothing"
    start_dispatcher --auto
    wait_for_log "lands alone"
    echo "ok: a restarted dispatcher explains its own hold rather than inheriting silence"
    grep -q "^worktree create" "$ORCA_CALLS" \
      && fail "it also launched something while holding: $(cat "$WORK/run.log")"
    echo "ok: ...and still opens nothing"
    stop_dispatcher
    ;;

  foundation_break_is_local)
    # The within-a-pass half must be a property of the DISPATCHER, not of the
    # Orca CLI's read-your-writes behaviour. `foundation_in_flight` on the next
    # iteration would also stop the pass -- but only if `worktree list` shows a
    # worktree `create` returned moments ago AND that entry carries
    # `linkedIssue`. A CLI that returns null there makes `live_worktrees` print
    # `-`, which this deliberately reads as "on no issue", and the pass launches
    # the next candidate behind the foundation issue: 1, 4 and 7 in eleven
    # seconds with every phase green.
    #
    # So: a stub that succeeds at `create` and reports the worktree with NO
    # linked issue, which is the case the fixture's read-your-writes create
    # cannot express. Only the local `is_foundation "$labels" && break` saves
    # this. Found by the independent review, which noted the phase for this half
    # was asserting the fixture's guarantee rather than the dispatcher's.
    make_fixture ok
    issue_labels "ready,foundation"
    cat >"$GH_ISSUES" <<'JSON'
[{"number":1,"title":"the foundation one","body":"","labels":[{"name":"ready"},{"name":"foundation"}]},
 {"number":4,"title":"an ordinary one","body":"","labels":[{"name":"ready"}]}]
JSON
    # A CLI that has not caught up: whatever it creates comes back unlinked.
    export ORCA_CREATE_UNLINKED=1
    start_dispatcher --auto
    wait_for_log "lands alone"
    n="$(grep -c "^worktree create" "$ORCA_CALLS" || true)"
    [ "${n:-0}" = 1 ] \
      || fail "with an unlinked worktree the pass opened $n: $(cat "$WORK/run.log")"
    echo "ok: the pass ends on the launch itself, not on what the CLI reports back"
    stop_dispatcher
    ;;

  foundation_resays)
    # A standing hold with no expiry goes quiet for as long as it stands, and
    # the line explaining it scrolls off the log. Hourly by default; driven here
    # with AUTOFLEET_HOLD_RESAY=1 so the phase costs a second rather than an
    # hour. Found by the independent review.
    make_fixture ok
    worktree_on_issue 1
    issue_labels "ready,foundation"
    # TWO INTERVALS, not one. mtime has second granularity, so a 1-second
    # interval makes "immediately again" depend on which side of a second
    # boundary the two calls land -- flaky one run in three. Each half gets an
    # interval that cannot be ambiguous for it.
    export AUTOFLEET_HOLD_RESAY=3600
    first="$(in_poll forget_poll_answers foundation_in_flight 2>&1)"
    grep -q "lands alone" <<<"$first" || fail "the first hold said nothing: $first"
    quiet="$(in_poll forget_poll_answers foundation_in_flight 2>&1)"
    grep -q "lands alone" <<<"$quiet" \
      && fail "it re-announced well inside the interval: $quiet"
    echo "ok: a standing hold stays quiet inside the re-say interval"
    # ...and now the same standing hold, with the interval long past.
    export AUTOFLEET_HOLD_RESAY=1
    sleep 2
    later="$(in_poll forget_poll_answers foundation_in_flight 2>&1)"
    grep -q "lands alone" <<<"$later" \
      || fail "a hold standing past the re-say interval never explained itself again: $later"
    echo "ok: ...and says itself again once the interval has passed"
    ;;

  foundation_waiting_once)
    # THE OTHER HOLD: a foundation CANDIDATE declining to join ordinary
    # worktrees. It is the older of the two and it had no phase at all, which is
    # how a fix for its noise shipped broken -- `foundation_in_flight` runs first
    # every iteration, so the only route to this branch is that function falling
    # through, and it cleared the marker on the way past. The marker was
    # write-only and the line printed every poll. Found by the independent
    # review.
    make_fixture ok
    # An ORDINARY worktree in flight, so foundation_in_flight says no...
    worktree_on_issue 4
    issue_labels "ready,docs"
    # ...and the only startable issue is a foundation one, which is the branch.
    cat >"$GH_ISSUES" <<'JSON'
[{"number":1,"title":"the foundation one","body":"","labels":[{"name":"ready"},{"name":"foundation"}]}]
JSON
    start_dispatcher --auto
    wait_for_log "it waits for"
    # NAMED, not counted: "waiting for the other 2 worktree(s)" named nothing a
    # person could go and land, and the two are never equivalent -- one may be
    # ours and the other a worktree nobody here can close. That is what
    # armaatus/autofleet#46 looked like from the outside, repeating indefinitely.
    grep -q "waits for #4" "$WORK/run.log" \
      || fail "the hold counted what it waits on instead of naming it: $(grep 'foundation issue' "$WORK/run.log")"
    # It said it once. Give it several more passes and it must not say it again.
    before="$(grep -c "it waits for" "$WORK/run.log" || true)"
    sleep 3
    after="$(grep -c "it waits for" "$WORK/run.log" || true)"
    [ "$before" = "$after" ] \
      || fail "the waiting hold is announced every poll ($before then $after in three seconds)"
    echo "ok: a foundation candidate waiting its turn names what it waits on, once"
    grep -q "^worktree create" "$ORCA_CALLS" \
      && fail "it announced the wait and launched the foundation issue anyway"
    echo "ok: ...and it does not launch alongside the ordinary worktree"
    stop_dispatcher
    ;;

  foundation_closed_frees)
    # A foundation issue that has CLOSED -- merged, worktree not yet reaped --
    # is finished, and holding the whole fleet for it until the reap catches up
    # is a stall with nothing left behind it. `poll_issue` returns state and
    # labels; this used only the labels. Found by the independent review.
    make_fixture ok
    worktree_on_issue 1
    issue_labels "ready,foundation"
    issue_state CLOSED
    in_fleet foundation_in_flight >/dev/null 2>&1 \
      && fail "a closed foundation issue still held the launch loop"
    echo "ok: a closed foundation issue holds nothing"
    ;;

  foundation_said_once)
    # A three-hour foundation issue against a 60-second poll is 180 identical
    # lines in fleet.log. The repo's idiom for "once" is a marker in $STATE_DIR
    # that outlives the poll cache -- `queue-labels-$n` and `gaveup-$n` are the
    # same shape -- and the first version of this said it every pass.
    make_fixture ok
    worktree_on_issue 1
    issue_labels "ready,foundation"
    first="$(in_poll forget_poll_answers foundation_in_flight 2>&1)"
    grep -q "lands alone" <<<"$first" || fail "the first hold said nothing: $first"
    again="$(in_poll forget_poll_answers foundation_in_flight 2>&1)"
    grep -q "lands alone" <<<"$again" \
      && fail "the hold is announced once per poll, which is 180 lines for a three-hour issue: $again"
    echo "ok: a standing hold is said once, not once per poll"
    # ...and it is news again when a DIFFERENT issue holds. The marker is keyed
    # on what the hold is for, so a hold that moves is announced.
    #
    # Deliberately not "the labels flapped and came back": the marker is cleared
    # by `launch`, not by the hold lifting, because the independent review found
    # that clearing it on the no-hold path deleted it one step before the other
    # hold could read it. A standing hold that briefly stopped being one, with
    # nothing launched in between, has told the reader nothing new -- so it stays
    # quiet, and that is the trade this phase records rather than papers over.
    worktree_on_issue 2
    third="$(in_poll forget_poll_answers foundation_in_flight 2>&1)"
    grep -q "lands alone" <<<"$third" \
      || fail "a hold for a different issue was never announced: $third"
    grep -q "#2" <<<"$third" || fail "it announced the hold but named the wrong issue: $third"
    echo "ok: ...and a hold that moves to another issue is announced again"
    ;;

  foundation_one_lookup)
    # One answer per poll. The launch loop asks up to MAX_WORKTREES times and
    # the answer cannot change in between except by this loop launching, which
    # is what invalidates it -- so three subprocesses for one answer is the
    # pattern count_startable exists to avoid.
    make_fixture ok
    worktree_on_issue 4
    issue_labels "ready,docs"
    in_poll forget_poll_answers foundation_in_flight foundation_in_flight foundation_in_flight \
      >/dev/null 2>&1
    n="$(grep -c "^worktree list" "$ORCA_CALLS" || true)"
    # `-eq`, not `-le`: a `foundation_in_flight` that never read the list at all
    # would satisfy `-le 1` while answering from nothing. Found by the
    # independent review.
    [ "${n:-0}" = 1 ] \
      || fail "three calls in one poll read the worktree list $n times"
    echo "ok: the answer is read once per poll, not once per candidate"
    ;;

  foundation_frees)
    # ...and only a foundation issue holds it. An ordinary worktree must not
    # stop the fleet filling its other two slots.
    make_fixture ok
    worktree_on_issue 4
    issue_labels "ready,docs"
    in_fleet foundation_in_flight >/dev/null 2>&1 \
      && fail "an ordinary issue in flight held the launch loop"
    echo "ok: an ordinary issue in flight does not hold it"
    ;;

  foundation_none)
    # An empty fleet holds nothing, which is the cold-start path.
    make_fixture ok
    in_fleet foundation_in_flight >/dev/null 2>&1 \
      && fail "an empty fleet held the launch loop"
    echo "ok: an empty fleet holds nothing"
    ;;

  foundation_blind)
    # The label lookup fails. HOLDING is the answer, matching in_flight's
    # documented stance: launching on a guess is the expensive direction, and a
    # foundation issue guessed wrong is the merge conflict the rule exists to
    # avoid. The next pass asks again.
    make_fixture ok
    worktree_on_issue 1
    issue_labels FAIL
    out="$(in_fleet foundation_in_flight 2>&1)"; rc=$?
    [ "$rc" = 0 ] || fail "an unreadable label held nothing (rc=$rc): $out"
    echo "ok: a label lookup that fails holds rather than launches"
    grep -q "cannot be answered" <<<"$out" || fail "it did not say it could not tell: $out"
    echo "ok: ...and says it could not tell, rather than reporting a foundation issue"
    ;;

  foundation_cli_blind)
    # ...and the same when the worktree list itself will not answer. There is
    # then nothing to reason from at all -- not even the count -- so holding is
    # the only honest answer. `live_count` already refuses to guess from this
    # shape; this is the same refusal one question later.
    make_fixture ok
    # A list that comes back in a shape nothing can read, which is what the
    # dispatcher actually sees when the CLI half-answers -- the stub's
    # `worktree list` succeeds in every mode, so making the CLI "fail" would not
    # reach this path.
    printf 'not json at all\n' >"$ORCA_WORKTREES"
    out="$(in_fleet foundation_in_flight 2>&1)"; rc=$?
    [ "$rc" = 0 ] || fail "an unreadable worktree list held nothing (rc=$rc): $out"
    echo "ok: a worktree list that will not parse holds too"
    grep -q "cannot be answered" <<<"$out" || fail "it did not say it could not tell: $out"
    echo "ok: ...and says so rather than reporting an empty fleet"
    ;;

  queue_skips)
    make_fixture ok
    cat >"$GH_ISSUES" <<'JSON'
[{"number":148,"title":"cut the v1 release","body":"","labels":[{"name":"ready"},{"name":"needs-human-step"}]},
 {"number":151,"title":"an ordinary one","body":"","labels":[{"name":"ready"}]}]
JSON
    out="$(in_fleet ready_issues 2>&1)"
    grep -q "^151" <<<"$out" \
      || fail "an ordinary ready issue stopped being startable: $out"
    grep -q "^148" <<<"$out" \
      && fail "an issue no agent may close is still startable, so the fleet opens a worktree per cycle for it: $out"
    echo "ok: an issue whose last step is yours is not startable"
    ;;
  list_declines)
    make_fixture ok
    issue_labels "ready,needs-human-step"
    # `fleet.sh run 148` with nothing owned and nothing live: one pass, then it
    # runs out of queue. If the decline leaked into `wanted` instead of dropping
    # the issue, this would never return.
    # --max-prs 1 bounds it either way: if the decline ever stops working, the
    # run opens its one worktree and stops, and the assertion below fires --
    # rather than the test hanging, which is a much worse way to fail.
    out="$(in_fleet cmd_run --max-prs 1 148 2>&1)"
    grep -q "is labelled needs-human-step" <<<"$out" \
      || fail "an explicitly named issue whose last step is yours was not declined: $out"
    grep -q "worktree create" "$ORCA_CALLS" \
      && fail "it opened a worktree for work no agent may finish: $(cat "$ORCA_CALLS")"
    grep -q "fleet down" <<<"$out" \
      || fail "the run never terminated, so the declined issue stayed in the queue: $out"
    echo "ok: an explicitly named issue whose last step is yours is declined and dropped"
    ;;
  timebox_rearms)
    make_fixture ok
    make_worktree
    make_overdue
    agent_state waiting
    issue_labels "ready,needs-human-step"
    in_fleet enforce_timebox >/dev/null 2>&1
    # The maintainer takes the label off to hand the worktree back to an agent.
    issue_labels "ready"
    out="$(in_fleet enforce_timebox 2>&1)"
    grep -q -- "--interrupt" "$ORCA_CALLS" \
      || fail "the box stayed disarmed after the label came off, so the agent runs uncapped: $out"
    echo "ok: removing the label re-arms the time-box"
    ;;
  labels_unknown)
    make_fixture ok
    make_worktree
    make_overdue
    agent_state waiting
    issue_labels FAIL
    out="$(in_fleet enforce_timebox 2>&1)"
    grep -q -- "--interrupt" "$ORCA_CALLS" \
      && fail "an agent was stopped on a lookup that failed, not on an answer: $out"
    [ -e "$AUTOFLEET_DIR/started/42" ] \
      || fail "the timer was disarmed by a failed lookup, so the box never fires again"
    grep -q "could not read its labels" <<<"$out" \
      || fail "the outage was not reported: $out"
    out="$(in_fleet notice_stalled 2>&1)"
    grep -q "nothing should be asking" <<<"$out" \
      && fail "a failed lookup was frozen as a stall, which is the noise this change removes: $out"
    [ -e "$AUTOFLEET_DIR/stalled-42" ] \
      && fail "the once-per-stall marker was written on a non-answer, so it is never re-evaluated"
    echo "ok: a label lookup that failed stops nothing and decides nothing"
    ;;
  outage_once)
    make_fixture ok
    make_worktree
    make_overdue
    # `working`, not `waiting`: the ordinary state of a grinding overrun, and
    # the one that sends notice_stalled down its clearing branch.
    agent_state working
    issue_labels FAIL
    out="$(in_poll enforce_timebox notice_stalled 2>&1)"
    grep -q "could not read its labels" <<<"$out" \
      || fail "the outage was not reported at all: $out"
    again="$(in_poll enforce_timebox notice_stalled 2>&1)"
    grep -q "could not read its labels" <<<"$again" \
      && fail "it says so every poll: one watcher cleared the other watcher marker: $again"
    echo "ok: an unreadable label is reported once, not once a minute"
    ;;
  one_lookup)
    make_fixture ok
    make_worktree
    add_origin
    make_overdue
    agent_state waiting
    issue_labels "ready,needs-human-step"
    : >"$GH_MERGED"
    # All THREE watchers, in one process, which is what a poll is. reap_abandoned
    # asks the same question as the other two, so a third round-trip is exactly
    # the drift the shared answer exists to stop.
    in_poll reap_abandoned enforce_timebox notice_stalled >/dev/null 2>&1
    n="$(grep -c -- "--json state,labels" "$GH_CALLS")"
    [ "$n" = 1 ] \
      || fail "asked GitHub $n times for one issue's state and labels in one poll"
    echo "ok: one poll asks for an issue's state and labels once"
    ;;
  timebox_clears)
    make_fixture ok
    make_worktree
    make_overdue
    agent_state working
    arm_box_markers
    # A PR opens: the time-box is done with this worktree.
    echo '[{"number":9,"body":"Closes #42"}]' >"$GH_PRS"
    in_fleet enforce_timebox >/dev/null 2>&1
    assert_no_box_markers "the PR-opened exit"
    echo "ok: the time-box leaves nothing behind when it lets an issue go"
    ;;
  stop_clears)
    make_fixture ok
    make_worktree
    make_overdue
    agent_state working
    arm_box_markers
    # Nothing exempts it any more, so this pass takes the stop.
    echo '[]' >"$GH_PRS"; issue_labels "ready"
    out="$(in_fleet enforce_timebox 2>&1)"
    grep -q -- "--interrupt" "$ORCA_CALLS" \
      || fail "it did not reach the stop, so this asserts nothing: $out"
    assert_no_box_markers "the stop"
    echo "ok: the stop leaves nothing behind either"
    ;;
  own_clears)
    make_fixture ok
    make_worktree
    make_overdue
    agent_state working
    # Everything a previous worktree for this issue leaves standing, armed by
    # driving the dispatcher through the poll that writes each one. `stalled-`
    # and `stall-labels-` are alternatives -- notice_stalled clears one when it
    # writes the other -- so they need two arrangements, not one.
    arm_box_markers
    agent_state waiting; issue_labels "ready"
    in_fleet notice_stalled >/dev/null 2>&1
    for m in $BOX_MARKERS stalled; do
      [ -e "$AUTOFLEET_DIR/$m-42" ] \
        || fail "could not arm $m-42, so the assertion that follows would be vacuous"
    done
    # `live_worktrees` skips an ARCHIVED worktree, so `in_flight` reads free and
    # the dispatcher opens a SECOND worktree for an issue whose markers are all
    # still set. Each of them throttles a message to once, so the new worktree
    # inherits silence: a standing `stalled-42` makes notice_stalled say nothing
    # at all for an agent that is genuinely stuck.
    in_fleet own 42 "$WORK/wt" >/dev/null 2>&1
    for m in $BOX_MARKERS stalled; do
      [ -e "$AUTOFLEET_DIR/$m-42" ] \
        && fail "$m-42 survived into a fresh worktree, which is silenced by it"
    done
    # ...and the other half of that pair.
    issue_labels FAIL
    in_fleet notice_stalled >/dev/null 2>&1
    [ -e "$AUTOFLEET_DIR/stall-labels-42" ] \
      || fail "could not arm stall-labels-42, so the assertion that follows would be vacuous"
    in_fleet own 42 "$WORK/wt" >/dev/null 2>&1
    [ -e "$AUTOFLEET_DIR/stall-labels-42" ] \
      && fail "stall-labels-42 survived into a fresh worktree, which is silenced by it"
    echo "ok: a fresh worktree starts with nothing already said on its behalf"
    ;;
  one_card)
    make_fixture ok
    make_worktree
    make_overdue
    agent_state waiting
    issue_labels "ready,needs-human-step"
    in_poll enforce_timebox notice_stalled >/dev/null 2>&1
    n="$(grep -c "waiting for you" "$ORCA_CALLS")"
    [ "$n" = 1 ] \
      || fail "put $n near-duplicate comments on the board in one poll"
    grep -q "past the time-box" "$ORCA_CALLS" \
      || fail "the comment that survived does not say it is past the box: $(cat "$ORCA_CALLS")"
    grep -q "not a stall" "$ORCA_CALLS" \
      || fail "the comment that survived does not say it is not a stall: $(cat "$ORCA_CALLS")"
    echo "ok: one poll leaves one board comment, and it says both things"
    ;;
  abandon_blocked)
    make_fixture ok
    make_worktree
    add_origin
    quiet_issue
    issue_labels "blocked"
    out="$(warn_then_release)"
    [ -d "$WORK/wt" ] && fail "a blocked issue's clean worktree still holds a slot: $out"
    [ -e "$AUTOFLEET_DIR/worktrees/42" ] \
      && fail "the worktree is gone but the issue is still owned, so the cap still counts it"
    grep -q "went blocked" <<<"$out" || fail "it did not say why it released it: $out"
    echo "ok: a worktree whose issue went blocked is released"
    ;;
  abandon_closed)
    make_fixture ok
    make_worktree
    add_origin
    quiet_issue
    issue_state CLOSED
    out="$(warn_then_release)"
    [ -d "$WORK/wt" ] && fail "a closed issue's clean worktree still holds a slot: $out"
    grep -q "closed" <<<"$out" || fail "it did not say why it released it: $out"
    echo "ok: a worktree whose issue closed with no merged PR is released"
    ;;
  abandon_human_step)
    make_fixture ok
    make_worktree
    add_origin
    quiet_issue
    # #139: the write its issue needs is one guard.py refuses from a fleet
    # worktree, so its agent correctly produced no PR, labelled the issue and
    # stopped. reap_merged waits for a merged PR that can never exist.
    issue_labels "ready,needs-human-step"
    out="$(warn_then_release)"
    [ -d "$WORK/wt" ] && fail "an issue no agent may close still holds a slot: $out"
    grep -q "needs-human-step" <<<"$out" || fail "it did not say why it released it: $out"
    echo "ok: a worktree whose last step is yours is released once it holds nothing"
    ;;
  abandon_keeps_dirty)
    make_fixture ok
    make_worktree
    add_origin
    quiet_issue
    issue_labels "blocked"
    dirty_worktree
    out="$(release_pass)"
    [ -d "$WORK/wt" ] || fail "it deleted uncommitted work on the strength of a label: $out"
    [ -e "$AUTOFLEET_DIR/worktrees/42" ] \
      || fail "it kept the directory but disowned the issue, so nothing looks at it again"
    grep -q "uncommitted" <<<"$out" || fail "it did not say what is in there: $out"
    grep -q "worktree rm" "$ORCA_CALLS" \
      && fail "it attempted the removal anyway, on a worktree holding uncommitted work"
    # Once per worktree, not once per poll.
    again="$(release_pass)"
    grep -q "uncommitted" <<<"$again" && fail "it says so every poll: $again"
    echo "ok: a dirty worktree is kept, and it says what it holds"
    ;;
  abandon_keeps_commits)
    make_fixture ok
    make_worktree
    add_origin
    quiet_issue
    issue_labels "blocked"
    commit_ahead
    out="$(release_pass)"
    [ -d "$WORK/wt" ] || fail "it deleted the only copy of a commit: $out"
    grep -q "not in origin/main" <<<"$out" || fail "it did not say what is in there: $out"
    grep -q "worktree rm" "$ORCA_CALLS" && fail "it attempted the removal anyway: $out"
    echo "ok: a worktree carrying commits that are nowhere else is kept"
    ;;
  abandon_unknown_git)
    make_fixture ok
    make_worktree
    quiet_issue
    issue_labels "blocked"
    # No origin at all, so there is nothing to compare against. That is the third
    # answer, and reading it as "holds nothing" is how a fix like this destroys
    # the work it was written to protect.
    out="$(release_pass)"
    [ -d "$WORK/wt" ] || fail "it removed a worktree it could not read: $out"
    grep -q "could not be read" <<<"$out" || fail "it did not say it could not tell: $out"
    echo "ok: a git that cannot answer is not read as an empty worktree"
    ;;
  abandon_leaves_working)
    make_fixture ok
    make_worktree
    add_origin
    quiet_issue
    agent_state working
    out="$(release_pass)"
    [ -d "$WORK/wt" ] || fail "it removed the worktree of an agent that is still working: $out"
    [ -e "$AUTOFLEET_DIR/worktrees/42" ] \
      || fail "it disowned an issue that is still being worked, so the cap stops counting it"
    grep -q "worktree rm" "$ORCA_CALLS" && fail "it attempted a removal with no reason to: $out"
    [ -n "$out" ] && fail "it had nothing to say and said it anyway: $out"
    echo "ok: an ordinary in-flight worktree is left alone"
    ;;
  abandon_timebox)
    make_fixture ok
    make_worktree
    add_origin
    make_overdue
    quiet_issue
    agent_state working
    in_fleet enforce_timebox >/dev/null 2>&1
    [ -e "$AUTOFLEET_DIR/gaveup-42" ] \
      || fail "the box stopped the agent without recording it, so nothing else can act on it"
    out="$(warn_then_release)"
    [ -d "$WORK/wt" ] && fail "#44's case again: three hours, nothing produced, slot held: $out"
    [ -e "$AUTOFLEET_DIR/gaveup-42" ] \
      || fail "the record died with the worktree, so the queue hands the issue straight back"
    echo "ok: a timed-out worktree holding nothing is released, and the record outlives it"
    ;;
  gaveup_not_restarted)
    make_fixture ok
    make_worktree
    add_origin
    make_overdue
    quiet_issue
    agent_state working
    cat >"$GH_ISSUES" <<'JSON'
[{"number":42,"title":"the one that ground for three hours","body":"","labels":[{"name":"ready"}]}]
JSON
    in_fleet enforce_timebox >/dev/null 2>&1
    # --max-prs 1 bounds this either way: if the decline stops working the run
    # opens its one worktree and stops, and the assertion below fires -- rather
    # than the test hanging, which is a much worse way to fail.
    out="$(in_fleet cmd_run --auto --max-prs 1 2>&1)"
    grep -q "worktree create" "$ORCA_CALLS" \
      && fail "it released the slot and handed it straight back to the same issue: $(cat "$ORCA_CALLS")"
    [ -d "$WORK/wt" ] \
      && fail "the poll never released the worktree, so the decline below asserts nothing"
    grep -q "fleet down" <<<"$out" \
      || fail "the run never terminated: a gave-up issue is still being counted as startable: $out"
    echo "ok: the slot a gave-up issue frees does not go straight back to it"
    ;;
  gaveup_retry)
    make_fixture ok
    make_worktree
    add_origin
    make_overdue
    quiet_issue
    agent_state working
    in_fleet enforce_timebox >/dev/null 2>&1
    [ -e "$AUTOFLEET_DIR/gaveup-42" ] \
      || fail "could not arm gaveup-42, so the assertion that follows would be vacuous"
    out="$(in_fleet cmd_retry 42 2>&1)"
    [ -e "$AUTOFLEET_DIR/gaveup-42" ] \
      && fail "retry left the record standing, so the issue is still declined: $out"
    grep -q "startable again" <<<"$out" || fail "retry said nothing useful: $out"
    echo "ok: fleet.sh retry hands a gave-up issue back to the queue"
    ;;
  abandon_warns_first)
    make_fixture ok
    make_worktree
    add_origin
    quiet_issue
    issue_labels "blocked"
    agent_state working
    out="$(release_pass)"
    [ -d "$WORK/wt" ] \
      || fail "it removed the worktree on the pass that found the reason, with no notice: $out"
    grep -q "next pass" <<<"$out" || fail "it did not say what happens next: $out"
    grep -q -- "--interrupt" "$ORCA_CALLS" \
      || fail "it warned the board and left the agent working against a rig that is going"
    grep -q "worktree rm" "$ORCA_CALLS" && fail "it removed it anyway: $(cat "$ORCA_CALLS")"
    echo "ok: the pass that finds a reason warns, and removes nothing"
    ;;
  abandon_warned_saved)
    make_fixture ok
    make_worktree
    add_origin
    quiet_issue
    issue_labels "blocked"
    release_pass >/dev/null 2>&1
    # The minute of notice is only worth having if it is really re-asked.
    commit_ahead
    out="$(release_pass)"
    [ -d "$WORK/wt" ] \
      || fail "it removed a worktree that had work in it by the time it acted: $out"
    grep -q "not in origin/main" <<<"$out" || fail "it did not say what saved it: $out"
    echo "ok: work that lands during the warning keeps the worktree"
    ;;
  abandon_two_keeps)
    make_fixture ok
    make_worktree
    quiet_issue
    issue_labels "blocked"
    # No origin yet: git cannot answer, and that is said once.
    first="$(release_pass)"
    grep -q "could not be read" <<<"$first" || fail "the unreadable case was not reported: $first"
    # Now it can answer, and there is something in there. One shared marker would
    # swallow this, and the board would go on claiming git was unreadable.
    add_origin
    dirty_worktree
    out="$(release_pass)"
    grep -q "uncommitted" <<<"$out" \
      || fail "the second keep was silenced by the first one's marker: $out"
    echo "ok: an unreadable git does not silence the line that says what is in there"
    ;;
  gaveup_pruned)
    make_fixture ok
    make_worktree
    add_origin
    make_overdue
    quiet_issue
    agent_state working
    in_fleet enforce_timebox >/dev/null 2>&1
    [ -e "$AUTOFLEET_DIR/gaveup-42" ] \
      || fail "could not arm gaveup-42, so the assertion that follows would be vacuous"
    # A person picks it up by hand and its PR lands.
    issue_state CLOSED
    out="$(in_fleet prune_gaveup 2>&1)"
    [ -e "$AUTOFLEET_DIR/gaveup-42" ] \
      && fail "the record outlived the work: status lists a finished issue forever, and the file never goes"
    grep -q "dropping the record" <<<"$out" || fail "it dropped it silently: $out"
    echo "ok: a give-up record is dropped once its issue lands"
    ;;
  list_says_declined)
    make_fixture ok
    issue_labels "ready,needs-human-step"
    out="$(in_fleet cmd_run --max-prs 1 148 2>&1)"
    grep -q "fleet down" <<<"$out" || fail "the run never terminated: $out"
    grep -q "every issue it was given has landed$" <<<"$out" \
      && fail "it reported an issue it declined as landed: $out"
    grep -q "declined" <<<"$out" || fail "the last line does not say what really happened: $out"
    echo "ok: a run that declined its issues does not report that they landed"
    ;;
  abandon_reason_flickers)
    make_fixture ok
    make_worktree
    add_origin
    quiet_issue
    agent_state working
    # 1. It goes blocked, and the first pass warns.
    issue_labels "blocked"
    release_pass >/dev/null 2>&1
    [ -e "$AUTOFLEET_DIR/warned-42" ] \
      || fail "could not arm warned-42, so the assertion that follows would be vacuous"
    # 2. unblock.yml relabels it on somebody else's merge and the reason is gone.
    issue_labels "ready"
    out="$(release_pass)"
    [ -n "$out" ] && fail "it had nothing to say about a worktree with no reason to release: $out"
    [ -e "$AUTOFLEET_DIR/warned-42" ] \
      && fail "the spent warning outlived the reason that bought it"
    # 3. A second dependency is added and it goes blocked again. This pass must
    #    warn, not remove: the notice is per occasion, not once per worktree.
    issue_labels "blocked"
    out="$(release_pass)"
    [ -d "$WORK/wt" ] \
      || fail "it removed the worktree with no notice at all, on a warning spent for an earlier occurrence: $out"
    grep -q "next pass" <<<"$out" || fail "it did not warn the second time: $out"
    # 4. ...and then it goes, so this is a delay rather than a deadlock.
    out="$(release_pass)"
    [ -d "$WORK/wt" ] && fail "the second warning never turned into a release: $out"
    echo "ok: a reason that comes back buys a fresh pass of notice"
    ;;
  abandon_lookup_blind)
    make_fixture ok
    make_worktree
    add_origin
    quiet_issue
    agent_state working
    # 1. Blocked, and warned.
    issue_labels "blocked"
    release_pass >/dev/null 2>&1
    [ -e "$AUTOFLEET_DIR/warned-42" ] \
      || fail "could not arm warned-42, so the assertion that follows would be vacuous"
    # 2. `gh` cannot answer. That is the third answer, not "it stopped being
    #    blocked", and the difference is a warning that is still owed.
    issue_labels FAIL
    out="$(release_pass)"
    [ -e "$AUTOFLEET_DIR/warned-42" ] \
      || fail "a failed lookup wiped a warning still owed to a reason nobody could read: $out"
    grep -q "could not read" <<<"$out" || fail "it discarded the pass in silence: $out"
    [ -d "$WORK/wt" ] || fail "it removed the worktree on a lookup that never answered: $out"
    # 3. The outage lasts. Once per outage, not once per poll.
    again="$(release_pass)"
    grep -q "could not read" <<<"$again" && fail "it says so every poll: $again"
    # 4. It ends, still blocked. The warning was never lost, so this pass
    #    releases rather than starting the notice over.
    issue_labels "blocked"
    out="$(release_pass)"
    [ -d "$WORK/wt" ] \
      && fail "the outage restarted the notice; under a flaky gh the release never happens: $out"
    echo "ok: a lookup that failed leaves the markers, and the notice, where they were"
    ;;
  status_stale)
    make_fixture ok
    make_repo_git
    dispatcher_running
    # What a real dispatcher records at start: the fleet.sh it actually parsed.
    in_fleet record_dispatcher
    merge_fleet_fix "a fix the running dispatcher never parsed"
    out="$(in_fleet cmd_status 2>&1)"
    grep -q "up since" <<<"$out" \
      || fail "status does not say when the dispatcher started: $out"
    grep -qi "not live" <<<"$out" \
      || fail "a dispatcher older than fleet.sh was not reported as stale: $out"
    grep -q "a fix the running dispatcher never parsed" <<<"$out" \
      || fail "it did not name the commit that is missing from it: $out"
    grep -qi "restart" <<<"$out" \
      || fail "it did not say a restart is what makes the fix live: $out"
    grep -q "AUTOFLEET_MAX" <<<"$out" \
      || fail "it did not say the cap is read at start too, so it changes only across a restart: $out"
    echo "ok: a dispatcher older than fleet.sh is reported stale, by commit"
    ;;
  status_current)
    make_fixture ok
    make_repo_git
    dispatcher_running
    in_fleet record_dispatcher
    out="$(in_fleet cmd_status 2>&1)"
    grep -q "up since" <<<"$out" \
      || fail "status does not say when the dispatcher started: $out"
    grep -qi "not live" <<<"$out" \
      && fail "a dispatcher running the file on disk was reported stale: $out"
    echo "ok: a current dispatcher says when it started and nothing more"
    ;;
  status_unrecorded)
    make_fixture ok
    make_repo_git
    dispatcher_running
    # No record at all -- a dispatcher started before this check existed.
    out="$(in_fleet cmd_status 2>&1)"
    grep -qi "cannot say" <<<"$out" \
      || fail "a dispatcher whose fleet.sh nothing recorded was not reported as unknown: $out"
    grep -qi "restart" <<<"$out" \
      || fail "it did not say what to do about it: $out"
    echo "ok: a dispatcher that recorded nothing is 'cannot say', not 'current'"
    ;;
  status_from_worktree)
    make_fixture ok
    make_repo_git
    dispatcher_running
    in_fleet record_dispatcher
    parked="$(git -C "$WORK/repo" rev-parse HEAD)"
    merge_fleet_fix "a fix the running dispatcher never parsed"
    # The agent's worktree still holds exactly the bytes the dispatcher parsed,
    # so a check that hashed the CALLER's copy would find them equal and say the
    # dispatcher is current.
    older_checkout "$parked"
    out="$(in_fleet_at "$WORK/wt2" cmd_status 2>&1)"
    grep -qi "not live" <<<"$out" \
      || fail "asked from a worktree branched before the fix, it called a stale dispatcher current: $out"
    grep -q "a fix the running dispatcher never parsed" <<<"$out" \
      || fail "it did not name the commit that is missing from the dispatcher: $out"
    echo "ok: staleness is about the dispatcher's checkout, not the caller's"
    ;;
  status_draining)
    make_fixture ok
    make_repo_git
    dispatcher_running
    in_fleet record_dispatcher
    merge_fleet_fix "a fix the running dispatcher never parsed"
    : >"$AUTOFLEET_DIR/DRAIN"
    out="$(in_fleet cmd_status 2>&1)"
    grep -q "DRAINING" <<<"$out" || fail "a drain stopped being reported: $out"
    grep -qi "not live" <<<"$out" \
      || fail "a draining dispatcher hid its staleness behind the stop, and a drain is exactly when it keeps running: $out"
    echo "ok: draining and still up says both"
    ;;
  status_stopped)
    make_fixture ok
    make_repo_git
    mkdir -p "$AUTOFLEET_DIR"; : >"$AUTOFLEET_DIR/STOP"
    out="$(in_fleet cmd_status 2>&1)"
    grep -q "STOPPED" <<<"$out" || fail "a hard stop stopped being reported: $out"
    # The two are not the same state and the screen may not blur them: a drain
    # lets agents finish and a stop freezes them, and the person reading this is
    # deciding whether to wait.
    grep -q "DRAINING" <<<"$out" \
      && fail "it called a hard stop a drain, so nothing on the screen says whether the agents are frozen: $out"
    echo "ok: status keeps the two states apart"
    ;;
  status_drained)
    make_fixture ok
    make_repo_git
    mkdir -p "$AUTOFLEET_DIR"; : >"$AUTOFLEET_DIR/STOP"
    out="$(in_fleet cmd_status 2>&1)"
    grep -q "STOPPED" <<<"$out" || fail "a stop stopped being reported: $out"
    grep -q "idle" <<<"$out" \
      || fail "the stop swallowed the line the documented restart waits for: $out"
    echo "ok: a drained fleet says idle while stopped"
    ;;
  status_behind)
    make_fixture ok
    make_repo_git
    dispatcher_running
    in_fleet record_dispatcher
    merged_but_not_pulled "a fix that merged while the dispatcher ran"
    out="$(in_fleet cmd_status 2>&1)"
    grep -qi "not live" <<<"$out" \
      || fail "a fix merged under a dispatcher whose checkout never pulled was reported as live: $out"
    grep -q "a fix that merged while the dispatcher ran" <<<"$out" \
      || fail "it did not name the merged commit: $out"
    grep -q "pull --ff-only" <<<"$out" \
      || fail "it advised a restart that on its own would change nothing: $out"
    # The steps in docs/WORKFLOW.md's order, which is the section this output
    # tells the reader to go and read. A screen that contradicts the page it
    # cites is worse than either alone.
    order="$(printf '%s\n' "$out" \
      | sed -n 's/.*stop\.sh.*/stop/p; s/.*pull --ff-only.*/pull/p; s/.*fleet\.sh resume.*/resume/p' \
      | tr '\n' ' ')"
    [ "$order" = "stop pull resume " ] \
      || fail "the steps are not in the order WORKFLOW.md gives them ($order): $out"
    echo "ok: merged-but-not-pulled is reported, and the pull sits where the doc puts it"
    ;;
  status_behind_revert)
    make_fixture ok
    make_repo_git
    dispatcher_running
    in_fleet record_dispatcher
    parked="$(git -C "$WORK/repo" rev-parse HEAD)"
    merged_but_not_pulled "a fix that merged while the dispatcher ran"
    revert_on_origin "$parked"
    out="$(in_fleet cmd_status 2>&1)"
    grep -qi "not live" <<<"$out" \
      && fail "it asked for a pull and a restart for bytes already running: $out"
    grep -q "up since" <<<"$out" \
      || fail "it stopped saying when the dispatcher started: $out"
    echo "ok: commits that cancel out are not something to pull for"
    ;;
  status_unreadable)
    make_fixture ok
    make_repo_git
    dispatcher_running
    in_fleet record_dispatcher
    # Asked from a second checkout, because a fleet.sh nothing can read is also
    # a fleet.sh nothing can source.
    older_checkout "$(git -C "$WORK/repo" rev-parse HEAD)"
    chmod 000 "$WORK/repo/scripts/fleet/fleet.sh"
    out="$(in_fleet_at "$WORK/wt2" cmd_status 2>&1)"
    chmod 644 "$WORK/repo/scripts/fleet/fleet.sh"
    grep -qi "cannot say" <<<"$out" \
      || fail "a file it could not read was reported as an answer: $out"
    grep -qi "STALE" <<<"$out" \
      && fail "it read a permission error as a change to the file: $out"
    echo "ok: a hash nobody could take is 'cannot say', not 'stale'"
    ;;
  status_names_root)
    make_fixture ok
    make_repo_git
    dispatcher_running
    in_fleet record_dispatcher
    parked="$(git -C "$WORK/repo" rev-parse HEAD)"
    merge_fleet_fix "a fix the running dispatcher never parsed"
    older_checkout "$parked"
    out="$(in_fleet_at "$WORK/wt2" cmd_status 2>&1)"
    grep -q "cd $WORK/repo && ./scripts/fleet/fleet.sh run --auto" <<<"$out" \
      || fail "read from a worktree, it told you to start a dispatcher in that worktree: $out"
    grep -q "cd $WORK/wt2" <<<"$out" \
      && fail "it named the caller's worktree, which the fleet removes when its PR merges: $out"
    echo "ok: the restart it prints names the dispatcher's own checkout"
    ;;
  status_recycled)
    make_fixture ok
    make_repo_git
    hold_pidfile_with_stranger
    out="$(in_fleet cmd_status 2>&1)"
    grep -q "running   (pid $HELD_PID)" <<<"$out" \
      && fail "a pidfile whose pid the OS recycled onto a stranger was reported as a running dispatcher: $out"
    grep -q "^idle" <<<"$out" \
      || fail "it said neither running nor idle about a pid that is not a dispatcher: $out"
    echo "ok: status asks the same question run does, so the two cannot disagree"
    ;;
  stop_spares_stranger)
    make_fixture ok
    hold_pidfile_with_stranger
    out="$(in_fleet cmd_stop --now 2>&1)"
    kill -0 "$HELD_PID" 2>/dev/null \
      || fail "stop --now signalled a pid out of a stale pidfile, and it was somebody else's process: $out"
    grep -q "dispatcher stopped" <<<"$out" \
      && fail "it reported stopping a dispatcher it never found: $out"
    grep -q "not one" <<<"$out" \
      || fail "it said nothing about a pidfile naming something that is not a dispatcher: $out"
    echo "ok: stop --now checks what it is about to signal, the way lib.sh does"
    ;;
  stop_stops_dispatcher)
    make_fixture ok
    hold_pidfile_with_dispatcher
    out="$(in_fleet cmd_stop --now 2>&1)"
    pid_gone "$HELD_PID" \
      || fail "stop --now left the dispatcher running; the check it gained is refusing everything: $out"
    grep -q "dispatcher stopped" <<<"$out" \
      || fail "it stopped the dispatcher and did not say so: $out"
    echo "ok: ...and still stops the one that is really there"
    ;;
  run_blind_ps)
    make_fixture ok
    hold_pidfile_with_dispatcher
    blind_ps
    out="$(run_one_pass)"; rc=$?
    [ "$rc" = 0 ] \
      || fail "a ps that would not answer held the fleet down, which is the failure the check exists to avoid: $out"
    grep -q "WARNING" <<<"$out" \
      || fail "it started over an unverifiable pid in silence, and that silence IS the two-dispatcher case: $out"
    grep -q "ps -p $HELD_PID" <<<"$out" \
      || fail "the warning does not name the pid it could not identify, nor how to find out: $out"
    # Not a bare `kill`: the whole reason this branch exists is that nothing
    # established what that pid is, and WORKFLOW.md now says the same.
    grep -q "kill $HELD_PID" <<<"$out" \
      && fail "it handed out a kill for a pid it had just said it could not identify: $out"
    echo "ok: an unanswerable ps starts the fleet, and says it could not tell"
    ;;
  status_blind_ps)
    make_fixture ok
    make_repo_git
    hold_pidfile_with_dispatcher
    blind_ps
    out="$(in_fleet cmd_status 2>&1)"
    # The idle LINE, not the word: restart_advice prints "until it says idle" in
    # the instructions right below, and grepping for that would pass on anything.
    grep -q "^idle" <<<"$out" \
      && fail "a live dispatcher ps would not name was reported as idle, which sends you to start a second: $out"
    grep -q "$HELD_PID" <<<"$out" \
      || fail "it did not name the pid it could not identify: $out"
    echo "ok: alive-but-unidentifiable is not idle"
    ;;
  stop_blind_ps)
    make_fixture ok
    hold_pidfile_with_dispatcher
    blind_ps
    out="$(in_fleet cmd_stop --now 2>&1)"
    pid_gone "$HELD_PID" \
      || fail "--now interrupted the agents, said nothing was there, and left the dispatcher polling: $out"
    grep -q "dispatcher stopped" <<<"$out" \
      || fail "it stopped the dispatcher and did not say so: $out"
    grep -q "not one" <<<"$out" \
      && fail "it called a dispatcher it had just signalled 'not one': $out"
    echo "ok: --now keeps its promise when ps will not answer"
    ;;
  run_refuses)
    make_fixture ok
    hold_pidfile_with_dispatcher
    out="$(run_one_pass)"; rc=$?
    [ "$rc" = 0 ] \
      && fail "a second dispatcher started while one was already running: $out"
    grep -q "$HELD_PID" <<<"$out" \
      || fail "it refused without naming the pid that holds it, which is the one thing you need: $out"
    grep -q "kill $HELD_PID" <<<"$out" \
      || fail "it did not say how to take over; a person restarting a stale dispatcher is doing the right thing: $out"
    # Both takeovers, because they cost different things: a drain is safe with
    # agents mid-work (#183) but waits hours for their PRs, and a bare kill is
    # immediate and gives up the reaping. A refusal that named only one sends
    # somebody to the wrong one.
    grep -q "stop.sh" <<<"$out" \
      || fail "it never mentions the stop, so nothing warns that a restart via stop.sh freezes every agent: $out"
    [ "$(cat "$AUTOFLEET_DIR/fleet.pid")" = "$HELD_PID" ] \
      || fail "the refusal took the pidfile anyway, so the running dispatcher's own exit would no longer release it"
    echo "ok: a second dispatcher is refused, by pid, and told how to take over"
    ;;
  run_stale_recycled)
    make_fixture ok
    hold_pidfile_with_stranger
    out="$(run_one_pass)"; rc=$?
    [ "$rc" = 0 ] \
      || fail "a pidfile whose pid the OS recycled onto a stranger refused to start the fleet at all: $out"
    grep -q "fleet up" <<<"$out" \
      || fail "it never started: $out"
    [ "$(cat "$AUTOFLEET_DIR/fleet.pid" 2>/dev/null)" = "$HELD_PID" ] \
      && fail "it started and left the stranger's pid in the pidfile"
    echo "ok: a recycled pid is not a dispatcher, and does not hold the fleet down"
    ;;
  run_stale_gone)
    make_fixture ok
    hold_pidfile_with_ghost
    out="$(run_one_pass)"; rc=$?
    [ "$rc" = 0 ] \
      || fail "a pidfile left by a killed dispatcher refused to start the fleet at all: $out"
    grep -q "fleet up" <<<"$out" \
      || fail "it never started: $out"
    echo "ok: a pidfile whose process is gone does not refuse"
    ;;
  status_keeps_cache)
    # #35's Acceptance, named in the issue and missing from the first fix: "A
    # test: arm `interrupted-$n`, run `status`, assert the marker survives", and
    # "fleet.sh status leaves $STATE_DIR byte-identical".
    #
    # Why it matters rather than being tidy: `interrupted-$num` is the ONLY thing
    # stopping `reap_abandoned` re-interrupting an agent that `enforce_timebox`
    # interrupted earlier in the same pass, and `carded-$num` is the only thing
    # stopping a second board comment. docs/WORKFLOW.md tells you to run `status`
    # in a loop until it says idle, so every watch of a working fleet re-armed
    # both. Asserted against a fleet with NO dispatcher, which is the ordinary
    # case and the one the conditional fix still wrote through.
    make_fixture ok
    mkdir -p "$AUTOFLEET_DIR/poll-cache"
    : >"$AUTOFLEET_DIR/poll-cache/interrupted-42"
    : >"$AUTOFLEET_DIR/poll-cache/carded-42"
    printf 'OPEN\tready\n' >"$AUTOFLEET_DIR/poll-cache/issue-42"
    # One status first, then the snapshot, then another: sourcing fleet.sh
    # `mkdir -p`s its own state directories, which is not what "byte-identical"
    # is about. What #35 is about is a status in a WATCH LOOP changing state --
    # so the question is whether the second one differs from the first.
    # `in_fleet_keeping_cache`, NOT `in_fleet`: this phase's whole subject is
    # whether `cmd_status` leaves the cache alone, and `in_fleet` empties it
    # first to model one pass. Through that helper this would assert nothing.
    in_fleet_keeping_cache cmd_status >/dev/null 2>&1
    before="$(cd "$AUTOFLEET_DIR" && find . | sort | cksum)"
    out="$(in_fleet_keeping_cache cmd_status 2>&1)"
    [ -e "$AUTOFLEET_DIR/poll-cache/interrupted-42" ] \
      || fail "status dropped interrupted-42, so the next pass re-interrupts an agent the time-box already stopped"
    [ -e "$AUTOFLEET_DIR/poll-cache/carded-42" ] \
      || fail "status dropped carded-42, so the next pass writes a second board comment under whoever is working in there"
    [ -e "$AUTOFLEET_DIR/poll-cache/issue-42" ] \
      || fail "status dropped issue-42, so every watcher re-issues the gh lookup poll_issue exists to avoid"
    after="$(cd "$AUTOFLEET_DIR" && find . | sort | cksum)"
    [ "$after" = "$before" ] \
      || fail "status changed \$STATE_DIR; the acceptance is that it leaves it byte-identical. before=$before after=$after, now holding: $(cd "$AUTOFLEET_DIR" && find . | sort | tr '\n' ' ')"
    # ...and with a dispatcher that ps cannot see, which is where the conditional
    # form of this fix was still wrong: `||` reads "alive but ps would not say"
    # as "no dispatcher" and wipes a LIVE dispatcher's cache.
    make_repo_git
    dispatcher_running
    blind_ps
    in_fleet_keeping_cache cmd_status >/dev/null 2>&1
    [ -e "$AUTOFLEET_DIR/poll-cache/interrupted-42" ] \
      || fail "status wiped a live dispatcher's cache on a host where ps will not answer -- the three-answer conflation, unfixed"
    echo "ok: status leaves the poll cache alone, with and without a ps that answers"
    ;;
  cap_ends_on_merge)
    # #36's Acceptance asked for this by name -- "a phase asserting the reap
    # happens after the cap is reached" -- and its Design notes said why: "the
    # test is the point: tests/test_fleet.sh uses --max-prs 1 only as a loop
    # bound, never asserting the drain, which is why this survived". It still
    # did. `list_declines`, `queue_skips` and `abandon_timebox` all pass
    # --max-prs 1 as a safety bound on a run that never reaches the cap.
    #
    # Reaching it is the whole phase, and without the drain-first `queued` guard
    # this run NEVER RETURNS: `wanted` is pruned only inside the launch loop,
    # that loop is gated on `while ! $drain_mode`, and the cap latches the drain.
    # So #148 stays in `wanted` after its PR merges and `reap_merged` disowns it
    # -- `owned` reaches 0, `queued` is stuck at 1, and the dispatcher polls
    # forever with `status` never saying idle and `cmd_run` refusing a second
    # dispatcher. That is #37's wedge, re-created by #36's fix, in the one mode
    # #37's fix does not cover. `run_ended` bounds it, so the failure is a
    # message rather than a hung suite. Found by the independent review.
    make_fixture ok
    add_origin
    issue_state OPEN; issue_labels "ready"
    # No PR yet: the cap has to be reached by a LAUNCH, so the first pass must
    # find #148 startable.
    echo '[]' >"$GH_PRS"
    : >"$GH_MERGED"
    ( in_fleet cmd_run --max-prs 1 148 >"$WORK/run.log" 2>&1 ) &
    HELD_PID=$!
    wait_for_log "worktree(s) opened" \
      || fail "the run never said what its cap was: $(cat "$WORK/run.log")"
    wait_for_log "opening a worktree for #148" \
      || fail "the cap was never reached, so this phase asserts nothing: $(cat "$WORK/run.log")"
    wait_for_log "launching nothing more" \
      || fail "reaching --max-prs did not latch the drain: $(cat "$WORK/run.log")"
    # ...and now the work lands, which is the only thing left that can end it.
    # The launched worktree has to be REAPABLE for that, and the create stub
    # leaves a bare directory: `reap_merged` gives up at `rev-parse` on it and
    # the worktree is owned forever, for a reason that is the fixture rather than
    # the code. Its path is the one the log just named.
    launched="$(sed -n 's/^.*is running in //p' "$WORK/run.log" | head -1)"
    [ -n "$launched" ] || fail "could not tell where the run opened its worktree: $(cat "$WORK/run.log")"
    reapable_worktree_at "$launched"
    echo '[{"number":9,"body":"Closes #148"}]' >"$GH_PRS"
    echo 9 >"$GH_MERGED"
    run_ended "$HELD_PID" \
      || fail "the run never ended after its one PR merged -- \`wanted\` still holds #148 because the prune lives inside the loop the drain just closed: $(cat "$WORK/run.log")"
    HELD_PID=""
    grep -q "everything in flight has landed" "$WORK/run.log" \
      || fail "it exited for some other reason than the work landing: $(cat "$WORK/run.log")"
    echo "ok: --max-prs latches the drain and the run still ends when its work lands"
    ;;
  drain_ends_on_merge)
    make_fixture ok
    make_worktree
    add_origin
    # Past its time-box, and kept only because its PR is open -- which is the
    # state every worktree in a real drain is in.
    make_overdue
    agent_state working
    issue_state OPEN; issue_labels "ready"
    echo '[{"number":9,"body":"Closes #42"}]' >"$GH_PRS"
    : >"$GH_MERGED"
    ( in_fleet cmd_run --auto >"$WORK/run.log" 2>&1 ) &
    HELD_PID=$!
    wait_for_log "fleet up"
    in_fleet cmd_stop >/dev/null 2>&1
    # Either line will do: the drain is noticed at the top of a pass, or in the
    # launch loop when it appears mid-pass, and which one a real `stop.sh` hits
    # is a race this phase must not depend on.
    wait_for_log "draining"
    # ...and now the PR the drain is waiting on merges, which is what a drain
    # that also froze the agents made impossible.
    echo 7 >"$GH_MERGED"
    run_ended "$HELD_PID" \
      || fail "the drain never ended; it is waiting for something only the time-box will now resolve: $(cat "$WORK/run.log")"
    HELD_PID=""
    grep -q "everything in flight has landed" "$WORK/run.log" \
      || fail "it exited for some other reason than the work landing: $(cat "$WORK/run.log")"
    [ -e "$AUTOFLEET_DIR/gaveup-42" ] \
      && fail "the time-box gave the worktree up; that is the three-hours-each ending #183 is about: $(cat "$WORK/run.log")"
    grep -q -- "--interrupt" "$ORCA_CALLS" \
      && fail "a drain interrupted an agent, which is --now's job and not this one"
    echo "ok: a drain ends when the work in flight lands, not at the time-box"
    ;;
  drain_after_stop)
    make_fixture ok
    in_fleet cmd_stop --now >/dev/null 2>&1
    out="$(in_fleet cmd_stop 2>&1)"
    grep -q "STILL SET" <<<"$out" \
      || fail "a drain over a stop said nothing about the stop, and the agents it promises are finishing are frozen: $out"
    grep -q "NOT frozen" <<<"$out" \
      && fail "it told you the agents were free to push while $AUTOFLEET_DIR/STOP was still there: $out"
    [ -e "$AUTOFLEET_DIR/STOP" ] \
      || fail "the drain cleared the stop; lifting one is resume's job and nothing here asked for it: $out"
    echo "ok: a drain does not lift a stop, and does not pretend it did"
    ;;
  stop_writes_drain)
    make_fixture ok
    out="$(in_fleet cmd_stop 2>&1)"
    [ -e "$AUTOFLEET_DIR/DRAIN" ] \
      || fail "a drain wrote no DRAIN file, so nothing tells the dispatcher to stop launching: $out"
    [ -e "$AUTOFLEET_DIR/STOP" ] \
      && fail "a drain wrote the STOP file, which is what guard.py reads -- the PRs it now waits for cannot be opened (#183): $out"
    grep -q "finish" <<<"$out" \
      || fail "it never says the agents may finish, which is the whole difference from --now: $out"
    echo "ok: a drain sets the drain and nothing else"
    ;;
  stop_now_writes_both)
    make_fixture ok
    out="$(in_fleet cmd_stop --now 2>&1)"
    [ -e "$AUTOFLEET_DIR/STOP" ] \
      || fail "--now let the agents keep pushing; it is the escape hatch and #183 must not have widened it: $out"
    [ -e "$AUTOFLEET_DIR/DRAIN" ] \
      || fail "--now froze the agents and left the dispatcher free to launch more: $out"
    echo "ok: a hard stop is a drain plus a freeze"
    ;;
  drain_lets_agents_finish)
    make_fixture ok
    mkdir -p "$AUTOFLEET_DIR"
    # The control first, so the allow below is not the guard failing to see this
    # fleet dir at all: with the STOP file set it must refuse.
    : >"$AUTOFLEET_DIR/STOP"
    [ "$(guard_says 'git push')" = 2 ] \
      || fail "guard.py did not refuse a push under STOP, so this phase cannot tell an allow from a hook it never reached"
    rm -f "$AUTOFLEET_DIR/STOP"
    out="$(in_fleet cmd_stop 2>&1)"
    [ "$(guard_says 'git push')" = 0 ] \
      || fail "a drain still blocks the push, so it waits for PRs it has itself forbidden and ends only at the time-box (#183): $out"
    [ "$(guard_says 'gh pr create --fill')" = 0 ] \
      || fail "a drain still blocks opening the PR, and a merged PR is what releases the worktree it is waiting on: $out"
    echo "ok: a drain lets the work in flight finish"
    ;;
  stop_freezes_agents)
    make_fixture ok
    out="$(in_fleet cmd_stop --now 2>&1)"
    [ "$(guard_says 'git push')" = 2 ] \
      || fail "a hard stop no longer stops a push: $out"
    [ "$(guard_says 'gh pr create --fill')" = 2 ] \
      || fail "a hard stop no longer stops a PR: $out"
    [ "$(guard_says 'ctest --test-dir build')" = 0 ] \
      || fail "it froze the machine rather than what leaves it; reading, building and testing stay open: $out"
    echo "ok: --now still stops every outward effect"
    ;;
  drain_launches_nothing)
    make_fixture ok
    in_fleet cmd_stop >/dev/null 2>&1
    out="$(run_one_pass)"; rc=$?
    [ "$rc" = 0 ] \
      && fail "a drain let a new dispatcher start, so the half a drain must keep is gone: $out"
    grep -qi "drain" <<<"$out" \
      || fail "it refused without saying which of the two states it is in: $out"
    echo "ok: a drain still starts nothing new"
    ;;
  resume_clears_both)
    make_fixture ok
    in_fleet cmd_stop --now >/dev/null 2>&1
    # Both, before: a `resume` asserted against files that were never there
    # passes on a fleet that writes neither.
    for f in STOP DRAIN; do
      [ -e "$AUTOFLEET_DIR/$f" ] \
        || fail "--now did not set $f, so the resume below clears nothing and asserts nothing"
    done
    out="$(in_fleet cmd_resume 2>&1)"
    [ -e "$AUTOFLEET_DIR/STOP" ] \
      && fail "resume left the STOP file, so no agent can push and nothing says why: $out"
    [ -e "$AUTOFLEET_DIR/DRAIN" ] \
      && fail "resume left the DRAIN file, so run goes on refusing with the stop apparently cleared: $out"
    echo "ok: resume clears both files"
    ;;
  stop_drain_blind_dispatcher)
    make_fixture ok
    make_repo_git
    dispatcher_running
    # A dispatcher that recorded what it parsed, and knows the drain file.
    in_fleet record_dispatcher
    out="$(in_fleet cmd_stop 2>&1)"
    grep -q "WARNING" <<<"$out" \
      && fail "it warned about a dispatcher that reads the drain file perfectly well: $out"
    # ...and one from before #183. It leaves a FULL record that simply lacks the
    # drain= line -- record_dispatcher has written root, started, commit and
    # hash since #173 -- so removing the file instead would also empty `root`
    # and only ever exercise the warning's fallback half.
    grep -v '^drain=' "$AUTOFLEET_DIR/dispatcher" >"$WORK/old-record"
    mv "$WORK/old-record" "$AUTOFLEET_DIR/dispatcher"
    out="$(in_fleet cmd_stop 2>&1)"
    grep -q "WARNING" <<<"$out" \
      || fail "a drain that pid $HELD_PID cannot see looked exactly like one it can, while it kept launching worktrees: $out"
    grep -q "kill $HELD_PID" <<<"$out" \
      || fail "the warning does not say how to take that dispatcher over: $out"
    # Its OWN checkout, the way every other restart this file prints does: a
    # relative `run --auto` starts a dispatcher in whatever worktree you typed it.
    grep -q "cd $WORK/repo && ./scripts/fleet/fleet.sh run --auto" <<<"$out" \
      || fail "the takeover does not name the dispatcher's own checkout: $out"
    echo "ok: a dispatcher too old to see the drain is not drained in silence"
    ;;
  live_scoped)
    make_fixture ok
    # One worktree of ours, one belonging to a different repository entirely --
    # which is the ordinary state of a machine running more than one fleet.
    worktree_list "42:wt" "7:foreign:other"
    n="$(in_fleet live_count 2>&1)"
    [ "$n" = 1 ] \
      || fail "counted $n live worktree(s); another repo's worktree is taking a slot from MAX_WORKTREES"
    grep -q -- "--repo path:$WORK/repo" "$ORCA_CALLS" \
      || fail "it asked for every worktree on the machine, not this repo's: $(cat "$ORCA_CALLS")"
    # The same list answers `in_flight`, which matches on an issue NUMBER, so an
    # unrelated repo's #7 must not answer for ours. 0 = in flight, 1 = free.
    in_fleet in_flight 7; rc=$?
    [ "$rc" = 1 ] \
      || fail "another repo's issue 7 reads as in flight here (in_flight said $rc)"
    echo "ok: the count, and what is in flight, are this repository's"
    ;;

  foundation_foreign)
    make_fixture ok
    # A foundation issue lands alone, so the dispatcher holds until nothing of
    # ours is in flight. Unscoped, that never happened: a worktree on another
    # repo held every foundation issue forever, because nothing this fleet does
    # can close one.
    #
    # And it is worse than a held gate. `foundation_in_flight` resolves each
    # linked number against THIS repository, so a foreign worktree on an issue
    # number that does not exist here makes the lookup FAIL -- and the hold is
    # fail-closed, so the dispatcher launches nothing at all. That is what
    # stopped this repo's own fleet on 2026-09-11 with `labels-198` in the
    # holding marker, #198 being armaatus/rommsync-nx#198.
    cat >"$GH_ISSUES" <<'JSON'
[{"number":196,"title":"the foundation one","body":"","labels":[{"name":"ready"},{"name":"foundation"}]}]
JSON
    worktree_list "198:foreign:other"
    n="$(in_fleet live_count 2>&1)"
    [ "$n" = 0 ] \
      || fail "counted $n live worktree(s) with only another repo's open, so the foundation gate never opens"
    out="$(in_fleet foundation_in_flight 2>&1)"; rc=$?
    [ "$rc" = 1 ] \
      || fail "another repo's worktree holds the launch loop (rc=$rc): $out"
    grep -q "cannot be answered" <<<"$out" \
      && fail "the foreign worktree's issue was looked up against this repo, and the failed lookup held the fleet: $out"
    # ...and the foundation issue is startable for no other reason, so the two
    # assertions above are about the gate rather than about an empty queue.
    out="$(in_fleet ready_issues 2>&1)"
    grep -q "^196" <<<"$out" \
      || fail "the foundation issue stopped being startable for some other reason, so the gate above proves nothing: $out"
    echo "ok: another repo's worktree neither holds a foundation issue nor stops the fleet"
    ;;

  selector_git_unusable)
    make_fixture ok
    # "git answered, but unusably." git before 2.31 does not know
    # `--path-format`: it echoes the unrecognised argument back as a flag and
    # still exits 0, so the answer is one git could not give. `dirname` then
    # refuses the leading `--` and produces nothing -- and a guard that reads
    # the string already built from it sees `path:` and lets it through, which
    # the CLI refuses with repo_not_found on every listing, forever. The two
    # phases that reach the fallback do so by git FAILING; this is the other
    # way in. Found by the local review.
    real_git="$(command -v git)"
    cat >"$WORK/bin/git" <<GITSTUB
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in --path-format=*) printf '%s\n.git\n' "\$a"; exit 0 ;; esac
done
exec "$real_git" "\$@"
GITSTUB
    chmod +x "$WORK/bin/git"
    # Through the DRIVER, because that is where the selector lives after #1:
    # `--repo` is an Orca flag and hard rule 2 forbids `fleet.sh` naming one.
    # Resolved fresh with the git stub on PATH, since the driver caches it at
    # source time.
    sel="$( cd "$WORK/repo" && PATH="$WORK/bin:$PATH" bash -c '
      set -uo pipefail
      REPO_ROOT="$PWD"
      . ./scripts/fleet/lib.sh >/dev/null 2>&1
      orca_resolve_repo_selector
    ' 2>&1 )"
    [ "$sel" = "path:$WORK/repo" ] \
      || fail "an unusable answer from git was passed to the CLI as a selector: [$sel]"
    echo "ok: git answering unusably falls back to this checkout, not to a selector the CLI refuses"
    ;;

  create_scoped)
    make_fixture ok
    make_repo_git
    older_checkout "$(git -C "$WORK/repo" rev-parse HEAD)"
    # The OTHER selector callsite. `worktree create` carried a raw
    # `path:$REPO_ROOT` while the listing resolved one properly, so the same
    # `repo_not_found` that blinded `status` stopped `fleet.sh run` from a
    # worktree opening anything at all -- and the two callsites could name
    # different repositories. Found by the local review.
    printf '%s\n' "$WORK/repo" >"$ORCA_REPO_ROOTS"
    in_fleet_at "$WORK/wt2" launch 4 "a title" >/dev/null 2>&1
    grep "^worktree create" "$ORCA_CALLS" | grep -q -- "--repo path:$WORK/repo" \
      || fail "the create names the caller's checkout, not the repository root: $(grep '^worktree create' "$ORCA_CALLS")"
    echo "ok: creating a worktree scopes to the repository root, from a worktree too"
    ;;

  status_worktree_scope)
    make_fixture ok
    make_repo_git
    dispatcher_running
    in_fleet record_dispatcher
    older_checkout "$(git -C "$WORK/repo" rev-parse HEAD)"
    # `--repo path:` names a repository ROOT. `fleet.sh status` is run from
    # wherever you are -- CLAUDE.md points agents in a fleet worktree at it --
    # so a selector built from the CALLER's checkout is a worktree path, which
    # the CLI refuses with repo_not_found. The listing then fails, and a failed
    # listing makes `in_flight` answer "could not tell" for every issue, so
    # `status` offers work that is already running.
    printf '%s\n' "$WORK/repo" >"$ORCA_REPO_ROOTS"
    worktree_list "42:wt"
    out="$(in_fleet_at "$WORK/wt2" cmd_status 2>&1)"
    grep -q "#42" <<<"$out" \
      || fail "asked from a worktree, it could not list what is running: the repo selector did not resolve: $out"
    echo "ok: status asked from a worktree still scopes to the repository"
    ;;

  *)
    echo "usage: tests/test_fleet.sh foundation_holds|foundation_break_is_local|foundation_resays|foundation_waiting_once|foundation_closed_frees|foundation_cold_start|foundation_restart_speaks|foundation_launch_held|foundation_said_once|foundation_one_lookup|foundation_frees|foundation_none|foundation_blind|foundation_cli_blind|create_says|create_warns|card_says|card_quiet|remove_forces|remove_advice|remove_keeps_stack|remove_sweeps_stack|merged_keeps_dirty|merged_keeps_owned|merged_unknown_git|merged_cli_silent|remove_scoped_sweep|stall_expected|stall_reports|timebox_waits|timebox_stops|queue_skips|list_declines|timebox_rearms|labels_unknown|outage_once|one_lookup|timebox_clears|stop_clears|own_clears|one_card|abandon_blocked|abandon_closed|abandon_human_step|abandon_keeps_dirty|abandon_keeps_commits|abandon_unknown_git|abandon_leaves_working|abandon_timebox|gaveup_not_restarted|gaveup_retry|abandon_warns_first|abandon_warned_saved|abandon_two_keeps|gaveup_pruned|list_says_declined|abandon_reason_flickers|abandon_lookup_blind|status_stale|status_current|status_unrecorded|status_from_worktree|status_draining|status_stopped|status_drained|status_behind|status_behind_revert|status_unreadable|status_names_root|run_refuses|run_stale_recycled|run_stale_gone|status_recycled|stop_spares_stranger|stop_stops_dispatcher|run_blind_ps|status_blind_ps|stop_blind_ps|drain_ends_on_merge|drain_after_stop|stop_writes_drain|stop_now_writes_both|drain_lets_agents_finish|stop_freezes_agents|drain_launches_nothing|resume_clears_both|stop_drain_blind_dispatcher|runner_stub|runner_unresolved|selector_git_unusable|create_scoped|live_scoped|foundation_foreign|status_worktree_scope|reap_blind_upstream|poll_empties_cache|restart_after_parked_drain|drain_parked_counted_once|drain_ends_with_parked|status_keeps_cache|cap_ends_on_merge" >&2
    exit 2 ;;
esac
