#!/usr/bin/env python3
"""Block the things this repo cannot afford an agent to do.

A PreToolUse hook: reads the tool call as JSON on stdin, exits 2 to block and
writes the reason to stderr, where Claude reads it and corrects itself. Exit 0
allows.

CLAUDE.md and the skills beside this file are advisory -- a session can read them
and still do the thing. Everything here is a rule where "rare" is not good
enough, so it is enforced instead of asked for.

It does NOT fail open. An unreadable payload, a missing key, an unparseable
command: all of those block, because a guard that quietly stops guarding when
something upstream changes shape is worse than no guard at all -- nothing on
screen says the enforcement went away.

Commands are shell-tokenised with shlex rather than matched as raw strings, so
`git -C /some/path push --force origin main` is caught and
`git commit -m "note about --force pushes"` is not. Compound commands are split
on `;`, `&&`, `||` and `|` and each segment is judged on its own, and `bash -c`
is recursed into.

What this is NOT: a sandbox. It reads a command and decides; it does not confine
one. A session that means to get past it can -- an interpreter one-liner that
opens a file, a path assembled from a variable, an `exec` through something this
does not model. The line it holds is the ROUTINE one: the heredoc, the redirect,
the `sed -i`, the `gh pr merge`, the shapes an agent reaches for when it is
solving the problem in front of it rather than working around a rule. Past that,
the backstops are the diff and the human who merges. Do not write documentation
that claims more than this.

    ./.claude/hooks/guard.py --selftest
"""

import contextlib
import io
import json
import os
import re
import shlex
import subprocess
import sys

# What THIS project asks the guard to protect, over and above the universal
# rules below.
#
# autofleet ships no knowledge of any one repo, and a guard whose rules are
# hardcoded to one is a guard the next project has to fork. So the project-
# specific half is a file: `.autofleet/guard.json` in the repo root, read here,
# every key optional.
#
#   {
#     "protected_paths": [
#       {"path": "server/contract/captures/",
#        "tail": "captures/",
#        "reason": "the pinned API contract; a test diffs a live probe against it"}
#     ],
#     "secret_suffixes": ["/config.ini"],
#     "secret_contains": ["/token.dat"],
#     "secret_tails":    ["token.dat", "config.ini"]
#   }
#
# A malformed file is FATAL rather than ignored. A guard that silently falls
# back to "protect nothing" on a typo is worse than no guard: it reports
# success on every write it was installed to stop.
REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GUARD_CONFIG = os.environ.get(
    "AUTOFLEET_GUARD_CONFIG", os.path.join(REPO_ROOT, ".autofleet", "guard.json")
)


def _load_guard_config(path):
    if not os.path.exists(path):
        return {}
    try:
        with open(path) as handle:
            loaded = json.load(handle)
    except (OSError, ValueError) as exc:
        print(f"guard.py: cannot read {path}: {exc}", file=sys.stderr)
        sys.exit(2)
    if not isinstance(loaded, dict):
        print(f"guard.py: {path} must hold a JSON object", file=sys.stderr)
        sys.exit(2)
    return loaded


PROJECT = _load_guard_config(GUARD_CONFIG)

# Each entry is a path this project will not let an agent write, and the reason
# it gives when it refuses. The reason is the whole value of the rule: "blocked"
# with no why sends the agent looking for a way around it.
PROTECTED_PATHS = tuple(
    (
        entry["path"],
        entry.get("tail", entry["path"].rstrip("/").rsplit("/", 1)[-1] + "/"),
        entry.get("reason", "protected by this project's .autofleet/guard.json"),
    )
    for entry in PROJECT.get("protected_paths", [])
)

# The fleet's state, shared by every worktree because a stop has to reach all of
# them. See scripts/fleet/fleet.sh.
FLEET_DIR = os.environ.get(
    "AUTOFLEET_DIR", os.path.join(os.path.expanduser("~"), ".autofleet")
)
STOP_FILE = os.path.join(FLEET_DIR, "STOP")
OWNED_DIR = os.path.join(FLEET_DIR, "worktrees")

# What a stopped fleet must not do. Reading, building and testing stay open --
# the point of a stop is that nothing further reaches the outside world, not
# that the machine freezes.
OUTWARD = (
    ("git", "push"),
    ("gh", "pr", "create"),
    ("gh", "pr", "comment"),
    ("gh", "pr", "review"),
    ("gh", "pr", "edit"),
    ("gh", "issue", "create"),
    ("gh", "issue", "comment"),
    ("gh", "issue", "edit"),
    ("gh", "api"),
)

# `gh api` is both halves of the API: reading a PR and merging one. Only the
# write methods are outward, and blocking the reads would stop an agent finding
# out what it was in the middle of.
API_WRITE_METHODS = ("POST", "PUT", "PATCH", "DELETE")

# ...and `gh api` sends POST implicitly the moment any field is present, so a
# request with no -X can still be a write. A GraphQL mutation is the same thing
# wearing a different hat.
API_FIELD_FLAGS = ("-f", "-F", "--field", "--raw-field", "--input")

# Files that hold a real bearer token or key. Every one is gitignored, and a
# session with a reason to write one has a bug. `.env` is generated -- there is
# a script for it.
SECRET_SUFFIXES = ("/.env", ".env") + tuple(PROJECT.get("secret_suffixes", []))
SECRET_CONTAINS = tuple(PROJECT.get("secret_contains", []))
# The same files matched by a distinctive tail, so a relative path after a `cd`
# is still recognised.
SECRET_TAILS = tuple(PROJECT.get("secret_tails", []))

# The enforcement layer itself. An agent that can rewrite its own guards has no
# guards; this is the line between "advisory" and "enforced" that CLAUDE.md
# documents, and it has to be enforced by something the agent cannot reach.
# Skills and subagents are deliberately NOT in here: they are advisory by
# design, they are reviewed in the diff like anything else, and an agent
# improving one is the loop working.
SELF_PROTECTED = (
    "/.claude/hooks/",
    "/.claude/settings.json",
    # Gitignored, so a permission rule written here appears in no diff. That is
    # exactly why it needs the guard the committed file has.
    "/.claude/settings.local.json",
)

# The same targets, matched loosely enough to survive a relative path. A shell
# command can `cd` first, so `captures/login.json` and
# `server/contract/captures/login.json` are the same file and only one of them
# looks like it. Suffix-matching a distinctive tail is imperfect -- see the
# honesty note in the module docstring -- but it is what makes the routine forms
# reachable at all.
PROTECTED_TAILS = (
    ".claude/hooks/",
    ".claude/settings.json",
    ".claude/settings.local.json",
    "workflows/unblock.yml",
) + tuple(tail for _, tail, _ in PROTECTED_PATHS) + SECRET_TAILS


def deny(message):
    print(message, file=sys.stderr)
    sys.exit(2)


def _words(command):
    """The command's tokens, best effort.

    shlex on an unbalanced quote raises; falling back to a whitespace split is
    still better than giving up, because giving up here means allowing.
    """
    try:
        return shlex.split(command)
    except ValueError:
        return command.split()


def _is_git(words, verb):
    """`git <verb>`, allowing git's own global options in between."""
    if not words:
        return False
    if words[0].rsplit("/", 1)[-1] != "git":
        return False
    i = 1
    while i < len(words):
        w = words[i]
        if w in ("-C", "-c", "--git-dir", "--work-tree", "--namespace"):
            i += 2
            continue
        if w.startswith("-"):
            i += 1
            continue
        return w == verb
    return False


