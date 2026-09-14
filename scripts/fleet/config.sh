#!/usr/bin/env bash
# The knobs a host project sets, and their defaults. Sourced by lib.sh, never
# executed -- but not therefore harmless: the validation at the foot of this file
# `exit`s on a knob it cannot accept, and in a sourced file that ends the
# SOURCING shell. A bad value in `.autofleet/config` is fatal to every fleet
# command, `stop.sh` included. Deliberate, and argued where the check is.
#
# autofleet ships no knowledge of any one project. Everything it needs to know
# about the repo it is driving -- what a worktree has to provision, which labels
# gate the work, what a stack is called -- arrives through this file and through
# `.autofleet/config` in the host repo, which is read after the defaults below
# and can override any of them.
#
# Environment beats the config file, which beats these defaults, so a one-off
# `AUTOFLEET_MAX=1 ./scripts/fleet/fleet.sh run --auto` still works.

# ---------------------------------------------------------------- dispatcher
# How many worktrees run at once. Three is the number rommsync-nx settled on:
# enough parallelism to matter, few enough that a human can still read what
# happened.
: "${AUTOFLEET_MAX:=3}"
# How often the dispatcher re-reads the world, in seconds.
: "${AUTOFLEET_POLL:=60}"
# How long one issue may hold a worktree before the dispatcher gives it up, in
# seconds. Long enough for a real issue including a full test run and both
# review rounds.
: "${AUTOFLEET_TIMEBOX:=10800}"
# How long a worktree removal may take before it is reported as refused.
: "${AUTOFLEET_RM_DEADLINE:=180}"

# ---------------------------------------------------------------- the labels
# The convention `unblock.yml` maintains and `fleet.sh` reads.
#
# RENAMING WORKS FOR THREE OF THESE, and the doc says which. `AUTOFLEET_READY_LABEL`
# is read by nothing -- `ready_issues` fetches every open issue and then filters
# on the LITERAL word in its Python block, never passing `gh` a `--label` -- so
# renaming it hands you an empty queue forever, with nothing on screen saying
# why. armaatus/autofleet#57. That sentence lives in docs/CONFIGURATION.md, and
# this is the file somebody actually has open while renaming, so it says it too.
# Found by the independent review, which pointed out the invitation was here and
# the warning was one file away.
: "${AUTOFLEET_READY_LABEL:=ready}"
: "${AUTOFLEET_BLOCKED_LABEL:=blocked}"
# An issue that defines an interface later issues include: it lands alone.
: "${AUTOFLEET_FOUNDATION_LABEL:=foundation}"
# An issue whose last step is a person's. The fleet opens no worktree for it.
: "${AUTOFLEET_HUMAN_STEP_LABEL:=needs-human-step}"
# Work that goes before the queue's own ordering. The only one of these labels
# that says WHEN rather than WHAT: the other four are properties of the issue
# (two of them derived by `unblock.yml`, two applied by a person), and this one
# is a property of the week. It moves an issue to the FRONT of the ready list and
# does nothing else -- it cannot start a blocked issue, cannot start a
# `needs-human-step` one, and does not lift a foundation hold.
: "${AUTOFLEET_PRIORITY_LABEL:=priority}"

# ---------------------------------------------------------------- the runner
# Which driver creates worktrees and terminals. `orca` is the only one that
# ships today; see fleet/runner/README.md for the contract a second one has to
# meet.
: "${AUTOFLEET_RUNNER:=orca}"

