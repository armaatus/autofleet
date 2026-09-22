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
  # THE REVIEW IS NOT A WORKFLOW ANY MORE. `claude-review.yml` and
  # `validate.yml` shipped here until armaatus/autofleet#152: one review venue
  # in Actions, one on the dispatcher, a mode knob to choose, and two copies of
  # every rule to keep in step. There is one venue now -- the dispatcher, which
  # a host already runs -- and a host that wants the review inside Actions
  # instead writes a workflow around `anthropics/claude-code-action` directly,
  # which is a thing to choose rather than a thing to inherit.
  ".github/workflows/agent-config.yml"
  ".github/scripts/merge_gate.py"
  ".github/scripts/issue_refs.py"
  ".github/scripts/pr_payload.sh"
  ".claude/hooks/guard.py"
  ".claude/hooks/shell-parses.sh"
  ".claude/agents/researcher.md"
  # The brief `scripts/fleet/review.sh` inlines. `validator.md` used to sit
  # beside it and does not any more: the question it asked -- were these
  # findings addressed -- is what a re-review of the fixed head answers in one
  # pass with no protocol, and the protocol was where it failed every time.
  ".claude/agents/reviewer.md"
  # The lint: `bash -n`, shellcheck, and the two selftests. It shells out to
  # nothing this installer does not also deliver -- a vendored lint that imports
  # a file the installer left behind fails on every host PR, on a check about the
  # host's own configuration (hard rule 1). It replaced `evals/lint.sh` and four
  # hand-written python scanners in armaatus/autofleet#153.
  "evals/run.sh"
  "docs/WORKFLOW.md"
  # Vendored because the payload POINTS AT IT: REVIEW.md links to it,
  # scripts/fleet/review.sh and .claude/agents/reviewer.md cite it as where the
  # local-review trade is written down, guard.py and merge_gate.py name it in
  # refusals, and the next steps below send the reader to it -- as does the
  # comment this installer writes into the host's own .autofleet/config. All of
  # that shipped while the file did not, so the link 404'd in every host repo.
  # Hard rule 1, found by the independent review.
  "docs/CONFIGURATION.md"
  # ...and RUNNERS.md, for the same reason and found by the same new assertion:
  # `scripts/fleet/runner/README.md` ships as part of `scripts/fleet` and its
  # first paragraph links here, so that link has been 404ing in every host repo
  # since the runner directory existed. A host writing a second driver is exactly
  # who needs it.
  "docs/RUNNERS.md"
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
# WHAT THE PAYLOAD WRITES AT RUNTIME, kept out of the host's history.
#
# WHAT THIS REPO'S OWN `.gitignore` NAMES, and hard rule 1 is the reason the
# installer may not ship fewer:
#
#   .env, .env.tmp*      `scripts/fleet/env.sh` writes the first per worktree
#                        and leaves the second behind if it is killed mid-write.
#                        THE ONE THAT HOLDS SECRETS. `.claude/hooks/guard.py`
#                        heads its secret list with "every one is gitignored",
#                        and in a host that sentence is only true because of
#                        this line. A project with ports and a setup hook that
#                        appends a token to `.env` is the ordinary case.
#
# TWO, and it was four. `.autofleet/run/` held the `reviewed-<sha>` push markers
# and `/findings.md` was what the two local review passes wrote on the way to
# the PR body; armaatus/autofleet#152 removed the passes and the marker with
# them, so the payload writes neither. A line for a file nothing writes is a
# line a host has to wonder about.
#
# The installer never touched the host's `.gitignore` at all, and that was
# survivable while everything the payload wrote was an empty marker, and stopped
# being so the moment one of them had CONTENT in it: untracked content in a repo
# an agent drives is what `git add -A` sweeps into a commit. The first version of
# this block shipped two of the four it then had and left `.env` out, which is
# the one that matters most; found by the independent review.
#
# APPENDED, never rewritten, and only when no line already covers it: a host's
# `.gitignore` is the host's. Matching is on the exact lines the payload would
# add, which is deliberately dumber than gitignore's own semantics -- a host
# that ignores the directory some other way gets one redundant line, and a
# regression here is a duplicate entry rather than a clobbered file. Found by
# the independent review of #55.
IGNORES=(".env" ".env.tmp*")
ensure_ignored() {
  local gi="$TARGET/.gitignore" want missing=()
  for want in "${IGNORES[@]}"; do
    grep -qxF -- "$want" "$gi" 2>/dev/null || missing+=("$want")
  done
  [ "${#missing[@]}" -gt 0 ] || {
    echo "   kept (yours): .gitignore already covers what the payload writes"
    # ...and COUNTED as kept, the way copy_one and seed_one count theirs. Without
    # it the summary undercounts by one on every re-run.
    kept=$((kept + 1)); return 0; }
  changed=$((changed + 1))
  if $DRY; then
    echo "   would add to .gitignore: ${missing[*]}"
    return 0
  fi
  echo "   .gitignore += ${missing[*]}"
  {
    # A leading blank line only when the file exists and does not end in one,
    # so a re-run does not stack them.
    if [ -s "$gi" ] && [ -n "$(tail -c 1 "$gi" 2>/dev/null)" ]; then printf '\n'; fi
    printf '# Written at runtime by the autofleet payload, never committed:\n'
    printf '# the per-worktree .env, review markers, and what the local\n'
    printf '# review passes write.\n'
    printf '%s\n' "${missing[@]}"
  } >>"$gi"
}

