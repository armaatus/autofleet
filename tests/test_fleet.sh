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
    # A REAL worktree at the path it reports, because the dispatcher provisions
    # one: `launch` runs `setup.sh` inside it before starting the build, and a
    # bare directory has no payload to run.
    "${REAL_GIT:-git}" -C "$WORK_FOR_STUB/repo" worktree add -q --detach \
      "$WORK_FOR_STUB/created" 2>/dev/null || mkdir -p "$WORK_FOR_STUB/created"
    echo "{\"result\":{\"worktree\":{\"path\":\"$WORK_FOR_STUB/created\"}}}"; exit 0 ;;
  "terminal create") echo '{"result":{"terminal":{"handle":"t1"}}}'; exit 0 ;;
  "terminal close")  echo '{"ok":true}'; exit 0 ;;
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
  # ...and the literal FAIL is a `gh` that could not answer AT ALL, which is a
  # different failure from a body it could not parse: the per-poll listing
  # caches the first as "could not tell" and must never cache it as "no PR".
  *"pr list"*)        [ "$(cat "$GH_PRS")" = FAIL ] && { echo "gh: could not connect" >&2; exit 1; }
                      cat "$GH_PRS"; exit 0 ;;
  # ...and the same FAIL shape, for the same reason: `ready_issues` caches its
  # own failure, and "could not tell" read as "the backlog is empty" ends the
  # dispatcher for the night on one blip.
  *"issue list"*)     [ "$(cat "$GH_ISSUES")" = FAIL ] && { echo "gh: could not connect" >&2; exit 1; }
                      cat "$GH_ISSUES"; exit 0 ;;
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

  # A build that does nothing and says what it cost. `$BUILD_CALLS` records every
  # invocation, so a phase can assert that a build was started without one ever
  # running. `--output-format json` is what the dispatcher and `cost.sh` read,
  # so the stub prints that object and nothing else on stdout.
  cat >"$WORK/bin/build-stub" <<'BUILDSTUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$BUILD_CALLS"
[ -n "${BUILD_STUB_SLEEP:-}" ] && sleep "$BUILD_STUB_SLEEP"
printf '{"subtype":"%s","num_turns":%s,"total_cost_usd":%s,"usage":{"input_tokens":1,"output_tokens":2,"cache_read_input_tokens":3,"cache_creation_input_tokens":4}}\n' \
  "${BUILD_STUB_SUBTYPE:-success}" "${BUILD_STUB_TURNS:-7}" "${BUILD_STUB_USD:-0.5}"
exit "${BUILD_STUB_RC:-0}"
BUILDSTUB
  chmod +x "$WORK/bin/build-stub"

  # THE DEFAULT DRIVER'S CALLS, in the vocabulary the assertions already speak.
  #
  # $REAL_GIT is exported for the fixture's OWN git calls, which go around this
  # shim deliberately: a phase that counts how many times one pass read the
  # worktree list must not also be counting the `git worktree list` this
  # fixture ran while setting that pass up.
  #
  # The app-backed driver's fake CLI recorded `worktree create|list|rm` into
  # $ORCA_CALLS, and every phase that asserts "the worktree was created through
  # the driver" greps for those words. The headless driver calls `git worktree
  # add|list|remove` instead, so this shim records the same three words for the
  # same three events and execs the real git for everything else. The
  # alternative was rewriting a hundred assertions to say `worktree add`, which
  # would have changed what they LOOK like without changing what they mean.
  REAL_GIT="$(command -v git)"; export REAL_GIT
  cat >"$WORK/bin/git" <<GITSHIM
#!/usr/bin/env bash
args=("\$@")
i=0
while [ \$i -lt \${#args[@]} ]; do
  case "\${args[\$i]}" in
    -C) i=\$((i + 2)); continue ;;
    -c) i=\$((i + 2)); continue ;;
    *) break ;;
  esac
done
if [ "\${args[\$i]:-}" = worktree ]; then
  case "\${args[\$((i + 1))]:-}" in
    add)    printf 'worktree create %s\\n' "\${args[*]}" >>"\$ORCA_CALLS" ;;
    list)   printf 'worktree list %s\\n'   "\${args[*]}" >>"\$ORCA_CALLS" ;;
    remove) printf 'worktree rm %s\\n'     "\${args[*]}" >>"\$ORCA_CALLS" ;;
  esac
fi
exec "$REAL_GIT" "\$@"
GITSHIM
  chmod +x "$WORK/bin/git"

  ORCA_CALLS="$WORK/calls"; : >"$ORCA_CALLS"
  BUILD_CALLS="$WORK/build-calls"; : >"$BUILD_CALLS"
  export BUILD_CALLS
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
  # THE DEFAULT DRIVER IS THE DEFAULT DRIVER (armaatus/autofleet#151). This
  # fixture used to drive every phase through the app-backed runner against a
  # fake CLI, which meant the driver a host project actually gets was exercised
  # by one phase. `headless` needs nothing but git, so the suite can drive the
  # real thing -- real `git worktree add`, real link files, real pid files --
  # and the phases that are ABOUT the app-backed driver say so by setting
  # AUTOFLEET_RUNNER themselves. The fake CLI stays on PATH for them.
  export AUTOFLEET_RUNNER=headless
  export AUTOFLEET_WORKTREE_ROOT="$WORK/trees"
  # The build command, so nothing in the suite can start a real agent. It
  # writes the result JSON the dispatcher reads and exits, which is what a
  # finished build looks like.
  export AUTOFLEET_BUILD_CMD="$WORK/bin/build-stub"
  export ORCA_CLI_COMMAND="$WORK/bin/orca-stub"
  export AUTOFLEET_DIR="$WORK/fleet"
  # ...and what the payload writes at runtime is ignored, exactly as install.sh
  # arranges in a host repo. Without this the `.env` that `setup.sh` writes into
  # every worktree is an untracked file, and every reap reads it as "this
  # worktree holds uncommitted work" and keeps the worktree forever.
  printf '.env\n.autofleet/run/\n' >"$WORK/repo/.gitignore"

  # THE FIXTURE REPO IS A GIT REPO, WITH THE PAYLOAD IN IT, from the start.
  #
  # Two reasons, both new with armaatus/autofleet#151. The default driver's
  # worktree listing is `git worktree list`, so a fixture whose repo git has
  # never heard of answers "could not read the listing" -- a real answer, and
  # not the one an empty fleet is supposed to give. And `launch` provisions the
  # worktree it opens by running `setup.sh` INSIDE it, so a worktree checked out
  # of a repo whose commit does not carry the payload has no setup.sh to run.
  make_repo_git
  : >"$WORK/planted"
  PATH="$WORK/bin:$PATH"
  export PATH
}

# A worktree the fleet would own: a git repo with one commit, and an owned-file
# naming it.
# A worktree the dispatcher owns, at the path every other helper here calls
# `$WORK/wt`. A REAL one: `git worktree add` in the fixture repo, plus the link
# file the headless driver keeps its issue mapping in.
#
# It used to be a standalone `git init` plus a line in $OWNED_DIR, because the
# driver's worktree listing was fabricated JSON and nothing joined the two. The
# listing is `git worktree list` now, so a worktree the fixture invents and git
# does not know about is invisible to every phase that reads it.
make_worktree() {
  plant_worktree 42 wt
  # ...and OWNED by the dispatcher, which is what `$OWNED_DIR` means. Every
  # reaper and every watcher walks that directory; a worktree git knows about
  # and the fleet does not is invisible to all of them.
  mkdir -p "$AUTOFLEET_DIR/worktrees"
  printf '%s\n' "$WORK/wt" >"$AUTOFLEET_DIR/worktrees/42"
}

# One real worktree: issue $1, at `$WORK/$2`, in repo `$WORK/${3:-repo}`.
plant_worktree() {
  local num="$1" suffix="$2" repo="$WORK/${3:-repo}" path="$WORK/$2"
  [ -d "$repo/.git" ] || make_repo_git_at "$repo"
  "$REAL_GIT" -C "$repo" worktree add -q -b "wt-$suffix" "$path" 2>/dev/null \
    || "$REAL_GIT" -C "$repo" worktree add -q "$path" "wt-$suffix"
  printf '%s\n' "$path" >>"$WORK/planted"
  mkdir -p "$AUTOFLEET_DIR/headless/links"
  [ "$num" = "-" ] \
    || printf '%s\n' "$num" >"$AUTOFLEET_DIR/headless/links/$(printf '%s' "$path" | tr '/' '%')"
}

# A build in `$WORK/wt` that is running, or that has stopped with rc $1.
#
# These replaced `build_running|waiting`. The app-backed runner classified
# a terminal into three states and `notice_stalled` was built on the third; a
# `claude -p` run is running or it is not, and the files below are exactly what
# `fleet_build_state_of` reads.
build_state_for() {
  local num="$1" path="$2" rc="${3:-}" dir="$AUTOFLEET_DIR/builds/$1"
  mkdir -p "$dir" "$AUTOFLEET_DIR/builds/by-path"
  printf '%s\n' "$path" >"$dir/worktree"
  printf '%s\n' "$num" >"$AUTOFLEET_DIR/builds/by-path/$(printf '%s' "$path" | tr '/' '%')"
  if [ -n "$rc" ]; then
    printf '%s\n' "$rc" >"$dir/rc"; rm -f "$dir/pid"
  else
    rm -f "$dir/rc"
    set -m
    ( exec -a "build $dir" sleep 300 ) & BUILD_SLEEPER=$!
    set +m
    printf '%s\n' "$BUILD_SLEEPER" >"$dir/pid"
  fi
}

build_running() {
  local dir; dir="$AUTOFLEET_DIR/builds/42"
  mkdir -p "$dir" "$AUTOFLEET_DIR/builds/by-path"
  rm -f "$dir/rc"
  printf '%s\n' "$WORK/wt" >"$dir/worktree"
  printf '%s\n' 42 >"$AUTOFLEET_DIR/builds/by-path/$(printf '%s' "$WORK/wt" | tr '/' '%')"
  # A pid that is alive and IS ours to signal -- `stop_build_in` really does
  # kill it, which is the whole of what the reaper's warning pass promises. It
  # was `$$` for one round, and the first phase that reached a stop killed the
  # test process itself: the phase exited silently with no failure message at
  # all, which is a much worse way to fail than red.
  #
  # Its own process GROUP, because that is what the driver signals -- the build
  # command is a wrapper seam, so the process holding the credentials is
  # routinely a child of what was forked.
  # ITS COMMAND LINE NAMES THE BUILD DIRECTORY, because that is what the driver
  # identifies its own build by: a pid file outlives a `kill -9` and a reboot,
  # and the number in it is then whatever the system reused it for. A fake build
  # that did not look like one would pass the phases while the identity check
  # rejected every real build, or the other way round.
  set -m
  ( exec -a "build $dir" sleep 300 ) & BUILD_SLEEPER=$!
  set +m
  printf '%s\n' "$BUILD_SLEEPER" >"$dir/pid"
}
build_exited() {
  build_running
  printf '%s\n' "${1:-0}" >"$AUTOFLEET_DIR/builds/42/rc"
  rm -f "$AUTOFLEET_DIR/builds/42/pid"
}
# ...and a build the driver CANNOT DESCRIBE, which is a third answer and not the
# same as "there is no build here". The dispatcher has a record that issue $1
# ran in `$WORK/wt`, and the index that would let the driver answer about it is
# gone -- a build directory half-swept, a fleet directory restored from a
# backup. Read as "nothing is running" it would count the worktree as waiting
# for a person and end a drain with an agent still in there; read as blind it is
# left alone and said once.
build_blind() {
  local num="${1:-42}" dir="$AUTOFLEET_DIR/builds/${1:-42}"
  mkdir -p "$dir"
  printf '%s\n' "$WORK/wt" >"$dir/worktree"
  rm -rf "$AUTOFLEET_DIR/builds/by-path"
  rm -f "$dir/pid" "$dir/rc"
}

# ...and what that run said it cost, which `build_exited` alone does not write.
build_result() {
  mkdir -p "$AUTOFLEET_DIR/builds/42"
  printf '{"subtype":"%s","num_turns":%s,"total_cost_usd":%s}\n' \
    "${1:-success}" "${2:-7}" "${3:-0.5}" >"$AUTOFLEET_DIR/builds/42/result.json"
}

# THE APP-BACKED DRIVER, for the phases that are about IT rather than about the
# dispatcher: how it relays a runtime's own words, how it retries a removal,
# what it does when the CLI cannot be reached. Everything else runs on the
# default driver, which is the point of armaatus/autofleet#151 -- the driver a
# host project gets is the one the suite drives.
use_orca_runner() { export AUTOFLEET_RUNNER=orca; }

# A live worktree the dispatcher owns, linked to issue $1, at `$WORK/wt`.
worktree_on_issue() { worktree_list "$1:wt"; }

# The worktree listing, from `issue:path-suffix[:repo]` triples -- `-` for a
# worktree linked to no issue, and a third field naming a repo other than the
# fixture's, which is what a machine running two fleets looks like (#46).
#
# It CREATES them now rather than describing them. The scope rule it exists to
# exercise is `git worktree list`'s own -- a worktree of another repository is
# simply not in this repository's listing -- so a fixture that only claimed a
# different `repoPath` would be asserting against a filter that no longer
# exists.
worktree_list() {
  local line num suffix repo
  # Everything THIS HELPER planted before, gone: a phase calls it to state the
  # whole listing, not to add to it.
  #
  # Only what it planted. A phase may have a worktree of its own for another
  # purpose -- `older_checkout` makes one to stand in for a checkout branched
  # before a fix -- and a reset that swept every worktree in the repo deleted it
  # out from under the phase that was about to cd into it.
  local existing
  if [ -s "$WORK/planted" ]; then
    while IFS= read -r existing; do
      [ -n "$existing" ] || continue
      "$REAL_GIT" -C "$WORK/repo" worktree remove --force "$existing" 2>/dev/null || true
    done <"$WORK/planted"
    : >"$WORK/planted"
  fi
  rm -rf "$AUTOFLEET_DIR/headless/links"
  for line in "$@"; do
    [ -n "$line" ] || continue
    num="${line%%:*}"; line="${line#*:}"
    suffix="${line%%:*}"
    case "$line" in *:*) repo="${line#*:}" ;; *) repo="repo" ;; esac
    plant_worktree "$num" "$suffix" "$repo"
  done
}

# The two halves of what one `gh issue view N --json state,labels` would print.
issue_labels() { printf '%s' "$1" >"$GH_LABELS"; }
issue_state()  { printf '%s' "$1" >"$GH_STATE"; }

# An `origin` whose `main` is this worktree's HEAD, and a `work` branch tracking
# it. The release check asks what the worktree holds that origin/main does not,
# so a worktree with no origin at all is the "could not tell" case rather than
# the empty one -- which is why every test that expects a removal sets this up.
add_origin() {
  # THE BRANCH IS READ, not assumed. `make_worktree` used to `"$REAL_GIT" init` a
  # standalone repo on a branch called `work`; it is a real `"$REAL_GIT" worktree add`
  # now, on a branch named after the worktree, and a hardcoded `work:main` here
  # pushed nothing and left every reap saying "git could not say what it holds".
  local br; br="$("$REAL_GIT" -C "$WORK/wt" rev-parse --abbrev-ref HEAD)"
  "$REAL_GIT" init -q --bare "$WORK/origin.git"
  "$REAL_GIT" -C "$WORK/wt" remote add origin "$WORK/origin.git" 2>/dev/null || true
  "$REAL_GIT" -C "$WORK/wt" push -q origin "$br:main"
  "$REAL_GIT" -C "$WORK/wt" push -q -u origin "$br"
}

