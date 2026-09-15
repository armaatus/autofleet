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
# THIS HEADER IS THE AUTHORITY on how the report reads a transcript -- the entry
# shape, the slug rule, the de-duplication. `config.sh` and
# `docs/CONFIGURATION.md` describe the same things for a host project setting the
# knob, and when they disagree with this file they are the ones that are wrong.
# They have been once already, which is why this sentence is here.
#
# THE FOUR NUMBERS ARE NOT INTERCHANGEABLE AND ARE NEVER ADDED TOGETHER. A cache
# read is roughly a tenth of an input token, so a run that looks expensive on
# `input` may be almost entirely cache, and one total would hide exactly the
# difference this report exists to show.
#
# IT NEVER FAILS A RUN. No transcript root, a root that is not there, a worktree
# already reaped, an entry with no `usage`, a half-written line at the end of a
# transcript a live agent is still appending to -- each is normal, costs one line
# on stderr, and exits 0. `cost` is a reporting command; a reporting command that
# can go non-zero is one more thing a night's run can die of.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
. ./scripts/fleet/lib.sh

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
      # One leading `#` allowed: every line this report prints spells an issue as
      # `#48`, so the form the output teaches was the form the parser refused.
      # Found by the independent review.
      n="${1#\#}"
      case "$n" in
        ''|*[!0-9]*) printf 'cost.sh: not an issue number: %s\n' "$1" >&2; exit 2 ;;
      esac
      issues+=("$n"); shift ;;
  esac
done

# `issue<TAB>path`, one line per worktree an issue has had. Both registries, and
# EVERY LINE of each file: $FLEET_RAN accumulates paths rather than replacing
# them, because `fleet.sh retry 44` opens a second worktree for the same issue
# and "did the abandoned attempt cost more than the one that landed" is one of
# the questions this report exists to answer. Duplicates are dropped downstream.
worktree_paths() {
  local dir f n line
  # BOTH, and the reason is the upgrade, not the wording. `own()` writes the two
  # in the same breath and is the only writer, so on a fleet that has launched
  # anything since this shipped every $FLEET_OWNED path is already in $FLEET_RAN
  # and the first pass finds nothing new. What it is for is the worktree that was
  # owned BEFORE this change existed: it has an $FLEET_OWNED entry and no ran/
  # one, and dropping this loop would lose the live run somebody is most likely
  # to be asking about. Both come from lib.sh. Found by the independent review,
  # which pointed out the comment here argued for reading one of them.
  for dir in "$FLEET_OWNED" "$FLEET_RAN"; do
    [ -d "$dir" ] || continue
    for f in "$dir"/*; do
      [ -f "$f" ] || continue
      n="${f##*/}"
      # Only ever issue numbers. Both directories are the fleet's own, but a
      # stray `.DS_Store` in one of them should be ignored rather than reported
      # as an issue with no transcripts.
      case "$n" in ''|*[!0-9]*) continue ;; esac
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf '%s\t%s\n' "$n" "$line"
      done <"$f"
    done
  done
}

# Everything below is one python pass: it has to read JSONL, de-duplicate by
# message id and format two output shapes, and splitting that across a pipeline
# of shell tools is how the table and the --json would come to disagree.
#
# Arguments rather than environment, all of them: `$AUTOFLEET_TRANSCRIPT_DIR` is
# a path a host project writes, and the shape and the filter come from the
# command line. An exported variable beside an argument list is a second way in
# for no reason.
shape=table; $json && shape=json
worktree_paths | python3 -c '
import json, os, re, sys

root = sys.argv[1]
as_json = sys.argv[2] == "json"
want = set(sys.argv[3:])

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

# The CLI truncates a slug at this length and appends a hash of the path. That
# hash is not reproducible here, so a slug this long is matched by PREFIX
# instead -- see directories_for().
SLUG_MAX = 200

