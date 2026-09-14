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

# `grep -q` on the RIGHT of a pipe is a flaky assertion here, and this file runs
# with `pipefail`. `-q` exits on the first match, the producer on the left then
# writes into a closed pipe, and the pipeline's exit status is that producer's
# EPIPE rather than grep's match -- so an assertion that HELD is reported as a
# FAIL. GNU sed says it out loud ("sed: couldn't flush stdout: Broken pipe");
# BSD sed dies quietly, which is why this is green on a Mac and red in CI, and
# why it is a race rather than a constant: it needs the match to land before the
# producer is done. It cost this PR a CI round on the one check at `cmd_status`
# below, and the other nine sites are the same bug waiting its turn.
#
# `grep` without `-q` reads its whole input, so there is nothing to break.
qgrep() { grep "$@" >/dev/null; }

# ---------------------------------------------------------------- the ceilings
# What a fleet agent is allowed to be given, in one table.
#
# Every limit this repo holds on the size of something an agent READS is a row
# here: the number, the issue that set it, what is measured, and what measures
# it. Prose grows back one useful paragraph at a time -- the opening brief
# reached 1,521 words that way and nothing objected at any single step -- so the
# only thing that holds a limit is a check that fails when it is crossed and a
# way to raise it deliberately (armaatus/autofleet#56).
#
# RAISING A ROW IS ALLOWED AND IS THE POINT. It is one line in a diff, reviewed
# like any other change, rather than a paragraph nobody notices. A lint that
# cannot be raised is one that gets deleted the first time it is inconvenient.
# What is not allowed is raising it quietly: the diff names the row that moved,
# and the PR body says what was bought with it.
#
# EVERY ROW CITES AN ISSUE, so a ceiling with no reason cannot be added and none
# of these reads as an arbitrary number a year from now. `claude-md` is the one
# row whose cap predates the tracker; it cites the issue that made it a row.
#
# THE ROW CARRIES WHAT IS MEASURED, not only the limit. Those two drifted apart
# once already: tests/test_brief.sh hardcoded the set of documents it summed
# while this file derived the same set from the reading table, so a third
# required document could be added here and silently left out of the total --
# green under an unchanged ceiling (armaatus/autofleet#54). One row, both halves.
#
# THE TABLE CARRIES THE LIMIT AND NEVER THE MEASUREMENT. A measured figure
# written into a comment is stale by the next commit; three consecutive rounds
# of armaatus/autofleet#105's review caught one. Every check below PRINTS what
# it measured. The table says only what it may be.
#
# NOT EVERY ROW IS MEASURED HERE, because a ceiling has to be measured from what
# the agent RECEIVES and not from what a file contains. Three of these bound the
# OUTPUT of a script, so a test phase that runs the script is the only honest
# place to measure them. tests/ is not vendored: a host installation gets the
# three rows this file measures, autofleet gets all six, and the `== the
# ceilings` check below is what holds the other three to a phase that exists,
# runs, and reads its limit from this table rather than restating it.
#
# A CEILING BOUNDS THE TEXT AND NOTHING ELSE. The rest of what a run costs --
# tool output, files read twice, review rounds -- is what
# `./scripts/fleet/fleet.sh cost` measures (armaatus/autofleet#48), and REVIEW.md
# asks a fleet PR body to carry that figure. The two halves belong together: the
# table stops the prompt growing, the cost report says whether anything actually
# got cheaper.
#
# A quoted heredoc, so an apostrophe in a description costs nothing. Fields:
#
#   name | limit | the issue that set it | what is measured | what measures it
#
# THE LIMIT IS THE LAST ALLOWED VALUE, on every row. It was not: two rows
# compared with `<` and four with `<=`, so a brief of exactly 400 words failed
# with "400, over the ceiling of 400" while a note of exactly 350 passed -- and
# anyone raising a row to the figure a check had just printed got a red build on
# two rows and a green one on the other four. Found by the local /code-review
# pass.
#
# The last field is a LIST, `; `-separated. A row measured from the source AND
# from the output names both: `brief` and `reading` are counted here off the
# heredoc, which is fast and vendored, and counted again by a phase that RUNS
# the script, which is the measurement the acceptance actually asks for. Naming
# only the first left the second deletable with the table still green.
CEILINGS="$(cat <<'CEILINGS'
claude-md|200|armaatus/autofleet#56|lines of CLAUDE.md, which every session reads in full|evals/lint.sh
brief|400|armaatus/autofleet#49|words of the opening brief's stage 1, the issue spec and any handoff note excluded and __TEST_COMMAND__ counted as one word|evals/lint.sh; tests/test_brief.sh stage1
reading|3500|armaatus/autofleet#54|words a fleet agent is told to read before its first edit: the brief's stage 1, plus every "count" row of the reading table below|evals/lint.sh; tests/test_brief.sh reading
handoff|350|armaatus/autofleet#55|words of the handoff note stage 1 prints ahead of the brief: the framing, plus a note at the AUTOFLEET_HANDOFF_MAX_WORDS default autofleet ships|tests/test_handoff.sh ceiling
testrun|5|armaatus/autofleet#52|lines a fully green ./tests/run.sh prints|tests/test_runner_bound.sh quiet
round|45|armaatus/autofleet#53|lines of one WHOLE clean round of ./scripts/fleet/await-review.sh, the review it hands back included, not the trailing prose alone|tests/test_await_review.sh quiet
CEILINGS
)"

# The ONE reader of the table, here and -- through tests/ceiling.sh, which
# extracts the same rows -- in the phases that measure the other three rows.
#
# A name with no row is FATAL rather than empty: `[ "$n" -lt "" ]` is a bash
# error, and a ceiling check whose limit came back empty is a check that stopped
# checking, which is hard rule 3.
ceiling_field() {
  local value
  value="$(awk -F'|' -v n="$1" -v f="$2" '$1 == n { print $f; found = 1 } END { exit !found }' <<<"$CEILINGS")" \
    || { echo "evals/lint.sh: no ceiling named '$1' in the ceilings table above" >&2; exit 2; }
  printf '%s\n' "$value"
}
ceiling()       { ceiling_field "$1" 2; }
ceiling_issue() { ceiling_field "$1" 3; }
ceiling_what()  { ceiling_field "$1" 4; }

# ...and `|| exit 2` at every call site that reads one, because the `exit 2`
# above runs inside the COMMAND SUBSTITUTION and kills only that subshell. Read
# straight into a comparison, a mistyped row leaves the right-hand side empty;
# bash calls that "integer expression expected", `[` returns 2, the `if` reads 2
# as false, and the ceiling passes everything forever. That is hard rule
# 3 arriving through a shell quirk, so the name is also checked the other way --
# `== the ceilings` reads every literal call site in this file and in the suites
# and fails on one that names no row.

# Every ceiling fails the same way, because the acceptance of
# armaatus/autofleet#56 is a message that names four things: what was measured,
# the limit, the figure, and where the limit is changed. Written once so a row
# added later cannot get three of them.
over_ceiling() {
  fail "$(ceiling_what "$1"): $2, over the ceiling of $(ceiling "$1") set by $(ceiling_issue "$1"). Raise the \`$1\` row in the ceilings table at the top of evals/lint.sh, deliberately, or spend fewer"
}
under_ceiling() {
  ok "$(ceiling_what "$1"): $2, ceiling $(ceiling "$1")"
}

# CLAUDE.md is read in full at the start of every session, so its size is a real
# cost paid on every task in every worktree. The cap is a smell test, not a
# formatting rule: past it, the file has stopped being what a new joiner needs on
# day one and started being documentation, which belongs in docs/. The number
# lives in the ceilings table above, with the other five.
echo "== the ceilings"
# The table itself, before anything reads it.
#
# Hard rule 3 in its own shape: a ceilings table is worth exactly as much as the
# checks behind its rows, so a row nobody measures is a limit that silently
# stopped limiting. This asserts the wiring -- every row cites an issue, names
# what it measures, and names something that measures it, and that something
# reads its number from HERE rather than restating it.
#
# The `tests/` half runs in autofleet only: tests/ is not vendored, so in a host
# installation those rows are three numbers with no local enforcement, which is
# the same trade `== every test phase actually runs` already makes.
if CEILINGS="$CEILINGS" python3 - <<'PYEOF'; then
import glob, os, re, sys

rows = [l for l in os.environ["CEILINGS"].splitlines() if l.strip()]
bad = []
if not rows:
    sys.exit("the ceilings table is empty, so every `ceiling` lookup below fails "
             "the run with a lookup error rather than a measurement")

# The sentinel the rest of this file uses for "which repository is this": a file
# of autofleet's own suite is present exactly when this is autofleet.
IN_AUTOFLEET = os.path.exists("tests/test_runner_bound.sh")

# The command-substitution spelling, which is the one every call site uses. A
# bare-word scan matches this file's own prose ("the ceiling is", "that ceiling
# fails") and invents forty row names out of it. (Written as a regex rather than
# as an example, so this comment is not itself a call site.)
CALL = re.compile(r"\$\(ceiling(?:_issue|_what)? ([a-z][a-z0-9-]*)\)")

def read(path):
    try:
        return open(path).read()
    except OSError as exc:
        bad.append(f"{path} cannot be read ({exc.strerror}), so a ceiling row "
                   "points at something that cannot be asserting anything")
        return ""

# The registry, so a row cannot name a phase that never runs. Parsed off
# `suite:phase phase ...`, the one format tests/run.sh dispatches on.
registry = {}
if IN_AUTOFLEET:
    for m in re.finditer(r'^"([a-z_]+):([^"]*)"$', read("tests/run.sh"), re.M):
        registry[m.group(1)] = m.group(2).split()

