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
# NO APOSTROPHE AND NO LONE BACKTICK IN A ROW BELOW, and it is not a style
# rule. This heredoc sits inside `"$( ... )"`, and bash lexes the body of a
# command substitution for quotes and backticks even where the heredoc
# delimiter is quoted -- so one `it's` in a description is an unterminated
# string, and the whole file stops parsing 3,000 lines later with the error
# pointing at the end of it. Two rows carried one each, which balanced; editing
# one of them was what found this.
CEILINGS="$(cat <<'CEILINGS'
claude-md|200|armaatus/autofleet#56|lines of CLAUDE.md, which every session reads in full|evals/lint.sh
brief|400|armaatus/autofleet#49|words of the opening brief, the issue spec excluded and __TEST_COMMAND__ counted as one word|evals/lint.sh; tests/test_brief.sh stage1
reading|3500|armaatus/autofleet#54|words a fleet agent is told to read before its first edit: the brief, every "count" row of the reading table below, and the one text autofleet does not write but the agent still reads -- the issue spec at the `spec` allowance|evals/lint.sh; tests/test_brief.sh reading
spec|500|armaatus/autofleet#98|words of an issue body the reading ceiling budgets for. NOT a limit on a tracker a maintainer writes -- it is the allowance the payload leaves for one, because the spec is injected ahead of the brief and read before the first edit like everything else|evals/lint.sh
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
# lives in the ceilings table above, with the others. How many rows there are
# is not written anywhere: it was "the other five" while there were six, and
# the row that made it seven did not come with an edit here.
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
# installation those rows are numbers with no local enforcement, which is the
# same trade `== every test phase actually runs` already makes. Which rows fall
# on which side is read off the table's fifth field rather than counted here --
# the counts that were written down went stale the first time a row was added.
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
  # not grown an entry that no assertion covers. That pin stays here.
  # The list below is literal on purpose: derived from SELF_PROTECTED, removing
  # an entry would remove its own check. That catches a removal but not an
  # ADDITION -- a new marker would get no assertion in guard.py's
  # _stateful_checks and the coverage would quietly narrow -- so pin the set.
  # The three `.autofleet/` entries joined it with armaatus/autofleet#38: the
  # merge gate refuses to let a PR touching them merge itself, and this is the
  # half that stops a fleet worktree disarming them while the PR is still open.
  if sp_drift="$(python3 -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("g", ".claude/hooks/guard.py")
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)
want = {"/.claude/hooks/", "/.claude/settings.json", "/.claude/settings.local.json",
        "/.autofleet/guard.json", "/.autofleet/config", "/.autofleet/review.md"}
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

echo "== the one review"
# Every one of these is a link in a chain whose breakage is SILENT, and the
# silence is the same in each case: merge-gate wants an approving verdict on the
# head, nothing produces one, and every pull request the fleet opens waits
# forever.

# 1. The reviewer's brief. review.sh inlines it into the prompt, so a missing
#    file is a review run against no policy at all.
if [ -f .claude/agents/reviewer.md ]; then
  for needle in "REVIEW.md" "request-changes" "verdict" "severity"; do
    grep -q -- "$needle" .claude/agents/reviewer.md \
      || fail ".claude/agents/reviewer.md no longer mentions '$needle', which the reviewer has to answer with or read"
  done
  ok "the reviewer brief names REVIEW.md, the verdict and the severities"
else
  fail ".claude/agents/reviewer.md is missing, so the review has no brief"
fi

# 2a. THE RULE THAT DECIDES A MERGE, stated the same way in the two places the
#     reviewer reads. `verdict` is request-changes if and only if something is
#     Critical or Important -- a brief that says one thing and a policy that
#     says another is a reviewer choosing, and what it chooses between is
#     whether the branch merges.
# Read with the whitespace squeezed out, because this is prose: a reflow that
# moved the clause onto the next line would silence a line-oriented grep, and an
# assertion a reflow can switch off is not an assertion.
flat() { tr -s '[:space:]' ' ' <"$1"; }
if flat REVIEW.md | qgrep 'if and only if' \
   && flat .claude/agents/reviewer.md | qgrep 'if and only if'; then
  ok "the policy and the brief agree on when a verdict blocks"
else
  fail "the 'request-changes if and only if Critical or Important' rule is missing from REVIEW.md or the reviewer brief; the reviewer is choosing"
fi

# 2b. ...and both of them say a Suggestion blocks nothing. This is the half that
#     costs money when it goes: a nit treated as a blocker buys a fix session,
#     a re-review and a park, to change a comment.
if flat REVIEW.md | qgrep 'blocks nothing' \
   && flat .claude/agents/reviewer.md | qgrep 'blocks nothing'; then
  ok "...and that Suggestions alone are an approve"
else
  fail "REVIEW.md or the reviewer brief has stopped saying a Suggestion blocks nothing"
fi

# 2c. THE VERDICT MARKER, spelled the same way in every file that writes or
#     reads it. `review.sh` writes it, `merge_gate.py` is the only thing that
#     lets a PR merge on it, and `await-review.sh` is what a person polls with.
#     A drift is a review that posts and is then ignored, which reads exactly
#     like a reviewer that never ran.
marker_missing=""
for f in scripts/fleet/review.sh .github/scripts/merge_gate.py \
         scripts/fleet/await-review.sh; do
  grep -q 'autofleet-verdict' "$f" || marker_missing="$marker_missing $f"
done
if [ -z "$marker_missing" ]; then
  ok "the verdict marker is spelled the same in the writer, the gate and the wait"
else
  fail "the verdict marker is missing from:$marker_missing -- a verdict nothing reads holds every PR forever"
fi

# 2d. ...and the MODEL does not spell it. The marker is what releases the merge
#     gate, so a prompt that handed the reviewer the string would put the one
#     thing separating its verdict from the author's inside untrusted output.
#     `review.sh` builds it from the schema's `verdict` field.
#
#     The literal OPENING of the comment, not the word: REVIEW.md explains the
#     marker in prose and must go on being able to, and what may not appear is a
#     block the reviewer could copy.
if grep -q -- '<!-- autofleet-verdict' .claude/agents/reviewer.md; then
  fail "the reviewer brief hands the model the verdict marker; review.sh writes it from the schema, and a model that can type it can approve itself"
else
  ok "...and the brief explains the marker without handing it to the model"
fi

# 2e. THE SEVERITIES THE SCHEMA ACCEPTS ARE THE ONES THE POLICY DEFINES. The
#     schema is an enum, so a policy word outside it is a finding the reviewer
#     cannot return at all -- and a value outside an enum fails the whole call
#     rather than dropping the field, which is a review that produces nothing.
sev_missing=""
for sev in Critical Important Suggestion; do
  grep -q "\"$sev\"" scripts/fleet/review.sh || sev_missing="$sev_missing review.sh:$sev"
  grep -qF -- "**$sev**" REVIEW.md || sev_missing="$sev_missing REVIEW.md:$sev"
