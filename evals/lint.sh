#!/usr/bin/env bash
# Is the agent configuration well-formed and still enforcing what it claims?
#
# Everything under .claude/ steers three parallel worktrees, and every failure
# mode it has is silent: a skill whose frontmatter does not parse never loads, a
# hook whose path is wrong never runs, a guard whose pattern stopped matching
# stops blocking. None of that shows up in a diff review or in a red build --
# it shows up as agents quietly doing the wrong thing for a week.
#
# So this asserts it, deterministically and with no model involved. It runs in
# `.github/workflows/agent-config.yml` as the gate, and as `agent.config` in
# ctest so a worktree sees a break before CI does.
#
#   ./evals/lint.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
ok()   { echo "  ok: $*"; }

# CLAUDE.md is read in full at the start of every session, so its size is a real
# cost paid on every task in every worktree. The cap is a smell test, not a
# formatting rule: past it, the file has stopped being what a new joiner needs on
# day one and started being documentation, which belongs in docs/.
CLAUDE_MD_MAX_LINES=200

echo "== CLAUDE.md"
if [ ! -f CLAUDE.md ]; then
  fail "CLAUDE.md is missing; it is the file every session reads first"
else
  lines="$(wc -l <CLAUDE.md | tr -d ' ')"
  if [ "$lines" -gt "$CLAUDE_MD_MAX_LINES" ]; then
    fail "CLAUDE.md is $lines lines (cap $CLAUDE_MD_MAX_LINES). Move detail into docs/ and link it."
  else
    ok "CLAUDE.md is $lines lines"
  fi
fi

# AGENTS.md is the vendor-neutral name other agent tools read. It is a symlink
# so there is exactly one file to keep true, and a copy would silently rot.
if [ -L AGENTS.md ]; then
  [ "$(readlink AGENTS.md)" = "CLAUDE.md" ] \
    || fail "AGENTS.md points at $(readlink AGENTS.md), not CLAUDE.md"
  ok "AGENTS.md -> CLAUDE.md"
elif [ -e AGENTS.md ]; then
  fail "AGENTS.md is a real file; it must be a symlink to CLAUDE.md so the two cannot drift"
fi

echo "== REVIEW.md"
if [ ! -f REVIEW.md ]; then
  fail "REVIEW.md is missing; /code-review and the PR review workflow both read it"
else
  for needle in "Correctness" "Important vs Nit" "Do not report"; do
    grep -q "$needle" REVIEW.md || fail "REVIEW.md has no '$needle' section"
  done
  ok "REVIEW.md names its passes and its thresholds"
  # The trailer merge_gate.py reads. It is the only thing separating a review
  # that found five nits from one that found nothing -- both are a COMMENTED
  # verdict -- and a policy file that stops asking for it turns the gate's
  # fail-closed default into the ordinary case, so every PR waits on an answer
  # to a review that said nothing.
  grep -q 'review-findings' REVIEW.md \
    || fail "REVIEW.md no longer asks a review to say how many findings it left; merge_gate.py cannot tell a clean review from a nitty one without it"
  ok "REVIEW.md asks for the findings count merge-gate reads"
fi

# A skill is a folder with a SKILL.md whose frontmatter says when it triggers.
# Both halves are load-bearing: no frontmatter and it never loads, no description
# and it loads for nothing.
# A skill and a subagent are the same shape: a markdown file whose frontmatter
# says what it is and when it applies. Both halves are load-bearing -- no
# frontmatter and it never loads, no description and it loads for nothing -- and
# checking them twice in two places is how the two checks drift apart.
check_frontmatter() {
  local file="$1" expect_name="$2" what="$3" fm declared
  [ -f "$file" ] || { fail "$what: $file is missing"; return; }
  [ "$(head -1 "$file")" = "---" ] \
    || { fail "$file does not open with a --- frontmatter block"; return; }
  fm="$(awk 'NR>1 && /^---$/{exit} NR>1' "$file")"
  grep -q '^name:' <<<"$fm" || fail "$file frontmatter has no name:"
  grep -q '^description:' <<<"$fm" || fail "$file frontmatter has no description:"
  declared="$(grep '^name:' <<<"$fm" | head -1 | sed 's/^name:[[:space:]]*//' \
              | tr -d '"'"'"' ')"
  [ "$declared" = "$expect_name" ] \
    || fail "$file declares name '$declared' but is filed as '$expect_name' -- they must match"
  ok "$what $expect_name"
}