seen = set()
for row in rows:
    parts = row.split("|")
    if len(parts) != 5:
        bad.append(f"the ceilings row `{row}` has {len(parts)} fields, not 5 "
                   "(name|limit|issue|what is measured|what measures it)")
        continue
    name, limit, issue, what, where = (p.strip() for p in parts)
    if not re.fullmatch(r"[a-z][a-z0-9-]*", name):
        bad.append(f"the ceilings row name `{name}` is not a plain lower-case "
                   "word; it is the key `ceiling <name>` is called with")
        continue
    if name in seen:
        bad.append(f"the ceilings table has two `{name}` rows; the second is "
                   "unreachable, so raising it raises nothing")
        continue
    seen.add(name)
    if not re.fullmatch(r"[1-9][0-9]*", limit):
        bad.append(f"the `{name}` ceiling is `{limit}`, which is not a whole "
                   "number above zero")
    # Every row cites an issue. A ceiling with no reason reads as an arbitrary
    # number a year from now, and nobody can tell whether raising it gives back
    # something that was deliberately bought.
    if not re.fullmatch(r"armaatus/(autofleet|rommsync-nx)#[0-9]+", issue):
        bad.append(f"the `{name}` ceiling cites `{issue}`, which is not an issue "
                   "(`armaatus/autofleet#N`). Every row says why its number is "
                   "what it is")
    if not what:
        bad.append(f"the `{name}` ceiling does not say WHAT it measures. The row "
                   "carries the membership as well as the number, or the two "
                   "drift apart the way armaatus/autofleet#54 found them")
    # ...and something measures it, reading the number from this table.
    for measurer in [w.strip() for w in where.split(";")]:
        if measurer == "evals/lint.sh":
            if name not in CALL.findall(read("evals/lint.sh")):
                bad.append(f"the `{name}` ceiling says evals/lint.sh measures it, "
                           f"but nothing here calls `$(ceiling {name})`")
            continue
        m = re.fullmatch(r"tests/test_([a-z_]+)\.sh ([a-z0-9_]+)", measurer)
        if not m:
            bad.append(f"the `{name}` ceiling says `{measurer}` measures it, which "
                       "is neither evals/lint.sh nor a `tests/test_<suite>.sh "
                       "<phase>`")
            continue
        if not IN_AUTOFLEET:
            continue
        suite, phase = m.group(1), m.group(2)
        if phase not in registry.get(suite, []):
            bad.append(f"the `{name}` ceiling is measured by {measurer}, which is "
                       f"not in tests/run.sh's registry for `{suite}` -- so it "
                       "never runs")
        # A CALL, not a mention. `ceiling {name}` as a substring is satisfied
        # by `over_ceiling {name}`, by a comment, by anything -- so the row
        # could read as wired while nothing anywhere read its number. Found by
        # the local /mattpocock-skills:code-review standards pass.
        if name not in CALL.findall(read(f"tests/test_{suite}.sh")):
            bad.append(f"tests/test_{suite}.sh does not call `$(ceiling {name})`, "
                       "so it is measuring against a number of its own and the "
                       "table's is no longer the one in force")

# ...and the other direction: every literal `$(ceiling <name>)` in the payload
# and in the suites names a row that EXISTS. A typo there resolves to nothing,
# and an empty limit is a comparison bash reports as an error and `if` reads as
# false -- a ceiling that passes everything, silently, forever.
callers = ["evals/lint.sh"]
if IN_AUTOFLEET:
    callers += sorted(glob.glob("tests/test_*.sh"))
for caller in callers:
    for name in sorted(set(CALL.findall(read(caller)))):
        if name not in seen:
            bad.append(f"{caller} asks for a `{name}` ceiling, which is not a row "
                       "in the table -- so it is measuring against an empty limit")

if bad:
    sys.exit("\n  ".join(bad))
print(f"        {len(rows)} rows, each citing an issue and measured somewhere")
PYEOF
  ok "every ceiling cites the issue that set it and is measured against this table"
else
  fail "the ceilings table is not well-formed, or a row is not enforced (above)"
fi

echo "== CLAUDE.md"
if [ ! -f CLAUDE.md ]; then
  fail "CLAUDE.md is missing; it is the file every session reads first"
else
  lines="$(wc -l <CLAUDE.md | tr -d ' ')"
  claude_md_lines="$(ceiling claude-md)" || exit 2
  if [ "$lines" -gt "$claude_md_lines" ]; then
    over_ceiling claude-md "$lines"
  else
    under_ceiling claude-md "$lines"
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
  for needle in "The dimensions" "Critical, Important, Suggestion" "What not to report"; do
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
  for needle in "review-findings" "review-important" "independent-review: local" \
                "REVIEW.md" "mattpocock-skills:code-review"; do
    grep -q -- "$needle" .claude/agents/reviewer.md \
      || fail ".claude/agents/reviewer.md no longer mentions '$needle', which the reviewer has to write or read"
  done
  ok "the reviewer brief names every trailer, REVIEW.md and the standards pass"
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
if flat REVIEW.md | qgrep 'nothing else after it'; then
  fail "REVIEW.md still says nothing may follow the findings trailer, which forbids the local-review marker the gate requires"
elif grep -q 'independent-review: local' REVIEW.md; then
  ok "REVIEW.md allows the trailers local review mode depends on"
else
  fail "REVIEW.md does not mention the local-review marker, so a reviewer reading it in full does not know to write one"
fi

# 2b. ...and it must not order a verdict GitHub refuses in this mode. `local`
#     means the reviewer is the PR's author, and GitHub declines
#     CHANGES_REQUESTED on your own pull request -- so a brief that orders
#     `--request-changes` for an Important finding ends the run with a non-zero
#     exit on its last action and nothing submitted.
if flat REVIEW.md | qgrep 'request changes on your own pull request' \
   && flat .claude/agents/reviewer.md | qgrep 'request changes on your own pull request'; then
  ok "REVIEW.md and the brief both say --request-changes is unavailable in local mode"
else
  fail "the reviewer is still told to --request-changes, which GitHub refuses on a self-authored PR"
fi

# 2c. The severity trailer, in all four places that have to agree about it.
#     It is what tells a nit-only review from an Important one, and the failure
#     it exists to prevent is silent in the cheap direction: a brief that stops
#     asking for it produces reviews with no `review-important` line, the gate
#     reads that as "did not say" forever, and the nit-only wording -- the whole
#     point of the trailer -- is never printed again. Nothing goes red. The loop
#     just quietly costs what it used to.
#
#     `github` mode gets the trailer too. It has no round number to gate the
#     late-round rule on, but the count is what `merge_gate.py` reads, and the
#     gate does not know which mode wrote the review it is looking at.
sev_missing=""
for f in REVIEW.md .claude/agents/reviewer.md scripts/fleet/review.sh \
         .github/workflows/claude-review.yml docs/WORKFLOW.md; do
  grep -q -- 'review-important' "$f" || sev_missing="$sev_missing $f"
done
if [ -z "$sev_missing" ]; then
  ok "the severity trailer is asked for by both briefs, the policy and the spawner"
else
  fail "review-important is missing from:$sev_missing -- severity stops reaching merge_gate.py, and the nit-only remedy stops being printed"
fi

# 2d. ...and merge_gate.py still reads it. A trailer three files ask for and
#     nothing parses is worse than no trailer: every reviewer pays to write it
#     and no reader is any better off.
if grep -q 'review-important:\\s\*(' .github/scripts/merge_gate.py \
   && grep -q 'declared_important' .github/scripts/merge_gate.py; then
  ok "merge_gate.py parses the severity trailer the briefs write"
else
  fail "merge_gate.py no longer parses review-important, so the trailer every review writes reaches nothing"
fi

# 2e. THE TRAILER BLOCK, CHARACTER FOR CHARACTER, in the three places that
#     dictate it and the one that documents it. Presence (2c) is not enough:
#     the first draft of this change had REVIEW.md stating the two trailers in
#     the OPPOSITE order from the block review.sh tells the reviewer to copy,
#     and every grep for presence was green. Parsing is order-independent, so
#     nothing would have broken -- but REVIEW.md is the file the brief calls
#     the authority a reviewer reads "first and in full", and the last time it
#     contradicted the dictated trailers a real review was discarded and the PR
#     blocked on a review that already existed. That paragraph is still in
#     REVIEW.md. Found by both independent reviews of this change.
if python3 - <<'PYEOF'
import re, sys

def block(path):
    """The dictated trailer block: the first two ADJACENT trailer lines.

    Anchored on the literal `<!-- ... -->` lines, not on the names: every one of
    these files also discusses the trailers in prose, in whatever order the
    sentence wanted, and matching that reported drift where there was none.
    Adjacency is what makes it the block a reviewer copies.
    """
    lines = [re.search(r"<!--\s*review-(important|findings):", ln)
             for ln in open(path).read().split("\n")]
    for i in range(len(lines) - 1):
        if lines[i] and lines[i + 1]:
            return [lines[i].group(1), lines[i + 1].group(1)]
    return []

want = ["important", "findings"]
bad = []
for path in ("REVIEW.md", ".claude/agents/reviewer.md", "scripts/fleet/review.sh",
             ".github/workflows/claude-review.yml", "docs/WORKFLOW.md"):
    got = block(path)
    if got != want:
        bad.append(f"{path} states the trailers as {got}, not {want}")
if bad:
    sys.exit("the trailer block has drifted:\n  " + "\n  ".join(bad))
PYEOF
then
  ok "every file stating the two trailers states them in the same order"
else
  fail "the trailer block has drifted between the policy and the prompts (above)"
fi

# 2f. ...and the round number reaches the reviewer at all. 2g below asserts the floor
#     is WRITTEN in both files; nothing asserted the one line that makes it
#     reachable. Delete `Review round:` from review.sh's prompt and every
#     reviewer falls back to the documented "treat it as round one", the floor
#     stops firing on every PR forever, and nothing goes red -- the same
#     silent-in-the-cheap-direction failure 2c exists to prevent, one level
#     down. Found by the independent review.
if grep -q 'Validation round: \$round' scripts/fleet/validate.sh \
   && grep -q 'validate_round' scripts/fleet/validate.sh; then
  ok "validate.sh tells the validator which round it is, and what the cap is"