done
if [ -z "$sev_missing" ]; then
  ok "the schema's severities are the three REVIEW.md defines"
else
  fail "a severity is in one of the schema and the policy and not the other:$sev_missing"
fi

# 2f. THE CEILING IS TWO REVIEWS, and it is a FILE rather than the shape of a
#     script: a dispatcher restart, a second machine or a person running
#     `after-pr.sh` by hand would each otherwise get their own two. What this
#     really defends is that the count is written BEFORE the review runs --
#     counting on success is a crash loop that re-reviews every poll at full
#     budget.
if grep -q '\.reviews' scripts/fleet/after-pr.sh \
   && grep -q 'Written BEFORE the run' scripts/fleet/after-pr.sh; then
  ok "after-pr.sh counts a review before it buys it"
else
  fail "after-pr.sh no longer counts reviews before running them, so the ceiling of two is not a ceiling"
fi

# 2g. THE REVIEWER READS AND THE FIX WRITES, and never the other way round. If
#     `review.sh` ever grants an edit tool, the pass that judges the diff is the
#     pass that wrote it; if it grants a posting tool, the verdict stops being
#     a value the script controls.
if grep -q "^tools='Read,Grep,Glob'" scripts/fleet/review.sh \
   && ! grep -qE '^tools=.*(Edit|Write|gh pr review)' scripts/fleet/review.sh; then
  ok "the reviewer's tool list is read-only, and does not include posting"
else
  fail "scripts/fleet/review.sh grants the reviewer a tool that edits or posts; the script posts, and fix.sh edits"
fi

# 2h. THE REVIEW IS NOT THE AUTHOR'S TO START, asserted here rather than only in
#     guard.py's own selftest: the selftest proves the rule works, and this
#     proves the rule is still wired to all three scripts it has to cover.
if grep -q '"review.sh", "fix.sh", "after-pr.sh"' .claude/hooks/guard.py \
   && python3 .claude/hooks/guard.py --selftest >/dev/null 2>&1; then
  ok "guard.py refuses the review, the fix and the loop from a fleet worktree"
else
  fail "guard.py no longer refuses review.sh, fix.sh and after-pr.sh from a fleet worktree -- a branch that can start its own reviewer can certify itself"
fi

# 3. THE BASE-REF READ. On a pull_request event actions/checkout defaults to the
#    MERGE ref, so without this pin the script deciding the required check is
#    the one the PR is proposing -- and a PR that replaced merge_gate.py's body
#    with an exit(0) would pass its own gate.
#
#    ONE step, not two greps: checked separately, the scripts could move to a
#    head-ref checkout and both halves would stay green.
if python3 - <<'BASEREF'; then
import re, sys
wf = open(".github/workflows/merge-gate.yml").read()
# Each `- uses: actions/checkout` block, up to the next step at the same indent.
steps = re.split(r"\n      - (?=uses:|name:|id:)", wf)
for step in steps:
    # `startswith`, because split()'s first element is the whole file preamble --
    # which discusses the checkout in prose and would otherwise be judged as if
    # it were the step.
    if not step.startswith("uses: actions/checkout"):
        continue
    if ".github/scripts" not in step:
        continue
    if "github.event.pull_request.base.sha" in step:
        sys.exit(0)
    sys.exit("the checkout that fetches .github/scripts is not pinned to the base "
             "sha, so a pull request could rewrite the gate that judges it")
sys.exit("no checkout step in merge-gate.yml fetches .github/scripts; the Decide "
         "step would run nothing at all")
BASEREF
  ok "merge-gate.yml reads the gate from the BASE ref, in one checkout"
else
  fail "merge-gate.yml's base-ref read of the gate has come apart (above)"
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

#    THE REVIEWER'S ALLOWLIST, which since armaatus/autofleet#152 is defended
#    in the opposite direction from the one it used to be. It used to have to
#    GRANT `Bash(gh pr review:*)`: the reviewer submitted for itself, and a list
#    without it produced an agent that read the whole diff, formed a verdict and
#    could not post -- every PR blocked on a review that had actually been
#    written. The script posts now, so the same grant is the hazard: a reviewer
#    that can post can post a verdict the script did not derive from the schema.
#
#    Both halves in one check, because .claude/agents/reviewer.md duplicates the
#    list in its frontmatter and ASSERTS that the two are identical. A drift
#    makes the registered subagent more powerful than the driven one, which is
#    the thing that paragraph exists to prevent.
#
#    The suite structurally cannot cover this -- `stub_reviewer` replaces the
#    reviewer command wholesale, so the allowlist is exercised by no test at all.
if python3 - <<'TOOLS'; then
import re, sys
driven = open("scripts/fleet/review.sh").read()
brief = open(".claude/agents/reviewer.md").read()

block = re.search(r"^tools=.*?(?=\n\n)", driven, re.S | re.M)
if not block:
    sys.exit("scripts/fleet/review.sh no longer builds a `tools=` allowlist")
granted = set(re.findall(r"[A-Za-z]+\([^)]*\)|(?<![\w(])[A-Z][A-Za-z]+(?![\w)])",
                         block.group(0).replace("tools=", "").replace('"$tools,', "")))
for forbidden, why in (
        ("Bash(gh pr review:*)",
         "the SCRIPT posts the verdict, from the schema's own `verdict` field. A "
         "reviewer that can post can post one the script did not derive, which is "
         "the whole of what the marker keeps out of reach"),
        ("Bash(gh api:*)",
         "it is withheld on purpose: the reviewer holds the maintainer's own gh "
         "login, and that is the one grant on the list with no ceiling. "
         "docs/CONFIGURATION.md carries it as a row in what this gives up"),
        ("Edit", "the reviewer reads; fix.sh writes"),
        ("Write", "the reviewer reads; fix.sh writes")):
    if forbidden in granted:
        sys.exit(f"review.sh grants `{forbidden}`. " + why)

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
TOOLS
  ok 'the reviewer reads only, cannot post its own verdict, and the two routes agree'
else
  fail "the reviewer's tool allowlist has drifted (above)"
fi

#    ...and the FIX session's, which has the opposite shape and a sharper edge:
#    it runs INSIDE a fleet-owned worktree with the build's own permission mode,
#    so it can edit, test, commit and push. What it may not do is the three
#    things `guard.py` refuses there anyway -- review, approve, merge -- and the
#    assertion that matters is that it goes on running under that guard rather
#    than being handed a permission mode of its own.
if python3 - <<'FIXTOOLS'; then
import re, sys
src = open("scripts/fleet/fix.sh").read()
if not re.search(r'^\s*--permission-mode "\$AUTOFLEET_BUILD_PERMISSION_MODE"', src, re.M):
    sys.exit("scripts/fleet/fix.sh no longer runs on AUTOFLEET_BUILD_PERMISSION_MODE. "
             "It edits the same worktree the build edited, under the same hooks; a "
             "second answer to `may I edit this` is two answers about one tree")
