#!/usr/bin/env bash
# Covers the three shipped docs against the code they describe.
#
# A doc that is wrong is worse than a doc that is missing: `docs/WORKFLOW.md`
# told a reader whose review never arrived to check `gh run list` and a
# `CLAUDE_CODE_OAUTH_TOKEN` repo secret, for a workflow armaatus/autofleet#152
# deleted -- so the one table in the tree headed "when the loop stalls" sent
# them to a venue that does not exist. Nothing noticed, because nothing reads
# these files but a person, and a person reads them when something is already
# wrong.
#
# These phases are DERIVED, not transcribed: each asks the code a question and
# holds the doc to the answer, so the assertion cannot rot into agreement with
# a doc that drifted.
#
#   test_docs.sh knobs   every knob config.sh defaults has a row in
#                        docs/CONFIGURATION.md. A knob a host cannot find is a
#                        knob a host does not set.
#   test_docs.sh venues  no doc sends a reader to a venue the tree does not
#                        have: a secret no workflow reads, a workflow no
#                        `.github/` ships.
#   test_docs.sh seeds   README does not call a file optional that the
#                        installer writes for you either way.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "  ok: $*"; }

case "${1:-}" in

  knobs)
  # Read out of config.sh rather than listed here, so a knob added tomorrow is
  # covered by this phase the moment it is added.
  missing=""
  for knob in $(grep -o '^: "${AUTOFLEET_[A-Z_]*' scripts/fleet/config.sh \
                | sed 's/^: "${//' | sort -u); do
    grep -qF -- "\`$knob\`" docs/CONFIGURATION.md || missing="$missing $knob"
  done
  [ -z "$missing" ] \
    || fail "config.sh defaults these and docs/CONFIGURATION.md has no row for them:$missing"
  ok "every knob the payload defaults has a row a host can read"
  ;;

  venues)
  # THE SECRET. Derived: if nothing under `.github/` reads it, no doc may tell
  # a reader to go and check it. Named rather than pattern-matched because the
  # failure is specific -- a person whose review never arrived, sent to look at
  # a repository setting that has done nothing since #152.
  for secret in CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_API_KEY; do
    grep -rq "$secret" .github/ 2>/dev/null && continue
    hits="$(grep -rln "$secret" docs README.md REVIEW.md CLAUDE.md 2>/dev/null || true)"
    [ -z "$hits" ] \
      || fail "nothing in .github/ reads $secret and these still tell a reader to check it: $hits"
  done
  ok "no doc points at a secret no workflow reads"

  # ...and no doc points at a review inside Actions. The review runs on the
  # dispatcher (`scripts/fleet/review.sh`) and the only way a reader finds that
  # out is a doc that says so.
  [ -e .github/workflows/claude-review.yml ] \
    && fail "this phase assumes the review is not a workflow, and one is back"
  grep -n 'gh run list' docs/WORKFLOW.md | grep -qi 'review' \
    && fail "docs/WORKFLOW.md sends a reader to Actions for a review that runs on the dispatcher"
  grep -q 'review.sh' docs/WORKFLOW.md \
    || fail "docs/WORKFLOW.md never names what runs the review, so a reader cannot find it"
  ok "...and the review's venue in the docs is the one the code uses"
  ;;

  seeds)
  # Derived from install.sh: a path in SEEDS is written for the host whether it
  # asks or not, so a README row calling it optional is a reader deciding not to
  # have a file they already have. "Optional to fill in" is the true sentence
  # and the row has to say which it means.
  sed -n '/^SEEDS=(/,/^)/p' install.sh | grep -q '"orca.yaml"' \
    || fail "this phase assumes install.sh seeds orca.yaml, and it does not any more"
  row="$(grep -F '| `orca.yaml` |' README.md)" \
    || fail "README.md has no row for orca.yaml, which the installer seeds"
  grep -qi 'seeded' <<<"$row" \
    || fail "README calls orca.yaml optional without saying the installer writes it anyway: $row"
  ok "README says orca.yaml is seeded, and what is optional about it"
  ;;

  *) echo "usage: $0 {knobs|venues|seeds}" >&2; exit 2 ;;
esac