echo "== skills"
shopt -s nullglob
for skill in .claude/skills/*/; do
  check_frontmatter "$skill/SKILL.md" "$(basename "$skill")" skill
done

echo "== subagents"
for agent in .claude/agents/*.md; do
  check_frontmatter "$agent" "$(basename "$agent" .md)" subagent
done

echo "== settings.json"
if ! python3 -c 'import json,sys; json.load(open(".claude/settings.json"))' 2>/dev/null; then
  fail ".claude/settings.json is not valid JSON -- every hook in it is silently off"
else
  ok ".claude/settings.json parses"
  # A hook whose command does not exist is not an error anyone sees; it is a
  # guard that stopped guarding.
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    # The whole command is treated as one path, not split at the first space:
    # every hook here IS a single script, and a checkout under "~/my worktrees/"
    # would otherwise report all of them missing on a perfectly correct tree.
    script="${cmd/\$CLAUDE_PROJECT_DIR/$REPO_ROOT}"
    [ -f "$script" ] || { fail "hook command does not exist: $cmd"; continue; }
    [ -x "$script" ] || { fail "hook command is not executable: $script"; continue; }
    case "$script" in
      *.py) python3 -m py_compile "$script" || fail "hook does not parse: $script" ;;
      *)    bash -n "$script" || fail "hook does not parse: $script" ;;
    esac
    ok "hook $(basename "$script")"
  done < <(python3 -c '
import json
s = json.load(open(".claude/settings.json"))
for group in s.get("hooks", {}).values():
    for matcher in group:
        for h in matcher.get("hooks", []):
            if h.get("type") == "command" and h.get("command"):
                print(h["command"])
')
fi

# The guards themselves. A hook that parses is not a hook that blocks: these
# feed it the shape it will see in production and assert the verdict, so a
# pattern that stops matching fails here rather than the day it lets something
# through.
echo "== guards actually guard"
# The exhaustive table lives in the hook itself (`guard.py --selftest`), next to
# the code it constrains, so a guard and its assertion cannot drift into
# separate files. It runs here so `ctest -R agent.config` and CI both cover it.
#
# One deliberate exception, below: the fleet's self-protection is asserted HERE
# rather than in the table, because a fleet-opened worktree cannot write
# `.claude/hooks/` -- which is the very rule being asserted. The table cannot
# grow an assertion that only a hand-opened worktree may add, so `guard.py
# --selftest` alone is no longer the whole record. This file is the rest of it.
if [ -x .claude/hooks/guard.py ]; then
  python3 .claude/hooks/guard.py --selftest 2>&1 | sed 's/^/  /'
  [ "${PIPESTATUS[0]}" = 0 ] || fail "the guard selftest does not hold"

  # ...and it has to hold from INSIDE a fleet worktree too. The stateless cases
  # assert what the guard does for an ordinary developer ("an ordinary push is
  # fine"), which is untrue by design where the fleet's own rules apply. Run
  # against the real fleet directory the selftest passed on a laptop and failed
  # in every agent's worktree -- `ctest -R agent.config` red exactly where the
  # work happens, green only on CI runners that are nobody's fleet.
  guard_tmp="$(mktemp -d)"
  mkdir -p "$guard_tmp/worktrees"
  printf '%s\n' "$REPO_ROOT" >"$guard_tmp/worktrees/999"
  AUTOFLEET_DIR="$guard_tmp" python3 .claude/hooks/guard.py --selftest >/dev/null 2>&1 \
    || fail "the guard selftest depends on where it is run: it fails inside a fleet worktree"
  ok "the guard selftest holds from inside a fleet worktree too"

  # ...and every path in SELF_PROTECTED is asserted, absolutely and through a
  # `cd`-shortened relative path, by `_stateful_checks` inside guard.py itself
  # (#139). #98 had to park those here because a fleet-opened worktree cannot
  # write `.claude/hooks/` -- but that left them outside merge_gate.py's
  # HUMAN_ONLY_PREFIXES, so a PR deleting them auto-merged with nobody
  # watching. In guard.py they are the enforcement layer, and a person merges
  # any PR that touches it.
  #
  # One thing guard.py still cannot check about itself: that SELF_PROTECTED has
  # not grown a fourth entry that no assertion covers. That pin stays here.
  # The list below is literal on purpose: derived from SELF_PROTECTED, removing
  # an entry would remove its own check. That catches a removal but not an
  # ADDITION -- a fourth marker would get no assertion in guard.py's
  # _stateful_checks and the coverage would quietly narrow -- so pin the set.
  if sp_drift="$(python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("g", ".claude/hooks/guard.py")
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)
want = {"/.claude/hooks/", "/.claude/settings.json", "/.claude/settings.local.json"}
if set(g.SELF_PROTECTED) != want:
    print(repr(sorted(g.SELF_PROTECTED)))
    sys.exit(1)
')"; then
    ok "SELF_PROTECTED still names exactly the paths _stateful_checks asserts"
  else
    fail "SELF_PROTECTED is now $sp_drift; give each entry an assertion in guard.py's _stateful_checks and update this list"
  fi

  # The six fleet-gate assertions that stood here are in guard.py's own
  # `_stateful_checks` now (#98, #139): parked here they could be deleted by a
  # PR that merged itself, and there they are part of the enforcement layer,
  # which never auto-merges. `--selftest` above is what runs them, and it fails
  # this script if any of them go red.
  #
  # Nothing is left behind on purpose. The first version of this move deleted
  # the two helpers and kept their call sites, so every run printed twelve
  # `command not found` lines to stderr, recorded no failure, and still said
  # "agent configuration is well-formed" -- the silent-success this file's own
  # header exists to warn about.

  rm -rf "$guard_tmp"
else
  fail ".claude/hooks/guard.py is missing or not executable"
fi

# And the wiring, end to end. The selftest calls the module's functions, which
# proves the rules; this proves the process -- stdin in, exit code out -- which
# is what settings.json actually depends on.
assert_hook() {
  local script="$1" want="$2" payload="$3" what="$4"
  [ -x "$script" ] || { fail "$script is missing; cannot check '$what'"; return; }
  printf '%s' "$payload" | "$script" >/dev/null 2>&1
  local got=$?
  [ "$got" = "$want" ] \
    && ok "$what" \
    || fail "$what: expected exit $want from $(basename "$script"), got $got"
}
G=.claude/hooks/guard.py
assert_hook "$G" 2 '{"tool_name":"Bash","tool_input":{"command":"gh pr merge 42"}}' \
  "the guard blocks over stdin, not just in-process"
assert_hook "$G" 0 '{"tool_name":"Bash","tool_input":{"command":"ctest --test-dir build"}}' \
  "...and allows ordinary work the same way"
assert_hook "$G" 2 'not json at all' \
  "an unreadable payload blocks rather than failing open"

echo "== the plugins the flow depends on"
# mattpocock-skills is not decoration: the brief in issue-command.sh tells every
# agent to run `/mattpocock-skills:code-review` (standards and spec-vs-diff,
# which the built-in review does not cover) and `/mattpocock-skills:tdd`. It is
# enabled in the COMMITTED settings.json, which is what makes it present in every
# worktree; drop the entry and the brief silently asks for a skill nobody has.
if python3 -c '
import json, sys
s = json.load(open(".claude/settings.json"))
sys.exit(0 if s.get("enabledPlugins", {}).get("mattpocock-skills@claude-plugins-official") else 1)
'; then
  ok "mattpocock-skills is enabled for every worktree"
else
  fail "mattpocock-skills is not enabled in .claude/settings.json, but the agent brief calls its skills"
fi

echo "== local review mode"
# Every one of these is a link in a chain whose breakage is SILENT, and the
# silence is the same in each case: merge-gate wants an independent review on the
# head, nothing produces one, and every PR the fleet opens waits forever. The
# mode exists precisely because that failure already happens by default on a
# repository with no CLAUDE_CODE_OAUTH_TOKEN.

# 1. The reviewer's brief. review.sh inlines it into the prompt, so a missing
#    file is a review submitted against no policy at all.
if [ -f .claude/agents/reviewer.md ]; then
  for needle in "review-findings" "independent-review: local" "REVIEW.md" \
                "mattpocock-skills:code-review"; do
    grep -q -- "$needle" .claude/agents/reviewer.md \
      || fail ".claude/agents/reviewer.md no longer mentions '$needle', which the reviewer has to write or read"
  done
  ok "the reviewer brief names both trailers, REVIEW.md and the standards pass"
else
  fail ".claude/agents/reviewer.md is missing, so local review mode has no brief"
fi

# 2a. REVIEW.md must not forbid the marker. It used to end the findings-trailer
#     rule with "and nothing else after it", which is exactly the second trailer
#     -- so a reviewer following the policy it is told to read "first and in
#     full" produced a review the gate then discarded. Found by the independent
#     review that hit it.
# Read with the whitespace squeezed out, because this is prose: a reflow that
# moved "nothing else" onto the next line would silence a line-oriented grep,
# and an assertion a reflow can switch off is not an assertion.
flat() { tr -s '[:space:]' ' ' <"$1"; }
if flat REVIEW.md | grep -q 'nothing else after it'; then
  fail "REVIEW.md still says nothing may follow the findings trailer, which forbids the local-review marker the gate requires"
elif grep -q 'independent-review: local' REVIEW.md; then
  ok "REVIEW.md allows the second trailer local review mode depends on"
else
  fail "REVIEW.md does not mention the local-review marker, so a reviewer reading it in full does not know to write one"
fi

# 2b. ...and it must not order a verdict GitHub refuses in this mode. `local`
#     means the reviewer is the PR's author, and GitHub declines
#     CHANGES_REQUESTED on your own pull request -- so a brief that orders
#     `--request-changes` for an Important finding ends the run with a non-zero
#     exit on its last action and nothing submitted.
if flat REVIEW.md | grep -q 'request changes on your own pull request' \
   && flat .claude/agents/reviewer.md | grep -q 'request changes on your own pull request'; then
  ok "REVIEW.md and the brief both say --request-changes is unavailable in local mode"
else
  fail "the reviewer is still told to --request-changes, which GitHub refuses on a self-authored PR"
fi

# 2. The marker, spelled the SAME WAY on both sides. review.sh tells the reviewer
#    what to write and merge_gate.py decides what counts; a drift between them is
#    a review that submits and is then ignored, which reads exactly like a
#    reviewer that never ran.
if grep -q 'independent-review:\\s\*local' .github/scripts/merge_gate.py \
   && grep -q 'independent-review: local' .claude/agents/reviewer.md; then
  ok "the local-review marker is spelled the same in the gate and in the brief"
else
  fail "the local-review marker has drifted between merge_gate.py and reviewer.md"
fi

# 3. The BASE-ref read. Drop `.autofleet/config` from that sparse-checkout and
#    review_mode() finds no file, returns `github`, and every PR on a local-mode
#    repository blocks -- with the workflow still green and nothing saying why.
# ONE step, not two greps. Checked separately, `.autofleet/config` could move to
# a head-ref checkout and both halves would stay green -- and a head-ref read is
# exactly the hole the base-ref read exists to close, since the PR would then be
# choosing the rule that judges it. Found by the local review of this change.
if python3 - <<'PYEOF'; then
import re, sys
wf = open(".github/workflows/merge-gate.yml").read()
# Each `- uses: actions/checkout` block, up to the next step at the same indent.
steps = re.split(r"\n      - (?=uses:|name:|id:)", wf)
for step in steps:
    # `startswith`, because split()'s first element is the whole file preamble --
    # which discusses both the checkout and the config in prose and would
    # otherwise be judged as if it were the step.
    if not step.startswith("uses: actions/checkout"):
        continue
    if ".autofleet/config" not in step:
        continue
    if "github.event.pull_request.base.sha" in step:
        sys.exit(0)
    sys.exit("the checkout that fetches .autofleet/config is not pinned to the base sha, "
             "so a pull request could turn on local review mode for itself")
sys.exit("no checkout step in merge-gate.yml fetches .autofleet/config; review_mode() "
         "would silently answer github and block every PR on a local-mode repository")
PYEOF
  ok "merge-gate.yml reads .autofleet/config from the BASE ref, in one checkout"
else
  fail "merge-gate.yml's base-ref read of .autofleet/config has come apart (above)"
fi

# 4. The guard that makes the marker mean anything. Without it the agent under
#    review can submit its own review and write its own marker, and every
#    assertion above stays green while the independence requirement is gone.
#
#    ANCHORED ON THE CONJUNCT, not on the words. This grepped for
#    `"pr", "review"`, which also matches guard.py's OUTWARD tuple -- a line that
#    predates the rule and governs only a STOPPED fleet. The whole rule could be
#    deleted with this check still green, which is precisely the shape hard rule
#    3 exists to forbid. Found by the local review of the PR that added it.
if grep -q '\["pr", "review"\] and _fleet_owns_this_worktree()' .claude/hooks/guard.py; then
  ok 'guard.py still refuses `gh pr review` from a fleet worktree'
else
  fail 'guard.py no longer refuses `gh pr review` from a fleet worktree, so an agent can forge its own independent review'
fi
#    ...and the REST spelling of the same act, which `Bash(gh api:*)` puts within
#    reach of every agent. `gh pr merge` has had both spellings guarded since it
#    was written; `gh pr review` shipped with only one.
if grep -q '/pulls/\\d+/reviews' .claude/hooks/guard.py; then
  ok '...and the `gh api .../pulls/N/reviews` spelling of it'
else
  fail 'guard.py does not refuse `gh api .../pulls/N/reviews`, which is the same act by its REST name'
fi
#    ...and the GraphQL one, which is the spelling with no path in it at all and
#    therefore the one a path-based rule cannot see. It had selftest rows and no
#    wiring assertion, alone among the three. Found by the independent review.
if grep -q 'addPullRequestReview' .claude/hooks/guard.py; then
  ok '...and the addPullRequestReview mutation, which carries no path to match'
else
  fail 'guard.py does not refuse the addPullRequestReview mutation, the one review spelling with no URL in it'
fi
#    ...and the three that came with it. Each was shipped with selftest rows and
#    no wiring assertion, which is the state this very block was added to fix one
#    change earlier -- "It had selftest rows and no wiring assertion, alone among
#    the three." Found by the independent review, correctly, one PR later.
if grep -q 'dismissPullRequestReview' .claude/hooks/guard.py; then
  ok '...and dismissPullRequestReview, which clears both merge_gate conditions at once'
else
  fail 'guard.py does not refuse dismissPullRequestReview; dismissing the review that found something clears the changes-requested block AND the answer requirement'
fi
if grep -q 'mergePullRequest' .claude/hooks/guard.py; then
  ok '...and mergePullRequest, the third name for an act blocked in two others'
else
  fail 'guard.py does not refuse mergePullRequest, so merging has two spellings blocked and one open'
fi
#    The body-carrying flags, by NAME. This one is a list rather than a rule
#    name, and a list is what silently loses an entry.
if python3 - <<'PYEOF'; then
import sys
src = open(".claude/hooks/guard.py").read()
# Sliced rather than matched with a pattern: a regex written here needs escapes
# that this file is generated through, and one of them arrived as a real newline
# and made the whole check a SyntaxError -- which `fail` then reported as the
# rule having lost a spelling. A check that cannot tell its own breakage from the
# breakage it looks for is worse than none.
try:
    head = src.index("_indirect = False")
    tail = src.index("if sub_cmd", head)
except ValueError:
    sys.exit("guard.py no longer builds an `_indirect` predicate; the rule that "
             "refuses a body this hook cannot read has changed shape")
block = src[head:tail]
for needle, why in [
    ('"--input"', "`gh api --input <file>` takes a plain path with no @ at all"),
    ('"--input="', "the equals spelling of the same"),
    ('startswith("@")', "a bare @file value"),
    ("=@", "the name=@file value form"),
]:
    if needle not in block:
        sys.exit("the indirect-body rule no longer covers " + needle + ": " + why)
PYEOF
  ok '...and it refuses every body-carrying spelling, not just the @ ones'
else
  fail 'guard.py: the rule refusing a body it cannot read has lost a spelling (above)'
fi

#    THE SUBMIT GRANT. Drop or misspell `Bash(gh pr review:*)` in review.sh's
#    tool list and the reviewer starts, reads the diff, spends its whole turn
#    budget, forms a verdict and CANNOT SUBMIT: exit 5, and every PR on a
#    local-mode repository blocked forever on a review that was actually
#    written. It is the one link in this chain with no assertion, and the suite
#    structurally cannot cover it -- `stub_reviewer` replaces the reviewer
#    command wholesale, so the allowlist is exercised by no test at all.
#
#    Both halves in one check, because .claude/agents/reviewer.md duplicates the
#    list in its frontmatter and ASSERTS that the two are identical. A drift
#    makes the registered subagent more powerful than the driven one, which is
#    the thing that paragraph exists to prevent. Found by the independent review.
if python3 - <<'PYEOF'; then
import re, sys
driven = open("scripts/fleet/review.sh").read()
brief = open(".claude/agents/reviewer.md").read()

block = re.search(r"^tools=.*?(?=\n\n)", driven, re.S | re.M)
if not block:
    sys.exit("scripts/fleet/review.sh no longer builds a `tools=` allowlist")
granted = set(re.findall(r"[A-Za-z]+\([^)]*\)|(?<![\w(])[A-Z][A-Za-z]+(?![\w)])",
                         block.group(0).replace("tools=", "").replace('"$tools,', "")))
if "Bash(gh pr review:*)" not in granted:
    sys.exit("review.sh does not grant `Bash(gh pr review:*)`, so its reviewer can "
             "read the whole diff and then not submit -- exit 5, and the PR blocks "
             "on a review that was written")
if "Bash(gh api:*)" in granted:
    sys.exit("review.sh grants `Bash(gh api:*)` again. It is withheld on purpose: "
             "in local mode the reviewer holds the maintainer's own gh login, and "
             "that is the one grant on the list with no ceiling. "
             "docs/CONFIGURATION.md carries it as a row in what local gives up")

front = re.search(r"^tools:\s*(.+)$", brief, re.M)
if not front:
    sys.exit(".claude/agents/reviewer.md has no `tools:` frontmatter, so the "
             "registered subagent inherits everything")
declared = {t.strip() for t in front.group(1).split(",") if t.strip()}
# The brief may not grant MORE than the driven route. Fewer is safe.
extra = declared - granted
if extra:
    sys.exit("reviewer.md's frontmatter grants what review.sh does not: "
             + ", ".join(sorted(extra))
             + " -- the registered subagent would be more powerful than the "
               "driven one, which is what that file's own note says it must not be")
PYEOF
  ok 'the reviewer can submit, cannot reach `gh api`, and the two routes agree'
else
  fail "the reviewer's tool allowlist has drifted (above)"
fi

#    Everything the payload POINTS AT must be in the payload. docs/CONFIGURATION.md
#    was cited by eight shipped files -- including a markdown link in REVIEW.md --
#    while shipping nowhere, so the link 404'd in every host repo. Hard rule 1.
#    Found by the independent review.
if python3 - <<'PYEOF'; then
import re, subprocess, sys
payload = re.search(r"PAYLOAD=\((.*?)\n\)", open("install.sh").read(), re.S)
if not payload:
    sys.exit("install.sh has no PAYLOAD list to check")
ships = set(re.findall(r'"([^"]+)"', payload.group(1)))
docs = ["docs/WORKFLOW.md", "docs/CONFIGURATION.md", "docs/RUNNERS.md", "REVIEW.md"]
searched = ["scripts/fleet", ".claude/hooks", ".claude/agents", ".github/scripts",
            "evals/lint.sh", "REVIEW.md", "docs/WORKFLOW.md", "install.sh"]
missing = []
for doc in docs:
    if doc in ships:
        continue
    hits = subprocess.run(["grep", "-rl", "--", doc.split("/")[-1]] + searched,
                          capture_output=True, text=True).stdout.split()
    hits = [h for h in hits if h != doc]
    if hits:
        missing.append(f"{doc} is named by {', '.join(sorted(hits))} and is not in PAYLOAD")
if missing:
    sys.exit("the payload points at documents it does not ship:\n  " + "\n  ".join(missing))
PYEOF
  ok "every doc the payload points at is a doc the payload ships"
else
  fail "install.sh ships files that link to documents it does not (above); those links 404 in every host repo"
fi

# 4b. The runner seam, asserted rather than believed.
#
#    Two ways it rots, and only something reading BOTH files can see either:
#    a `runner_*` the fleet calls that no driver defines is a dispatcher that
#    dies the first time it takes that path, and a driver function that
#    docs/RUNNERS.md does not describe is a contract a second driver cannot
#    implement -- which is the whole of armaatus/autofleet#1. The drafted
#    contract had already drifted from the code by three functions before it was
#    made real. Found by the independent review.
#
#    lib.sh may PROVIDE a contract function (runner_agent_terminal is a filter
#    over runner_agent_terminals, with nothing runner-specific in it), so it
#    counts as a definition; a driver that defines its own still wins, because
#    lib.sh defines it before it sources the driver.
if python3 - <<'PYEOF'; then
import re, sys, glob

def defined(path):
    return set(re.findall(r"^(runner_[a-z_]+)\(\)", open(path).read(), re.M))

drivers = sorted(glob.glob("scripts/fleet/runner/*.sh"))
if not drivers:
    sys.exit("no runner driver ships; scripts/fleet/runner/ is empty")

# COMMENTS ARE STRIPPED, for the same reason 4c strips them and found by the
# same review: this check read every `runner_[a-z_]+` token in the file,
# including the ones inside prose, so a comment that merely NAMES a function the
# fleet does not call failed the check as a contract the drivers had broken. It
# fired the moment a comment in issue-command.sh explained why a local variable
# must not be called `runner_rc` -- the check tripping over its own
# documentation. A function that appears only in a comment is not called, so
# stripping can only shrink the required set, never hide real drift.
def strip_comment(line):
    """The line with a trailing shell comment removed, quotes respected.

    `re.sub(r"#.*", "", line)` cut at the first `#` ANYWHERE, and fleet.sh is
    full of `"#$num: ..."` strings -- so everything after one was invisible.
    Round eight fixed that in 4c's awk; this is the same fix in 4b, which had it
    too. The direction it matters in is the FALSE NEGATIVE: a real call after a
    `"#..."` string on the same line was invisible, so `say "#7: x"; runner_nope`
    passed.

    Quoted spans are deliberately NOT removed, even though a `runner_*` name
    inside a message string is not a call and will be reported as one. Removing
    them would be worse: `list="$(runner_agent_terminals)"` is a call INSIDE
    double quotes, and command substitution in a quoted string is how most of
    this file reaches the driver. A false positive here says "the contract and
    the code disagree" and is fixed by rewording one message; a false negative
    lets a driver ship without a function the fleet calls.
    """
    out, quote = [], ""
    for ch in line:
        if not quote:
            if ch in "\"'":
                quote = ch
            elif ch == "#":
                break
        elif ch == quote:
            quote = ""
        out.append(ch)
    return "".join(out)

def code_only(text):
    return "\n".join(strip_comment(line) for line in text.splitlines())

provided = defined("scripts/fleet/lib.sh")
called = set()
for path in glob.glob("scripts/fleet/*.sh"):
    called |= set(re.findall(r"\brunner_[a-z_]+", code_only(open(path).read())))
called -= provided

# Only the ```sh CONTRACT FENCES count as documentation. Any mention anywhere in
# the page used to, which made this half of the check vacuous: a function deleted
# from the contract block still passed because some paragraph further down
# happened to say its name. The page's job is to be the thing a second driver is
# written against, and that is the fences. Found by the independent review of the
# change that added this check.
doc = open("docs/RUNNERS.md").read()
documented = set()
for fence in re.findall(r"```sh\n(.*?)```", doc, re.S):
    documented |= set(re.findall(r"^runner_[a-z_]+", fence, re.M))
if not documented:
    sys.exit("docs/RUNNERS.md has no ```sh contract block; this check now asserts nothing")

bad = []
for driver in drivers:
    defines = defined(driver)
    for name in sorted(called - defines):
        bad.append(f"{name} is called by the fleet and {driver} does not define it")
    for name in sorted(defines - documented):
        bad.append(f"{driver} defines {name} and docs/RUNNERS.md never names it")
for name in sorted(provided - documented):
    bad.append(f"lib.sh provides {name} and docs/RUNNERS.md never names it")
# ...and the other direction, which the check missed on its first pass: a name on
# the page that nothing defines is a function a second driver would implement for
# nobody, and it is exactly how the drafted contract came to carry three of them.
# Found by the independent review of the change that added this check.
everywhere = provided | set().union(*(defined(d) for d in drivers))
for name in sorted(documented - everywhere):
    bad.append(f"docs/RUNNERS.md names {name} and nothing defines it")
if bad:
    sys.exit("the runner contract and the code disagree:\n  " + "\n  ".join(bad))
PYEOF
  ok "every runner_* the fleet calls is defined by every driver, and documented"
else
  fail "the runner contract has drifted from the code (above); a second driver cannot be written against a page that is wrong"
fi

# 4c. The acceptance line of armaatus/autofleet#1, run rather than quoted.
#
#    CLAUDE.md hard rule 4 states this grep AS the rule, docs/RUNNERS.md says
#    "returning nothing is what keeps it that way", and runner/README.md calls it
#    "checkable rather than aspirational" -- and nothing checked it. 4b above
#    cross-checks runner_* NAMES, which is a different question; `runner_stub`
#    covers only the paths it drives, so stop.sh, setup.sh, env.sh, reap.sh,
#    review.sh, await-review.sh, answer-review.sh and record-review.sh could all
#    reintroduce a `$ORCA_CLI` and ship green through both. Hard rule 3 is that a
#    rule with no assertion is not shipped, and this is the change that turned
#    the convention into a rule. Found by the independent review.
#    The PATTERN is a case-insensitive `orca`, and it got there in three steps,
#    each one a review finding rather than a tidy-up.
#
#    `ORCA_CLI\|orca ` could not see the driver's own knobs (`ORCA_DEADLINE`) or
#    `orca` at end of line (`command -v orca`, `exec orca`, `mkdir -p .orca`).
#    `ORCA_\|orca\b` could not see `orca_cli_resolve`, `orca_cli` or `orca_json`
#    AT ALL -- `_` is a word constituent, so `\b` does not match after `orca`,
#    and `ORCA_` is uppercase-only -- nor the `Orca` spelling in a runtime
#    message. That was not hypothetical: one of the two leaks this PR removed was
#    `issue-command.sh`'s `orca_cli_resolve` call, which matched neither pattern,
#    and `agent-autostart.sh`'s sibling was caught only because its MESSAGE
#    happened to contain `orca `. `tolower(out) ~ /orca/` sees all of it.
#
#    And the comment is truncated by a QUOTE-AWARE scan, not `sub(/#.*/, ...)`:
#    that cut at the first `#` anywhere, and `fleet.sh` is full of `"#$num: ..."`
#    strings, so everything after one was invisible to this check. The mirror
#    image of the false positive round six fixed. `ORCA_CLI\|orca ` could not see
#    `ORCA_DEADLINE`, `ORCA_SEND_DEADLINE` or `ORCA_CREATE_DEADLINE` -- the
#    driver's own knobs -- nor `orca` at end of line: `command -v orca`,
#    `exec orca`, `mkdir -p .orca`. Round two's finding ON THIS PR was
#    agent-autostart.sh exporting a variable only the driver reads; spelled
#    `ORCA_DEADLINE=20` it shipped green through the old pattern, and 4b does not
#    see it either because 4b asks about runner_* NAMES. The tighter pattern
#    found two live ones: `mkdir -p .orca` in record-review.sh and await-review.sh,
#    left behind when the review marker moved to .autofleet/run -- so
#    record-review.sh made a directory nothing uses and wrote into one nothing
#    made.
#
#    COMMENTS ARE EXCLUDED, and that is a real narrowing rather than a
#    convenience: this repo's comments cite `orca.yaml` and the app by name all
#    over, on purpose -- hard rule 4 is that the dependency is NAMED, not hidden.
#    What the rule forbids is CODE outside the driver reaching for the runtime.
#    `config.sh` is the one exception, and the only one: it is where the default
#    driver is chosen, so naming one there is the choice rather than a leak.
#
#    The comment is STRIPPED rather than the line skipped, because a `grep -v`
#    on a leading `#` only sees whole-line comments. `AUTOFLEET_RUNNER=tmux  #
#    not orca` is code plus prose, and skipping-on-leading-# failed it as a
#    broken seam while permitting the identical words a line higher -- which is
#    the opposite of the rule in all three places that state it. Latent when it
#    was found (lint was green); it would have fired on the first person to
#    annotate a line instead of a block. Found by the review of the round-five
#    fix.
if leak="$(grep -rni 'orca' scripts/fleet --include='*.sh' \
               | grep -v '^scripts/fleet/runner/' \
               | awk 'BEGIN { sq = sprintf("%c", 39) }
                 {
                   code = $0
                   sub(/^[^:]*:[0-9]+:/, "", code)   # drop path:lineno:
                   # Truncate at the first # that is NOT inside quotes, so a trailing comment
                   # is prose and a `"#$num"` in the middle of a line does not hide the rest.
                   out = ""; q = ""
                   for (i = 1; i <= length(code); i++) {
                     c = substr(code, i, 1)
                     if (q == "") {
                       if (c == "\"" || c == sq) q = c
                       else if (c == "#") break
                     } else if (c == q) q = ""
                     out = out c
                   }
                   if (tolower(out) ~ /orca/) print
                 }' \
               | grep -v '^scripts/fleet/config.sh:[0-9]*:: "${AUTOFLEET_RUNNER:=orca}"$')"; then
  fail "the runner seam is broken -- these reach for one runner's CLI from outside scripts/fleet/runner/:
