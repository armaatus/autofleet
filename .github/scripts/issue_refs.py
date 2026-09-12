#!/usr/bin/env python3
"""The two cross-reference conventions this repo runs on, spelled once.

Three parsers read the same two line-shapes out of issue and pull request
bodies, and they used to disagree:

  `Closes #N`     GitHub links and closes on any of NINE keywords, matched
                  case-insensitively with any run of whitespace before the `#`.
                  `fleet.sh` matched the single spelling `Closes #N`, so a PR
                  saying `Fixes #12` closed the issue and unblocked its
                  dependants while `has_open_pr` still reported #12 free -- and
                  the dispatcher opened a second worktree for work already in
                  flight, out of only three slots.

  `Blocked by #N` `.github/workflows/unblock.yml` matches the pattern below;
                  `fleet.sh` matched `Blocked by #` exactly. A body written
                  `blocked by #7` was a blocker to the workflow and invisible to
                  the fleet, so the issue that frees the most work scored zero
                  and lost the ordering the queue exists to produce.

                  The line has to BEGIN a line, and -- when the body carries the
                  `<!-- blockers -->` marker CLAUDE.md and docs/WORKFLOW.md both
                  describe -- has to sit below it. Neither was true before, and
                  the unanchored whole-body read let ordinary prose relabel the
                  backlog: `no longer blocked by #7` in Design notes registered
                  as a blocker, and CLAUDE.md tells agents to edit issue bodies
                  as they work, so an agent could write that sentence into its
                  OWN issue, watch `edited` fire, and be interrupted and reaped
                  by `fleet.sh` -- which reads `blocked` as "this worktree will
                  never produce a merged PR" (#47).

WHY IT LIVES IN `.github/scripts/` rather than `scripts/fleet/`, which is where
its busiest reader is: `.github/workflows/merge-gate.yml` runs `merge_gate.py`
from a SPARSE CHECKOUT of `.github/scripts` alone, taken from the base branch.
A module anywhere else is simply not on disk when the gate runs. `fleet.sh` is
in a full worktree and can reach here; the gate cannot reach out.

`unblock.yml` is JavaScript inside YAML and cannot import this at all. What
keeps it in step is that it spells BOTH patterns identically AND scopes them the
same way. `evals/lint.sh` asserts all three: the two literals match character for
character, and the workflow's reader is run over this module's own SELFTEST table
and has to return the same answers. It fails if either side is edited alone.

    python3 .github/scripts/issue_refs.py --selftest
"""

import re
import sys

# GitHub's closing keywords, verbatim from its documentation on linking a pull
# request to an issue. Nine, not one: an agent that writes `Fixes #12` gets
# exactly the same behaviour out of GitHub as one that writes `Closes #12`, so
# every reader of a body here has to agree with that.
CLOSING_KEYWORDS = (
    "close", "closes", "closed",
    "fix", "fixes", "fixed",
    "resolve", "resolves", "resolved",
)

# Longest first so the alternation reads in the obvious order. It would match
# either way -- Python backtracks into the shorter branches -- but a pattern
# whose correctness depends on backtracking is a pattern nobody edits safely.
_KEYWORDS = "|".join(sorted(CLOSING_KEYWORDS, key=len, reverse=True))

# `\b` at both ends: `Uncloses #12` is not a closing line, and `Closes #160` is
# not one for #16.
#
# Deliberately NOT accepting GitHub's `owner/repo#N` or full-URL forms. They
# close an issue in ANOTHER repository, and reading one as a local reference
# would tell the fleet that its own issue N is in flight when nothing is --
# "nothing startable" with the backlog wide open. CLAUDE.md asks for `Closes
# #N`, and that is the form every reader here agrees on.
CLOSES = re.compile(r"\b(?:" + _KEYWORDS + r")\s+#(\d+)\b", re.IGNORECASE)

# Character for character what unblock.yml matches. Parity is the point: an
# issue this disagrees with the workflow about is one the fleet may start while
# the labels call it blocked.
#
# `^` with re.MULTILINE, not `\b`: `\b` rules out `unblocked by #12` -- there is
# no word boundary inside `unblocked` -- but it happily matches the `blocked by
# #7` inside `no longer blocked by #7`, which is the same sentence with the
# opposite meaning. A blocker is a LINE, so the line is what is matched.
#
# THE PREFIX IS WIDE ON PURPOSE, and every character of it is a spelling an agent
# actually reaches for: `- `, `* `, `+ `, `> `, `1. `, `1) `, `- [ ] ` and
# `**Blocked by #7**`. A narrower class does not fail loudly -- it returns NO
# blockers, which marks the issue `ready` with its foundation open, and that is
# the collision the label exists to prevent. Found by the independent review,
# which caught five of these silently blocking nothing.
#
# `[0-9]`, NOT `\d`: Python's `\d` matches any Unicode decimal digit and
# JavaScript's does not, so `Blocked by #\u0667` was a blocker to the fleet and
# invisible to the workflow -- a disagreement no parity check written in one of
# the two languages can see.
BLOCKED_BY = re.compile(
    r"^[ \t]*(?:(?:[-*+>]|[0-9]+[.)]|\[[ xX]\]|\*{1,2})[ \t]*)*"
    r"blocked\s+by\s+#([0-9]+)",
    re.IGNORECASE | re.MULTILINE)