# ---------------------------------------------------------------- the review
# Where the INDEPENDENT review runs -- the second opinion on the PR, from a
# context that has not seen the conversation which produced the diff. The local
# `/code-review` pass before the push is required in both modes and is not
# affected by this.
#
#   github  .github/workflows/claude-review.yml submits it, from its own
#           account. Needs a CLAUDE_CODE_OAUTH_TOKEN secret on the repository
#           (`claude setup-token`). Without that secret the job no-ops and every
#           PR blocks forever on a review that cannot arrive -- which is the
#           whole reason the other mode exists.
#   local   the DISPATCHER runs the reviewer on this machine
#           (`scripts/fleet/review.sh`) and it submits as whoever `gh` is logged
#           in as -- usually the same account that opened the PR. Independence
#           becomes context-level rather than identity-level. That is weaker;
#           docs/CONFIGURATION.md says exactly how, and `merge_gate.py` reads
#           this knob from the BASE ref so a PR cannot turn it on for itself.
#
# `merge_gate.py` parses this out of `.autofleet/config` with a regex rather
# than sourcing it, so keep the assignment on one line.
: "${AUTOFLEET_REVIEW_MODE:=github}"
# What `review.sh` runs to produce that review. A command on PATH, invoked with
# `-p` and a fixed tool allowlist. Named rather than hardcoded so a project can
# point it at a wrapper -- a different model, a different account, a `ssh` to
# the machine that holds the subscription.
: "${AUTOFLEET_REVIEW_CMD:=claude}"
# How long one local review may run before it is killed and the PR left for the
# next poll to pick up. Long enough for a real diff; short enough that a wedged
# reviewer is not an overnight hold on the worktree waiting for it.
: "${AUTOFLEET_REVIEW_TIMEOUT:=1800}"
# The reviewer's turn budget, passed through as `--max-turns`. The wall clock
# above is the backstop for a wedged process; this is the bound the reviewer can
# see and spend against, which is what makes "submit before you run out" in
# .claude/agents/reviewer.md a budget rather than a hope. 80 is what
# claude-review.yml grants.
: "${AUTOFLEET_REVIEW_MAX_TURNS:=80}"
# How many attempts one head may get that produce NO VERDICT.
#
# A reviewer that runs and submits nothing is retried, because that is usually
# transient -- and unbounded, it is a full-budget reviewer started every poll
# against a head that will never get a verdict, until the agent pushes or its
# three-hour time-box expires. `claude-review.yml` bounds the same case at ONE
# more attempt per head and then leaves a comment saying a person decides. This
# is that bound.
: "${AUTOFLEET_REVIEW_MAX_TRIES:=3}"
# Validated, because of how a bad value fails. The only consumer is
# `[ "${tries_n:-0}" -ge "$AUTOFLEET_REVIEW_MAX_TRIES" ]` in fleet.sh: with a
# non-number, `[` prints "integer expression expected" and returns 2, so the
# test is FALSE, the cap never fires, and the unbounded full-budget-reviewer-
# every-poll behaviour this knob exists to bound is back -- silently, apart from
# one stderr line per poll. `fleet.sh` runs without `-e`, so nothing stops.
#
# 0 is rejected separately: it reads as "never review", and the gave-up line
# would announce "0 reviewers on <sha> submitted nothing, which is the cap",
# which is not true of any run. A knob whose bad value turns a guard OFF has to
# refuse the value; this is the same reasoning tests/run.sh applies to
# AUTOFLEET_TEST_TIMEOUT, which had the check this one only had the argument
# for. Found by the independent review.
#
# The check itself is at the BOTTOM of this file, after `.autofleet/config` is
# sourced. Here it could only ever see the environment route: the host config is
# read last so it can override these defaults, so a project writing
# `AUTOFLEET_REVIEW_MAX_TRIES=three` into the file this table documents reached
# the cap unchecked and the guard was decorative for the one route that matters.

# How many reviews one PULL REQUEST may accrue before a person is asked.
#
# A different question from the one above, and nothing was answering it. That
# cap is per HEAD and counts only reviewers that submitted NOTHING -- a reviewer
# that submits findings clears it, so a PR whose every round produces findings
# is bounded by nothing at all. `AWAIT_REVIEW_MAX_ROUNDS` bounds the agent's
# side, but only while the agent is alive and only on rounds it read back:
# measured at 3 against 4 real reviews on #85, 2 against 4 on #86, 1 against 3
# on #88. #85's agent stopped at its cap and a fourth review landed with nobody
# left to answer it.
#
# So this bounds the DISPATCHER: after this many reviews on one PR, it stops
# starting them and says so. Four rather than three, because it must not fire
# before the agent's own three-round cap has had its say -- two caps at the same
# number is one of them being dead code.
: "${AUTOFLEET_REVIEW_MAX_ROUNDS:=4}"
# ABOVE the `.autofleet/config` source, like every other default here. Placed
# below it once, in the same change that added it, and the empty-value refusal
# became unreachable: the host file sets `KNOB=`, then a `:=` running afterwards
# substitutes the default, and the check the tests drive through that file has
# nothing left to refuse. Green here, dead for the one route that matters --
# the same failure this knob's neighbour records two comments up.
#
# The check itself is at the BOTTOM, with its neighbour's, for that reason.

# Found by the independent review of the change that added it.