else
  fail "validate.sh no longer passes the round number, so a validator cannot tell its last pass from its first and the 'a fail at the cap is the right outcome' rule never fires"
fi

# 2g. THE VALIDATION TRAILER, spelled the same way in every file that writes it
#     and the one file that reads it.
#
#     This replaced the late-round nit floor, which existed because a review
#     could spend four rounds on a pull request. It cannot any more: the reviewer
#     runs once and the validator runs at most twice, and what makes that
#     terminate rather than deadlock is `merge_gate.py` reading a `pass` on the
#     current head as standing in for a review the author's own fix moved the
#     head out from under.
#
#     So the trailer is now the load-bearing string of the whole loop, and every
#     way it can break is silent: a validator writing a format the gate does not
#     read submits a verdict that is discarded, the PR is held forever on a
#     validation that already happened, and nothing goes red. Exactly the
#     silent-in-the-cheap-direction failure 2c exists to prevent, one phase down.
trailer_missing=""
for f in .github/scripts/merge_gate.py scripts/fleet/validate.sh \
         .claude/agents/validator.md .github/workflows/validate.yml; do
  [ -f "$f" ] || { trailer_missing="$trailer_missing $f(absent)"; continue; }
  grep -q 'validated:' "$f" || trailer_missing="$trailer_missing $f"
done
if [ -z "$trailer_missing" ]; then
  ok "the validated trailer is named by the gate, both drivers and the brief"
else
  fail "the validated trailer is missing from:$trailer_missing -- a verdict nothing reads holds every PR forever"
fi

# 2h. ...and every one of them states the FAIL-CLOSED property: a missing or
#      unrecognised verdict is not a pass.
#
#      POSITIVE AND STRUCTURAL, for the reason the check this replaced arrived at
#      after two failed attempts: hunting the wrong sentence matches one historic
#      wording and fires only on a byte-exact revert, and widening the pattern
#      walks straight into a negation trap. So this asserts what must be TRUE --
#      each file names both verdicts, so neither can quietly become the default.
#
#      The direction is the whole safety of the phase. A validator that crashed
#      writes nothing at all, and nothing at all must not read as consent.
verdicts_missing=""
for f in .github/scripts/merge_gate.py scripts/fleet/validate.sh \
         .claude/agents/validator.md; do
  [ -f "$f" ] || { verdicts_missing="$verdicts_missing $f(absent)"; continue; }
  # Both words, each on its own pass: a file naming only `pass` is one where
  # `fail` has become unreachable, which is the same hole wearing a green face.
  flat "$f" | qgrep -F 'pass' || verdicts_missing="$verdicts_missing $f(pass)"
  flat "$f" | qgrep -F 'fail' || verdicts_missing="$verdicts_missing $f(fail)"
done
if [ -z "$verdicts_missing" ]; then
  ok "...and each names both verdicts, so an unrecognised one cannot default to consent"
else
  fail "a validation verdict is unnamed in:$verdicts_missing -- a verdict that cannot be written is one the gate never sees"
fi

# 2i. THE VALIDATOR IS NOT THE AUTHOR'S TO START, asserted here rather than only
#     in guard.py's own table.
#
#     A `pass` releases the merge gate outright, so an agent that could run
#     `validate.sh` from its own worktree could certify its own branch. The hook
#     refuses it; this is the assertion that the hook still contains the rule,
#     which is hard rule 3 -- a rule with no assertion is not shipped.
if grep -q 'validate.sh' .claude/hooks/guard.py \
   && python3 .claude/hooks/guard.py --selftest >/dev/null 2>&1; then
  ok "guard.py refuses validate.sh from a fleet worktree, and its selftest holds"
else
  fail "guard.py no longer refuses validate.sh from a fleet worktree, or its selftest does not hold -- a branch that can start its own validator can certify itself"
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

#    ...and the SELF-review's allowlist, which has a sharper edge than the
#    independent reviewer's: self-review.sh runs INSIDE a fleet-owned worktree,
#    where a pass that could edit files could edit `.claude/hooks/guard.py` on
#    its way past -- the one thing guard.py refuses the agent itself. It reports;
#    the author fixes. `gh api` is withheld for the same no-ceiling reason as
#    above.
#
#    WHAT THIS COVERS, stated because the check's own message overclaimed it:
#    the DIRECT grant, and nothing more. `Task` and `Agent` are on the list --
#    both passes are skills that fan out -- so whether a subagent inherits this
#    ceiling is a property of the runner, not of this line. `review.sh` has the
#    same shape and the same gap. Read this as "the pass itself was not handed a
#    pen", which is the part a diff to this repo can change. armaatus/autofleet#51, found by the local
#    /mattpocock-skills:code-review pass, which noted review.sh had this
#    assertion and self-review.sh had none.
if python3 - <<'PYEOF'; then
import re, sys
src = open("scripts/fleet/self-review.sh").read()
block = re.search(r"^TOOLS=.*?(?=\n\n)", src, re.S | re.M)
if not block:
    sys.exit("scripts/fleet/self-review.sh no longer builds a `TOOLS=` allowlist, "
             "so its two passes run with whatever the command defaults to")
granted = block.group(0)
if "Bash(gh api:*)" in granted:
    sys.exit("self-review.sh grants `Bash(gh api:*)`. It is withheld on purpose: "
             "it is the one grant on the list with no ceiling, and this pass runs "
             "under the maintainer's own gh login")
# THE DENY LIST IS WHAT ACTUALLY TAKES THE PEN AWAY. `--allowed-tools` is
# ADDITIVE -- it grants on top of `.claude/settings.json`, which permits
# `Write(.claude/agents/**)` and `Edit(.claude/agents/**)` by design. An earlier
# version of this check read the absence of those words in `TOOLS=` as a
# guarantee, which is hard rule 3 with the silence in the check rather than in
# the guard. Assert the flag that binds. Found by the local
# /mattpocock-skills:code-review pass.
denied = re.search(r"^DENIED=.*$", src, re.M)
if not denied:
    sys.exit("scripts/fleet/self-review.sh no longer sets a `DENIED=` list, so "
             "nothing stops a pass writing: `--allowed-tools` only ADDS to what "
             ".claude/settings.json already permits, and that includes "
             "Write/Edit under .claude/agents/ -- the independent reviewer's brief")
for forbidden in ("Write", "Edit", "NotebookEdit"):
    if forbidden not in denied.group(0):
        sys.exit(f"self-review.sh's DENIED list no longer refuses `{forbidden}`. "
                 "The self-review passes report and the author fixes -- and this "
                 "one runs in a fleet-owned worktree, where a pass that can write "
                 "can rewrite .claude/agents/reviewer.md, the brief the "
                 "independent reviewer runs on")
# ON THE SPAWN, not anywhere in the file. `"--disallowed-tools" in src` was true
# of the COMMENT that explains it, so the assertion survived the flag being
# dropped from the command line -- hard rule 3, in the check written to prevent
# exactly that. Anchored on the flag followed by the variable, on a line that is
# not a comment. Found by the local /code-review pass.
if not re.search(r'^\s*--disallowed-tools "\$DENIED"', src, re.M):
    sys.exit("scripts/fleet/self-review.sh builds a DENIED list and never passes "
             "it to the command as `--disallowed-tools \"$DENIED\"`, so it "
             "refuses nothing")
if "Skill" not in granted:
    sys.exit("self-review.sh no longer grants `Skill`, so both passes -- which ARE "
             "skills -- silently review with most of what they are for switched off")
PYEOF
  ok 'the self-review passes report only, and cannot reach `gh api`'
else
  fail "the self-review's tool allowlist has drifted (above)"
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

# 4f. THE SLUG RULE THE COST REPORT IMPLEMENTS IS THE ONE ITS PROSE PUBLISHES.
#
#    Same shape as 4d, and added because it already happened once inside the
#    change that introduced it: `scripts/fleet/cost.sh` widened the rule to every
#    non-alphanumeric character, `docs/CONFIGURATION.md` was reworded, and
#    `scripts/fleet/config.sh` -- the file a host project actually has open at
#    the moment it sets AUTOFLEET_TRANSCRIPT_DIR -- kept saying "`/` and `.`".
#    config.sh is in install.sh PAYLOAD, so a stale rule there is a stale
#    instruction in every host repo.
#
#    Worth a check rather than a comment because of HOW it fails: a wrong slug
#    rule produces a confident table of zeros over the words "reaped, or run
#    before the fleet recorded its worktree path". Nothing is red, nothing is
#    empty, and the explanation on screen is wrong. Hard rule 3 -- a rule with
#    no assertion is not shipped. Found by the independent review.
if python3 - <<'PYEOF'
import re, sys

code = open("scripts/fleet/cost.sh").read()
# The rule as the code states it. Read out rather than hardcoded, so widening it
# again to something this check has never heard of fails here rather than
# passing quietly.
rule = re.search(r're\.sub\(r"\[\^([^"]*)\]", "-", path\)', code)
if not rule:
    sys.exit("cost.sh no longer derives the transcript slug with a re.sub over a "
             "character class; this check now asserts nothing")
if rule.group(1) != "A-Za-z0-9":
    sys.exit("cost.sh now keeps [%s] in a slug, which no page here describes; "
             "reword config.sh and docs/CONFIGURATION.md, then widen this check"
             % rule.group(1))

cap = re.search(r"^SLUG_MAX = (\d+)$", code, re.M)
if not cap:
    sys.exit("cost.sh no longer names a SLUG_MAX; this check now asserts nothing")