# Worktree paths whose slug prefix matched more than one directory. They have a
# stated reason for showing zeros, so they must not ALSO be told they have no
# transcripts and were probably reaped -- that line states a CAUSE, and it would
# be stating a false one over the top of the true one printed moments earlier.
# The same trap round two of the review found on the subagent path.
ambiguous = set()

def note(line):
    # stderr, in BOTH shapes. An explanation on stdout is a line every --json
    # consumer has to strip, and the whole point of --json is that these numbers
    # get compared across runs by something that is not a person.
    print(line, file=sys.stderr)

def slug(path):
    # EVERY non-alphanumeric, not just "/" and "."; that is the CLI rule, and
    # the narrower one was silently wrong rather than noisily wrong. A worktree
    # under a directory with an underscore or a space -- `my_project`, an
    # ordinary thing -- lands in a directory the narrow rule never looks in, and
    # every issue is then reported as "no transcripts: reaped", which is a
    # confident and incorrect explanation. Neither rule differs on any of the 85
    # project directories on the machine this was written on, which is exactly
    # why it had to be checked against the CLI rather than against a sample.
    return re.sub(r"[^A-Za-z0-9]", "-", path)

def directories_for(path):
    """The transcript directory (or directories) for one worktree path."""
    if not root:
        return []
    name = slug(path)
    exact = os.path.join(root, name)
    if os.path.isdir(exact):
        return [exact]
    if len(name) <= SLUG_MAX:
        return []
    # Over the cap the CLI keeps the first SLUG_MAX characters and appends "-"
    # plus a hash of the path, and the prefix is what identifies it here.
    #
    # EXACTLY ONE MATCH, OR NONE. The comment here used to argue that 200
    # characters of absolute path made a collision implausible; it is not, and a
    # comment asserting a false invariant is what stops the next reader looking.
    # Two worktrees agree that far whenever the ROOT they sit under is itself
    # longer than 200 characters -- `slug(path)[:200]` is then entirely inside
    # the shared prefix, every directory matches every path, each row becomes the
    # sum of all of them and the total is multiplied by the number of rows.
    # Silent, nothing on stderr, no zero to notice.
    #
    # One path has one hash and therefore one directory, so more than one match
    # cannot be identified and is refused rather than guessed. Said, because a
    # worktree that has transcripts and reports none is the case the "reaped"
    # line would otherwise explain wrongly. Found by the independent review.
    prefix = name[:SLUG_MAX] + "-"
    try:
        listing = sorted(os.listdir(root))
    except OSError:
        return []
    matched = [os.path.join(root, n) for n in listing
               if n.startswith(prefix) and os.path.isdir(os.path.join(root, n))]
    if len(matched) > 1:
        ambiguous.add(path)
        note("%d transcript directories share the first %d characters of the"
             " slug for %s, so none of them can be told apart; not counted"
             % (len(matched), SLUG_MAX, path))
        return []
    return matched

pairs = []
seen_pairs = set()
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    issue, _, path = line.partition("\t")
    if want and issue not in want:
        continue
    if (issue, path) in seen_pairs:
        continue
    seen_pairs.add((issue, path))
    pairs.append((issue, path))

# One entry per issue, in issue order, carrying every worktree it has had.
by_issue = {}
for issue, path in pairs:
    by_issue.setdefault(issue, []).append(path)
order = sorted(by_issue, key=int)

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

# A FILTER THAT MATCHED NOTHING IS NOT AN EMPTY FLEET. `cost 999` used to answer
# "the fleet has no recorded worktree path for anything to measure yet" with
# records for three other issues sitting right there, and then print a total row
# of zeros anyway. Said precisely, naming the issues actually asked for.
#
# NOT when the root is unusable. Two lines fired together on a host that has
# vendored autofleet, not emptied the knob and not run the fleet yet -- and the
# Acceptance of #48 asks for ONE explanatory line. The root is the bigger news
# and it is already said; a second line about the registry is noise under it.
missing = sorted(want - set(order), key=int) if usable else []
if missing:
    note("no worktree path is recorded for #%s -- the fleet has not run it"
         % ", #".join(missing))