def _gh_rest(words):
    """`gh`'s subcommand tokens, with its own global options stripped.

    `gh -R owner/repo pr review 26 --comment` is `gh pr review`, and matching on
    `words[1:3]` said otherwise -- so every rule below that names a subcommand
    was one `-R` away from not applying. `_is_git` has done this for git since
    it was written; the gh rules were reading raw positions.

    Found by the independent review of the change that added the review rule,
    which noticed the merge rule has always had the same shape.

    Only for deciding WHICH SUBCOMMAND this is. Rules that inspect flags -- the
    `--auto` allowance on `gh pr merge`, the write detection on `gh api` -- keep
    reading the unstripped list, because that is where the flags still are.
    """
    if not words or words[0].rsplit("/", 1)[-1] != "gh":
        return []
    rest, i = [], 1
    while i < len(words):
        w = words[i]
        # The only global option that takes a separate value. `--repo=x` is one
        # token and falls through to the generic skip below.
        if w in ("-R", "--repo"):
            i += 2
            continue
        if w.startswith("-"):
            i += 1
            continue
        rest.append(w)
        i += 1
    return rest


def _verb(words):
    return words[0].rsplit("/", 1)[-1] if words else ""


def _touches_protected(word):
    """The PROTECTED_PATHS entry this word writes into, if any."""
    tail = _protected_tail(word)
    for entry in PROTECTED_PATHS:
        where, protected_tail, _ = entry
        if where in word or (protected_tail and tail == protected_tail):
            return entry
    return None


def _protected_tail(path):
    """The protected marker this path ends in, if any.

    Suffix rather than prefix: the command may have `cd`-ed first, so the only
    reliable part of a relative path is its tail.
    """
    normalised = path.replace("//", "/").lstrip("./")
    for tail in PROTECTED_TAILS:
        if tail.endswith("/"):
            if ("/" + normalised).find("/" + tail) >= 0 or normalised.startswith(tail):
                return tail
        elif normalised == tail or normalised.endswith("/" + tail):
            return tail
    return None


def _repo_root():
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=5,
        )
        return out.stdout.strip() if out.returncode == 0 else ""
    except Exception:
        return ""


def _fleet_owns_this_worktree():
    """Was this worktree opened by the dispatcher rather than by a person?

    The push gate below is for the automatic flow only. Someone working by hand
    in their own worktree gets no gate -- a half-finished branch is a normal
    thing to push, and a guard that argues about it is a guard people route
    around.
    """
    root = _repo_root()
    if not root or not os.path.isdir(OWNED_DIR):
        return False
    try:
        for entry in os.listdir(OWNED_DIR):
            with open(os.path.join(OWNED_DIR, entry)) as fh:
                if os.path.realpath(fh.read().strip()) == os.path.realpath(root):
                    return True
    except OSError:
        return False
    return False


def _head_sha():
    try:
        out = subprocess.run(
            ["git", "rev-parse", "HEAD"], capture_output=True, text=True, timeout=5
        )
        return out.stdout.strip() if out.returncode == 0 else ""
    except Exception:
        return ""


def _git_c_dir(words):
    """The directory `git -C <dir>` would act in, if any."""
    for i, w in enumerate(words):
        if w == "-C" and i + 1 < len(words):
            return words[i + 1]
        if w.startswith("--git-dir="):
            return w.split("=", 1)[1]
    return None


def _current_branch(cwd=None):
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--abbrev-ref", "HEAD"],
            capture_output=True, text=True, timeout=5, cwd=cwd,
        )
        return out.stdout.strip() if out.returncode == 0 else ""
    except Exception:
        return ""


# `;` `&&` `||` `|` and newlines separate commands; only the first word of each
# is the verb. Judging the whole string as one command is how `x && rm <secret>`
# reads as an invocation of `x`.
_SEGMENT_SPLIT = re.compile(r"(?:\|\||&&|\||;|\n)")

_HEREDOC = re.compile(r"<<-?\s*(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\1")


def _strip_heredocs(command):
    """Drop heredoc BODIES before splitting.

    A heredoc body is data. Splitting it on newlines and judging every line as a
    command is how writing documentation about this file trips this file: a line
    quoting a blocked command inside a doc is prose, not the command. The
    redirect on the opening line is still a real write and is still judged; only
    what follows the delimiter is skipped.
    """
    lines = command.split("\n")
    out, i = [], 0
    while i < len(lines):
        line = lines[i]
        out.append(line)
        m = _HEREDOC.search(line)
        i += 1
        if not m:
            continue
        delim = m.group(2)
        while i < len(lines) and lines[i].strip() != delim:
            i += 1
        i += 1  # the delimiter line itself
    return "\n".join(out)


def _segments(command):
    for raw in _SEGMENT_SPLIT.split(_strip_heredocs(command)):
        raw = raw.strip()
        if raw:
            yield raw


REDIRECT = re.compile(r"^(?:\d*|&)?>{1,2}$")


def _written_paths(words):
    """Every path this command creates, replaces, moves or deletes.

    A write is a write whichever verb performs it. The point of collecting them
    is that check_path -- the rules about secrets, the pinned contract, the
    workflow and the hooks themselves -- then applies to a shell command exactly
    as it applies to an Edit. Without this, `cat > .claude/hooks/guard.py`
    rewrites the guard and the guard says nothing.
    """
    written = []
    positional = [w for w in words[1:] if not w.startswith("-")]
    verb = _verb(words)

    # Redirections, attached (`>out`) or detached (`> out`).
    for i, w in enumerate(words):
        if REDIRECT.match(w):
            if i + 1 < len(words):
                written.append(words[i + 1])
        else:
            m = re.match(r"^(?:\d*|&)?>{1,2}(.+)$", w)
            if m:
                written.append(m.group(1))

    if verb in ("rm", "shred", "truncate", "unlink"):
        written += positional
    elif verb == "tee":
        written += positional
    elif verb in ("cp", "install", "ln") and positional:
        written.append(positional[-1])
    elif verb == "mv" and positional:
        # Both ends: a move REMOVES the source. `cp` out is reading; `mv` out is
        # deleting, and the comment that justifies ignoring cp's source does not
        # carry to mv.
        written += positional
    elif verb == "dd":
        written += [w.split("=", 1)[1] for w in words[1:] if w.startswith("of=")]
    elif verb == "sed" and any(
        w == "-i" or (w.startswith("-i") and not w.startswith("--")) for w in words[1:]
    ):
        written += positional
    elif _is_git(words, "rm") or _is_git(words, "restore"):
        written += positional[1:]
    elif _is_git(words, "checkout") and "--" in words:
        written += words[words.index("--") + 1:]

    return [w for w in written if w and not w.startswith("-")]


def _after_cd(prefix, words):
    """Where a `cd` leaves the shell, as a prefix for the paths that follow.

    `None` means "somewhere this cannot work out" -- a variable, a bare `cd`,
    a `cd -`. Unknown has to stay unknown: guessing a prefix would resolve a
    later path to a file the command never touches, and a guard that blocks the
    wrong file gets switched off.
    """
    targets = [w for w in words[1:] if not w.startswith("-")]
    if len(targets) != 1:
        return None
    target = targets[0]
    if "$" in target or "`" in target or target == "-":
        return None
    if target.startswith("/"):
        collapsed = _collapse(target)
        if collapsed is None:
            return None
        return collapsed + "/" if collapsed != "/" else "/"
    if prefix is None:
        return None
    collapsed = _collapse(prefix + target)
    if collapsed is None:
        return None
    return collapsed + "/" if collapsed else ""


