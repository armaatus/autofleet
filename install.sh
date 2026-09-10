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
  ".claude/agents/reviewer.md"
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
# Recorded BEFORE the loop, because after it the file exists either way and
# nothing can tell a fresh seed from the host's own answers.
had_config=false; [ -e "$TARGET/.autofleet/config" ] && had_config=true
had_settings=false; [ -e "$TARGET/.claude/settings.json" ] && had_settings=true
for rel in "${SEEDS[@]}"; do seed_one "$rel"; done

# The seed is autofleet's own config, and autofleet runs itself on
# `AUTOFLEET_REVIEW_MODE=local` (see hard rule 1: the weaker path is the one that
# has to be exercised daily). Copying that verbatim would hand every host repo
# the weaker independence guarantee as a DEFAULT, chosen by nobody and announced
# nowhere -- which is the exact failure the mode's whole design is built to
# avoid. So a freshly seeded config is normalised back to the strong default and
# the change is printed. A config the host already had is never touched.
#
# THE WHOLE BLOCK, not just the assignment. The lines above it in autofleet's own
# config explain why AUTOFLEET runs local mode -- "no CLAUDE_CODE_OAUTH_TOKEN on
# this repository", "the mode it runs itself on" -- and a host repo that read
# that over a `github` setting would be reading a paragraph about somebody else's
# repository. Found by the local review of the change that added this.
#
# In PYTHON, not sed: this has to match every spelling `merge_gate.review_mode()`
# accepts, including `export`, quotes and the `: "${X:=local}"` form. A
# normalisation pinned to one spelling silently ships `local` the day the line is
# reworded, which is the outcome this exists to prevent.
normalise_review_mode() {
  # Under --dry-run the seed has not been written, so there is nothing in the
  # target to read: report against the file that WOULD be copied. A dry run
  # silent about a rewrite the real install performs is the bug commit f5817b8
  # existed to fix, one file over.
  local cfg="$TARGET/.autofleet/config"
  $DRY && cfg="$SOURCE/.autofleet/config"
  [ -f "$cfg" ] || return 0
  python3 - "$cfg" "$DRY" <<'PYEOF'
import re, sys
path, dry = sys.argv[1], sys.argv[2] == "true"
lines = open(path).read().splitlines()

# The same shapes merge_gate.REVIEW_MODE_RE reads -- `export` and quotes -- and
# for the same reason: a normalisation pinned to one spelling silently ships
# `local` the day the line is reworded. Deliberately NOT the `: "${X:=local}"`
# form: config.sh's own default runs first, so that shape sets nothing, and a
# file that only *looks* like it selects local mode must not be rewritten as if
# it did. evals/lint.sh asserts this stays in step with the gate.
ASSIGN = re.compile(
    r"""^[ \t]*(?:export[ \t]+)?"""
    r"""AUTOFLEET_REVIEW_MODE=[ \t]*["']?local\b""",
    re.I,
)
hit = next((i for i, ln in enumerate(lines) if ASSIGN.match(ln)), None)
if hit is None:
    raise SystemExit(0)
if dry:
    print("   would set .autofleet/config review mode to github (the strong default)")
    raise SystemExit(0)

# THE WHOLE BLOCK, not just the assignment. The comment lines above it explain
# why AUTOFLEET runs local mode -- "no CLAUDE_CODE_OAUTH_TOKEN on this
# repository", "the mode it runs itself on" -- and a host repo reading that over
# a `github` setting is reading a paragraph about somebody else's repository.
# Walk back over the contiguous comment block that introduces it.
top = hit
while top > 0 and lines[top - 1].lstrip().startswith("#"):
    top -= 1
while top > 0 and not lines[top - 1].strip():
    top -= 1

replacement = """# Where the independent review runs -- `github` or `local`.
#
# `github` is the default and the strong one, and it needs a
# CLAUDE_CODE_OAUTH_TOKEN secret on this repository (`claude setup-token`).
# WITHOUT that secret .github/workflows/claude-review.yml no-ops with a green
# check and every pull request blocks forever on a review that cannot arrive.
#
# `local` runs the reviewer on the machine instead, with a weaker independence
# guarantee that docs/CONFIGURATION.md spells out in full. Choose deliberately.
AUTOFLEET_REVIEW_MODE=github""".splitlines()

out = lines[:top] + [""] + replacement + lines[hit + 1:]
open(path, "w").write("\n".join(out).rstrip("\n") + "\n")
print("   .autofleet/config  (review mode set to github, the strong default --")
print("                       the next steps below are where you choose otherwise)")
PYEOF
}
$had_config || normalise_review_mode

