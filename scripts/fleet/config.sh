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
# THE TIME-BOXES ARE GONE. What bounded an issue used to be hours -- a build box
# and a second one for the answering half -- because an interactive session runs
# until something stops it. See AUTOFLEET_BUILD_MAX_TURNS and
# AUTOFLEET_BUILD_MAX_BUDGET_USD under "the runner": a run ends by itself now,
# and hours were never the thing that cost anything anyway.
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
# Which driver creates a worktree and runs the build in it. `headless` is the
# default and needs nothing but `git`, `gh` and the build command; `orca` runs
# the identical build in a terminal on a machine that has the app, so the
# maintainer can watch it. The contract a third one has to meet is docs/RUNNERS.md, which
# CLAUDE.md hard rule 4 names as the authority -- fleet/runner/README.md, which
# this used to point at, is about the seam and lists no `runner_*` at all.
#
# A name with no `scripts/fleet/runner/<name>.sh` beside it is named where
# lib.sh sources it -- the file it looked for and the drivers that do ship --
# and stops the four scripts that call `fleet_require_runner`: the dispatcher,
# the setup hook, the board and the autostart watcher. `evals/lint.sh` check 4g
# goes red on it before an agent is ever opened.
: "${AUTOFLEET_RUNNER:=headless}"

# What the build agent is, and how much of it one issue may have.
#
# THE TIME-BOX IS THESE TWO NUMBERS NOW. The old one was a wall clock the
# dispatcher enforced by interrupting a live session with a turn that asked it
# to stop, which needed a session that could be typed into and a runtime that
# would relay the keystrokes. `claude -p` ends by itself at either of these, and
# the dispatcher's job shrinks to reading the exit and saying which one it was.
# armaatus/autofleet#41, armaatus/autofleet#151.
#
# A budget rather than only a turn count because the two fail differently: a
# build that reads whole files burns dollars at a low turn count, and one that
# greps in a loop burns turns cheaply. The defaults are this repository's
# measurements -- a median issue here has cost about $20 -- and a host project
# is expected to move them, which is what docs/CONFIGURATION.md says.
: "${AUTOFLEET_BUILD_CMD:=claude}"
: "${AUTOFLEET_BUILD_MAX_TURNS:=400}"
: "${AUTOFLEET_BUILD_MAX_BUDGET_USD:=25}"

# Where the headless driver puts the worktrees it creates. Empty means
# `$AUTOFLEET_DIR/trees`, which is the answer for every host that does not care.
# A host that keeps its checkouts on another volume sets this.
: "${AUTOFLEET_WORKTREE_ROOT:=}"

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
# ---------------------------------------------------------------- the SELF-review
#
# The OTHER review: the two passes the author runs on its own diff before the
# pull request exists (`scripts/fleet/self-review.sh`). Separate knobs from the
# independent reviewer's above, because the two runs are shaped differently --
# one reads a pull request through `gh` and submits a verdict, the other reads a
# local range and prints findings -- and a project that wants a cheaper model for
# its own diff than for the verdict on it has to be able to say so.
#
# The command DEFAULTS to the independent reviewer's, so a host that has set
# nothing, and a host that has set only `AUTOFLEET_REVIEW_CMD`, both still work.
#
# THE FALLBACK IS RESOLVED AT THE BOTTOM OF THIS FILE, not here. `.autofleet/config`
# is sourced further down so it can override these defaults -- so a host that
# sets `AUTOFLEET_REVIEW_CMD=my-wrapper` in that file would have had the
# self-review fall back to the `claude` this line saw, which is the one route
# the documented fallback is actually for. Empty here; `:=` treats empty as
# unset, so the resolution below fires for anything the environment and the host
# config did not set. Found by the local /code-review pass.
: "${AUTOFLEET_SELF_REVIEW_CMD:=}"
# How long ONE pass may run before it is killed. Lower than the independent
# reviewer's 1800 because there are two of them and they are spent inside the
# build's own run: two wedged passes at 1800 would be an hour of a build's turns
# and dollars with nothing to show.
: "${AUTOFLEET_SELF_REVIEW_TIMEOUT:=1200}"
# Each pass's turn budget, passed through as `--max-turns`. The same number
# `claude-review.yml` and the independent reviewer get: both passes fan out into
# sub-agents of their own, so the visible budget is what keeps "report what you
# have while you still have turns" meaningful.
: "${AUTOFLEET_SELF_REVIEW_MAX_TURNS:=80}"
# How many times ONE BRANCH may run the two passes before the loop is called
# done and what it has found is handed on to the independent reviewer.
#
# THE NEIGHBOUR ABOVE BOUNDS ONE PASS. This bounds the number of them, and it
# was the hole: `AUTOFLEET_REVIEW_MAX=1` and `AUTOFLEET_VALIDATE_MAX=2` bound
# everything AFTER the pull request exists, and nothing bounded what came
# before it. Measured on this machine, PR #126 ran SIXTEEN rounds of both
# passes and PR #129 ran eight, each round two fresh full-budget agents
# re-reading the whole branch diff -- 36% of issue #71's 207M tokens.
#
# It ground because the loop has nothing to converge on. A review pass can
# always find one more Suggestion; the agent answers a finding with a commit;
# the commit moves the head; `record-review.sh` keys its marker on the head, so
# the marker is stale and another round is needed to push. Every turn of that
# cycle is the same size as the last.
#
# TWO, for the same reason AUTOFLEET_VALIDATE_MAX is two: one round to find
# what is there, one to check the answers to it. The findings that survive a
# second round are the independent reviewer's job, which is the phase that
# exists for exactly this and is bounded at one.
: "${AUTOFLEET_SELF_REVIEW_MAX:=2}"

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