elif usable and not order:
    note("the fleet has no recorded worktree path for anything to measure yet")

# Two counters, not one, because they are two different pieces of news and one
# message for both said the reassuring one. A half-written last line is normal
# and costs nothing; a file or directory that would not open means a whole
# worktree is missing from its row, which shows as zeros with no hint why.
bad_lines = 0
bad_files = 0

def add_file(path, sums):
    """Fold one transcript into sums. True if it carried any usage at all."""
    global bad_lines, bad_files
    # ONE `seen` PER FILE, and de-duplication is not optional. The CLI writes one
    # entry per content block of an assistant message, each carrying the SAME
    # `message.usage` -- 26 entries for 15 messages in the transcript this was
    # written against. Summing the entries reports roughly twice what the run
    # cost, which is worse than reporting nothing, because it looks like an
    # answer.
    seen = set()
    counted = False
    try:
        # `errors="replace"`, and it is the difference between this file keeping
        # its promise and breaking it. The decode happens in `for raw in handle`
        # below, OUTSIDE the `try` around `json.loads` -- so with a strict decode
        # one invalid byte anywhere in any transcript raised UnicodeDecodeError
        # out of here, out of measure(), out of the module: a traceback, exit 1,
        # and NO TABLE AT ALL, not even for the issues already summed. The header
        # of this file promises the opposite, and so does docs/CONFIGURATION.md.
        #
        # The trigger is ordinary. A transcript carries the agent prose, this
        # repo is full of em dashes, and an em dash is three bytes -- so an agent
        # killed mid-write (`stop.sh --now`, the time-box interrupt, a crashed
        # worktree) leaves a partial multi-byte character at the tail. The
        # ASCII-truncated line was handled and the multi-byte one was fatal.
        # Replaced, the bad bytes become U+FFFD, `json.loads` rejects the line,
        # and it lands in `bad_lines` where the comment already says it belongs.
        # Found by the independent review.
        handle = open(path, encoding="utf-8", errors="replace")
    except OSError:
        bad_files += 1
        return False
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
                bad_lines += 1
                continue
            if not isinstance(entry, dict) or entry.get("type") != "assistant":
                continue
            message = entry.get("message")
            if not isinstance(message, dict):
                continue
            usage = message.get("usage")
            # An entry with no usage is normal -- an interrupted turn, an older
            # transcript format -- and is skipped, not fatal.
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
    return counted