# What a round-N reviewer is asked to read: `full` (the whole branch, every
# round) or `delta` (what changed since the last reviewed head, plus what that
# reaches).
#
# DEFAULTS TO `full`, and that is not timidity. `review.sh` inlines
# `.claude/agents/reviewer.md` verbatim as the reviewer's brief, and that file
# is under `.claude/`, which `merge_gate.HUMAN_ONLY_PREFIXES` refuses to let an
# agent merge. So the machinery here can land before the brief does, and a
# `review.sh` that started handing out ranges while the brief still said
# "`gh pr diff <N>`" would produce a reviewer that read the whole diff anyway:
# no saving, and a confused reviewer. The default flips in a one-line follow-up
# once the brief knows what a range is. armaatus/autofleet#65.
: "${AUTOFLEET_REVIEW_SCOPE:=full}"
# ...and every Kth round is `full` regardless, so no pull request is ever judged
# by an unbroken chain of deltas.
#
# The risk a delta review carries is that `git diff <last>..<head>` shows lines,
# not reachability: a round-five commit that changes a helper's exit convention
# shows three changed lines, and the caller it breaks was reviewed in round one
# and is not in the delta at all. The brief buys most of that back by requiring
# the touched files whole plus a grep for the callers of anything whose contract
# moved -- and this is the backstop for what those two clauses miss. 4 means at
# most three consecutive deltas.
: "${AUTOFLEET_REVIEW_FULL_EVERY:=4}"
# The byte ceiling on the carried-forward context file a delta round is handed.
#
# The file holds the previous round's findings, how they were answered, the
# unresolved threads and the commits between the two heads -- all of it text
# somebody else wrote on a pull request, and all of it unbounded in principle.
# The whole point of this issue is a prompt that does not grow with the rounds,
# so the file that replaces the growth needs a cap of its own or it becomes the
# growth. 16K is about seven times the largest reviewer body PR #32 ever
# produced (2,320 bytes).
: "${AUTOFLEET_REVIEW_CONTEXT_MAX:=16384}"
# ------------------------------------------------------------- what is KEPT ---
#
# Every store under $FLEET_DIR only ever grew. On this machine the reviewer
# transcripts reached 184K across 46 files in under two days, 65% of them
# belonging to pull requests that had already merged, and `fleet.log` grew
# without rotation. None of it is read again: a transcript matters while its
# review is being answered, and a merged PR's never is.
#
# A cap stops a thing getting worse; only deletion makes it smaller. These are
# the two numbers that decide what goes. Set either to 0 to keep everything,
# which is what a host project debugging its own reviewer wants.

# Reviewer transcripts to keep PER OPEN pull request. Older ones for that PR go,
# and every transcript for a PR that is no longer open goes -- after one grace
# pass, and never while a reviewer for that PR is still writing to it.
#
# This also governs the `reviewed-<sha>` sweep, so 0 really does mean "keep
# every piece of review state", which is what the line below promises.
: "${AUTOFLEET_KEEP_REVIEWS:=3}"

# Bytes of fleet.log to keep. At the cap the file is rotated to fleet.log.1 --
# ONE generation, because the point is a bound, and two files at the cap is
# twice the cap.
#
# NOT while a reviewer is running: `review.sh` is spawned with `>>` on this file
# and holds the inode for up to AUTOFLEET_REVIEW_TIMEOUT, so the cap is a bound
# the fleet reaches between reviews rather than a hard ceiling.
: "${AUTOFLEET_LOG_MAX_BYTES:=1048576}"

# ------------------------------------------------------------- the handoff
# How long the note one attempt leaves the next may be, in words.
#
# `scripts/fleet/handoff.sh` REFUSES over this rather than truncating, and that
# is the whole argument for the cap being a number a script enforces instead of
# a sentence in the brief. Unbounded, the note grows into a second spec that the
# next attempt reads in full before its first edit -- which is the cost
# armaatus/autofleet#55 exists to remove, arriving through the fix. Truncated,
# it is worse still: the reader cannot tell "nothing else was open" from "the
# rest did not fit", and what falls off the end of a note written in that order
# is exactly what is still open.
#
# 300 is a starting point. Set it to 0 to turn the cap off, the way
# AUTOFLEET_KEEP_REVIEWS=0 turns the sweep off -- an unbounded note is then
# something a host asked for, not something a mistyped value produced silently.
# The check at the foot of this file is what makes that distinction hold.
: "${AUTOFLEET_HANDOFF_MAX_WORDS:=300}"