def _collapse(path):
    """`a/./b`, `a//b` and `a/c/../b` all as the one path they name.

    `None` for a walk that climbs past the top: the same "unknown has to stay
    unknown" rule `_after_cd` follows, for the same reason.

    Both the prefix a `cd` leaves and the path written after it go through
    this. Normalising only the prefix is what left `cd .claude && cat >
    ./hooks/guard.py` writable -- the marker is matched literally, and `./`
    in the tail is enough to stop it matching.
    """
    rooted = path.startswith("/")
    out = []
    for part in path.split("/"):
        if not part or part == ".":
            continue
        if part == "..":
            if not out:
                return None
            out.pop()
        else:
            out.append(part)
    joined = "/".join(out)
    return ("/" + joined) if rooted else joined


def check_bash(command, cwd=""):
    branch = None
    # What a `cd` earlier on this line has already consumed. Everything below
    # matches a path by its tail, which is what survives a relative path -- but
    # a marker whose own prefix is the thing the `cd` ate has no tail left to
    # match: once `cd .claude` has run, `hooks/guard.py` shares nothing with
    # `/.claude/hooks/`. Putting the prefix back is what makes it a path again.
    for segment in _segments(command):
        words = _words(segment)
        if not words:
            continue

        if _verb(words) == "cd":
            # Before the prefix moves: a redirection on the `cd` line happens
            # where the shell already stands, not where it is going.
            _judge_writes(words, cwd)
            cwd = _after_cd(cwd, words)
            continue

        # `bash -c "..."` is a command in an argument. Judge what it will run.
        if _verb(words) in ("bash", "sh", "zsh", "dash") and "-c" in words:
            idx = words.index("-c")
            if idx + 1 < len(words):
                check_bash(words[idx + 1], cwd)
            continue

        # A stopped fleet produces no outward effects, even from an agent that
        # is mid-thought and has not read the news. Reading, building and
        # testing stay open: the point is to stop the work reaching anyone, not
        # to freeze the machine.
        if os.path.exists(STOP_FILE):
            for prefix in OUTWARD:
                head = [w.rsplit("/", 1)[-1] for w in words[: len(prefix)]]
                matched = head == list(prefix) or (
                    prefix[0] == "git" and _is_git(words, prefix[1]))
                if matched and prefix == ("gh", "api"):
                    # A read is not outward. A write is, however it is spelled:
                    # an explicit method, any field flag (which makes gh POST on
                    # its own), or a GraphQL mutation.
                    method = ""
                    writes = False
                    for i, w in enumerate(words):
                        if w in ("-X", "--method") and i + 1 < len(words):
                            method = words[i + 1].upper()
                        elif w.startswith("--method="):
                            method = w.split("=", 1)[1].upper()
                        elif w in API_FIELD_FLAGS or any(
                            w.startswith(f + "=") for f in API_FIELD_FLAGS
                        ):
                            writes = True
                        elif "mutation" in w and "graphql" in " ".join(words):
                            writes = True
                    if method not in API_WRITE_METHODS and not writes:
                        continue
                if matched:
                    deny(
                        f"Blocked: the fleet is stopped ({STOP_FILE}).\n"
                        "Nothing goes out while that file exists -- no push, no PR, no "
                        "comment.\n"
                        "Say where you got to and stop. A person clears it with: "
                        "./scripts/fleet/fleet.sh resume"
                    )

        # In the automatic flow, a PR arrives already reviewed or it does not
        # arrive. `/code-review` locally, findings recorded, THEN push -- so the
        # independent review on the PR is a second opinion rather than the first
        # one. Only in fleet-owned worktrees: pushing a half-finished branch by
        # hand is a normal thing to do and this must not argue about it.
        pushes = _is_git(words, "push")
        opens_pr = [w.rsplit("/", 1)[-1] for w in words[:3]] == ["gh", "pr", "create"]
        if (pushes or opens_pr) and _fleet_owns_this_worktree():
            sha = _head_sha()
            marker = os.path.join(_repo_root(), ".autofleet", "run", f"reviewed-{sha}")
            if sha and not os.path.exists(marker):
                deny(
                    "Blocked: this worktree was opened by the fleet, and nothing leaves "
                    "one of those\n"
                    "unreviewed. Run the local review first, then record it:\n"
                    "  /code-review high\n"
                    "  /mattpocock-skills:code-review\n"
                    "  ./scripts/fleet/record-review.sh   # writes .autofleet/run/reviewed-<sha>\n"
                    "Fix what it found, re-run the tests, and push then. The marker is "
                    "per-commit,\n"
                    "so amending or adding a commit needs the review re-run -- which is "
                    "the point."
                )

        # "A human merges. Do not merge your own PR." -- CLAUDE.md, "Finishing a
        # task". Separation of duties is the one review control this project
        # has, and an agent that can merge is not separated from anything.
        if _verb(words) == "gh":
            rest = words[1:]
            sub_cmd = _gh_rest(words)
            # The independent review is not the author's to write, and in
            # `AUTOFLEET_REVIEW_MODE=local` that stops being self-evident.
            #
            # In the default `github` mode this rule is redundant: the reviewer
            # is a different GitHub account, so `merge_gate.independent_reviews()`
            # discards anything the PR's own author submitted and an agent
            # reviewing itself achieves nothing. In `local` mode the reviewer and
            # the author ARE one account, and what separates them is a marker in
            # the review body -- which an agent with `gh pr review` could simply
            # write. This is the half that makes the marker mean something:
            # the agent under review cannot reach the command that produces it.
            #
            # Only in a fleet-owned worktree. `scripts/fleet/review.sh` runs from
            # the repo root, which is not one, which is how the dispatcher's
            # reviewer still submits. And a person reviewing a PR from their own
            # checkout is the ordinary case this must not argue about.
            if sub_cmd[:2] == ["pr", "review"] and _fleet_owns_this_worktree():
                deny(
                    "Blocked: this worktree was opened by the fleet, and an agent does "
                    "not submit\n"
                    "the independent review of its own pull request.\n"
                    "\n"
                    "In local review mode the reviewer signs in as the same GitHub "
                    "account you do,\n"
                    "so the ONLY thing separating its verdict from yours is a marker in "
                    "the review\n"
                    "body -- and this is what keeps that marker out of your reach. The "
                    "dispatcher\n"
                    "runs the reviewer for you; wait for it:\n"
                    "  ./scripts/fleet/await-review.sh\n"
                    "\n"
                    "To answer findings, reply on the thread and resolve it, then say "
                    "what you did:\n"
                    "  ./scripts/fleet/resolve-thread.sh\n"
                    "  ./scripts/fleet/answer-review.sh \"<what you did, or why you did not>\""
                )
            if sub_cmd[:2] == ["pr", "merge"]:
                # `--auto` does not merge. It asks GitHub to merge later, once
                # the required checks pass -- and `merge-gate` is one of those,
                # so the conditions in it are what actually decide. That keeps
                # separation of duties intact: the agent never approves and
                # never merges; it queues a request that a rule you set either
                # satisfies or does not.
                if "--auto" in rest and "--admin" not in rest:
                    continue
                deny(
                    "Blocked: agents do not merge PRs on this repo (CLAUDE.md, "
                    '"Finishing a task").\n'
                    "A human merges. Open the PR, put the /code-review findings in "
                    "its body, and stop there."
                )
            # The REST spelling of the same thing.
            if sub_cmd[:1] == ["api"] and any(
                re.search(r"/pulls/\d+/merge", w) for w in rest
            ):
                deny(
                    "Blocked: `gh api .../pulls/N/merge` is merging a PR, which agents "
                    "do not do\n"
                    'on this repo (CLAUDE.md, "Finishing a task"). A human merges.'
                )
            # ...and the REST spelling of submitting a review, which is the same
            # act as `gh pr review` above and was reachable while that rule
            # matched only the porcelain.
            #
            # THIS IS NOT SYMMETRY FOR ITS OWN SAKE. In `local` review mode the
            # marker in a review body is the only thing separating the reviewer's
            # verdict from the author's, so `gh api --method POST
            # repos/O/R/pulls/N/reviews -f body='...<!-- independent-review:
            # local <sha> -->'` was a live way for an agent to write its own.
            # docs/CONFIGURATION.md claimed the marker was out of the author's
            # reach; until this it was not.
            #
            # Reachable through `defaultMode: "auto"` in settings.json rather
            # than through an allowlist entry -- an earlier version of this
            # comment said `Bash(gh api:*)` was allowlisted, and it is not. The
            # rule is right; the reason it gave was wrong. Found by the
            # independent review of this change.
            #
            # Both review passes on the PR that introduced local mode found this
            # independently, which is what two axes are for.
            #
            # A GET is left alone: reading the reviews on a PR is how
            # `review-status.sh` and `await-review.sh` answer "has this been
            # reviewed yet", and refusing that would break the loop this guards.
            # ...and the GRAPHQL spelling, which has no `/pulls/N/reviews` path
            # in it at all. `gh api graphql -f query='mutation{
            # addPullRequestReview(...) }'` creates the same review record, with
            # the same author and the same commit oid, and
            # `independent_reviews()` counts it identically.
            #
            # Not a spelling nobody had thought of: the stop-file rule above
            # already detects a mutation this way. The rule that carried the
            # security claim did not, which is the finding.
            #
            # The whole `addPullRequestReview*` family, plus the submit: a
            # PENDING review submitted later is a review too. `resolveReviewThread`
            # -- the one mutation scripts/fleet/resolve-thread.sh sends -- is
            # deliberately not in here.
            if sub_cmd[:1] == ["api"] and _fleet_owns_this_worktree() and any(
                "addPullRequestReview" in w or "submitPullRequestReview" in w
                for w in rest
            ):
                deny(
                    "Blocked: that GraphQL mutation submits a pull request review, and this\n"
                    "worktree was opened by the fleet. An agent does not submit the "
                    "independent\n"
                    "review of its own pull request -- see the `gh pr review` refusal; this "
                    "is the\n"
                    "same act by a third name.\n"
                    "\n"
                    "Resolving a thread is `resolveReviewThread`, which is allowed and is "
                    "what\n"
                    "./scripts/fleet/resolve-thread.sh sends.\n"
                    "\n"
                    "The dispatcher runs the reviewer for you:  "
                    "./scripts/fleet/await-review.sh"
                )
            if sub_cmd[:1] == ["api"] and any(
                re.search(r"/pulls/\d+/reviews", w) for w in rest
            ) and _fleet_owns_this_worktree():
                method = ""
                for i, w in enumerate(rest):
                    if w in ("-X", "--method") and i + 1 < len(rest):
                        method = rest[i + 1].upper()
                    elif w.startswith("--method="):
                        method = w.split("=", 1)[1].upper()
                # `gh api` defaults to GET, and to POST as soon as a field is
                # given -- so "no -X" is not "harmless read". The flag list is
                # API_FIELD_FLAGS, shared with the stop-file rule above rather
                # than spelled a second time here: a list that exists twice is a
                # list that will disagree with itself.
                writes = any(
                    w in API_FIELD_FLAGS
                    or any(w.startswith(f + "=") for f in API_FIELD_FLAGS)
                    for w in rest[1:]
                )
                if method in ("POST", "PUT", "PATCH") or (not method and writes):
                    deny(
                        "Blocked: `gh api .../pulls/N/reviews` with a body is submitting a "
                        "review,\n"
                        "and this worktree was opened by the fleet. An agent does not submit "
                        "the\n"
                        "independent review of its own pull request -- see the `gh pr review` "
                        "refusal;\n"
                        "this is the same act by its REST name.\n"
                        "\n"
                        "The dispatcher runs the reviewer for you:  "
                        "./scripts/fleet/await-review.sh"
                    )

        # A force-push to main rewrites the commit chain, which is this
        # project's audit trail: who asked for what, what the agent produced,
        # who approved it.
        if _is_git(words, "push"):
            forced = any(
                w in ("--force", "-f", "--force-with-lease")
                or w.startswith("--force-with-lease=")
                or (len(w) > 1 and w[0] == "-" and not w.startswith("--") and "f" in w)
                for w in words[1:]
            )
            if forced:
                # Everything after the `push` verb. Taking "words[1:] minus
                # flags" swept in the verb itself and the ARGUMENT of a global
                # option, so `git -C main push --force origin HEAD` read as
                # targeting main and `git push -f origin` read as having two
                # refspecs and therefore not being a bare push.
                try:
                    after = words[words.index("push") + 1:]
                except ValueError:
                    after = words[1:]
                refs = [w for w in after if not w.startswith("-")]
                targets_main = any(
                    r == "main"
                    or r.startswith("main:")
                    or r.startswith("+main")
                    or r.endswith(":main")
                    or r.endswith(":refs/heads/main")
                    or r == "refs/heads/main"
                    for r in refs
                )
                # `git push -f origin HEAD` is the commoner idiom than naming the
                # branch, and on main it is the same rewrite.
                if not targets_main and any(r == "HEAD" for r in refs):
                    if branch is None:
                        branch = _current_branch(_git_c_dir(words))
                    targets_main = branch == "main"
                # ...and so is `git push -f` with no refspec at all.
                if not targets_main and len(refs) <= 1:
                    if branch is None:
                        branch = _current_branch(_git_c_dir(words))
                    targets_main = branch == "main"
                if targets_main:
                    deny(
                        "Blocked: force-pushing main rewrites the commit chain that is "
                        "this project's audit trail.\n"
                        "Push to your branch instead, or ask a human to do it "
                        "deliberately."
                    )

        # Every path this segment writes goes through the same rules an Edit
        # would. A write is a write whichever verb performs it.
        _judge_writes(words, cwd)

    return 0


