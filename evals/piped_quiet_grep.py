#!/usr/bin/env python3
"""Payload scripts that pipe an assertion into `grep -q`.

`-q` exits on the first match, the producer on the left of the pipe then writes
into a closed one, and `set -o pipefail` makes the pipeline 141 -- so a check
that HELD is reported as failed. A race, so green on small input and red on
large. `evals/lint.sh` runs this; CLAUDE.md carries the rule.

A separate file rather than a heredoc inside lint.sh: the pattern this looks for
is `| grep -q`, and a heredoc containing it would have to be written so as not
to match itself, which is how a detector ends up with a hole shaped like its own
source. Prints one line, the offending paths; empty means clean.
"""
import glob
import os
import re
import sys

PATTERNS = (
    "scripts/fleet/*.sh",
    "scripts/fleet/runner/*.sh",
    "evals/*.sh",
    ".github/scripts/*.sh",
    ".claude/hooks/*.sh",
    "install.sh",
)

# `-q` in any bundle of short flags (`-q`, `-qE`, `-qxF`), and the long spelling.
HAZARD = re.compile(r"\|\s*grep\b[^|]*?(?:\s-[A-Za-z]*q|\s--quiet)")
COMMENT = re.compile(r"\s*#")


def offenders(root="."):
    found = []
    for path in sorted({p for pat in PATTERNS for p in glob.glob(os.path.join(root, pat))}):
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        # Continuations first: a `|` ending one line and the grep beginning the
        # next is one pipeline, and a line-oriented scan walks straight past it.
        for line in text.replace("\\\n", " ").splitlines():
            if COMMENT.match(line):
                continue
            if HAZARD.search(line):
                found.append(os.path.relpath(path, root))
                break
    return found


if __name__ == "__main__":
    print("; ".join(offenders(sys.argv[1] if len(sys.argv) > 1 else ".")))