# The two pages that ship the rule to a host project. `config.sh` is the one
# somebody has open while setting the knob; the doc is the one they are sent to.
pages = ("scripts/fleet/config.sh", "docs/CONFIGURATION.md")
bad = []
for path in pages:
    # LOWER-CASED. The check read the raw text, and `config.sh` states the rule
    # in capitals -- so it was satisfied only by an incidental second mention
    # further down the same comment. Reword the sentence that actually publishes
    # the rule and this passed; delete the aside and it failed with the rule
    # still correct. Found by the independent review.
    prose = open(path).read().lower()
    if "non-alphanumeric" not in prose:
        bad.append("%s does not say the slug replaces every non-alphanumeric "
                   "character" % path)
    # The rule it USED to state, which is the one that went stale. Matched on the
    # phrasing both pages carried, not on the characters alone -- "/" and "." are
    # in every one of these files for other reasons.
    for stale in ("every `/` and `.` turned into", "`/`-and-`.`-to-`-`"):
        if stale in prose:
            bad.append("%s still describes the old `/`-and-`.` slug rule" % path)
# BOTH pages, not just config.sh. The doc is the one a host project is SENT to,
# and it published the rule without the cap -- so of the two pages this check
# exists to keep honest, the less complete one was the less checked. Found by the
# independent review.
for path in pages:
    if cap.group(1) not in open(path).read():
        bad.append("%s does not name the %s-character slug cap cost.sh applies"
                   % (path, cap.group(1)))
if bad:
    sys.exit("the published slug rule has drifted from the one that runs:\n  "
             + "\n  ".join(bad))
PYEOF
then
  ok "the cost report's slug rule is the one config.sh and CONFIGURATION.md publish"
else
  fail "the slug rule in the docs is not the slug rule in cost.sh (above); config.sh ships to every host repo, and a wrong rule reports zeros rather than an error"
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
   && sed -n '/^cmd_status()/,/^}/p' scripts/fleet/fleet.sh | qgrep 'review:'; then
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
              review.sh self-review.sh handoff.sh; do
  path="scripts/fleet/$script"
  [ -x "$path" ] || { fail "$path is missing or not executable"; continue; }
  bash -n "$path" || { fail "$path does not parse"; continue; }
  ok "$script"
done

# ...and none of the payload pipes an assertion into `grep -q`.
#
# `-q` exits on the first match, the producer on the left writes into a closed
# pipe, and `set -o pipefail` makes the pipeline 141 -- so a check that HELD
# reports as failed, and a guard that was looking for something reports that it
# found nothing. It is a RACE: it needs the match to land before the producer is
# done, so it is green on small input and red on large, and GNU sed says
# "couldn't flush stdout: Broken pipe" while BSD sed dies quietly -- green on a
# Mac, red in CI.
#
# This repository has now paid for it twice: `clear_stale_review_records` in
# fleet.sh carries the measurement (500 refs exits 0, 1000 exits 141, and a
# reviewed commit lost its record), and the `cmd_status` check above cost this
# change a CI round with every assertion in it actually holding. Twice is what
# makes it a rule rather than a war story. `qgrep` above is the shape that is
# safe: `grep` without `-q` reads its whole input.
#
# Every payload SHELL script, not only the ones that set `pipefail` themselves.
# lib.sh does not set it -- it is SOURCED, and every caller does (fleet.sh,
# issue-command.sh) -- so the first version of this check skipped the one file
# where the bug was still live, which is the shared-helper case it most needed
# to see. Found by the independent review. Continuations are joined first,
# because a `|` at the end of one line with the `grep -q` at the start of the
# next is the same pipeline; comments are excluded, because fleet.sh's QUOTES
# the bad form and that quotation is the record of where it was measured.
# Its own assertions first, the way guard.py's and merge_gate.py's are run: a
# detector that has already shipped blind twice has the least claim to be the
# one tool here with no selftest. Found by the independent review.
python3 "$REPO_ROOT/evals/piped_quiet_grep.py" --selftest \
  || fail "evals/piped_quiet_grep.py fails its own selftest, so the scan below means nothing"
if bad="$(python3 "$REPO_ROOT/evals/piped_quiet_grep.py")"; then
  if [ -n "$bad" ]; then
    fail "these pipe an assertion into \`grep -q\`, which reports a holding check as failed under load -- and a sourced file inherits its caller's pipefail: $bad"
  else
    ok "no assertion in the payload is piped into \`grep -q\`"
  fi
else
  fail "the \`grep -q\` scan could not run, so it is asserting nothing"
fi

# ...and the brief must still name them -- across BOTH of its stages.
#
# Since armaatus/autofleet#49 the brief arrives in two pieces out of the one
# file: the bare form prints the spec, steps 1-3 and a pointer, and `--after-pr`
# prints steps 4-6.
# The risk the split carries is an instruction that lands in NEITHER stage,
# which is a rule nobody enforces: armaatus/rommsync-nx#90's PR that nobody queued for
# auto-merge, armaatus/rommsync-nx#88 and #89 sitting blocked on one unresolved thread.
#
# Asserted PER STAGE rather than over the union, which is strictly stronger and
# is the union by construction. The union alone passed for the wrong reason and
# all three review passes said so: stage 1 says "Two subagents in
# `.claude/agents/`", so a union grep for `.claude/` matched forever, and
# deleting `.claude/` from stage 2's list of paths no agent may merge still
# printed ok. That is hard rule 3 -- a guard that silently stops guarding -- and
# the cost of it is an agent spending its review and both validations turning green a
# gate that can never pass.
# The brief is ONE heredoc with a `@@AFTER-PR@@` line in it -- which is also
# what keeps main's copy of this check readable, since its extraction is the
# range from the `sed` line to `BRIEF` and two heredocs left it reading nothing.
brief="$(sed -n "/^sed .*BRIEF/,/^BRIEF$/p" scripts/fleet/issue-command.sh)"
# The text begins at the `---` rule the brief opens with and ends at the
# terminator; between them is exactly what the agent receives. Anchored on the
# TEXT rather than on the shape of the command that prints it: keyed to `| awk `
# this went blind the moment that command grew a second line, and counted awk's
# own source as part of the brief. Found by the independent review, twice over
# -- once as the nit about this file's line-oriented scanning, once as the
# measurement being of something other than what it claims.
body="$(sed -n '/^---$/,$p' <<<"$brief" | sed '$d')"
stage1="$(sed -n "1,/^@@AFTER-PR@@$/p" <<<"$body" | sed '$d')"
stage2="$(sed -n "/^@@AFTER-PR@@$/,\$p" <<<"$body" | sed '1d')"
if [ -z "$stage1" ] || [ -z "$stage2" ]; then
  fail "one of issue-command.sh's two brief heredocs could not be read, so everything below asserts nothing"
else
  brief_fails_before=$fails
  # Stage 1: what is due before anything leaves the worktree -- including the
  # pointer, without which stage 2 is unreachable and half the brief is dead
  # text -- and the three things armaatus/autofleet#49 added because CLAUDE.md
  # names them and the brief the fleet actually sends never did.
  # `self-review.sh` rather than `record-review.sh` since armaatus/autofleet#51:
  # step 3 is one command that runs both passes in processes that are not the
  # agent's, and records the marker itself. `record-review.sh` is still the
  # primitive and stage 2 still names it -- the rebase remedy re-records without
  # re-reviewing -- so it is asserted there, in the list below.
  #
  # `verifier` left this list with the subagent: one review and two validations
  # replaced it, and the brief names those two by their own scripts.
  for named in self-review.sh "/code-review" "mattpocock-skills:code-review" \
                --after-pr researcher "gh pr diff --stat" handoff.sh; do
    grep -qF -- "$named" <<<"$stage1" \
      || fail "the opening brief no longer names $named, which is due before anything leaves the worktree"
  done
  # ...and none of what stage 2 owns, because carrying it here is the cost
  # armaatus/autofleet#49 measured: it rides in the prompt prefix of every request made before the PR
  # exists.
  # `board.sh` and `Closes #` as well as the scripts: tests/test_brief.sh has
  # both in its own negative list and tests/ is NOT vendored, so this loop is
  # the only thing holding the split in a host installation. Found by the
  # independent review.
  for named in await-review.sh answer-review.sh review-status.sh validate.sh \
                board.sh "--auto --squash" "Closes #"; do
    grep -qF -- "$named" <<<"$stage1" \
      && fail "the opening brief carries $named, which belongs to --after-pr; the split is not holding"
  done
  # Guarded on the counter: `ok` after a loop that may have called `fail` prints
  # a green line for an assertion that just failed, two lines above it. Found by
  # the independent review.
  [ "$fails" = "$brief_fails_before" ] \
    && ok "stage 1 names what is due before the push, and nothing that is not"
  brief_fails_before=$fails

  # Stage 2: every script of the loop, the closing line merge-gate demands, and
  # the three paths no agent can merge itself.
  # `handoff.sh` is in BOTH stages, and that is the one instruction here which
  # deliberately is. Stage 1 asks for the note when the work is put down --
  # armaatus/autofleet#55's other half, the attempt the time-box interrupts --
  # and stage 2 asks for it at the push and after every round. An instruction
  # that arrives only after the PR exists cannot serve a case that happens
  # before one does; the independent review of #55 is where that was measured.
  # `resolve-thread.sh` is NOT in this list any more, and its absence is the
  # assertion. The validator resolves what it is satisfied by; an author that
  # closed its own threads would be holding the per-finding ledger it is judged
  # against. The negative is checked below, where the rest of the negatives are.
  for named in record-review.sh await-review.sh review-status.sh \
                answer-review.sh handoff.sh "--auto --squash" "Closes #" \
                "THERE IS ONLY ONE" "VALIDATOR" "At most TWO validations" \
                ".github/workflows/" ".github/scripts/" ".claude/"; do
    grep -qF -- "$named" <<<"$stage2" \
      || fail "the post-PR half of the brief no longer mentions $named, so the loop stops at that step"
  done
  grep -qF -- "resolve-thread.sh" <<<"$stage2" \
    && fail "the post-PR brief tells the author to resolve its own review threads; the validator resolves what it accepts, or a resolved thread means nothing"
  [ "$fails" = "$brief_fails_before" ] \
    && ok "stage 2 names one review, two validations, and the paths a person has to merge"

  # The `brief` row, in the vendored check and not only in autofleet's own
  # suite: a host project gets the brief and the reason it was split, so it
  # should get the thing that stops it growing back. tests/test_brief.sh stage1
  # measures the same row on what the script actually PRINTS, and reads the
  # number out of the same table.
  #
  # AUTOFLEET's words, not the host's. `__TEST_COMMAND__` is counted as the one
  # word it is and the host's command is never substituted in -- because this
  # check is vendored and `agent-config.yml` runs it on every PR in every repo
  # that installs the payload. Measured WITH the host's command, an ordinary
  # nine-word `docker compose run --rm app pytest -q --tb=short --maxfail=1`
  # puts a clean installation over the ceiling on its first PR, on a text it did
  # not write, with a failure that tells it to edit a vendored file the next
  # `install.sh` overwrites. That is hard rule 1, and it is what rounds 1 and 2
  # of that review were both circling: the answer was not a better reader for
  # `.autofleet/config`, it was not reading it at all.
  #
  # The budget did NOT move for armaatus/autofleet#55, and the attempt to move
  # it is worth recording. #55's other half is the attempt the time-box
  # interrupts, and the only place an agent can be told to leave a note before a
  # PR exists is stage 1 -- stage 2 is fetched after the push. The first
  # spelling added a paragraph and raised this to 425; `agent-config.yml` re-runs
  # MAIN's copy of this file against the branch and refused, which is the check
  # doing exactly what it is for. The sentence was paid for out of stage 1
  # instead: the STOP paragraph absorbed it (both are the work being put down),
  # and three sentences elsewhere were tightened without losing a rule.
  #
  # No figure is written here. One was, twice -- `391`, then `386` -- and each
  # went stale at the next commit to the brief; three rounds of
  # armaatus/autofleet#105's review caught it. The line below prints what it
  # measured, which is the only copy that cannot rot.
  rendered="${stage1//__ISSUE__/49}"
  words="$(printf '%s\n' "$rendered" | wc -w | tr -d " ")"
  brief_budget="$(ceiling brief)" || exit 2
  if [ "$words" -le "$brief_budget" ]; then
    under_ceiling brief "$words"
  else
    over_ceiling brief "$words"
  fi