$(printf '%s\n' "$leak" | sed 's/^/    /')"
else
  ok "nothing outside scripts/fleet/runner/ reaches for the orca CLI"
fi

# 4d. ...and the two pages that PRINT that pipeline print the one that runs.
#
#    Both `docs/RUNNERS.md` and `scripts/fleet/runner/README.md` reproduce 4c's
#    command in a ```sh fence, and CLAUDE.md hard rule 4 now says "the exact
#    pipeline is in docs/RUNNERS.md" -- so those fences are the authoritative
#    statement of the rule, not a decoration. They drifted immediately: 4c was
#    fixed to STRIP the comment and both pages went on publishing the version
#    that SKIPPED whole-line comments, which disagrees with 4c on exactly the
#    line round six's finding was about (`AUTOFLEET_RUNNER=tmux  # not orca` is
#    a leak to the page and clean to the check). Both pages ship -- RUNNERS.md
#    in install.sh's PAYLOAD, README.md inside scripts/fleet -- so a host repo
#    got the wrong pipeline and a maintainer running it by hand got a different
#    verdict from CI.
#
#    4b cannot see this: it compares runner_* NAMES. Found by the independent
#    review of the change that fixed 4c.
if python3 - <<'PYEOF'
import re, sys

def core(text):
    """The command, with whitespace normalised away and NOTHING ELSE.

    This used to strip comments before comparing -- which normalised the awk's
    own comment-handling line to a stub on BOTH sides, so a page publishing a
    different comment regex there compared equal. That line is precisely the
    stage whose semantics were the drift 4d exists to catch, so 4d had a hole
    exactly where it mattered. Comparing the text verbatim means a page has to
    carry the explanatory comments too -- which is right: they are the reason
    the fence is readable, and a maintainer running it by hand gets them.
    Found by the independent review.
    """
    return re.sub(r"\s+", " ", text).strip()

