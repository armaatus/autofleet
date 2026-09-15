#!/usr/bin/env python3
"""Payload scripts that put a comment INSIDE a `\\` line continuation.

A trailing `\\` joins the next line, and a `#` on that joined line comments out
everything after it -- including the rest of the command. So this:

    gh api "$url" \\
    # why we ask for previous_filename too
      --jq '...' >"$files" || exit 2

runs `gh api "$url"` with no `--jq`, dumps the raw payload to stdout, and leaves
`--jq ...` to run as a command of its own and take the `|| exit 2`. It parses
under `bash -n`, which is the PostToolUse hook's whole check, so nothing caught
it: review-status.sh shipped this way in #121 and every caller got 100KB of JSON
and "could not tell". `evals/lint.sh` runs this; CLAUDE.md carries the rule.

Prints one line, `path:lineno` for the continuation that swallows a comment;
empty means clean.
"""
import glob
import os
import re
import sys

# The same payload shell the other two scans read, and the same reason for the
# boundary: `.github/workflows/*.yml` carries `run:` blocks with this hazard too,
# but a PR editing a workflow cannot merge itself, so widening the glob would red
# the lint on a file the change may not fix. That is armaatus/autofleet#90's list.
PATTERNS = (
    "scripts/fleet/*.sh",
    "scripts/fleet/runner/*.sh",
    "evals/*.sh",
    ".github/scripts/*.sh",
    ".claude/hooks/*.sh",
    "install.sh",
)

COMMENT = re.compile(r"\s*#")


def continues(line):
    """Does this line end in a continuation that joins the next one?

    An EVEN number of trailing backslashes is `\\\\` -- an escaped backslash, a
    literal character -- and does not continue anything. `printf 'a\\\\'` at the
    end of a line is the shape, and reading it as a continuation would name the
    comment below it as a bug.
    """
    return (len(line) - len(line.rstrip("\\"))) % 2 == 1


def hazard_lines(text):
    """1-based numbers of continuation lines whose next line is a comment.

    Reported on the line carrying the `\\`, not the comment: that is the line a
    reader has to move or terminate, and the comment itself is usually right.
    """
    lines = text.splitlines()
    hits = []
    for i, raw in enumerate(lines):
        if not continues(raw):
            continue
        # A COMMENT LINE IS NOT THE ONLY HAZARD, but it is the only one that is
        # always a bug: a blank continuation line is legal and common, and a
        # `#` mid-line on a continued command may well be inside a quoted
        # string. Anchored at the start of the next line, which is where the
        # form this exists for always puts it.
        if i + 1 < len(lines) and COMMENT.match(lines[i + 1]):
            hits.append(i + 1)
    return hits


def offenders(root="."):
    found = []
    for path in sorted({p for pat in PATTERNS
                        for p in glob.glob(os.path.join(root, pat))}):
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        hits = hazard_lines(text)
        if hits:
            rel = os.path.relpath(path, root)
            found.append("%s:%s" % (rel, ",".join(str(n) for n in hits)))
    return found


def selftest():
    """The live shape, and the two ways a naive scan gets this wrong."""
    cases = [
        ("gh api x \\\n# why\n  --jq y", True, "the live shape from #121"),
        ("gh api x \\\n  # indented, same bug\n  --jq y", True,
         "leading whitespace does not save it"),
        ("gh api x \\\n  --jq y\n# a comment after the statement", False,
         "a comment BELOW a finished command is fine"),
        ("gh api x \\\n\n  --jq y", False, "a blank continuation line is legal"),
        ("printf 'a\\\\'\n# a comment", False,
         "an escaped backslash is not a continuation"),
        ("# a comment\ngh api x", False, "a comment above a command is the right place"),
        ("gh api x \\\n  --jq y # trailing comment", False,
         "a trailing comment ends the statement, which is what it means to"),
    ]
    bad = 0
    for src, want, why in cases:
        got = bool(hazard_lines(src))
        if got != want:
            print("FAIL: %r -> %s, expected %s (%s)" % (src, got, want, why))
            bad += 1
    if bad:
        return 1
    print("  %d comment-in-continuation assertions hold" % len(cases))
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        sys.exit(selftest())
    print("; ".join(offenders(sys.argv[1] if len(sys.argv) > 1 else ".")))