def _judge_writes(words, cwd):
    """Judge every path one segment writes, from where the shell stands now.

    A function rather than a loop in place because `cd` needs it too: a
    redirection attached to the `cd` itself -- `cd tmp > .claude/settings.json`
    -- is performed before the directory changes, so it is judged against the
    prefix in hand, and skipping it lost the secrets, captures and
    self-protection rules for that shape.
    """
    for path in _written_paths(words):
        if cwd and not path.startswith("/"):
            path = cwd + path
        collapsed = _collapse(path)
        if collapsed is not None:
            path = collapsed
        protected = _touches_protected(path)
        if protected:
            where, _, reason = protected
            deny(
                f"Blocked: {where} is {reason}.\n"
                "Redirecting into it, or moving it away, rewrites it just as surely as "
                "editing it.\n"
                "Reading it is fine -- this blocks writing one."
            )
        check_path(path)


def check_path(path):
    normalised = path if path.startswith("/") else "/" + path
    tail = _protected_tail(path)

    # Only in a worktree the dispatcher opened. In the automatic flow nobody is
    # watching and an agent rewriting its own guards is a real risk; in a manual
    # session the person editing IS the control, and a guard nobody can ever
    # improve is a guard that rots. Same line the push gate draws, for the same
    # reason.
    for marker in SELF_PROTECTED if _fleet_owns_this_worktree() else ():
        if marker in normalised or (tail and marker.endswith(tail)):
            deny(
                f"Blocked: {path} is part of the enforcement layer, and this worktree "
                "was opened\n"
                "by the fleet. An agent that can rewrite its own guards while nobody is "
                "watching has\n"
                "no guards -- that is the line CLAUDE.md draws between advisory and "
                "enforced.\n"
                "Change it in a worktree you opened yourself, where the diff and the "
                "person merging\n"
                "are the control. Skills and subagents are advisory and editable "
                "anywhere."
            )

    if (normalised.endswith(SECRET_SUFFIXES)
            or any(m in normalised for m in SECRET_CONTAINS)
            or (tail and tail in SECRET_TAILS)):
        deny(
            f"Blocked: {path} holds per-worktree secrets, and none of them belong in "
            "the tree.\n"
            ".env is generated -- regenerate it with ./scripts/fleet/env.sh rather than "
            "editing it."
        )

    for where, protected_tail, reason in PROTECTED_PATHS:
        if where in normalised or (protected_tail and tail == protected_tail):
            deny(
                f"Blocked: {where} is {reason}.\n"
                "Editing it to match a failing run silences whatever it exists to "
                "catch.\n"
                "Say in the PR body what changed and why, or ask for it to be "
                "regenerated the way\n"
                "this project regenerates it."
            )

    if normalised.endswith("/.github/workflows/unblock.yml") or tail == "workflows/unblock.yml":
        deny(
            "Blocked: unblock.yml derives the blocked/ready labels that decide what "
            "other agents\n"
            'may start (CLAUDE.md, "Working in parallel"). Changing it changes what '
            "three worktrees\n"
            "are allowed to do. A human edits this one."
        )

    return 0