lint = open("evals/lint.sh").read()
m = re.search(r"if leak=\"\$\((.*?)\)\"; then", lint, re.S)
if not m:
    sys.exit("could not find 4c's own pipeline in evals/lint.sh; this check now asserts nothing")
want = core(m.group(1))

bad = []
for path in ("docs/RUNNERS.md", "scripts/fleet/runner/README.md"):
    doc = open(path).read()
    # Anchored on `grep -rn`, not on the PATTERN: 4d's own regex named the
    # pattern it was written against, so widening the pattern made both pages
    # "no longer print the seam grep at all" -- a check that breaks when the
    # thing it guards is legitimately edited. It caught the drift, which is the
    # point, but for the wrong reason.
    fence = re.search(r"```sh\n(grep -rn.*?)```", doc, re.S)
    if not fence:
        bad.append(f"{path} no longer prints the seam grep at all")
        continue
    if core(fence.group(1)) != want:
        bad.append(f"{path} prints a different pipeline from the one 4c runs")
if bad:
    sys.exit("the published seam check has drifted from the one that runs:\n  "
             + "\n  ".join(bad))
PYEOF
then
  ok "both pages print the seam check that evals/lint.sh actually runs"
else
  fail "the seam check in the docs is not the seam check in the lint (above); hard rule 4 cites docs/RUNNERS.md as exact, and both pages ship to host repos"
fi

# 4e. ...and CLAUDE.md does not restate it.
#
#    BELOW 4d's `fi`, not inside its success branch -- which is where this was
#    first written. `fail()` counts and returns rather than exiting, so a failing
#    4d skipped 4e and the output said nothing about a check not having run: a
#    guard that silently stops guarding, on a guard added because hard rule 4
#    went stale in prose twice. Found by the independent review of the commit
#    that added it.
#
#    4d compares FENCES, and CLAUDE.md states hard rule 4 in prose, so it is
#    structurally outside 4d -- which is exactly where the rule went stale twice.
#    Round five put the pattern in that paragraph, round eight proved the pattern
#    blind, and round nine found CLAUDE.md still publishing it: the file every
#    agent reads first, handing out a grep that returns nothing on the very leak
#    this PR removed. An agent checking hard rule 4 with it concludes the seam is
#    intact.
#
#    The rule cannot be asserted in prose, so the fix is to keep the pipeline OUT
#    of the prose: CLAUDE.md describes the rule and points at docs/RUNNERS.md for
#    the command. This check fails if a command comes back, which is the only
#    form of drift that can mislead. Found by the independent review.
#    ANCHORED ON "a grep that mentions orca", not on a spelling. The first
#    version matched `grep -rn` or `grep -rni` followed by `orca`, plus the
#    literal `ORCA_\|orca` -- the two spellings the rule had HAD. A restatement
#    as `grep -rIni 'orca' scripts/fleet` or `grep -rn --include='*.sh' -i orca`
#    matched neither, and 4e would print its ok line while the pipeline sat back
#    in the one file every agent reads first. That is exactly the defect 4d
#    fixed in itself one round earlier, in the sibling that did not get the same
#    treatment. Found by the independent review.
#
#    A line carrying both `grep` and `orca` is the shape of a restatement and
#    nothing else: hard rule 4's prose says "shells out to `orca`" on one line
#    and "runs the grep that says so" on another, and neither carries both.
#    `.` and not `[^\n]`: grep is line-based, so `.` cannot cross a newline
#    anyway -- while `[^\n]` in a bracket expression excludes the literal letter
#    `n`, which every spelling of the flags contains (`-rni`). The first version
#    of this widening matched nothing at all for that reason, and said ok.
#    IN PYTHON, like 4b and 4d, and not because the shell could not do it: three
#    layers of quoting -- python heredoc into a shell string into an ERE -- ate
#    the backslashes twice while this check was being written, and each time the
#    result was a check that printed `ok` and matched nothing. A guard whose
#    escaping is hard to read is a guard nobody notices has stopped guarding,
#    which is the whole of hard rule 3.
if python3 - <<'PYEOF'
import re, sys

# Two shapes, because the rule has been restated as both already:
#   1. a grep command line that mentions orca, in either order;
#   2. the bare PATTERN, with its BRE alternation next to orca -- which is what
#      the paragraph carried for four rounds, with no `grep` on the line at all.
#
# Prose naming `ORCA_DEADLINE` or `orca_cli_resolve` as EXAMPLES is not a
# restatement, and must not match: what distinguishes the pattern form is the
# `\|` alternation beside the word, not the word.
SHAPES = (
    re.compile(r"grep.*orca|orca.*grep", re.I),
    re.compile(r"orca[^ ]*\\\||\\\|[^ ]*orca", re.I),
)

try:
    lines = open("CLAUDE.md").read().splitlines()
except OSError as e:
    sys.exit(f"could not read CLAUDE.md, so hard rule 4's wording is unchecked: {e}")

bad = [f"{n}: {ln.strip()}" for n, ln in enumerate(lines, 1)
       if any(sh.search(ln) for sh in SHAPES)]
if bad:
    sys.exit("CLAUDE.md restates the seam pipeline:\n    "
             + "\n    ".join(bad)
             + "\n  It is prose, so 4d cannot check it, and it has gone stale twice."
               "\n  Describe the rule there and let docs/RUNNERS.md carry the command.")
PYEOF
then
  ok "CLAUDE.md describes hard rule 4 without restating the command 4d guards"
else
  fail "hard rule 4's own paragraph carries the command again (above)"
fi

# 5. The dispatcher is what runs it. review.sh existing and never being called is
#    the same outcome as it not existing.
if grep -q 'review_open_prs' scripts/fleet/fleet.sh; then
  ok "the dispatcher's poll calls review_open_prs"
else
  fail "fleet.sh no longer calls review_open_prs, so nothing starts the local reviewer"
fi

# 6. ...and the installer ships it.
for shipped in ".claude/agents/reviewer.md"; do
  grep -q "\"$shipped\"" install.sh \
    || fail "install.sh does not ship $shipped, so a host project vendors a broken local review mode"
done
grep -q 'AUTOFLEET_REVIEW_MODE' install.sh \
  || fail "install.sh never mentions AUTOFLEET_REVIEW_MODE, so a host project is not told the default needs a secret"