# --------------------------------------------------------------- the cost
# Where the agent CLI writes its session transcripts, and therefore the only
# place `cost.sh` can find out what a worktree run actually spent.
#
# Claude Code writes one JSONL per session under
# `<root>/<cwd-slug>/<session-id>.jsonl`, where the slug is the absolute working
# directory with every NON-ALPHANUMERIC character turned into `-`, truncated at
# 200 characters with a hash appended past that. That is the whole of the tie
# between a session and an issue: the fleet knows each issue's worktree path, and
# the path is what names the directory.
#
# A knob rather than a constant because it is the one project-specific thing the
# report needs, and hard rule 2 says a script may not know it. WHAT IT MOVES IS
# THE PATH, NOT THE FORMAT: `cost.sh` reads the entry shape above and the
# non-alphanumeric-to-`-` slug rule, so a host whose CLI writes the same shape
# somewhere else points this at it, and a host whose CLI writes something else
# gets a report of zeros. That host sets it EMPTY, which `cost.sh` answers with
# one line and exit 0 rather than an error -- a reporting command must never be
# the thing that fails a run.
#
# `=` AND NOT `:=`, alone among the knobs in this file. Every other default
# substitutes on unset OR NULL, which is right when empty has no meaning; here
# empty IS the off switch, and `:=` handed it straight back the default -- so
# `AUTOFLEET_TRANSCRIPT_DIR= ./scripts/fleet/fleet.sh cost` reported the whole
# machine instead of declining, and the one documented way to turn the report off
# from the environment did nothing. The host-config route was unaffected (a plain
# assignment there is read after these defaults and wins either way), which is
# exactly the shape of bug that ships: the documented off switch works in the
# place nobody tests it from.
: "${AUTOFLEET_TRANSCRIPT_DIR=$HOME/.claude/projects}"

# ------------------------------------------------------------- per-worktree
# The prefix every derived compose project name carries, and the thing reap.sh
# sweeps by. Must be unique to this project on this machine: reap.sh removes
# stacks matching it whose worktree is gone.
: "${AUTOFLEET_PROJECT_PREFIX:=af}"
# `name:base` pairs. Each worktree gets `base + offset`, written to .env as
# `NAME=<port>`. Empty means this project needs no ports.
: "${AUTOFLEET_PORTS:=}"
# The modulus the per-worktree offset is taken over. Also the width of each
# port range above, so the bases must be at least this far apart.
: "${AUTOFLEET_PORT_SPAN:=2000}"
# The compose file a worktree's stack is described by, relative to the repo
# root. Empty means this project runs no containers, and teardown skips docker
# entirely.
: "${AUTOFLEET_COMPOSE_FILE:=}"
# Extra arguments for the teardown `docker compose down`, e.g. `--profile tls`.
# A service whose profile is not active survives `down`, comes back under
# `restart: unless-stopped`, and holds its port with no worktree left to find
# it by.
: "${AUTOFLEET_COMPOSE_DOWN_ARGS:=}"

# ------------------------------------------------------------- project hooks
# Where the project says what a worktree needs. Both are optional, both run
# from the repo root with .env already exported, and a non-zero exit from the
# setup hook fails provisioning loudly rather than handing an agent a broken
# rig.
: "${AUTOFLEET_SETUP_HOOK:=.autofleet/setup.sh}"
: "${AUTOFLEET_TEARDOWN_HOOK:=.autofleet/teardown.sh}"
# What the summary tells the agent to run. Cosmetic, but it is the first thing
# an agent reads in a fresh worktree.
: "${AUTOFLEET_TEST_COMMAND:=}"

# -------------------------------------------------------------- niceties
# The title on the macOS notifications the dispatcher posts.
: "${AUTOFLEET_NOTIFY_TITLE:=autofleet}"

# The host repo's overrides, last so they win over the defaults but not over
# the environment -- every default above is `:=`, so an exported value is
# already in place by the time this runs, and a config file that uses `:=` too
# preserves that. A config file that assigns outright deliberately overrides
# even the environment.
if [ -f "${AUTOFLEET_CONFIG:-$REPO_ROOT/.autofleet/config}" ]; then
  . "${AUTOFLEET_CONFIG:-$REPO_ROOT/.autofleet/config}"
fi

# ----------------------------------------------------- knobs that must be sane
#
#
# AFTER the host config, because that is the route that matters: a value only
# checked before it is checked on the one path nobody uses. See the note by
# AUTOFLEET_REVIEW_MAX_TRIES above for why this knob in particular cannot be
# allowed through wrong -- a non-number makes `[ N -ge X ]` return 2, the cap
# test false, and the cap itself absent.
#
# FATAL, and fatal to every fleet command, not just the dispatcher: this file is
# sourced by lib.sh, so `exit` here takes the sourcing shell with it -- including
# `stop.sh`, which is the one you reach for when something is wrong. That is the
# intended trade and it is named here rather than discovered: the message says
# exactly which knob and what it got, and the fix is a one-line edit to the file
# the message is about. A cap that is silently absent is the failure this exists
# to prevent, and it cannot be prevented by a warning nobody reads in a
# dispatcher log.