def measure(paths):
    """(sessions, found, {field: tokens}) for every worktree one issue has had.

    `found` is whether ANY transcript carried usage, subagents included, and is
    what decides the "no transcripts -- reaped" line. `sessions` counts top-level
    transcripts only, so a worktree whose session file carries no usage but whose
    subagents do has sessions == 0 with real figures beside it -- and was then
    told it had no transcripts, which is the one line in this file that states a
    CAUSE, stating a false one. Found by the independent review.
    """
    global bad_files
    sums = {key: 0 for _, key in FIELDS}
    sessions = 0
    found = False
    # ONE PASS PER DIRECTORY, not per recorded path. `directories_for` falls back
    # to a PREFIX match past SLUG_MAX, so two of the paths for ONE issue that agree on
    # their first 200 slug characters return the SAME directory -- and two
    # attempts at one issue are exactly that shape, since what tells them apart
    # is a trailing suffix. Read once per path, every file was summed twice and
    # `sessions` counted twice: a row exactly double, with nothing on stderr and
    # no zero to notice. That is the failure this whole file calls the worst one
    # available, arriving for the third time in this change. An ordered set, so
    # the report still reads them in a stable order. Found by the independent
    # review.
    directories = []
    for path in paths:
        for directory in directories_for(path):
            if directory not in directories:
                directories.append(directory)
    for directory in directories:
        try:
            entries = sorted(os.listdir(directory))
        except OSError:
            # A transcript directory that cannot be listed is one worktree
            # with no figures, not a report that dies half way through.
            bad_files += 1
            continue
        for name in entries:
            full = os.path.join(directory, name)
            if name.endswith(".jsonl") and os.path.isfile(full):
                # A file directly in the project directory is a SESSION.
                if add_file(full, sums):
                    sessions += 1
                    found = True
            elif os.path.isdir(full) and os.path.isdir(
                    os.path.join(full, "subagents")):
                # ...and everything under it belongs to that session.
                #
                # SUBAGENTS LIVE HERE, and missing them is not a rounding
                # error. A subagent writes its own transcript under
                # `<session-id>/subagents/agent-*.jsonl`, and this repo
                # REQUIRES subagents: researcher and the review
                # passes per issue (CLAUDE.md). Reading only the top level
                # dropped 92% of the cache-write tokens for one worktree and
                # reported 1 session where 4 agents had run.
                #
                # `<session-id>/subagents` BY NAME, and then walked to
                # the bottom. The walk has to be DEEP, because an agent that
                # spawns an agent nests one level further down again -- but
                # it must not be WIDE: a session directory carries siblings,
                # `tool-results` among them on this machine, and persisted
                # tool output landing there as `.jsonl` would be summed as if
                # an agent had spent it. Found by the independent review.
                # `onerror`, because os.walk SWALLOWS its errors by
                # default: a subagents/ directory that would not open
                # vanished silently, one level below the "each costs one
                # line on stderr" this file promises. Found by the
                # independent review.
                def unreadable(_error):
                    global bad_files
                    bad_files += 1
                subagents = os.path.join(full, "subagents")
                for here, _dirs, files in os.walk(subagents,
                                                  onerror=unreadable):
                    for nested in sorted(files):
                        if nested.endswith(".jsonl"):
                            if add_file(os.path.join(here, nested), sums):
                                found = True
    return sessions, found, sums

rows = []
silent = []
for issue in (order if usable else []):
    paths = by_issue[issue]
    sessions, found, sums = measure(paths)
    # ...unless something already said why this row is empty. See `ambiguous`.
    if not found and not any(p in ambiguous for p in paths):
        silent.append(issue)
    rows.append({"issue": issue, "worktrees": paths, "sessions": sessions,
                 **{key: sums[key] for _, key in FIELDS}})

total = {"sessions": sum(r["sessions"] for r in rows)}
for _, key in FIELDS:
    total[key] = sum(r[key] for r in rows)

if usable and silent:
    # One line, naming them: a row of zeros would be indistinguishable from a
    # worktree that genuinely spent nothing, and the reason is worth saying once.
    note("no transcripts under %s for #%s -- reaped, or run before the fleet"
         " recorded its worktree path" % (root, ", #".join(silent)))
if bad_lines:
    note("%d transcript line(s) could not be parsed and were skipped" % bad_lines)
if bad_files:
    # Said separately and said louder: this one means a row is short of figures,
    # which shows as a small number rather than as an absence.
    note("%d transcript file(s) or director(ies) could not be read, so the"
         " figures are short by whatever was in them" % bad_files)

if as_json:
    json.dump({"transcript_dir": root, "issues": rows, "total": total},
              sys.stdout, indent=2)
    sys.stdout.write("\n")
    raise SystemExit(0)

# No rows, no table. The header and a total of zeros is a MEASUREMENT -- of a
# fleet that spent nothing -- and nothing was measured. The --json above still
# emits its structure, because a consumer has to tell "no data" from a crash.
if not rows:
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
widths = [max(len(h), *(len(r[i]) for r in body)) for i, h in enumerate(headers)]
print("  ".join(h.rjust(w) for h, w in zip(headers, widths)))
for i, r in enumerate(body):
    if i == len(body) - 1:
        # A rule above the total, so the row that is not an issue does not read
        # as one.
        print("  ".join("-" * w for w in widths))
    print("  ".join(c.rjust(w) for c, w in zip(r, widths)))
' "${AUTOFLEET_TRANSCRIPT_DIR:-}" "$shape" "${issues[@]+"${issues[@]}"}"