ok "install.sh ships the reviewer and names the knob"

# 7. `fleet.sh status` names which reviewer is going to answer. This is the one
#    line whose whole purpose is to speak when everything else is quiet -- a
#    `github`-mode repository with no token has a green review job, a waiting
#    agent, and nothing anywhere saying which reviewer it is waiting for.
if grep -q 'AUTOFLEET_REVIEW_MODE' scripts/fleet/fleet.sh \
   && sed -n '/^cmd_status()/,/^}/p' scripts/fleet/fleet.sh | grep -q 'review:'; then
  ok "fleet.sh status names the review mode on its first screen"
else
  fail "fleet.sh status no longer names the review mode, so nothing says which reviewer a waiting agent is waiting for"
fi

# 8. THE GATE AND THE SHELL AGREE, spelling for spelling.
#
#    This is the assertion whose absence let the two disagree in the BLOCKING
#    direction. `merge_gate.review_mode()` read `: "${X:=local}"` as local while
#    every shell consumer read github, because config.sh's own default runs
#    before `.autofleet/config` is sourced -- so a host copying the style it sees
#    all over config.sh got a gate sitting in local mode waiting for a review no
#    dispatcher would ever start. The check that existed compared the gate to the
#    INSTALLER, never to the shell that actually runs the fleet.
#
#    Driven by sourcing config.sh for real, not by a second regex. A paraphrase
#    of the shell is what is being tested here; using one to test it would assert
#    that two copies of the same mistake match. Found by the independent review.
if python3 - <<'PYEOF'; then
import os, shutil, subprocess, sys, tempfile
sys.path.insert(0, ".github/scripts")
# The environment wins in review_mode() -- deliberately, for --selftest -- so an
# exported value here would make every answer below the same constant and the
# assertion vacuous. That happened to the installer check beside this one.
os.environ.pop("AUTOFLEET_REVIEW_MODE", None)
from merge_gate import review_mode

SPELLINGS = [
    "AUTOFLEET_REVIEW_MODE=local",
    "AUTOFLEET_REVIEW_MODE='local'",
    'AUTOFLEET_REVIEW_MODE="local"',
    "export AUTOFLEET_REVIEW_MODE=local",
    "  AUTOFLEET_REVIEW_MODE=local",
    ': "${AUTOFLEET_REVIEW_MODE:=local}"',
    "# AUTOFLEET_REVIEW_MODE=local",
    # The two the list was missing, and the reason it was missing them is that
    # it was written from the shapes the gate accepts rather than from the shapes
    # a person types. Both made the two readers disagree.
    "AUTOFLEET_REVIEW_MODE=LOCAL",
    "AUTOFLEET_REVIEW_MODE= local",
    "AUTOFLEET_REVIEW_MODE=Local",
    "AUTOFLEET_REVIEW_MODE=local\nAUTOFLEET_REVIEW_MODE=github",
    "AUTOFLEET_REVIEW_MODE=whatever",
    "",
]
root = os.getcwd()
bad = []
for text in SPELLINGS:
    d = tempfile.mkdtemp()
    os.makedirs(os.path.join(d, ".autofleet"))
    open(os.path.join(d, ".autofleet", "config"), "w").write(text + "\n")
    gate = review_mode(root=d)
    # ...and what the shell is left holding, from config.sh itself.
    # `fleet_review_mode`, not the raw variable: an unrecognised value leaves
    # the variable holding itself while every consumer treats it as github, and
    # comparing the raw string would report a disagreement that is not one --
    # then be silenced by whoever normalised the comparison instead of the code.
    # The function IS what the fleet asks, so it is what this asks.
    shell = subprocess.run(
        ["bash", "-c",
         'REPO_ROOT="$1"; cd "$2"; AUTOFLEET_CONFIG="$1/.autofleet/config"; '
         '. "$2/scripts/fleet/lib.sh"; fleet_review_mode',
         "_", d, root],
        capture_output=True, text=True,
    ).stdout.strip()
    shutil.rmtree(d)
    if gate != shell:
        bad.append(f"{text!r}: gate says {gate!r}, the shell holds {shell!r}")
if bad:
    sys.exit("merge_gate.review_mode() and scripts/fleet/config.sh disagree:\n  "
             + "\n  ".join(bad))
PYEOF
  ok "merge_gate.review_mode() and the shell read .autofleet/config the same way"
else
  fail "the gate and the shell disagree about the review mode (above); one of them will block every PR"
fi

# 9. ...and install.sh normalises every spelling of `local` that the gate can READ.
#    This repo's own .autofleet/config says `local`, and install.sh seeds that
#    file verbatim. If the installer's matcher is narrower than
#    merge_gate.REVIEW_MODE_RE, a rewording of the line here silently ships the
#    weaker mode to every host project -- "chosen by nobody and announced
#    nowhere", which is the outcome the installer's own comment says it prevents.
#    Found by the local review of the change that added it.
if python3 - <<'PYEOF'; then
import re, subprocess, sys, tempfile, os, shutil
# `review_mode()` reads the environment before the file, so an exported value
# would make `seen_by_gate` the same constant for every spelling and this whole
# assertion vacuous. Found by the independent review of the change that added it.
os.environ.pop("AUTOFLEET_REVIEW_MODE", None)
spellings = [
    "AUTOFLEET_REVIEW_MODE=local",
    "AUTOFLEET_REVIEW_MODE='local'",
    'AUTOFLEET_REVIEW_MODE="local"',
    "export AUTOFLEET_REVIEW_MODE=local",
    '  AUTOFLEET_REVIEW_MODE=local',
    ': "${AUTOFLEET_REVIEW_MODE:=local}"',
]
sys.path.insert(0, ".github/scripts")
from merge_gate import review_mode
src = open("install.sh").read()
m = re.search(r"ASSIGN = re\.compile\(\n(.*?)\n\s*re\.I,\n\)", src, re.S)
if not m:
    sys.exit("install.sh no longer has an ASSIGN pattern to check against the gate's")
# The two adjacent raw-string literals, concatenated the way Python would. The
# captured text ends in the `,` that separates them from `re.I`, so it has to go
# before this is an expression rather than a one-tuple.
literal = m.group(1).strip().rstrip(",")
try:
    pattern = re.compile(eval("(" + literal + ")"), re.I)
except Exception as exc:
    sys.exit(f"could not read install.sh's ASSIGN pattern ({exc}); it has changed shape")
bad = []
for line in spellings:
    d = tempfile.mkdtemp()
    os.makedirs(os.path.join(d, ".autofleet"))
    open(os.path.join(d, ".autofleet", "config"), "w").write(line + "\n")
    seen_by_gate = review_mode(root=d) == "local"
    shutil.rmtree(d)
    seen_by_installer = bool(pattern.match(line))
    if seen_by_gate and not seen_by_installer:
        bad.append(line)
if bad:
    sys.exit("install.sh would not normalise these, but merge_gate.py reads them "
             "as local: " + "; ".join(bad))
PYEOF
  ok 'install.sh normalises every spelling of `local` merge_gate.py can read'
else
  fail "install.sh's normalisation is narrower than merge_gate.py's reader (above)"
fi

echo "== the flow's own scripts"
# The brief names these by path. A rename that misses the brief turns into an
# agent halfway through a task running a command that does not exist.
for script in fleet.sh stop.sh await-review.sh review-status.sh record-review.sh \
              resolve-thread.sh answer-review.sh issue-command.sh agent-autostart.sh \
              review.sh; do
  path="scripts/fleet/$script"
  [ -x "$path" ] || { fail "$path is missing or not executable"; continue; }
  bash -n "$path" || { fail "$path does not parse"; continue; }
  ok "$script"
done
# ...and the brief must still name them.
brief="$(sed -n "/^sed .*BRIEF/,/^BRIEF$/p" scripts/fleet/issue-command.sh)"
for named in record-review.sh await-review.sh review-status.sh resolve-thread.sh \
              answer-review.sh; do
  grep -q "$named" <<<"$brief" \
    || fail "the agent brief no longer mentions $named, so the loop stops at that step"
done
ok "the brief still names the review loop"

echo "== every test phase actually runs"
# A phase defined in one of the phase-dispatching test scripts and missing from
# the SUITES registry in tests/run.sh never runs -- not locally, not in CI -- and
# is indistinguishable from a phase that passes. It happened on the project this
# came from: the assertions for a whole behaviour shipped green by never being
# executed. The script and the registry are two files, so only something reading
# both can say they agree.
#
# Every suite in the registry, not one named here: the check that covered a
# single script by name missed the file that then grew ten phases in one change.
if python3 - <<'PHASES'
import os, re, sys

# WHICH repository is this -- asked ONCE, before anything is opened, so no path
# below can answer it differently.
#
# `evals/lint.sh` is vendored and `tests/` is not (CLAUDE.md Layout), so in a
# host installation there is no phase registry and nothing here to judge. The
# discriminator cannot be a generic name: `tests/` is the commonest test
# directory there is, and `tests/run.sh` is a common shell-project convention --
# this repository is the proof that it is the natural name to reach for. A host
# project with either gets told its agent configuration is broken, in a
# repository where nothing is wrong, on a check `agent-config.yml` runs on every
# PR. That is hard rule 1 with the damage landing on the payload.
#
# So the question is answered by autofleet OWN suite: one of the scripts
# tests/run.sh dispatches is present exactly when the registry it reads should
# be. Two earlier attempts at this got it wrong in the two available ways -- the
# directory, then only the missing-file branch, leaving a host repo with its own
# tests/run.sh to fail on a SUITES block it has never heard of. Both found by the
# independent review.
IN_AUTOFLEET = os.path.exists("tests/test_runner_bound.sh")
if not IN_AUTOFLEET:
    # NOT `ok`: the caller cannot print a green line for an assertion that did
    # not run. 77 is the runner convention this change adds, borrowed here so the
    # caller can tell "nothing to check" from "checked and agreed".
    print("  (autofleet suite is not here -- not vendored, so there is no phase registry)")
    sys.exit(77)
try:
    runner = open("tests/run.sh").read()
except OSError:
    # Absent in autofleet itself is this check silently stopping, which is the
    # thing hard rule 3 is about.
    sys.exit("autofleet suite is here but tests/run.sh is not; this check now asserts nothing")
block = re.search(r"SUITES=\((.*?)\n\)", runner, re.S)
if not block:
    sys.exit("tests/run.sh has no SUITES registry; this check now asserts nothing")