# The same thing for a worktree the run itself opened, whose path the phase does
# not know until the log says so. `add_origin` is hardcoded to $WORK/wt, and
# `reap_merged` gives up at `rev-parse --abbrev-ref HEAD` on a directory that is
# not a git repo -- so a launched worktree was unreapable and any phase that
# waited for one to land waited forever, for a reason that had nothing to do with
# what it was testing.
reapable_worktree_at() {
  local path="$1" bare="$WORK/origin-$(basename "$path").git" br
  # A REAL worktree of the fixture repo already, because the default driver
  # created it with `git worktree add` -- so this only has to give it an
  # upstream. `git init` over the top of one is what it used to do, and that
  # leaves two gits disagreeing about the same directory.
  br="$("$REAL_GIT" -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null)" || br=""
  if [ -z "$br" ]; then
    "$REAL_GIT" init -q -b work "$path"
    "$REAL_GIT" -C "$path" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    br=work
  fi
  "$REAL_GIT" init -q --bare "$bare"
  "$REAL_GIT" -C "$path" remote add origin "$bare" 2>/dev/null || true
  "$REAL_GIT" -C "$path" push -q origin "$br:main"
  "$REAL_GIT" -C "$path" push -q -u origin "$br"
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

# A build that has STOPPED without opening a pull request: the run's own exit
# status and the result it printed. This replaced `make_overdue`, which aged the
# `started/` marker so a wall clock would fire -- there is no wall clock, and
# what the dispatcher reads is the exit.
build_ran_out() { build_exited 1; build_result error_max_turns 400 25.0; }

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

# THE LAUNCH GATE'S OWN COUNT, spelled the way `cmd_run` spells it: one
# `live_worktrees`, counted by `count_worktrees`. These phases used to call a
# `live_count` wrapper in fleet.sh that no production caller had left, so they
# asserted a route the dispatcher does not take -- armaatus/autofleet#71. The
# pair runs inside ONE source of fleet.sh, because the point is that the count
# comes from the listing the gate already holds and not from a second read.
gate_count() {
  rm -rf "$AUTOFLEET_DIR/poll-cache"
  (cd "$WORK/repo" && . ./scripts/fleet/fleet.sh \
    && { list="$(live_worktrees)" || exit 1; count_worktrees "$list"; })
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
  : >"$STUB_DIR/worktrees"
  STUB_CALLS="$STUB_DIR/calls"; : >"$STUB_CALLS"
  export STUB_DIR STUB_CALLS
  cat >"$WORK/repo/scripts/fleet/runner/stub.sh" <<'STUBDRIVER'
#!/usr/bin/env bash
# A runner backed by text files. Records every call it is asked to make.
#
# Nothing here is provided by lib.sh any more: `runner_agent_terminal` was the
# one contract function with no runner in it, and it went with the terminal
# listing it filtered (armaatus/autofleet#151).
stub_say() { printf '%s\n' "$*" >>"$STUB_CALLS"; }

runner_available()       { stub_say available; return 0; }
runner_dispatcher_hint() { echo "tmux new-session -s fleet"; }
runner_set_deadline()    { stub_say "set deadline $1"; return 0; }

runner_worktree_create() {
  local repo="$1" name="$2" issue="$3" path="$STUB_DIR/wt-$3"
  stub_say "worktree create $name $issue"
  # A failure path, which this stub did not have -- so the contract's "the
  # runtime's own words on failure, on STDOUT" was asserted only against the
  # Orca CLI stub, by `create_says`. On stdout deliberately: `launch` captures
  # stdout only, and a driver that answers on stderr reproduces "could not
  # create it:" followed by nothing. Found by the independent review.
  [ -e "$STUB_DIR/create-fails" ] && { echo "the stub refuses to create"; return 1; }
  # A REAL worktree, because the dispatcher provisions one now: `launch` runs
  # `setup.sh` inside it before starting the build, and a bare directory has no
  # payload to run. A driver whose worktrees are not checkouts of the repo it
  # was handed is not a driver this fleet can use.
  # $REAL_GIT, around the shim that records the default driver's git calls: this
  # phase's closing assertion is that NOTHING reached the app's CLI, and it
  # reads the same ledger the shim writes into.
  "${REAL_GIT:-git}" -C "$repo" worktree add -q -b "$name" "$path" 2>/dev/null \
    || { echo "the stub could not add a worktree"; return 1; }
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
runner_build_start() {
  stub_say "build start $1 $2"
  # A driver that cannot start a build at all -- which fails the LAUNCH now,
  # loudly, on the pass that tried it. The app-backed runner used to start the
  # agent from its own hook, so a failure there left a provisioned worktree
  # nobody was working in and nothing said so.
  [ -e "$STUB_DIR/build-fails" ] && return 1
  printf '%s\n' "$2" >"$STUB_DIR/building-$2"
  return 0
}
runner_build_state() {
  stub_say "build state $1"
  # Non-zero is "there is no build here to describe", which is not the same
  # answer as "it has stopped" -- and `notice_build_exit` has to keep them
  # apart, or a running build is reported as having given up.
  [ -e "$STUB_DIR/build-blind" ] && return 1
  [ -e "$STUB_DIR/build-exited" ] && { echo "exited $(cat "$STUB_DIR/build-exited")"; return 0; }
  echo running
}
runner_build_stop() { stub_say "build stop $1"; return 0; }
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
#
# `IN_POLL=true`, because that is the whole of what "inside one pass" means to
# fleet.sh: `cmd_run` sets it beside `forget_poll_answers` and the worktree-list
# cache is open only while it is set. A helper named for a poll that did not set
# it would model a pass with the caching switched off.
in_poll() { (cd "$WORK/repo" && . ./scripts/fleet/fleet.sh; IN_POLL=true; for fn in "$@"; do "$fn"; done); }

# ...and the same pass with the calls written as a SCRIPT rather than as bare
# names. `in_poll` cannot carry these: they take arguments (`launch 44 "..."`,
# `remove_worktree "$WORK/wt"`), shadow a command, and read $POLL_CACHE by name.
# One helper rather than a copy of the preamble in each phase -- what a pass is
# should have one definition in this file, and it nearly got a second. Found by
# the independent review.
#
# `forget_poll_answers` is inside it, unlike `in_poll`, where the phases pass it
# as the first function name.
in_pass() { (cd "$WORK/repo" && . ./scripts/fleet/fleet.sh; IN_POLL=true; forget_poll_answers; eval "$1"); }

# The fixture repo under git, because "which fixes are not live in the running
# dispatcher" is answered in commits and cannot be faked with a hash alone.
make_repo_git_at() {
  mkdir -p "$1"
  "$REAL_GIT" -C "$1" init -q -b main
  "$REAL_GIT" -C "$1" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
}

make_repo_git() {
  "$REAL_GIT" -C "$WORK/repo" init -q -b main
  "$REAL_GIT" -C "$WORK/repo" -c user.email=t@t -c user.name=t add -A
  # `--allow-empty`: `make_fixture` commits the repo now, so a phase that calls
  # this to snapshot the payload may find nothing changed -- and a `commit` that
  # exits 1 for that reason would fail the phase under `set -e`.
  "$REAL_GIT" -C "$WORK/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "the fleet as the dispatcher parsed it"
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

# ...and the same wait for the Nth time it says something, which `wait_for_log`
# cannot do: it greps the whole log, so asking twice for a line already there
# returns at once. Passes are what a phase that must outlast one of them waits
# on, and they need $AUTOFLEET_LOG_PASSES=on to be said at all.
wait_for_passes() {
  local want="$1" i=0 seen
  while [ "$i" -lt 200 ]; do
    # `grep -c` prints 0 AND exits 1 on no match, so a `|| echo 0` fallback makes
    # the substitution two lines and the test says `integer expression expected`.
    # The status is not the test here either: normalise what came back.
    seen="$(grep -c "pass complete" "$WORK/run.log" 2>/dev/null)" || true
    case "${seen:-}" in ''|*[!0-9]*) seen=0 ;; esac
    [ "$seen" -ge "$want" ] && return 0
    sleep 0.1; i=$((i + 1))
  done
  fail "the dispatcher did not finish $want passes: $(cat "$WORK/run.log" 2>/dev/null)"
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

# A backlog of $1 `ready` issues, every one of them already claimed by an open
# PR. That is the ORDINARY state of a fleet whose slate is full, and it is the
# worst case for the per-pass budget: nothing is startable, so the launch loop
# scans the whole list before it gives up. armaatus/autofleet#69.
backlog_all_claimed() {
  local n="$1" i
  {
    printf '['
    for i in $(seq 1 "$n"); do
      [ "$i" = 1 ] || printf ','
      printf '{"number":%s,"title":"issue %s","body":"","labels":[{"name":"ready"}]}' "$i" "$i"
    done
    printf ']\n'
  } >"$GH_ISSUES"
  {
    printf '['
    for i in $(seq 1 "$n"); do
      [ "$i" = 1 ] || printf ','
      printf '{"number":%s,"isDraft":false,"headRefOid":"deadbee","body":"Closes #%s"}' "$((100 + i))" "$i"
    done
    printf ']\n'
  } >"$GH_PRS"
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
    use_orca_runner
    out="$( cd "$WORK/repo" && bash -c '
      set -uo pipefail
      REPO_ROOT="$PWD"
      . ./scripts/fleet/lib.sh
      runner_worktree_list >/dev/null; echo "list rc=$?"
      runner_build_state /nowhere >/dev/null; echo "state rc=$?"
    ' 2>&1 )"
    grep -q "unbound variable" <<<"$out" \
      && fail "the driver died on a shell variable instead of answering: $out"
    grep -q "list rc=0" <<<"$out" \
      || fail "a driver call that resolved its own CLI still did not answer: $out"
    # `state rc=1` rather than 0: there is no build in `/nowhere`, and "there is
    # no build here to describe" is the answer. What is under test is that it
    # ANSWERED at all rather than dying on an unbound variable four frames down.
    grep -q "state rc=" <<<"$out" \
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
  runner_missing)
    # A machine with no usable runner is told so, ONCE, AT THE START --
    # armaatus/autofleet#13, both of its acceptance lines and the two hooks that
    # were still finding out late.
    #
    # The failure this replaces is not an error at all, which is what made it
    # expensive: an unreachable runtime came back as an ANSWER. The CLI printed
    # nothing, the JSON never parsed, and the caller reported "this worktree has
    # no linked issue" -- leaving a fully provisioned worktree whose agent sat on
    # an unsent prompt forever. Every assertion below is about a refusal arriving
    # before anything is spent, carrying enough to act on.
    make_fixture ok
    use_orca_runner

    # 1. THE DRIVER THAT DOES NOT EXIST. lib.sh names the FILE it looked for.
    #    "no runner driver for AUTOFLEET_RUNNER=nope" alone sends the reader to
    #    `.autofleet/config`, where the name is the one thing that is not wrong.
    out="$( cd "$WORK/repo" && AUTOFLEET_RUNNER=nope ./scripts/fleet/fleet.sh status 2>&1 )"; rc=$?
    [ "$rc" = 0 ] \
      && fail "fleet.sh status succeeded with a runner driver that does not exist: $out"
    grep -q "scripts/fleet/runner/nope.sh" <<<"$out" \
      || fail "the refusal did not name the file it looked for, which is the only place the remedy is: $out"
    # ANCHORED LOOSELY: the list is every driver in the directory, so a second
    # one sorting before `orca` would break a fixed substring. Found by the
    # local review.
    grep -qE "drivers here: .*orca" <<<"$out" \
      || fail "it did not say which drivers do ship, so the next step is a guess: $out"
    # ...and it stops THERE. fleet.sh runs `set -uo pipefail` without `-e`, so a
    # lib.sh that only `return 1`s let the script sail on into a shell with no
    # driver, where the next runner_* is `command not found` -- rc 127 through
    # `runner_available ||`, which printed "the nope runner is not usable here"
    # as if the name were the problem. The cause had scrolled past; the sentence
    # the reader acts on named the consequence.
    grep -q "is not usable here" <<<"$out" \
      && fail "it carried on past the missing driver and reported the consequence as the cause: $out"
    # ...AND THE SCRIPTS THAT NEED NO DRIVER ARE UNTOUCHED, which is the half
    # this nearly got wrong. `cost` reads transcripts off disk and calls no
    # runner_* at all -- "what did last night cost" is asked from exactly the
    # machines where the runner is not there, a CI box, a laptop with the app
    # shut -- and behind it sit the seven review and validation scripts, which
    # would otherwise have refused to answer a review comment for want of a
    # driver none of them uses. A refusal at source time takes all of them;
    # `fleet_require_runner` takes only the four that call it.
    # Found by the local review.
    out="$( cd "$WORK/repo" && AUTOFLEET_RUNNER=nope ./scripts/fleet/fleet.sh cost 2>&1 )"; rc=$?
    [ "$rc" = 0 ] \
      || fail "the one subcommand that needs no runner died on a driver it never calls: $out"
    grep -q "so it stops here" <<<"$out" \
      && fail "cost was given the consequence of a driver it never asks for: $out"
    # ONCE, which is the issue's title: fleet.sh execs cost.sh and both source
    # lib.sh, so the block had two chances to print for one command. Found by
    # the local review.
    [ "$(grep -c "no runner driver for" <<<"$out")" = 1 ] \
      || fail "the refusal printed $(grep -c "no runner driver for" <<<"$out") times for one command: $out"
    # ...and the rest of lib.sh is still there. `return 1` at the driver source
    # left FLEET_DIR and the stop files undefined, which is how the first
    # attempt at this died two lines into fleet.sh instead of saying anything.
    out="$( cd "$WORK/repo" && AUTOFLEET_RUNNER=nope bash -c '
      set -uo pipefail
      REPO_ROOT="$PWD"
      . ./scripts/fleet/lib.sh 2>/dev/null
      echo "source rc=$?"
      echo "dir=${FLEET_DIR:-UNSET}"
      echo "missing=${FLEET_RUNNER_MISSING:-UNSET}"
    ' 2>&1 )"
    grep -q "^source rc=0$" <<<"$out" \
      || fail "sourcing lib.sh without a driver answered non-zero, which every -e caller reads as fatal: $out"
    grep -q "dir=UNSET" <<<"$out" \
      && fail "lib.sh stopped at the driver and left the library half sourced: $out"
    grep -q "^missing=1$" <<<"$out" \
      || fail "nothing recorded that the driver was missing, so fleet_require_runner has nothing to act on: $out"
    # ...AND THE ENVIRONMENT CANNOT DISARM IT. `FLEET_RUNNER_MISSING` is set on
    # both arms rather than defaulted, and the comment beside it says why; a
    # later author writing `FLEET_RUNNER_MISSING="${FLEET_RUNNER_MISSING:-0}"`
    # turns the whole refusal off with the suite green, which is the shape hard
    # rule 3 exists against. Check 4g closes the sibling hole for
    # AUTOFLEET_RUNNER with `env -u`; this closes this one. Found by the
    # self-review.
    out="$( cd "$WORK/repo" && AUTOFLEET_RUNNER=nope FLEET_RUNNER_MISSING=0 \
      ./scripts/fleet/fleet.sh status 2>&1 )"; rc=$?
    [ "$rc" = 0 ] \
      && fail "an exported FLEET_RUNNER_MISSING=0 disarmed the refusal, which is the whole guard: $out"
    grep -q "scripts/fleet/runner/nope.sh" <<<"$out" \
      || fail "the refusal stopped naming the file once the environment claimed a driver was present: $out"

    # 1b. A DRIVER THAT IS THERE AND DEFINES NOTHING -- a host driver with a
    #     syntax error, or one that returns early when a dependency it needs is
    #     absent. The file test alone called that a working driver, every
    #     `runner_*` was then `command not found`, and rc 127 through
    #     `runner_available ||` printed "the <name> runner is not usable here":
    #     #13's own failure, arriving through the code that fixes it. Found by
    #     the self-review.
    printf '#!/usr/bin/env bash\n# defines nothing\nreturn 0 2>/dev/null || true\n' \
      >"$WORK/repo/scripts/fleet/runner/hollow.sh"
    out="$( cd "$WORK/repo" && AUTOFLEET_RUNNER=hollow ./scripts/fleet/fleet.sh status 2>&1 )"; rc=$?
    [ "$rc" = 0 ] \
      && fail "a driver that defines no runner_* was accepted as working: $out"
    grep -q "runner/hollow.sh is there and did not finish implementing" <<<"$out" \
      || fail "the refusal did not say the driver sourced and implemented nothing, which is the only thing that separates it from a missing file: $out"
    grep -q "is not usable here" <<<"$out" \
      && fail "the undefined runner_* was reported as an unusable runtime, which is the consequence named as the cause: $out"
    # ...and the LAST line, which is `fleet_require_runner`'s and is the only
    # one a descendant shell gets, must not say the file is absent. It is right
    # there. "no <path>, so it stops here" under a file that exists is the same
    # confident wrong sentence one layer down, and both self-review axes
    # converged on it.
    grep -q "hollow.sh did not finish implementing the runner_\* contract, so it stops here" <<<"$out" \
      || fail "the line that stops the script did not say what is wrong with a driver that is present: $out"
    grep -qE "no [^ ]*hollow\.sh, so it stops here" <<<"$out" \
      && fail "the refusal told the reader to create a driver file that is already there: $out"

    #     ...AND THE SAME UNDER `set -e`, which is `setup.sh`: a driver that
    #     `return`s when a dependency it needs is absent makes the `.` non-zero,
    #     and errexit killed the hook there before anything could be said. The
    #     driver is written in that documented shape rather than stubbed, since
    #     what is under test is the source failing, not the file being empty.
    #     Found by the self-review.
    cat >"$WORK/repo/scripts/fleet/runner/bails.sh" <<'DRIVER'
#!/usr/bin/env bash
# A host driver that bails when something it needs is not installed.
command -v definitely-not-on-this-machine >/dev/null 2>&1 || return 1
runner_available() { return 0; }
DRIVER
    out="$( cd "$WORK/repo" && AUTOFLEET_RUNNER=bails ./scripts/fleet/setup.sh 2>&1 )"; rc=$?
    [ "$rc" = 0 ] \
      && fail "a worktree was provisioned against a driver whose source did not finish: $out"
    grep -q "bails.sh is there and did not finish implementing" <<<"$out" \
      || fail "errexit killed the hook on the failed source, so the reason never printed: $out"
    grep -q "project setup hook" <<<"$out" \
      && fail "the project hook ran for a worktree whose driver never finished sourcing: $out"

    #     ...AND AN INHERITED SENTENCE CANNOT SURVIVE INTO THE OTHER ARM. The
    #     string is exported so it crosses `fleet.sh`'s exec of `cost.sh`, which
    #     means a shell that sourced lib.sh under a hollow driver passes it to
    #     one whose driver is simply absent -- where it would name a file that
    #     is not the missing one. Found by the self-review.
    out="$( cd "$WORK/repo" && AUTOFLEET_RUNNER=nope \
      FLEET_RUNNER_MISSING_SAYS="/somewhere/else.sh did not finish implementing" \
      ./scripts/fleet/fleet.sh status 2>&1 )"
    grep -q "somewhere/else.sh" <<<"$out" \
      && fail "an inherited sentence named a driver that has nothing to do with this failure: $out"
    grep -qE "no [^ ]*runner/nope\.sh, so it stops here" <<<"$out" \
      || fail "the missing-file arm did not say the file is missing once an unrelated sentence was in the environment: $out"

    #     ...AND A DRIVER THAT BAILS AFTER DEFINING ITS PROBE. docs/RUNNERS.md
    #     imposes no ordering, so `command -v runner_available` alone called
    #     this one working: the guard passed, `runner_available ||` passed, and
    #     `launch`'s `runner_worktree_create` was `command not found` with
    #     "could not create it:" and nothing under it. The source's own status
    #     is the only thing that knows. Found by the self-review.
    cat >"$WORK/repo/scripts/fleet/runner/lateba.sh" <<'DRIVER'
#!/usr/bin/env bash
# A driver that defines its probe and THEN discovers it cannot work.
runner_available() { return 0; }
command -v definitely-not-on-this-machine >/dev/null 2>&1 || return 1
runner_worktree_create() { :; }
DRIVER

    out="$( cd "$WORK/repo" && AUTOFLEET_RUNNER=lateba ./scripts/fleet/fleet.sh status 2>&1 )"; rc=$?
    [ "$rc" = 0 ] \
      && fail "a driver that returned before implementing the contract was accepted because its probe happened to be defined first: $out"
    grep -q "lateba.sh is there and did not finish implementing" <<<"$out" \
      || fail "the refusal did not say the driver stopped part way, which is the only thing separating it from a working one: $out"
    grep -q "defines no runner_worktree_create" <<<"$out" \
      || fail "the refusal did not name which of the two conditions failed, so the driver's author has to guess: $out"

    #     ...AND A CONFORMANT DRIVER THAT MERELY SOURCES NON-ZERO IS ACCEPTED.
    #     `[ -n "${FOO:-}" ] && export FOO` with FOO empty is a routine last
    #     line, and refusing a driver that implements everything because of it
    #     would be this issue's own confident lie about a machine that is fine.
    #     The status raises the bar to runner_worktree_create; it does not
    #     decide. Found by the self-review, which caught the first fix
    #     overreaching.
    cat >"$WORK/repo/scripts/fleet/runner/trailer.sh" <<'DRIVER'
#!/usr/bin/env bash
# Implements the two lib.sh looks for, and ends on a false test.
runner_available() { return 0; }
runner_worktree_create() { :; }
runner_worktree_list() { :; }
[ -n "${DEFINITELY_UNSET_HERE:-}" ] && export DEFINITELY_UNSET_HERE
DRIVER
    out="$( cd "$WORK/repo" && AUTOFLEET_RUNNER=trailer bash -c '
      set -uo pipefail
      REPO_ROOT="$PWD"
      . ./scripts/fleet/lib.sh 2>&1
      echo "missing=${FLEET_RUNNER_MISSING:-UNSET}"
    ' 2>&1 )"
    grep -q "^missing=0$" <<<"$out" \
      || fail "a driver that implements the contract was refused because its last line was a false test: $out"
    grep -q "did not finish implementing" <<<"$out" \
      && fail "a conformant driver was told it stopped part way: $out"

    # 1c. AN EMPTY RUNNER NAME. `.autofleet/config` is sourced after config.sh's
    #     `:=orca` default, so `AUTOFLEET_RUNNER=` in that file arrives here
    #     empty -- and the once-per-tree test was `"" = ""`, true, which
    #     suppressed the four lines carrying the remedy. Found by the
    #     self-review.
    #     Through a config FILE, which is the only way it is reachable: an empty
    #     AUTOFLEET_RUNNER in the environment is replaced by config.sh's
    #     `:=orca` default, and the host config is sourced after it.
    printf 'AUTOFLEET_RUNNER=""\n' >"$WORK/empty-runner-config"
    out="$( cd "$WORK/repo" && AUTOFLEET_CONFIG="$WORK/empty-runner-config" \
      ./scripts/fleet/fleet.sh status 2>&1 )"; rc=$?
    [ "$rc" = 0 ] \
      && fail "an empty AUTOFLEET_RUNNER was accepted: $out"
    grep -q "no runner driver for AUTOFLEET_RUNNER=" <<<"$out" \
      || fail "an empty runner name suppressed the block that names the drivers that do ship: $out"
    grep -qE "drivers here: .*orca" <<<"$out" \
      || fail "the remedy for an empty name did not list the drivers that ship: $out"
    # ...ONCE for one command, which the first fix for the empty name broke: the
    # sentinel it exports is itself empty, so an emptiness test never matched it
    # again and `fleet.sh cost` -- which execs cost.sh, both sourcing lib.sh --
    # printed the four lines twice. Found by the self-review.
    out="$( cd "$WORK/repo" && AUTOFLEET_CONFIG="$WORK/empty-runner-config" \
      ./scripts/fleet/fleet.sh cost 2>&1 )"
    [ "$(grep -c "no runner driver for" <<<"$out")" = 1 ] \
      || fail "an empty runner name printed the refusal $(grep -c "no runner driver for" <<<"$out") times for one command: $out"

    # 2. A DRIVER PRESENT, ITS RUNTIME UNREACHABLE. The driver's own words plus
    #    the caller's consequence, and nothing provisioned. Written as a driver
    #    of its own rather than by starving the Orca one: whether THIS machine
    #    can find an orca CLI is a property of the machine -- /Applications is
    #    on the candidate list and this suite runs on machines that have it --
    #    and what is under test here is the CALLER, which must be the same for
    #    any driver.
    cat >"$WORK/repo/scripts/fleet/runner/down.sh" <<'DRIVER'
#!/usr/bin/env bash
# A driver whose runtime is not answering. Says why on stderr, in the shape
# docs/RUNNERS.md asks of `runner_available`; the caller adds the consequence.
runner_available() {
  printf 'the down runtime is not answering here\n' >&2
  printf '     tried: down --version (/nowhere/down)\n' >&2
  printf '     install the down runtime and start it\n' >&2
  return 1
}
# Everything else the dispatcher could reach records itself instead of doing
# anything. $ORCA_CALLS cannot answer this question -- runner/orca.sh is never
# sourced under AUTOFLEET_RUNNER=down, so the Orca stub that writes that file is
# unreachable for the whole part and the assertion against it passed for a
# reason other than the behaviour. Found by the self-review.
runner_worktree_create() { printf 'worktree_create\n' >>"$DOWN_CALLS"; return 1; }
runner_worktree_list()   { printf 'worktree_list\n'   >>"$DOWN_CALLS"; }
runner_worktree_set()    { printf 'worktree_set\n'    >>"$DOWN_CALLS"; }
runner_build_state()     { printf 'build_state\n'     >>"$DOWN_CALLS"; return 1; }
runner_set_deadline()    { printf 'set_deadline\n'    >>"$DOWN_CALLS"; }
DRIVER
    : >"$WORK/down-calls"
    out="$( cd "$WORK/repo" && AUTOFLEET_RUNNER=down DOWN_CALLS="$WORK/down-calls" \
      ./scripts/fleet/fleet.sh run --auto --max-prs 1 2>&1 )"; rc=$?
    [ "$rc" = 0 ] \
      && fail "the dispatcher ran with a runtime that answers nothing: $out"
    grep -q "not answering here" <<<"$out" \
      || fail "the driver said why and the dispatcher swallowed it: $out"
    grep -q "tried: down --version" <<<"$out" \
      || fail "what was tried never reached the person reading the log: $out"
    grep -q "nothing to dispatch with" <<<"$out" \
      || fail "the driver's reason arrived without the consequence, which only the caller can add: $out"
    [ -s "$WORK/down-calls" ] \
      && fail "a dispatcher that had been told the runner is unusable still called into it: $(cat "$WORK/down-calls")"
    # NOT a second check on $AUTOFLEET_DIR/worktrees: `make_worktree` is what
    # creates that directory and this phase does not call it, so an emptiness
    # test there passes on every machine whatever the dispatcher did. The
    # recorded calls above are the whole of this claim. Found by the
    # self-review, on an assertion this branch added.
    :

    # 3. ...AND setup.sh PROBES. It runs earliest of the three hooks and was the
    #    only one that did not, while the runner holds the agent's tab until it
    #    returns. Finding out late here reads as: submodules initialised,
    #    containers built, a watcher started, and an agent tab that never
    #    receives a prompt.
    #
    #    The probe sits AFTER env.sh -- which is milliseconds, and is where a
    #    machine missing its basic tools says so -- and before everything that
    #    costs anything. So what is asserted is that NOTHING BELOW IT RAN: no
    #    project hook, no watcher, no "worktree ready". See the comment on the
    #    probe for why in front of env.sh was wrong.
    out="$( cd "$WORK/repo" && AUTOFLEET_RUNNER=down DOWN_CALLS="$WORK/down-calls" \
      ./scripts/fleet/setup.sh 2>&1 )"; rc=$?
    [ "$rc" = 0 ] \
      && fail "setup.sh provisioned a worktree whose agent can never be started: $out"
    grep -q "not answering here" <<<"$out" \
      || fail "setup.sh stopped without the driver's reason: $out"
    grep -q "project setup hook" <<<"$out" \
      && fail "the project hook ran for a worktree whose agent the runner cannot start: $out"
    grep -q "watching for the agent's issue prompt" <<<"$out" \
      && fail "it started a watcher to poll a runtime it had already been told is not answering: $out"
    grep -q "worktree ready" <<<"$out" \
      && fail "it reported the worktree ready after refusing the runner that has to start its agent: $out"

    # 4. THE SHIPPED DRIVER'S REFUSAL names the runner, what was tried, and what
    #    to install. The candidate list is overridden rather than the resolve
    #    stubbed out, because WHAT WAS TRIED is collected during the resolve --
    #    stubbing the resolve asserts the message with its middle line empty,
    #    which is the line this half of #13 adds.
    printf '#!/usr/bin/env bash\nexit 3\n' >"$WORK/bin/orca-mute"
    chmod +x "$WORK/bin/orca-mute"
    # A CLI THAT HANGS, told apart from one that answers no. One second of it,
    # which is what ORCA_CLI_PROBE_SECONDS is dropped to below: the wording is
    # the assertion, not the wait.
    printf '#!/usr/bin/env bash\nsleep 30\n' >"$WORK/bin/orca-hangs"
    chmod +x "$WORK/bin/orca-hangs"
    # stderr is closed over the SOURCE and reopened after it, so what is counted
    # below is the refusal and only the refusal. `. lib.sh` can write to stderr
    # itself -- config.sh relays a deprecated knob there -- and a three-line
    # ceiling that includes the sourcing chatter is measuring the wrong thing.
    # Found by the local review.
    refusal="$( cd "$WORK/repo" && ORCA_CLI_PROBE_SECONDS=1 bash -c '
      set -uo pipefail
      REPO_ROOT="$PWD"
      exec 3>&2 2>/dev/null
      . ./scripts/fleet/lib.sh
      exec 2>&3 3>&-
      orca_cli_candidates() { printf "%s\n" /nonexistent/orca-not-installed orca-absent-nowhere orca-mute orca-hangs; }
      runner_available
    ' 2>&1 )"; rc=$?
    [ "$rc" = 0 ] \
      && fail "the driver said it was available with nothing on PATH that answers: $refusal"
    # The HEADLINE, not just the word somewhere: the candidate names this phase
    # injects both contain `orca`, so a grep for that alone passes with the
    # first line gone entirely. Found by the local review.
    grep -q "^no orca CLI" <<<"$refusal" \
      || fail "the refusal's first line did not name the runner: $refusal"
    # An ABSOLUTE candidate was never a PATH lookup, so it must not be reported
    # as one -- the /Applications fallback is absolute, which makes this the
    # common case on a Mac with no Orca. Found by the local review.
    grep -q "/nonexistent/orca-not-installed (no such file, or not executable)" <<<"$refusal" \
      || fail "an absolute candidate was reported as a PATH failure, which it cannot be: $refusal"
    # ...and a BARE name is the case that genuinely cannot be told apart from
    # here: absent, or right there and mode 0700, which is the Orca install
    # CLAUDE.md names as the reason this probe exists. It says both.
    grep -q "orca-absent-nowhere (not found on PATH, or found and not executable)" <<<"$refusal" \
      || fail "a bare candidate that cannot be run was not named as tried, or claimed a cause it did not check: $refusal"
    grep -q "orca-mute (--version exited 3)" <<<"$refusal" \
      || fail "a candidate that is installed and answers no was not told apart from one that is absent: $refusal"
    # ...and a HANG is a third thing. Both used to read "--version did not
    # answer", which sent a person looking for a wedged app on the strength of
    # an `exit 3` that had already answered. Only the deadline wrapper returns
    # 124, so the two cannot be confused once the status is read rather than
    # thrown away. Raised by the independent review.
    grep -q "orca-hangs (no --version answer in 1s)" <<<"$refusal" \
      || fail "a CLI that hangs was not told apart from one that is there and exits non-zero: $refusal"
    grep -q "install Orca" <<<"$refusal" \
      || fail "it named the runtime and not the remedy, which is what #13 calls a line that stops half way: $refusal"
    # ...and ORCA_CLI_COMMAND is ONE candidate, not a word-split list. The old
    # loop expanded it unquoted, so a path with spaces became several candidates
    # and none of them existed; this pins the documented shape, which
    # docs/CONFIGURATION.md now states because the refusal names the knob.
    # Found by the local review.
    mkdir -p "$WORK/bin/two words"
    printf '#!/usr/bin/env bash\nexit 3\n' >"$WORK/bin/two words/orca-spaced"
    chmod +x "$WORK/bin/two words/orca-spaced"
    spaced="$( cd "$WORK/repo" && ORCA_CLI_COMMAND="$WORK/bin/two words/orca-spaced" bash -c '
      set -uo pipefail
      REPO_ROOT="$PWD"
      exec 3>&2 2>/dev/null
      . ./scripts/fleet/lib.sh
      exec 2>&3 3>&-
      orca_cli_candidates
    ' 2>&1 )"
    grep -qxF "$WORK/bin/two words/orca-spaced" <<<"$spaced" \
      || fail "a CLI path containing a space was split into candidates that do not exist: $spaced"
    # THREE LINES, which is the relay bound docs/RUNNERS.md sets and the reason
    # what was tried is one comma-joined line rather than one line per
    # candidate: `runner_worktree_create` prints this on the stream `launch`
    # logs, and `launch` retries every pass.
    lines="$(printf '%s\n' "$refusal" | wc -l)"
    [ "$((lines))" -le 3 ] \
      || fail "the refusal is $lines lines, over the three docs/RUNNERS.md allows a relay, and launch reprints it every pass: $refusal"

    echo "ok: a machine with no usable runner is told which file, what was tried and what to install, before anything is provisioned"
    ;;
  stop_now_stops_builds)
    # WHAT `stop --now` DOES NOW. Its pair `drain_lets_agents_finish` survives on
    # the same line in tests/run.sh; this is the half that changed shape.
    # `stop_freezes_agents` asserted that the freeze reached a live session and
    # that the guard still refused anything outward afterwards -- and there is no
    # session to freeze, so the first half became "the build is killed". The
    # second half did not change at all and is the escape hatch, so it is
    # asserted against the real `.claude/hooks/guard.py` exactly as before.
    # Named in the PR body rather than dropped; found by
    # `/mattpocock-skills:code-review`.
    make_fixture ok
    make_worktree
    build_running
    pid="$(cat "$AUTOFLEET_DIR/builds/42/pid")"
    kill -0 "$pid" 2>/dev/null \
      || fail "the fixture build is not running, so this phase would assert nothing"
    out="$(in_fleet cmd_stop --now 2>&1)"
    grep -q "stopped the build for #42" <<<"$out" \
      || fail "stop --now did not say it stopped the build it stopped: $out"
    # REAPED before the check: the fake build is a job of this shell, so a
    # killed one stays a zombie until it is waited on and `kill -0` goes on
    # answering yes about a process that is already dead.
    wait "$BUILD_SLEEPER" 2>/dev/null
    kill -0 "$pid" 2>/dev/null \
      && { kill -9 "$pid" 2>/dev/null; fail "stop --now left the build running: $out"; }
    echo "ok: stop --now stops the build it owns, and says which"

    # ...and a fleet with no build running does not claim to have stopped one.
    in_fleet cmd_resume >/dev/null 2>&1
    rm -rf "$AUTOFLEET_DIR/builds"
    out="$(in_fleet cmd_stop --now 2>&1)"
    grep -q "stopped the build" <<<"$out" \
      && fail "it reported a stop for a worktree with no build in it: $out"
    grep -q "there were none" <<<"$out" \
      || fail "it said nothing at all where there was nothing to stop: $out"
    echo "ok: ...and says so plainly when there is nothing to stop"

    # THE ESCAPE HATCH, unchanged by this issue and asserted against the real
    # hook rather than a copy of its rule: a stopped fleet lets nothing out.
    # Stopped again first -- the second half above resumed, and asserting a
    # stopped fleet's refusals against a running one asserts nothing.
    in_fleet cmd_stop --now >/dev/null 2>&1
    [ "$(guard_says 'git push')" = 2 ] \
      || fail "a stopped fleet allowed a push"
    [ "$(guard_says 'gh pr create --fill')" = 2 ] \
      || fail "a stopped fleet allowed a pull request"
    in_fleet cmd_resume >/dev/null 2>&1
    [ "$(guard_says 'git push')" = 0 ] \
      || fail "the stop outlived the resume, so the fleet can never push again"
    echo "ok: ...and the guard still refuses anything outward while it is stopped"
    ;;

  no_build_command)
    # A MACHINE WITH NO AGENT CLI STILL RUNS EVERY FLEET COMMAND THAT DOES NOT
    # BUILD. `runner_available` asked for the build command for one round, and
    # `fleet.sh` probes the driver at SOURCE time and dies on a no -- so on a CI
    # runner with no `claude` installed the reviewer, the validator, `cost` and
    # the whole review pipeline stopped, none of which builds anything. Eleven
    # `review_mode` phases went red in CI and green here, for the one reason
    # that makes this class of bug ship: this machine has `claude`.
    make_fixture ok
    # PATH without the build command, and with the tools the driver really
    # needs. `fleet_build_program` is what the check reads, so pointing
    # AUTOFLEET_BUILD_CMD at something absent is the same arrangement without
    # having to rebuild PATH.
    out="$( cd "$WORK/repo" && AUTOFLEET_BUILD_CMD=definitely-not-installed \
              ./scripts/fleet/fleet.sh status 2>&1 )"; rc=$?
    [ "$rc" = 0 ] \
      || fail "a fleet command that builds nothing died because the build command is absent (rc $rc): $out"
    grep -q "not on PATH" <<<"$out" \
      && fail "the driver refused itself over a command it does not use: $out"
    echo "ok: the driver is usable on a machine with no agent CLI installed"

    # ...and a LAUNCH says so, out loud, on the pass that tried it -- rather
    # than spawning a run that dies instantly and is resumed up to
    # AUTOFLEET_BUILD_MAX_RUNS.
    make_worktree
    out="$( AUTOFLEET_BUILD_CMD=definitely-not-installed \
            in_fleet start_build 42 "$WORK/wt" 2>&1 )"; rc=$?
    [ "$rc" = 0 ] \
      && fail "a build started with no build command on PATH: $out"
    grep -q "definitely-not-installed" <<<"$out" \
      || fail "it did not name the command it could not find: $out"
    grep -q "AUTOFLEET_BUILD_CMD" <<<"$out" \
      || fail "it did not name the knob that sets it, which is the only way to fix it: $out"
    echo "ok: ...and a launch that cannot build says which command is missing"
    ;;

  build_command)
    # THE SPEC'S CENTRAL ARTEFACT, and nothing asserted it. The issue names the
    # flags exactly and its design notes say `--bare` must not be passed --
    # which is the line that keeps `.claude/hooks/guard.py` running under a
    # headless agent, so a build that lost it could merge its own pull request
    # and push before its review was recorded, with every phase still green.
    # Found by `/mattpocock-skills:code-review`.
    make_fixture ok
    line="$(in_fleet fleet_build_command_line "$AUTOFLEET_DIR/builds/42")"
    for flag in --permission-mode --max-turns --max-budget-usd "--output-format json" \
                --append-system-prompt-file; do
      grep -qF -- "$flag" <<<"$line" \
        || fail "the build command line no longer passes $flag: $line"
    done
    grep -qF -- "--bare" <<<"$line" \
      && fail "the build command line passes --bare, which turns off every rule in guard.py: $line"
    # The two long inputs are READ FROM FILES rather than carried inline, which
    # is what makes the line safe to hand to a terminal: the prompt and the
    # brief are multi-line text from a tracker, and a command line quoting them
    # is one apostrophe away from running something else.
    grep -qF -- "\$(cat '$AUTOFLEET_DIR/builds/42/prompt')" <<<"$line" \
      || fail "the prompt is not read from its file: $line"
    grep -qF -- "'$AUTOFLEET_DIR/builds/42/system.md'" <<<"$line" \
      || fail "the brief is not read from its file: $line"
    # ...and the knobs reach it, so moving one moves the build.
    line="$( AUTOFLEET_BUILD_MAX_TURNS=7 AUTOFLEET_BUILD_MAX_BUDGET_USD=3.5 \
             AUTOFLEET_BUILD_PERMISSION_MODE=plan \
             in_fleet fleet_build_command_line "$AUTOFLEET_DIR/builds/42" )"
    grep -qF -- "--max-turns 7" <<<"$line" \
      || fail "AUTOFLEET_BUILD_MAX_TURNS does not reach the command line: $line"
    grep -qF -- "--max-budget-usd 3.5" <<<"$line" \
      || fail "AUTOFLEET_BUILD_MAX_BUDGET_USD does not reach the command line: $line"
    grep -qF -- "--permission-mode plan" <<<"$line" \
      || fail "AUTOFLEET_BUILD_PERMISSION_MODE does not reach the command line: $line"
    # ...and it writes its own exit status last, which is what lets ONE state
    # reader serve a background child and a command hosted in somebody else's
    # terminal.
    grep -qF -- "/rc'" <<<"$line" \
      || fail "the command line no longer records its own exit status: $line"
    echo "ok: the one build command line carries every flag the issue names, and not --bare"

    # BOTH DRIVERS RUN IT, byte for byte. The claim "only where it runs differs"
    # is only checkable by comparing what each hands to the shell.
    headless="$( AUTOFLEET_RUNNER=headless in_fleet fleet_build_command_line "$AUTOFLEET_DIR/builds/42" )"
    orca="$( AUTOFLEET_RUNNER=orca in_fleet fleet_build_command_line "$AUTOFLEET_DIR/builds/42" )"
    [ "$headless" = "$orca" ] \
      || fail "the two drivers would run different commands:\n  $headless\n  $orca"
    echo "ok: ...and both drivers compose the identical line"
    ;;

  resume_brief)
    # A RESUME IS THE SAME BRIEF, AND IT COUNTS AS A RUN.
    #
    # It was the AFTER-PR brief, because the loop had a second half: a resumed
    # run picked up at "wait for the review, answer it, resolve the threads".
    # armaatus/autofleet#152 deleted that half -- the agent's job ends at an
    # open pull request and everything after it is the dispatcher's -- so a
    # resume differs from a first run in nothing at all. What it starts from is
    # the branch and the pull request, which is state no brief carries.
    #
    # THE ASSERTION MOVED WITH THE SHAPE rather than being deleted with it. What
    # it has to catch now is a `start_build` that stopped fetching the brief on
    # the second call: a resumed build handed an empty system prompt looks like
    # a build and produces nothing. So the two are compared for being the SAME
    # rather than for differing, and the run count is what bounds them.
    make_fixture ok
    make_worktree
    add_origin
    cat >"$WORK/bin/gh" <<'GHSTUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALLS"
