#!/usr/bin/env bash
# The knobs a host project sets, and their defaults. Sourced by lib.sh, never
# executed.
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
# is read by nothing -- `ready_issues` asks `gh` for the literal word -- so
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