fi

echo "== the rule of one home"
# The loop was written three times: CLAUDE.md, the brief, and docs/WORKFLOW.md,
# which is the longest of the three and which the brief's first sentence sent
# every agent to read. CLAUDE.md plus the brief plus REVIEW.md plus WORKFLOW.md
# measured 13,425 words before the first edit -- and then rode in the prompt
# prefix of every request for the rest of the session (armaatus/autofleet#54).
# WORKFLOW.md alone was 10,036 of them.
#
# Two assertions, and they are different shapes:
#
#   the rule of one home  for each rule that is actually ENFORCED, exactly one
#                         agent-facing text states it in full, and that text is
#                         the one named as its home. Everything else links.
#   the reading ceiling   what a fleet agent is told to read before its first
#                         edit, counted in words, against a number that has to
#                         be raised deliberately.
#
# This is the same shape as check 4e, which pins the Orca seam pipeline to
# docs/RUNNERS.md and fails if CLAUDE.md grows a second copy. That one was added
# after the rule went stale in prose twice. The six below are the rules whose
# second copy costs something worse than staleness: an agent that reads the copy
# and not the original does the wrong thing with the merge.
#
# docs/WORKFLOW.md is deliberately NOT in the agent-facing set. It is the
# maintainer's explanation and the record of why each rule exists -- the reason
# this repo's comment density is high on purpose -- and nothing here is deleted
# from it for being long. What changed is who is told to read it. The assertion
# that keeps that true is further down: a page whose agent-instruction sections
# are pointers has no copy-pasteable fence for a step of the loop.
if [ -n "$stage1" ] && [ -n "$stage2" ]; then
  reading_ceiling="$(ceiling reading)" || exit 2
  reading_what="$(ceiling_what reading)" || exit 2
  reading_issue="$(ceiling_issue reading)" || exit 2
  if stage1="$stage1" stage2="$stage2" rendered="$rendered" \
     reading_ceiling="$reading_ceiling" reading_what="$reading_what" \
     reading_issue="$reading_issue" python3 - <<'PYEOF'; then
import os, re, sys

def read(path):
    """A file this check cannot read must SAY so, not raise.

    An unguarded `open` here surfaces a traceback under the message "the loop is
    written more than once", which is a check reporting the wrong thing about a
    file that is simply absent. Same reason the `== CLAUDE.md` block at the top
    of this file guards with `[ ! -f ]`. Found by the local /code-review pass.
    """
    try:
        return open(path).read()
    except OSError as exc:
        sys.exit(f"{path} cannot be read ({exc.strerror}), so the rule of one "
                 "home and the reading ceiling assert nothing")

# AUTOFLEET'S OWN TEXTS, AND THE HOST'S. This file is VENDORED and
# `agent-config.yml` runs it on every PR in every repo that installs the payload
# -- but `CLAUDE.md` is NOT vendored: a host project writes its own, and
# install.sh's PAYLOAD does not carry it. So every assertion below that reads
# `CLAUDE.md` is autofleet-only, and the vendored half is the one made of text
# autofleet actually wrote: the brief, and `REVIEW.md`.
#
# The first version of this check asserted the whole table against whatever
# `CLAUDE.md` said, anywhere. A host whose working agreement links
# `CONTRIBUTING.md` -- most of them -- got a red REQUIRED check on its first PR,
# about a document autofleet has never heard of, and the remedy in the message
# was to edit a vendored file that the next `install.sh` overwrites. That is hard
# rule 1, and it is the same trap the `BRIEF_WORD_BUDGET` comment above is
# written about. Both local review passes found it independently.
#
# The probe is the one at `== every test phase actually runs` below, for the
# reason given there: a file of autofleet's own suite is present exactly when
# this is autofleet.
IN_AUTOFLEET = os.path.exists("tests/test_runner_bound.sh")

texts = {
    "REVIEW.md":          read("REVIEW.md"),
    "the brief, stage 1": os.environ["stage1"],
    "the brief, stage 2": os.environ["stage2"],
}
if IN_AUTOFLEET:
    # Ordered so a failure names CLAUDE.md first, where a second copy usually is.
    texts = {"CLAUDE.md": read("CLAUDE.md"), **texts}

def paragraphs(text):
    return re.split(r"\n\s*\n", text)

def without_tables(par):
    """A markdown table row is a MAP, not an instruction.

    CLAUDE.md's Layout table names `.claude/`, `.github/workflows/` and
    `.github/scripts/` on three consecutive rows, and a table has no blank line
    in it -- so paragraph-level matching reads the whole table as one statement
    of the merge rule, which it plainly is not. Saying where a directory lives
    is the one thing that file has to be able to do without tripping this.
    """
    return "\n".join(l for l in par.splitlines() if not l.lstrip().startswith("|"))

def triple(text):
    """All three human-only prefixes in ONE paragraph: the merge rule stated."""
    return any(all(p in without_tables(par)
                   for p in (".claude/", ".github/workflows/", ".github/scripts/"))
               for par in paragraphs(text))

# (the rule, its home, what "stated in full" looks like)
#
# Each signature is the OPERATIVE form, chosen so that naming the rule in
# passing does not match it:
#
#   self-review.sh      by name. Nothing else may say it: CLAUDE.md's "Finishing
#                       a task" used to carry its own copy of the two slash
#                       commands, which is how an agent ends up running them in
#                       the context the move was supposed to get them out of
#                       (armaatus/autofleet#51). Stage 2 names `record-review.sh`
#                       bare in the rebase remedy, which is the primitive under
#                       this one and a pointer rather than the instruction.
#   at most two validations  the phrasing IS the rule. It replaced "at most
#                       three rounds", which was the cap on REVIEWS when a pull
#                       request could have four of them; the reviewer now runs
#                       once and the bound that is left to state is the
#                       validator's.
RULES = [
    ("run both self-review passes and record the result before pushing",
     "the brief, stage 1",
     lambda t: "self-review.sh" in t),
    ("arm `--auto --squash` the moment the PR exists", "the brief, stage 2",
     lambda t: "--auto --squash" in t),
    ("the two-validation cap", "the brief, stage 2",
     lambda t: re.search(r"at most\s+two\s+validations", t, re.I) is not None),
    # The reviewer runs ONCE, and an agent that believes otherwise answers a
    # review with a push expecting a fresh one -- which is the loop this shape
    # removed, re-derived from a brief that forgot to say so. Stage 2's home,
    # next to the wait that reads it back.
    ("the review runs once", "the brief, stage 2",
     lambda t: "THERE IS ONLY ONE" in t),
    ("the paths only a person may merge", "the brief, stage 2", triple),
    ("the STOP file", "the brief, stage 1",
     lambda t: ".autofleet/STOP" in t),
    # All three, because the rule is BOTH halves: the closing line AND the two
    # pass names `merge_gate.py` greps the body for. Keyed on `Closes #` alone,
    # stage 2 could drop the pass names and this still printed ok, on a check
    # named for a rule it was covering half of. Found by the independent review.
    # BOTH halves, because the rule is both: the closing line AND the pass name
    # `merge_gate.py` greps the body for. Keyed on `Closes #` alone, stage 2
    # could drop the pass name and this still printed ok, on a check named for a
    # rule it was covering half of.
    #
    # ONE pass name now, not two. `/code-review` left `LOCAL_PASSES` when
    # `/implement` became the opening prompt -- it runs
    # `/mattpocock-skills:code-review` itself, and requiring a second overlapping
    # review before the pull request existed was cost with no reader.
    ("`Closes #N`, and what merge-gate reads from the body", "the brief, stage 2",
     lambda t: all(n in t for n in ("Closes #",
                                    "mattpocock-skills:code-review"))),
]