case "$*" in
  *"issue view 42"*) echo "the issue body" ;;
  *) echo '[]' ;;
esac
GHSTUB
    chmod +x "$WORK/bin/gh"
    in_fleet start_build 42 "$WORK/wt" >/dev/null 2>&1 \
      || fail "the opening build would not start"
    grep -qF -- "issue-command.sh 42" "$GH_CALLS" 2>/dev/null \
      || grep -q "issue-command.sh" "$AUTOFLEET_DIR/builds/42/prompt" \
      || grep -q "Your brief is in the system prompt" "$AUTOFLEET_DIR/builds/42/prompt" \
      || fail "the opening run was handed no brief at all: $(cat "$AUTOFLEET_DIR/builds/42/prompt")"
    opening="$(cat "$AUTOFLEET_DIR/builds/42/system.md")"
    in_fleet start_build 42 "$WORK/wt" >/dev/null 2>&1 \
      || fail "the resume would not start"
    resumed="$(cat "$AUTOFLEET_DIR/builds/42/system.md")"
    [ -s "$AUTOFLEET_DIR/builds/42/system.md" ] \
      || fail "the resumed run was handed an empty system prompt"
    [ "$opening" = "$resumed" ] \
      || fail "the resume was handed a different brief from the opening run; there is only one"
    # ...and the resume may not send the agent at a brief that refuses it.
    # `--after-pr` is an ERROR now, so a resumed run told to fetch it would get
    # a refusal where its instructions should be.
    grep -qF -- "--after-pr" <<<"$resumed" \
      && fail "the resumed run's brief still points at --after-pr, which now refuses"
    # ...and the run count moved, which is what AUTOFLEET_BUILD_MAX_RUNS reads.
    [ "$(cat "$AUTOFLEET_DIR/builds/42/run-count")" = 2 ] \
      || fail "the resume did not count as a run, so the bound on resumes never fires"
    echo "ok: a resume is handed the same brief and counts as a run"
    ;;

  runner_stub)
    # THE acceptance for armaatus/autofleet#1, and the only assertion that keeps
    # holding once the move has been made: with a driver that is neither of the
    # two that ship, a dispatcher, a worktree hook and the brief resolver all do
    # their whole job, and the app's CLI is never asked anything.
    make_fixture ok
    stub_runner
    make_repo_git
    # An `orca` ON PATH as well as the one the fixture exports: the claim is
    # that nothing reaches for the runtime, not that nothing reaches for the one
    # name a test happened to set. Both record into $ORCA_CALLS.
    cp "$WORK/bin/orca-stub" "$WORK/bin/orca"

    printf '%s\t%s\t%s\n' "$WORK/wt" work 42 >"$STUB_DIR/worktrees"
    printf '42' >"$STUB_DIR/issue"
    plant_worktree 42 wt
    add_origin
    mkdir -p "$AUTOFLEET_DIR/worktrees"
    printf '%s\n' "$WORK/wt" >"$AUTOFLEET_DIR/worktrees/42"

    [ "$(gate_count)" = 1 ] \
      || fail "the dispatcher could not count its own worktrees through a third driver"

    # The build watcher: the state and the board, one poll of each.
    issue_labels "ready"
    : >"$STUB_DIR/build-exited"; printf '1\n' >"$STUB_DIR/build-exited"
    echo '[]' >"$GH_PRS"
    out="$(in_fleet notice_build_exit 2>&1)"
    grep -q "ran out" <<<"$out" \
      || fail "the build state never arrived through the driver: $out"
    grep -q "worktree set" "$STUB_CALLS" \
      || fail "the board update did not go through the driver: $(cat "$STUB_CALLS")"
    rm -f "$STUB_DIR/build-exited" "$AUTOFLEET_DIR/gaveup-42"

    # "I could not tell" is not "it has stopped", through a driver that says so.
    : >"$STUB_DIR/build-blind"
    out="$(in_fleet notice_build_exit 2>&1)"
    rm -f "$STUB_DIR/build-blind"
    grep -q "would not say whether its build is running" <<<"$out" \
      || fail "a state the driver could not read was not reported as one: $out"
    [ -e "$AUTOFLEET_DIR/gaveup-42" ] \
      && fail "a build whose state could not be read was recorded as having given up"

    # The launch: create, provision, start the build, set the card.
    in_fleet launch 44 "a second issue" >/dev/null 2>&1 \
      || fail "launch failed against a driver that answers everything"
    grep -q "worktree create" "$STUB_CALLS" \
      || fail "the worktree was not created through the driver: $(cat "$STUB_CALLS")"
    grep -q "build start" "$STUB_CALLS" \
      || fail "the build was not started through the driver: $(cat "$STUB_CALLS")"

    # ...and a driver that cannot start one FAILS THE LAUNCH, out loud. The
    # app-backed runner used to start the agent from its own worktree hook, so
    # a failure there left a fully provisioned worktree nobody was working in
    # and the dispatcher never knew. armaatus/autofleet#151.
    : >"$STUB_DIR/build-fails"
    out="$(in_fleet launch 46 "a fourth issue" 2>&1)"; rc=$?
    rm -f "$STUB_DIR/build-fails"
    [ "$rc" = 0 ] \
      && fail "a launch whose build would not start was reported as a launch: $out"
    grep -q "no build running" <<<"$out" \
      || fail "it did not say the worktree has no build in it: $out"

    in_fleet stop_build_in "$WORK/wt" >/dev/null 2>&1
    grep -q "build stop $WORK/wt" "$STUB_CALLS" \
      || fail "the stop did not reach this worktree's build through the driver: $(cat "$STUB_CALLS")"

    # Only #42 is under test here: the launches above own two more worktrees,
    # and a reap that also had to judge them would be asserting about their
    # fixtures rather than about the driver.
    rm -f "$AUTOFLEET_DIR/worktrees/44" "$AUTOFLEET_DIR/worktrees/46"
    out="$(in_fleet reap_merged 2>&1)"
    [ -d "$WORK/wt" ] && fail "the merged worktree was not removed through the driver: $out"
    grep -q -- "--yes" "$REAP_CALLS" \
      || fail "the stack sweep did not run after a removal through the driver: $(cat "$REAP_CALLS")"

    # THE THREE-WAY ANSWER, on the one function that has it. A worktree with no
    # linked issue and a runtime that would not say must not reach a person as
    # the same sentence: they did for a year, and it cost three worktrees a
    # night.
    : >"$STUB_DIR/blind"
    out="$( cd "$WORK/repo" && ./scripts/fleet/issue-command.sh 2>&1 )"; rc=$?
    rm -f "$STUB_DIR/blind"
    [ "$rc" = 0 ] \
      && fail "a runner that would not answer was read as an issue number: $out"
    grep -q "would not say" <<<"$out" \
      || fail "a runtime that could not answer was reported as a worktree with no issue: $out"
    : >"$STUB_DIR/issue"
    out="$( cd "$WORK/repo" && ./scripts/fleet/issue-command.sh 2>&1 )"
    grep -q "would not say" <<<"$out" \
      && fail "a worktree that really has no linked issue was reported as a runtime outage: $out"
    printf '42' >"$STUB_DIR/issue"

    # A removal nobody answered is NOT a refusal. The dispatcher parks a slot for
    # good on a refusal and retries on silence, so this is a worktree lost per
    # runtime restart if the driver conflates them.
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

    # `runner_worktree_set` IS STILL IN THE CONTRACT, and two assertions used to
    # drive it here through `board.sh` -- the card update the brief handed every
    # agent, and the REFUSAL that made its written-down $REPO_ROOT assumption
    # acceptable rather than quiet. `board.sh` went with the post-PR protocol it
    # reported into (armaatus/autofleet#152); the dispatcher's own `card` calls
    # are what exercise the seam now, and `card_says` and `card_quiet` assert
    # them. Nothing is re-asserted here, and this note is what stops a reader
    # concluding the coverage was merely dropped.

    # ...and the contract's STREAM, against a driver that is neither shipped
    # one. `launch` captures stdout only, so a driver obeying docs/RUNNERS.md
    # must answer there; `create_says` asserts this against the app CLI stub,
    # which leaves the page's claim untested for everyone the page is for.
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
    echo "ok: dispatcher, reap and both worktree hooks run on a third driver"
    ;;
  create_says)
    # `launch` printing "could not create it:" and then nothing is the same line
    # whether the app is down or the branch already exists, and it repeats every
    # pass with the issue left in the queue. The driver has to relay the
    # runtime's stderr for that line to be worth anything -- docs/RUNNERS.md says
    # so, and until the independent review said otherwise nothing asserted it.
    make_fixture create_fails
    use_orca_runner
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
    use_orca_runner
    out="$(in_fleet launch 44 "a second issue" 2>&1)"
    grep -q "reported no path" <<<"$out" \
      && fail "a warning on stderr broke the JSON parse, so the fleet created a worktree it does not own and cannot reap: $out"
    grep -q "#44 is building in" <<<"$out" \
      || fail "the created worktree was not tracked: $out"
    [ -e "$AUTOFLEET_DIR/worktrees/44" ] \
      || fail "nothing owns the worktree that was just created, so no reap will ever look at it: $out"
    echo "ok: a create that warns on stderr is still parsed, owned and carded"
    ;;
  card_says)
    make_fixture set_fails
    use_orca_runner
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
    use_orca_runner
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
    use_orca_runner
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
  farewell_runner_blind)
    make_fixture ok
    mkdir -p "$AUTOFLEET_DIR/worktrees" "$WORK/wt99"
    printf '%s\n' "$WORK/wt" >"$AUTOFLEET_DIR/worktrees/42"
    printf '%s\n' "$WORK/wt99" >"$AUTOFLEET_DIR/worktrees/99"
    # THE TWO BRANCHES A DRAIN CANNOT REACH ON PURPOSE. The farewell re-derives
    # its list by asking the runner, and the count in `fleet down: $reason` came
    # from the last poll -- so a runner that stops answering in between leaves
    # the two disagreeing, or leaves a header with nothing under it. Reached
    # inline that is a race no fixture can arrange, which is why it is a
    # function. Both branches could be deleted with the suite green.
    # Found by `/code-review`. armaatus/autofleet#71.
    : >"$AUTOFLEET_DIR/held-42"
    : >"$AUTOFLEET_DIR/held-99"
    # Neither has a build the driver can describe, which is the outage: "I could
    # not tell" for both, so the farewell can name neither.
    build_blind 42
    mkdir -p "$AUTOFLEET_DIR/builds/99"
    printf '%s\n' "$WORK/wt99" >"$AUTOFLEET_DIR/builds/99/worktree"
    out="$(in_fleet farewell_parked 2 2>&1)"
    grep -q "the runner would not say" <<<"$out" \
      || fail "the farewell announced 2 worktrees and named none, with nothing saying why: $out"
    grep -q "waiting for you rather than for an agent" <<<"$out" \
      && fail "it printed the header for a list it could not build: $out"
    echo "ok: a farewell that cannot name any of them says so instead of printing an empty header"

    # ...and the SHORTFALL: one nameable, and the poll had counted two.
    build_state_for 42 "$WORK/wt" 0
    build_state_for 99 "$WORK/wt99"
    out="$(in_fleet farewell_parked 2 2>&1)"
    grep -q -- "#42 --" <<<"$out" || fail "it did not name the one it could: $out"
    grep -q -- "#99 --" <<<"$out" \
      && fail "it named a worktree whose agent is working, and told a person to discard what is in there: $out"
    grep -q "1 fewer than the line above says" <<<"$out" \
      || fail "the farewell said 1 under a line that said 2, with nothing reconciling them: $out"
    # ...NAMING BOTH CAUSES. A shortfall is a runner that would not answer or an
    # agent that went back to work, and naming only the outage sends a person to
    # look for one that is not happening. Found by `/code-review`. #71.
    grep -q "agent went back to work" <<<"$out" \
      || fail "the shortfall line blamed the runner for a difference an agent at work also makes: $out"
    echo "ok: ...and says so when it can name fewer than the poll counted"

    # ...and the other direction, which is an agent that FINISHED in between:
    # both name-able now, against a farewell line that counted one.
    build_state_for 99 "$WORK/wt99" 0
    out="$(in_fleet farewell_parked 1 2>&1)"
    grep -q -- "#99 --" <<<"$out" \
      || fail "the worktree whose agent went idle was not named: $out"
    grep -q "more than the line above says" <<<"$out" \
      || fail "the farewell named more worktrees than the farewell line said, with nothing reconciling them: $out"
    echo "ok: ...and when it can name more"
    ;;

  parked_since_swept_at_start)
    make_fixture ok
    # `parked-since-$n` is the survive-a-pass marker: a keep-marker counts only
    # once it has been seen on two consecutive passes, which is what stops one
    # transient `blocked` label from ending a drain with an agent still writing.
    # It lives in $STATE_DIR rather than the poll cache, and nothing at startup
    # cleared it -- `release_dispatcher_files` is on the EXIT trap, so a
    # `kill -9`'d dispatcher leaves its markers behind and the NEXT dispatcher
    # counts those worktrees as parked on its FIRST pass. That is precisely the
    # case the rule exists to rule out, arriving through the rule's own
    # bookkeeping. It self-heals from the second poll onward, and the window is
    # the one pass where a wrong `parked` signs the dispatcher off on top of an
    # agent. armaatus/autofleet#71.
    mkdir -p "$AUTOFLEET_DIR"
    : >"$AUTOFLEET_DIR/parked-since-42"
    : >"$AUTOFLEET_DIR/parked-since-99"
    # An empty backlog, so the run reaches its own exit rather than launching.
    echo '[]' >"$GH_ISSUES"
    in_fleet cmd_run --auto >"$WORK/run.log" 2>&1
    [ -e "$AUTOFLEET_DIR/parked-since-42" ] \
      && fail "a marker left by a dead dispatcher survived into this one, which counts that worktree as parked on its first pass: $(cat "$WORK/run.log")"
    [ -e "$AUTOFLEET_DIR/parked-since-99" ] \
      && fail "the sweep cleared one marker and not the rest"
    echo "ok: a dispatcher starting clears the survive-a-pass markers a dead one left"
    ;;

  queued_blind_keeps_polling)
    make_fixture ok
    # `count_startable`'s DOCUMENTED NON-ZERO, driven through the run loop.
    # `queued="$(count_startable)"` used to discard it: `queued` came back empty,
    # `[ "" -eq 0 ]` wrote `integer expression expected` to stderr every poll for
    # as long as the outage lasted -- into the log a person scans in the morning,
    # at exactly the moment it most needs to be readable -- and the fix shipped
    # with nothing driving it. `budget_ready_list_blind` asserts the non-zero at
    # the FUNCTION; the behaviour it buys is one level up, in the loop that
    # decides whether the backlog is finished. armaatus/autofleet#71.
    #
    # WHICH ROW FAILS ON REVERT, said because three of the four do not:
    # `[ "" -eq 0 ]` exits 2 and reads as FALSE, so the run kept polling before
    # the fix as well as after. Only the `integer expression expected` grep
    # catches the discard. The three rows below it are there for the OTHER way
    # this goes wrong -- `|| queued=0`, which reads "could not tell" as "nothing
    # left" and signs the dispatcher off during an outage -- and they would
    # catch that. Both failures live on the same line, which is why they are in
    # one phase. Found by `/mattpocock-skills:code-review`.
    #
    # `FAIL` makes `ready_issues` fail, which is one of count_startable's three
    # `|| return 1`s -- and the one an outage actually produces.
    printf 'FAIL\n' >"$GH_ISSUES"
    # ON THE SIGNAL, NOT ON A CLOCK. This waited `sleep 3` -- "three passes at a
    # 1s poll" -- and on a machine loaded enough that no pass reached the test
    # in three seconds, the revert-failing row was green because the line it
    # greps for had not been written yet. $AUTOFLEET_LOG_PASSES is the one thing
    # that can answer "has a pass finished" without guessing from a clock.
    # Found by the independent review of 2b00a3a.
    #
    # TWO, and one is not enough for a reason that is not "two passes are
    # safer": the discard speaks from `[ "$queued" -eq 0 ]`, which runs just
    # AFTER the `pass complete` line of the same pass. So pass 1's line is
    # printed with the test still ahead of it, and waiting for one would race it
    # by a few statements. Pass 2's line is the first proof that pass 1 got
    # through the test. Do not tidy this to `wait_for_passes 1`. The count is
    # `/mattpocock-skills:code-review`'s: the first version of this comment said
    # two passes were needed because one might not have happened, which is the
    # wrong reason and the one a reader would tidy away.
    export AUTOFLEET_LOG_PASSES=on
    start_dispatcher --auto
    wait_for_log "fleet up"
    wait_for_passes 2
    grep -q "integer expression expected" "$WORK/run.log" \
      && fail "a gh outage wrote a bash error into the dispatcher's log once a poll: $(cat "$WORK/run.log")"
    echo "ok: an unreadable backlog does not put a shell error in the log every poll"
    grep -q "fleet down" "$WORK/run.log" \
      && fail "a backlog that could not be READ was taken for a backlog that is EMPTY, and the run signed off: $(cat "$WORK/run.log")"
    kill -0 "$HELD_PID" 2>/dev/null \
      || fail "the dispatcher exited during a gh outage: $(cat "$WORK/run.log")"
    echo "ok: ...and the run keeps polling rather than deciding the backlog is finished"
    stop_dispatcher
    ;;

  status_parked_beside_working)
    make_fixture ok
    # THE SEPARATION, which is the state a person actually meets: a drain that
    # ended with one outstanding leaves ONE parked worktree beside one that is
    # still being written. #37 asks `status` to name the parked one separately
    # from the working one, and every phase that touched this planted a single
    # worktree -- so the naming was asserted and the separation never was. A
    # `status` that printed the reason and the recovery line against every row
    # would have passed all of them, and it tells a person to go and discard
    # what an agent is writing. armaatus/autofleet#71.
    mkdir -p "$AUTOFLEET_DIR/worktrees" "$WORK/wt99"
    printf '%s\n' "$WORK/wt" >"$AUTOFLEET_DIR/worktrees/42"
    printf '%s\n' "$WORK/wt99" >"$AUTOFLEET_DIR/worktrees/99"
    worktree_list "42:wt" "99:wt99"
    # #42 is parked -- its removal was refused, the one reason that needs no
    # agent check -- and #99 CARRIES A MARKER TOO, with its agent mid-work.
    #
    # The marker on #99 is what makes this phase about the sentence its comment
    # names. With no marker, `why_parked 99` returns 1 and `parked_for_person`
    # returns before the agent gate is ever reached -- delete the gate and the
    # phase still passed, so it asserted the separation and not the reason for
    # it. `held-99` is the ordinary case: a worktree whose issue went blocked
    # with a commit in it, while its agent is still writing.
    # Found by `/mattpocock-skills:code-review`.
    : >"$AUTOFLEET_DIR/stuck-42"
    : >"$AUTOFLEET_DIR/held-99"
    # #42's build has stopped; #99's is still running, which is what makes the
    # gate on `held-99` decide anything.
    build_state_for 42 "$WORK/wt" 0
    build_state_for 99 "$WORK/wt99"
    dispatcher_running
    in_fleet record_dispatcher
    out="$(in_fleet cmd_status 2>&1)"

    # Both are listed...
    grep -q -- "#42" <<<"$out" || fail "status dropped the parked worktree: $out"
    grep -q -- "#99" <<<"$out" || fail "status dropped the working worktree: $out"
    # ...and exactly one of them carries a reason and a recovery line.
    n="$(grep -c "waiting for you" <<<"$out" || true)"
    [ "$n" = 1 ] \
      || fail "$n of 2 worktrees were named as waiting for a person; only the parked one is: $out"
    grep -q "$WORK/wt99" <<<"$(grep -A2 -- "#42" <<<"$out")" \
      && fail "the parked worktree's recovery line points at the working one: $out"
    # The recovery line is the parked worktree's, by path -- so a `status` that
    # printed one recovery line for the whole listing cannot pass this.
    recovery="$(grep "worktree remove --force\|status --short" <<<"$out" || true)"
    grep -q "'$WORK/wt'" <<<"$recovery" \
      || fail "the parked worktree got no recovery line naming its own directory: $out"
    grep -q "wt99" <<<"$recovery" \
      && fail "status handed a person a recovery line for a directory an agent is writing to: $out"
    echo "ok: a parked worktree is named with its reason and its recovery line, beside a working one that is not"
    ;;

  drain_parked_counted_once)
    # Two markers, ONE worktree. `reap_merged` keeps a merged worktree owned as
    # `merge-blind-42` when its upstream was pruned, and `reap_abandoned` can
    # then write `stuck-42` beside it in the same pass. Counting markers rather
    # than issues made `parked` 2 for one worktree, so `owned` dropped to 0 with
    # #99 still mid-work and the dispatcher exited -- #36's failure, re-created
    # by the fix for #37. The `-lt 0` clamp turned it from a visible wrong answer
    # into a silent one. Found by the independent review.
    # STDOUT ONLY on every count below, and the reason is the gate. A worktree
    # whose build state cannot be read is NOT counted as waiting for a person,
    # and it says so once on stderr -- which is the right behaviour and was
    # never in this phase's way while the gate read a machine-wide agent
    # listing that always answered. Folded into the count, that sentence made
    # `= 0` compare a number against a paragraph.
    make_fixture ok
    mkdir -p "$AUTOFLEET_DIR/worktrees" "$AUTOFLEET_DIR"
    printf '%s\n' "$WORK/wt" >"$AUTOFLEET_DIR/worktrees/42"
    printf '%s\n' "$WORK/wt99" >"$AUTOFLEET_DIR/worktrees/99"
    : >"$AUTOFLEET_DIR/merge-blind-42"
    : >"$AUTOFLEET_DIR/stuck-42"
    # TWO passes, because a marker must survive one before it counts -- the
    # first pass records it, the second counts it. See count_parked_owned.
    [ "$(in_fleet count_parked_owned 2>/dev/null)" = 0 ] \
      || fail "a marker counted on the pass it appeared; a transient one would end the drain with an agent still working"
    echo "ok: a marker does not count on the pass it appears"
    out="$(in_fleet count_parked_owned 2>/dev/null)"
    [ "$out" = 1 ] \
      || fail "two markers on one worktree counted as $out parked; #99 is still in flight and the drain would exit: $out"
    echo "ok: a worktree with two keep-markers is one parked worktree"

    # ...and a marker that goes away before the next pass never counts, which is
    # the failure this rule exists for: `held-` and `git-blind-` are re-derived
    # every pass, and one transient `blocked` label would otherwise sign the
    # dispatcher off with an agent still writing.
    rm -f "$AUTOFLEET_DIR/merge-blind-42" "$AUTOFLEET_DIR/stuck-42"
    [ "$(in_fleet count_parked_owned 2>/dev/null)" = 0 ] \
      || fail "a marker that cleared still counted as a worktree waiting for a person"
    : >"$AUTOFLEET_DIR/held-42"
    [ "$(in_fleet count_parked_owned 2>/dev/null)" = 0 ] \
      || fail "a transient held- counted on its first pass"
    rm -f "$AUTOFLEET_DIR/held-42"
    [ "$(in_fleet count_parked_owned 2>/dev/null)" = 0 ] \
      || fail "a held- that came and went across two passes was counted"
    echo "ok: ...and a marker that comes and goes never counts"

    # ...AND THE TWO RE-DERIVED MARKERS NEED THE AGENT TO BE IDLE, not merely
    # to have no terminal. `reap_abandoned` writes `held-` and `continue`s
    # without ever reaching `remove_worktree`, so the terminal it left behind
    # outlives the agent -- and gating on terminal EXISTENCE meant the worktree
    # was never counted, the drain never ended, and `status` never said idle.
    # #37 verbatim, through the door the gate was added to close.
    #
    # The first version of this phase could not tell the two apart either:
    # `agent_state` writes $ORCA_PS and $ORCA_TERMINALS together, and the
    # terminal it writes is byte-identical whatever state is passed -- so
    # `build_exited` passed the "a live agent is not waiting" assertion
    # exactly as `working` did. The phase read as one thing and asserted
    # another. Found by the independent review.
    build_running
    : >"$AUTOFLEET_DIR/held-42"
    in_fleet count_parked_owned >/dev/null 2>&1
    [ "$(in_fleet count_parked_owned 2>/dev/null)" = 0 ] \
      || fail "held-42 counted as waiting for a person while its agent is WORKING"
    echo "ok: a worktree whose agent is working is not waiting for a person"

    # ...and the SAME terminal, with the agent no longer working, does count --
    # which is what the old gate could not see, and why the drain hung.
    build_exited
    in_fleet count_parked_owned >/dev/null 2>&1
    [ "$(in_fleet count_parked_owned 2>/dev/null)" = 1 ] \
      || fail "held-42 with its agent idle did not count -- the terminal outlives the agent, so the drain waits forever"
    echo "ok: ...and the same terminal with an idle agent does count"

    # "Could not tell" is not "it has stopped": a state the driver cannot read
    # leaves the worktree uncounted, because somebody may still be in there.
    # Reached by taking the driver's INDEX away and leaving the record, which is
    # the shape that is genuinely unanswerable -- no build recorded at all is a
    # real answer, and one this phase asserts the other way below.
    build_blind
    in_fleet count_parked_owned >/dev/null 2>&1
    [ "$(in_fleet count_parked_owned 2>/dev/null)" = 0 ] \
      || fail "an agent-state listing that could not be read was treated as 'nobody is working'"
    echo "ok: ...and an unreadable listing is not an idle one"

    # ...AND IT SAYS SO. Taking the safe direction silently is #37's own
    # complaint -- "nothing says the drain has become unbounded". One unreadable
    # `worktree ps` is a hiccup; a persistent one means this worktree never
    # counts, `owned` never reaches 0, and the operator has no way to learn why.
    # `live_worktrees` already says the equivalent for its own call, and these
    # are two different runner calls that fail independently. Found by the
    # independent review.
    rm -f "$AUTOFLEET_DIR/ps-blind-42"
    : >"$AUTOFLEET_DIR/held-42"
    build_blind
    # THE LOG, not stdout: `count_parked_owned` discards the predicate's stdout
    # (it wants the rc, not the reason), and `say` tees to the log regardless --
    # which is the channel an operator actually reads.
    : >"$AUTOFLEET_DIR/fleet.log"
    in_fleet count_parked_owned >/dev/null 2>&1
    grep -q "could not read the build's state" "$AUTOFLEET_DIR/fleet.log" \
      || fail "a runner that would not say whether its build is running left the drain unbounded and said nothing: $(cat "$AUTOFLEET_DIR/fleet.log")"
    echo "ok: ...and says so rather than stalling in silence"

    # ...AND ON THE SCREEN, which is the channel #37 asks for. This function
    # returns its count on STDOUT and the poll reads it through
    # `parked="$(count_parked_owned)"`, so a `say` here would land inside
    # `$parked` -- which is why the callsite is `>/dev/null` and why the one
    # message the issue asks for reached `fleet.log` alone, never the terminal
    # running `fleet.sh run --auto`, while every other line in the poll body
    # appeared on screen. The phase asserting it against the log was green on the
    # wrong channel. armaatus/autofleet#71.
    rm -f "$AUTOFLEET_DIR/ps-blind-42"
    : >"$AUTOFLEET_DIR/held-42"
    build_blind
    # `2>&1 >/dev/null` in that ORDER: stderr onto the capture, then stdout away.
    onscreen="$(in_fleet count_parked_owned 2>&1 >/dev/null)"
    grep -q "could not read the build's state" <<<"$onscreen" \
      || fail "the warning about an unbounded drain goes to the log and nowhere a person watching the dispatcher can see it: [$onscreen]"
    echo "ok: ...on the operator's screen and not only in the log"
    # ...and STDOUT still carries nothing but the count, or the poll's next line
    # is arithmetic on a sentence.
    rm -f "$AUTOFLEET_DIR/ps-blind-42"
    n="$(in_fleet count_parked_owned 2>/dev/null)"
    case "$n" in ''|*[!0-9]*) fail "the count the poll reads is not a number: [$n]" ;; esac
    echo "ok: ...and the count the poll reads is still a bare number"
    build_exited
    rm -f "$AUTOFLEET_DIR/held-42" "$AUTOFLEET_DIR/ps-blind-42"

    # MERGE-HELD AND MERGE-BLIND ARE GATED TOO. They were reached only when a
    # `held-`/`git-blind-` marker was also on disk, so they were counted with no
    # agent check -- and `reap_merged`'s own comment says why that tree is dirty:
    # "auto-merge fires the moment the last check passes, so review fixes made
    # after it sit uncommitted here". That is an agent mid-work.
    build_running
    rm -f "$AUTOFLEET_DIR"/held-42 "$AUTOFLEET_DIR"/git-blind-*
    : >"$AUTOFLEET_DIR/merge-held-42"
    in_fleet count_parked_owned >/dev/null 2>&1
    [ "$(in_fleet count_parked_owned 2>/dev/null)" = 0 ] \
      || fail "merge-held-42 counted as waiting for a person while its agent is making review fixes, which is exactly when that marker is written"
    echo "ok: a merged worktree with a working agent is not waiting for a person"
    build_exited
    in_fleet count_parked_owned >/dev/null 2>&1
    [ "$(in_fleet count_parked_owned 2>/dev/null)" = 1 ] \
      || fail "merge-held-42 with an idle agent did not count, so the drain waits forever"
    echo "ok: ...and does once the agent is idle"
    rm -f "$AUTOFLEET_DIR/merge-held-42"
    # ...and leave the listing readable and the agent idle, or every assertion
    # after this one tests a runner that cannot answer rather than its subject.
    build_exited
    rm -f "$AUTOFLEET_DIR/held-42"

    # CASE (a): `stuck-` plus a stale `held-`, which nothing could ever clear.
    # The gate keyed on marker PRESENCE, so a worktree whose reason is "its
    # removal was refused" -- needing no agent check at all -- was still gated
    # on a `held-` beside it. And `held-` outlived everything: `park_worktree`
    # wrote `stuck-` without clearing it, after which both reaps return early.
    # `parked` 0, `owned` 1, the drain polls forever: #37 verbatim, in the PR
    # that closes #37. Found by the independent review.
    build_running
    : >"$AUTOFLEET_DIR/stuck-42"
    : >"$AUTOFLEET_DIR/held-42"
    in_fleet count_parked_owned >/dev/null 2>&1
    [ "$(in_fleet count_parked_owned 2>/dev/null)" = 1 ] \
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
    rm -f "$AUTOFLEET_DIR"/stuck-42 "$AUTOFLEET_DIR/held-42"
    # ...and hand the next block an IDLE agent. Case (a) above set it working to
    # prove the gate is not consulted for a refused removal; the block below is
    # about the two reasons that ARE gated, so a working agent there would make
    # it assert the opposite of its own message.
    build_exited

    # ...and the two reap_abandoned keeps, which an earlier comment asserted did
    # not exist. Uncounted, `owned` never reaches 0 and the drain never ends --
    # #37's unbounded drain through a different door, in the PR that closes #37.
    rm -f "$AUTOFLEET_DIR/merge-blind-42" "$AUTOFLEET_DIR/stuck-42"
    : >"$AUTOFLEET_DIR/held-42"
    : >"$AUTOFLEET_DIR/git-blind-99"
    # #99's build has stopped too, or the gate answers "could not tell" for it
    # and this counts one worktree while asserting two.
    build_state_for 99 "$WORK/wt99" 0
    in_fleet count_parked_owned >/dev/null 2>&1   # the pass that records them
    out="$(in_fleet count_parked_owned 2>/dev/null)"
    [ "$out" = 2 ] \
      || fail "held- and git-blind- are not counted as waiting for a person, so the drain waits on them forever:: $out"
    echo "ok: ...and all five keep-markers count"

    # ...AND THE TWO BLIND MARKERS ARE GATED ON A WORKING AGENT TOO, which
    # nothing armed. `held-` and `merge-held-` were pinned with `agent_state
    # working`; `git-blind-` and `merge-blind-` never were, so the gate they
    # shared could have stopped applying to them and the suite would have said
    # nothing. It could, and it nearly did: the gate matched the human sentence
    # `why_parked` prints, so rewording the blind line took the check off BOTH of
    # these at once. `merge-blind-` is the marker `reap_merged` writes in the
    # window its own comment says an agent is making review fixes.
    # armaatus/autofleet#71.
    for marker in git-blind merge-blind; do
      rm -f "$AUTOFLEET_DIR"/held-* "$AUTOFLEET_DIR"/git-blind-* \
            "$AUTOFLEET_DIR"/merge-held-* "$AUTOFLEET_DIR"/merge-blind-* \
            "$AUTOFLEET_DIR"/stuck-*
      build_running
      : >"$AUTOFLEET_DIR/$marker-42"
      in_fleet count_parked_owned >/dev/null 2>&1
      [ "$(in_fleet count_parked_owned 2>/dev/null)" = 0 ] \
        || fail "$marker-42 counted as waiting for a person while its agent is WORKING, and the dispatcher would sign off on top of it"
      build_exited
      in_fleet count_parked_owned >/dev/null 2>&1
      [ "$(in_fleet count_parked_owned 2>/dev/null)" = 1 ] \
        || fail "$marker-42 with an idle agent did not count, so the drain waits forever"
    done
    echo "ok: ...and both blind markers are gated on the agent, in each direction"

    # ...AND THE GATE SURVIVES THE SENTENCE BEING REWORDED, which is the
    # assertion that would have failed before the gate was re-keyed and the only
    # one that can: the change is behaviour-identical, so every outcome row
    # above passes on revert. The old `case` matched `$reason` -- the human line
    # `why_parked` prints -- so editing that line silently switched the gate off
    # and the worktree counted as waiting for a person while its agent wrote.
    # Rewording it in the fixture's own copy of fleet.sh is the fixture for that.
    # armaatus/autofleet#71, and found by `/mattpocock-skills:code-review` of the
    # change that claimed this without asserting it.
    # THE `printf` ONLY, not every occurrence of the sentence: a blanket
    # replace rewrites the old `case` pattern too, and then the prose-keyed gate
    # still matches its own reworded prose and the row passes on revert. The
    # fixture has to change what a PERSON reads and nothing else, which is
    # exactly the edit the gate must survive.
    sed -i.bak "s/printf 'git could not say what it holds/printf 'git will not say what is in there/" \
      "$WORK/repo/scripts/fleet/fleet.sh"
    rm -f "$WORK/repo/scripts/fleet/fleet.sh.bak"
    grep -q "git will not say what is in there" "$WORK/repo/scripts/fleet/fleet.sh" \
      || fail "the reword did not land, so this asserts nothing"
    rm -f "$AUTOFLEET_DIR"/held-* "$AUTOFLEET_DIR"/git-blind-* \
          "$AUTOFLEET_DIR"/merge-held-* "$AUTOFLEET_DIR"/merge-blind-* \
          "$AUTOFLEET_DIR"/stuck-* "$AUTOFLEET_DIR"/parked-since-*
    build_running
    : >"$AUTOFLEET_DIR/git-blind-42"
    in_fleet count_parked_owned >/dev/null 2>&1
    [ "$(in_fleet count_parked_owned 2>/dev/null)" = 0 ] \
      || fail "rewording the sentence took the agent gate off git-blind-; the dispatcher would sign off with an agent still writing"
    echo "ok: ...and rewording the reason a person reads does not switch the gate off"
    # ...AND REORDERING THE REASONS DOES NOT EITHER. The gate briefly keyed on
    # the ABSENCE of `stuck-`, which is the same answer only while `stuck-` is
    # the first entry in $PARK_MARKERS -- so a sixth reason added above it would
    # have ungated all five in silence. Moving `git-blind` to the front of that
    # list is the fixture for exactly that edit: precedence changes, and whether
    # `git-blind-` is gated must not. Found by `/mattpocock-skills:code-review`.
    sed -i.bak 's/^PARK_MARKERS=.*/PARK_MARKERS="git-blind stuck merge-held held merge-blind"/' \
      "$WORK/repo/scripts/fleet/fleet.sh"
    rm -f "$WORK/repo/scripts/fleet/fleet.sh.bak"
    grep -q '^PARK_MARKERS="git-blind ' "$WORK/repo/scripts/fleet/fleet.sh" \
      || fail "the reorder did not land, so this asserts nothing"
    # BOTH MARKERS, which is what makes this row distinguish the two keyings.
    # With `git-blind` first the reason IS `git-blind`, which is gated; the
    # absence-keyed version asks only whether `stuck-` is on disk, finds it, and
    # counts the worktree with its agent mid-work.
    rm -f "$AUTOFLEET_DIR"/held-* "$AUTOFLEET_DIR"/git-blind-* \
          "$AUTOFLEET_DIR"/merge-held-* "$AUTOFLEET_DIR"/merge-blind-* \
          "$AUTOFLEET_DIR"/stuck-* "$AUTOFLEET_DIR"/parked-since-*
    build_running
    : >"$AUTOFLEET_DIR/git-blind-42"
    : >"$AUTOFLEET_DIR/stuck-42"
    in_fleet count_parked_owned >/dev/null 2>&1
    [ "$(in_fleet count_parked_owned 2>/dev/null)" = 0 ] \
      || fail "the gate asked whether stuck- is on disk rather than which reason this is, so a reason ahead of stuck- is counted with its agent mid-work"
    echo "ok: ...and neither does reordering them"
    sed -i.bak 's/^PARK_MARKERS=.*/PARK_MARKERS="stuck merge-held held merge-blind git-blind"/' \
      "$WORK/repo/scripts/fleet/fleet.sh"
    rm -f "$WORK/repo/scripts/fleet/fleet.sh.bak"
    rm -f "$AUTOFLEET_DIR"/git-blind-* "$AUTOFLEET_DIR"/stuck-* \
          "$AUTOFLEET_DIR"/parked-since-*
    build_exited
    # ...and put the fixture back, or every row after this one runs against a
    # fleet.sh this phase edited and an agent it left working.
    sed -i.bak "s/printf 'git will not say what is in there/printf 'git could not say what it holds/" \
      "$WORK/repo/scripts/fleet/fleet.sh"
    rm -f "$WORK/repo/scripts/fleet/fleet.sh.bak"
    rm -f "$AUTOFLEET_DIR"/git-blind-* "$AUTOFLEET_DIR"/parked-since-*
    build_exited

    # ...AND THE TWO PLACES THAT TELL A PERSON know the same five. Counting a
    # worktree as waiting for someone and then never naming it is worse than not
    # counting it: it is present in the tally and absent from the list that says
    # what to do about it. `cmd_status` and the farewell both drifted the moment
    # there were more than three reasons, and `cmd_status`'s block had no test at
    # all -- delete it and the suite stayed green. Found by the independent
    # review, which called all three findings one crack.
    # `cmd_status` lists through `live_worktrees`, so the runner has to report
    # #42 as well as the fleet owning it.
    worktree_on_issue 42
    # ...and a build for #42 that has STOPPED, or the four gated reasons answer
    # "could not tell" and `status` says so instead of naming it.
    build_exited
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

    # ...AND STATUS AGREES WITH THE COUNT. `cmd_status` called `why_parked` raw
    # while the counter wrapped it in the agent gate, so a worktree the counter
    # deliberately refused to call parked was printed by `status` as parked --
    # and handed a person a recovery line for a directory an agent is writing
    # to. Same crack, opposite direction. One predicate now. Found by the
    # independent review.
    rm -f "$AUTOFLEET_DIR"/stuck-* "$AUTOFLEET_DIR"/merge-held-* \
          "$AUTOFLEET_DIR"/merge-blind-* "$AUTOFLEET_DIR"/held-* \
          "$AUTOFLEET_DIR"/git-blind-*
    : >"$AUTOFLEET_DIR/held-42"
    build_running
    out="$(in_fleet cmd_status 2>&1)"
    grep -q "waiting for you" <<<"$out" \
      && fail "status called #42 'waiting for you' while its agent is working, and told a person to go and discard what is in there: $out"
    echo "ok: status does not call a worktree parked while its agent works"
    build_exited
    out="$(in_fleet cmd_status 2>&1)"
    grep -q "waiting for you" <<<"$out" \
      || fail "status stopped naming a genuinely parked worktree once the gate was shared: $out"
    echo "ok: ...and still names it once the agent is idle"

    # EVERY park reason is cleared on release. Not driven from a list -- there
    # is none, deliberately, see why_parked -- but asserted for all five, because
    # a marker outliving its release gates the NEXT worktree for that issue with
    # the last one's state.
    for reason in stuck merge-held merge-blind held git-blind; do
      : >"$AUTOFLEET_DIR/$reason-42"
    done
    in_fleet clear_issue_markers 42 >/dev/null 2>&1
    for reason in stuck merge-held merge-blind held git-blind; do
      [ -e "$AUTOFLEET_DIR/$reason-42" ] \
        && fail "$reason-42 outlived the release, so the next worktree for #42 is gated by the last one's marker"
    done
    echo "ok: ...and releasing an issue clears every park reason in the list"

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
    # THE REFUSAL HAS TO COME FROM A RUNTIME, so this phase runs on the
    # app-backed driver: `git worktree remove --force` does not refuse, and a
    # park that cannot be reached is a claim about the dispatcher that nothing
    # would be asserting.
    use_orca_runner
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
    # ...AS ITS LAST LINES, which is what #37's third acceptance bullet asks and
    # what it got one line short of. The naming block ran inside the loop and
    # `fleet down: $reason` printed after it -- and `$reason` carries a COUNT
    # ("and 1 worktree(s) are waiting for you"), not which issue and not the
    # command that releases it. A reader stops at the last line. Nothing pinned
    # the ordering, because this phase greps the whole log.
    # armaatus/autofleet#71.
    down="$(grep -n "fleet down" "$WORK/run.log" | tail -1 | cut -d: -f1)"
    named="$(grep -n -- "#42 --" "$WORK/run.log" | tail -1 | cut -d: -f1)"
    freed="$(grep -n "worktree remove --force" "$WORK/run.log" | tail -1 | cut -d: -f1)"
    [ -n "$down" ] && [ -n "$named" ] && [ -n "$freed" ] \
      || fail "the farewell, the name or the release command is missing: $(cat "$WORK/run.log")"
    [ "$named" -gt "$down" ] && [ "$freed" -gt "$named" ] \
      || fail "\`fleet down\` is the last line a person reads, and it carries a count rather than which issue or how to free it (down=$down named=$named freed=$freed): $(cat "$WORK/run.log")"
    echo "ok: ...as its LAST lines, naming the issue and the command that frees it"
    [ -d "$WORK/wt" ] \
      || fail "it released the parked worktree, which is what parking exists to prevent"
    echo "ok: ...and leaves it alone"
    ;;

  remove_advice)
    make_fixture rm_never_works
    use_orca_runner
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
    use_orca_runner
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
    use_orca_runner
    make_worktree
    add_origin
    # HEAD still reads, so the branch and the merged-PR lookup both answer; the
    # index does not, so `git status` cannot say whether anything is uncommitted.
    # THE WORKTREE'S OWN GIT DIR, resolved rather than assumed: `$WORK/wt` is a
    # real `git worktree add` now, so `.git` in it is a FILE pointing at
    # `<repo>/.git/worktrees/<name>` and `.git/index` is not a path at all.
    printf 'not an index' >"$("$REAL_GIT" -C "$WORK/wt" rev-parse --absolute-git-dir)/index"
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
    use_orca_runner
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
    use_orca_runner
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
    use_orca_runner
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
    # ...AND EVERY OTHER SAY-ONCE MARKER, because they are the same shape and
    # the same rule. `rotate-blind` was cleared by nothing at all, so "rotating
    # with a pid ps cannot name" was said once per MACHINE -- an operator
    # debugging truncated reviewer output next month got no line at all, which
    # is the same silence this phase exists to end. Found by the independent
    # review.
    : >"$AUTOFLEET_DIR/rotate-blind"
    start_dispatcher --auto
    wait_for_log "lands alone"
    echo "ok: a restarted dispatcher explains its own hold rather than inheriting silence"
    [ -e "$AUTOFLEET_DIR/rotate-blind" ] \
      && fail "the rotation's say-once marker survived a dispatcher start, so it speaks once per machine rather than once per run"
    echo "ok: ...and the rotation's say-once marker goes with it"
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

  waiting_names_foreign)
    make_fixture ok
    # THE DASH BRANCH, which is the branch the hold is about. `live_worktrees`
    # writes `-` for a worktree with no linked issue -- hand-opened, or another
    # repository's -- and that is precisely the one a person most needs named,
    # because it is the one nobody in this repository can close. #31/#46 were
    # holds that could not say which kind they were waiting on; nothing passed a
    # `-` through `waiting_worktrees` until now.
    #
    # And the two readers of one listing have to agree. `cmd_status` printed
    # `#-` for such a worktree while the hold printed its basename, so the line
    # a person reads on screen and the line in the log named the same directory
    # two ways. armaatus/autofleet#71.
    worktree_list "42:wt" "-:handmade"
    named="$(in_fleet waiting_worktrees "$(in_fleet live_worktrees)")"
    grep -q "handmade" <<<"$named" \
      || fail "the hold does not name the worktree nobody here can close: [$named]"
    grep -q -- "#-" <<<"$named" \
      && fail "the hold printed a dash where a person needs a name: [$named]"
    grep -q -- "#42" <<<"$named" \
      || fail "the linked worktree stopped being named by its issue: [$named]"

    dispatcher_running
    in_fleet record_dispatcher
    out="$(in_fleet cmd_status 2>&1)"
    grep -q -- "#-" <<<"$out" \
      && fail "status prints a bare dash for a worktree the hold names by its directory: $out"
    # ANCHORED ON THE LABEL COLUMN. A bare `grep handmade` is satisfied by the
    # PATH column beside it, so a `cmd_status` that still rendered `#-` in the
    # label and printed the path unchanged would pass -- which is the row
    # asserting nothing that this phase exists to stop.
    # Found by `/mattpocock-skills:code-review`.
    grep -q "^  handmade " <<<"$out" \
      || fail "status does not name the unlinked worktree the way the hold does: $out"
    grep -q -- "#42" <<<"$out" \
      || fail "status stopped naming the linked worktree by its issue: $out"
    echo "ok: an unlinked worktree is named by its directory, in the hold and on screen"
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
    # ...AND IT IS THIS FUNCTION'S OWN CACHE THAT DID IT. armaatus/autofleet#30
    # put a cache under `live_worktrees` too, and `in_poll` switches it on -- so
    # the count above now passes whichever of the two caches is working. Delete
    # `$POLL_CACHE/foundation` and calls two and three read the cached LIST
    # instead of the runner, the count stays 1, and the phase stays green while
    # the thing it is named for is gone. That is the hole this PR went and filled
    # with `foundation_sees_launch`, reopened one level up by its own helper
    # widening. Found by the independent review of that change.
    #
    # `IN_POLL=false` takes the lower cache out of the way, so the count is
    # about the upper one and nothing else. Three reads is the answer when
    # `foundation_in_flight` has no cache of its own.
    : >"$ORCA_CALLS"
    in_pass 'IN_POLL=false
      foundation_in_flight
      foundation_in_flight
      foundation_in_flight' >/dev/null 2>&1
    n="$(grep -c "^worktree list" "$ORCA_CALLS" || true)"
    [ "${n:-0}" = 1 ] \
      || fail "with the list cache out of the way, three calls read the list $n times -- this function's own cache is not what makes it one"
    echo "ok: ...and it is this function's own cache doing it, not the one underneath"
    ;;

  poll_list_once)
    # armaatus/autofleet#30. The list underneath that answer was read three times
    # a pass -- the launch gate's count, `foundation_in_flight`, and
    # `count_startable` -- plus once more per issue `in_flight` was asked about.
    # Each one is a subprocess out to the runner for a list that cannot change
    # between them, which is the pattern `count_startable` exists to avoid.
    #
    # `-eq 1`, not `-le 1`, for the reason `foundation_one_lookup` gives: a
    # `live_worktrees` that never read the list at all would satisfy `-le` while
    # answering from nothing.
    make_fixture ok
    worktree_on_issue 4
    issue_labels "ready,docs"
    in_pass '
      live_worktrees
      foundation_in_flight
      count_startable
      in_flight 4' >/dev/null 2>&1
    n="$(grep -c "^worktree list" "$ORCA_CALLS" || true)"
    [ "${n:-0}" = 1 ] \
      || fail "one pass read the worktree list $n times; four callers share one answer"
    echo "ok: a pass that launches nothing reads the worktree list once"
    ;;

  poll_list_after_launch)
    # ...and a pass that LAUNCHES reads it again, which is the half a count over
    # a quiet pass cannot see. `launch` changes the list, so the cached copy
    # describes a world one worktree out of date -- and the read after it is what
    # makes `foundation_in_flight` on the next iteration see the worktree this
    # launch just created. That guarantee is `foundation_sees_launch`'s; this
    # phase is the cost half, and it fails in BOTH directions: at 1 the
    # invalidation is gone, at 5 the cache is.
    make_fixture ok
    worktree_on_issue 4
    issue_labels "ready,docs"
    in_pass '
      live_worktrees
      foundation_in_flight
      count_startable
      launch 44 "a second issue"
      # What the launch loop does next, and what the next iteration asks.
      live_worktrees
      foundation_in_flight' >/dev/null 2>&1
    grep -q "^worktree create" "$ORCA_CALLS" \
      || fail "the launch never happened, so what follows asserts nothing: $(cat "$ORCA_CALLS")"
    n="$(grep -c "^worktree list" "$ORCA_CALLS" || true)"
    # The dump, not just the count: this assertion has no slack, it was seen to
    # flake once under load and not again in ~70 runs, and the next agent to meet
    # it red will not have this PR body in front of them. Found by the
    # independent review.
    [ "${n:-0}" = 2 ] \
      || fail "a pass that launched once read the worktree list $n times; it is one per pass plus one per launch. CALLS=[$(cat "$ORCA_CALLS")]"
    echo "ok: a launch costs exactly one more read, and everything after it shares that one"
    ;;

  poll_list_after_remove)
    # The other invalidation point. A removal takes a worktree OUT of the list,
    # and a pass that kept reading the cached copy would count a slot that is
    # already free as taken -- and `foundation_in_flight`, whose answer is read
    # off the same list, would hold the fleet for a worktree that is gone.
    #
    # Which is why both drops go through one function: two caches over one list
    # with two invalidation points is what armaatus/autofleet#30 says not to
    # leave behind.
    make_fixture ok
    make_worktree
    in_pass '
      live_worktrees
      remove_worktree "$WORK/wt"
      live_worktrees' >/dev/null 2>&1
    [ -d "$WORK/wt" ] \
      && fail "the removal did not happen, so what follows asserts nothing"
    n="$(grep -c "^worktree list" "$ORCA_CALLS" || true)"
    [ "${n:-0}" = 2 ] \
      || fail "a pass that removed a worktree read the list $n times; the read after a removal is not optional"
    echo "ok: a removal drops the cached list too, not only the answer read off it"
    ;;

  poll_list_cache_unreadable)
    # The cached read fails CLOSED. `[ -e ]` says the entry is an answer, but a
    # `cat` that cannot read it prints nothing -- and an empty listing is not
    # "could not tell", it is "no worktrees are running", which the launch gate
    # reads as three free slots. This function's header opens with that exact
    # failure: "reading a failed call as zero live worktrees is how one transient
    # hiccup turns into three duplicate worktrees for issues that already have
    # one". Found by both local review passes, independently.
    #
    # A DIRECTORY where the file should be, rather than `chmod 000`: it is the
    # same "exists and will not read" to `[ -e ]` and to `cat`, and it stays that
    # way for root, who ignores the mode bits and would pass this phase for the
    # wrong reason on any machine that runs the suite as one.
    make_fixture ok
    worktree_on_issue 4
    out="$(in_pass '
      live_worktrees >/dev/null || { echo "seed=failed"; exit 0; }
      rm -f "$POLL_CACHE/worktrees"; mkdir -p "$POLL_CACHE/worktrees"
      answer="$(live_worktrees)"; echo "rc=$? answer=[$answer]"' 2>/dev/null)"
    grep -q "seed=failed" <<<"$out" \
      && fail "the first read cached nothing, so what follows asserts nothing: $out"
    grep -q "rc=" <<<"$out" \
      || fail "the phase never reached the second read: $out"
    # `rc=1`, not just "not rc=0 and empty". An implementation that fell THROUGH
    # from an unreadable entry to a fresh runner read passes the weaker form
    # while doing the thing `live_worktrees` explicitly rejects -- a `cat` that
    # died part-way has already printed half a listing, and the fresh read would
    # hand the caller that half twice. Found by the independent review.
    grep -q "rc=1" <<<"$out" \
      || fail "an unreadable cache did not answer 'could not read it': $out"
    n="$(grep -c "^worktree list" "$ORCA_CALLS" || true)"
    [ "${n:-0}" = 1 ] \
      || fail "the unreadable cache was answered by re-reading the runner ($n reads), not by failing"
    echo "ok: a cache entry that will not read is a failure, not an empty fleet"
    ;;

  poll_list_reshape_fails)
    # ...and so does the reshape. The awk that turns the driver's
    # `path<TAB>branch<TAB>issue` into the `issue<TAB>path` every caller reads
    # used to be this function's LAST command, so an awk that died came back as
    # the function's own non-zero. Caching made it a middle command, with a
    # `print_listing` after it that always succeeds -- and an empty listing
    # returned with SUCCESS is three free slots, cached for the rest of the pass.
    # Found by the local review.
    #
    # A shell function shadowing `awk`, because what is being modelled is an awk
    # that is not there or cannot run -- this file is vendored onto host images
    # nobody here chose. Emptying `PATH` would take the rest of the dispatcher
    # with it and prove nothing about this line.
    make_fixture ok
    worktree_on_issue 4
    out="$(in_pass '
      awk() { return 127; }
      answer="$(live_worktrees)"; echo "rc=$? answer=[$answer]"' 2>/dev/null)"
    grep -q "rc=" <<<"$out" || fail "the phase never reached the read: $out"
    grep -q "rc=0" <<<"$out" \
      && fail "a reshape that failed answered 'no worktrees are running', with success: $out"
    [ -e "$AUTOFLEET_DIR/poll-cache/worktrees" ] \
      && fail "a reshape that failed cached its empty answer for the rest of the pass"
    echo "ok: a reshape that fails is a failure, not an empty fleet"
    ;;

  poll_list_short_write)
    # ...and a WRITE that fails part-way. The `mv` closes the interruption half
    # of the atomicity -- a dispatcher killed mid-write leaves the `.new` behind
    # and the answer untouched -- and left the write-ERROR half open: a `printf`
    # that put down half the listing and then died (ENOSPC or EIO on $STATE_DIR,
    # its stderr already swallowed) still returned 0 through `print_listing`, the
    # `&&` fired, and `mv` installed the half as the pass's answer.
    #
    # A SHORT listing is worse than an empty one. `in_flight` reads this same
    # list, so an issue whose worktree fell off the end of the file reads as
    # free, and the pass opens a second worktree for work that is already
    # running. Found by the independent review.
    #
    # The shadow is keyed on the FORMAT, because `live_worktrees` calls `printf`
    # twice and only one of them is this: `%s` reshapes the driver's lines and
    # must go through, `%s\n` is `print_listing` and is the one being broken.
    make_fixture ok
    worktree_on_issue 4
    out="$(in_pass '
      printf() {
        if [ "$1" = "%s\n" ]; then command printf "%s" "trunc"; return 1; fi
        command printf "$@"
      }
      answer="$(live_worktrees)"; echo "rc=$? answer=[$answer]"' 2>/dev/null)"
    grep -q "rc=" <<<"$out" || fail "the phase never reached the read: $out"
    grep -q "rc=0" <<<"$out" \
      && fail "a write that died part-way was reported as success: $out"
    [ -e "$AUTOFLEET_DIR/poll-cache/worktrees" ] \
      && fail "half a listing was installed as the pass's answer, and in_flight reads it as a free slot"
    [ -e "$AUTOFLEET_DIR/poll-cache/worktrees.new" ] \
      && fail "the half-written temporary was left behind for the next pass to find"
    echo "ok: a write that dies part-way installs nothing and says so"
    ;;

  poll_cache_gate_empty)
    # An EMPTY $IN_POLL reads as closed, not as open. Bash runs a simple command
    # that expands to no words with status 0, so a bare `$IN_POLL` would read as
    # true and switch the caching ON -- fail-open, in the one function whose
    # every comment is about failing closed.
    #
    # Nothing in this tree can reach that: the assignment is at source time. It
    # is covered because `forget_worktree_answers` carries a `${POLL_CACHE:-}`
    # guard written for the armaatus/rommsync-nx `sed` extraction that may bring
    # functions without the top-level assignments, and this gate is the other
    # half of exactly that case -- with `$cached` becoming `/worktrees` and the
    # write reaching for `/worktrees.new`. Found by the independent review.
    make_fixture ok
    worktree_on_issue 4
    out="$(in_pass 'IN_POLL=""
      live_worktrees >/dev/null 2>&1
      [ -e "$POLL_CACHE/worktrees" ] && echo "cached=yes" || echo "cached=no"
      poll_cache_open && echo "gate=open" || echo "gate=closed"' 2>&1)"
    grep -q "gate=closed" <<<"$out" \
      || fail "an empty \$IN_POLL opened the cache gate: $out"
    grep -q "cached=no" <<<"$out" \
      || fail "an empty \$IN_POLL wrote the poll cache: $out"
    echo "ok: an empty \$IN_POLL reads as closed, not as open"
    ;;

  poll_list_once_in_run)
    # Acceptance 1 is about a POLL, and the phases above count over a sequence
    # they spell out themselves -- right about the mechanism, but not a floor
    # under the pass. A read added inside `reap_merged`, `review_open_prs` or
    # `notice_stalled` satisfies every one of them and still breaks the
    # acceptance. This one counts over `cmd_run`'s own body. Found by the
    # independent review.
    #
    # One pass and then out, because the issue it is given is already closed:
    # `wanted` empties, nothing is startable, and the run ends on its own. Same
    # shape as `poll_empties_cache`, which needs a bounded real dispatcher for
    # the same reason -- and `--max-prs 1` bounds the failure path, where a
    # launch would otherwise keep it polling.
    make_fixture ok
    make_repo_git
    add_origin
    worktree_on_issue 4
    issue_state CLOSED; issue_labels "ready"
    ( in_fleet cmd_run --max-prs 1 148 >"$WORK/run.log" 2>&1 ) &
    HELD_PID=$!
    wait_for_log "fleet up" \
      || fail "the dispatcher never started: $(cat "$WORK/run.log" 2>/dev/null)"
    run_ended "$HELD_PID" >/dev/null 2>&1
    HELD_PID=""
    n="$(grep -c "^worktree list" "$ORCA_CALLS" || true)"
    [ "${n:-0}" = 1 ] \
      || fail "one pass of cmd_run read the worktree list $n times: $(cat "$WORK/run.log")"
    echo "ok: one pass of the real poll body reads the worktree list once"
    ;;

  foundation_sees_launch)
    # armaatus/autofleet#30's third acceptance, and it did not hold before this
    # phase existed -- not here and not on main. `launch`'s cache drop is what
    # makes the NEXT iteration's `foundation_in_flight` see the worktree the
    # launch just created, and deleting that line failed NOTHING:
    # `foundation_cold_start`, `foundation_launch_held` and `foundation_holds`
    # all stayed green. The launch loop breaks on `is_foundation "$labels"` from
    # the issue it has just launched and never reaches the next iteration, so
    # every phase that drives `cmd_run` stops one step short of the line.
    #
    # That per-iteration check's own comment already says it covers "the
    # across-passes half". The within-a-pass half had no phase at all, which is
    # hard rule 3's shape -- and it is why #30's premise, that the drop "is
    # load-bearing enough to have its own test phase", is stale. #30 is edited
    # to say so.
    #
    # Asserted on the FUNCTION rather than through `cmd_run`, because the launch
    # loop's own break is exactly what hides this.
    make_fixture ok
    issue_labels "ready,foundation"
    out="$(in_pass '
      foundation_in_flight; echo "before=$?"
      launch 44 "the foundation one"
      foundation_in_flight; echo "after=$?"' 2>&1)"
    grep -q "before=1" <<<"$out" \
      || fail "it held with nothing in flight, so what follows asserts nothing: $out"
    grep -q "after=0" <<<"$out" \
      || fail "the check after a launch did not see the foundation worktree that launch created: $out"
    echo "ok: the check after a launch sees the worktree the launch created"
    ;;

  status_list_uncached)
    # #35's acceptance, defended at the mechanism rather than at the call graph.
    # `cmd_status` asks `in_flight` about every ready issue for its `next up`
    # table, and `in_flight` reads the worktree list -- so the moment that list
    # became cacheable, `status` became a writer into $STATE_DIR.
    #
    # The write is the small half. `status_keeps_cache` would still pass, because
    # it compares the second status against the first and by then the entry is
    # already there. The damage is a `status` in the watch loop docs/WORKFLOW.md
    # prescribes handing the dispatcher beside it a list read at another moment
    # in its pass -- a stale list is a duplicate worktree, or a foundation hold
    # that never fires.
    make_fixture ok
    worktree_on_issue 42
    mkdir -p "$AUTOFLEET_DIR/poll-cache"
    out="$(in_fleet_keeping_cache cmd_status 2>&1)"
    grep -q "#42" <<<"$out" \
      || fail "status listed no worktree, so it never reached the read this phase is about: $out"
    [ -e "$AUTOFLEET_DIR/poll-cache/worktrees" ] \
      && fail "status cached a worktree list into a live dispatcher's poll cache; #35 is that it leaves \$STATE_DIR alone"
    # BOTH files. The write is `>"$cached.new"` and then a `mv`, so a shape where
    # the `mv` fails leaves the temporary behind -- a `status` that wrote into
    # $STATE_DIR with this phase still green. Found by the independent review.
    [ -e "$AUTOFLEET_DIR/poll-cache/worktrees.new" ] \
      && fail "status left a half-written cache temporary in \$STATE_DIR"
    echo "ok: status reads the worktree list without writing the poll cache"
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
    # the only honest answer. `live_worktrees` already refuses to guess from
    # this shape; this is the same refusal one question later.
    make_fixture ok
    use_orca_runner
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
  priority_first)
    make_fixture ok
    # #7 is what the queue would pick on its own: lowest number, and two issues
    # name it as a blocker. #151 frees nothing and is the highest number here,
    # so if it comes out first it can only be the label that put it there.
    cat >"$GH_ISSUES" <<'JSON'