# How many reviews one PULL REQUEST gets, and how many validations may follow.
#
# THE LOOP IS ONE REVIEW AND THEN AT MOST TWO VALIDATIONS, and these are the two
# numbers that say so. It replaced a loop bounded at four reviews per PR that
# routinely spent all four: #86 burned four without one ever judging its current
# head, because every answer to a finding was a commit, every commit moved the
# head, and a head move invalidates the review that asked for it. Reviewing the
# same branch four times is not four times the assurance; it is the same review
# of four different commits, none of which is the one that merges.
#
# So the two phases are bounded separately, because they are different jobs:
#
#   AUTOFLEET_REVIEW_MAX     how many times the REVIEWER judges the diff. One.
#                            It fires at PR-open, on the head the PR opened
#                            with, and everything after that is the fix.
#   AUTOFLEET_VALIDATE_MAX   how many times the VALIDATOR judges the answer.
#                            Two: one for the commits answering the review, and
#                            one more for the commits answering the validator.
#                            Past it a person decides, which is the point -- an
#                            unbounded loop ends in a person too, just later and
#                            having spent a night getting there.
#
# Both are per PULL REQUEST, not per head, and both count only runs that
# submitted something. A validator killed at its deadline, or one whose CLI was
# not on PATH, is refunded -- `validate.sh` says which exits do that and why,
# in the same words `review.sh` says it.
: "${AUTOFLEET_REVIEW_MAX:=1}"
: "${AUTOFLEET_VALIDATE_MAX:=2}"
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

# One line per dispatcher pass, saying the pass ended. OFF by default, because a
# line a minute is exactly the log volume the say-once markers elsewhere in this
# file exist to prevent -- and ON it is the only deterministic answer to "has a
# pass finished", which is a question both an operator watching a quiet fleet and
# a test asserting what a pass COST have to be able to ask. armaatus/autofleet#69
# measured the per-pass budget by watching call counts stop moving, which is a
# wall-clock guess; this is the signal that guess was standing in for.
#
# `on` or `off`, and validated below, because the first shape of this knob was
# "set to anything" -- read with `[ -n ]`, which turns ON for `0` and for `off`.
# A host writing `AUTOFLEET_LOG_PASSES=0` into `.autofleet/config` then gets the
# line a minute this default exists to prevent, with no diagnostic saying why.
# Found by the local review.
: "${AUTOFLEET_LOG_PASSES:=off}"

# ---------------------------------------------------- what replaced all this
# FIVE KNOBS USED TO LIVE HERE and they are gone with armaatus/autofleet#151:
# AUTOFLEET_HANDOFF_MAX_WORDS, AUTOFLEET_CONTEXT_RESET, AUTOFLEET_AGENT_CLEAR_CMD,
# AUTOFLEET_HANDOFF_GRACE_SECONDS and AUTOFLEET_CONTEXT_RECYCLE.
#
# Every one of them was about keeping ONE interactive session usable for the
# whole of an issue: cap the note it writes before being cleared, decide whether
# to clear it at the pull request, name the command that clears it, say how long
# it gets to write the note, and how often to do the whole dance mid-build. The
# cost they were managing is real -- sessions were measured past 900,000 tokens,
# most of it a build nobody was still reading -- and the cause was that the
# session could not be allowed to END.
#
# A `claude -p` run ends. AUTOFLEET_BUILD_MAX_TURNS and
# AUTOFLEET_BUILD_MAX_BUDGET_USD above are what bounds it, and a second run
# starts from the branch and the pull request, which is state that outlives any
# session and needs nothing written down. AUTOFLEET_BUILD_MAX_RUNS is how many
# of those one worktree gets.
: "${AUTOFLEET_BUILD_MAX_RUNS:=3}"

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