bad = []
for rule, home, states in RULES:
    where = [name for name, text in texts.items() if states(text)]
    if where == [home]:
        continue
    if not where:
        bad.append(f'{rule} is stated nowhere; its home is {home}')
    elif home not in where:
        bad.append(f'{rule} has left {home}, its home; it is now stated in '
                   + ", ".join(where))
    else:
        bad.append(f'{rule} is stated in {home}, its home, AND restated in '
                   + ", ".join(w for w in where if w != home)
                   + " -- link to the home instead")

# The reading ceiling.
#
# Every `*.md` path the brief's stage 1 -- and, in autofleet, CLAUDE.md -- may
# name, and what its words cost an agent before its first edit. A path missing
# from this table fails: adding a pointer to a document is how the 10,036-word
# one got into the brief, and the table is where that decision is made rather
# than noticed later.
#
#   count    required reading. Its words are inside the ceiling.
#   map      may be NAMED but is not required reading. CLAUDE.md says which
#            document is whose, so it may name these; stage 1 may not, because
#            the brief telling an agent to read something is what makes it
#            required regardless of what any table says.
#   written  a file the agent WRITES. Not reading at all.
DOCS = {
    "CLAUDE.md":                    ("count", "read in full at the start of every session"),
    "REVIEW.md":                    ("count", "the policy the brief names at step 3; a ceiling that left it out would just move words here"),
    "docs/WORKFLOW.md":             ("map",   "the maintainer's explanation, and the reference an agent consults when it needs one; not per-issue reading"),
    "docs/CONFIGURATION.md":        ("map",   "read when wiring a host project"),
    "docs/RUNNERS.md":              ("map",   "read when touching the runner seam (hard rule 4)"),
    "README.md":                    ("map",   "read when deciding whether to install it, not before editing"),
    "AGENTS.md":                    ("map",   "a symlink to CLAUDE.md; counting it would count it twice"),
    ".claude/agents/researcher.md": ("map",   "read by the subagent, in the subagent's own context"),
    ".claude/agents/reviewer.md":   ("map",   "inlined by review.sh into the reviewer's own prompt, not read here"),
    ".claude/agents/validator.md":  ("map",   "inlined by validate.sh and validate.yml into the validator's own prompt"),
    ".autofleet/review.md":         ("map",   "the host project's own correctness rules; read by the reviewer, in its own context"),
    "findings.md":                  ("written", "what a pass run BY HAND writes for record-review.sh; step 3's own file is the one below"),
    ".autofleet/run/self-review.md": ("written", "where self-review.sh leaves what the two passes found -- gitignored, and the file the rebase remedy re-records"),
}

# `+`, not `*`. With `*` the prefix is optional, so the bare word `.md` in
# ordinary prose -- "every `.md` under docs/" -- matched as a path, and the
# failure named a file that does not exist. Found by the local /code-review pass.
NAMED = re.compile(r"[A-Za-z0-9_./-]+\.md")

# What the brief NAMES, it makes required -- whatever the table says. The table
# records an intention; the brief is what the agent is actually told. So a `map`
# document named in stage 1 is both reported here AND counted into the ceiling
# below, because that is what it costs.
required = {p for p, v in DOCS.items() if v[0] == "count"}
# BOTH STAGES are scanned for pointers, though only stage 1's words are in the
# ceiling. The first version scanned stage 1 alone, which left the guard watching
# half the brief: a `docs/WORKFLOW.md` added to stage 2 tripped nothing -- not
# this scan, not the ceiling, not tests/test_brief.sh -- and that is the
# regression armaatus/autofleet#54 is about, one stage over. Found by the
# independent review.
scanned = [("the brief, stage 1", texts["the brief, stage 1"], ("count", "written")),
           ("the brief, stage 2", texts["the brief, stage 2"], ("count", "written"))]
if IN_AUTOFLEET:
    scanned.append(("CLAUDE.md", texts["CLAUDE.md"], ("count", "map", "written")))
for where, text, may_name in scanned:
    for path in sorted(set(NAMED.findall(text))):
        kind = DOCS.get(path)
        if kind is None:
            bad.append(f"{where} names {path}, which is not in the reading table "
                       "above -- decide whether its words are inside the ceiling "
                       "and say so there")
        elif kind[0] not in may_name:
            bad.append(f"{where} sends the agent to {path}, which is not required "
                       f"reading ({kind[1]}). Name it in CLAUDE.md's document map "
                       "if it needs naming at all")
            if kind[0] == "map":
                required.add(path)

# ...and REVIEW.md is named where the passes are run, not in the preamble. An
# agent reads the brief top to bottom; a policy named before step 1 is read
# before step 1.
s1 = texts["the brief, stage 1"]
if "REVIEW.md" in s1 and "/code-review" in s1 \
        and s1.index("REVIEW.md") < s1.index("/code-review"):
    bad.append("the brief names REVIEW.md before it names /code-review, so it is "
               "read in the preamble rather than at the step it is the policy for")

# The reading ceiling is the acceptance of armaatus/autofleet#54: CLAUDE.md, the
# OPENING brief, and anything either names as required reading, before the first
# edit. Its number is the `reading` row of the ceilings table at the top of this
# file.
#
# STAGE 2 IS DELIBERATELY OUTSIDE THE SUM, and this is the only place that says
# so. "Before its first edit" is the measurement, and stage 2 is fetched after
# the PR exists -- counting its ~1,100 words would put the total near 4,500 and
# make the ceiling mean something other than its name. What stage 2 does NOT get
# is a free pointer: the scan above reads both halves, so neither can send an
# agent to a document whose words nobody counted. Found by the independent
# review, which caught the ceiling's comment claiming "either" while the sum took
# one.
#
# `rendered` is stage 1 with the issue number substituted and __TEST_COMMAND__
# left standing as the one word it is -- the same figure the `brief` row above
# measures, and for the same reason: this check is vendored, and a host
# project's nine-word test command must not spend autofleet's margin in a repo
# that did not write the text.
#
# In a host repo CLAUDE.md is out of the sum for the same reason it is out of the
# table above: it is the host's own file, and a ceiling stored in a vendored
# script is not autofleet's to put on it. What remains -- the brief, REVIEW.md,
# and anything the brief names -- is text autofleet ships, which is exactly what
# a vendored ceiling may bound.
#
# The limit itself is the `reading` row of the ceilings table at the top of this
# file, passed in rather than restated: one number, one home, and the same one
# tests/test_brief.sh reads when it measures this row on what the script prints.
CEILING = int(os.environ["reading_ceiling"])
if not IN_AUTOFLEET:
    required.discard("CLAUDE.md")
parts = [(p, len(read(p).split())) for p in sorted(required)]
parts.append(("the brief, stage 1", len(os.environ["rendered"].split())))
total = sum(n for _, n in parts)
if total > CEILING:
    # The four things armaatus/autofleet#56 asks every ceiling failure to name:
    # what was measured, the limit, the figure, and where the limit is changed.
    # Spelled here rather than through `over_ceiling` because this check is
    # python inside the shell, and the breakdown per document is the part that
    # says WHICH text grew.
    bad.append(f"{os.environ['reading_what']}: {total}, over the ceiling of "
               f"{CEILING} set by {os.environ['reading_issue']}. Raise the "
               "`reading` row in the ceilings table at the top of evals/lint.sh, "
               "deliberately, or spend fewer: "
               + ", ".join(f"{p} {n}" for p, n in parts))

if bad:
    sys.exit("\n  ".join(bad))
whose = "" if IN_AUTOFLEET else " (this repo's own CLAUDE.md is not counted: autofleet did not write it)"
print(f"        {total} words before the first edit, ceiling {CEILING}{whose}")
PYEOF
    ok "each enforced rule is stated once, in the file that is its home"
  else
    fail "the loop is written more than once, or costs more than it may (above)"
  fi
else
  # Hard rule 3. The extraction above already `fail`s when it comes back empty,
  # so the run is red either way -- but a block that quietly asserts nothing
  # prints no line saying so, and the next reader of a red log sees six checks
  # where there were seven. The adjacent block at the top of this section is the
  # shape being copied. Found by the local /mattpocock-skills:code-review pass.
  fail "the brief's two stages could not be read, so the rule of one home and the reading ceiling asserted nothing"
fi

# ...and docs/WORKFLOW.md's agent-instruction sections are POINTERS.
#
# The page keeps every word of explanation -- that is what it is for -- but a
# fenced block holding a step of the loop is a copy an agent can work from, and
# a copy is what drifts. The brief is the home; this page says where the home
# is. Fences are the test because a fence is the only form an agent can act on
# without reading the prose around it.
if python3 - <<'PYEOF'; then
import re, sys
try:
    page = open("docs/WORKFLOW.md").read()
except OSError as exc:
    sys.exit(f"docs/WORKFLOW.md cannot be read ({exc.strerror}); this check "
             "asserts nothing")

# BOTH forms of code block markdown has, because the repo writes in both: the
# brief in `issue-command.sh` uses the four-space indented form throughout, so
# that is the style an editor reaches for, and a check that only saw fences would
# let the whole second copy back in under the more natural spelling.
#
# `[^\n]*` for the info string, not `[A-Za-z]*`: ANY opener, including a tag
# carrying a digit, a dot or a space. An opener this does not match does not skip
# one block -- it shifts the non-greedy pairing, so the PROSE between two fences
# is scanned and the fences themselves are not, and the check goes quiet rather
# than going red. That is hard rule 3 arriving silently, and the narrower class
# had the hole its own comment described. Found by the local /code-review pass,
# then again by the independent review one class wider.
blocks = re.findall(r"```[^\n]*\n(.*?)```", page, re.S)
fenced = set()
for m in re.finditer(r"```.*?```", page, re.S):
    fenced.update(range(m.start(), m.end()))
# ACCEPTED COST: this cannot tell an indented code block from a nested bullet or
# a wrapped list item at four spaces. A prose sentence under a nested bullet that
# happens to say `await-review.sh` fails with "still prints a runnable copy of
# the loop", which will read as a lie to whoever hits it. The trade is deliberate
# -- the indented form is how the brief writes commands, so a scan that skipped
# it would let the whole second copy back in under the more natural spelling --
# but the next reader deserves to know it is a trade. Found by the independent
# review.
for m in re.finditer(r"(?m)^ {4,}\S.*$", page):
    if m.start() not in fenced:
        blocks.append(m.group(0))