[{"number":7,"title":"the queue would pick this","body":"","labels":[{"name":"ready"}]},
 {"number":9,"title":"blocked by 7","body":"<!-- blockers -->\nBlocked by #7","labels":[{"name":"blocked"}]},
 {"number":10,"title":"blocked by 7 as well","body":"<!-- blockers -->\nBlocked by #7","labels":[{"name":"blocked"}]},
 {"number":151,"title":"the one a person wants first","body":"","labels":[{"name":"ready"},{"name":"priority"}]},
 {"number":152,"title":"priority, and its last step is yours","body":"","labels":[{"name":"ready"},{"name":"priority"},{"name":"needs-human-step"}]},
 {"number":153,"title":"priority, and still blocked","body":"","labels":[{"name":"blocked"},{"name":"priority"}]}]
JSON
    out="$(in_fleet ready_issues 2>&1)"
    [ "$(head -1 <<<"$out" | cut -f1)" = 151 ] \
      || fail "the labelled issue did not go first, so the label buys nothing: $out"
    echo "ok: a priority issue outranks the issue that frees the most work"
    grep -q "^7" <<<"$out" \
      || fail "labelling one issue dropped the rest of the queue: $out"
    echo "ok: ...and the rest of the queue is still there, behind it"
    grep -q "^152" <<<"$out" \
      && fail "priority started an issue whose last step is a person's: $out"
    echo "ok: priority does not make a needs-human-step issue startable"
    grep -q "^153" <<<"$out" \
      && fail "priority started a BLOCKED issue, which is the one thing no label may do: $out"
    echo "ok: priority does not make a blocked issue startable"
    ;;
  status_priority)
    make_fixture ok
    cat >"$GH_ISSUES" <<'JSON'