if not re.search(r'^\s*\( cd "\$worktree" &&', src, re.M):
    sys.exit("scripts/fleet/fix.sh no longer runs the fix IN the worktree, so "
             "guard.py's fleet-worktree rules -- the ones that refuse review, "
             "approve and merge -- do not apply to it")
for cap in ("--max-turns", "--max-budget-usd"):
    if cap not in src:
        sys.exit(f"scripts/fleet/fix.sh passes no {cap}, so the one fix session a "
                 "pull request gets is bounded by the wall clock alone")
FIXTOOLS
  ok 'the fix session runs in the worktree, under the guard, with both caps'
else
  fail "the fix session's bounds have drifted (above)"
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

# 4f. DELETED WITH THE RULE IT GUARDED.
#
#    It asserted that the transcript slug `cost.sh` derives -- worktree path,
#    every non-alphanumeric character to `-`, capped at SLUG_MAX -- was the rule
#    `config.sh` and `docs/CONFIGURATION.md` published to a host project, because
#    a wrong slug produced a confident table of zeros with a wrong explanation
#    under it. There is no slug: `--output-format json` makes the build print
#    what it spent and `cost.sh` reads that file (armaatus/autofleet#151).
#
#    Named rather than silently removed, because hard rule 3 is about the
#    opposite move -- a guard that stops guarding while the rule stands. This
#    one outlived its rule, and a check with nothing to assert is a green line
#    that means nothing.

# 4g. THE DRIVER THIS REPO IS CONFIGURED TO USE IS ONE THAT EXISTS.
#
#    4b asks whether every driver PRESENT implements the contract; nothing asked
#    whether the name in `.autofleet/config` resolves to a file at all. A host
#    project that sets AUTOFLEET_RUNNER to a driver it has not written yet -- or
#    keeps one past a rename -- is green here and discovers it when the
#    dispatcher opens its first worktree, which is after a person walked away
#    expecting PRs. Red before an agent is opened is the whole point of this
#    file. armaatus/autofleet#13.
#
#    The name is READ FROM config.sh rather than assumed to be `orca`, because
#    `.autofleet/config` is sourced from inside it and is exactly where a host
#    project overrides it.
#
#    A STRIPPED ENVIRONMENT, because the question is which driver THIS REPO is
#    configured for, not which one the maintainer happens to
#    have exported in the shell they ran the lint from. `bash -c` inherits the
#    environment, so a `AUTOFLEET_RUNNER=stub` left over from a test run would
#    fail the lint on a repo that is correctly configured -- and config.sh's own
#    layering note says a config file that assigns outright overrides even the
#    environment, so the ambient value is not authoritative here either way.
#    EVERY autofleet knob rather than the two that were named, which is what
#    three self-review rounds cost to arrive at: config.sh also sources
#    `${AUTOFLEET_CONFIG:-$REPO_ROOT/.autofleet/config}`, so a stale
#    AUTOFLEET_CONFIG answers this check about another repo's file -- and it
#    `exit 2`s on several other ambient knobs, so a leftover
#    AUTOFLEET_REVIEW_MAX_ROUNDS made the check report that the runner could not
#    be established. Consequence as cause, in the check that closes that hole.
#    The rest of the environment is KEPT: `env -i` was the round in between, and
#    a host config that reads $USER or $TMPDIR would have failed under `set -u`
#    with this check blaming the config. Found by the local review, then three
#    times by the self-review.
#
#    `|| exit 1` after the source, because without it the "would not source"
#    branch below was unreachable: `.` returning non-zero is discarded under
#    `set -uo pipefail` with no `-e`, `printf` then exits 0, and a config.sh
#    with a syntax error was reported as one that "leaves AUTOFLEET_RUNNER
#    empty" -- the misattribution this comment claims to avoid, in the check
#    that makes the claim. Found by the local review.
# Every autofleet knob in the ambient environment, and nothing else. `env -i`
# was the previous attempt and took the rest of the environment with it: a host
# `.autofleet/config` that reads $USER or $TMPDIR then hits `set -u` and this
# check reports "config.sh would not source" on a repo that is fine -- and the
# remedy it prints, running the command by hand, works, so it is unreproducible
# too. Found by the self-review, on the fix for the fix.
fleet_lint_unset=()
while IFS='=' read -r fleet_lint_name _; do
  case "$fleet_lint_name" in
    AUTOFLEET_*|ORCA_*|FLEET_*) fleet_lint_unset+=(-u "$fleet_lint_name") ;;
  esac
done < <(env)
if runner="$(env ${fleet_lint_unset[@]+"${fleet_lint_unset[@]}"} bash -c '
    set -uo pipefail
    REPO_ROOT="$PWD"
    . ./scripts/fleet/config.sh || exit 1
    printf "%s" "${AUTOFLEET_RUNNER:-}"' 2>/dev/null)"; then
  if [ -z "$runner" ]; then
    fail "scripts/fleet/config.sh leaves AUTOFLEET_RUNNER empty, so lib.sh looks for scripts/fleet/runner/.sh and every command that reaches for the runtime stops"
  elif [ -f "scripts/fleet/runner/$runner.sh" ]; then
    ok "AUTOFLEET_RUNNER=$runner resolves to scripts/fleet/runner/$runner.sh"
  else
    fail "AUTOFLEET_RUNNER=$runner names no driver: scripts/fleet/runner/$runner.sh does not exist, so the dispatcher, the setup hook, the board and the autostart watcher all stop on it (4h below). Set it in .autofleet/config to one that ships, or write that file against docs/RUNNERS.md"
  fi
else
  fail "scripts/fleet/config.sh would not source, so which runner this repo is configured for cannot be established; run it by hand to see what it refused"
fi

# 4h. EVERY SCRIPT THAT REACHES FOR THE RUNTIME STOPS ON A DRIVER THAT IS NOT
#     THERE, and the ones that do not reach for it are left alone.
#
#     `lib.sh` says the driver is missing and finishes sourcing; it does not
#     `exit`, because seven scripts source it and call no `runner_*` at all --
#     the whole review and validation pipeline, which would otherwise refuse to
#     answer a review comment for want of a driver none of them uses. The price
#     of that choice is that the refusal is now the CALLER's to act on, and a
#     caller that forgets calls a function that does not exist: `command not
#     found`, rc 127, which fleet.sh's `runner_available || die` reported as
#     "the runner is not usable here" -- the consequence named as the cause.
#     That is precisely the failure armaatus/autofleet#13 exists to remove, so
#     it is asserted rather than remembered. Hard rule 3.
#
#     Comments are stripped the same way 4b and 4c strip them, and for the same
#     reason: a `runner_*` named in prose is not a call. What is asserted is the
#     ORDER, not the presence: the guard has to come before the first call, or
#     the `command not found` arrives first and splits the message in half.
if python3 - <<'PYEOF'
import re, sys, glob