# The loop's steps. `issue-command.sh` itself is NOT here: printing the command
# that fetches the brief is the pointer this check is asking for.
STEPS = ["self-review.sh", "record-review.sh", "await-review.sh",
         "review-status.sh", "resolve-thread.sh", "answer-review.sh",
         "gh pr merge", "/code-review", "/mattpocock-skills:code-review"]
found = sorted({s for b in blocks for s in STEPS if s in b})
if found:
    sys.exit("docs/WORKFLOW.md still prints a runnable copy of the loop: "
             + ", ".join(found)
             + ". The brief is where those live; this page explains why they exist")
# ...and it says whose page it is in its OPENING PARAGRAPH, which is the
# acceptance of armaatus/autofleet#54 word for word. Anywhere above the first
# `##` was the first spelling and it is too loose: an audience stated in the
# fourth paragraph is one an agent has already paid three paragraphs to reach.
# The title is dropped first, then everything up to the first blank line.
# Found by the local /mattpocock-skills:code-review pass.
body = page.split("\n", 1)[1] if page.startswith("#") else page
# `paragraphs()` above, not a literal "\n\n": a blank line carrying one trailing
# space is invisible, nothing here strips it, and the split would then make
# `opening` the whole page -- so the check would pass on a page that names its
# audience in the last paragraph. Found by the independent review.
opening = [p for p in re.split(r"\n\s*\n", body) if p.strip()][0]
for needle in ("maintainer", "issue-command.sh"):
    if needle not in opening:
        sys.exit("docs/WORKFLOW.md's OPENING PARAGRAPH does not say who reads it "
                 "and where the agent's instructions are instead (missing: "
                 f"{needle}). The paragraph read: {opening[:120]}...")
PYEOF
  ok "docs/WORKFLOW.md names its audience and points at the brief rather than copying it"
else
  fail "docs/WORKFLOW.md is still a second copy of the loop (above)"
fi

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
  if sed -n '/say so if no verdict/,/^      - /p' "$review_wf" | qgrep "gh pr review"; then
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
       | qgrep -E "^[[:space:]]*cancel-in-progress:[[:space:]]*true"; then
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


# Over the CODE, and the code is the `script:` BODY -- not the file. `literal()`
# takes the FIRST assignment it finds, and this file explains itself at length:
# a commented-out literal above the real one would be the one compared, and the
# comparison would pass while the workflow ran something else.
#
# Stripping `//` out of the whole file was only half of that, and the half that
# was missing is the one that bites. The YAML header above `script:` is 67 lines
# of `#` prose that survives a `//` strip, and the ordering assertion below uses
# `find()` -- so extending the concurrency comment with a line like
# `# so removeLabel runs before addLabels` puts the first hit inside a comment,
# ahead of every line of code, and `where_remove > where_add` can never be true
# again. The check then passes for ANY order, including the one it exists to
# catch. Verified: one such comment is enough. Hard rule 3, arriving through the
# prose that describes the rule. Found by the independent review.
_body = re.search(r"(?m)^\s*script: \|\n(.*)\Z", src, re.S)
if not _body:
    sys.exit("unblock.yml has no inline `script: |` block; none of the checks "
             "below can see what the job actually runs")
code = "\n".join(re.sub(r"//.*", "", line) for line in _body.group(1).splitlines())


def literal(name):
    """The JS regex `name` is assigned, as a Python pattern and flags."""
    hit = re.search(r"const\s+" + name + r"\s*=\s*/(.*)/([a-z]*);", code)
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

# ...and the prefix stays UNAMBIGUOUS. `\*{1,2}` alongside `*` in the character
# class matched the same text two ways under a `*` quantifier, which is
# exponential: 22 asterisks took 15 seconds to fail, and a separator line in an
# issue body would hang this workflow on every edit and the dispatcher with it.
# Timed rather than pattern-matched, because the next way to reintroduce it will
# not be spelled the same. Found by the independent review.
# TWENTY, not more. The probe has to be long enough that a reintroduced
# ambiguity is unmistakably slow and short enough that it still RETURNS: at 40
# asterisks the bad pattern never finishes and this check hangs the lint instead
# of failing it, which is a worse outcome than the bug. Measured on the two
# patterns: 20 asterisks is 2.6s ambiguous and 5 microseconds not.
import time as _time
_probe = "*" * 20 + "x"
_t0 = _time.time()
wf_blocked.search(_probe)
m.BLOCKED_BY.search(_probe)
if _time.time() - _t0 > 1.0:
    sys.exit("the blocker pattern backtracks exponentially on a line of "
             "asterisks; a separator line in any issue body would hang unblock.yml "
             "and ready_issues() with it -- an alternative that overlaps the "
             "character class has been reintroduced")

# Character for character first, which is what #47's acceptance asked for: two
# differently-spelled but equivalent patterns pass the behavioural run below and
# are still the drift this section exists to catch, because the NEXT edit to
# either one starts from a different string.
for name, workflow_side, module_side in (
    ("BLOCKED_BY", wf_blocked, m.BLOCKED_BY),
    ("BLOCKERS_MARKER", wf_marker, m.BLOCKERS_MARKER),
):
    if workflow_side.pattern != module_side.pattern:
        sys.exit(f"unblock.yml spells {name} as {workflow_side.pattern!r} and "
                 f"issue_refs.py spells it {module_side.pattern!r}")

# ...and the workflow has to actually USE the scoping, not merely define it.
# Nothing asserted the call: deleting `blockersSection(` from the loop and
# matching over the raw body left every check here green while the workflow read
# whole bodies again -- hard rule 3, the guard that stops guarding. Found by the
# independent review.
if not re.search(r"blockersSection\(\s*issue\.body\s*\)\.matchAll\(\s*BLOCKED_BY\s*\)",
                 code):
    sys.exit("unblock.yml no longer matches BLOCKED_BY over blockersSection("
             "issue.body); the marker scoping is defined and not used, so prose "
             "anywhere in a body blocks work again (#47)")
if not re.search(r"matchAll\(\s*BLOCKERS_MARKER\s*\)", code):
    sys.exit("unblock.yml no longer walks BLOCKERS_MARKER; blockersSection "
             "cannot be finding the marker at all")

# THE SHAPE OF THE WALK AND THE SLICE, not just the call.
#
# Everything above compares the workflow's two regex LITERALS, lifted into
# Python. The scoping around them is a JavaScript arrow function, and the mirror
# used to check it (`wf_blocked_by`) is re-typed here rather than executed -- so
# these three one-line mutations of unblock.yml left this whole file green while
# the workflow did something else, which the independent review demonstrated:
#
#   `{ first = m; break; }` -> `last = m`       : last marker wins again
#   `: text`                -> `: ''`           : the 14 marker-less issues read
#                                                 as UNBLOCKED -- fail-open, and
#                                                 the collision the label exists
#                                                 to prevent
#   `slice(first.index + ...)` -> `slice(0, ...)`: reads only ABOVE the marker
#
# Pinned by shape, the way the call site already is. Executing the JS under node
# would close it properly, but node is not a dependency this repo has (CLAUDE.md:
# bash and python3, nothing to install) and a check that silently skips where node
# is absent is hard rule 3 arriving through the door marked "not a failure".
if not re.search(r"for\s*\(const\s+m\s+of\s+text\.matchAll\(\s*BLOCKERS_MARKER\s*\)\s*\)"
                 r"\s*\{\s*first\s*=\s*m;\s*break;\s*\}", code):
    sys.exit("unblock.yml no longer stops at the FIRST blockers marker; a body "
             "carrying the template marker twice loses the section above the "
             "last one, and goes ready with an open blocker (#47)")
if not re.search(r"return\s+first\s*\?\s*text\.slice\(\s*first\.index\s*\+\s*"
                 r"first\[0\]\.length\s*\)\s*:\s*text\s*;", code):
    sys.exit("unblock.yml no longer returns everything BELOW the marker, with the "
             "whole body as the fallback; slicing the other way, or returning '' "
             "when there is no marker, reads issues as unblocked that are not")

# The stale label comes off BEFORE the new one goes on. `cancel-in-progress`
# makes a run that dies between the two calls reachable, and the other order
# leaves the issue carrying both `blocked` and `ready` -- and fleet.sh\'s
# ready_issues() selects on `ready` without ever consulting `blocked`, so that
# issue is startable. This order leaves neither label, and the fleet starts
# nothing without `ready`. Found by the independent review.
# `find`, not `index`: a workflow that has stopped writing labels at all should
# say so, not raise a ValueError out of the middle of a lint run.
where_remove, where_add = code.find("removeLabel"), code.find("addLabels")
if where_remove < 0 or where_add < 0:
    sys.exit("unblock.yml no longer both removes and adds labels; it cannot be "
             "maintaining blocked/ready, which is the only thing it is for")
if where_remove > where_add:
    sys.exit("unblock.yml adds the new label before removing the stale one; a "
             "cancelled run leaves an issue carrying both `blocked` and `ready`, "
             "and fleet.sh will start it (#47)")
# ...and the removal is not allowed to fail quietly. Ordering the two calls fixes
# a run that DIES between them and does nothing for one that FAILS the first and
# carries on: a swallowed 403 on removeLabel plus a successful addLabels is the
# both-labels state again, behind a green check. Found by the independent review.
if re.search(r"removeLabel\((?:[^;]|\n)*?\.catch\(\s*\(\s*\)\s*=>", code):
    sys.exit("unblock.yml discards every error from removeLabel again; a rate "
             "limit on the removal leaves the issue carrying both `blocked` and "
             "`ready`, and ready_issues() starts it (#47)")
if not re.search(r"err\.status\s*!==\s*404", code):
    sys.exit("unblock.yml no longer singles out a 404 from removeLabel; only the "
             "label already being gone is a safe failure to pass over")