[{"number":7,"title":"the queue would pick this","body":"","labels":[{"name":"ready"}]},
 {"number":151,"title":"the one a person wants first","body":"","labels":[{"name":"ready"},{"name":"priority"}]}]
JSON
    out="$(in_fleet cmd_status 2>&1)"
    # A `next up` list that has been reordered with nothing on screen saying why
    # reads as a bug in the ordering, and gets reported as one.
    grep -qE "^ +#151 +[0-9]+ +priority " <<<"$out" \
      || fail "the reordered row is not marked, so the queue looks wrong rather than steered: $out"
    echo "ok: status marks the row that is ahead of the ordering"
    grep -qE "^ +#7 +[0-9]+ +priority " <<<"$out" \
      && fail "an unlabelled issue was marked as priority: $out"
    echo "ok: ...and only that row"
    ;;
  priority_renamed)
    make_fixture ok
    # The label is a knob (AUTOFLEET_PRIORITY_LABEL), and a host repo that
    # renames it must not silently get the default back -- which is what a
    # hardcoded word in the python would do, with nothing on screen to say so.
    cat >"$GH_ISSUES" <<'JSON'
[{"number":7,"title":"the queue would pick this","body":"","labels":[{"name":"ready"}]},
 {"number":151,"title":"labelled with the house word","body":"","labels":[{"name":"ready"},{"name":"now"}]},
 {"number":152,"title":"labelled with the default","body":"","labels":[{"name":"ready"},{"name":"priority"}]}]
