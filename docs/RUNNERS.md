# Runners

A **runner** is whatever creates a worktree, opens a terminal in it, and can be
asked what it is doing. `scripts/fleet/runner/$AUTOFLEET_RUNNER.sh` is the
driver, sourced by `lib.sh`.

Today there is exactly one: `orca`. **autofleet needs Orca**, and this page is
the honest account of how tightly.

## What is actually behind the seam

`scripts/fleet/runner/orca.sh` holds the CLI plumbing:

- `orca_cli_resolve` — find a working `orca` binary, in `$ORCA_CLI`. The wrapper
  on `PATH` locates Orca.app by reading its own symlink, and a macOS install has
  shipped that symlink `0700 root:wheel`, so the readlink fails for the user the
  hooks run as and every call dies. Nothing notices a broken CLI as such — the
  JSON never parses — so it surfaces one layer up as an *answer*: "this worktree
  has no linked issue", a fully provisioned worktree, and an agent sitting on an
  unsent prompt forever. So the wrapper is verified rather than assumed, and the
  app's own binary is the fallback.
- `orca_run_with_deadline` — every CLI call with a hard watchdog. The runtime can
  accept a connection and never answer, and `wait-for-setup` holds the agent's
  tab until `setup.sh` returns, so a hook that blocks forever costs the whole
  worktree. macOS ships no `timeout`, hence the manual one.

## What is not behind it yet

`fleet.sh`, `agent-autostart.sh` and `issue-command.sh` still invoke `$ORCA_CLI`
directly, for:

| Capability | Orca command | Why the fleet needs it |
|---|---|---|
| create a worktree | `orca worktree create` | one issue, one isolated tree |
| list worktrees | `orca worktree list` / `ps` | what is in flight, and what is stale |
| remove a worktree | `orca worktree rm` | reclaiming a slot once the PR merged |
| set worktree metadata | `orca worktree set` | linking the issue to the tree |
| create a terminal | `orca terminal create` | the agent's tab, and the log tab |
| read/send a terminal | `orca terminal read` / `send` | submitting the opening prompt; noticing a stalled agent |

Moving those callsites behind a driver API is what makes a second runner
possible. It is tracked in the backlog, and it is the repo's first real feature.

## The contract a second driver must meet

A driver is a shell file that defines these, and nothing else may assume how they
work:

```sh
runner_available()                 # 0 if this runner can be used at all
runner_worktree_create <branch> <path> [<issue>]
runner_worktree_list               # `path<TAB>branch<TAB>issue` lines
runner_worktree_remove <path>      # 0 only if it is really gone
runner_worktree_set <path> <key> <value>
runner_terminal_create <path> <title> <command>
runner_terminal_read <id> <lines>
runner_terminal_send <id> <text>
```

Three properties matter more than the shapes:

1. **Every call has a deadline.** A driver that can block forever takes the
   worktree with it.
2. **"I could not tell" is not "nothing".** Every one of these must distinguish a
   negative answer from a failed question. Conflating them is how a dispatcher
   waits out its whole time-box and then reports that nothing arrived.
3. **`runner_worktree_list` answers for THIS repository, and scoping it is the
   driver's job.** One machine runs one fleet per repository -- that is what
   `.autofleet/config` is for -- and a runtime that knows about all of them will
   answer for all of them unless asked otherwise. The caller may not do the
   filtering: it holds an issue NUMBER and a path, and both collide across
   repositories, while the runtime is the only thing that knows which repository
   a worktree belongs to. Orca's answer is `worktree list --repo path:<root>`;
   a `git worktree` driver's is `git -C <root> worktree list`. Get this wrong
   and another repository's worktree takes a slot, answers `in_flight` for an
   issue of ours, and holds every `foundation` issue forever -- #46, which
   stopped this repo's own fleet for a day.

   `path:` names a repository ROOT, and the dispatcher is not always run from
   one: `fleet.sh status` is run from a fleet worktree. `repo_selector` in
   `fleet.sh` resolves that through `git --git-common-dir`, and until the list
   moves behind `runner_worktree_list` (#1) it passes the flag at the callsite.

A plain-`git worktree` + tmux driver satisfies all of it, and would drop the
macOS-only dependency entirely.
