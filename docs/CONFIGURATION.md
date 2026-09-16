# Configuration

Everything autofleet knows about your project arrives through four files. The
payload in `scripts/fleet/` knows about none of it, and a change that puts a
project detail in there is the thing that makes the next repo fork this one
(CLAUDE.md, hard rule 2).

| File | Read by | Overwritten on upgrade? |
|---|---|---|
| `.autofleet/config` | every fleet script, via `scripts/fleet/config.sh` | no |
| `.autofleet/setup.sh` | `scripts/fleet/setup.sh`, once per worktree | no |
| `.autofleet/teardown.sh` | `scripts/fleet/archive.sh`, once per removal | no |
| `.autofleet/guard.json` | `.claude/hooks/guard.py`, on every tool call | no |

Those same three are also **unwritable from a fleet worktree** — `guard.py`
refuses the edit there, as it does for its own hooks and settings, because it
re-reads `guard.json` on every tool call and an emptied file disarms every
project rule long before anything merges. In a worktree you opened yourself they
stay editable: you are the control there. Reading them is never blocked.

Three files here are **human-merge-only**: `merge-gate` refuses to let a PR
touching `.autofleet/guard.json`, `.autofleet/config` or `.autofleet/review.md`
merge itself, the same way it refuses one touching `.claude/` or
`.github/workflows/`. Those three decide what the rules *are* — the guard's
project rules, `AUTOFLEET_REVIEW_MODE`, and the correctness rules the reviewer
applies — so a person merges the change. `setup.sh` and `teardown.sh` are
ordinary project code and merge like anything else.

## `.autofleet/config`

Shell, sourced. `scripts/fleet/config.sh` holds every default with `:=`, so the
precedence is **environment beats this file beats the defaults** — a one-off
`AUTOFLEET_MAX=1 ./scripts/fleet/fleet.sh run --auto` still works. Assign
outright (`AUTOFLEET_MAX=1`) if you want this file to win over the environment
too.

One knob is `=` rather than `:=`, and it says why at its own default:
`AUTOFLEET_TRANSCRIPT_DIR`, where **empty is the off switch**. `:=` substitutes
on unset *or null*, which would hand an explicitly emptied value straight back
the default and make the documented way to turn the cost report off do nothing.

### The dispatcher

| Knob | Default | What it costs to change |
|---|---|---|
| `AUTOFLEET_MAX` | `3` | The ceiling is not machine capacity, it is how many streams one person can review properly. Raising it makes the review queue the bottleneck. |
| `AUTOFLEET_POLL` | `60` | How often the dispatcher re-reads the world, in seconds. Lower burns API quota; higher delays every handoff. |
| `AUTOFLEET_TIMEBOX` | `10800` | How long one issue may hold a worktree. Long enough for a full test run and both review rounds; short enough that an overnight run does not spend the night on the one task that was never going to work. |
| `AUTOFLEET_RM_DEADLINE` | `180` | How long a worktree removal may take before it is reported as refused. |

### The labels

`unblock.yml` maintains the first two and `fleet.sh` reads them; the other three
a person applies. `install.sh` prints the `gh label create` line for all five —
create them before anything can carry one.