JSON
    out="$(AUTOFLEET_PRIORITY_LABEL=now in_fleet ready_issues 2>&1)"
    [ "$(head -1 <<<"$out" | cut -f1)" = 151 ] \
      || fail "the renamed label was not read, so the knob is decoration: $out"
    echo "ok: AUTOFLEET_PRIORITY_LABEL renames the label the queue reads"
    # ...AND THE DEFAULT WORD LOST ITS EFFECT, which is the half that catches a
    # python that reads the knob and keeps `priority` beside it. #152 carries
    # the default and must now sort like any other ready issue -- so it must not
    # come ahead of #7, which carries nothing. Without this the phase passes on
    # an implementation that honours both words at once. Found by the
    # independent review.
    rest="$(tail -n +2 <<<"$out" | cut -f1 | tr '\n' ' ')"
    case "$rest" in
      "152 "*) fail "the default word still sorted ahead with the knob renamed, so both words are live: $out" ;;
    esac
    echo "ok: ...and the default word stops being one"
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
  one_lookup)
    make_fixture ok
    make_worktree
    add_origin
    build_ran_out
    issue_labels "ready,needs-human-step"
    : >"$GH_MERGED"
    # BOTH watchers, in one process, which is what a poll is. They ask the same
    # question about the same issue, so a second round-trip is exactly the drift
    # the shared answer exists to stop. It was three watchers before
    # armaatus/autofleet#151 and the claim is unchanged.
    in_poll reap_abandoned notice_build_exit >/dev/null 2>&1
    n="$(grep -c -- "--json state,labels" "$GH_CALLS")"
    [ "$n" = 1 ] \
      || fail "asked GitHub $n times for one issue's state and labels in one poll"
    echo "ok: one poll asks for an issue's state and labels once"
    ;;
  own_clears)
    make_fixture ok
    make_worktree
    add_origin
    build_ran_out
    # Everything a previous worktree for this issue leaves standing, armed by
    # driving the dispatcher through the passes that write each one rather than
    # by touching the files: a marker set by hand asserts against a state the
    # code may never produce.
    quiet_issue
    in_fleet notice_build_exit >/dev/null 2>&1
    issue_labels FAIL
    in_fleet reap_abandoned >/dev/null 2>&1
    armed=""
    for m in build-done exit-blind queue-labels unreachable human-step held stuck warned parked-since; do
      [ -e "$AUTOFLEET_DIR/$m-42" ] && armed="$armed $m"
    done
    [ -n "$armed" ] \
      || fail "no per-issue marker was armed at all, so the assertion that follows would be vacuous"
    # `live_worktrees` can stop listing a worktree while its markers stand, so
    # the dispatcher opens a SECOND worktree for an issue whose markers are all
    # still set. Each of them throttles a message to once, so the new worktree
    # inherits silence: a standing marker makes the dispatcher say nothing at
    # all about a worktree that is genuinely stuck.
    in_fleet own 42 "$WORK/wt" >/dev/null 2>&1
    for m in $armed; do
      [ -e "$AUTOFLEET_DIR/$m-42" ] \
        && fail "$m-42 survived into a fresh worktree, which is silenced by it"
    done
    echo "ok: a fresh worktree starts with nothing already said on its behalf"
    ;;
  own_outlives_release)
    make_fixture ok
    # WHAT AN ISSUE COST HAS TO OUTLIVE ITS WORKTREE. The owned registry is what
    # is RUNNING, and `disown_issue` empties it the moment a worktree is
    # released -- so a cost report built on it alone goes blank exactly when a
    # run finishes, which is when somebody asks what it cost.
    #
    # A second registry under `$AUTOFLEET_DIR/ran/` used to carry that, because
    # the report found an issue's cost by slugging every path it had run in into
    # the agent CLI's transcript root. The build directory is keyed on the ISSUE
    # and outlives everything, so the registry became a store nothing read and
    # went with the slug (armaatus/autofleet#151). This is the claim that
    # survived it.
    in_fleet own 42 "$WORK/wt" >/dev/null 2>&1
    mkdir -p "$AUTOFLEET_DIR/builds/42"
    printf '{"num_turns":9,"total_cost_usd":1.25}\n' >"$AUTOFLEET_DIR/builds/42/result.json"
    in_fleet disown_issue 42 >/dev/null 2>&1
    [ -e "$AUTOFLEET_DIR/worktrees/42" ] \
      && fail "disown_issue left the OWNED entry behind; the fixture proves nothing"
    out="$( cd "$WORK/repo" && ./scripts/fleet/cost.sh 42 2>&1 )"
    grep -q "1.25" <<<"$out" \
      || fail "releasing the worktree erased what #42 cost: $out"
    echo "ok: what an issue spent survives the release of the worktree it spent it in"

    # ...and `own` still clears the per-issue markers, which is the other half of
    # what it is for: a fresh worktree must start with nothing already said on
    # its behalf, or it inherits the previous attempt's silence.
    : >"$AUTOFLEET_DIR/held-42"
    : >"$AUTOFLEET_DIR/build-done-42"
    in_fleet own 42 "$WORK/wt" >/dev/null 2>&1
    for m in held build-done; do
      [ -e "$AUTOFLEET_DIR/$m-42" ] \
        && fail "$m-42 survived into a fresh worktree, which is silenced by it"
    done
    echo "ok: ...and a fresh worktree starts with nothing already said on its behalf"
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
    build_running
    out="$(release_pass)"
    [ -d "$WORK/wt" ] || fail "it removed the worktree of an agent that is still working: $out"
    [ -e "$AUTOFLEET_DIR/worktrees/42" ] \
      || fail "it disowned an issue that is still being worked, so the cap stops counting it"
    grep -q "worktree rm" "$ORCA_CALLS" && fail "it attempted a removal with no reason to: $out"
    [ -n "$out" ] && fail "it had nothing to say and said it anyway: $out"
    echo "ok: an ordinary in-flight worktree is left alone"
    ;;
  gaveup_not_restarted)
    make_fixture ok
    make_worktree
    add_origin
    quiet_issue
    build_ran_out
    cat >"$GH_ISSUES" <<'JSON'