def _payload_cwd(payload):
    """Where this Bash call starts, as a prefix relative to the repo root.

    A `cd` is tracked within one command string, but Claude Code's shell keeps
    its directory between tool calls: `cd .claude/hooks` in one call writes
    nothing and is allowed, and `cat > guard.py` in the next arrived with no
    prefix at all. The payload carries the directory it will run in, so the
    second call can be judged the way the first would have been.

    Same rule as everywhere else here: anything that cannot be established is
    no prefix rather than a guessed one. A cwd outside the repo yields nothing,
    because every marker is relative to the root and a path outside it is not
    ours to judge.
    """
    cwd = payload.get("cwd")
    # Absolute, or it is not the answer this claims to be: a relative or
    # foreign-looking cwd resolves against wherever the hook happens to run,
    # which is a guessed prefix wearing a real one's clothes.
    if not isinstance(cwd, str) or not os.path.isabs(cwd):
        return ""
    # After the cheap checks: every Bash call reaches here, and this shells out.
    root = _repo_root()
    if not root:
        return ""
    try:
        rel = os.path.relpath(os.path.realpath(cwd), os.path.realpath(root))
    except (OSError, ValueError):
        return ""
    if rel == os.curdir or rel.startswith(os.pardir):
        return ""
    return rel + "/"


def main(payload):
    tool = payload.get("tool_name") or ""
    tool_input = payload.get("tool_input") or {}

    if tool == "Bash":
        command = tool_input.get("command")
        if not isinstance(command, str) or not command.strip():
            deny(
                "Blocked: this Bash call carries no readable command, so the guards in "
                ".claude/hooks/guard.py\n"
                "cannot tell whether it is allowed. Refusing rather than allowing an "
                "unexamined command."
            )
        return check_bash(command, _payload_cwd(payload))

    # NotebookEdit names its target notebook_path, not file_path. Reading only
    # file_path is how a matcher ends up promising coverage it does not have.
    path = tool_input.get("file_path") or tool_input.get("notebook_path")
    if not isinstance(path, str) or not path:
        # A tool the matcher caught that names no path -- nothing here applies.
        return 0
    return check_path(path)