# `issue-command.sh` is exempt BY NAME and for a stated reason: it prints the
# brief for an issue, which needs no runtime, and it asks `runner_available`
# only to decide whether it can additionally resolve THIS worktree's issue --
# behind `if [ -z "$ref" ] && runner_available 2>/dev/null`. With no driver that
# call is rc 127, the `&&` is false, and the script carries on doing the thing
# it was run for. Requiring a driver there would refuse an agent its own brief.
EXEMPT = {"scripts/fleet/issue-command.sh"}

def strip_comment(line):
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

lib = open("scripts/fleet/lib.sh").read()
if "fleet_require_runner()" not in lib:
    sys.exit("lib.sh no longer defines fleet_require_runner; this check now asserts nothing")
lib_code = code_only(lib)
defined_in_lib = set(re.findall(r"^(runner_[a-z_]+)\(\)", lib_code, re.M))

# A lib-defined `runner_*` counts as "not reaching for the runtime" ONLY if it
# does not itself reach, DIRECTLY OR THROUGH ANOTHER ONE. `runner_agent_terminal`
# is a filter over the DRIVER's `runner_agent_terminals`, so a script whose only
# reach is that wrapper does reach the driver, and without one gets rc 127 from
# inside lib.sh. The first version of this check called every lib-defined name
# safe -- which passed such a script unguarded and, worse, FAILED the build if
# its author added the guard anyway, arguing for the removal of a correct one.
#
# TRANSITIVE, by shrinking to a fixpoint rather than looking one level down: a
# lib `runner_a` calling a lib `runner_b` that calls the driver is a reach, and
# the one-level version called it safe. That set is empty today -- lib.sh
# defines exactly one of these and it reaches -- which is precisely why the
# arithmetic has to be right before a second one is written. Named `lib_safe`
# rather than `provided`, because check 4b above already binds `provided` in
# this file to the whole set and two spellings of one word is a reader looking
# at the wrong thing. Both found by the local review.
lib_safe = set(defined_in_lib)
while True:
    body_of = {}
    for name in lib_safe:
        m = re.search(r"^%s\(\)\s*\{(.*?)^\}" % re.escape(name), lib_code, re.M | re.S)
        body_of[name] = set(re.findall(r"\brunner_[a-z_]+", m.group(1))) if m else {"runner_unknown"}
    shrunk = {n for n in lib_safe if not (body_of[n] - lib_safe)}
    if shrunk == lib_safe:
        break
    lib_safe = shrunk

bad, guarded = [], []
for path in sorted(glob.glob("scripts/fleet/*.sh")):
    if path == "scripts/fleet/lib.sh":
        continue
    code = code_only(open(path).read())
    reaches = [m for m in re.finditer(r"\brunner_[a-z_]+", code) if m.group(0) not in lib_safe]
    if not reaches:
        # ...and the other direction: a guard in a script that needs none is a
        # refusal nobody asked for, and it is how `cost` nearly lost the one
        # property fleet.sh documents at length.
        if "fleet_require_runner" in code:
            bad.append(path + " calls fleet_require_runner and reaches for no runtime at all")
        continue
    if path in EXEMPT:
        continue
    guard = re.search(r"\bfleet_require_runner\b", code)
    if not guard:
        bad.append(path + " calls the driver and never calls fleet_require_runner")
        continue
    # PRESENT IS NOT ENOUGH. agent-autostart.sh called `runner_set_deadline` 33
    # lines before its guard, so with no driver the rc-127 `command not found`
    # landed BETWEEN lib.sh's refusal and the line that completes it -- the
    # split message this whole change exists to remove. The check said ok.
    # Found by the local review.
    if reaches[0].start() < guard.start():
        bad.append("%s calls %s at offset %d, before fleet_require_runner at %d"
                   % (path, reaches[0].group(0), reaches[0].start(), guard.start()))
        continue
    guarded.append(path)
if not guarded:
    sys.exit("no script guards its driver calls; this check now asserts nothing")
for path in sorted(EXEMPT):
    if not glob.glob(path):
        bad.append(path + " is exempted here and does not exist")
# ...and the PAGE that enumerates them names the same set. Hard rule 4 makes
# docs/RUNNERS.md the authority, and the count is restated in five places --
# that page, docs/CONFIGURATION.md, config.sh, lib.sh and this check's own
# comment -- with nothing asserting any of them. It has already gone stale once
# inside this branch: the page said "five" while this check exempted one of
# them. Only the page is checked, because it is the one a later reader is told
# to trust; the other four are prose pointing at it. Found by the local review.
doc = open("docs/RUNNERS.md").read()
para = [p for p in doc.split("\n\n") if "call `fleet_require_runner`" in p]
if len(para) != 1:
    sys.exit("docs/RUNNERS.md no longer has exactly one paragraph enumerating the "
             "guarded callers, so the count it publishes is unchecked")
named = set(re.findall(r"`([a-z-]+\.sh)`", para[0]))
want = {p.split("/")[-1] for p in guarded}
# The paragraph also names the UNGUARDED exception by design, and `lib.sh`,
# which DEFINES `fleet_require_runner` rather than calling it -- the same file
# the loop above skips for the same reason. Neither is a mismatch.
named -= {p.split("/")[-1] for p in EXEMPT} | {"lib.sh"}
if named != want:
    bad.append("docs/RUNNERS.md names {%s} as calling fleet_require_runner; the code says {%s}"
               % (", ".join(sorted(named)), ", ".join(sorted(want))))
if bad:
    sys.exit("the missing-driver refusal is not acted on where it has to be:\n  "
             + "\n  ".join(bad))
PYEOF
then
  ok "every script that reaches for the runtime stops on a driver that is not there"
else
  fail "a script calls the driver without calling fleet_require_runner (above); without a driver that call is rc 127, and the caller reports the consequence as the cause"
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
# ...and sets the three rules the gate deliberately does not check. They are
# branch protection since armaatus/autofleet#152 -- a host that installs the
# payload and never sets them has a merge gate that asks three questions and a
# repository that will merge a red build.
for rule in required_status_checks required_conversation_resolution \
            dismiss_stale_reviews; do
  grep -q "$rule" install.sh \
    || fail "install.sh does not set $rule, and merge_gate.py stopped checking it -- nothing does"
done
ok "install.sh ships the reviewer and sets the branch rules the gate leaves to GitHub"