# ------------------------------------------------- the compression proxy
# Every model call this fleet makes pays full price for its context, and the
# cost knobs above only MEASURE that. A compressing proxy in front of the call
# is the other half: the agent is pointed at a local HTTP endpoint that squeezes
# what it READS -- tool output, logs, file reads, JSON, diffs -- before the
# tokens are counted. Savings scale with how repetitive the payload is: repeated
# JSON and log lines compress hard, prose and already-dense output barely at
# all, and this fleet's traffic is a mix of both. docs/CONFIGURATION.md has the
# measured number for this repo and what turning it on costs you.
#
# OFF BY DEFAULT, and off means INERT: at `0` nothing is exported, nothing is
# probed, and there is nothing to install. That is what keeps CLAUDE.md's "no
# build step, no dependencies to install" true for a repository that never sets
# this. The install line is in docs/CONFIGURATION.md, which is where the price
# of turning it on belongs.
#
# NAMED FOR HEADROOM, WIRED TO NOBODY. The knob carries the name because hard
# rule 4's temperament is that a dependency is named rather than hidden -- but
# nothing under scripts/fleet/ imports it, probes for its CLI, or reads a file
# of its. The mechanism is two environment variables and a TCP probe, so any
# Anthropic-compatible compressing proxy satisfies it.
: "${AUTOFLEET_HEADROOM:=0}"
# Where that proxy answers. ONE HOST-LEVEL ENDPOINT, shared by every worktree on
# the machine -- deliberately NOT a per-worktree port out of AUTOFLEET_PORTS, and
# deliberately not written into `.env`, which derives per-worktree values from
# the worktree path. Writing this per worktree would imply an isolation that
# does not exist, and the first person to debug it would look for three proxies.
#
# The fleet PROBES this and never spawns it. Starting and stopping the daemon is
# outside autofleet: a dispatcher that owns a daemon's lifecycle is a dispatcher
# that can fail to start for a reason that has nothing to do with the backlog.
: "${AUTOFLEET_HEADROOM_URL:=http://127.0.0.1:8787}"

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

# The self-review's command, now that the host config has had its say. See the
# note by the knob above for why this cannot be done where it is declared.
: "${AUTOFLEET_SELF_REVIEW_CMD:=$AUTOFLEET_REVIEW_CMD}"

# ----------------------------------------------------- knobs that must be sane
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
# The self-review's two, refused for the same reason and with a sharper edge:
# the timeout's only consumer is
# `[ "$waited" -ge "$AUTOFLEET_SELF_REVIEW_TIMEOUT" ]` in self-review.sh, so a
# non-number makes `[` return 2, the test FALSE, and the deadline never fires --
# a wedged pass then holds the worktree until the three-hour time-box expires.
# Found by the local /code-review pass.
config_whole_number AUTOFLEET_SELF_REVIEW_TIMEOUT "$AUTOFLEET_SELF_REVIEW_TIMEOUT" \
  1 "a positive whole number of seconds"
config_whole_number AUTOFLEET_SELF_REVIEW_MAX_TURNS "$AUTOFLEET_SELF_REVIEW_MAX_TURNS" \
  1 "a positive whole number of turns"

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
# The same shape, for the same reason: anything that is not `on` would leave the
# quiet default, but silently -- and here the misspelling fails in the LOUD
# direction instead (`[ -n ]` read `0` and `off` as on), which is worse than
# either. See the knob's own comment.
case "$AUTOFLEET_LOG_PASSES" in
  on|off) ;;
  *) echo "AUTOFLEET_LOG_PASSES must be 'on' or 'off';" \
          "got '$AUTOFLEET_LOG_PASSES'" >&2
     exit 2 ;;
esac

# WHAT ONE RUN MAY SPEND, and the reason these are checked rather than trusted
# is the one stated above: the consumers are `claude -p` flags, and a
# non-number reaches the build command as an argument it refuses -- which is a
# build that dies the moment it starts, once per launch, forever.
config_whole_number AUTOFLEET_BUILD_MAX_TURNS "$AUTOFLEET_BUILD_MAX_TURNS" \
  1 "a positive whole number of turns"

config_whole_number AUTOFLEET_BUILD_MAX_RUNS "$AUTOFLEET_BUILD_MAX_RUNS" \
  1 "a positive whole number (1 means a build is never resumed)"