def phases_in(path):
    # Heredoc bodies are dropped first. The phases write stub `orca` and `gh`
    # scripts, and those carry their own two-space `case` arms -- `worktree)`,
    # `terminal)` -- which are shell being generated, not phases of this file.
    kept, delim = [], None
    for line in open(path).read().splitlines():
        if delim is not None:
            if line.strip() == delim:
                delim = None
            continue
        here = re.search(r"<<-?\s*[\'\"]?([A-Za-z_][A-Za-z0-9_]*)[\'\"]?\s*$", line)
        if here:
            delim = here.group(1)
        kept.append(line)
    body = "\n".join(kept).split('case "${1:-}" in', 1)[1]
    # What is left: the phase labels are the only ones at exactly two spaces, and
    # `*)` is the usage fallback.
    return set(re.findall(r"^  ([a-z0-9_]+)\)$", body, re.M))

bad = covered = 0
# The label each phase is REPORTED under, collected on the way past: `suite/phase`
# for a suite with phases, bare `suite` for one that runs whole. Built here rather
# than walked again below, so a change to the registry syntax needs one edit and
# not two. Found by the independent review.
labels = set()
for suite, listed in re.findall(r'"([a-z_]+):([^"]*)"', block.group(1)):
    if not listed.strip():
        labels.add(suite)
        continue
    labels.update(f"{suite}/{name}" for name in listed.split())
    script = f"tests/test_{suite}.sh"
    try:
        defined = phases_in(script)
    except (OSError, IndexError):
        print(f"{suite}: tests/run.sh registers phases for {script}, which does not dispatch on one")
        bad = 1
        continue
    listed = set(listed.split())
    for name in sorted(defined - listed):
        print(f"{name}: defined in {script}, never registered in tests/run.sh")
        bad = 1
    for name in sorted(listed - defined):
        print(f"{name}: registered in tests/run.sh, but {script} has no such phase")
        bad = 1
    covered += 1
if covered == 0:
    print("no suite in tests/run.sh was paired with a script; this check now asserts nothing")
    bad = 1

# The OTHER registry of phase labels. SKIPPABLE names the phases allowed to exit
# 77 rather than pass or fail, and it is the same two-files-must-agree problem:
# rename or split a phase and the stale entry goes on looking correct, until the
# first machine where that phase actually declines gets a hard FAIL naming a
# label the maintainer believes is listed. A registry nothing cross-checks is
# what hard rule 3 is about. Found by /code-review.
skippable = re.search(r'^SKIPPABLE="([^"]*)"', runner, re.M)
if not skippable:
    print("tests/run.sh has no SKIPPABLE registry; the skip allowlist now asserts nothing")
    bad = 1
else:
    for name in sorted(set(skippable.group(1).split()) - labels):
        print(f"{name}: allowed to skip in tests/run.sh, but no such phase is registered")
        bad = 1
sys.exit(bad)
PHASES
then
  ok "every phase-dispatching suite agrees with tests/run.sh, and SKIPPABLE names phases that exist"
elif [ "$?" = 77 ]; then  # NOTHING may go between the `if` list and here: $? is
                          # still the python block's status only while nothing
                          # else has run. shellcheck would flag the shape
                          # (SC2181) and nothing lints this file.
  # A host installation, where `tests/` was never vendored. Said, and not counted
  # as agreement: a green line for an assertion that did not run is the same
  # false comfort as a phase that stopped executing.
  :
else
  fail "the phase registries in tests/run.sh do not match the scripts; an unregistered phase never runs, and a stale SKIPPABLE entry allows nothing. The line above says which"
fi

echo "== the workflows parse as GitHub reads them"
# An invalid workflow file does not fail loudly: GitHub creates a run with no
# jobs, named after the file, and the check it was meant to report simply never
# appears. With `merge-gate` as a required check that reads as "pending forever"
# and nothing can merge. It happened once already --
# `pull_request_review_thread` is a webhook event, not a workflow trigger, and
# putting it in `on:` invalidated the whole file.
#
# Optional, because actionlint is not everywhere. CI has it, and says so.
if command -v actionlint >/dev/null 2>&1; then
  actionlint .github/workflows/*.yml || fail "actionlint rejects a workflow"
  ok "actionlint accepts every workflow"
else
  echo "  --: actionlint is not installed (brew install actionlint); CI still checks this"
fi

# claude-code-action authenticates by exchanging a GitHub OIDC token, so a job
# that uses it needs `id-token: write` -- at the job level, or inherited from the
# workflow. Without it the action retries three times, fails, and submits
# nothing. That is invisible in the way that matters: `merge-gate` then blocks
# every PR on a review that will never arrive, and the only clue is a red job
# nobody required. It cost the first real fleet run.
if ls .github/workflows/*.yml >/dev/null 2>&1; then
  if python3 - <<'PY'
import re, sys, glob

bad = []
for path in glob.glob(".github/workflows/*.yml"):
    text = open(path).read()
    if "claude-code-action" not in text:
        continue
    # Cheap and good enough: the token is needed somewhere in scope, and these
    # files declare permissions either at the top or on the job.
    if "id-token: write" not in text:
        bad.append(path)
for path in bad:
    print(path)
sys.exit(1 if bad else 0)
PY
  then
    ok "every workflow using claude-code-action grants id-token: write"
  else
    fail "a workflow uses claude-code-action without 'id-token: write'; the action cannot authenticate and will submit nothing"
  fi
fi

# `track_progress: true` forces the action into TAG mode, which waits for an
# @claude trigger phrase. On an automatic review there is none, so the action
# skips -- and the JOB GOES GREEN while nothing was reviewed. That is the worst
# shape a failure can take here: merge-gate then blocks every PR on a review
# that was never submitted, and the check that should have said so is passing.
# The KEY, not the word: the comment above the removal in claude-review.yml
# explains what track_progress does, and a bare grep flags its own explanation.
if grep -rnE "^[[:space:]]*track_progress:" .github/workflows/*.yml >/dev/null 2>&1; then
  fail "a workflow sets track_progress, which forces tag mode; an automatic review then skips silently while its job reports success"
else
  ok "no workflow forces tag mode on an automatic review"

fi

# Silence is this workflow's failure mode and it is invisible: the action can
# burn 35 turns and real money, decide a verdict, and end without ever running
# `gh pr review` -- is_error false, job green, nothing on the PR. That happened
# on #99 twice on one head, and every watcher downstream then waits forever for
# a review that already came and went.
#
# Two things have to stay true, and both are one careless edit from gone.
review_wf=".github/workflows/claude-review.yml"
if [ -f "$review_wf" ]; then
  grep -q "no verdict was submitted" "$review_wf" \
    || fail "claude-review.yml no longer notices a review that submitted nothing"
  ok "a review that submits nothing is reported"

  # It must stay a COMMENT. A generated review would satisfy merge_gate.py's
  # requirement for an independent review while carrying no judgement at all --
  # worse than the silence it replaces, because it would merge things.
  if sed -n '/say so if no verdict/,/^      - /p' "$review_wf" | grep -q "gh pr review"; then
    fail "the no-verdict notice submits a REVIEW; that would satisfy merge-gate with no judgement"
  fi
  ok "the no-verdict notice is a comment, never a review"

  # ...and the reviewer is told to declare what it found. Without the trailer
  # every review fails closed, so this does not break a PR -- it makes every one
  # of them wait for an answer to findings that may not exist, which is the
  # slow way for a gate to stop meaning anything.
  grep -q 'review-findings' "$review_wf" \
    || fail "claude-review.yml no longer tells the reviewer to end with <!-- review-findings: N -->, which merge_gate.py reads to tell a clean review from one with findings"
  ok "the reviewer is told to declare how many findings it left"
fi

# The reviewer is told to submit its verdict with a command it can actually run.
#
# `claude_args` grants Read, Grep, Glob and a fixed list of gh/git calls -- no
# Write, no generic Bash, no redirection and no mktemp. The prompt nonetheless
# told it to submit with `--body-file <file>`, a file it had no way to create.
# So a run only submitted at all if it improvised away from its instruction, and
# PR #131 got three green review runs and zero reviews out of it. A green job
# that did nothing is the shape nothing else here catches.
if [ -f "$review_wf" ]; then
  # 2>&1 because the checks below report by `sys.exit("...")`, which writes to
  # stderr; without it the failure would print a reason that is an empty string.
  if reason="$(python3 - "$review_wf" 2>&1 <<'REVIEWCMD'
import re, sys

text = open(sys.argv[1]).read()
# From `review:` to the next top-level job key, BY SHAPE. Naming the job that
# follows would hard-code the very thing the comment on the sed below says not
# to, and the two slices of this same file must not disagree.
start = text.find("\n  review:")
if start < 0:
    sys.exit("claude-review.yml has no `review:` job")
after = re.search(r"\n  [a-z][a-z_-]*:\n", text[start + 1:])
job = text[start:start + 1 + after.start()] if after else text[start:]

args = re.search(r"claude_args:\s*(.+)", job)
if not args:
    sys.exit("the review job has no claude_args, so what it may run is unknown")
allowed = args.group(1)
# Anything that could create a file for --body-file to read.
can_write = ("Write" in allowed
             or re.search(r"Bash(?!\()", allowed)
             or "Bash(mktemp" in allowed)
# The COMMAND, not the word: the prompt explains why --body-file is wrong, and a
# bare search flags its own explanation.
told_to = [ln for ln in job.splitlines()
           if "gh pr review" in ln and "--body-file" in ln]
if told_to and not can_write:
    sys.exit("the review prompt submits with `--body-file`, and the job grants "
             "no tool that can create a file: " + told_to[0].strip())
if "gh pr review" not in job:
    sys.exit("the review prompt no longer names `gh pr review`, so nothing tells "
             "it to submit a review at all")
if "Bash(gh pr review:" not in allowed:
    sys.exit("the review job does not allow `gh pr review`, so it cannot submit")
REVIEWCMD
)"
  then
    ok "the reviewer can run the command it is told to submit with"
  else
    # The check's OWN words. A fixed string here reported a renamed job or a
    # missing claude_args as "the reviewer cannot run its submit command",
    # which sends the reader to the wrong line.
    fail "claude-review.yml: $reason"
  fi

  # A review is not a build. Cancelling the run that was producing the verdict
  # leaves that head with none -- and the no-verdict notice is `needs: review`,
  # so it does not fire either. #86's merged head and #81's both show
  # `cancelled` for this job.
  # From `review:` to the next top-level job key, by shape rather than by name:
  # a range hard-coded to `verdict:` would silently swallow the rest of the file
  # the day that job is renamed, and pick up the `mention` job's own
  # cancel-in-progress -- a failure about the wrong job.
  if sed -n '/^  review:/,/^  [a-z][a-z_-]*:$/p' "$review_wf" \
       | grep -qE "^[[:space:]]*cancel-in-progress:[[:space:]]*true"; then
    fail "the review job cancels in progress; a killed review leaves the head with no verdict and nothing that says so"
  fi
  ok "a review in flight is never cancelled by the next event"

  # ...and when a review IS silent, the pipeline asks once more on its own. The
  # comment alone named two remedies and both were manual, so a PR whose review
  # said nothing waited for a person to notice it.
  grep -q 'gh workflow run claude-review.yml' "$review_wf" \
    || fail "a review that submitted nothing no longer asks for another one; the PR waits for a person"
  # ...and the run it asks for must be allowed to happen. A dispatch by
  # GITHUB_TOKEN runs as github-actions[bot], and claude-code-action refuses a
  # non-human actor unless it is named here -- so without this the retry starts
  # a run that always declines, which is a mechanism that cannot fire.
  grep -qE "^[[:space:]]*allowed_bots:.*(github-actions|\*)" "$review_wf" \
    || fail "the review job does not allow github-actions, so the review it asks for after a silent one is refused as a non-human actor"
  ok "a silent review asks for exactly one more, and that one is allowed to run"
fi

# A cancelled run is not a green run. `cancel-in-progress` is right on a branch,
# where only the newest push matters, and wrong on main, where every commit is
# one somebody has to be able to trust: two merges close together cancelled the
# earlier commit's build outright, and nothing re-ran it. #105 and #102 merged
# seconds apart and #105's main build died mid-flight.
if [ -f .github/workflows/ci.yml ]; then
  if grep -qE "^[[:space:]]*cancel-in-progress:[[:space:]]*true[[:space:]]*$" .github/workflows/ci.yml; then
    fail "ci.yml cancels in progress unconditionally, so a merge can cancel main's own build and that commit is never verified"
  fi
  ok "main's builds are never cancelled by the next merge"
fi

echo "== the labels a host has to create"
# config.sh names every label the dispatcher reads; install.sh's next-steps are
# the only place a host is TOLD to create them, and a label that does not exist
# is a label no issue can carry. A default added to one file and not the other
# is not a crash -- it is a queue that silently never orders anything the way the
# docs say it does, on somebody else's repo, where nobody here will see it.
#
# Only the install half is asserted. AUTOFLEET_READY_LABEL is read by nothing
# today -- `ready` is a literal in ready_issues, while its three neighbours are
# threaded through properly and AUTOFLEET_BLOCKED_LABEL is read at the
# "its issue went blocked" path -- and that one is #57. Asserting the read half
# here would go red on a defect this file cannot fix.
#
# COUNTED, not just looped over. The rows come out of a `sed` that knows the
# `: "${X:=y}"` shape config.sh writes defaults in; reflow those lines, or write
# the next one as a plain assignment, and this loop runs zero times and prints
# `ok` while asserting nothing. That is the failure this whole file exists to
# refuse -- the SUITES check two sections UP says so in the same words.
labels_ok=1
labels_seen=0
while read -r var default; do
  [ -n "$var" ] || continue
  labels_seen=$((labels_seen + 1))
  grep -q "gh label create $default " install.sh \
    || { fail "$var defaults to \`$default\`, and install.sh never tells a host to create that label"
         labels_ok=0; }
done < <(sed -n 's/^: "${\(AUTOFLEET_[A-Z_]*_LABEL\):=\([^}]*\)}"/\1 \2/p' scripts/fleet/config.sh)
if [ "$labels_seen" = 0 ]; then
  fail "no AUTOFLEET_*_LABEL default was found in scripts/fleet/config.sh; this check now asserts nothing"
elif [ "$labels_ok" = 1 ]; then
  ok "all $labels_seen label defaults in config.sh are ones install.sh tells a host to create"
fi

echo "== the cross-reference conventions"
# `Closes #N` and `Blocked by #N` are read by three parsers -- GitHub itself,
# unblock.yml, and fleet.sh via merge_gate.py's neighbour -- and every way they
# disagree is silent. The fleet either opens a second worktree for work already
# in flight, or reports "nothing startable" with the backlog wide open.
if [ -x .github/scripts/issue_refs.py ]; then
  python3 .github/scripts/issue_refs.py --selftest 2>&1 | sed 's/^/  /'
  [ "${PIPESTATUS[0]}" = 0 ] || fail "the issue-reference selftest does not hold"
else
  fail ".github/scripts/issue_refs.py is missing or not executable"
fi

# unblock.yml is JavaScript inside YAML and cannot import the module, so the one
# thing keeping the two in step is that they spell the patterns identically.
# Asserted from BOTH ends, and BEHAVIOURALLY rather than by grep: a textual
# assertion passes the moment the two strings match and says nothing about the
# marker scoping that now sits around them, which is half the rule. The workflow
# regex literals are lifted out, translated into Python, and run over
# issue_refs.SELFTEST -- the same table, the same expected answers. Anything the
# two disagree about is an issue the fleet may start while the labels call it
# blocked, or leave sitting while the labels call it ready.
if python3 - <<'PYEOF'; then
import importlib.util, re, sys

spec = importlib.util.spec_from_file_location("r", ".github/scripts/issue_refs.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

src = open(".github/workflows/unblock.yml").read()


def literal(name):
    """The JS regex `name` is assigned, as a Python pattern and flags."""
    hit = re.search(r"const\s+" + name + r"\s*=\s*/(.*)/([a-z]*);", src)
    if not hit:
        sys.exit(f"unblock.yml no longer assigns a {name} regex literal; this "
                 f"check can no longer see what it matches")
    pattern, js_flags = hit.group(1), hit.group(2)
    flags = 0
    if "i" in js_flags:
        flags |= re.IGNORECASE
    if "m" in js_flags:
        flags |= re.MULTILINE
    try:
        return re.compile(pattern, flags)
    except re.error as exc:
        sys.exit(f"unblock.yml's {name} is not a pattern Python can read ({exc}); "
                 f"the two readers can no longer be compared at all")