[{"number":42,"title":"the one that ran out of turns","body":"","labels":[{"name":"ready"}]}]
JSON
    echo '[]' >"$GH_PRS"
    in_fleet notice_build_exit >/dev/null 2>&1
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
    quiet_issue
    build_ran_out
    in_fleet notice_build_exit >/dev/null 2>&1
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
    build_running
    out="$(release_pass)"
    [ -d "$WORK/wt" ] \
      || fail "it removed the worktree on the pass that found the reason, with no notice: $out"
    grep -q "next pass" <<<"$out" || fail "it did not say what happens next: $out"
    # THE BUILD IS STOPPED ON THE WARNING PASS, so the poll of grace is a poll
    # in which nothing new is written into a directory that is about to go. It
    # was an interrupt typed at a session before armaatus/autofleet#151; the
    # claim is the same one.
    if kill -0 "$(cat "$AUTOFLEET_DIR/builds/42/pid" 2>/dev/null)" 2>/dev/null; then
      fail "it warned the board and left the build writing into a rig that is going"
    fi
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
    quiet_issue
    build_ran_out
    in_fleet notice_build_exit >/dev/null 2>&1
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
    build_running
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
    build_running
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
    # THE SNAPSHOT HASHES CONTENTS, not the list of names. `find . | sort |
    # cksum` hashes PATHS: an append to an already-existing fleet.log, or a
    # marker rewritten in place, passes it unchanged -- and `say` is
    # `tee -a "$STATE_DIR/fleet.log"`, so the one write `cmd_status` was most
    # likely to make was precisely the one a name-hash cannot see. The phase
    # quoted "byte-identical" twice and asserted something strictly weaker.
    # Found by the independent review.
    #
    # `cksum <"$f"`, not `cksum "$f"`: the second prints the filename too, and
    # the names are already covered by the `find` half above it.
    state_bytes() {
      (cd "$AUTOFLEET_DIR" \
        && find . | sort \
        && find . -type f | sort | while IFS= read -r f; do
             printf '%s ' "$f"; cksum <"$f"
           done) | cksum
    }
    in_fleet_keeping_cache cmd_status >/dev/null 2>&1
    before="$(state_bytes)"
    out="$(in_fleet_keeping_cache cmd_status 2>&1)"
    [ -e "$AUTOFLEET_DIR/poll-cache/interrupted-42" ] \
      || fail "status dropped interrupted-42, so the next pass re-interrupts an agent the time-box already stopped"
    [ -e "$AUTOFLEET_DIR/poll-cache/carded-42" ] \
      || fail "status dropped carded-42, so the next pass writes a second board comment under whoever is working in there"
    [ -e "$AUTOFLEET_DIR/poll-cache/issue-42" ] \
      || fail "status dropped issue-42, so every watcher re-issues the gh lookup poll_issue exists to avoid"
    after="$(state_bytes)"
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

    # ...AND THROUGH THE PARKED PATH, which is the one this PR added and the one
    # nothing here reached: with no owned worktree carrying a park reason,
    # `cmd_status` never called `parked_for_person` at all, so the `ps-blind-`
    # write inside it could be deleted and this phase stayed green. An assertion
    # that exists but not for the property the issue names is hard rule 3's
    # subject. Found by the independent review.
    #
    # The state it needs is the one this repo keeps three phases for: the
    # worktree listing ANSWERS (so `live_worktrees` reports #42) while the agent
    # states do NOT (so `parked_for_person` takes its blind arm). They are two
    # different runner calls and they fail independently.
    mkdir -p "$AUTOFLEET_DIR/worktrees"
    printf '%s\n' "$WORK/wt" >"$AUTOFLEET_DIR/worktrees/42"
    : >"$AUTOFLEET_DIR/held-42"
    worktree_on_issue 42
    printf 'not json' >"$ORCA_PS"
    rm -f "$AUTOFLEET_DIR/ps-blind-42"
    in_fleet_keeping_cache cmd_status >/dev/null 2>&1
    before="$(state_bytes)"
    out="$(in_fleet_keeping_cache cmd_status 2>&1)"
    [ -e "$AUTOFLEET_DIR/ps-blind-42" ] \
      && fail "status created the ps-blind- latch; it is the dispatcher's said-once marker, and a watch loop consuming it means the dispatcher's own terminal never prints why the drain is unbounded: $out"
    after="$(state_bytes)"
    [ "$after" = "$before" ] \
      || fail "status changed \$STATE_DIR through the parked path. before=$before after=$after"
    echo "ok: ...and through the parked path, where the latch belongs to the poll"

    # ...and the same look with the states READABLE does not release the latch
    # either. That direction is the milder half -- the dispatcher re-says a line
    # it already said -- but it is still a write, and still `status`'s to leave
    # alone.
    build_exited
    : >"$AUTOFLEET_DIR/ps-blind-42"
    before="$(state_bytes)"
    out="$(in_fleet_keeping_cache cmd_status 2>&1)"
    [ -e "$AUTOFLEET_DIR/ps-blind-42" ] \
      || fail "status cleared the dispatcher's ps-blind- latch, so the next pass re-says a line the operator has already been told: $out"
    after="$(state_bytes)"
    [ "$after" = "$before" ] \
      || fail "status changed \$STATE_DIR clearing the latch. before=$before after=$after"
    echo "ok: ...and does not release it either"
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
    launched="$(sed -n 's/^.*is building in //p' "$WORK/run.log" | head -1)"
    [ -n "$launched" ] || fail "could not tell where the run opened its worktree: $(cat "$WORK/run.log")"
    reapable_worktree_at "$launched"
    echo '[{"number":9,"body":"Closes #148"}]' >"$GH_PRS"
    echo 9 >"$GH_MERGED"
    # THE REAP RUNS ON THE PASSES AFTER THE CAP, asserted before the exit rather
    # than inferred from it. #36's bullet asks for this by name; what shipped
    # asserted the run ENDS, which is a different property -- a cap that stopped
    # reaping as well as launching fails that assertion as a TIMEOUT, read as
    # "some other failure" rather than as the reap having stopped. The say at the
    # latch promises "still reaping what is in flight"; this is the line that
    # holds it to it. armaatus/autofleet#71.
    # `wait_for_log` calls `fail` itself, so it needs no `|| fail` here: the
    # absence of this line IS "the cap stopped reaping as well as launching".
    wait_for_log "is merged; marking it done"
    # `awk 'NR==1'`, NOT `head -1`: `head` exits on line one, `grep` dies of
    # EPIPE, and `set -o pipefail` makes the pipeline 141 -- on a long enough log
    # only, which is green on a Mac and red in CI. It is CLAUDE.md's `grep -q`
    # rule one construct over, and these were the only `head -1 |` in tests/.
    # Found by `/mattpocock-skills:code-review`.
    latched="$(grep -n "launching nothing more" "$WORK/run.log" | awk -F: 'NR==1{print $1}')"
    reaped="$(grep -n "is merged; marking it done" "$WORK/run.log" | awk -F: 'NR==1{print $1}')"
    [ -n "$latched" ] && [ "$reaped" -gt "$latched" ] \
      || fail "the reap ran before the cap latched the drain (latch line $latched, reap line $reaped), so this asserts nothing about the passes after it: $(cat "$WORK/run.log")"
    echo "ok: the reap still runs on the passes after the cap"
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
    # Its build has stopped and it is kept only because its PR is open -- which
    # is the state every worktree in a real drain is in.
    build_ran_out
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
    grep -q "build stop" "$WORK/build-calls" \
      && fail "a drain stopped a build, which is --now's job and not this one"
    echo "ok: a drain ends when the work in flight lands, not at a deadline"
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
    n="$(gate_count 2>&1)"
    [ "$n" = 1 ] \
      || fail "counted $n live worktree(s); another repo's worktree is taking a slot from MAX_WORKTREES"
    # SCOPED TO THE REPOSITORY, which the default driver gets from `git
    # worktree list` itself: another repo's worktrees are not in this repo's
    # listing, so the whole class of bug armaatus/autofleet#31 is about cannot
    # be reached by it. Asserted on the listing it ran, not on a selector it
    # passed -- the app-backed driver's `--repo path:` is the same claim in its
    # own vocabulary, and `create_scoped` pins that one.
    grep -q "worktree list -C $WORK/repo" "$ORCA_CALLS" \
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
    n="$(gate_count 2>&1)"
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
    use_orca_runner
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

  selector_relative_common)
    make_fixture ok
    use_orca_runner
    # THE RULE, not one way to break it. `--repo path:` needs an ABSOLUTE root,
    # and the guard used to be a denylist -- empty, or a leading dash -- which
    # reaches the fallback only because the local `dirname` happens to refuse
    # `--path-format=absolute`. A git that answers the common dir RELATIVELY --
    # which is what `--git-common-dir` prints without `--path-format`, the very
    # option the pre-2.31 case above is about not having -- makes `dirname`
    # answer `.`: non-empty, no leading dash, and `path:.` goes to the CLI,
    # which is the same permanent `repo_not_found` stall the selector exists to
    # prevent. Matching a leading slash states the requirement instead.
    # armaatus/autofleet#71.
    real_git="$(command -v git)"
    cat >"$WORK/bin/git" <<GITSTUB
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in --git-common-dir) printf '.git\n'; exit 0 ;; esac
done
exec "$real_git" "\$@"
GITSTUB
    chmod +x "$WORK/bin/git"
    sel="$( cd "$WORK/repo" && PATH="$WORK/bin:$PATH" bash -c '
      set -uo pipefail
      REPO_ROOT="$PWD"
      . ./scripts/fleet/lib.sh >/dev/null 2>&1
      orca_resolve_repo_selector
    ' 2>&1 )"
    [ "$sel" = "path:$WORK/repo" ] \
      || fail "a relative common dir became a selector the CLI refuses: [$sel]"
    echo "ok: a selector that is not an absolute root reaches the fallback"
    ;;

  create_scoped)
    make_fixture ok
    use_orca_runner
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
    # THE LISTING IS THE REPOSITORY'S, not the caller's. `fleet.sh status` is
    # run from wherever you are -- CLAUDE.md points agents in a fleet worktree
    # at it -- and a listing built from the CALLER's checkout answers for that
    # worktree alone. `in_flight` then reads "could not tell" for every issue,
    # and `status` offers work that is already running.
    worktree_list "42:wt"
    out="$(in_fleet_at "$WORK/wt2" cmd_status 2>&1)"
    grep -q "#42" <<<"$out" \
      || fail "asked from a worktree, it could not list what is running: the repo selector did not resolve: $out"
    echo "ok: status asked from a worktree still scopes to the repository"
    ;;

  # ------------------------------------------------- the per-pass budget ---
  # What one poll costs, asserted rather than re-derived by hand. The numbers in
  # docs/WORKFLOW.md's budget table are these. armaatus/autofleet#69.
  budget_idle_pass)
    # The ordinary state of a fleet whose slate is all claimed: every `ready`
    # issue already has a PR, so the launch loop scans the list to the end and
    # starts nothing. Before the per-poll PR listing this pass made 13 `gh`
    # calls -- one `pr list` per candidate scanned, plus two `issue list`, plus
    # `count_startable`'s own `pr list` -- and every one of those grew with the
    # backlog.
    make_fixture ok
    backlog_all_claimed 10
    out="$(in_fleet cmd_run --auto 2>&1)"
    grep -q "nothing startable left" <<<"$out" \
      || fail "the pass did not end on an empty slate, so what follows is not one pass: $out"
    gh="$(grep -c . "$GH_CALLS" || true)"
    [ "$gh" = 2 ] \
      || fail "one idle pass over 10 claimed \`ready\` issues made $gh \`gh\` calls, not 2: $(cat "$GH_CALLS")"
    echo "ok: one idle pass costs 2 gh calls"
    # ...and ONE worktree listing, which is #30's cache doing its job with
    # `in_flight` reading it too. One cache, one invalidation point: this
    # asserts the number, #30's own phases assert where it is dropped.
    wt="$(grep -c "^worktree list" "$ORCA_CALLS" || true)"
    [ "$wt" = 1 ] \
      || fail "one idle pass made $wt \`worktree list\` calls, not 1: $(grep "^worktree list" "$ORCA_CALLS")"
    echo "ok: ...and one worktree listing"
    ;;

  budget_scales)
    # THE SLOPE, which is the number that matters. The measured figures live in
    # docs/WORKFLOW.md, "What one poll costs", and are not restated here: this
    # file said 46 `ready` and 3000/hour while the docs said 53 and 3400, which
    # is two records of one measurement disagreeing about which day it was
    # taken. What this phase asserts is the SHAPE -- the same count at 10 and at
    # 50 -- which does not go stale when the backlog moves.
    make_fixture ok
    backlog_all_claimed 10
    out="$(in_fleet cmd_run --auto 2>&1)"
    grep -q "nothing startable left" <<<"$out" || fail "the 10-issue pass did not end: $out"
    ten="$(grep -c . "$GH_CALLS" || true)"
    make_fixture ok
    backlog_all_claimed 50
    out="$(in_fleet cmd_run --auto 2>&1)"
    grep -q "nothing startable left" <<<"$out" || fail "the 50-issue pass did not end: $out"
    fifty="$(grep -c . "$GH_CALLS" || true)"
    [ "$ten" = "$fifty" ] \
      || fail "a pass over 10 ready issues made $ten \`gh\` calls and one over 50 made $fifty: the cost still scales with the backlog"
    echo "ok: the gh calls a pass makes do not scale with the size of the backlog ($ten either way)"
    ;;

  budget_pr_list_once)
    # One listing, shared. Two issues asked about, one `gh pr list` -- and the
    # answers are still each issue's own.
    make_fixture ok
    backlog_all_claimed 3
    out="$(in_pass 'in_flight 2; echo "claimed=$?"; in_flight 9; echo "free=$?"' 2>&1)"
    grep -q "claimed=0" <<<"$out" || fail "an issue with an open PR read as free: $out"
    grep -q "free=1" <<<"$out" || fail "an issue with no PR did not read as free: $out"
    n="$(grep -c "pr list --state open --json number,body" "$GH_CALLS" || true)"
    [ "$n" = 1 ] || fail "two in_flight questions cost $n open-PR listings, not 1: $(cat "$GH_CALLS")"
    echo "ok: one open-PR listing answers every in_flight question in a pass"
    ;;

  budget_pr_list_blind)
    # A `gh` that could not answer at all. "Could not tell" is cached AS SUCH --
    # the second caller in the pass gets 2, not the 1 an empty cache file would
    # mean -- because reading it as "no PR" opens a second worktree for work
    # already in flight, which is the failure has_open_pr's third answer exists
    # to prevent. The same contract poll_issue's `.unreadable` already keeps.
    make_fixture ok
    backlog_all_claimed 3
    printf 'FAIL\n' >"$GH_PRS"
    out="$(in_pass 'in_flight 2; echo "first=$?"; in_flight 9; echo "second=$?"' 2>&1)"
    grep -q "first=2" <<<"$out" || fail "an unreadable PR listing did not answer 'could not tell': $out"
    grep -q "second=2" <<<"$out" \
      || fail "the cached failure came back as an answer rather than as 'could not tell': $out"
    n="$(grep -c "pr list --state open --json number,body" "$GH_CALLS" || true)"
    [ "$n" = 1 ] || fail "the failed listing was re-asked $n times in one pass: $(cat "$GH_CALLS")"
    echo "ok: a PR listing that could not be read is cached as 'could not tell', and asked once"
    # ...and the other shape of the same failure: `gh` exits 0 and hands back
    # something that is not a listing. python printing nothing is what "no PR"
    # looks like, so this one has to end at 2 as well.
    make_fixture ok
    backlog_all_claimed 3
    printf 'not a listing\n' >"$GH_PRS"
    out="$(in_pass 'in_flight 2; echo "first=$?"; in_flight 9; echo "second=$?"' 2>&1)"
    grep -q "first=2" <<<"$out" || fail "a malformed PR listing read as 'no PR': $out"
    grep -q "second=2" <<<"$out" || fail "a malformed PR listing read as 'no PR' on the second ask: $out"
    echo "ok: ...and so is one that came back malformed"
    # ...and the shape a length test alone cannot see: WELL-FORMED JSON that is
    # not a listing. An error envelope `gh` hands back with status 0 has a
    # `len()` like a list does, so the page-limit probe passed it through and it
    # was cached as an answer -- which each caller then rediscovered by throwing.
    make_fixture ok
    backlog_all_claimed 3
    printf '{"message":"Bad credentials"}\n' >"$GH_PRS"
    out="$(in_pass 'in_flight 2; echo "first=$?"; in_flight 9; echo "second=$?"' 2>&1)"
    grep -q "first=2" <<<"$out" || fail "a JSON object that is not a listing read as an answer: $out"
    grep -q "second=2" <<<"$out" || fail "...and was cached as one: $out"
    echo "ok: ...and so is well-formed JSON that is not a listing at all"
    ;;

  budget_launch_cost)
    # WHAT ONE LAUNCH ADDS, measured rather than re-derived -- the row in
    # docs/WORKFLOW.md's budget table is this number. In `--auto` the title and
    # labels come out of the `ready` listing the pass already has, so a launch
    # costs no `gh` call at all; what it costs is runner calls.
    make_fixture ok
    cat >"$GH_ISSUES" <<'JSON'