echo "==> what the payload writes at runtime"
ensure_ignored

echo "==> your answers (seeded once, never overwritten)"
# Recorded BEFORE the loop, because after it the file exists either way and
# nothing can tell a fresh seed from the host's own answers.
had_config=false; [ -e "$TARGET/.autofleet/config" ] && had_config=true
had_settings=false; [ -e "$TARGET/.claude/settings.json" ] && had_settings=true
for rel in "${SEEDS[@]}"; do seed_one "$rel"; done


# ------------------------------------------------------- the branch rules
#
# THREE RULES THE GATE DOES NOT CHECK, because GitHub already has them and a
# Python re-implementation of a rule GitHub enforces is a second answer to the
# same question. `merge_gate.py` asks three things -- a closing line, the paths
# a person merges, an approving review of this head -- and everything else that
# used to be in its 3,162 lines is set here, once, on the default branch:
#
#   required status checks          so `--auto` waits on a red build instead of
#                                   merging into one. `merge-gate` always, plus
#                                   whatever $AUTOFLEET_REQUIRED_CHECKS names.
#
#                                   THE HOST'S BUILD CHECK IS NOT GUESSED. A
#                                   required context is the JOB's name, which
#                                   this installer cannot know -- autofleet's
#                                   own is `suite`, not `ci`, because that is
#                                   the job key inside `ci.yml` -- and setting a
#                                   context no job produces makes every pull
#                                   request wait forever on a check that never
#                                   reports. Hard rule 2: a project detail
#                                   arrives through configuration, never through
#                                   a guess in the payload. The next-steps below
#                                   say how to add it.
#   required_conversation_resolution
#                                   every review thread resolved. This was ~400
#                                   lines of thread paging in the gate, and the
#                                   paging had a truncation bug that made a
#                                   partial list read as a clean one.
#   dismiss_stale_reviews           a push after an approval drops it. The gate
#                                   binds its own check to the head sha as well,
#                                   so the two agree; this is the half that
#                                   makes GitHub's own UI agree with them.
#
# NOT FATAL WHEN IT FAILS, and that is deliberate. It needs admin on the
# repository, which the person running the installer may not have, and an
# installer that refuses to finish over a permission is an installer nobody
# finishes. It prints what it could not set and the exact `gh api` to re-run.
#
# `enforce_admins` is left OFF on purpose: `HUMAN_ONLY_PREFIXES` means a
# repository admin merging the enforcement layer by hand, with `merge-gate`
# red, is the designed path and not an exception.
set_branch_protection() {
  # THE DEFAULT BRANCH, asked of GitHub. It was `symbolic-ref HEAD`, which is
  # whatever branch the installer happens to run on -- and vendoring the payload
  # on a branch so as to open a pull request for it is the natural way to do it.
  # That protected a throwaway branch and left `main` with no required
  # `merge-gate` context at all, so `gh pr merge --auto --squash` would merge
  # without the gate ever being required. Found by the local /code-review pass.
  local branch
  branch="$(GH_PAGER=cat gh repo view --json defaultBranchRef \
              --jq .defaultBranchRef.name 2>/dev/null)" || branch=""
  [ -n "$branch" ] && [ "$branch" != null ] || branch=main
  if $DRY; then
    echo "   branch protection on '$branch' (skipped: --dry-run)"
    return 0
  fi
  # `|| nwo=""`, because this file runs under `set -e` and a repository with no
  # remote -- or a machine with no `gh` -- makes that substitution non-zero.
  # Without it the installer stops here, silently, having written the payload and
  # nothing else, and the summary never prints. Found by the suite's host
  # fixture, which is a git repo with no remote for exactly this class of reason.
  local nwo
  nwo="$(GH_PAGER=cat gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" \
    || nwo=""
  if [ -z "$nwo" ]; then
    echo "   branch protection: gh could not say which repository this is; not set"
    return 0
  fi
  # NEVER OVER AN EXISTING RULE. `PUT .../protection` is a full REPLACE, not a
  # merge: a host that already required two approving reviews, a build context,
  # push restrictions or a linear history would have all of it silently reset by
  # installing a payload -- and `"required_approving_review_count": 0` and
  # `"restrictions": null` below would write the human-approval requirement away.
  # Every other host-owned artefact this installer touches is deliberately
  # non-destructive: `ensure_ignored` appends only what is missing,
  # `merge_plugin_entry` merges one key, `seed_one` never overwrites. This was
  # the exception, with nothing warning about it. Found by the local
  # /code-review pass.
  if GH_PAGER=cat gh api "repos/$nwo/branches/$branch/protection" \
       >/dev/null 2>&1; then
    echo "   branch protection on '$branch': KEPT (yours) -- it already has rules,"
    echo "                       and setting these would REPLACE them wholesale."
    echo "                       docs/CONFIGURATION.md has what to add by hand."
    return 0
  fi

  # The contexts, as a JSON array built from the word list.
  local contexts
  contexts="$(REQUIRED="merge-gate ${AUTOFLEET_REQUIRED_CHECKS:-}" python3 -c '
import json, os
# Deduplicated and ORDER-PRESERVING: `merge-gate` first whatever the host set,
# and a host that names it again does not get it twice.
seen, out = set(), []
for name in os.environ["REQUIRED"].split():
    if name not in seen:
        seen.add(name); out.append(name)
print(json.dumps(out))
')" || contexts='["merge-gate"]'
  # A HEREDOC on stdin, not a stack of `-f` flags: `required_status_checks` is a
  # nested object with an array in it, and `gh api -f` can only write flat
  # strings. `--input -` takes the whole document.
  if GH_PAGER=cat gh api -X PUT "repos/$nwo/branches/$branch/protection" \
       --input - >/dev/null 2>&1 <<JSON
{
  "required_status_checks": {"strict": false, "contexts": $contexts},
  "enforce_admins": false,
  "required_pull_request_reviews": {"dismiss_stale_reviews": true,
                                    "required_approving_review_count": 0},
  "required_conversation_resolution": true,
  "restrictions": null
}
JSON
  then
    echo "   branch protection on '$branch' ($contexts required, threads must"
    echo "                       resolve, approvals dismissed on push)"
  else
    echo "   branch protection on '$branch': NOT SET -- needs admin on $nwo."
    echo "                       docs/CONFIGURATION.md has the gh api call to re-run."
  fi
}
set_branch_protection