# ---------------------------------------------------------------- the plugin
# `mattpocock-skills` is not decoration and it is not optional. The agent brief
# tells every worktree to run `/mattpocock-skills:code-review`, `merge_gate.py`
# REQUIRES that pass to be named in the PR body before a PR may merge, and
# `evals/lint.sh` fails if the entry is missing. So a host repo without it gets
# a brief asking for a skill nobody has and a gate nothing can satisfy.
#
# Two halves, because enabling and installing are different things and this
# repo has now been bitten by both:
#
#   the entry   `.claude/settings.json` is SEEDED, never overwritten -- a repo
#               that already had one therefore never got the entry at all. This
#               merges just that key into an existing file, leaving every
#               permission and hook in it alone.
#   the install autofleet's own checkout had the entry enabled for MONTHS while
#               the plugin was installed only for a different project, so every
#               agent was being told to run a skill that did not resolve and
#               nothing said so. `enabledPlugins` enables what is installed; it
#               does not install anything.
PLUGIN="mattpocock-skills@claude-plugins-official"
MARKETPLACE="anthropics/claude-plugins-official"

merge_plugin_entry() {
  local dst="$TARGET/.claude/settings.json"
  # A settings.json this install just SEEDED already carries the entry, because
  # it is a copy of ours -- there is nothing to merge and "kept (yours)" would be
  # a lie about a file the host did not have. `$had_settings` is recorded before
  # the seed loop for exactly that reason.
  if ! $had_settings; then
    echo "   .claude/settings.json  (seeded from ours, which already enables the plugin)"
    return 0
  fi
  # ...and under --dry-run the seed has not been written, so there is nothing in
  # the target to read: say what WOULD happen rather than returning in silence.
  # A dry run quieter than the install it describes is the bug f5817b8 fixed.
  if [ ! -f "$dst" ]; then
    $DRY && echo "   would add enabledPlugins.$PLUGIN to .claude/settings.json"
    return 0
  fi
  python3 - "$dst" "$PLUGIN" "$DRY" <<'PYEOF'
import json, sys
path, plugin, dry = sys.argv[1], sys.argv[2], sys.argv[3] == "true"
try:
    with open(path) as fh:
        settings = json.load(fh)
except Exception as exc:
    # Not silence: a settings.json this cannot read is one the entry never
    # reaches, and the failure would surface as an eval failing in the host repo
    # for a reason nothing connects back to here.
    print(f"   !! could not read .claude/settings.json ({exc});"
          f" add {{\"enabledPlugins\": {{\"{plugin}\": true}}}} by hand")
    raise SystemExit(0)
if settings.get("enabledPlugins", {}).get(plugin):
    print("   kept (yours): .claude/settings.json already enables the plugin")
    raise SystemExit(0)
if dry:
    print("   would add enabledPlugins."+plugin+" to .claude/settings.json")
    raise SystemExit(0)
settings.setdefault("enabledPlugins", {})[plugin] = True
with open(path, "w") as fh:
    json.dump(settings, fh, indent=2)
    fh.write("\n")
print("   .claude/settings.json  (enabledPlugins += " + plugin + ")")
PYEOF
}

install_plugin() {
  if ! command -v claude >/dev/null 2>&1; then
    echo "   claude is not on PATH; install the plugin yourself (see the steps below)"
    return 0
  fi
  if $DRY; then
    echo "   would install $PLUGIN into $TARGET"
    return 0
  fi
  # `--scope project` writes the install against the TARGET repo's path, which
  # is why this runs from inside it. Both commands are idempotent, and neither
  # is fatal: a machine with no network still gets a working vendored payload
  # and a printed pair of commands to run later.
  #
  # It also REWRITES .claude/settings.json to add the same entry
  # merge_plugin_entry just added -- reordering the keys as it goes, which shows
  # up as diff noise in the host repo on the first install. That is why the merge
  # above happens anyway rather than being left to this: `claude` may not be
  # here, and the entry is what evals/lint.sh and the agent brief depend on.
  ( cd "$TARGET" \
      && claude plugin marketplace add "$MARKETPLACE" >/dev/null 2>&1
    cd "$TARGET" && claude plugin install "$PLUGIN" --scope project >/dev/null 2>&1
  ) && echo "   $PLUGIN installed for $TARGET" \
    || echo "   !! could not install $PLUGIN; run the two commands below by hand"
}

echo "==> the mattpocock-skills plugin (the brief and merge-gate both require it)"
merge_plugin_entry
install_plugin

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
  6. Choose where the independent review runs -- AUTOFLEET_REVIEW_MODE in
     .autofleet/config. The default `github` needs a CLAUDE_CODE_OAUTH_TOKEN
     secret on the repository (mint one with `claude setup-token`); WITHOUT it
     that job no-ops and every PR blocks forever on a review that cannot arrive.
     `local` runs the reviewer on your machine instead, with a weaker
     independence guarantee that docs/CONFIGURATION.md spells out.
  7. Make `merge-gate` a required check on your default branch.
  8. Read docs/WORKFLOW.md, then: ./scripts/fleet/fleet.sh status

If the plugin step above could not run, these are the two commands, from inside
the repo you installed into:

  claude plugin marketplace add anthropics/claude-plugins-official
  claude plugin install mattpocock-skills@claude-plugins-official --scope project

NEXT