wf_blocked, wf_marker = literal("BLOCKED_BY"), literal("BLOCKERS_MARKER")

# The workflow's own scoping, spelled here the way the JS spells it: the LAST
# marker alone on a line, or the whole body when there is none.
def wf_blocked_by(body):
    text = body or ""
    last = None
    for hit in wf_marker.finditer(text):
        last = hit
    if last:
        text = text[last.end():]
    return [int(hit.group(1)) for hit in wf_blocked.finditer(text)]


bad = []
for body, _closes, want in m.SELFTEST:
    got = wf_blocked_by(body)
    if got != want:
        bad.append(f"{body!r}: the workflow reads {got}, issue_refs reads {want}")
if bad:
    sys.exit("unblock.yml and issue_refs.py disagree about which issues block "
             "which:\n  " + "\n  ".join(bad))
# ...and the table has to still be saying something. A selftest emptied of its
# blocker rows would pass the loop above without comparing anything.
if sum(1 for _b, _c, want in m.SELFTEST if want) < 5:
    sys.exit("issue_refs.SELFTEST no longer carries enough blocker rows for this "
             "comparison to mean anything")
PYEOF
  ok "the fleet and unblock.yml read the same blockers, over the same table"
else
  fail "unblock.yml and issue_refs.py no longer derive the same blockers (above); an issue one calls blocked the other will start"
fi

