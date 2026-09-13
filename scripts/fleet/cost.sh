#!/usr/bin/env bash
# What a worktree run cost, per issue.
#
#   ./scripts/fleet/fleet.sh cost           every issue the fleet has run
#   ./scripts/fleet/fleet.sh cost 48 52     just those
#   ./scripts/fleet/fleet.sh cost --json    the same figures, for a machine
#
# Nothing recorded what an agent spent on an issue, so every judgement about
# context -- is the brief too long, is a review pass in the wrong process, did a
# rebase round cost more than the implementation -- was a guess. The agent CLI
# already writes the answer: one JSONL per session under
# `$AUTOFLEET_TRANSCRIPT_DIR/<cwd-slug>/<session-id>.jsonl`, with a `usage` block
# on every assistant message. The worktree PATH is the whole of the tie between a
# session and an issue, and the fleet knows that path for every issue it started.
#
# THE FOUR NUMBERS ARE NOT INTERCHANGEABLE AND ARE NEVER ADDED TOGETHER. A cache
# read is roughly a tenth of an input token, so a run that looks expensive on
# `input` may be almost entirely cache, and one total would hide exactly the
# difference this report exists to show.
#
# IT NEVER FAILS A RUN. No transcript root, a root that is not there, a worktree
# already reaped, a half-written line at the end of a transcript a live agent is
# still appending to -- each is normal, costs one line on stderr, and exits 0.
# `cost` is a reporting command; a reporting command that can go non-zero is one
# more thing a night's run can die of.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
. ./scripts/fleet/lib.sh

# Where `own()` records the worktree path of every issue the fleet has started,
# and -- unlike $FLEET_OWNED -- does NOT forget it when the worktree is released.
# That asymmetry is the point: the owned registry answers "what is running", and
# this answers "what has run", which is the question a cost report is.
RAN_DIR="$FLEET_DIR/ran"

json=false
issues=()
while [ $# -gt 0 ]; do
  case "$1" in
    --json) json=true; shift ;;
    -h|--help)
      cat >&2 <<'USAGE'
usage: cost.sh [--json] [<issue> ...]

  What each issue's worktree spent, from the agent CLI's own session
  transcripts: input, output, cache-read and cache-write tokens, and how many
  sessions ran there. The four are printed separately and never summed.

  With no issues, every issue the fleet has a recorded worktree path for.
USAGE
      exit 2 ;;
    -*) printf 'cost.sh: unknown option %s\n' "$1" >&2; exit 2 ;;
    *)
      case "$1" in
        ''|*[!0-9]*) printf 'cost.sh: not an issue number: %s\n' "$1" >&2; exit 2 ;;
      esac
      issues+=("$1"); shift ;;
  esac
done

# `issue<TAB>path`, the owned registry FIRST so a worktree that is live now wins
# over the path recorded when it started -- they agree today, and if they ever
# stop agreeing the live one is the one with transcripts still arriving in it.
# Duplicates are dropped downstream, first seen wins.
worktree_paths() {
  local dir f n p
  for dir in "$FLEET_OWNED" "$RAN_DIR"; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*; do
      [ -f "$f" ] || continue
      n="${f##*/}"
      # Only ever issue numbers. Both directories are the fleet's own, but a
      # stray `.DS_Store` in one of them should be ignored rather than reported
      # as an issue with no transcripts.
      case "$n" in ''|*[!0-9]*) continue ;; esac
      p="$(cat "$f" 2>/dev/null)" || continue
      [ -n "$p" ] || continue
      printf '%s\t%s\n' "$n" "$p"
    done
  done
}

# Everything below is one python pass: it has to read JSONL, de-duplicate by
# message id and format two output shapes, and splitting that across a pipeline
# of shell tools is how the table and the --json would come to disagree.
#
# Arguments rather than environment for the two user-supplied strings, because
# `$AUTOFLEET_TRANSCRIPT_DIR` is a path a host project writes and the issue
# filter comes from the command line.
FLEET_COST_JSON=0; $json && FLEET_COST_JSON=1
export FLEET_COST_JSON
worktree_paths | python3 -c '
import json, os, sys

root = sys.argv[1]
want = set(sys.argv[2:])
as_json = os.environ.get("FLEET_COST_JSON") == "1"

# The four, in the order the report prints them, paired with the key each one
# has in the CLI transcript. One list, because the table header, the JSON keys
# and the summing all walk it -- three hand-written copies of four field names
# is three chances for the column labelled "cache read" to be showing something
# else.
FIELDS = [
    ("input",       "input_tokens"),
    ("output",      "output_tokens"),
    ("cache read",  "cache_read_input_tokens"),
    ("cache write", "cache_creation_input_tokens"),
]

def note(line):
    # stderr, in BOTH shapes. An explanation on stdout is a line every --json
    # consumer has to strip, and the whole point of --json is that these numbers
    # get compared across runs by something that is not a person.
    print(line, file=sys.stderr)

def slug(path):
    # The CLI names a transcript directory after the absolute working directory
    # with every "/" and "." replaced by "-". Not a hash and not reversible:
    # "/a/b.c" and "/a-b-c" collide, which is a property of the CLI rather than
    # of this script, and the direction we need (path -> directory) is exact.
    return path.replace("/", "-").replace(".", "-")