# ...and below this marker, when a body carries one. CLAUDE.md and
# docs/WORKFLOW.md have both always said the lines live "below a `<!-- blockers
# -->` marker"; nothing enforced it, so a mention of a blocker anywhere in Goal,
# Scope or Design notes counted as one.
#
# MATCHED ON ITS OWN LINE, and the LAST such line wins. #47's own body is the
# case that demands both: it quotes `<!-- blockers -->` mid-sentence in its Scope
# while discussing this very bug, and carries the real marker, empty, at the end.
# A `find` for the bare string picks the prose one and reads the entire rest of
# the issue as blockers -- which is how #47 came to be labelled `blocked` by
# seven blockers it does not have.
BLOCKERS_MARKER = re.compile(r"^[ \t]*<!--\s*blockers\s*-->[ \t]*$", re.MULTILINE)


def _normalised(body):
    """`body` with CRLF folded to LF, because `$` cannot step over a `\r`.

    A body edited through the GitHub WEB UI arrives CRLF. Under both engines `$`
    matches before the `\n` and not before the `\r`, so the marker line simply
    stopped existing and the read fell back to the whole body -- the read this
    module exists to stop, silently, for exactly the issues a human touched.

    Folded here rather than patched into the pattern (`[ \t\r]*$`) because the
    two readers are compared by lifting the workflow's pattern text into Python,
    and that comparison cannot see an engine difference in how `$` and `\r`
    interact. Normalising the INPUT makes the patterns mean the same thing in
    both languages, which is the only version of parity that check can prove.
    Found by the independent review.
    """
    return (body or "").replace("\r\n", "\n").replace("\r", "\n")


def closes(body):
    """Every issue number `body` says it closes, in order, as ints."""
    return [int(m.group(1)) for m in CLOSES.finditer(body or "")]


def closes_issue(body, number):
    """Does `body` carry a closing line for this one issue?

    `number` arrives from the shell -- a directory name under the fleet's
    owned-worktree registry, or an argument off the command line -- so it is a
    string, and not necessarily a number. Anything that is not an issue number
    is closed by nothing, which is the honest answer and a quieter one than a
    traceback out of a `python3 -c` inside a pipeline.
    """
    try:
        number = int(number)
    except (TypeError, ValueError):
        return False
    return number in closes(body)


def blockers_section(body):
    """The part of `body` the blocker lines may live in.

    Everything below the last `<!-- blockers -->` line, or the whole body when
    there is no marker at all. The fallback is deliberate and is the fail-CLOSED
    direction: 14 of this repo's own open issues predate the marker, and a host
    project vendoring this may never adopt it. Reading those as "no blockers"
    would mark a dependent issue `ready` and let the fleet start it on top of a
    foundation that has not landed -- the one collision the label exists to
    prevent. Missing the marker costs a false `blocked`, which costs a wait.
    """
    body = _normalised(body)
    last = None
    for m in BLOCKERS_MARKER.finditer(body):
        last = m
    return body[last.end():] if last else body


def blocked_by(body):
    """Every issue number `body` names as a blocker, in order, as ints."""
    return [int(m.group(1)) for m in BLOCKED_BY.finditer(blockers_section(body))]