# 7. `fleet.sh status` says how much of the post-PR loop a pull request has
#    spent. This is the one line whose whole purpose is to speak when everything
#    else is quiet: a PR at its ceiling of two reviews sits with nothing
#    happening to it, and that looks exactly like a PR nothing has started on.
if sed -n '/^cmd_status()/,/^}/p' scripts/fleet/fleet.sh | qgrep 'review:' \
   && sed -n '/^cmd_status()/,/^}/p' scripts/fleet/fleet.sh | qgrep 'AT THE CEILING'; then
  ok "fleet.sh status names the reviews spent, and says when one is at the ceiling"
else
  fail "fleet.sh status no longer says how many reviews a PR has spent, so a PR parked at the ceiling looks like one nothing has started"
fi

# 7b. EVERY MODEL CALL THE FLEET STARTS GOES THROUGH THE COMPRESSION SEAM.
#
#     `AUTOFLEET_HEADROOM` (armaatus/autofleet#89) is worth exactly what it
#     covers, and what it covers is every `scripts/fleet/*.sh` that runs an
#     agent as a direct child. Two do: review.sh and fix.sh. A third added
#     without `fleet_headroom_env` is the failure with NO
#     symptom -- the seam still works, its own tests still pass, and the number
#     docs/CONFIGURATION.md publishes quietly becomes a fraction of the truth.
#
#     HERE AND NOT IN `tests/`, which was the first version and was wrong: per
#     CLAUDE.md's Layout table `tests/` is autofleet's own suite and does not
#     ship, so a host project got the seam and not the guard on it while
#     docs/CONFIGURATION.md sold the guard as the guarantee. `evals/` ships.
#
#     PER SCRIPT, NOT PER CALL, and docs/CONFIGURATION.md says so in those
#     words: this asks whether a file that starts a model call also calls the
#     seam, not whether each individual call does. A script that gains a SECOND,
#     unwrapped call still passes. Tightening that needs a shell parser; the
#     sharp edge is named rather than papered over.
#
#     BOTH SIDES READ CODE, NOT PROSE. The first version grepped the raw file,
#     so a `$AUTOFLEET_*_CMD` in a comment made a file a call site and -- far
#     worse -- a COMMENT mentioning `fleet_headroom_env` cleared one. A guard a
#     comment satisfies has stopped guarding, which is this check's own subject.
#
#     AND IT FAILS CLOSED. `if x="$(python3 ...)"` sends a CRASHING scan to the
#     `ok` branch: an ImportError -- a host whose older installer never shipped
#     `evals/shell_code.py` is the live case -- printed nothing, exited 1, and
#     lint reported the seam as covered. The `grep -q` scan below has said
#     "could not run, so it is asserting nothing" since it was written; these
#     two now say it too. Found by the self-review.
#
#     THE CANARY IS THE OTHER HALF. A detector that matches nothing reports a
#     clean tree, so the two call sites this repository HAS are named: if the
#     scan stops finding them, the scan is broken, not the payload.
python3 "$REPO_ROOT/evals/shell_code.py" --selftest \
  || fail "evals/shell_code.py fails its own selftest, so the two scans below mean nothing"
if sites="$(python3 - <<'PYEOF'
import sys
sys.path.insert(0, "evals")
from shell_code import payload_shell, starts_a_model_call

calls, covered = {}, {}
for path, _, raw, code in payload_shell():
    calls[path] = calls.get(path, False) or starts_a_model_call(raw)
    covered[path] = covered.get(path, False) or "fleet_headroom_env" in code
for path in sorted(calls):
    if calls[path]:
        print(("site " if covered[path] else "LEAK ") + path)
PYEOF
)"; then
  clean=1
  # `fail` COUNTS AND RETURNS -- it does not exit, which is what lets this file
  # report every breach in one run. So the `ok` has to be conditional or the log
  # says both things about the same check, one line apart, and the reader has to
  # know which of the two is the verdict. Found by the self-review.
  if leaks="$(printf '%s\n' "$sites" | sed -n 's/^LEAK //p')" && [ -n "$leaks" ]; then
    clean=0
    fail "these start a model call and never go through fleet_headroom_env, so the compression knob silently covers less than docs/CONFIGURATION.md says:
$(printf '%s\n' "$leaks" | sed 's/^/    /')"
  fi
  for known in scripts/fleet/review.sh scripts/fleet/fix.sh; do
    printf '%s\n' "$sites" | qgrep -xF "site $known" && continue
    clean=0
    fail "the model-call scan no longer sees $known, so it is asserting nothing about the compression seam"
  done
  [ "$clean" = 1 ] \
    && ok "every fleet script that starts a model call goes through the compression seam"
else
  fail "the model-call scan could not run, so it is asserting nothing"
fi

# 7c. ...AND THE SEAM STAYS GENERIC. The knob is NAMED for headroom because a
#     dependency is named rather than hidden -- but nothing in the payload may
#     reach for it. No `command -v headroom`, no version probe, no config file
#     of theirs: the mechanism is two environment variables and a TCP connect,
#     so any Anthropic-compatible compressing proxy satisfies it.
#
#     docs/CONFIGURATION.md states that as a guarantee, and hard rule 3's
#     temperament is that a rule with no assertion is not shipped -- the same
#     reasoning that makes 4c RUN the Orca grep instead of quoting it. So this
#     runs it.
#
#     WHAT IS ALLOWED is every identifier the fleet itself owns, plus the
#     literal `headroom:` -- the label on `fleet.sh status`'s row, which is the
#     "named rather than hidden" half of the rule in the one place a person
#     reads. A command word is never followed by a colon, so admitting it costs
#     the check nothing. This differs from 4c on purpose: hard rule 4 forbids
#     NAMING Orca in a message because the driver is meant to be invisible;
#     here naming the vendor IS the rule, and only reaching for it is the leak.
if leaks="$(python3 - <<'PYEOF'
import re, sys
sys.path.insert(0, "evals")
from shell_code import payload_shell

OWNED = re.compile(r"(AUTOFLEET_HEADROOM(_URL)?|_?fleet_headroom_[a-z_]*|headroom:)")

for path, n, raw, code in payload_shell():
    if "headroom" in OWNED.sub("", code).lower():
        print(f"    {path}:{n}: {raw.strip()}")
PYEOF
)"; then
  if [ -n "$leaks" ]; then
    fail "the compression seam is no longer generic -- these reach for headroom itself, which docs/CONFIGURATION.md promises the payload does not:
$leaks"
  else
    ok "the compression seam names headroom and reaches for nothing of theirs"
  fi
else
  fail "the headroom-leak scan could not run, so it is asserting nothing"
fi

# 8 AND 9 WENT WITH THE MODE THEY GUARDED.
#
# Two checks lived here. One drove `merge_gate.review_mode()` and
# `fleet_review_mode()` against the same spellings, because a gate and a
# dispatcher that disagree about which reviewer is running block every pull
# request between them. The other held `install.sh`'s normalisation of
# `AUTOFLEET_REVIEW_MODE=local` at least as wide as the gate's reader, so a
# seeded host config could not hand a project the weaker independence guarantee
# by accident.
#
# There is one venue now (armaatus/autofleet#152): the dispatcher. The knob, the
# workflow it chose between and both readers of it are gone, and a check with
# nothing to compare is worse than no check -- it is a green line about a
# property that no longer exists. The note stays so the next person to wonder
# where the parity assertion went does not write a third one.