pairs = []
seen_issues = set()
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    issue, _, path = line.partition("\t")
    if want and issue not in want:
        continue
    if issue in seen_issues:
        continue
    seen_issues.add(issue)
    pairs.append((issue, path))
pairs.sort(key=lambda p: int(p[0]))

# One line, and then NO TABLE. A table of zeros is the wrong answer here: every
# row would say this issue cost nothing, which is a measurement, and nothing was
# measured. --json still gets its structure, because a consumer that has to
# distinguish "no data" from "a parse error" needs the shape either way.
usable = True
if not root:
    note("no transcript root is configured (AUTOFLEET_TRANSCRIPT_DIR is empty),"
         " so there is nothing to measure")
    usable = False
elif not os.path.isdir(root):
    note("no transcripts on this machine: %s is not there" % root)
    usable = False

unreadable = 0

def measure(path):
    """(sessions, {field: tokens}) for one worktree path."""
    global unreadable
    sums = {key: 0 for _, key in FIELDS}
    sessions = 0
    directory = os.path.join(root, slug(path)) if root else ""
    if not directory or not os.path.isdir(directory):
        return 0, sums
    for name in sorted(os.listdir(directory)):
        if not name.endswith(".jsonl"):
            continue
        # ONE `seen` PER FILE, and de-duplication is not optional. The CLI writes
        # one entry per content block of an assistant message, each carrying the
        # SAME `message.usage` -- 26 entries for 15 messages in the transcript
        # this was written against. Summing the entries reports roughly twice
        # what the run cost, which is worse than reporting nothing, because it
        # looks like an answer.
        seen = set()
        counted = False
        try:
            handle = open(os.path.join(directory, name), encoding="utf-8")
        except OSError:
            unreadable += 1
            continue
        with handle:
            for raw in handle:
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    entry = json.loads(raw)
                except ValueError:
                    # A live agent is appending to its own transcript while this
                    # runs, so the last line can be half a record. Skip it.
                    unreadable += 1
                    continue
                if not isinstance(entry, dict) or entry.get("type") != "assistant":
                    continue
                message = entry.get("message")
                if not isinstance(message, dict):
                    continue
                usage = message.get("usage")
                # An entry with no usage is normal -- an interrupted turn, an
                # older transcript format -- and is skipped, not fatal.
                if not isinstance(usage, dict):
                    continue
                marker = message.get("id")
                if marker is not None:
                    if marker in seen:
                        continue
                    seen.add(marker)
                for _, key in FIELDS:
                    value = usage.get(key)
                    if isinstance(value, int) and not isinstance(value, bool):
                        sums[key] += value
                counted = True
        # A file that carried no usage at all is not a session that cost
        # anything, so it does not inflate the count.
        if counted:
            sessions += 1
    return sessions, sums

rows = []
silent = []
for issue, path in (pairs if usable else []):
    sessions, sums = measure(path)
    if sessions == 0:
        silent.append(issue)
    rows.append({"issue": issue, "worktree": path, "sessions": sessions,
                 **{key: sums[key] for _, key in FIELDS}})

total = {"sessions": sum(r["sessions"] for r in rows)}
for _, key in FIELDS:
    total[key] = sum(r[key] for r in rows)

if usable and silent:
    # One line, naming them: a row of zeros would be indistinguishable from a
    # worktree that genuinely spent nothing, and the reason is worth saying once.
    note("no transcripts under %s for #%s -- reaped, or run before the fleet"
         " recorded its worktree path" % (root, ", #".join(silent)))
if unreadable:
    note("%d transcript line(s) could not be read and were skipped" % unreadable)
if usable and not rows:
    note("the fleet has no recorded worktree path for anything to measure yet")

if as_json:
    json.dump({"transcript_dir": root, "issues": rows, "total": total},
              sys.stdout, indent=2)
    sys.stdout.write("\n")
    raise SystemExit(0)

if not usable:
    raise SystemExit(0)

headers = ["issue", "sessions"] + [label for label, _ in FIELDS]
keys = ["issue", "sessions"] + [key for _, key in FIELDS]

def cell(row, key):
    value = row[key]
    # Thousands separators, because the comparison this report exists for is
    # between numbers six and seven digits long and the eye cannot do that
    # unaided. `--json` is what a machine reads.
    return format(value, ",") if isinstance(value, int) else str(value)

body = [[cell(r, k) for k in keys] for r in rows]
body.append(["total", format(total["sessions"], ",")]
            + [format(total[key], ",") for _, key in FIELDS])
widths = [max(len(h), *(len(r[i]) for r in body)) if body else len(h)
          for i, h in enumerate(headers)]
print("  ".join(h.rjust(w) for h, w in zip(headers, widths)))
for i, r in enumerate(body):
    if i == len(body) - 1 and rows:
        # A rule above the total, so the row that is not an issue does not read
        # as one.
        print("  ".join("-" * w for w in widths))
    print("  ".join(c.rjust(w) for c, w in zip(r, widths)))
' "${AUTOFLEET_TRANSCRIPT_DIR:-}" "${issues[@]+"${issues[@]}"}"