SELFTEST = [
    # (tool, tool_input, expected exit, what it proves)
    #
    # Every row here is either a rule this repo depends on or an escape someone
    # actually found. The list is the record of what has been checked -- it is
    # not a proof that nothing else gets through; see the module docstring.

    # --- merging ------------------------------------------------------------
    ("Bash", {"command": "gh pr merge 42 --squash"}, 2, "an agent cannot merge its own PR"),
    ("Bash", {"command": "gh pr merge 42 --auto --squash"}, 0,
     "...but it may ASK GitHub to merge once the required checks pass"),
    ("Bash", {"command": "gh pr merge 42 --squash --admin"}, 2,
     "...and --admin, which bypasses those checks, is still merging"),
    ("Bash", {"command": "gh  pr  merge 12"}, 2, "...however it is spaced"),
    ("Bash", {"command": "/opt/homebrew/bin/gh pr merge 12"}, 2, "...through an absolute gh"),
    ("Bash", {"command": "gh api -X PUT repos/o/r/pulls/12/merge"}, 2, "...or spelled as the REST call"),
    ("Bash", {"command": "gh pr create --title x --body y"}, 0, "opening a PR is allowed"),
    ("Bash", {"command": "gh api repos/o/r/pulls/12"}, 0, "reading a PR over the API is allowed"),
    ("Bash", {"command": "ctest --test-dir build --output-on-failure"}, 0, "running the tests is allowed"),
    ("Bash", {"command": 'git commit -m "note: do not gh pr merge yourself"'}, 0, "a commit message is not a command"),
    ("Bash", {"command": 'grep -rn "gh pr merge" CLAUDE.md'}, 0, "grepping for a blocked command is allowed"),

    # --- force-pushing main -------------------------------------------------
    ("Bash", {"command": "git push --force origin main"}, 2, "force-pushing main is blocked"),
    ("Bash", {"command": "git push origin main -f"}, 2, "...with the flag last"),
    ("Bash", {"command": "git push --force origin refs/heads/main"}, 2, "...spelled as a full ref"),
    ("Bash", {"command": "git -C /w/main push --force origin some-branch"}, 0,
     "a -C path containing 'main' is not a refspec"),
    ("Bash", {"command": "git -C /w/demo push --force-with-lease origin main"}, 2, "...through git's global options"),
    ("Bash", {"command": "git push --force origin armaatus/fix-main-loop"}, 0, "a branch whose name contains 'main' is fine"),
    ("Bash", {"command": "git push -u origin armaatus/thing"}, 0, "an ordinary push is fine"),

    # --- a project's own protected paths ------------------------------------
    # Everything in this group is driven by SELFTEST_PROJECT below rather than
    # by anything hardcoded here: these rows prove the .autofleet/guard.json
    # mechanism, using the pinned-contract rule autofleet was extracted from
    # (armaatus/rommsync-nx) as the worked example.
    ("Bash", {"command": "probe.py > server/contract/captures/login.json"}, 2, "redirecting into a capture is blocked"),
    ("Bash", {"command": "probe.py >server/contract/captures/login.json"}, 2, "...with no space after the >"),
    ("Bash", {"command": "probe.py 1> server/contract/captures/login.json"}, 2, "...through an explicit fd"),
    ("Bash", {"command": "cd server/contract && cp /tmp/x captures/login.json"}, 2, "...after a cd, where the path is relative"),
    ("Bash", {"command": "rm server/contract/captures/login.json"}, 2, "deleting a capture is blocked"),
    ("Bash", {"command": "mv server/contract/captures/login.json /tmp/gone.json"}, 2, "moving one AWAY is deleting it, and blocked"),
    ("Bash", {"command": "sed -i '' s/a/b/ server/contract/captures/login.json"}, 2, "editing a capture in place is blocked"),
    ("Bash", {"command": "cp /tmp/new.json server/contract/captures/login.json"}, 2, "copying over a capture is blocked"),
    ("Bash", {"command": "cp server/contract/captures/login.json /tmp/look.json"}, 0, "copying one OUT is reading, and allowed"),
    ("Bash", {"command": "cat server/contract/captures/login.json"}, 0, "reading a capture is allowed"),
    ("Bash", {"command": "diff server/contract/captures/login.json /tmp/new.json > /tmp/d"}, 0, "a diff whose output goes elsewhere is allowed"),
    ("Bash", {"command": "grep -r foo server/contract/captures/"}, 0, "grepping the captures is allowed"),

    # --- the enforcement layer, from the shell ------------------------------
    # The whole class the first version missed: check_path only ran for Edit, so
    # every one of these rewrote a guarded file and said nothing.
    ("Bash", {"command": "cat > .claude/hooks/guard.py"}, 0,
     "the guards are writable by hand; _stateful_checks covers the fleet case"),
    ("Bash", {"command": "sed -i '' s/deny/allow/ .claude/hooks/guard.py"}, 0, "...by hand, the same"),
    ("Bash", {"command": "sed -i '' s/deny/allow/ .github/workflows/unblock.yml"}, 2, "...nor the blocked/ready workflow"),
    ("Bash", {"command": "echo TOKEN > token.dat"}, 2, "...nor a stored token"),
    ("Bash", {"command": "printf x > .env"}, 2, "...nor .env"),
    ("Bash", {"command": "echo '{}' > .claude/settings.local.json"}, 0, "...and so is the settings override"),
    ("Bash", {"command": "true && rm .env"}, 2, "a second segment is judged too"),
    ("Bash", {"command": 'bash -c "rm .env"'}, 2, "...and so is bash -c"),
    ("Bash", {"command": "cat .claude/hooks/guard.py"}, 0, "reading the guard is allowed"),
    ("Bash", {"command": "echo hi > /tmp/note.txt"}, 0, "an ordinary redirect is allowed"),

    # --- payloads -----------------------------------------------------------
    ("Bash", {}, 2, "a Bash call with no command is refused, not allowed"),

    # --- the editing tools --------------------------------------------------
    ("Edit", {"file_path": "/w/demo-project/.env"}, 2, "secrets are not editable"),
    ("Edit", {"file_path": "/w/demo-project/server/testing/fixture-auth.env"}, 2, "...including a project's fixture credentials"),
    ("Write", {"file_path": "/w/demo-project/token.dat"}, 2, "...and a stored token"),
    ("Edit", {"file_path": "/w/demo-project/server/contract/captures/login.json"}, 2, "a capture is not hand-edited"),
    ("Edit", {"file_path": "/w/demo-project/.github/workflows/unblock.yml"}, 2, "the blocked/ready workflow is not agent-editable"),
    # The enforcement layer is guarded only in a fleet worktree, so both halves
    # of that live in _stateful_checks below.
    ("Edit", {"file_path": "/w/demo-project/.claude/skills/house-style/SKILL.md"}, 0, "skills are advisory and stay editable"),
    ("Edit", {"file_path": "/w/demo-project/.claude/agents/verifier.md"}, 0, "so do subagents"),
    ("Edit", {"file_path": "/w/demo-project/src/app.c"}, 0, "ordinary source files are editable"),
    ("NotebookEdit", {"notebook_path": "/w/demo-project/.env"}, 2, "NotebookEdit names its target notebook_path, and is guarded too"),
    ("Bash", {"command": "cat > /tmp/doc.md <<'EOF'\nrm .env\nEOF"}, 0,
     "a heredoc body is data -- documenting a blocked command is not running it"),
    ("Bash", {"command": "rm .env"}, 2, "...and the same line outside a heredoc still blocks"),
]


# The hook's own path, assembled rather than written out: this module is full of
# rules about writing to it, and a literal makes the file its own false positive.
HOOK_REL = ".claude/" + "hooks/" + "guard.py"
SETTINGS_REL = ".claude/" + "settings.json"
LOCAL_SETTINGS_REL = ".claude/" + "settings.local.json"
_stateful_ran = 0