SELFTEST = [
    # Every keyword GitHub closes on, in the case an agent is likely to use.
    ("Closes #12", [12], []),
    ("closes #12", [12], []),
    ("CLOSED #12", [12], []),
    ("Close #12", [12], []),
    ("Fixes #12", [12], []),
    ("fix #12", [12], []),
    ("Fixed #12", [12], []),
    ("Resolves #12", [12], []),
    ("resolve #12", [12], []),
    ("RESOLVED #12", [12], []),
    # Any whitespace, because GitHub takes any whitespace.
    ("Closes  #12", [12], []),
    ("Closes\t#12", [12], []),
    ("Closes\n#12", [12], []),
    # ...but the keyword has to be the whole word, and the number the whole
    # number.
    ("Uncloses #12", [], []),
    ("Closes#12", [], []),
    ("Closes #12abc", [], []),
    ("this closes nothing and mentions #12 in passing", [], []),
    # Several, in the order written, is a PR that closes two issues.
    ("Closes #12\nFixes #13\n", [12, 13], []),
    # The blocker convention, in the spellings unblock.yml already accepts.
    ("Blocked by #7", [], [7]),
    ("blocked by #7", [], [7]),
    ("Blocked  By  #7", [], [7]),
    ("Blocked by\n#7", [], [7]),
    ("<!-- blockers -->\nBlocked by #7\nBlocked by #8\n", [], [7, 8]),
    ("nothing blocks this", [], []),
    # A blocker is a LINE. Prose that says the opposite of what it contains was
    # a blocker to both readers until #47, and CLAUDE.md tells agents to write
    # exactly this kind of sentence into issue bodies as they work.
    ("no longer blocked by #7", [], []),
    ("unblocked by #12", [], []),
    ("#40 was unblocked by #12 when that merged", [], []),
    ("it is blocked by #7 today", [], []),
    # ...but the spellings a blocker line is actually written in all hold,
    # including the markdown list an agent reaches for first.
    ("- Blocked by #7", [], [7]),
    ("* blocked by #7", [], [7]),
    ("  Blocked by #7", [], [7]),
    ("Closes #1\n- Blocked by #7\n", [1], [7]),
    # Below the marker only, when there is one. Scope and Design notes discuss
    # blockers constantly; none of that is the list.
    ("Prose: blocked by #9\n\n<!-- blockers -->\nBlocked by #10\n", [], [10]),
    ("<!-- blockers -->\n", [], []),
    # CRLF, as the GitHub web UI writes it. The marker has to survive the `\r`
    # or the whole body is read again and prose blocks work.
    ("Prose\r\nblocked by #9\r\n\r\n<!-- blockers -->\r\nBlocked by #10\r\n",
     [], [10]),
    ("<!-- blockers -->\r\nBlocked by #7\r\n", [], [7]),
    # Every markdown spelling an agent writes a list in. Five of these returned
    # NOTHING before the independent review found them -- and returning nothing
    # marks the issue `ready` with its blocker open, which is the direction that
    # starts work on a foundation that has not landed.
    ("+ Blocked by #7", [], [7]),
    ("1. Blocked by #7", [], [7]),
    ("2) Blocked by #7", [], [7]),
    ("- [ ] Blocked by #7", [], [7]),
    ("- [x] Blocked by #7", [], [7]),
    ("> Blocked by #7", [], [7]),
    ("**Blocked by #7**", [], [7]),
    ("<!-- blockers -->\n- [ ] Blocked by #7\n1. Blocked by #8\n", [], [7, 8]),
    # ...and the prefix stays a PREFIX. Prose is still prose.
    ("1. no longer blocked by #7", [], []),
    ("- unblocked by #12", [], []),
    # `\d` is Unicode in Python and ASCII in JavaScript, so an Arabic-Indic
    # numeral was a blocker to the fleet and invisible to the workflow. Neither
    # reads it now, which is a disagreement fewer.
    ("Blocked by #\u0667", [], []),
    # The LAST marker on its own line, because #47 quotes the marker mid-sentence
    # in its Scope and carries the real one, empty, at the end. Reading from the
    # quoted one is how it came to carry seven blockers it does not have.
    ("the `<!-- blockers -->` marker\nblocked by #12\n\n<!-- blockers -->\n", [], []),
    ("<!-- blockers -->\nBlocked by #3\n\n<!-- blockers -->\nBlocked by #4\n",
     [], [4]),
    # No marker at all: the whole body, still anchored. 14 of this repo's open
    # issues have no marker, and a host project may never adopt one -- reading
    # those as unblocked is the direction that starts work on a foundation that
    # has not landed.
    ("Blocked by #7\nBlocked by #8\n", [], [7, 8]),
    # A real body, carrying both.
    ("## Plan\nCloses #115\n\n<!-- blockers -->\nBlocked by #40\n", [115], [40]),
    # Neither reader may fall over on an absent body: `gh` returns null for one.
    (None, [], []),
]


def selftest():
    failures = 0
    for body, want_closes, want_blocked in SELFTEST:
        shown = repr(body)
        got_closes, got_blocked = closes(body), blocked_by(body)
        if got_closes != want_closes or got_blocked != want_blocked:
            print(f"FAIL: {shown}: closes {got_closes} (want {want_closes}), "
                  f"blocked by {got_blocked} (want {want_blocked})",
                  file=sys.stderr)
            failures += 1
        else:
            print(f"  ok: {shown}")
    if not closes_issue("Fixes #12", 12) or closes_issue("Fixes #120", 12):
        print("FAIL: closes_issue does not agree with closes()", file=sys.stderr)
        failures += 1
    if not closes_issue("Fixes #12", "12") or closes_issue("Fixes #12", ".DS_Store"):
        print("FAIL: closes_issue does not take an issue number off the shell",
              file=sys.stderr)
        failures += 1
    if failures:
        print(f"{failures} issue-reference assertion(s) failed", file=sys.stderr)
        return 1
    print(f"{len(SELFTEST)} issue-reference assertions hold")
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        sys.exit(selftest())
    print(__doc__.strip(), file=sys.stderr)
    sys.exit(2)
