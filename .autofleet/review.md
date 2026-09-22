# autofleet's own correctness rules for a review

Read after [REVIEW.md](../REVIEW.md). That file is the generic policy and it is
vendored; this one is autofleet's, and it is not.

It does not restate the hard rules — `CLAUDE.md` has those in full. It says
where to *look* for a breach of them in a diff, which is a different thing and
the part a reviewer cannot derive.

## Where this project breaks

- **The payload/host duality.** `scripts/fleet/`, `.claude/`, `.github/` and
  `evals/` are both what a host repository vendors and what autofleet runs on
  itself. A change that works in only one of those places is a defect, not a
  rough edge. Ask of every hunk: what does this do in a repository that is not
  this one? A new file in the payload that `install.sh` does not list is the
  usual form.

- **A project detail inside the payload.** A port, a container name, a build or
  test command, a protected path, a directory layout. All of it arrives through
  `.autofleet/config`, `.autofleet/guard.json` and the two project hooks. One
  hardcoded detail is what makes the next repository fork this one — and this
  file exists because the review policy itself was carrying another project's
  save format for months.

- **A guard rule with no assertion.** Every rule in `.claude/hooks/guard.py` has
  a row in its `--selftest`, and every condition in
  `.github/scripts/merge_gate.py` has one in its. A rule added without one is not
  shipped: it will stop matching, and nothing will say so. A row asserting only
  the exit code, where the behaviour is what the refusal *says*, is not a test.

- **A rule deleted in silence.** The other half of the same property, and the
  one armaatus/autofleet#153 made live: a refusal removed without its row
  removed, or a row removed without the reader being told what is no longer
  enforced, reads as a tidy-up. `docs/WORKFLOW.md`'s guardrails section names
  what was deliberately given up; a deletion that is not there is a deletion
  nobody will notice has happened.

- **`orca` outside `scripts/fleet/runner/`.** Case-insensitively, including
  `ORCA_DEADLINE`, `mkdir -p .orca` and the `Orca` spelling in a message. Prose
  does not count, nor does `config.sh`'s `AUTOFLEET_RUNNER` default. The grep is
  printed in [docs/RUNNERS.md](../docs/RUNNERS.md); run it against the diff.

- **A `runner_*` call with no guard.** A script that reaches for the runtime
  must ask `fleet_require_runner` first, and ask it *before* the first
  `runner_*` — the order is the property. A driver that omits a function the
  fleet calls is `command not found` in a script with no `-e`.

- **An assertion piped into `grep -q`** in a file with `pipefail`. `-q` exits on
  the first match, the producer dies of EPIPE, and a check that *held* reports as
  failed — on large input only, so green on a Mac and red in CI.

- **stderr silenced after the redirection that fails.** `read -r x <"$f"
  2>/dev/null` prints the open failure and *then* silences the stream. Write
  `2>/dev/null <"$f"`.

- **A brief or a working agreement that grew.** `CLAUDE.md` is under 400 words
  and the brief under 60 lines, because both ride in the prompt prefix of every
  request for the rest of the session. `tests/test_brief.sh` holds the brief;
  nothing holds `CLAUDE.md`, so this is where it is noticed.

## What not to report here

The comment density. It is high on purpose: most of these rules exist because
something failed once, and the failure is the only thing that makes the rule
readable a year later. A diff that matches it is correct.
