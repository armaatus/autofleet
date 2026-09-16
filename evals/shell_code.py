#!/usr/bin/env python3
"""One answer to "which part of this shell line is CODE, and which is prose".

Two checks in evals/lint.sh need it -- 7b asks which scripts start a model call
and whether they go through the compression seam, 7c asks whether any of them
reaches for the vendor the seam is named after -- and both are wrong in the same
way without it: a rule satisfied by a COMMENT is a rule that stopped guarding.
check 4c learnt this for the runner seam and carries its own copy in awk; this is
the Python one, written once because the third caller is the one that drifts.

Shipped rather than inlined: `evals/` is vendored (CLAUDE.md, Layout), and a
vendored lint that imports a file the installer did not deliver fails on every
host PR, on a check about the host's own configuration. Hard rule 1.
"""


def code_of(line):
    """`line` with any trailing comment removed, quotes respected.

    A `#` opens a comment only at the START OF A WORD. Treating every unquoted
    `#` as one truncates the line at `$#` and `${#x}` -- ordinary shell -- and
    everything after it goes unscanned, which is a check that quietly stops
    looking half way along its own input. Found by the self-review.

    Quote tracking is deliberately naive about backslash escapes: the checks
    that use this ask "does this word appear in code", and an escaped quote
    shifts where the comment starts, never whether the word is there.
    """
    out, quote, prev = [], "", " "
    for c in line:
        if not quote:
            if c in "\"'":
                quote = c
            elif c == "#" and (prev.isspace() or prev in ";&|(" or prev == ""):
                break
        elif c == quote:
            quote = ""
        out.append(c)
        prev = c
    return "".join(out)