# ---------------------------------------------------------------- the plugin
# `mattpocock-skills` is not decoration and it is not optional. The agent brief
# tells every worktree to run `/implement`, which drives
# `/mattpocock-skills:tdd` at the seams. A host repo without it gets a brief
# asking for a skill nobody has.
#
# It used to be load-bearing twice over: `merge_gate.py` required
# `/mattpocock-skills:code-review` to be NAMED in the PR body before a PR could
# merge. That string stopped meaning anything with armaatus/autofleet#152 --
# the pass it stood for is gone and the gate reads a verdict instead of prose.
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
  # here, and the entry is what the agent brief depends on.
  ( cd "$TARGET" \
      && claude plugin marketplace add "$MARKETPLACE" >/dev/null 2>&1
    cd "$TARGET" && claude plugin install "$PLUGIN" --scope project >/dev/null 2>&1
  ) && echo "   $PLUGIN installed for $TARGET" \
    || echo "   !! could not install $PLUGIN; run the two commands below by hand"
}

echo "==> the mattpocock-skills plugin (the brief requires it)"
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
       gh label create priority         --color d4c5f9 --description "A person put this at the front of the dispatcher's queue"
  5. If you already had a .claude/settings.json, add the two hook entries from
     this repo's own settings.json -- guard.py on PreToolUse, shell-parses.sh on
     PostToolUse. Unregistered hooks do not run, and nothing says so.
  6. Add YOUR build check to the required contexts. This installer set
     `merge-gate` and cannot guess the other one: a required context is the
     JOB's name inside your workflow file, and a context no job produces makes
     every PR wait forever on a check that never reports. Re-run the installer
     with AUTOFLEET_REQUIRED_CHECKS="<your job name>", or edit the rule by hand
     -- docs/CONFIGURATION.md has the gh api call. The other two rules,
     conversation resolution and dismissing an approval when the head moves,
     are set; merge_gate.py deliberately does not re-check any of the three.
  7. Write .autofleet/review.md -- YOUR project's correctness rules, the ones
     REVIEW.md cannot know. The file that must be written atomically, the header
     that may not appear in that directory, the address a test may not reach.
     The reviewer reads it after REVIEW.md wherever it exists, and it is not
     seeded because seeding it would hand you somebody else's. REVIEW.md's "...and
     this project's own" section says what belongs in it.
  8. Read what the review gives up -- the reviewer signs in as whoever `gh` is,
     which is normally the account that opened the pull request.
     docs/CONFIGURATION.md, "What this gives up, exactly".
  9. Read docs/WORKFLOW.md, then: ./scripts/fleet/fleet.sh status

If the plugin step above could not run, these are the two commands, from inside
the repo you installed into:

  claude plugin marketplace add anthropics/claude-plugins-official
  claude plugin install mattpocock-skills@claude-plugins-official --scope project

NEXT