def _stateful_checks():
    """The two gates that depend on files rather than on the command alone.

    A stop that is not tested is a stop you find out about in the moment you
    needed it, so this builds a throwaway fleet directory and drives both.
    """
    import tempfile

    global STOP_FILE, OWNED_DIR
    saved = (STOP_FILE, OWNED_DIR)
    failures = 0

    def expect(want, tool_input, what, tool="Bash", because=None, cwd=None):
        """Drive one payload and judge the answer.

        `because` is a substring of the refusal, and the reason it exists is
        that exit 2 on its own is not proof: the guard also exits 2 for a
        payload it cannot read. Without it, a refactor that made these payloads
        unreadable -- or that moved a deny into the wrong branch -- would keep
        every assertion here green for a reason nobody intended. This carries
        the check the fleet-gate assertions had in evals/lint.sh before they
        moved here, which the move had dropped.
        """
        nonlocal failures
        global _stateful_ran
        _stateful_ran += 1
        # An allowed call writes no reason, so a `because` on one could never
        # hold. Catching it here rather than letting it fail every run.
        assert not (because and want == 0), "because= needs a refusal to read"
        payload = {"tool_name": tool, "tool_input": tool_input}
        if cwd is not None:
            payload["cwd"] = cwd
        said = io.StringIO()
        try:
            with contextlib.redirect_stderr(said):
                main(payload)
            got = 0
        except SystemExit as exc:
            got = exc.code
        why = said.getvalue()
        if got != want:
            # With the reason, because that is what a false block looks like
            # from here: capturing stderr to match it must not also swallow it.
            detail = f" -- {why.strip()}" if why.strip() else ""
            print(
                f"FAIL: {what} (expected exit {want}, got {got}){detail}",
                file=sys.stderr,
            )
            failures += 1
        elif because and because not in why:
            print(
                f"FAIL: {what} (exit {got} for the wrong reason: "
                f"{because!r} not in {why.strip()!r})",
                file=sys.stderr,
            )
            failures += 1
        else:
            print(f"  ok: {what}")

    with tempfile.TemporaryDirectory() as tmp:
        STOP_FILE = os.path.join(tmp, "STOP")
        OWNED_DIR = os.path.join(tmp, "worktrees")
        os.makedirs(OWNED_DIR)

        # No stop, not fleet-owned: nothing in the way.
        expect(0, {"command": "git push origin HEAD"}, "an ordinary push is not gated")
        expect(0, {"command": "gh pr create --title x"}, "...nor opening a PR")
        # The permitted half of the review rule, and it is not decoration: drop
        # the `_fleet_owns_this_worktree()` conjunct from it and every deny row
        # below stays green while `scripts/fleet/review.sh` -- which runs from
        # the repo root -- can no longer submit anything, so every PR on a
        # local-mode repository blocks forever. Found by the local review of the
        # change that added the rule.
        expect(0, {"command": "gh pr review 7 --comment --body x"},
               "...nor reviewing a PR from a worktree the fleet does not own")
        expect(0, {"command": "gh api --method POST repos/o/r/pulls/7/reviews -f body=x"},
               "...nor its REST spelling from there")
        expect(0, {"file_path": os.path.join(_repo_root() or "/w", HOOK_REL)},
               "the guards are editable by hand, where a person is watching", tool="Edit")

        # Stopped: nothing outward, everything inward.
        with open(STOP_FILE, "w") as fh:
            fh.write("stopped\n")
        expect(2, {"command": "git push origin HEAD"}, "a stopped fleet cannot push")
        expect(2, {"command": "gh pr create --title x"}, "...cannot open a PR")
        expect(2, {"command": "gh pr comment 7 --body x"}, "...cannot comment")
        expect(2, {"command": "gh issue edit 7 --body x"}, "...cannot edit an issue")
        expect(0, {"command": "ctest --test-dir build"}, "...but can still run the tests")
        expect(0, {"command": "cmake --build build"}, "...and still build")
        expect(0, {"command": "git status"}, "...and still read git")
        os.remove(STOP_FILE)

        # Fleet-owned and unreviewed: the push gate. The marker is per-commit,
        # so a fresh HEAD has none.
        root = _repo_root()
        if root:
            with open(os.path.join(OWNED_DIR, "999"), "w") as fh:
                fh.write(root + "\n")
            sha = _head_sha()
            marker = os.path.join(root, ".autofleet", "run", f"reviewed-{sha}")
            had_marker = os.path.exists(marker)
            if had_marker:
                os.rename(marker, marker + ".selftest")
            try:
                expect(2, {"command": "git push origin HEAD"},
                       "a fleet worktree cannot push before the local review")
                expect(2, {"command": "gh pr create --title x"},
                       "...nor open a PR")
                expect(0, {"command": "ctest --test-dir build"},
                       "...but the gate is only on what leaves")
                os.makedirs(os.path.dirname(marker), exist_ok=True)
                with open(marker, "w") as fh:
                    fh.write("reviewed\n")
                expect(0, {"command": "git push origin HEAD"},
                       "...and lifts once the review is recorded")
                # The other half of local review mode, and the sharp one:
                # with `gh pr review` reachable from here, the marker that makes
                # a self-review count is a string an agent can type.
                expect(2, {"command": "gh pr review 7 --comment --body x"},
                       "a fleet worktree cannot submit its own independent review",
                       because="does not submit")
                expect(0, {"command": "gh pr view 7 --json body"},
                       "...but reading the PR is not reviewing it")
                # The REST spelling. `gh pr merge` has had one of these since it
                # was written; `gh pr review` did not, and `Bash(gh api:*)` is on
                # the agent allowlist -- so this was the live way to forge the
                # marker local review mode depends on.
                expect(2, {"command": "gh api --method POST repos/o/r/pulls/7/reviews -f body=x"},
                       "...nor by its REST name", because="REST name")
                expect(2, {"command": "gh api -X POST repos/o/r/pulls/7/reviews -f event=COMMENT"},
                       "...nor with -X and the short flag", because="REST name")
                expect(2, {"command": "gh api repos/o/r/pulls/7/reviews -f body=x"},
                       "...nor with no method at all, which gh turns into a POST",
                       because="REST name")
                expect(2, {"command": "gh api --method=POST repos/o/r/pulls/7/reviews -f body=x"},
                       "...nor with --method=POST, the equals spelling",
                       because="REST name")
                expect(2, {"command": "gh api repos/o/r/pulls/7/reviews --input body.json"},
                       "...nor with --input, which also makes it a write",
                       because="REST name")
                expect(0, {"command": "gh api repos/o/r/pulls/7/reviews"},
                       "...but READING the reviews is what await-review.sh does")
                # The THIRD spelling. A GraphQL mutation carries no
                # `/pulls/N/reviews` path, so the rule above never sees it --
                # and it creates the same review record. Found by the
                # independent review of the change that added the other two.
                expect(2, {"command": "gh api graphql -f query='mutation{ addPullRequestReview(input:{pullRequestId:\"x\",event:COMMENT,body:\"y\"}){clientMutationId} }'"},
                       "...nor the GraphQL mutation that does the same thing",
                       because="third name")
                expect(2, {"command": "gh api graphql -f query='mutation{ submitPullRequestReview(input:{pullRequestReviewId:\"x\",event:COMMENT}){clientMutationId} }'"},
                       "...nor submitting one that was left pending",
                       because="third name")
                expect(0, {"command": "gh api graphql -F id=x -f query='mutation($id:ID!){ resolveReviewThread(input:{threadId:$id}){clientMutationId} }'"},
                       "...but resolving a thread is what resolve-thread.sh sends")
                # ...and a global option must not walk past any of it.
                expect(2, {"command": "gh -R owner/repo pr review 7 --comment --body x"},
                       "...nor `gh -R owner/repo pr review`, which read as a different subcommand",
                       because="does not submit")
                expect(2, {"file_path": os.path.join(root, HOOK_REL)},
                       "a fleet worktree cannot rewrite its own guards", tool="Edit",
                       because="enforcement layer")
                expect(0, {"file_path": os.path.join(root, ".claude/skills/x/SKILL.md")},
                       "...but skills stay advisory even there", tool="Edit")

                # Every path in SELF_PROTECTED, not just the hook. Dropping
                # settings.local.json from that tuple used to leave every
                # assertion here green; it is the sharp one, because it is
                # gitignored and a permission rule written into it appears in
                # no diff. Moved here from evals/lint.sh (#98) so that deleting
                # them is itself a change to the enforcement layer, which never
                # auto-merges -- parked in lint.sh they could be removed by a
                # PR that merged itself.
                # `because` on each, because exit 2 alone would also be
                # satisfied by the secrets branch: settings.local.json is
                # gitignored and holds permission rules, so it is one plausible
                # edit away from being denied as a secret instead. That would
                # keep these green while making the file unwritable in a
                # hand-opened worktree too, where it has to stay editable.
                for rel in (SETTINGS_REL, LOCAL_SETTINGS_REL):
                    expect(2, {"file_path": os.path.join(root, rel)},
                           f"...nor {rel}", tool="Edit", because="enforcement layer")
                    expect(2, {"command": "echo x > " + rel},
                           f"...nor {rel} from the shell", because="enforcement layer")

                # ...and the same three through a path a `cd` has shortened,
                # which is the whole of #139: the marker's own prefix is what
                # the `cd` consumed, so nothing about `hooks/guard.py` looks
                # like the enforcement layer until the prefix is put back.
                for rel in (HOOK_REL, SETTINGS_REL, LOCAL_SETTINGS_REL):
                    expect(2, {"command": "cd .claude && cp /tmp/x " + rel.split("/", 1)[1]},
                           f"...nor {rel} after a cd, where the path is relative")
                expect(2, {"command": "cd .claude/hooks && sed -i '' s/deny/allow/ guard.py"},
                       "...nor two levels down, where only the basename is left")
                expect(2, {"command": "cd .claude && cd hooks && cat > guard.py"},
                       "...nor a cd reached in two steps")
                expect(2, {"command": "cd .claude/hooks && cd .. && cp /tmp/x settings.json"},
                       "...and .. walks back up rather than giving up")
                expect(0, {"command": "cd .claude && cat > notes.md"},
                       "...while an ordinary file under the same cd stays writable")
                expect(0, {"command": "cd $SOMEWHERE && cat > guard.py"},
                       "...and an unresolvable cd does not invent a path to blame")

                # The prefix was normalised and the written path was not, so a
                # dot-segment in the tail was enough to stop the marker matching
                # -- `./` is one keystroke from the case asserted above.
                expect(2, {"command": "cd .claude && cp /tmp/x ./hooks/guard.py"},
                       "...nor with a ./ in the path the cd left")
                expect(2, {"command": "cd .claude && cp /tmp/x .//hooks/guard.py"},
                       "...nor with a doubled slash")
                expect(2, {"command": "cd .claude/skills && cp /tmp/x ../hooks/guard.py"},
                       "...nor climbing back out of a deeper cd")
                # `bash -c` is a shape the guard already models; it started its
                # own prefix from scratch and so forgot the cd in front of it.
                expect(2, {"command": "cd .claude && bash -c 'cp /tmp/x hooks/guard.py'"},
                       "...nor when bash -c runs the write, inheriting the cd")
                # A redirection on the `cd` line writes before the directory
                # changes. Judging it needs the prefix in hand, not the new one.
                expect(2, {"command": "cd tmp > .claude/hooks/guard.py"},
                       "...nor a redirection attached to the cd itself")

                # The shell keeps its directory between tool calls, so the
                # prefix has to come from the payload as well as from the line.
                # `cd .claude/hooks` writes nothing and is allowed; the write
                # arrives in the next call with no `cd` in front of it at all.
                expect(2, {"command": "cat > guard.py"},
                       "...nor a write from a cwd the previous call left behind",
                       cwd=os.path.join(root, ".claude", "hooks"))
                expect(2, {"command": "cp /tmp/x ../settings.json"},
                       "...nor one that climbs out of that cwd",
                       cwd=os.path.join(root, ".claude", "hooks"))
                # ...while a cwd that is not itself protected stays ordinary.
                # `.claude/hooks/` is the wrong place to ask this: the whole
                # directory is protected, so a note written beside the guard is
                # blocked too, and rightly.
                expect(0, {"command": "cat > notes.md"},
                       "...while a write from an ordinary cwd is untouched",
                       cwd=os.path.join(root, "server"))
                expect(0, {"command": "cat > guard.py"},
                       "...and a cwd outside the repo is not ours to judge",
                       cwd="/tmp")

                # Exit 2 is not proof on its own: an unreadable payload exits 2
                # too. These pin the refusal to the branch that should produce
                # it -- the check evals/lint.sh had before the move.
                expect(2, {"command": "cd .claude && cp /tmp/x hooks/guard.py"},
                       "...and the refusal names the enforcement layer",
                       because="enforcement layer")
            finally:
                if os.path.exists(marker):
                    os.remove(marker)
                if had_marker:
                    os.rename(marker + ".selftest", marker)

    STOP_FILE, OWNED_DIR = saved
    return failures