**Renaming works for three of the five today.** `AUTOFLEET_FOUNDATION_LABEL`,
`AUTOFLEET_HUMAN_STEP_LABEL` and `AUTOFLEET_PRIORITY_LABEL` are read through the
variable. `AUTOFLEET_READY_LABEL` is not — `ready` is a literal in the
dispatcher's queue filter, and `unblock.yml` writes both `ready` and `blocked` by
name in JavaScript — so renaming that one gives you a dispatcher looking for a
label nothing writes: an empty queue, forever, with nothing on screen saying why.
That is [#57](https://github.com/armaatus/autofleet/issues/57). Until it lands,
keep `ready` and `blocked`.

`AUTOFLEET_READY_LABEL` (`ready`), `AUTOFLEET_BLOCKED_LABEL` (`blocked`),
`AUTOFLEET_FOUNDATION_LABEL` (`foundation`),
`AUTOFLEET_HUMAN_STEP_LABEL` (`needs-human-step`),
`AUTOFLEET_PRIORITY_LABEL` (`priority`).

`priority` is the only one that says *when* rather than *what*, and the only
ordering the tracker cannot derive: an issue carrying it goes to the front of the
ready list, ahead of whatever frees the most other work. It reorders and nothing
more — it cannot start a `blocked` issue, cannot start a `needs-human-step` one,
and does not lift a foundation hold. Label several and the ordinary ordering
decides between them. `fleet.sh status` marks the rows that carry it, so a queue
that looks reordered says why.

One consequence worth knowing before you use it, and it is larger than a
reordering. A `priority` issue can start ahead of a `ready` foundation issue,
and while it runs the foundation issue waits — a foundation issue will not join
worktrees already in flight. The part that costs: the scan **stops at the first
foundation issue** once anything is in flight, so every ready issue behind it is
skipped for that pass as well, whether or not it has anything to do with it.

The fleet therefore runs at **one** worktree for the priority issue's whole
time-box, and at one again while the foundation issue lands alone. Nothing about
"a foundation issue lands alone" is weakened, and what depends on it is `blocked`
either way — but the dependants are not what stalls, so that is the wrong thing
to be reassured by.

Measure that against the right baseline. Those dependants are also what make the
foundation issue sort to the *front* of an unlabelled queue — the second sort key
is how many issues it frees — so it would have taken a solo time-box first
anyway. The label therefore adds one solo time-box rather than costing the
difference between a full fleet and one worktree; `docs/WORKFLOW.md` works the
arithmetic through. If another time-box at one worktree is not what you meant,
the foundation issue is the one to label.

### The review

Two reviews gate a pull request, and both are configurable here.

The first is the **self-review**: the `/code-review` and
`/mattpocock-skills:code-review` passes the author runs on its own diff before
pushing — `guard.py` refuses the push without it, and `merge_gate.py` refuses to
merge a PR whose body does not name both. Required in every mode.
[`scripts/fleet/self-review.sh`](../scripts/fleet/self-review.sh) runs both, in
processes that are not the author's session, and calls `record-review.sh` with
what they found.

The second is the **independent** review: a verdict from a context that has not
seen the conversation which produced the diff. `AUTOFLEET_REVIEW_MODE` says where
it runs.

| Knob | Default | Notes |
|---|---|---|
| `AUTOFLEET_REVIEW_MODE` | `github` | `github` or `local`. |
| `AUTOFLEET_REVIEW_CMD` | `claude` | What `local` mode runs, with `-p` and a fixed tool allowlist. A command on `PATH`, so a wrapper can point it at another model or another account. |
| `AUTOFLEET_REVIEW_TIMEOUT` | `1800` | Seconds one local review may run before it is killed and the PR left for the next poll. The wall-clock backstop for a wedged process. |
| `AUTOFLEET_REVIEW_MAX_TRIES` | `3` | How many attempts one head may get that end with **no verdict** — a reviewer that ran and submitted nothing, or one killed at the timeout. A run that never reached a reviewer (the fleet was stopped, `gh` would not answer, the command is not on `PATH`) does not spend one. A reviewer that runs and returns no verdict is retried, because that is usually transient — unbounded, it is a full-budget reviewer every poll against a head that will never get one. At the cap the dispatcher says so, names the transcript, and stops; a push starts the count again. **Must be a positive whole number: a value that is not is refused, and because this file is sourced the refusal ends every fleet command that reads it, `stop.sh` included.** A cap that is silently absent is the failure the check exists to prevent, so it refuses rather than warns. |
| `AUTOFLEET_REVIEW_MAX` | `1` | **`local` mode only** — `review_open_prs` returns early in `github` mode, so there are no dispatcher-started reviewers to cap. How many times one **pull request** is reviewed. One: the reviewer judges the head the PR opened with, and from the first fix onward the head has moved out from under it. What judges the fix is the validator. It replaced `AUTOFLEET_REVIEW_MAX_ROUNDS` (default `4`), which routinely spent all four — every answer to a finding was a commit, every commit moved the head, and a head move invalidated the review that asked for it; #86 burned four without one ever judging the commit that merged. **Setting the old name is an error, not an alias** — see below. The count lives in `<pr>.rounds` under the fleet's `reviewing/` directory, counts reviews **submitted** across every head, and survives `stop.sh`. **Must be a positive whole number.** |
| `AUTOFLEET_VALIDATE_MAX` | `2` | **`local` mode only.** How many times one pull request is **validated** — the narrower second phase, which asks whether the review's findings were addressed and whether the commits answering them broke anything. Two: one for the commits answering the review, one more for the commits answering the validator. Past it a person decides, and `validate.sh` says so rather than leaving the PR quietly held. The count lives in `v-<pr>.rounds` beside the reviewer's, and a validator that never ran — killed at the deadline, no CLI on `PATH`, a stopped fleet — is **refunded**: a cap that fires early here hands a person a branch nothing validated, which is the one outcome this phase refuses. **Must be a positive whole number.** |
| `AWAIT_REVIEW_MAX_ROUNDS` | `3` | The **agent's** cap, and the only one of the three that is not `AUTOFLEET_`-prefixed — it is read by `await-review.sh` alone and has never had a row here. On the fourth call for one PR the script exits 5 rather than waiting, and the agent stops and says what is unresolved. Per *worktree*, in `.autofleet/run/review-rounds`, and counted only on the path that actually read a review back on this worktree's head — so it undercounts against the reviews a PR really had, deliberately: three CI timeouts in a row must not exhaust the cap without a finding having been seen. That undercount is why `AUTOFLEET_REVIEW_MAX` and `AUTOFLEET_VALIDATE_MAX` exist as well; they are not redundant with it. Its default of `3` is still right under the new shape for a different reason: one review plus two validations is three things an agent waits for. **Must be a positive whole number: a value that is not is refused, and `await-review.sh` exits 2 rather than waiting** — `[ 4 -gt three ]` returns 2, which reads as false, so an unvalidated cap never fires and the agent laps forever. Empty means unset, and the default applies. |
| `AUTOFLEET_REVIEW_MAX_TURNS` | `80` | The reviewer's turn budget, passed as `--max-turns`. The bound it can *see* and spend against, which is what makes "submit before you run out" a budget rather than a hope. `claude-review.yml` grants the same number. |
| `AUTOFLEET_REVIEW_SCOPE` | `full` | What a round-N reviewer is asked to read. `full` is the whole branch, every round. `delta` is `<last reviewed head>..<head>` plus, by the three clauses in the prompt, the surroundings of every change and every caller of anything whose contract it moved. Clause 2 is deliberately **size-aware** — a touched file is read whole only when it is small enough to be, and a large one only around its hunks. Measured on `armaatus/autofleet#105`, rounds 2–6: the full diff each round is 339,928 bytes in total, the delta plus every touched file read whole is 1,228,680, and the delta plus only the small files whole is 112,451. The unqualified form costs more than the thing it replaces. **The default is `full` because [`.claude/agents/reviewer.md`](../.claude/agents/reviewer.md) — which `review.sh` inlines verbatim as the brief — is under a path `merge_gate.py` refuses to let an agent merge**, so the machinery can land before the brief does; a `review.sh` handing out ranges while the brief still said `gh pr diff <N>` would produce a reviewer that read the whole diff anyway. `delta` degrades to `full`, and says which it used, on round one, on a force-push that orphans the last reviewed head, and when the `git fetch` of the PR ref fails. |
| `AUTOFLEET_REVIEW_FULL_EVERY` | `4` | Every Kth round is a `full` review regardless of `AUTOFLEET_REVIEW_SCOPE`, so no pull request is judged by an unbroken chain of deltas. `git diff <last>..<head>` shows lines, not reachability: a round-five commit that changes a helper's exit convention shows three changed lines, and the caller it breaks was reviewed in round one and is not in the delta at all. The prompt's caller clause buys most of that back; this is the backstop for what it misses. `4` means at most three consecutive deltas; `1` makes every round full, which is another way to turn the delta path off. Must be a positive whole number — `0` is a division by zero in the round test. |
| `AUTOFLEET_REVIEW_CONTEXT_MAX` | `16384` | The byte ceiling on the carried-forward context file a `delta` round is handed — the previous round's findings, how they were answered, the threads still open, and the commits between the two heads. It reaches the reviewer as a **file it reads**, never as text spliced into its prompt, because all of it is third-party writing on a pull request and that is what `await-review.sh` already does with a review body. Capped because the complaint this answers is a prompt that grows with the rounds, and an uncapped carried-forward file is that growth wearing a different hat. Each free-text block gets a third of the budget, so one enormous review body cannot push the mechanical sections out. `0` carries nothing forward. |

Every round appends one row to `$FLEET_DIR/reviews/cost.tsv` —
`when / pr / head / scope / input tokens / output tokens / usd / ms / turns` —
taken from the `--output-format json` envelope the reviewer emits. The envelope
never reaches `pr-<n>-<head>.log`, which keeps the reviewer's own words exactly
as before. **It degrades, as far as it can:** `AUTOFLEET_REVIEW_CMD` is a
wrapper seam, and output that does not parse as JSON — a wrapper that ignores
the flag, an envelope whose `result` is empty — is written through as text with
no row recorded. A wrapper that *rejects* an unknown flag is a different case
and this cannot save it: the run is lost, not just the row. The seam already
assumes flag tolerance — `--allowed-tools`, `--max-turns` and
`--append-system-prompt` are passed the same way — so a wrapper that forwards
its arguments is fine and one that filters them was already broken. This is a measurement, not a
gate — nothing blocks on a missing row.

**`cost.tsv` is the one store under `$FLEET_DIR/reviews/` that
`AUTOFLEET_KEEP_REVIEWS` does not prune, and that is deliberate: it *is* the
before-and-after, so a sweep would delete the "before".** It grows by one short
row per reviewed head — under a hundred bytes — so a thousand rounds is under
100 KB. Delete it by hand when a measurement is finished with; nothing reads it
but a person.

**`github`** — [`claude-review.yml`](../.github/workflows/claude-review.yml)
submits it, from that workflow's own account. It needs a
`CLAUDE_CODE_OAUTH_TOKEN` secret on the repository; mint one with
`claude setup-token`.

> Without that secret the job **no-ops with a notice and a green check**, and
> because `merge_gate.py` requires an independent review on the current head,
> every pull request the fleet opens then blocks forever on a review that cannot
> arrive. The agents wait out `await-review.sh`'s 45-minute deadline, three
> times, and the backlog stops. It is the loudest possible consequence of the
> quietest possible failure, which is why `fleet.sh status` names the mode on its
> first screen.

**`local`** — the dispatcher runs the reviewer on this machine
([`scripts/fleet/review.sh`](../scripts/fleet/review.sh), briefed by
[`.claude/agents/reviewer.md`](../.claude/agents/reviewer.md)) and submits with
`gh pr review`. Same policy, same `REVIEW.md`, same trailers.

#### What `local` gives up, exactly

The reviewer signs in as whoever `gh` is logged in as, which is normally the same
account that opened the pull request. So independence stops being something
GitHub can attest to and becomes something the fleet asserts:

|  | `github` | `local` |
|---|---|---|
| Reviewer's context | fresh | fresh |
| Reviewer's identity | a different account | **the author's account** |
| What proves it | GitHub's own author field | a marker in the review body |
| `--request-changes` | available | **refused by GitHub** — see below |
| Reviewer's credential | an Actions token, scoped by the job's `permissions:`, in a container that is then destroyed | **your own `gh` login**, reaching every repo and org that account can |
| Inline comments | yes (`gh api` is granted) | no — `gh api` is deliberately **not** granted, so findings go in the body |
| The validation | [`validate.yml`](../.github/workflows/validate.yml), on `synchronize` | [`validate.sh`](../scripts/fleet/validate.sh), started by the dispatcher — the same brief, the same trailer, and it can run the project's test command, which the workflow reaches through its own runner |
| `AUTOFLEET_REVIEW_MAX` / `AUTOFLEET_VALIDATE_MAX` | **not applied** — `review_open_prs` returns early unless the mode is `local`, so the dispatcher starts nothing to cap. The phases still run, as `claude-review.yml` and `validate.yml`; what is missing is a cap on how many times | applied |

The last two rows are new and point the other way from the rest: this is `local`
having something `github` does not. Both belong here for the reason the section
already gives about `--request-changes` — a control that is documented and
silently inapplicable is worse than one that is absent. `REVIEW.md`,
`.claude/agents/reviewer.md` and [WORKFLOW.md](WORKFLOW.md) all state the floor
without a mode qualifier, because a reviewer reads them without knowing which
mode started it; the fallback is what makes that safe, and this table is where
the difference is recorded.


**The reviewer runs as you.** That is the row above with the widest blast
radius, and it is not narrowed by `guard.py`: the reviewer runs from the repo
root precisely so that the fleet-worktree rules do not apply to it, which is what
lets it submit at all. So the ceiling on what it can do is its **tool allowlist**,
and that is why `Bash(gh api:*)` — which `claude-review.yml` does grant — is
withheld here. What is left can read the tree, read the pull request, and submit
one review. It is an agent reading a diff written by somebody else; the prompt
hardening in its brief is a mitigation, not a boundary, exactly as with the guard
above.

**`--request-changes` does not exist in `local` mode.** GitHub will not accept
`CHANGES_REQUESTED` on a self-authored pull request (*"Review Can not request
changes on your own pull request"*), and here the reviewer is the author's
account. So `merge_gate.py`'s "the latest review still requests changes"
condition is unreachable, and `<!-- review-findings: N -->` is the only lever
holding the branch. It is enough — any `N` above zero blocks the merge until the
author answers — but a control that is documented and silently inapplicable is
worse than one that is absent, so it is written down here, in
[REVIEW.md](../REVIEW.md) and in the reviewer's brief.

`<!-- review-important: M -->` rides alongside it and is **not** a second lever:
it holds nothing and releases nothing. It exists because the verdict type used
to carry severity and in this mode cannot, so with `N` alone every reader
downstream saw "five nits" and "one data-loss bug" as the same integer. What `M`
buys is the *instruction*: at `0`, `await-review.sh` tells the agent that
`answer-review.sh` discharges the hold with no commit, where a fix would move the
head and buy the next round. Omitting `M` is read as "did not say", never as
zero. This was found by the
local reviewer being unable to submit its own verdict.

`merge_gate.independent_reviews()` normally discards anything the PR's author
submitted. In `local` mode it accepts one **iff** the body carries
`<!-- independent-review: local <head-sha> -->` for the current head. That is a
checklist gate, exactly as `record-review.sh` is, and three things keep it
meaningful:

1. **Opt-in per repository.** The knob lives in `.autofleet/config`, and
   `install.sh` normalises a freshly seeded config back to `github` so no host
   project inherits the weaker mode by accident.
2. **Read from the base ref.** `merge-gate.yml` sparse-checks-out
   `.autofleet/config` at `pull_request.base.sha`, so a PR cannot switch its own
   repository into the weaker mode as part of the change that mode is judging.
3. **Out of the ordinary reach of the author.** `guard.py` refuses, from a
   fleet-owned worktree, every way to submit a review it can recognise:
   `gh pr review`, `gh api .../pulls/N/reviews`, the `addPullRequestReview` and
   `submitPullRequestReview` GraphQL mutations — and any `gh api` carrying a
   body it cannot read (`--input`, `@file`), because a payload this hook cannot
   inspect is one it cannot judge.

   *Recognise* is the operative word, and it is not a synonym for *all*. This
   list has grown twice, each time because a review found a spelling that walked
   past it — first the REST name, then GraphQL, then a body in a file. Treat it
   as the set of mistakes caught so far, not as a proof. The dispatcher runs the reviewer from the repo root, which is not a
   fleet worktree, which is how it still submits.

   *Reach*, not *possibility*: this is a hook over a command line, not a
   capability boundary. It stops an agent that drifts into reviewing itself and
   an agent that follows an instruction planted in a diff. It does not stop an
   agent that sets out to defeat it, and the summary below says so. The first
   two spellings shipped guarded; the third did not, and the independent review
   of that change found it.

`local` **adds** a way to satisfy the requirement; it never removes the strong
one. A review by a different account still counts, with no marker at all.

The honest summary: `local` protects against an author's blind spots, which is
what the second opinion is actually for. It does not protect against an author
determined to forge one. If you need that, keep `github`, or give the reviewer
its own account and log `gh` in as that.

#### The self-review's own knobs

Separate from the independent reviewer's above, because the two runs are shaped
differently — one reads a pull request through `gh` and submits a verdict, the
other reads a local commit range and prints findings — and a project that wants a
cheaper model for its own diff than for the verdict on it has to be able to say
so.

| Knob | Default | Notes |
|---|---|---|
| `AUTOFLEET_SELF_REVIEW_CMD` | `$AUTOFLEET_REVIEW_CMD` | What runs each pass, with `-p`, a fixed tool allowlist and a `--disallowed-tools` deny list. The deny list is the half that binds: `--allowed-tools` is **additive** — it grants on top of `.claude/settings.json`, which permits `Write`/`Edit` under `.claude/agents/` by design — so the absence of a tool from the grant is not a ceiling. Defaults to the independent reviewer's command, so a host that has set nothing — and a host that has set only `AUTOFLEET_REVIEW_CMD` — still works. |
| `AUTOFLEET_SELF_REVIEW_TIMEOUT` | `1200` | Seconds **one** pass may run before it is killed. Lower than the independent reviewer's `1800` because there are two of them and they are spent out of the agent's `AUTOFLEET_TIMEBOX`, not out of the dispatcher's poll. A pass killed here is reported as a **failure**, never as "no findings". **Must be a positive whole number**, for the reason the `MAX_TRIES` row gives: a non-number makes `[ N -ge X ]` return 2, the deadline test false, and a wedged pass then holds the worktree until the time-box expires. A bad value is refused, and because this file is sourced the refusal ends every fleet command that reads it, `stop.sh` included. |
| `AUTOFLEET_SELF_REVIEW_MAX_TURNS` | `80` | Each pass's turn budget, passed as `--max-turns`. The same number the independent reviewer and `claude-review.yml` get: both passes fan out into sub-agents of their own. Validated the same way as the timeout above. |

> **A pass that produces nothing records nothing.** `self-review.sh` exits
> non-zero, names the pass that was silent, and writes no marker — so the push
> gate stays closed. Recording an empty marker would satisfy that gate and let a
> pull request go out claiming two reviews that never ran, which is strictly
> worse than a review that is merely absent.
>
> A pass counts when it **exited zero** and its **stdout is not blank** — and
> the load-bearing word is *stdout*. #51 measured the failure this catches: exit
> 0 with 446 bytes of output, all of it unrelated permission warnings. Those
> warnings are on stderr. `self-review.sh` writes the two streams to different
> files, so stdout carries the pass's final message and nothing else; merge them,
> as `review.sh` does, and noise is indistinguishable from a verdict.
>
> The passes are *asked* to end with `<!-- self-review-findings: N -->`, and the
> count is worth having in the PR body, but it is **not** a gate: measured over
> three rounds, `/code-review` emitted it zero times out of three. It is a
> harness skill with an output contract of its own, and a gate it cannot pass is
> a gate that never opens.
>
> `self-review.sh` refuses a **dirty working tree** for the same reason: the
> marker is keyed on `HEAD` and `HEAD` is what gets pushed, so uncommitted work
> would be neither reviewed nor sent. Commit first.

> Like `AUTOFLEET_REVIEW_CMD`, this seam is advertised as model-agnostic and is
> not: the flags are Claude Code's. That is
> [#27](https://github.com/armaatus/autofleet/issues/27), open against
> `review.sh`; `self-review.sh` is deliberately a second consumer of the same
> shape rather than a third convention, so one fix covers both.

### The handoff note

One session covers the plan, the implementation, both self-review passes, the
push, the PR, the review and up to two validations, inside one `AUTOFLEET_TIMEBOX` and
one context window. When the dispatcher interrupts that worktree, or
`./scripts/fleet/fleet.sh retry N` hands the issue back, the next attempt used
to begin from the issue body alone and re-derive from the files every decision
the first one made. `scripts/fleet/handoff.sh` is the note that carries those
decisions across, and the opening brief asks for it in both halves — when the
work is put down, and at the push and after every review round:

```bash
./scripts/fleet/handoff.sh write 42 --stdin <<'NOTE'
...
NOTE
./scripts/fleet/handoff.sh          # print this worktree's note
```

It holds the decisions taken and why, the files touched, what each review round
said and how it was answered, and what is still open — not the plan, which is in
the PR body, and not the diff.

Two things read it back. `issue-command.sh` prints it **between the issue's
spec and the brief** in the next session **in that worktree** — which is the
case it is for and the one that always works; the `resumed` test phase asserts
that ordering, so a session gets the spec, then what the last attempt left, then
its marching orders. `./scripts/fleet/fleet.sh retry N` names it by absolute path when
you hand the issue back, so a second worktree opened alongside a first one still
standing can be pointed at it. The dispatcher's own opening prompt names it too,
in a narrower state than either — `handoff_note_for` in `scripts/fleet/fleet.sh`
is where that is argued, and `retry` is the line to read.

**It lives at `.autofleet/run/handoff-<issue>.md`, and it dies with the
worktree.** That directory is gitignored and per worktree: the note survives a
session restart *inside* the worktree, which is the case it exists for, and it
goes when the worktree is reaped. It is not durable storage and nothing backs it
up. That is deliberate rather than unfinished — a note that outlived its
worktree would be read by an attempt working from a different tree, telling it
which files were touched in a tree it cannot see.

| Knob | Default | Notes |
|---|---|---|
| `AUTOFLEET_HANDOFF_MAX_WORDS` | `300` | How long the note may be. Over it the script **refuses and changes nothing** rather than truncating: a note cut off at the sentence that said what is still open reads exactly like one where nothing was. Unbounded, the note grows into a second spec the next attempt reads in full before its first edit, which is the cost it exists to remove. `0` turns the cap off. **Must be a whole number**: a value that is not is refused, and because this file is sourced the refusal ends every fleet command that reads it — a non-number would otherwise make the comparison error out, the cap never fire, and the guard be absent with nothing on screen saying so. |
| `AUTOFLEET_CONTEXT_RESET` | `on` | **A session per phase, not per issue.** One agent session used to span the build, the PR, the wait, the answer and the validation, so every file read while building stayed in context and was re-billed on every turn afterwards — sessions were measured past 900,000 tokens, most of it a build nobody was still reading. The pull request is the seam: once it is open the build is done, and what the answering work needs is the review, the diff and what the build decided. So the dispatcher asks for the handoff note, drops the conversation, and hands the answering half of the brief to a session that starts from the note. `off` keeps the one-session shape, which is what a host wants when its agent CLI has no way to drop a conversation from the terminal — the same thing as setting `AUTOFLEET_AGENT_CLEAR_CMD` empty, said twice because a host should not have to discover the equivalence. **Must be `on` or `off`**: anything else fails in the safe direction (no reset) and would do it silently, so it is refused instead — a host that wrote `true` would go on paying for 900k contexts with no way to find out. |
| `AUTOFLEET_AGENT_CLEAR_CMD` | `/clear` | What drops the conversation, typed into the agent's terminal like any other prompt. `/clear` is Claude Code's; a host on another CLI puts its own here. **Empty turns the reset off, and says so in the log** rather than resetting nothing quietly: an unrecognised command typed at an agent is a turn spent on a syntax error, and the next thing to arrive is the answering brief, which the agent would then answer with its whole build still in front of it — the one-session shape plus a wasted turn, which is worse than either. Note the default uses `=` and not `:=`, alone with `AUTOFLEET_COST_ROOT`: empty is a *setting* here, and `:=` handed it back the default. |
| `AUTOFLEET_HANDOFF_GRACE_SECONDS` | `120` | How long an agent gets to write its handoff note before the thing that asked for it takes the terminal away. Three callers, all ending a session: the context reset above, the time-box, and the reaper's warning pass. Before this they interrupted first and asked nothing, so an interrupted attempt wrote nothing down — the half of the handoff note's purpose that its mere existence did not deliver, because a note needs a *turn* to be written in. It is spent **across polls, not inside one**: the dispatcher asks, records when it asked, and decides on a later pass. A version that slept the grace inside the pass stopped the whole dispatcher for two minutes per issue — with three worktrees, six minutes in which no review is collected and no time-box fires. It is a ceiling, not a wait: the moment the note's timestamp *moves*, the caller goes on. `0` does not ask at all, which is the behaviour before this knob existed. **Must be a whole number of seconds.** |

### What the fleet keeps

Every store under `$FLEET_DIR` only ever grew until these two knobs arrived, and
the cost is not the bytes: stale state gets read as current. A transcript named
for a head nobody is reviewing is a file the next reader opens looking for an
answer. Set either to `0` to keep everything, which is what a host project
debugging its own reviewer wants.

| Knob | Default | Notes |
|---|---|---|
| `AUTOFLEET_KEEP_REVIEWS` | `3` | Reviewer transcripts kept **per open pull request**, and the off switch for the `reviewed-<sha>` sweep too, so `0` means every piece of review state the dispatcher would otherwise delete. |
| `AUTOFLEET_LOG_MAX_BYTES` | `1048576` | Bytes of `fleet.log` kept before it rotates to `fleet.log.1`. **One** generation, because the point is a bound and two files at the cap is twice the cap. |
| `AUTOFLEET_LOG_PASSES` | `off` | `on` and the dispatcher writes one line per poll saying the pass ended and what it found; anything that is not `on` or `off` is refused at startup rather than read as one of them (`0` used to turn it **on**). **Off by default** — a line a minute is the log volume the say-once markers exist to prevent — and the only way to know a pass has finished without guessing from a clock. Turn it on when you are measuring what a pass costs (see [WORKFLOW.md, "What one poll costs"](WORKFLOW.md)) or watching a fleet that appears to be doing nothing. |

**What goes, and when.** Older transcripts for an open PR go; every transcript
for a PR that is no longer open goes regardless, because a review of a closed PR
is answering a question nobody is asking. Never on the pass the PR drops off the
open list, though, and never while a reviewer for it is still writing: the sweep
keeps one bookkeeping file per closed PR, `reviews/.closed-<n>`, recording that
it was already seen closed on an earlier pass, and collects that file as soon as
the transcripts it tracks are gone.

**What it costs.** `review_open_prs` runs the sweep from the open list it already
has, plus **one `gh pr view <n> --json state` per candidate pull request per
pass** — per pull request, not per transcript, and only after a whole grace pass.
The open list is `--author "@me"`, which is right for deciding whom to review and
wrong for "is this PR still open": on a host whose worktrees open PRs under a
different account than the dispatcher's `gh` login, absence from it would mean
every PR looked closed. Anything but a confident `CLOSED`/`MERGED` keeps the file.
An `OPEN` answer returns the PR to the open list for the rest of that sweep, so
its transcripts are capped like any other open PR's rather than accumulating with
nothing to trim them — and drops the `.closed-<n>` marker, so the question is
asked again on the pass after next rather than on every one. The sweep says how
many it took.

**The review records go the same way.** `$FLEET_DIR/reviewing/` holds four small
records per pull request beside the reviewer's lock — `.done`, `.tries`,
`.rounds` and `.said` — and the same four again under a `v-` prefix for the
validator; what each one holds is written out once, in `scripts/fleet/fleet.sh`'s
header above `is_review_record`, and not restated here. What a host operator
needs from this page is that they are swept on **the same rule and through the
same code** as the transcripts above — `pr_sweep_verdict`, which both call: not
on the pass the PR drops off the open list, not without a confirming
`gh pr view <n> --json state`, and one decision per pull request per pass rather
than one per file, with `reviewing/.closed-<n>` as that sweep's bookkeeping. Two
things are NOT shared, and both are deliberate. A PR whose reviewer is still
running is skipped by the transcript sweep and not by this one — the record
sweep only ever reaches a PR GitHub has confirmed closed, and a reviewer still
writing against one of those is finishing work on a PR that is already gone. And
`<pr>.rounds` outlives a `stop.sh`: it counts what the PULL REQUEST has cost
rather than what this dispatcher's run has, nothing re-derives it, and clearing
it on a restart would hand every open PR a fresh set of rounds — the cap not
existing for anybody who restarts the fleet. The record sweep described here is
what prunes it, once the PR has closed. The protection is not decoration — the
file at stake is `<pr>.done`, and a `.done` deleted under an open PR hands that
head a reviewer every poll.

**The rotation** is `mv` rather than truncate-in-place, and **not while a
reviewer is running** — `review.sh` is spawned with `>>` on `fleet.log` and holds
the inode for up to `AUTOFLEET_REVIEW_TIMEOUT`, so rotating under it sends its
output to a file nobody reads and the next rotation unlinks what it is still
writing. The dispatcher's own writes are `tee -a`, fresh per call, and follow a
rename without noticing. So the cap is a bound the fleet reaches **between**
reviews, not a hard ceiling: on a busy fleet the log can sit above it until the
reviewers finish. If the rotation cannot happen at all — a read-only state
directory, an undeletable `fleet.log.1` — it says so once per dispatcher, and
again after a rotation that works.


### What a run costs

`./scripts/fleet/fleet.sh cost` reports what each issue's worktree spent, read
back out of the agent CLI's own session transcripts — no extra instrumentation,
because the CLI already wrote the answer.

```
issue  sessions  input  output  cache read  cache write
   48         3    170  23,340   2,898,820      102,120
   52         1     48  24,838   2,024,487       89,837
-----  --------  -----  ------  ----------  -----------
total         4    218  48,178   4,923,307      191,957
```

`--json` prints the same figures for something that is not a person, which is
the point: these numbers are only useful compared across runs.

| Knob | Default | Notes |
|---|---|---|
| `AUTOFLEET_TRANSCRIPT_DIR` | `~/.claude/projects` | Where the agent CLI writes one JSONL per session, under `<root>/<cwd-slug>/<session-id>.jsonl`. Set it **empty** to turn the report off — one explanatory line, exit 0. |

It moves the **path**, not the format. `cost.sh` reads a fixed entry shape
(`type: assistant`, `message.usage`, the four token keys) and a fixed slug rule,
so a host whose CLI writes that shape somewhere else points this at it — and a
host whose CLI writes something else entirely sets it empty rather than getting
a report of zeros.

`scripts/fleet/cost.sh`'s header is the authority on how the report reads a
transcript; this section describes the same rules for whoever is setting the
knob, and if the two disagree, this one is wrong.

**The four figures are never added together.** A cache read is roughly a tenth
of an input token, so a run that looks expensive on `input` may be almost
entirely cache, and one total would hide exactly the difference the report
exists to show.

**What ties a session to an issue** is the worktree path. The slug is the
absolute working directory with every non-alphanumeric character turned into
`-`, truncated at **200** characters with a hash of the path appended past that
— a slug over the cap is matched on its prefix, and a prefix that matches more
than one directory identifies none of them and is reported rather than guessed.
`own()` records each issue's path under `$FLEET_DIR/ran/<issue>` —
*appended*, so an issue that `retry` ran twice is measured across both
worktrees, and deliberately *not* cleared when the worktree is released, or the
report would empty itself exactly when a run finishes. One short file per issue
the fleet ever starts.

**Subagent transcripts count.** A subagent writes its own file under
`<session-id>/subagents/`, and this repo uses them per issue — the researcher,
and the review pass `/implement` runs before it commits. They are folded into the
four token figures; `sessions` counts the top-level sessions only, so it stays the
number of times an agent *produced* something in that worktree — a session
interrupted before its first assistant message carries no `usage` and is not
one.

**It never fails a run.** No transcript root, a root that is not there, a
worktree already reaped, an entry with no `usage`, a half-written last line in a
transcript a live agent is still appending to: each costs one line on stderr and
exits 0. Explanations go to stderr in both shapes, so `--json` on stdout stays
machine-readable.

**What it does not see.** Only sessions whose working directory was the worktree
itself. A reviewer run from the main checkout (`AUTOFLEET_REVIEW_MODE=local`)
lands under the main checkout's slug, not the worktree's, so its tokens are not
in that issue's row.

### Compressing what the agents read

Off by default, and off costs nothing. At `AUTOFLEET_HEADROOM=0` — the default —
nothing is exported, nothing is probed, and there is nothing to install, which is
what keeps CLAUDE.md's "no build step, no dependencies to install" true for a
repository that never touches this.

At `1`, the fleet points the model calls **it makes itself** at a local HTTP
proxy that compresses what the agent *reads* — tool output, logs, file reads,
JSON, diffs — before those tokens are counted. It exports two variables:

```
ANTHROPIC_BASE_URL=$AUTOFLEET_HEADROOM_URL
ENABLE_TOOL_SEARCH=true
```

| Knob | Default | Notes |
|---|---|---|
| `AUTOFLEET_HEADROOM` | `0` | `1` points fleet-started model calls at the compression proxy. `0` changes nothing anywhere. |
| `AUTOFLEET_HEADROOM_URL` | `http://127.0.0.1:8787` | Where the proxy answers. **One host-level port**, shared by every worktree on the machine — deliberately not a per-worktree port out of `AUTOFLEET_PORTS`, and deliberately not in `.env`, which derives per-worktree values from the worktree path. |

`./scripts/fleet/fleet.sh status` says which of the three states you are in: off,
on and answering, or on and not answering.

**It degrades, loudly, and never blocks.** Before it exports anything the fleet
opens a TCP connection to that URL. If nothing answers it prints one line naming
both the URL and the knob and runs the agent **unwrapped, at full token price**.
A dispatcher that refuses to dispatch because an optional optimiser is down is a
worse failure than one expensive pass.

**The fleet probes the proxy and never spawns it.** Starting and stopping the
daemon is yours; a dispatcher that owns a daemon's lifecycle is a dispatcher that
can fail to start for a reason that has nothing to do with the backlog.

#### What it covers, and what it does not

The three model calls the fleet starts as a **direct child** of one of its own
scripts:

| Call | Script | Started by |
|---|---|---|
| the independent review | `scripts/fleet/review.sh` | the dispatcher, in `AUTOFLEET_REVIEW_MODE=local` |
| the validation | `scripts/fleet/validate.sh` | the dispatcher |
| both self-review passes | `scripts/fleet/self-review.sh` | the agent, in its worktree |

A fourth call site added without the export would be a knob that silently
measures a fraction of what this page says it does, so **`evals/lint.sh` fails**
on any shell file anywhere under `scripts/fleet/` that runs a
`$AUTOFLEET_*_CMD` in command position
and contains no call to the seam. It is in `evals/` rather than `tests/` because
`evals/` is vendored: a host project gets the guard along with the thing it
guards.

What it does **not** catch, named here rather than left to be discovered: it is
**per script**, not per call, so a script that goes through the seam once and
then gains a second, unwrapped call still passes; it reads the command word, so a
call captured into a variable (`out="$($AUTOFLEET_REVIEW_CMD …)"`) or a literal
`claude -p` that bypasses the knob entirely is invisible to it. Both need a shell
parser. `evals/shell_code.py --selftest` records the shapes it does and does not
see, and `lint.sh` runs that selftest before trusting the scan.

It does **not** cover the worktree agent. That process is started by the runtime,
not by `fleet.sh`, and it does not inherit the dispatcher's environment. On the
Orca driver the agent's terminal is a child of the Orca app, not of the
dispatcher — `printenv` inside a fleet-opened worktree shows no `AUTOFLEET_*` at
all, and the process tree runs `Orca Helper → login → zsh → bash → claude` with
`fleet.sh` nowhere in it. The `runner_*` contract in [RUNNERS.md](RUNNERS.md) has
no environment parameter, and this knob did not add one.

To cover the worktree agent, wrap `claude` on the machine instead. This is
durable and global to your user, which is why it is a person's step and not the
fleet's:

```bash
headroom wrap claude      # starts the proxy, sets ANTHROPIC_BASE_URL and
                          # ENABLE_TOOL_SEARCH for `claude` from now on
headroom unwrap claude    # undo the durable part
```

**The two overlap, and `wrap` wins. Pick one.** `wrap` is durable and global to
your `claude`, and the reviewer, the validator and both self-review passes all
run `claude` by default — so on a wrapped machine those three go through the
proxy whatever `AUTOFLEET_HEADROOM` says, and the knob adds nothing there but the
`status` row. Worse, its degrade line becomes **untrue**: if the proxy dies,
`fleet_headroom_env` prints "running unwrapped, at full token price" and takes
its own exports back, but a wrapped `claude` is still pointed at the dead proxy
through its own settings and its model call fails anyway. `fleet.sh status` is
reporting the knob's state, not the wrap's.

So:

- **Want the worktree agent covered?** Use `wrap`, and leave `AUTOFLEET_HEADROOM`
  at `0`. `headroom doctor` is then the thing that tells you the proxy is down.
- **Want the probe, the degrade and the `status` row?** Use the knob, and leave
  `claude` unwrapped. The worktree agent pays full price; #130 is the issue that
  would close that gap properly.
- Setting both is the "two mechanisms for one behaviour" outcome this seam was
  written to avoid.

#### Installing it

```bash
uv tool install --python 3.13 "headroom-ai[all]"   # or: pip install "headroom-ai[all]"
headroom proxy --port 8787
```

The npm package of the same name is SDK-only and ships no CLI.

**On "compression runs locally", from observation rather than from the README.**
Started here, the proxy's own banner reports `Telemetry: DISABLED`, `Security:
loopback-only (no inbound token)` and `License: OSS`, and its savings ledger is a
local JSONL under `~/.headroom/`. But `lsof` on the proxy process during a run
that sent **only** Anthropic traffic also showed connections to Google and CDN
addresses — its routing table carries upstreams for other providers, so
connection-pool warmup is the obvious explanation, and it was not established
what, if anything, was sent over them. If you need a hard "nothing leaves this
machine" guarantee, verify it yourself before turning the knob on. At `0` the
proxy is never contacted at all.

#### What a custom base URL costs you

All three are Claude-side and apply to **any** non-default `ANTHROPIC_BASE_URL`,
not just this one. Turning the knob on trades them away:

- **Claude Remote Control is unavailable** in a proxied session.
- **Server-managed settings are not fetched.** Anthropic skips that fetch for any
  non-default base URL. The OS-level `managed-settings.json` is unaffected — it
  is read from disk.
- **`/context all` misreports** without `ENABLE_TOOL_SEARCH=true`, which is why
  the knob sets it alongside the base URL rather than leaving it to you.

#### What it is worth here

Savings scale with how repetitive the payload is: repeated JSON and log lines
clear 90%, prose and already-dense output compress very little. This fleet's
traffic is a mix — issue bodies and PR bodies are prose, `gh` JSON, test output
and diffs are not — so the number that matters is a measured one for this
repository, not the vendor's.

Measured here on one read-only pass over a real pull request (its body, its diff,
the issue it closes, the files it touches, `git log`), run twice with the same
prompt and the same tool allowlist. **Not a `review.sh` run**: `guard.py` refuses
that from a fleet-opened worktree, which is the rule working, so the pass reads
everything a review reads and submits nothing.

| | unproxied | through the proxy |
|---|---|---|
| billed cost | $5.4725 | $2.7213 |
| cache read | 3,476,688 | 1,659,126 |
| cache creation | 330,435 | 131,728 |
| output | 17,183 | 22,969 |
| turns | 28 | 31 |
| wall clock | 248s | 350s |

The proxy's own ledger for that traffic: **8.8% compressed, 133,864 of 1,529,329
tokens over 22 calls** — below the vendor's published 21–57%, which is what a
prose-heavy mix predicts. Read the two numbers separately: **8.8% is what
compression is worth here**, per payload and deterministic. The halved bill is
one sample, it also carries whatever `ENABLE_TOOL_SEARCH=true` is worth on its
own, and the two runs are not byte-identical (28 turns against 31). **Output
tokens and wall clock both went up.** Measure your own traffic before you assume
either figure.

**Any Anthropic-compatible compressing proxy satisfies this seam.** Nothing under
`scripts/fleet/` imports headroom, probes for its CLI, or reads a file of its:
the mechanism is two environment variables and a TCP connect. The knob carries
the name because a dependency is named rather than hidden, not because the code
knows about it — and `evals/lint.sh` **runs** that rule rather than quoting it,
so a `command -v headroom` added anywhere under `scripts/fleet/` later fails the
build. It scans that directory and not the rest of the payload, which is where
every line of this seam lives.

The probe is strict about the URL on purpose: **no scheme or no host reads as
unreachable**, so `AUTOFLEET_HEADROOM_URL=localhost:8787` (no `http://`) and an
empty value both degrade loudly instead of being probed against port 80 of your
own machine and then exported as a broken base URL.

If the proxy dies between two calls in one process — the two self-review passes
are minutes apart — the second call **puts back whatever was there before**
rather than leaving the agent pointed at a dead endpoint.

**If you already have your own `ANTHROPIC_BASE_URL`, the knob replaces it while
the proxy is up.** It is recorded and restored, so it is not lost — but for as
long as the proxy answers, the fleet's calls go to the proxy and then wherever
*it* sends them upstream, **not through your gateway**. If that gateway is doing
your authentication, your compliance logging or your egress control, that is the
thing to know before setting `AUTOFLEET_HEADROOM=1`, and the reason to point
`AUTOFLEET_HEADROOM_URL` at a proxy you have configured to forward through it.

**Keep a non-loopback URL on `https://`.** The probe accepts any `http://` host,
and whatever the knob exports is where `claude` then sends its credential — so
`http://proxy.corp:8787` puts an API key or OAuth bearer token on the wire in
cleartext for anything between here and that host. The default is loopback,
where that does not apply; the moment the proxy is not on this machine, it does.

### Per-worktree isolation

A worktree's identity is a pure function of its absolute path: a slug, an offset,
and a project name. Teardown **recomputes** it rather than reading `.env` back,
because `.env` is generated by a hook that is itself allowed to fail half way,
and a port nothing can re-derive is a port nothing can release.

| Knob | Default | Notes |
|---|---|---|
| `AUTOFLEET_PROJECT_PREFIX` | `af` | Must be unique to this project on this machine: `reap.sh` sweeps stacks matching it whose worktree is gone. |
| `AUTOFLEET_PORTS` | *(empty)* | `name:base` pairs, e.g. `API:21000 PROXY:23000`. Each worktree gets `base + offset`, written to `.env` as `NAME=<port>`. |
| `AUTOFLEET_PORT_SPAN` | `2000` | The modulus the offset is taken over, and therefore the width of each range above. Bases must be at least this far apart. |
| `AUTOFLEET_COMPOSE_FILE` | *(empty)* | Empty means this project runs no containers, and teardown skips docker entirely. |
| `AUTOFLEET_COMPOSE_DOWN_ARGS` | *(empty)* | Your `--profile` flags. **Getting this wrong leaks**: `down` only touches services whose profile is active, so an inactive one survives teardown, comes back under `restart: unless-stopped`, and holds a port with no directory left to identify it by. |

### The rest

`AUTOFLEET_RUNNER` (`orca`) — see [RUNNERS.md](RUNNERS.md). A name with no
`scripts/fleet/runner/<name>.sh` beside it is named where `lib.sh` sources it —
the file it looked for and the drivers that do ship — and stops the four scripts
that call `fleet_require_runner`; `evals/lint.sh` goes red on it, so a typo here is
caught before a worktree is opened rather than by an agent sitting on a prompt
that never sends.
`ORCA_CLI_COMMAND` (Orca driver only) — the CLI to try first, ahead of `orca`,
`orca-dev`, `orca-ide` and the `/Applications` fallback. **Exactly one command**,
so a path containing spaces is a single candidate and a value with arguments in
it (`orca --debug`) is not a command at all: nothing on `PATH` has that name, the
candidate is turned down, and the resolve falls through to plain `orca` — a
different CLI from the one that was configured. It used to be expanded unquoted,
where the same value was two candidates that both failed. The driver's refusal
names this knob, so it is listed here rather than left in
`scripts/fleet/runner/orca.sh`, and it has no default line in `config.sh` but is
settable in `.autofleet/config`, which `config.sh` sources into the same shell
before `lib.sh` sources the driver.
`AUTOFLEET_SETUP_HOOK` / `AUTOFLEET_TEARDOWN_HOOK` — paths to the two hooks.
`AUTOFLEET_TEST_COMMAND` — quoted into the agent's opening prompt, so it names
the command your project actually runs rather than one autofleet guessed.
`AUTOFLEET_NOTIFY_TITLE` — the title on the macOS notifications the dispatcher
posts.
`AUTOFLEET_DIR` (env only, `~/.autofleet`) — where `STOP`, `DRAIN` and the owned-
worktree registry live. Outside every worktree on purpose: a stop that only some
processes can see is not a stop.

## `.autofleet/setup.sh`

Runs once per worktree, from the repo root, with `.env` already exported and
`FLEET_OFFSET` available. **Its exit status is provisioning's exit status** — a
non-zero exit fails the worktree loudly rather than handing an agent a broken
rig, which is the failure mode `wait-for-setup` exists to prevent.

This is where containers, fixtures, a build, a venv, seeded data all go.

## `.autofleet/teardown.sh`

Runs before the stack comes down, from the repo root, when a worktree is removed.
Never fatal: the runner is removing the worktree either way, and a hook that
exits non-zero must not stop the stack removal, which is the part that leaks if
it is skipped.

## `.autofleet/guard.json`

What `guard.py` refuses to write in **this** repo, over and above its universal
rules (merging a PR, force-pushing the default branch, editing `unblock.yml`,
editing `.env`, and — in a fleet worktree only — editing the hooks themselves).

```json
{
  "protected_paths": [
    {"path": "server/contract/captures/",
     "tail": "captures/",
     "reason": "the pinned API contract a test diffs a live probe against"}
  ],
  "secret_suffixes": ["/config.ini"],
  "secret_contains": ["/token.dat"],
  "secret_tails":    ["token.dat", "config.ini"]
}
```

`reason` is the whole value of a `protected_paths` entry: "blocked" with no *why*
sends the agent looking for a way around it. `tail` is how a relative path after
a `cd` is still recognised — suffix-matching a distinctive tail is imperfect, and
the module docstring says so.

A malformed file is **fatal**, not ignored. A guard that silently falls back to
"protect nothing" on a typo reports success on every write it was installed to
stop.

A *well-formed* file with a mistyped key is the same failure wearing a nicer
suit: `guard.py` reads every key with `.get()`, so `protected_path` is not an
error, it is no rule at all. `evals/lint.sh` reads the keys `guard.py` actually
reads and fails the build on a key in this file that is not one of them, and on a
rule declared here that does not reach the tuple `guard.py` enforces.

## The ceilings

Some of what the fleet costs is text: the working agreement, the opening brief,
the review policy, what a test run prints, what a review round hands back. All
of it is read by an agent whose context has to survive a plan, an implementation
and three review rounds — and prose grows back one useful paragraph at a time.
The opening brief reached 1,521 words that way and nothing objected at any
single step.

So every one of those limits is a row in the **ceilings table at the top of
[`evals/lint.sh`](../evals/lint.sh)**, and each row carries five fields:

| Field | What |
|---|---|
| name | the key `ceiling <name>` is called with |
| limit | the number, and the only copy of it. The **last allowed** value, on every row |
| issue | the issue that set it. Every row cites one |
| what is measured | the membership, so a limit and its contents cannot drift apart |
| what measures it | a `; `-separated list of `evals/lint.sh` and `tests/test_<suite>.sh <phase>` entries — **every** place that reads the number, not just the first |

The rows are `claude-md` and `reading` and `brief` — the text an agent reads
before its first edit — `spec`, the room `reading` leaves for the issue body it
is handed, `handoff`, the note a resumed session is handed ahead of the brief,
and `testrun` and `round`, which bound what a green test run and one clean
review round print back. `spec` is the one that is not a limit on autofleet's
own text: an issue body is the maintainer's, and the row is the allowance the
payload leaves for one. **No figure is written here, or in any comment.**
The table holds the limit; the checks print what they measured. A measured
number written into prose is stale by the next commit.

Some rows bound the OUTPUT of a script rather than the contents of a file,
because a ceiling has to be measured from what the agent *receives* — a check
that reads the source counts words the agent never sees and misses the ones
`sed` substitutes in. Those are measured by a test phase that runs the script,
so a host installation, which does not vendor `tests/`, gets the rows
`evals/lint.sh` measures and the numbers for the rest. Which is which is the
table's fifth field, and is not counted in prose here: "three of the rows" was
written when there were six and stayed after there were seven.

### Raising one

**Raising a ceiling is allowed, and it is the point.** Edit the row's second
field. That is one line in a diff, reviewed like any other change, rather than a
paragraph nobody notices — and a lint that cannot be raised is one that gets
deleted the first time it is inconvenient. Say in the PR body what the room was
bought for.

Two things to know before you do:

- **A number that moves on the branch alone has not moved.**
  `.github/workflows/agent-config.yml` re-runs *main's* copy of the lint against
  the branch, so the old ceiling is still the one in force until the change
  lands. Paying for the words instead — tightening something else — is usually
  faster than arguing with that, and it is what the brief did when it tried to
  buy a sentence at 425 words.
- **Nothing may restate the number.** A row measured by a test phase reads it
  through `tests/ceiling.sh`; `evals/lint.sh` reads its own through `ceiling`.
  The `== the ceilings` check fails the build if a row cites no issue, names a
  phase the runner never calls, or is a number nothing reads.

Adding a row is the same edit plus the check that measures it — a row with
nothing behind it is a ceiling that has already stopped holding.

**A ceiling bounds the text and nothing else.** The rest of what a run costs —
tool output, files read twice, review rounds — is what [`fleet.sh
cost`](#what-a-run-costs) measures, and [REVIEW.md](../REVIEW.md) asks a fleet
PR body to carry that figure. The two halves belong together: the table stops
the prompt growing, the cost report says whether anything actually got cheaper.

## Checking your work

```bash
./evals/lint.sh                                # is the agent config well-formed
python3 .claude/hooks/guard.py --selftest      # do the guards still guard
python3 .github/scripts/merge_gate.py --selftest
```
