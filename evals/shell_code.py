#!/usr/bin/env python3
"""Which part of a shell line is CODE, and which is prose -- and which lines
start a model call.

Three checks in evals/lint.sh need the first question answered: 7b asks which
scripts start a model call and whether they go through the compression seam, 7c
asks whether any of them reaches for the vendor the seam is named after. Both are
wrong in the same way without it -- a rule a COMMENT satisfies is a rule that has
stopped guarding. check 4c learnt that for the runner seam and carries its own
copy in awk; this is the Python one, written once because the third caller is the
one that drifts.

Shipped rather than inlined: `evals/` is vendored (CLAUDE.md, Layout), and a
vendored lint that imports a file the installer did not deliver fails on every
host PR, on a check about the host's own configuration. Hard rule 1.

    python3 evals/shell_code.py --selftest

...because a helper two guards depend on and nothing exercises is the third way
this has gone quietly wrong. Hard rule 3's temperament.
"""

import re
import sys

# What may stand in front of a command and leave it a command: a wrapper that
# still ends up running the agent in the environment of this process, or a shell
# construct the call is nested in.
_PREFIX = re.compile(
    r"^(exec|command|nohup|time|timeout\s+[0-9smhd.]+|if|while|until|then|do|!"
    r"|[A-Za-z_][A-Za-z0-9_]*=\S*)\s+|^[(]\s*|^\$[(]\s*"
)

# The expansion itself, in every spelling bash accepts: quoted or bare, braced
# or not. The first version wanted the quotes and the bare brace-less form only,
# which `"${AUTOFLEET_REVIEW_CMD}"` and `$AUTOFLEET_REVIEW_CMD` both walk past.
# Where one command ends and the next begins. Crude on purpose -- an operator
# inside quotes splits a line that was already going to be looked at whole, and
# the worst that costs is one extra fragment that matches nothing.
_SEPARATOR = re.compile(r"(?:;|&&|\|\||\|&|\|)")

_CALL = re.compile(r'^"?\$\{?AUTOFLEET_[A-Z_]*_CMD\}?"?')


def code_of(line):
    """`line` with any trailing comment removed, quotes respected.

    A `#` opens a comment only at the START OF A WORD. Treating every unquoted
    `#` as one truncates the line at `$#` and `${#x}` -- ordinary shell -- and
    everything after it goes unscanned, which is a check that quietly stops
    looking half way along its own input.

    Quote tracking is deliberately naive about backslash escapes: the callers
    ask "does this word appear in code", and an escaped quote moves where the
    comment starts, never whether the word is there.

    LINE BY LINE, with two consequences worth naming rather than discovering. A
    heredoc body and a multi-line string are read as ordinary lines, so quote
    tracking can be wrong inside them; and a STRING counts as code, so
    `echo fleet_headroom_env` satisfies 7b the way a comment used to. Both are
    accepted: closing either needs a shell parser, and both fail toward
    scanning more rather than less.
    """
    out, quote, prev = [], "", ""
    for c in line:
        if not quote:
            if c in "\"'":
                quote = c
            elif c == "#" and (prev == "" or prev.isspace() or prev in ";&|("):
                break
        elif c == quote:
            quote = ""
        out.append(c)
        prev = c
    return "".join(out)


def payload_shell():
    """Every shell file in the vendored payload, as (path, lineno, raw, code).

    Both callers walked `scripts/fleet/**/*.sh` and called `code_of` on each
    line, which is one loop written twice in the file whose whole reason for
    existing is that the third copy of a question drifts. Found by the
    self-review.
    """
    import glob

    for path in sorted(glob.glob("scripts/fleet/**/*.sh", recursive=True)):
        with open(path, encoding="utf-8") as fh:
            for n, raw in enumerate(fh, 1):
                yield path, n, raw, code_of(raw)


def starts_a_model_call(line):
    """Is this line's CODE a `$AUTOFLEET_*_CMD` in command position.

    COMMAND POSITION, not "appears on the line", and that is the difference
    between a call site and a mention: `fleet.sh` passes
    `"$AUTOFLEET_AGENT_CLEAR_CMD"` as an ARGUMENT -- keystrokes for a terminal,
    not a model -- and a check that read the whole line would demand the
    dispatcher export a base URL for it.
    """
    # SPLIT ON THE SEPARATORS FIRST. `set -m; "$AUTOFLEET_REVIEW_CMD" ...` is
    # one line with two commands in it, and a detector that only looks at the
    # start of the line reports the second one as absent. Found by the
    # self-review.
    for part in _SEPARATOR.split(code_of(line)):
        part = part.strip()
        while True:
            shorter = _PREFIX.sub("", part, count=1)
            if shorter == part:
                break
            part = shorter
        if _CALL.match(part):
            return True
    return False


_CASES = [
    # (line, is a call site)
    ('"$AUTOFLEET_REVIEW_CMD" -p "$prompt" \\', True),
    ('  "$AUTOFLEET_SELF_REVIEW_CMD" -p "$label" \\', True),
    ('timeout 600 "$AUTOFLEET_REVIEW_CMD" -p x', True),
    ('exec "$AUTOFLEET_REVIEW_CMD" --print', True),
    ('FOO=1 exec "$AUTOFLEET_REVIEW_CMD"', True),
    ('"${AUTOFLEET_REVIEW_CMD}" -p x', True),
    ("$AUTOFLEET_REVIEW_CMD -p x", True),
    ('if ! "$AUTOFLEET_REVIEW_CMD" -p x; then', True),
    # A DOCUMENTED GAP, asserted as False so it cannot be mistaken for covered:
    # a call captured into a variable begins with `out="$(`, and reaching it
    # needs a shell parser rather than a prefix list. It is recorded here rather
    # than half-fixed because a check that claims a shape it does not see is the
    # failure this whole file exists to stop. If the payload ever grows one,
    # this case changes to True and the prefix list grows with it.
    ('out="$($AUTOFLEET_REVIEW_CMD -p x)"', False),
    ('set -m; "$AUTOFLEET_REVIEW_CMD" -p x', True),
    ('mkdir -p "$d" && "$AUTOFLEET_REVIEW_CMD" -p x', True),
    # ...and the mentions, which are not call sites.
    ('  say_to_agent_in "$path" "$AUTOFLEET_AGENT_CLEAR_CMD" || continue', False),
    ('command -v "$AUTOFLEET_REVIEW_CMD" >/dev/null 2>&1 || {', False),
    ('# "$AUTOFLEET_REVIEW_CMD" -p "$prompt"', False),
    ('echo "runs it ($AUTOFLEET_REVIEW_CMD)"', False),
]

_CODE_CASES = [
    ("a $# b", "a $# b"),                    # $# is not a comment
    ("y=${#z} # c", "y=${#z} "),             # ...nor is ${#x}
    ('echo "#hash" # real', 'echo "#hash" '),  # a # inside quotes is text
    ("# whole", ""),
    ("x=1", "x=1"),
]

if __name__ == "__main__":
    if "--selftest" not in sys.argv:
        print(__doc__)
        raise SystemExit(0)
    bad = 0
    for line, want in _CODE_CASES:
        got = code_of(line)
        if got != want:
            print(f"code_of({line!r}) = {got!r}, want {want!r}")
            bad += 1
    for line, want in _CASES:
        got = starts_a_model_call(line)
        if got != want:
            print(f"starts_a_model_call({line!r}) = {got}, want {want}")
            bad += 1
    if bad:
        raise SystemExit(f"{bad} shell_code assertions failed")
    print(f"{len(_CODE_CASES) + len(_CASES)} shell_code assertions hold")