[{"number":4,"title":"an ordinary one","body":"","labels":[{"name":"ready"}]}]
JSON
    echo '[]' >"$GH_PRS"
    start_dispatcher --auto --max-prs 1
    wait_for_log "opened 1 worktree"
    stop_dispatcher
    grep -q "^worktree create" "$ORCA_CALLS" || fail "nothing was launched: $(cat "$WORK/run.log")"
    # No `gh issue view` for the title or the labels of what it picked.
    # `--json title`, NOT `issue view 4`: `poll_issue` asks `issue view 4 --json
    # state,labels` for the very same issue once `reap_abandoned` owns it, so the
    # looser pattern matched a call this phase is not about and failed whenever a
    # second pass started before `stop_dispatcher` landed -- at AUTOFLEET_POLL=1,
    # a margin of under a second. Found by the local review.
    n="$(grep -c -- "--json title" "$GH_CALLS" || true)"
    [ "$n" = 0 ] \
      || fail "a launch in --auto still spent $n \`gh issue view --json title\` calls on an issue the ready listing already described: $(cat "$GH_CALLS")"
    echo "ok: a launch in --auto costs no gh call of its own"
    ;;

  budget_pr_page_speaks)
    # THE CLIFF SAYS SO. Refusing a listing at its page limit is right, and
    # refusing it in silence is the worst property a stop can have: nothing
    # launches, nothing is time-boxed, no build context is reset, and the run
    # loop polls forever, with not one line in the log to read in the morning.
    # Once per outage, through hold_say_into, not once a minute.
    make_fixture ok
    backlog_all_claimed 100
    out="$(in_pass 'in_flight 2; in_flight 3' 2>&1)"
    grep -q "page limit" <<<"$out" \
      || fail "the dispatcher refused every issue for the rest of the run and said nothing: $out"
    [ "$(grep -c "page limit" <<<"$out")" = 1 ] \
      || fail "it said it once per caller rather than once per outage: $out"
    echo "ok: a PR listing at its page limit says so, once"
    # ...and nothing at all when the listing is whole.
    make_fixture ok
    backlog_all_claimed 99
    out="$(in_pass 'in_flight 2' 2>&1)"
    grep -q "page limit" <<<"$out" && fail "it warned about a listing that was not truncated: $out"
    echo "ok: ...and stays quiet when it is not"
    # ...and says it AGAIN when the wedge recurs, rather than inheriting an
    # hour-old marker from the last one. A say-once marker that outlives its
    # condition is a stop nobody is told about twice.
    make_fixture ok
    backlog_all_claimed 100
    out="$(in_pass 'in_flight 2' 2>&1)"
    grep -q "page limit" <<<"$out" || fail "the first wedge said nothing: $out"
    backlog_all_claimed 99
    in_pass 'in_flight 2' >/dev/null 2>&1
    backlog_all_claimed 100
    out="$(in_pass 'in_flight 2' 2>&1)"
    grep -q "page limit" <<<"$out" \
      || fail "a wedge that cleared and came back inside the hour was never mentioned: $out"
    echo "ok: ...and says it again when the wedge clears and recurs"
    ;;

  budget_status_says_blind)
    # `fleet.sh status` is what a person runs when nothing is launching, and at
    # the page limit it was the most misleading thing in the tree: `in_flight`
    # answers 2, the next-up loop reads 2 as "not running", and every `ready`
    # issue printed as startable beside a dispatcher that would start none of
    # them. Found by the local review.
    # A FULL PAGE IS NO LONGER A REFUSAL (armaatus/autofleet#151 folds
    # armaatus/autofleet#122). It used to blank the listing, so `in_flight`
    # answered 2 for every issue and `status` printed every `ready` issue as
    # startable beside a dispatcher that would start none of them. The page is
    # used now, so the claims here are the opposite ones: the queue it prints is
    # the real one, and every issue on that page reads as claimed.
    make_fixture ok
    backlog_all_claimed 100
    out="$(in_fleet cmd_status 2>&1)"
    grep -q "could not be read" <<<"$out" \
      && fail "status still refuses a listing at the page limit, which is the stop #151 removed: $out"
    grep -qE "^ +1 " <<<"$out" \
      && fail "an issue whose PR is on the page it read was still offered as startable: $out"
    echo "ok: status reads a full page rather than refusing it"
    # ...and the same is true well under the limit, so this is not a property of
    # the number 100.
    make_fixture ok
    backlog_all_claimed 3
    out="$(in_fleet cmd_status 2>&1)"
    grep -q "could not be read" <<<"$out" && fail "status warned about a listing it read fine: $out"
    echo "ok: ...and stays quiet when it could"
    ;;

  budget_pass_signal)
    # $AUTOFLEET_LOG_PASSES itself: off by default, because a line a minute is
    # the log volume every say-once marker in fleet.sh exists to prevent.
    # armaatus/autofleet#69 Design note 7.
    make_fixture ok
    backlog_all_claimed 10
    out="$(in_fleet cmd_run --auto 2>&1)"
    grep -q "pass complete" <<<"$out" \
      && fail "the dispatcher logged a line per pass without being asked: $out"
    echo "ok: the per-pass line is off by default"
    make_fixture ok
    backlog_all_claimed 10
    out="$(AUTOFLEET_LOG_PASSES=on in_fleet cmd_run --auto 2>&1)"
    grep -q "pass complete" <<<"$out" \
      || fail "AUTOFLEET_LOG_PASSES=on said nothing: $out"
    # ...AFTER the last call a pass makes, which is what makes it usable as the
    # end-of-pass signal budget_busy_pass waits on rather than a clock.
    [ "$(grep -c . "$GH_CALLS")" = 2 ] \
      || fail "the pass line landed before the pass was done: $(cat "$GH_CALLS")"
    echo "ok: ...and on, it says so once the pass has spent everything it spends"

    # ...and `0` is REFUSED rather than read as either. The first shape of this
    # knob was `[ -n ]`, so `AUTOFLEET_LOG_PASSES=0` -- the one thing a host
    # writes when it means off -- turned the line a minute ON, with nothing said
    # about it. AUTOFLEET_CONTEXT_RESET's validator is the shape copied here.
    # Found by the local review.
    cfg_out="$( (cd "$WORK/repo" \
      && AUTOFLEET_LOG_PASSES=0 bash -c '. ./scripts/fleet/config.sh') 2>&1 )"
    cfg_rc=$?
    [ "$cfg_rc" = 2 ] \
      || fail "AUTOFLEET_LOG_PASSES=0 was accepted (rc=$cfg_rc): $cfg_out"
    grep -q "must be 'on' or 'off'" <<<"$cfg_out" \
      || fail "it was refused without saying why: $cfg_out"
    echo "ok: ...and a value that is neither on nor off is refused, not read as on"
    ;;

  budget_status_says_backlog_blind)
    # The OTHER listing's failure, which had neither a caveat nor a phase. A
    # `gh` outage printed an empty `next up` table under a header that had
    # already gone out, and an empty table reads as "the backlog is finished" --
    # the one wrong conclusion this block exists to prevent. Found by the local
    # review.
    make_fixture ok
    printf 'FAIL\n' >"$GH_ISSUES"
    out="$(in_fleet cmd_status 2>&1)"
    grep -q "not because the backlog is finished" <<<"$out" \
      || fail "an unreadable issue listing printed as an empty queue: $out"
    echo "ok: status says an empty next-up table is an outage, not an empty backlog"
    ;;

  budget_status_one_listing)
    # ...and it costs ONE open-PR listing, not one per row. Outside a poll there
    # is no $POLL_CACHE to read -- that gate is #35's -- so every `in_flight` in
    # the next-up loop went to `gh` afresh: ~54 calls for one screen against this
    # repository's own queue, which is the slope #69 removed from the dispatcher
    # left standing in the command a person types. Found by the local review.
    make_fixture ok
    backlog_all_claimed 10
    # Nothing claimed, so every row survives `in_flight` and the loop runs to the
    # end -- which is the shape that made this expensive.
    echo '[]' >"$GH_PRS"
    in_fleet cmd_status >/dev/null 2>&1
    n="$(grep -c -- "pr list --state open --json number,body" "$GH_CALLS" || true)"
    [ "$n" = 1 ] \
      || fail "one status screen over 10 ready issues took $n open-PR listings, not 1: $(cat "$GH_CALLS")"
    echo "ok: one status screen costs one open-PR listing, whatever the queue holds"
    # ...and it still writes nothing, which is what keeps that memo a variable
    # rather than a fourth cache file. #35.
    [ -e "$AUTOFLEET_DIR/poll-cache/open-prs" ] \
      && fail "status wrote the poll cache; the out-of-poll memo must not be a file"
    echo "ok: ...and leaves the poll cache alone"
    ;;

  budget_ready_blind_speaks)
    # A `ready` listing that could not be read has to SAY so. Its two siblings
    # both do. This one cached the failure in silence, so a persistent outage --
    # expired auth, a broken $ISSUE_REFS -- left the dispatcher polling forever,
    # launching nothing, with nothing in the log at all. Silencing the python's
    # traceback made that worse: the traceback was ugly and it was also the only
    # signal. Found by the local review.
    make_fixture ok
    printf 'FAIL\n' >"$GH_ISSUES"
    # TWICE IN ONE PASS, which is what makes the second assertion an assertion.
    # Called once the count can only be 1 or 0, so "it said so more than once"
    # was unreachable and the say-once marker went untested -- the same shape
    # `budget_ready_list_blind` uses to prove the cached failure is not re-asked.
    # Found by the local review.
    out="$(in_pass 'ready_issues; ready_issues' 2>&1)"
    grep -q "could not read the issue listing" <<<"$out" \
      || fail "the dispatcher stopped starting anything and said nothing: $out"
    [ "$(grep -c "could not read the issue listing" <<<"$out")" = 1 ] \
      || fail "it said so more than once in one pass: $out"
    echo "ok: an unreadable ready listing says so, once"
    # ...and nothing when it reads fine.
    make_fixture ok
    backlog_all_claimed 3
    out="$(in_pass 'ready_issues' 2>&1)"
    grep -q "could not read the issue listing" <<<"$out" \
      && fail "it warned about a listing it read fine: $out"
    echo "ok: ...and stays quiet when it could read it"
    ;;

  budget_status_keeps_said)
    # ...and it still writes NOTHING. #35's acceptance is that `status` leaves
    # $STATE_DIR byte-identical, and the say-once marker's removal is a write:
    # ungated, a `status` run beside a wedged dispatcher deleted the marker and
    # the dispatcher said its lines again on the next poll. The same class of
    # bug as the IN_POLL gate on the cache itself. Found by the local review.
    make_fixture ok
    backlog_all_claimed 3
    mkdir -p "$AUTOFLEET_DIR"
    printf '100' >"$AUTOFLEET_DIR/pr-page-full"
    before="$(cat "$AUTOFLEET_DIR/pr-page-full")"
    in_fleet_keeping_cache cmd_status >/dev/null 2>&1
    [ -e "$AUTOFLEET_DIR/pr-page-full" ] \
      || fail "status deleted a live dispatcher's say-once marker, so it will repeat itself next poll"
    [ "$(cat "$AUTOFLEET_DIR/pr-page-full")" = "$before" ] \
      || fail "status rewrote the say-once marker"
    echo "ok: status does not drop the page-limit marker a dispatcher is holding"
    # ...nor the OTHER say-once marker, which shipped a round later without the
    # gate its sibling had. Two markers, one rule, and only one of them was
    # covered.
    printf 'ready' >"$AUTOFLEET_DIR/ready-unreadable"
    in_fleet_keeping_cache cmd_status >/dev/null 2>&1
    [ -e "$AUTOFLEET_DIR/ready-unreadable" ] \
      || fail "status deleted the ready-listing say-once marker, so the dispatcher will repeat itself next poll"
    echo "ok: ...nor the ready-listing one"
    ;;

  budget_busy_pass)
    # THE OTHER ROW OF docs/WORKFLOW.md's table. The section claims the `budget_`
    # phases assert its numbers; without this one it asserted the idle row and
    # the launch row and left the busy figure to drift. Three owned worktrees,
    # three open PRs, review mode `github`: the two shared listings, and four
    # calls per worktree. Found by the local review.
    #
    # THE NUMBER WAS 8 AND IS 14, and the difference is the fixture rather than
    # the code. All three owned issues used to name ONE directory, so the three
    # per-worktree calls that key on the branch collapsed into one answer. A
    # real fleet has three branches, and always paid this.
    make_fixture ok
    backlog_all_claimed 10
    : >"$GH_MERGED"
    # THREE WORKTREES MEANS THREE PATHS. The listing was fabricated text before
    # armaatus/autofleet#151 and three rows could name one directory; it is
    # `git worktree list` now, and one directory is one worktree however many
    # issues claim it.
    worktree_list 1:wt1 2:wt2 3:wt3
    mkdir -p "$AUTOFLEET_DIR/worktrees"
    for n in 1 2 3; do
      printf '%s\n' "$WORK/wt$n" >"$AUTOFLEET_DIR/worktrees/$n"
      # Each build has finished, which is the steady state a full fleet spends
      # most of its life in.
      build_state_for "$n" "$WORK/wt$n" 0
    done
    # A TOTAL, the way budget_idle_pass asserts the idle row -- `>= 3` of each
    # kind would have let the 8 drift, which is the one thing this phase exists
    # to stop. A total needs ONE pass and no second one racing it, so the poll is
    # slowed right down: the fixture's default of 1s is what makes every other
    # phase here cheap and is exactly wrong for this one.
    #
    # ASKED, not guessed. Three rounds of review went into tightening a quiet
    # window -- 0.5s, then 2s -- that was always a wall-clock stand-in for one
    # question: has the pass finished? Nothing guarantees two `gh` stub calls
    # inside a pass are closer together than any chosen window; between them a
    # pass forks `python3`, the runner stub and, because this fixture points
    # `reap_merged` at a real repository, `git` three times. Under the parallel
    # worktrees this repo runs at, a slow gap mid-pass broke the wait early and
    # failed the phase with a drift report about a partial count.
    #
    # $AUTOFLEET_LOG_PASSES makes the dispatcher say so instead, once per pass,
    # after `count_startable` -- which is the last call any pass makes. That is
    # armaatus/autofleet#69's own Design note 7 ("count it, so this is not
    # re-derived by hand") in the smallest form that answers this. The five
    # minute poll stays as the second guarantee: even if the line were missed,
    # no second pass exists to contaminate the count.
    AUTOFLEET_POLL=300 AUTOFLEET_LOG_PASSES=on start_dispatcher --auto
    wait_for_log "pass complete"
    # The count is taken AFTER that line, which the dispatcher writes once
    # `count_startable` -- the last call of a pass -- has returned. The five
    # minute poll above is the second guarantee: no next pass can be underway
    # while this reads $GH_CALLS.
    n="$(grep -c . "$GH_CALLS" 2>/dev/null || true)"
    stop_dispatcher
    [ "$n" = 14 ] \
      || fail "a full fleet of three worktrees cost $n \`gh\` calls in one pass, not 14: $(cat "$GH_CALLS")"
    # ...and a whole number of passes, which a count taken mid-pass would not be.
    # Belt to the pass line's braces, and the thing that would say so if the
    # signal were ever emitted before the last call of a pass rather than after.
    [ $(( n % 14 )) = 0 ] \
      || fail "the count was taken mid-pass ($n is not a whole number of 14s): $(cat "$GH_CALLS")"
    echo "ok: a full fleet of three worktrees costs 14 gh calls a pass"
    ;;

  budget_list_mode_no_listing)
    # THE PREFETCH'S OWN CONDITION, which is the half hard rule 3 would
    # otherwise have shipped unasserted. Named for LIST MODE and not for a full
    # fleet, because list mode is the whole of what it covers: with every slot
    # full the launch loop never runs, and in list mode `count_startable` is
    # unreachable too (`queued` comes from `wanted`), so NOTHING in the pass
    # reads the listing. In `--auto` `count_startable` takes it anyway, which is
    # why docs/WORKFLOW.md's busy row counts it -- an earlier name for this
    # phase said "full fleet" and would have had a maintainer believe otherwise.
    # Drop `[ "$live" -lt "$MAX_WORKTREES" ]` and this fixture pays one `gh` call
    # a minute for a whole time-box. Found by the local review.
    make_fixture ok
    : >"$GH_MERGED"
    worktree_list 1:wt1 2:wt2 3:wt3
    start_dispatcher 42
    i=0
    while [ "$i" -lt 200 ] && [ "$(grep -c "^worktree list" "$ORCA_CALLS" || true)" -lt 2 ]; do
      sleep 0.1; i=$((i + 1))
    done
    stop_dispatcher
    [ "$(grep -c "^worktree list" "$ORCA_CALLS" || true)" -ge 2 ] \
      || fail "no pass completed: $(cat "$WORK/run.log")"
    n="$(grep -c -- "pr list --state open --json number,body" "$GH_CALLS" || true)"
    [ "$n" = 0 ] \
      || fail "a full fleet took $n open-PR listings for a launch loop that never runs: $(cat "$GH_CALLS")"
    echo "ok: a pass that cannot launch does not pay for the listing that would tell it what to launch"
    ;;

  budget_drain_no_listing)
    # ...and the drain half of the same condition. A drain launches nothing and
    # forces `queued` to 0, so the listing answers nothing there either -- and a
    # drain waiting on three PRs to merge can last hours.
    make_fixture ok
    backlog_all_claimed 10
    # `--until 1`, an epoch already past. `deadline_from` takes `Nh`, `Nm`,
    # `HH:MM` or a bare epoch, and `HH:MM` in the past rolls forward a day --
    # so a bare epoch is the only spelling that is reliably behind us.
    out="$(in_fleet cmd_run --auto --until 1 2>&1)"
    grep -q "deadline passed" <<<"$out" || fail "the run did not enter a drain: $out"
    n="$(grep -c -- "pr list --state open --json number,body" "$GH_CALLS" || true)"
    [ "$n" = 0 ] || fail "a draining pass took $n open-PR listings it had no reader for: $(cat "$GH_CALLS")"
    echo "ok: a draining pass does not pay for the listing either"
    ;;

  budget_ready_list_blind)
    # The `ready` listing's half of the same contract. A `gh` that could not
    # answer must not come back as an empty queue: `count_startable` reading one
    # answers 0, and `queued == 0` with nothing owned is how `cmd_run` decides
    # the backlog is finished and exits. One blip would end an overnight run.
    make_fixture ok
    printf 'FAIL\n' >"$GH_ISSUES"
    out="$(in_pass 'ready_issues; echo "first=$?"; ready_issues; echo "second=$?"' 2>&1)"
    grep -q "first=1" <<<"$out" || fail "an unreadable issue listing did not fail: $out"
    grep -q "second=1" <<<"$out" \
      || fail "the cached failure came back as an empty backlog rather than as a failure: $out"
    n="$(grep -c "issue list --state open" "$GH_CALLS" || true)"
    [ "$n" = 1 ] || fail "the failed issue listing was re-asked $n times in one pass: $(cat "$GH_CALLS")"
    echo "ok: a ready listing that could not be read fails, is cached as a failure, and is asked once"
    # ...and the run loop keeps polling on it rather than deciding the queue is
    # empty. count_startable's documented non-zero is what carries that.
    out="$(in_pass 'count_startable; echo "rc=$?"' 2>&1)"
    grep -q "rc=1" <<<"$out" || fail "count_startable answered a number from a listing it could not read: $out"
    echo "ok: ...and count_startable refuses to answer a number from it"
    # ...and it does it QUIETLY. `gh`'s stderr was silenced and python's was not,
    # so the JSONDecodeError this path relies on for its non-zero also put a raw
    # traceback in $LOG once a poll, for as long as the outage lasted -- which is
    # the log a person scans in the morning.
    grep -qi "Traceback" <<<"$out" \
      && fail "a gh outage put a python traceback in the dispatcher's log: $out"
    echo "ok: ...and without a traceback in the log"
    # A body that PARSES and is not a listing is the other shape. `{}` iterates
    # no keys, prints nothing, and exits 0 -- so it cached as "the backlog is
    # empty", which is how cmd_run decides there is no work left and stops for
    # the night.
    make_fixture ok
    printf '{}\n' >"$GH_ISSUES"
    out="$(in_pass 'ready_issues; echo "rc=$?"' 2>&1)"
    grep -q "rc=1" <<<"$out" \
      || fail "a JSON object that is not an issue listing read as an empty backlog: $out"
    grep -qi "Traceback" <<<"$out" && fail "...and said so with a traceback: $out"
    echo "ok: ...and well-formed JSON that is not a listing is not an empty backlog"
    ;;

  budget_ready_list_once)
    # An empty backlog is an ANSWER and caches as one -- `-e`, not `-s`. Two
    # readers, one `gh issue list`, and the second still gets the empty answer
    # rather than a second call.
    make_fixture ok
    echo '[]' >"$GH_ISSUES"
    out="$(in_pass 'ready_issues; echo "first=$?"; ready_issues; echo "second=$?"' 2>&1)"
    grep -q "first=0" <<<"$out" || fail "an empty backlog did not read as an answer: $out"
    grep -q "second=0" <<<"$out" || fail "the cached empty backlog did not read as an answer: $out"
    n="$(grep -c "issue list --state open" "$GH_CALLS" || true)"
    [ "$n" = 1 ] || fail "an empty backlog was asked for $n times in one pass: $(cat "$GH_CALLS")"
    echo "ok: an empty ready listing is an answer, cached as one, asked once"
    # ...and a real queue still round-trips whole, last record included. `$(...)`
    # eats the trailing newline, and without `print_listing` putting it back the
    # launch loop's `read` drops the last candidate -- so a one-issue backlog
    # would never start at all.
    make_fixture ok
    backlog_all_claimed 1
    out="$(in_pass 'ready_issues | wc -l; ready_issues | wc -l' 2>&1 | tr -d " ")"
    [ "$out" = "$(printf '1\n1')" ] \
      || fail "a one-issue ready listing did not survive the cache as one whole record: $out"
    echo "ok: ...and a one-issue queue survives the cache with its last record intact"
    ;;

  budget_pr_list_truncated)
    # A FULL PAGE IS USED, which is armaatus/autofleet#122 folded into
    # armaatus/autofleet#151. It used to answer "could not tell" for every issue
    # -- the safe direction, at the price of the whole dispatcher: nothing
    # launched, nothing was time-boxed, and the run loop polled forever on a
    # repository whose only sin was 100 open pull requests. What it can still
    # get wrong is bounded: an issue whose PR is past the page boundary reads as
    # free and gets a second worktree, which `reap_merged`'s `Closes #N` sweep
    # finds within a pass.
    make_fixture ok
    backlog_all_claimed 100
    out="$(in_pass 'in_flight 2; echo "rc=$?"' 2>&1)"
    grep -q "rc=0" <<<"$out" \
      || fail "a PR listing at the page limit was refused, which is the stop that made a busy repository unusable: $out"
    echo "ok: an open-PR listing at its page limit is read rather than refused"
    # One short of the limit is a whole listing and still answers.
    make_fixture ok
    backlog_all_claimed 99
    out="$(in_pass 'in_flight 2; echo "rc=$?"' 2>&1)"
    grep -q "rc=0" <<<"$out" || fail "a listing one short of the page limit stopped answering: $out"
    echo "ok: ...and one short of it still does"
    ;;

  budget_listing_before_launch)
    # THE LINE THE WINDOW RESTS ON. `open_pr_listing`'s header says the listing
    # is taken no later than the line before the launch loop, because the launch
    # loop is the one reader that acts on the answer by opening a worktree.
    # Nothing else in the suite can tell: delete the prefetch and the counts stay
    # at 2, because the loop's first `in_flight` fetches lazily instead. The
    # ORDER is what changes -- lazily, `ready_issues` gets there first -- so the
    # order is what this asserts. Hard rule 3: a guard with no assertion is not
    # shipped. Found by the local review.
    make_fixture ok
    backlog_all_claimed 10
    out="$(in_fleet cmd_run --auto 2>&1)"
    grep -q "nothing startable left" <<<"$out" || fail "the pass did not end: $out"
    first="$(head -1 "$GH_CALLS")"
    case "$first" in
      "pr list --state open --json number,body"*) : ;;
      *) fail "the pass's first gh call was '$first', not the open-PR listing: the launch loop got there first, and the window named at the cache is no longer the one the code takes" ;;
    esac
    echo "ok: the pass takes its open-PR listing before the launch loop scans anything"
    ;;

  budget_pr_list_fresh_per_pass)
    # The cache is the POLL's. A PR opened between passes is seen on the next
    # one -- the window named at the cache is one poll wide, not the run's life.
    make_fixture ok
    backlog_all_claimed 1
    out="$(in_pass 'in_flight 9; echo "before=$?"' 2>&1)"
    grep -q "before=1" <<<"$out" || fail "#9 was not free to start with: $out"
    backlog_all_claimed 9
    out="$(in_pass 'in_flight 9; echo "after=$?"' 2>&1)"
    grep -q "after=0" <<<"$out" \
      || fail "a PR opened between passes was still invisible on the next one: $out"
    echo "ok: the open-PR listing is re-read every pass"
    ;;

  *)
    # NOT A SECOND REGISTRY. This used to spell out every phase, and it was
    # already ten names behind `tests/run.sh` before this change added five more
    # -- a list nothing reads and nothing checks. The fleet row of SUITES in
    # tests/run.sh is the registry `evals/lint.sh` asserts against, so that is
    # where a reader is sent. Found by `/mattpocock-skills:code-review`, which
    # reported the drift; the copy is the reason for the drift.
    echo "usage: tests/test_fleet.sh <phase>" >&2
    echo "  the phases are the \`fleet:\` row of SUITES in tests/run.sh --" >&2
    echo "  one registry, which is what evals/lint.sh checks against." >&2
    exit 2 ;;
esac
