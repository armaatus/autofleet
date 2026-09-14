# autofleet's own correctness rules for a review

Read after [REVIEW.md](../REVIEW.md). That file is the generic policy and it is
vendored; this one is autofleet's, and it is not.

It does not restate the hard rules — `CLAUDE.md` has those in full, and stating
an enforced rule twice is what `evals/lint.sh` refuses. It says where to *look*
for a breach of them in a diff, which is a different thing and the part a
reviewer cannot derive.

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
  a row in its `--selftest`, and every check in `evals/lint.sh` asserts the
  wiring. A rule added without one is not shipped: it will stop matching, and
  nothing will say so.

- **A gate condition with no `--selftest` row.** Same property, in
  `.github/scripts/merge_gate.py`. A row asserting only the verdict, where the
  behaviour is what the refusal *says*, is not a test — the optional wording
  field exists for exactly that.

- **`orca` outside `scripts/fleet/runner/`.** Case-insensitively, including
  `ORCA_DEADLINE`, `mkdir -p .orca` and the `Orca` spelling in a message. Prose
  does not count. `evals/lint.sh` check 4c runs the grep; a diff that widens the
  surface without widening the check is the finding.

- **An assertion piped into `grep -q`** in a file with `pipefail`. `-q` exits on
  the first match, the producer dies of EPIPE, and a check that *held* reports as
  failed — on large input only, so green on a Mac and red in CI.
  `evals/piped_quiet_grep.py` scans the payload's shell; the `run:` blocks in
  `.github/workflows/` are not scanned yet (#90).

- **A brief that grew.** What an agent reads before its first edit —
  `CLAUDE.md`, `REVIEW.md`, and stage 1 of `issue-command.sh` — is under a word
  ceiling `evals/lint.sh` enforces, because it rides in the prompt prefix of
  every request for the rest of the session. A paragraph added there is paid for
  by every task in every worktree.

- **Two documents saying one thing.** `evals/lint.sh` asserts each enforced rule
  is stated in full in exactly one agent-facing text. A change that adds a
  helpful restatement elsewhere has added the thing that goes stale.

## What not to report here

The comment density. It is high on purpose: most of these rules exist because
something failed once, and the failure is the only thing that makes the rule
readable a year later. A diff that matches it is correct.