# ONE refusal, four knobs. Spelled out inline it was two copies; the third and
# fourth would have been where a `-gt` met a `-ge` and one cap became
# off-by-one silently. The comment blocks below stay attached to the knobs they
# are about -- each of them is a failure somebody had -- and only the mechanism
# is shared.
#
# $1 the name, $2 the value, $3 the smallest legal value, $4 how to say that.
config_whole_number() {
  case "$2" in
    # Digits first, then a NUMERIC test for the floor. `''|*[!0-9]*|0` rejected
    # the literal `0` and let `00` straight through -- all digits, not that
    # literal -- and `[ 0 -ge 00 ]` is true.
    ''|*[!0-9]*)
      echo "$1 must be $4; got '$2'" >&2
      exit 2 ;;
  esac
  [ "$2" -ge "$3" ] || { echo "$1 must be $4; got '$2'" >&2; exit 2; }
}

# Digits first, then a NUMERIC test for positive. `''|*[!0-9]*|0` rejected the
# literal `0` and let `00` straight through -- all digits, not that literal --
# and `[ 0 -ge 00 ]` is true, so the cap is zero attempts: no PR is ever
# reviewed, every PR blocks on a review that cannot arrive, and the hold
# announces "0 reviewers on <sha> submitted nothing, which is the cap", which is
# the exact untrue line the 0 rejection exists to prevent. One spare zero and the
# guard was the failure. Found by the independent review.
config_whole_number AUTOFLEET_REVIEW_MAX_TRIES "$AUTOFLEET_REVIEW_MAX_TRIES" \
  1 "a positive whole number"

# The same shape of failure as the one above, one step earlier: `[ "$words" -le
# "$cap" ]` in handoff.sh with a non-number prints "integer expression expected"
# and returns 2, so the test is FALSE, `refuse_if_over_cap` returns early, and a
# note of any length is accepted -- the guard absent, silently, which is hard
# rule 3.
#
# BELOW the block above, and not between that block's comment and its `case`:
# the paragraph ending "One spare zero and the guard was the failure" is about
# AUTOFLEET_REVIEW_MAX_TRIES and has to stay next to it. Found by the local
# /mattpocock-skills:code-review pass, which is the one that reads comments as
# load-bearing.
#
# Unlike the knob above, 0 is a LEGAL value here and means "no cap"; only a
# non-number has to be refused, because only a non-number turns the guard off
# without saying so.
config_whole_number AUTOFLEET_HANDOFF_MAX_WORDS "$AUTOFLEET_HANDOFF_MAX_WORDS" \
  0 "a whole number (0 turns the cap off)"


# The same validation, for the same reason: the only consumer is an integer `[`
# test in fleet.sh, and a non-number makes that test FALSE rather than an error
# anybody sees, so the cap silently does not exist.
config_whole_number AUTOFLEET_REVIEW_MAX_ROUNDS "$AUTOFLEET_REVIEW_MAX_ROUNDS" \
  1 "a positive whole number"

# The two knobs armaatus/autofleet#65 added, refused for the same reason: each
# is read by an arithmetic expansion or a command argument where a non-number
# means the bound is absent rather than wrong.
#
#   FULL_EVERY  `$(( rounds % AUTOFLEET_REVIEW_FULL_EVERY ))` -- 0 is a division
#               by zero, which prints an error and yields 1, so EVERY round
#               would read as the Kth. The floor is 1, which means "every round
#               is full" and is a legitimate way to turn the delta path off from
#               the config file.
#   CONTEXT_MAX `head -c "$AUTOFLEET_REVIEW_CONTEXT_MAX"` -- a non-number makes
#               `head` fail and the context file empty, which is a delta review
#               with nothing carried forward and no sign that anything is
#               missing. 0 is legal and means "carry nothing".
config_whole_number AUTOFLEET_REVIEW_FULL_EVERY "$AUTOFLEET_REVIEW_FULL_EVERY" \
  1 "a positive whole number (1 makes every round a full review)"
config_whole_number AUTOFLEET_REVIEW_CONTEXT_MAX "$AUTOFLEET_REVIEW_CONTEXT_MAX" \
  0 "a whole number of bytes (0 carries nothing forward)"

# Not a number, so not the helper. A misspelling here fails in the safe
# direction anyway -- `review.sh` tests for the literal `delta` and anything
# else is a full review -- but silently, and a project that wrote `deltas` in
# its config would keep paying for full reviews and have no way to find out.
case "$AUTOFLEET_REVIEW_SCOPE" in
  full|delta) ;;
  *) echo "AUTOFLEET_REVIEW_SCOPE must be 'full' or 'delta';" \
          "got '$AUTOFLEET_REVIEW_SCOPE'" >&2
     exit 2 ;;
esac