# ...and the rest is REPORTED, after the loop. Throwing from inside the loop
# abandons every issue after the failing one; swallowing leaves the run green
# while the labels are wrong. Found by the independent review.
if not re.search(r"writeFailures\.push", code):
    sys.exit("unblock.yml no longer records a failed label write; a rate limit on "
             "one removal goes unreported and the run stays green with an issue "
             "left startable on an open blocker (#47)")
# BOTH writes go through writeFailures, not just the removal. The policy was
# stated in the diff and applied to one of the two: a 403 on addLabels threw,
# abandoning every issue after it in the loop and discarding the failures already
# collected -- and, since the removal now runs first, leaving that issue with
# NEITHER label. Found by the independent review.
add_call = re.search(r"addLabels\(\{(?:[^}]|\n)*?\}\)((?:[^;]|\n)*?);", code)
if not add_call:
    sys.exit("unblock.yml no longer has a readable addLabels call; this check "
             "cannot see whether it handles its own failure")
# ...and the add is GATED on the removal. Ordering the writes and catching the
# failure are both necessary and neither is sufficient: with `labels` a pre-run
# snapshot, a recorded 403 on the removal still fell through to the add, and the
# issue ended carrying BOTH labels -- the state ready_issues() starts. The
# ordering check above and the catch check below each passed throughout. Found by
# the independent review.
if not re.search(r"if\s*\(\s*removed\s*&&\s*!labels\.includes\(add\)\s*\)", code):
    sys.exit("unblock.yml adds a label without checking that the stale one came "
             "off; a failed removal plus a successful add leaves the issue "
             "carrying both `blocked` and `ready`, and fleet.sh starts it (#47)")
if not re.search(r"removed\s*=\s*await\s+github\.rest\.issues\.removeLabel", code):
    sys.exit("unblock.yml no longer records whether the removal succeeded; the "
             "gate on the add cannot be meaningful without it")
if "catch" not in add_call.group(1):
    sys.exit("unblock.yml's addLabels has no catch; a rate limit there throws "
             "mid-loop, abandons every issue after it, discards the writeFailures "
             "already collected, and leaves that issue carrying NEITHER label "
             "(#47)")
if not re.search(r"core\.setFailed\(", code):
    sys.exit("unblock.yml no longer fails the run when a label write failed; a "
             "partly-relabelled backlog behind a green check is what Scope 3 was "
             "about")
if re.search(r"if\s*\(!err\s*\|\|\s*err\.status\s*!==\s*404\s*\)\s*throw", code):
    sys.exit("unblock.yml throws from inside the relabelling loop; every issue "
             "after the failing one is then left un-relabelled, which is worse "
             "than finishing the pass and failing the step afterwards")
# CRLF is folded on the way in rather than patched into the pattern, because the
# comparison above lifts the workflow\'s pattern text into Python and cannot see
# an engine difference in how `$` and `\r` interact.
if not re.search(r"replace\(\s*/\\r", code):
    sys.exit("unblock.yml no longer folds CRLF before reading a body; a body "
             "edited in the GitHub web UI loses its `<!-- blockers -->` marker "
             "and the whole body is read as blockers again (#47)")

# The workflow's own scoping, spelled here the way the JS spells it: the FIRST
# marker alone on a line, or the whole body when there is none. (This header said
# LAST for one commit, in the file whose job is to notice that -- and three checks
# below fail the build over the same word. Found by the independent review.)
def wf_blocked_by(body):
    # The same fold and the same FIRST-marker walk the workflow does, asserted by
    # shape below. Re-typed here rather than lifted, because a JS arrow function
    # is not something Python can execute -- which is why the assertions that pin
    # the workflow's walk and slice matter more than this mirror does.
    text = (body or "").replace("\r\n", "\n").replace("\r", "\n")
    first = None
    for hit in wf_marker.finditer(text):
        first = hit
        break
    if first:
        text = text[first.end():]
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
#
# ON THE JOB, NOT THE WORKFLOW, and that distinction is the assertion: at
# workflow level EVERY triggering event enters the group, including the
# `pull_request: closed` of a PR that was never merged, which the job\'s `if:`
# then skips -- so it cancels a reconcile in flight and does no relabelling of
# its own. Found by the independent review, on the first version of this change.
if python3 - <<'PYEOF'; then
import re, sys
src = open(".github/workflows/unblock.yml").read()
if re.search(r"(?m)^concurrency:", src):
    sys.exit("unblock.yml declares concurrency at WORKFLOW level; an event the "
             "job skips still takes the group and cancels a run in flight, so a "
             "PR closed without merging aborts a relabelling pass and does none")
hit = re.search(r"(?m)^    concurrency:\n((?:[ \t]{6,}\S.*\n)+)", src)
if not hit:
    sys.exit("unblock.yml has no job-level concurrency: group; two runs from two "
             "issue edits can interleave and land an issue ready with an open "
             "blocker")
block = hit.group(1)
if not re.search(r"(?m)^\s+group:\s*\S", block):
    sys.exit("unblock.yml\'s concurrency: has no group:")
if not re.search(r"(?m)^\s+cancel-in-progress:\s*true", block):
    sys.exit("unblock.yml\'s concurrency: does not cancel in progress; the older "
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
import re, sys, os
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
# ...and it agrees with the readers about WHICH marker wins. The page is the
# vendored one an agent reads before editing an issue body, and it defines where
# blocker lines go: `42f23d9` moved both readers to first-wins and left this page
# saying "the last marker", so an agent appending a fresh marker would expect the
# section above to be superseded when it is actually added to. Nothing caught
# that -- the trigger check above only looks for the four event names. Found by
# the independent review.
if re.search(r"below the last `<!-- blockers -->` marker", page):
    sys.exit("docs/WORKFLOW.md says blocker lines are read below the LAST marker; "
             "both readers take the FIRST one and everything under it, so the page "
             "describes a rule the code does not implement")
if not re.search(r"below the \*\*first\*\* `<!-- blockers -->` marker", page):
    sys.exit("docs/WORKFLOW.md no longer says which marker wins; it is the page "
             "that defines the convention for every agent that edits an issue")
# ...and it says what happens with NO marker, which is the branch governing 14 of
# this repo's own open issues and every host project that never adopts the
# convention. The page used to say flatly that prose does not block anything.
# That is true below a marker and false without one, and the agent who believes
# it writes `- Blocked by #12 until that lands` into Design notes and has its own
# worktree reaped -- the harm #47 was filed about, arriving through the sentence
# that says it cannot happen. Found by the independent review.
if not re.search(r"body with no marker is read whole", page):
    sys.exit("docs/WORKFLOW.md does not say that a body with no `<!-- blockers "
             "-->` marker is read whole; an agent reading it will believe prose "
             "in Design notes is inert on an issue where it is a blocker (#47)")
# ...and NOT a matching demand on CLAUDE.md, deliberately.
#
# CLAUDE.md is absent from install.sh's PAYLOAD -- a host project writes its own
# -- and this file IS vendored. An assertion here requiring a literal English
# sentence there fails the lint in every host repo, which is hard rule 1 exactly.
# The first version of this check was unconditional and did that; the second made
# it conditional on the page mentioning the marker, which is better and still
# wrong, because it demands OUR phrasing of a page whose author may reasonably
# word it differently.
#
# So the vendored page carries the assertion and this repo's own CLAUDE.md does
# not. What keeps that honest is that docs/WORKFLOW.md is where the convention is
# specified and CLAUDE.md points at it. Raised twice by the independent review,
# which is why it is written down rather than simply deleted.
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
     | grep -vi '^ *[0-9]*: *#' | qgrep .; then
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
if ! grep -A6 'sparse-checkout' .github/workflows/merge-gate.yml | qgrep '\.github/scripts'; then
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
  # THREE readers, not two. await-review.sh joined them when it stopped asking
  # `pulls/<n>/comments` for the findings it hands back (#53) -- and it is the
  # one most able to drift, because it wants a field the other two do not read.
  # Unlisted, it could grow its own `reviewThreads(first:100)` tomorrow and this
  # would stay green, which is #114 exactly.
  for reader in .github/workflows/merge-gate.yml scripts/fleet/review-status.sh \
                scripts/fleet/await-review.sh; do
    # Comment lines excluded HERE TOO, and that is the point. Every one of these
    # files also NAMES pr_payload.sh in a comment explaining why it does not
    # write its own query -- so a grep of the whole file is satisfied by the
    # explanation and stays green when the call it describes is deleted. The
    # call itself is `pr_payload.sh` in the workflow and `fleet_pr_payload` in
    # the two scripts, which reach it through lib.sh.
    grep -vE '^[[:space:]]*#' "$reader" | qgrep -E 'fleet_pr_payload|pr_payload\.sh' \
      || fail "$reader does not read the PR through .github/scripts/pr_payload.sh, so it is paging threads on its own again"
    # Comment lines excluded: both files EXPLAIN what `reviewThreads(first:100)`
    # got wrong, and a bare grep flags its own explanation.
    grep -vE '^[[:space:]]*#' "$reader" | qgrep 'reviewThreads(first:' \
      && fail "$reader carries its own reviewThreads query again; the first page is not the list"
  done
  # merge-gate.yml runs BOTH of these out of the BASE branch's checkout, and a
  # base predating either one is a PR a person merges -- which has to be SAID.
  # Before the guard named both, the second one to be added killed the step with
  # `No such file or directory` on exactly the PR introducing it.
  for needed in merge_gate.py pr_payload.sh; do
    sed -n '/agreed rule to judge this by/,/^      - name:/p' \
      .github/workflows/merge-gate.yml | qgrep "$needed" \
      || fail "merge-gate.yml runs $needed from the base checkout without checking the base has it; a base predating it dies with a shell error instead of the human-merge notice"
  done
  ok "a base without the gate's own scripts is told, not crashed into"

  ok "the gate, review-status and the wait read one paginated payload"
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
