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
# Found by the independent review of the change that added it.
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
case "$AUTOFLEET_REVIEW_MAX_TRIES" in
  ''|*[!0-9]*|0)
    echo "AUTOFLEET_REVIEW_MAX_TRIES must be a positive whole number;" \
         "got '$AUTOFLEET_REVIEW_MAX_TRIES'" >&2
    exit 2 ;;
esac
