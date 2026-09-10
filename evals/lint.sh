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

# 8. ...and normalises every spelling of `local` that the gate can READ.
#    This repo's own .autofleet/config says `local`, and install.sh seeds that
#    file verbatim. If the installer's matcher is narrower than
#    merge_gate.REVIEW_MODE_RE, a rewording of the line here silently ships the
#    weaker mode to every host project -- "chosen by nobody and announced
#    nowhere", which is the outcome the installer's own comment says it prevents.
#    Found by the local review of the change that added it.
if python3 - <<'PYEOF'; then
import re, subprocess, sys, tempfile, os, shutil
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
import re, sys

runner = open("tests/run.sh").read()
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
for suite, listed in re.findall(r'"([a-z_]+):([^"]*)"', block.group(1)):
    if not listed.strip():
        continue
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
sys.exit(bad)
PHASES
then
  ok "every phase-dispatching suite agrees with tests/run.sh"
else
  fail "a phase test script and tests/run.sh disagree about which phases exist; the ones above never run"
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
# thing keeping the two in step is that they spell the pattern identically.
# Asserted from BOTH ends: change either alone and this goes red.
grep -qF 'blocked\s+by\s+#(\d+)/gi' .github/workflows/unblock.yml \
  || fail "unblock.yml no longer matches blocked\\s+by\\s+#(\\d+)/gi; issue_refs.BLOCKED_BY is now a different rule from the one that maintains the labels"
python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("r", ".github/scripts/issue_refs.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
sys.exit(0 if m.BLOCKED_BY.pattern == r"blocked\s+by\s+#(\d+)" else 1)
' || fail "issue_refs.BLOCKED_BY no longer spells unblock.yml's pattern character for character"
ok "the fleet and unblock.yml read the same blockers"

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