# The same validation, for the same reason: the only consumer is an integer `[`
# test in fleet.sh, and a non-number makes that test FALSE rather than an error
# anybody sees, so the cap silently does not exist.
config_whole_number AUTOFLEET_REVIEW_MAX "$AUTOFLEET_REVIEW_MAX" \
  1 "a positive whole number"
config_whole_number AUTOFLEET_VALIDATE_MAX "$AUTOFLEET_VALIDATE_MAX" \
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
# THE THREE CAPS THAT BOUND WHAT AN ISSUE SPENDS, refused for the reason every
# other number in this section is: a non-number makes `[ N -ge X ]` return 2,
# bash reads 2 as false, and the cap never fires. Silently, which is worse here
# than for most of these, because each of these three IS the bound on a loop
# that has already been measured running away.
#
#   SELF_REVIEW_MAX   `[ "$round" -gt "$AUTOFLEET_SELF_REVIEW_MAX" ]` in
#                     self-review.sh. False forever means the pre-PR loop is
#                     uncapped again -- sixteen rounds on PR #126, two fresh
#                     full-budget agents each. The floor is 1 and 0 is NOT an
#                     off switch: at 0 the first round is already over the cap,
#                     so no self-review ever runs and the push gate opens on
#                     findings nothing produced. That is the hole self-review.sh
#                     exists to close, reached through a config typo.
#   BUILD_MAX_RUNS    `[ "$runs" -ge "$AUTOFLEET_BUILD_MAX_RUNS" ]` in
#                     fleet.sh's `build_exited`. False forever is the resume
#                     loop with no bound -- a run that ends the instant it
#                     starts, restarted every poll, spending the account one
#                     session at a time with the log saying "resuming".
config_whole_number AUTOFLEET_SELF_REVIEW_MAX "$AUTOFLEET_SELF_REVIEW_MAX" \
  1 "a positive whole number (0 would mean no self-review ever runs)"

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

# THE OLD KNOB IS AN ERROR, NOT AN ALIAS.
#
# `AUTOFLEET_REVIEW_MAX_ROUNDS` bounded reviews-per-PR at four when four reviews
# was the shape. The two knobs above replaced it, and a host repository that
# tuned the old one meant something by the number -- "give this project more
# rounds" -- which maps onto neither of them. Aliasing it to the review cap
# would keep the file working and quietly change what it asks for, which is the
# failure mode every other check in this file is written against: a setting that
# is read, accepted, and does something else.
#
# So it is loud. A host repo hits this once, on the first run after upgrading,
# with both replacements named in the message.
# `${VAR+set}`, not `-n "${VAR:-}"`. A host config that has been half-edited
# leaves `AUTOFLEET_REVIEW_MAX_ROUNDS=` with nothing after the `=` -- still a
# line about a knob nothing reads, and still someone who thinks they have
# configured the cap. `-n` sees an empty string and says nothing, which is the
# silent-acceptance this check exists to refuse. Found by the suite, which
# already drove the empty case through `.autofleet/config` for the old knob.
if [ -n "${AUTOFLEET_REVIEW_MAX_ROUNDS+set}" ]; then
  echo "AUTOFLEET_REVIEW_MAX_ROUNDS is set, and nothing reads it any more." >&2
  echo "The loop is one review and then at most two validations, bounded" >&2
  echo "separately because they are different jobs:" >&2
  echo "  AUTOFLEET_REVIEW_MAX=1     how many times the reviewer judges the diff" >&2
  echo "  AUTOFLEET_VALIDATE_MAX=2   how many times the validator judges the answer" >&2
  echo "Remove the old line from .autofleet/config and set whichever of those" >&2
  echo "you meant. docs/CONFIGURATION.md has both rows." >&2
  exit 2
fi

# THE COMPRESSION KNOB IS A TOGGLE AND ONLY TWO VALUES ARE ONE. `fleet_headroom_on`
# tests for the literal `1`, so `AUTOFLEET_HEADROOM=on` -- the spelling the two
# knobs above this file take, which is exactly why somebody will write it --
# read as OFF: every review quietly paid full token price, `fleet.sh status`
# said "off", and nothing anywhere named the typo. A knob whose wrong value is
# indistinguishable from its default is the silent-acceptance failure the rest of
# this section exists to refuse. Found by the self-review.
case "$AUTOFLEET_HEADROOM" in
  0|1) ;;
  *) echo "AUTOFLEET_HEADROOM must be '0' or '1'; got '$AUTOFLEET_HEADROOM'." >&2
     echo "docs/CONFIGURATION.md has the row, and what turning it on costs." >&2
     exit 2 ;;
esac