# The blocker rule that cost #47: a blocker is a LINE, below the marker. Both
# readers are checked on the two sentences CLAUDE.md actively invites agents to
# write into issue bodies -- through the module, so this fails if either the
# pattern or the scoping is loosened back.
python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("r", ".github/scripts/issue_refs.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
prose = ["no longer blocked by #7", "#40 was unblocked by #12 when that merged"]
sys.exit(0 if not any(m.blocked_by(p) for p in prose) else 1)
' || fail "prose saying an issue is NOT blocked registers as a blocker again; an agent editing its own issue body can get its own worktree reaped (#47)"
ok "negated prose does not block anything"

# The concurrency group. Every other workflow here has one; this is the one that
# now fires on every issue edit, from up to three worktrees that CLAUDE.md tells
# to edit issue bodies as they work. Two interleaved runs can land an issue
# `ready` with an open blocker, which is the foundation collision the label
# exists to prevent.
if python3 - <<'PYEOF'; then
import re, sys
src = open(".github/workflows/unblock.yml").read()
# Top level, not inside a job: a group under `jobs:` is indented.
hit = re.search(r"(?m)^concurrency:\n((?:[ \t]+\S.*\n)+)", src)
if not hit:
    sys.exit("unblock.yml has no top-level concurrency: group")
block = hit.group(1)
if not re.search(r"(?m)^\s+group:\s*\S", block):
    sys.exit("unblock.yml's concurrency: has no group:")
if not re.search(r"(?m)^\s+cancel-in-progress:\s*true", block):
    sys.exit("unblock.yml's concurrency: does not cancel in progress; the older "
             "run finishes last and writes the STALER labels, which is the "
             "inversion the group is here to stop")
# `github.ref` in the group would scope it per-branch, and every one of these
# runs on the default branch: that is one group with a name that suggests
# otherwise, and it would silently stop serialising if one ever did not.
if "github.ref" in block:
    sys.exit("unblock.yml scopes its concurrency group by ref; these runs are "
             "not per-branch and would stop serialising")
PYEOF
  ok "unblock.yml serialises its runs and the newest one wins"
else
  fail "unblock.yml's concurrency group is missing or would not serialise (above)"
fi

# The trigger list, named. Nothing asserted it, and dropping `opened` returns the
# repo to issues that carry no label and that `fleet.sh` will therefore never
# start -- silently, because an unstartable backlog looks exactly like an empty
# one. README.md and docs/WORKFLOW.md describe this list to agents, so it is
# checked against them too, below.
if python3 - <<'PYEOF'; then
import re, sys
src = open(".github/workflows/unblock.yml").read()
want = {"opened", "edited", "closed", "reopened"}
hit = re.search(r"(?m)^  issues:\n\s+types:\s*\[([^\]]*)\]", src)
if not hit:
    sys.exit("unblock.yml no longer lists issue trigger types inline; this check "
             "cannot see them")
got = {t.strip() for t in hit.group(1).split(",") if t.strip()}
if got != want:
    sys.exit(f"unblock.yml fires on issues {sorted(got)}; it has to fire on "
             f"{sorted(want)} -- an issue filed with no blockers carries no "
             f"label until one of these arrives, and fleet.sh starts nothing "
             f"without `ready`")
if not re.search(r"(?m)^  pull_request:\n\s+types:\s*\[\s*closed\s*\]", src):
    sys.exit("unblock.yml no longer fires on a closed pull request; a merge would "
             "stop unblocking its dependants")
if not re.search(r"(?m)^  workflow_dispatch:", src):
    sys.exit("unblock.yml can no longer be run by hand; it is the only way to "
             "recover a backlog whose labels have drifted")
PYEOF
  ok "unblock.yml fires on the triggers the docs promise"
else
  fail "unblock.yml's trigger list has changed (above)"
fi

# ...and docs/WORKFLOW.md names the same list. It is vendored, and it is what an
# agent reads before it edits an issue body -- so a page still saying the labels
# are derived "on every merge" tells that agent its edit is local when the edit
# relabels the entire backlog. README.md is deliberately NOT checked here: a host
# project keeps its own.
if python3 - <<'PYEOF'; then
import re, sys
src = open(".github/workflows/unblock.yml").read()
hit = re.search(r"(?m)^  issues:\n\s+types:\s*\[([^\]]*)\]", src)
types = [t.strip() for t in hit.group(1).split(",") if t.strip()] if hit else []
if not types:
    sys.exit("no issue trigger types to check the docs against")
page = open("docs/WORKFLOW.md").read()
missing = [t for t in types if f"`{t}`" not in page]
if missing:
    sys.exit("docs/WORKFLOW.md does not name the triggers unblock.yml fires on: "
             + ", ".join(missing))
if re.search(r"unblock\.yml[^.]{0,120}on every merge", page, re.S):
    sys.exit("docs/WORKFLOW.md still says the labels are derived on every merge; "
             "they are derived on every issue edit too, which is what makes an "
             "agent editing an issue body a backlog-wide event")
PYEOF
  ok "docs/WORKFLOW.md names the triggers unblock.yml actually fires on"
else
  fail "docs/WORKFLOW.md describes a trigger set unblock.yml no longer has (above)"
fi

# ...and the blast radius that made #47 urgent: one `issues.get` per distinct
# blocker, on a trigger that fires on every edit. A 5xx or a rate limit on one of
# them marked every dependant `blocked` -- which fleet.sh reads as "this worktree
# will never produce a merged PR" -- and reported it through `core.warning`, so
# the check stayed GREEN while three slots froze. The open page already answers
# "is #N open"; a regrown per-blocker lookup brings the whole path back.
#
# Over the CODE, not the comments. The file explains at length what it used to do
# and why it stopped, in the comment density CLAUDE.md asks for, and a plain grep
# reads that explanation as the thing itself -- the same reason hard rule 4's
# check 4c excludes comments from its own seam grep.
if python3 - <<'PYEOF'; then
import re, sys
src = open(".github/workflows/unblock.yml").read()
hit = re.search(r"(?m)^\s*script: \|\n(.*)\Z", src, re.S)
if not hit:
    sys.exit("unblock.yml has no inline `script: |` block; this check cannot see "
             "what the job runs")
script = hit.group(1)
# Line comments only. The file has no block comments and no string containing
# `//`; a URL would be the usual counter-example and there is none.
code = "\n".join(re.sub(r"//.*", "", line) for line in script.splitlines())
problems = []
if re.search(r"issues\.get\b", code):
    problems.append("it looks blockers up one at a time again (`issues.get`); a "
                    "transient failure on one of those marks every dependant "
                    "blocked, and fleet.sh reaps a live worktree over it")
if re.search(r"core\.warning\b", code):
    problems.append("it reports through `core.warning` again, which leaves the "
                    "run GREEN while the labels it just wrote are wrong")
if not re.search(r"\bopenNumbers\b", code):
    problems.append("it no longer answers `is #N open` from the page it already "
                    "fetched, so the per-blocker lookups have somewhere to regrow")
if not re.search(r"core\.info\([^)]*not open", code, re.S):
    problems.append("it no longer logs which blockers it treated as not open; an "
                    "issue filed before its own foundation goes `ready` with "
                    "nothing in the log to read afterwards")
if problems:
    sys.exit("unblock.yml (#47): " + "; ".join(problems))
PYEOF
  ok "unblock.yml reads blocker state from the page it already has, and says what it concluded"
else
  fail "unblock.yml can freeze the backlog behind a green check again (above)"
fi

# ...and EVERY function in the fleet that reads one of the two conventions gets
# it from the module. A `grep -q issue_refs` over the whole file would be
# satisfied by one surviving import while the other three regrew patterns of
# their own, which is precisely the drift this section exists to catch -- so
# each function is checked on its own, by name.
fleet_reads_shared=1
for fn in ready_issues has_open_pr issue_is_done count_startable; do
  body="$(sed -n "/^$fn()/,/^}/p" scripts/fleet/fleet.sh)"
  [ -n "$body" ] \
    || { fail "scripts/fleet/fleet.sh has no $fn(); this check no longer covers what it names"
         fleet_reads_shared=0; continue; }
  grep -q 'from issue_refs import' <<<"$body" \
    || { fail "fleet.sh's $fn() no longer imports issue_refs; it can drift from GitHub and unblock.yml again"
         fleet_reads_shared=0; }
  # Any regex of its own over either convention, in any spelling and either
  # language -- not just the two capitalisations it used to carry.
  if grep -inE '(close[sd]?|fix(e[sd])?|resolve[sd]?|blocked[^"]*by)[^"]*#' <<<"$body" \
     | grep -vi '^ *[0-9]*: *#' | grep -q .; then
    fail "fleet.sh's $fn() spells out a closing or blocker reference again; there is one place for those, .github/scripts/issue_refs.py"
    fleet_reads_shared=0
  fi
done
[ "$fleet_reads_shared" = 1 ] && ok "every fleet function reading a body reads the shared patterns"

echo "== the merge gate"
# The one required check `gh pr merge --auto` waits on. Its decision lives in a
# script rather than in the YAML precisely so it can be tested without a pull
# request -- and so a change to what "may merge" means fails here first.
if [ -x .github/scripts/merge_gate.py ]; then
  python3 .github/scripts/merge_gate.py --selftest 2>&1 | sed 's/^/  /'
  [ "${PIPESTATUS[0]}" = 0 ] || fail "the merge-gate selftest does not hold"
else
  fail ".github/scripts/merge_gate.py is missing or not executable"
fi
grep -q 'merge_gate.py' .github/workflows/merge-gate.yml \
  || fail "merge-gate.yml no longer calls merge_gate.py, so the check decides nothing"
# merge_gate.py imports issue_refs.py, and the gate job checks out
# `.github/scripts` ALONE. Widen that import to anything outside this directory
# and the gate stops with an ImportError -- a required check that can never
# conclude, on every PR.
# A LIST now, not one path: `.autofleet/config` rides along so review_mode() can
# read the mode in CI. Matched loosely enough to survive that becoming three
# paths, and strictly enough that dropping this one is still caught.
if ! grep -A6 'sparse-checkout' .github/workflows/merge-gate.yml | grep -q '\.github/scripts'; then
  fail "merge-gate.yml no longer sparse-checks-out .github/scripts; the paths merge_gate.py imports from are no longer the ones it gets"
fi
sparse_tmp="$(mktemp -d)"
cp -R .github/scripts "$sparse_tmp/scripts"
if ( cd "$sparse_tmp/scripts" && python3 -c 'import merge_gate' ) 2>"$sparse_tmp/err"; then
  ok "the gate still imports from the only directory it is given"
else
  fail "merge_gate.py does not import with only .github/scripts on disk, which is all the gate job checks out: $(tr '\n' ' ' <"$sparse_tmp/err")"
fi
rm -rf "$sparse_tmp"

# One query, paginated, in one file. `reviewThreads(first:100)` is the FIRST
# hundred: past that a PR silently loses its newest threads and the gate reports
# "no review thread is unresolved" from a page it knew was partial. Both readers
# used to carry their own copy of that query, and so their own copy of the bug.
if [ -x .github/scripts/pr_payload.sh ]; then
  bash -n .github/scripts/pr_payload.sh || fail ".github/scripts/pr_payload.sh does not parse"
  for reader in .github/workflows/merge-gate.yml scripts/fleet/review-status.sh; do
    grep -q 'pr_payload.sh' "$reader" \
      || fail "$reader does not read the PR through .github/scripts/pr_payload.sh, so it is paging threads on its own again"
    # Comment lines excluded: both files EXPLAIN what `reviewThreads(first:100)`
    # got wrong, and a bare grep flags its own explanation.
    grep -vE '^[[:space:]]*#' "$reader" | grep -q 'reviewThreads(first:' \
      && fail "$reader carries its own reviewThreads query again; the first page is not the list"
  done
  # merge-gate.yml runs BOTH of these out of the BASE branch's checkout, and a
  # base predating either one is a PR a person merges -- which has to be SAID.
  # Before the guard named both, the second one to be added killed the step with
  # `No such file or directory` on exactly the PR introducing it.
  for needed in merge_gate.py pr_payload.sh; do
    sed -n '/agreed rule to judge this by/,/^      - name:/p' \
      .github/workflows/merge-gate.yml | grep -q "$needed" \
      || fail "merge-gate.yml runs $needed from the base checkout without checking the base has it; a base predating it dies with a shell error instead of the human-merge notice"
  done
  ok "a base without the gate's own scripts is told, not crashed into"

  ok "the gate and review-status read one paginated payload"
else
  fail ".github/scripts/pr_payload.sh is missing or not executable"
fi

echo "== orca.yaml"
if [ ! -f orca.yaml ]; then
  fail "orca.yaml is missing; new worktrees would provision nothing"
else
  grep -q 'issue-command.sh' orca.yaml \
    || fail "orca.yaml's issueCommand no longer points at scripts/fleet/issue-command.sh, so a new worktree's agent starts from a bare URL"
  grep -q 'setupAgentStartupPolicy: wait-for-setup' orca.yaml \
    || fail "orca.yaml no longer holds the agent tab for setup; agents will run the tests against a rig that is not up"
  ok "orca.yaml still wires the agent to the spec"
fi

echo "== eval cases"
cases=(evals/cases/*.json)
[ "${#cases[@]}" -gt 0 ] || fail "evals/cases/ is empty; the eval job would pass by having nothing to run"
for case_file in "${cases[@]}"; do
  python3 -c '
import json, sys
c = json.load(open(sys.argv[1]))
for key in ("name", "prompt", "expect"):
    if key not in c:
        sys.exit("missing key: " + key)
e = c["expect"]
if not isinstance(e, dict) or not (e.get("contains") or e.get("absent")):
    sys.exit("expect must carry contains and/or absent")
' "$case_file" || fail "$case_file is not a well-formed eval case"
  ok "$(basename "$case_file")"
done

echo
if [ "$fails" -gt 0 ]; then
  echo "$fails problem(s) in the agent configuration." >&2
  exit 1
fi
echo "agent configuration is well-formed."
