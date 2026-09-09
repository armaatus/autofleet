#!/usr/bin/env bash
# Vendor autofleet into a repo.
#
#   ./install.sh /path/to/your-repo          # copy the payload in
#   ./install.sh --dry-run /path/to/repo     # say what would change
#   ./install.sh --force /path/to/repo       # overwrite files that differ
#
# autofleet is VENDORED rather than installed: the payload lands in the host
# repo and is committed there. That is deliberate. Every piece of it -- the
# guards, the merge gate, the workflows -- is something a reviewer has to be
# able to read in the diff of the repo it governs, and something CI has to be
# able to run with no dependency on a machine having autofleet checked out.
#
# The cost is that upgrades are a re-run and a diff, not a version bump. Re-run
# this against the same repo, read the diff, keep what you want.
set -euo pipefail

SOURCE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# What ships, and where it lands. Every path is copied verbatim from this
# checkout to the same path in the target -- which is why this repo mirrors a
# host installation rather than keeping the payload in a directory of its own.
# See CLAUDE.md, hard rule 1.
PAYLOAD=(
  "scripts/fleet"
  ".github/workflows/merge-gate.yml"
  ".github/workflows/unblock.yml"
  ".github/workflows/claude-review.yml"
  ".github/workflows/agent-config.yml"
  ".github/scripts/merge_gate.py"
  ".github/scripts/issue_refs.py"
  ".github/scripts/pr_payload.sh"
  ".claude/hooks/guard.py"
  ".claude/hooks/shell-parses.sh"
  ".claude/agents/verifier.md"
  ".claude/agents/researcher.md"
  "evals/lint.sh"
  "evals/run.sh"
  "docs/WORKFLOW.md"
  "REVIEW.md"
)

# Written only if absent, never overwritten: these are the host project's own
# answers, and clobbering them on an upgrade is how a re-run silently undoes a
# project's configuration.
SEEDS=(
  ".autofleet/config"
  ".autofleet/guard.json"
  ".autofleet/setup.sh"
  "orca.yaml"
  # The hooks have to be REGISTERED to run, and a repo that already has a
  # settings.json has its own permissions in it. Seeding rather than copying
  # means an existing one is never clobbered -- and the next-steps below say
  # what to add to it by hand, because merging someone's permission list is not
  # something an installer should guess at.
  ".claude/settings.json"
)

DRY=false
FORCE=false
TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=true ;;
    --force)   FORCE=true ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *)  [ -z "$TARGET" ] || { echo "one target, not two" >&2; exit 2; }
        TARGET="$1" ;;
  esac
  shift
done

[ -n "$TARGET" ] || { echo "usage: $0 [--dry-run] [--force] <repo>" >&2; exit 2; }
TARGET="$(cd "$TARGET" 2>/dev/null && pwd)" \
  || { echo "no such directory: $TARGET" >&2; exit 2; }
[ "$TARGET" != "$SOURCE" ] \
  || { echo "that is autofleet itself; it is already installed here" >&2; exit 2; }

# A git repo, because everything the payload does assumes one: the fleet opens
# worktrees, the gate reads pull requests, the guard refuses a force-push.
[ -d "$TARGET/.git" ] || git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1 \
  || { echo "$TARGET is not a git repository" >&2; exit 2; }

changed=0
kept=0

copy_one() {
  local rel="$1" src="$SOURCE/$rel" dst="$TARGET/$rel"
  [ -e "$src" ] || { echo "!! $rel is missing from this checkout" >&2; return 1; }
  if [ -e "$dst" ] && diff -rq "$src" "$dst" >/dev/null 2>&1; then
    kept=$((kept + 1)); return 0
  fi
  if [ -e "$dst" ] && ! $FORCE; then
    echo "   differs (kept): $rel   -- re-run with --force to overwrite"
    kept=$((kept + 1)); return 0
  fi
  changed=$((changed + 1))
  # `${DRY:+...}` would expand on the string "false" as readily as on "true",
  # which is how a real install announced itself as a dry run.
  if $DRY; then echo "   would write $rel"; return 0; fi
  echo "   $rel"
  mkdir -p "$(dirname "$dst")"
  rm -rf "$dst"
  cp -R "$src" "$dst"
}

seed_one() {
  local rel="$1" src="$SOURCE/$rel" dst="$TARGET/$rel"
  if [ -e "$dst" ]; then
    echo "   kept (yours): $rel"
    kept=$((kept + 1)); return 0
  fi
  changed=$((changed + 1))
  if $DRY; then echo "   would seed $rel"; return 0; fi
  echo "   $rel"
  mkdir -p "$(dirname "$dst")"
  cp -R "$src" "$dst"
}

echo "==> payload"
for rel in "${PAYLOAD[@]}"; do copy_one "$rel"; done
echo "==> your answers (seeded once, never overwritten)"
for rel in "${SEEDS[@]}"; do seed_one "$rel"; done

echo
if $DRY; then
  echo "$changed would change, $kept already match. Nothing was written."
  exit 0
fi
echo "$changed written, $kept unchanged."
cat <<'NEXT'

Next, in the repo you just installed into:

  1. Edit .autofleet/config     -- the ports, the compose file, the test command.
  2. Edit .autofleet/setup.sh   -- what a fresh worktree needs before work starts.
  3. Edit .autofleet/guard.json -- the paths and secrets guard.py must refuse.
  4. Add the labels the dispatcher reads:
       gh label create ready   --color 0e8a16 --description "All blockers closed; safe to start"
       gh label create blocked --color b60205 --description "Waiting on an open blocker; do not start"
       gh label create foundation       --color 5319e7 --description "Defines an interface later issues include; lands alone"
       gh label create needs-human-step --color b60205 --description "Last step is the maintainer's; the fleet opens no worktree"
  5. If you already had a .claude/settings.json, add the two hook entries from
     this repo's own settings.json -- guard.py on PreToolUse, shell-parses.sh on
     PostToolUse. Unregistered hooks do not run, and nothing says so.
  6. Make `merge-gate` a required check on your default branch.
  7. Read docs/WORKFLOW.md, then: ./scripts/fleet/fleet.sh status

NEXT
