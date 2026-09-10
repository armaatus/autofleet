# Runners

A **runner** is whatever creates a worktree, opens a terminal in it, and can be
asked what it is doing. `scripts/fleet/runner/$AUTOFLEET_RUNNER.sh` is the
driver, sourced by `lib.sh`.

Today there is exactly one that ships: `orca`. It is no longer load-bearing
anywhere else — `scripts/fleet/runner/` is the whole of the dependency, and

```sh
grep -rn 'ORCA_CLI\|orca ' scripts/fleet --include='*.sh' \
  | grep -v '^scripts/fleet/runner/'
```

returning nothing is what keeps it that way. A second runner is a second file in
that directory.

## The contract

A driver defines the functions below and nothing outside the directory may
assume how any of them work. Two properties matter more than the shapes, and
both are load-bearing rather than stylistic:

1. **Every call has a deadline.** A driver that can block forever takes the
   worktree with it: `orca.yaml`'s `setupAgentStartupPolicy: wait-for-setup`
   holds the agent's tab until `setup.sh` returns, so a hook that never comes
   back costs the whole worktree. macOS ships no `timeout`, so `lib.sh` provides
   `fleet_run_with_deadline` — a watchdog, not part of this contract, because
   `finish_removal` runs `reap.sh` through it too.
2. **"I could not tell" is not "nothing".** Every one of these distinguishes a
   negative answer from a failed question. Conflating them is how a dispatcher
   waits out its whole time-box and then reports that nothing arrived — see the
   `*_blind_ps` and `foundation_blind` phases in `tests/test_fleet.sh`, which
   pin exactly this.

Nothing below returns JSON. A caller that parses JSON has hardcoded one runner,
which is the thing this seam exists to prevent.

### Is it there

```sh
runner_available          # 0 if this runner can be used at all
runner_dispatcher_hint    # one line: how a person starts the dispatcher visibly
```

`runner_available` **says why on stderr when it cannot** — only the driver knows
what to check next, and "is the Orca app running?" is not a sentence the
dispatcher can write for an arbitrary runner. The caller adds the consequence.

`runner_dispatcher_hint` is the one human-facing string that is runner-specific;
`fleet.sh`'s usage prints it rather than hardcoding a command line that is wrong
for every other driver.

### Worktrees

```sh
runner_worktree_create <repo> <name> <issue> <agent> <prompt> <comment>
runner_worktree_list      # `path<TAB>branch<TAB>issue` lines
runner_worktree_issue     # THIS worktree's linked issue
runner_worktree_set <path> <key> <value> [<key> <value> ...]
runner_worktree_remove <path> [<deadline>]
```

- **`runner_worktree_create`** prints the new worktree's path on success, and the
  runtime's own words on failure — "could not create it" with nothing after it
  reads the same whether the app is down or the branch already exists.
- **`runner_worktree_list`** emits `path<TAB>branch<TAB>issue`, `-` where the
  runner has no answer for a field, excluding the main worktree and archived
  ones — the fleet counts these to decide whether it may launch, and neither of
  those is a slot. **Non-zero when the list could not be read**, which is not
  the same as "nothing is running": reading a failed call as zero live worktrees
  is how one transient hiccup turns into three duplicate worktrees.
- **`runner_worktree_issue`** has THREE answers, and the middle one is why it is
  not a boolean: `0` with the issue on stdout, `2` for "there is no linked
  issue", `1` for "the runtime would not say". A hook that reads 1 as 2
  announces that a worktree the fleet linked to an issue has none — which is
  exactly what happened on 2026-09-05, and cost three worktrees a night.
- **`runner_worktree_set`** takes `key value` PAIRS, because every caller sets a
  status and the comment explaining it: sent separately, a failure between them
  leaves the board carrying a new status with the previous line under it. The
  keys the fleet uses are `workspace-status` and `comment`. Silent on success,
  the runtime's own words on failure.
- **`runner_worktree_remove`** returns `0` only if the worktree is REALLY gone,
  `1` if the runner answered and refused, `2` if it never answered. The caller
  acts on the difference: a refusal is a decision about this worktree and is not
  worth retrying, while a deadline is the runtime restarting and says nothing
  about the worktree at all. It must not run the runner's own teardown hooks —
  see the comment on the Orca implementation for what that cost (#163).

### Agents and terminals

```sh
runner_agent_states       # `path<TAB>state` lines
runner_agent_terminals    # `handle<TAB>worktree-path` lines
runner_agent_terminal <path>
runner_terminal_draft <handle>
runner_terminal_send <handle> <text>
runner_terminal_enter <handle>
runner_terminal_interrupt <handle>
```

- **`runner_agent_states`** is ONE listing for the whole machine, not one call
  per worktree: the dispatcher matches it against every owned worktree each
  poll, and three deadline-length calls a minute for an answer that arrives in a
  single response is the shape this replaced.
- **`runner_agent_terminals`** lists only live agent tabs — not the shell and
  log tabs beside them, and not handles whose terminal is already gone. The
  worktree path is on every line because it is what keeps three parallel
  worktrees from sending into each other's agents.
- **`runner_terminal_draft`** is the composer text an agent has NOT sent, as
  `<length> <text with newlines flattened>`, or nothing at all when there is no
  draft. Non-zero means the read failed. It is whole rather than truncated: the
  caller reads the text back to decide whether the runtime drafted a real prompt
  or only the issue URL, and the length is what makes a paste caught half way
  through comparable to the same paste once it has landed.
- **`runner_terminal_send`** types without submitting; **`runner_terminal_enter`**
  submits. They are separate because `agent-autostart.sh` appends to a draft
  before pressing Return, and a driver that only had "send this text" could not
  express it.

## Writing a second driver

`tests/test_fleet.sh runner_stub` is the worked example and the regression
guard: it defines all fourteen functions over three text files, points
`AUTOFLEET_RUNNER` at them, and then drives the dispatcher, both worktree hooks
and the reap through it — asserting at the end that the `orca` CLI was never
asked anything. A driver that satisfies that phase satisfies the fleet.

A plain-`git worktree` + tmux driver satisfies all of it, and would drop the
macOS-only dependency entirely. Two things it would have to answer that Orca
answers for free, and that no amount of shell moves away:

- **A linked issue.** Orca records the issue on the worktree, which is what
  `runner_worktree_issue` reads and the only durable statement that a draft is
  expected in that tab. A git-worktree driver has to keep that mapping itself.
- **A drafted prompt.** `agent-autostart.sh` exists because Orca puts the
  resolved spec into the agent's composer WITHOUT submitting it. A driver that
  simply launches the agent with the prompt has nothing for that script to do,
  and `runner_terminal_draft` returning nothing is the honest answer — the
  watcher then says "the agent came up with an empty composer" and stops, which
  is correct.

## What autofleet still assumes about the runtime

Named here rather than left to be discovered:

- The agent runs in a terminal the runner can list, read and interrupt. A runner
  that starts agents some other way has to fake a handle for them.
- One worktree, one directory on this machine, at a path the dispatcher can
  `stat`. `runner_worktree_remove` is judged on that directory being gone.
- `orca.yaml` is where a worktree's setup, archive and issue-command hooks are
  wired. That file is Orca's, and a second runner needs its own equivalent —
  the scripts those hooks point at (`setup.sh`, `archive.sh`,
  `issue-command.sh`) are runner-agnostic and would be reused as they are.