echo "== the flow's own scripts"
# The brief names these by path. A rename that misses the brief turns into an
# agent halfway through a task running a command that does not exist.
for script in fleet.sh stop.sh issue-command.sh await-review.sh \
              after-pr.sh review.sh fix.sh; do
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

# ...and stderr silenced BEFORE the redirection that can fail, not after it.
#
# Same scan, same tree, one statement later in the pipeline of things that read
# as harmless. `read -r h n <"$m.tries" 2>/dev/null` prints the open failure and
# then silences the stream, so a dispatcher poll left a shell error in fleet.log
# on the first look at every new head (armaatus/autofleet#87) -- and the line was
# re-typed until there were seventeen of it. Its own selftest first, for the
# reason the scan above gives.
python3 "$REPO_ROOT/evals/late_stderr_silence.py" --selftest \
  || fail "evals/late_stderr_silence.py fails its own selftest, so the scan below means nothing"
if bad="$(python3 "$REPO_ROOT/evals/late_stderr_silence.py")"; then
  if [ -n "$bad" ]; then
    fail "these silence stderr after the redirection that fails, so the diagnostic prints anyway -- put the \`2>/dev/null\` before the \`<\`: $bad"
  else
    ok "no payload script silences stderr after the open that would fail"
  fi
else
  fail "the late-stderr scan could not run, so it is asserting nothing"
fi

# ...and no comment sits between a `\` and the line it continues.
#
# The third scan of the same tree, and the one with the worst failure mode: the
# shell joins the comment onto the command, which comments out the rest of it,
# and the continued line runs as a command of its own. `bash -n` passes.
# `scripts/fleet/review-status.sh` carried one from armaatus/autofleet#121 and
# answered every invocation with 97 KB of unfiltered JSON and exit 2 -- "could
# not read" -- at the step of the brief where an agent learns whether its review
# threads are resolved. Its own selftest first, for the reason the scans above
# give.
python3 "$REPO_ROOT/evals/continuation_comment.py" --selftest \
  || fail "evals/continuation_comment.py fails its own selftest, so the scan below means nothing"
if bad="$(python3 "$REPO_ROOT/evals/continuation_comment.py")"; then
  if [ -n "$bad" ]; then
    fail "these put a comment between a \\ and the line it continues, so the shell swallows the rest of the command -- move the comment above it: $bad"
  else
    ok "no payload script comments out the line it is continuing"
  fi
else
  fail "the continuation-comment scan could not run, so it is asserting nothing"
fi

# ...and the brief must still name them.
#
# The risk is an instruction that falls out of the brief entirely, which is a
# rule nobody enforces: armaatus/rommsync-nx#90's PR that nobody queued for
# auto-merge, armaatus/rommsync-nx#88 and #89 sitting blocked on one unresolved
# thread.
#
# THERE IS ONE STAGE. There were two -- the bare form printed the spec, steps
# 1-3 and a pointer, `--after-pr` printed steps 4-6 -- and this check was
# asserted PER STAGE rather than over the union, because the union passed for
# the wrong reason: stage 1 said "Two subagents in `.claude/agents/`", so a
# union grep for `.claude/` matched forever and deleting it from stage 2 still
# printed ok. armaatus/autofleet#152 deleted stage 2 instead: the agent's job
# ends at an open pull request, and everything that half described is the
# dispatcher's. What is left to assert is one text, and the NEGATIVE list is
# what keeps the second stage from growing back inside the first.
brief="$(sed -n "/^sed .*BRIEF/,/^BRIEF$/p" scripts/fleet/issue-command.sh)"
# The text begins at the `---` rule the brief opens with and ends at the
# terminator; between them is exactly what the agent receives. Anchored on the
# TEXT rather than on the shape of the command that prints it: keyed to `| awk `
# this went blind the moment that command grew a second line, and counted awk's
# own source as part of the brief.
stage1="$(sed -n '/^---$/,$p' <<<"$brief" | sed '$d')"
if [ -z "$stage1" ]; then
  fail "issue-command.sh's brief heredoc could not be read, so everything below asserts nothing"