# The project config the selftest runs against.
#
# Not the host repo's own `.autofleet/guard.json`: the rows above assert exact
# refusals, and a suite whose expectations come from whatever file happens to
# be on disk asserts nothing. This is a fixture, and it doubles as the worked
# example of what a project puts in that file.
SELFTEST_PROJECT = {
    "protected_paths": [
        {
            "path": "server/contract/captures/",
            "tail": "captures/",
            "reason": "the pinned API contract a test diffs a live probe against",
        }
    ],
    "secret_suffixes": ["/config.ini"],
    "secret_contains": ["/token.dat", "/device.dat"],
    "secret_tails": ["token.dat", "device.dat", "config.ini"],
}


def _install_selftest_project():
    """Put SELFTEST_PROJECT in place of whatever the host repo configured."""
    global PROJECT, PROTECTED_PATHS, PROTECTED_TAILS
    global SECRET_SUFFIXES, SECRET_CONTAINS, SECRET_TAILS
    PROJECT = SELFTEST_PROJECT
    PROTECTED_PATHS = tuple(
        (
            entry["path"],
            entry.get("tail", entry["path"].rstrip("/").rsplit("/", 1)[-1] + "/"),
            entry.get("reason", "protected by this project's .autofleet/guard.json"),
        )
        for entry in PROJECT["protected_paths"]
    )
    SECRET_SUFFIXES = ("/.env", ".env") + tuple(PROJECT["secret_suffixes"])
    SECRET_CONTAINS = tuple(PROJECT["secret_contains"])
    SECRET_TAILS = tuple(PROJECT["secret_tails"])
    PROTECTED_TAILS = (
        ".claude/hooks/",
        ".claude/settings.json",
        ".claude/settings.local.json",
        "workflows/unblock.yml",
    ) + tuple(tail for _, tail, _ in PROTECTED_PATHS) + SECRET_TAILS


def selftest():
    """Every assertion below, run against a fleet state this function controls.

    The stateless cases assert what the guard does for an ordinary developer --
    "an ordinary push is fine", "the guards are writable by hand". Run with the
    real fleet directory those are not merely untrue inside a fleet worktree,
    they are untrue BY DESIGN: that is what _stateful_checks exercises
    separately, with a throwaway fleet it builds itself.

    Left alone, the selftest therefore passed on a laptop and failed inside every
    agent's worktree, which is where it matters most -- `ctest -R agent.config`
    red for every agent all night, passing only on CI runners that are nobody's
    fleet. A test that is red where the work happens teaches people to ignore a
    red suite.

    So: point the fleet at an empty directory for the duration. Nothing is owned,
    nothing is stopped, and each case asserts the one thing it says it does.
    """
    import tempfile

    global STOP_FILE, OWNED_DIR
    saved = (STOP_FILE, OWNED_DIR)
    _install_selftest_project()
    with tempfile.TemporaryDirectory() as empty:
        STOP_FILE = os.path.join(empty, "STOP")
        OWNED_DIR = os.path.join(empty, "worktrees")
        try:
            return _selftest_body()
        finally:
            STOP_FILE, OWNED_DIR = saved


def _selftest_body():
    failures = 0
    for tool, tool_input, want, what in SELFTEST:
        try:
            main({"tool_name": tool, "tool_input": tool_input})
            got = 0
        except SystemExit as exc:
            got = exc.code
        if got != want:
            print(f"FAIL: {what} (expected exit {want}, got {got})", file=sys.stderr)
            failures += 1
        else:
            print(f"  ok: {what}")
    failures += _stateful_checks()
    if failures:
        print(f"{failures} guard assertion(s) failed", file=sys.stderr)
        return 1
    print(f"{len(SELFTEST) + _stateful_ran} guard assertions hold")
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        sys.exit(selftest())
    try:
        raw = sys.stdin.read()
        parsed = json.loads(raw)
    except Exception:
        deny(
            "Blocked: .claude/hooks/guard.py could not read this tool call, so it "
            "cannot tell\n"
            "whether it is allowed. Refusing rather than allowing an unexamined action."
        )
    if not isinstance(parsed, dict):
        deny("Blocked: .claude/hooks/guard.py got a tool call that is not an object.")
    sys.exit(main(parsed))