else
  brief_fails_before=$fails
  # What is due before the agent stops: the build, the pull request body the
  # gate reads, the subagent that keeps a wide search off the bill, and the
  # STOP file.
  for named in "/implement" "Closes #" researcher "gh pr diff --stat" \
                "Commit as you go" ".autofleet/STOP" \
                ".github/workflows/" ".github/scripts/" ".claude/"; do
    grep -qF -- "$named" <<<"$stage1" \
      || fail "the brief no longer names $named, which the agent needs before it stops"
  done
  # ...and none of what the dispatcher owns. Every one of these was in the
  # deleted second stage, and every one of them is now a thing the agent is
  # refused by `guard.py` -- a brief that asked for it would send an agent to
  # spend its budget being told no.
  #
  # `--after-pr` is in this list and that is the point: the flag is an ERROR
  # now, so a brief that still pointed at it would be pointing at a refusal.
  for named in --after-pr await-review.sh review.sh fix.sh after-pr.sh \
                "--auto --squash" "gh pr merge"; do
    grep -qF -- "$named" <<<"$stage1" \
      && fail "the brief carries $named, which is the dispatcher's; the agent's job ends at the open pull request"
  done
  # Guarded on the counter: `ok` after a loop that may have called `fail` prints
  # a green line for an assertion that just failed, two lines above it.
  [ "$fails" = "$brief_fails_before" ] \
    && ok "the brief names what is due before the agent stops, and nothing that is not"

  # The `brief` row, in the vendored check and not only in autofleet's own
  # suite: a host project gets the brief and the reason it is short, so it
  # should get the thing that stops it growing back. tests/test_brief.sh
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
  # `install.sh` overwrites. That is hard rule 1.
  #
  # No figure is written here. One was, twice -- `391`, then `386` -- and each
  # went stale at the next commit to the brief. The line below prints what it
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
if [ -n "$stage1" ]; then
  reading_ceiling="$(ceiling reading)" || exit 2
  # WHAT AUTOFLEET DOES NOT WRITE, AND THE AGENT STILL READS. Stage 1 injects
  # the issue body, which is in the context before the first edit and was not in
  # this sum. The number said 3,402 while a real run on a 468-word issue read
  # 3,870, which is a ceiling measuring the part of the load that happens to be
  # ours. Charged as an allowance rather than as a measurement because its text
  # is not in the tree: what the payload gets is whatever is left.
  #
  # A SECOND ALLOWANCE LIVED HERE, for the handoff note stage 1 used to print
  # ahead of the brief. It went with the note (armaatus/autofleet#151): a second
  # `claude -p` reads the branch and the pull request, not a note, so there is
  # no longer a text of ours injected before the first edit.
  spec_allowance="$(ceiling spec)" || exit 2
  reading_what="$(ceiling_what reading)" || exit 2
  reading_issue="$(ceiling_issue reading)" || exit 2
  if stage1="$stage1" rendered="$rendered" \
     reading_ceiling="$reading_ceiling" reading_what="$reading_what" \
     spec_allowance="$spec_allowance" \
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
    "REVIEW.md": read("REVIEW.md"),
    "the brief": os.environ["stage1"],
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
#   the review runs once  REVIEW.md's, not the brief's, and that moved with
#                       armaatus/autofleet#152. The agent's job ends at the open
#                       pull request, so how many reviews follow is no longer
#                       something it acts on -- it is the policy the reviewer
#                       reads. A brief that restated it would be spending the
#                       reading ceiling on a fact nobody in that context uses.
RULES = [
    ("the review runs once, and one fix answers it", "REVIEW.md",
     lambda t: re.search(r"[Tt]wo reviews\s+maximum", t) is not None),
    ("a Suggestion blocks nothing", "REVIEW.md",
     lambda t: "blocks nothing" in t),
    ("the paths only a person may merge", "the brief", triple),
    ("the STOP file", "the brief",
     lambda t: ".autofleet/STOP" in t),
    # `Closes #N` AND NOTHING ELSE, which is what the gate reads from the body
    # since armaatus/autofleet#152. This tuple used to require the two
    # self-review pass names beside it, because `merge_gate.LOCAL_PASSES`
    # grepped the body for both -- and keyed on `Closes #` alone it printed ok
    # while the brief had dropped one of them. The passes are gone and the gate
    # reads a verdict rather than prose, so the closing line is the whole rule.
    ("`Closes #N`, which is what merge-gate reads from the body", "the brief",
     lambda t: "Closes #" in t),
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
    "REVIEW.md":                    ("map",   "the policy the REVIEW applies, in its own context: review.sh inlines it into the reviewer's prompt. It was a `count` row while a self-review ran inside the agent's session, and charging it after that moved out made the ceiling bound 1,352 words nothing in that context holds. The brief naming it is still a failure, by the `map` rule below -- that is what stops it moving back"),
    "docs/WORKFLOW.md":             ("map",   "the maintainer's explanation, and the reference an agent consults when it needs one; not per-issue reading"),
    "docs/CONFIGURATION.md":        ("map",   "read when wiring a host project"),
    "docs/RUNNERS.md":              ("map",   "read when touching the runner seam (hard rule 4)"),
    "README.md":                    ("map",   "read when deciding whether to install it, not before editing"),
    "AGENTS.md":                    ("map",   "a symlink to CLAUDE.md; counting it would count it twice"),
    ".claude/agents/researcher.md": ("map",   "read by the subagent, in the subagent's own context"),
    ".claude/agents/reviewer.md":   ("map",   "inlined by review.sh into the reviewer's own prompt, not read here"),
    ".autofleet/run/self-review.md": ("written", "retired with the self-review passes (armaatus/autofleet#152); the row stays so a brief that names it fails as a pointer to a file nothing writes rather than as an unknown path"),
    ".autofleet/review.md":         ("map",   "the host project's own correctness rules; read by the reviewer, in its own context"),
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
# ONE STAGE to scan, and every word of it is in the ceiling below. This used to
# scan both halves of a split brief though only the first half's words were
# charged -- a `docs/WORKFLOW.md` added to the second tripped nothing, which is
# the regression armaatus/autofleet#54 is about, one stage over.
scanned = [("the brief", texts["the brief"], ("count", "written"))]
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

# The ordering check this replaced asked only that the brief name REVIEW.md
# AFTER `/code-review`, so it was read at the step rather than in the preamble.
# There is no step in this context that reads it at all: `review.sh` inlines the
# policy into the process it starts. So the brief may not name it in either
# position, which the `map` rule above already enforces -- and unlike the
# ordering test, it also charges the words back if someone puts it there anyway.

# The reading ceiling is the acceptance of armaatus/autofleet#54: CLAUDE.md, the
# OPENING brief, and anything either names as required reading, before the first
# edit. Its number is the `reading` row of the ceilings table at the top of this
# file.
#
# THE WHOLE BRIEF IS IN THE SUM, which it was not when the brief had two
# stages: the second was fetched after the PR existed, so its ~1,100 words were
# outside a ceiling whose name is "before its first edit". That half is deleted
# rather than exempt now (armaatus/autofleet#152), so the exemption goes with it.
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
parts.append(("the brief", len(os.environ["rendered"].split())))
# The one the tree does not hold. An allowance, not a measurement: a host
# project's issues are not autofleet's to bound. What this does is stop the
# payload spending its room.
parts.append(("the issue spec (allowance)", int(os.environ["spec_allowance"])))
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

# THE TWO REVIEW VENUES WENT WITH THE MODE.
#
# Two checks lived here, and both were about the same hazard: `local` mode ran
# the reviewer and the validator on the dispatcher, `github` mode ran the same
# briefs in `claude-review.yml` and `validate.yml`, and any difference between
# the two made the knob decide what a review DOES rather than only where it
# runs. One held their tool grants equal -- the workflows once granted no
# `Skill`, so the reviewer was ordered to run a fan-out pass it had no tool for
# and nothing in the log said so. The other held each workflow to standing down
# when the base ref said `local`, because two venues running meant two agents
# and two bills per pull request.
#
# There is one venue now (armaatus/autofleet#152) and both workflows are gone.
# A host that wants the review inside Actions writes one around
# `anthropics/claude-code-action` directly -- which is a thing to choose, and
# the thing these two checks existed to stop autofleet choosing on its behalf.

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

# ONE QUERY, IN ONE FILE. The readers used to carry their own copies, and so
# their own copy of the bug in them: `reviewThreads(first:100)` is the FIRST
# hundred, and past that a pull request silently lost its newest threads while
# the gate reported "no review thread is unresolved" from a page it knew was
# partial (#114). Thread resolution is branch protection now and the query no
# longer pages anything -- but what made the copies drift was that there WERE
# copies, so the rule survives its original reason.
if [ -x .github/scripts/pr_payload.sh ]; then
  bash -n .github/scripts/pr_payload.sh || fail ".github/scripts/pr_payload.sh does not parse"
  # FOUR readers. `fix.sh` joined them for the review body it answers, and
  # `await-review.sh` is the one most able to drift because it asks a question
  # the gate does not -- "has ANYONE judged this head", which includes a refusal.
  # Unlisted, either could grow a query of its own tomorrow and this would stay
  # green, which is #114 exactly.
  for reader in .github/workflows/merge-gate.yml scripts/fleet/review.sh \
                scripts/fleet/fix.sh scripts/fleet/await-review.sh; do
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

  ok "the gate, the review, the fix and the wait read one payload"
else
  fail ".github/scripts/pr_payload.sh is missing or not executable"
fi

# THE PROTECTED SET HAS ONE IMPLEMENTATION, and after armaatus/autofleet#152 it
# has one reader too. `review-status.sh` asked `merge_gate.human_only()` so that
# a local answer about which paths a person merges could not drift from the
# gate's -- the drift cost three wasted review rounds in #96. That script is
# gone with the post-PR protocol it served, so the assertion here is the
# narrower one that survives: the gate still exposes the question as a FUNCTION
# rather than as two constants a future reader would test itself.
if grep -q '^def human_only(' .github/scripts/merge_gate.py \
   && grep -q 'HUMAN_ONLY_FILES' .github/scripts/merge_gate.py; then
  ok "merge_gate exposes human_only(), so a second reader cannot test the prefixes alone"
else
  fail "merge_gate.py no longer answers which paths a person merges through one function; a reader testing the prefixes alone misses .autofleet/guard.json"
fi

# ...and the guard's project half is LOADED, not merely declared. `guard.py`
# reads every key with `PROJECT.get(...)`, so a `.autofleet/guard.json` key with
# a typo in it is not an error: it is silently no rule at all, and
# `guard.py --selftest` asserts against its own SELFTEST_PROJECT fixture rather
# than this file, so nothing else in the tree notices. Hard rule 3. The read keys
# are derived from guard.py rather than listed here -- a list would be the second
# copy this check exists to make unnecessary.
guard_probe="$(mktemp -d)"
printf '{}\n' >"$guard_probe/empty.json"
guard_drift="$(AUTOFLEET_GUARD_PROBE="$guard_probe/empty.json" python3 -c '
import importlib.util, json, os, re, sys
source = open(".claude/hooks/guard.py").read()
# BOTH spellings. `--selftest` reloads the same four keys by subscript
# (PROJECT["secret_tails"]), so a regex matching only `.get("...")` would report
# a key added to that path alone as one guard.py never reads -- a false positive
# is the worst failure a pin like this has, because the fix is to delete it.
read = set(re.findall(r"PROJECT(?:\.get)?\(?\[?\"([A-Za-z_]+)\"", source))
# The same file guard.py would read, override and all. Anything else compares a
# file the host declared against rules loaded from a different one.
path = os.environ.get("AUTOFLEET_GUARD_CONFIG",
                      os.path.join(".autofleet", "guard.json"))
# Read HERE rather than through guard.py, so a malformed file is reported as
# what it is. Left to the import below it would be an uncaught ValueError, exit
# 1 -- the code that means "drift" -- with nothing on stdout to say otherwise.
try:
    declared = json.load(open(path)) if os.path.exists(path) else {}
except (OSError, ValueError) as exc:
    print("cannot be read at all: %s" % exc)
    sys.exit(2)
# A leading underscore is the comment convention the shipped example uses.
unread = sorted(k for k in declared if not k.startswith("_") and k not in read)
if unread:
    print("keys guard.py never reads: %s" % ", ".join(unread))
    sys.exit(1)


def counts(config):
    """What guard.py ends up enforcing when it reads `config`."""
    os.environ["AUTOFLEET_GUARD_CONFIG"] = config
    spec = importlib.util.spec_from_file_location("g", ".claude/hooks/guard.py")
    g = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(g)
    return {"protected_paths": len(g.PROTECTED_PATHS),
            "secret_suffixes": len(g.SECRET_SUFFIXES),
            "secret_contains": len(g.SECRET_CONTAINS),
            "secret_tails": len(g.SECRET_TAILS)}


# MEASURED, not hardcoded. guard.py adds universal entries of its own to some of
# these tuples -- `("/.env", ".env")` today -- and subtracting a literal 2 would
# turn this check red in every host repo the day a third one is added, naming a
# `.autofleet/guard.json` nobody touched. The baseline is the same guard.py
# loading an EMPTY config, which is what "over and above its universal rules"
# means.
base = counts(os.environ["AUTOFLEET_GUARD_PROBE"])
loaded = counts(path)
short = ["%s: declared %d, loaded %d" % (k, len(declared.get(k, [])),
                                         loaded[k] - base[k])
         for k in loaded if len(declared.get(k, [])) != loaded[k] - base[k]]
if short:
    print("; ".join(short))
    sys.exit(1)
')"; guard_rc=$?
rm -rf "$guard_probe"
# EXIT 1 IS THE VERDICT; anything else is the probe itself dying. A malformed
# guard.json makes guard.py `sys.exit(2)` at import, and an entry missing `path`
# raises KeyError -- both with nothing on stdout, so the old spelling printed
# `does not enforce ()`: no reason, in exactly the case this check is nearest to.
if [ "$guard_rc" = 0 ]; then
  ok "every rule .autofleet/guard.json declares is a rule guard.py loads"
elif [ "$guard_rc" = 1 ]; then
  fail ".autofleet/guard.json declares rules guard.py does not enforce ($guard_drift)"
else
  fail "could not read .autofleet/guard.json through guard.py (exit $guard_rc); guard.py refuses a malformed config at import, and its reason is on stderr above"
fi

# The prose copies of the set, pinned to the code. This change hand-edited four
# at once, and the new entry that arrives after it will not know where they are.
#
# THE MAINTAINER PAGES, NOT THE BRIEF. The brief cannot carry this list: the
# rule-of-one-home check above reads every `*.md` it names as a document the
# agent is being SENT to, and `.autofleet/review.md` is the reviewer's reading,
# not the author's -- naming it there costs 536 words of a 3,500-word ceiling to
# say "a person merges this". So the brief describes the seam and these two
# pages carry the list.
for protected_file in $(python3 -c '
import importlib.util
spec = importlib.util.spec_from_file_location("mg", ".github/scripts/merge_gate.py")
mg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mg)
print(" ".join(mg.HUMAN_ONLY_FILES))
'); do
  for page in docs/CONFIGURATION.md docs/WORKFLOW.md; do
    qgrep -F "$protected_file" "$page" \
      || fail "$protected_file is human-merge-only and $page does not say so; the maintainer reading that page is the person who has to do the merging"
  done
done
# ...and the brief still has to SEND the agent at the seam, even without the
# list. Without this, the paragraph above could lose its `.autofleet/` sentence
# and every check here stays green.
grep -vE '^[[:space:]]*#' scripts/fleet/issue-command.sh \
  | qgrep -F 'the files in `.autofleet/` that set the rules' \
  || fail "the brief no longer tells an agent that .autofleet/'s rule files never merge themselves; it spends its review rounds on a gate that will never go green"
ok "the pages a maintainer reads name every file merge_gate refuses to merge by itself"

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
