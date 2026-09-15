#!/usr/bin/env python3
"""Decide whether a pull request may merge itself.

`.github/workflows/merge-gate.yml` runs this as the one required check that
`gh pr merge --auto` waits on. Everything the flow promises about a PR is
asserted here, in one deterministic place, rather than trusted to the agent that
produced it:

  1. it was reviewed LOCALLY before it was pushed -- both passes, findings in
     the body;
  2. an independent review exists on the CURRENT head, so pushing a fix
     invalidates it and a re-review is required -- from a different account in
     the default `github` mode, or from the dispatcher's own reviewer in
     `local` mode, which `review_mode()` explains;
  3. that review's latest word is not "changes requested";
  4. no review thread is still open -- and the thread list it read was
     complete, rather than the first page of one;
  5. it says which issue it closes, in a form GitHub will act on;
  6. a review that reports findings has been ANSWERED by the author, so the
     branch cannot merge out from under the fixes it asked for;
  7. it does not touch the enforcement layer, which never merges itself.

Point 6 exists because points 2 and 3 are not enough on their own. `gh pr merge
--auto` is armed the moment the PR is created -- deliberately, since that is
what stops a finished PR sitting green and unmerged (#90) -- and the independent
review only runs afterwards. `--request-changes` is caught by point 3, and an
inline finding is caught by point 4, but a review that returns nits as a
COMMENTED verdict in its BODY satisfies every one of them, so auto-merge fires
while the author is still editing. Four PRs went in that way -- #146, #154,
#159, #168 -- and the window is not the life of the PR but the minutes between
the review landing and the author's next push, which is exactly a full test
run. See `answered()` for what an answer is.

Point 3 reads the LATEST review per author rather than GitHub's
`reviewDecision`, and that is the whole trick. `reviewDecision` is sticky: once
a reviewer requests changes it stays CHANGES_REQUESTED until dismissed or until
that reviewer approves -- and this reviewer never approves, by design. A PR
whose findings were all addressed would sit blocked forever. Taking the latest
review instead lets a clean re-review supersede the old verdict on its own, with
no dismissal step and nothing waiting on a person.

    python3 .github/scripts/merge_gate.py <head-sha> <pr.json> <files.txt>

Exits 0 when the PR may merge, 1 when it may not, and prints why either way.
`--selftest` runs it against recorded shapes and needs no network.
"""

import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from issue_refs import CLOSING_KEYWORDS, closes  # noqa: E402

# Paths that never merge themselves. `.claude/**` is the enforcement layer --
# the guards and the settings that register them -- and `.github/workflows/**`
# can turn off the very checks gating this PR. Both change rarely, and a person
# merging them is the point. enforce_admins is off, so an admin can merge these
# by hand with this check red; nothing else can.
# `.github/scripts/` is in here for the same reason as the other two: this file
# IS the gate, so a PR that changes what "may merge" means must not be able to
# merge itself on the strength of its own new rules.
# Shorter than any real review and longer than "test", "lgtm" or a stray
# newline. A number rather than a heuristic, because the alternative is judging
# review quality, which this script cannot do and should not pretend to.
MIN_REVIEW_BODY = 40

# The same bar for the author's answer, and lower: an answer is a disposition,
# not a review. "Reworded it" is a real answer; "ok" is the acknowledgement
# equivalent of PR #95's one-word review, and it leaves a human reading the PR
# with nothing to check the disposition against.
MIN_ANSWER_BODY = 20

# What the reviewer says it found, and what the author says about it. Both are
# HTML comments so neither shows up in the rendered text a person reads.
#
# A trailer rather than a verdict type, because the verdict type cannot carry
# this: REVIEW.md sends anything Important to `--request-changes` and everything
# else to `--comment`, so "a COMMENTED review" spans both "five nits" and
# "nothing at all" -- the two cases that have to be told apart here. Asking the
# reviewer to state a number is one instruction; inferring it from prose is a
# heuristic over third-party text.
REVIEW_FINDINGS_RE = re.compile(r"<!--\s*review-findings:\s*(\d+)\s*-->", re.I)
ANSWER_RE = re.compile(r"<!--\s*review-answered\s+([0-9a-f]{6,40})\s*-->", re.I)

# How many of those findings were Important. The count above cannot answer it:
# REVIEW.md defines `review-findings: N` as Important PLUS Nit summed, so five
# nits and one data-loss bug arrive here as the same integer, and every reader
# downstream -- this gate, `await-review.sh`, the agent reading either -- has to
# treat them the same. It did. Measured on #85/#86/#88: every nit was answered
# with a commit, the commit moved the head, the head move invalidated the review
# that asked for it, and the dispatcher started another. #86 burned four reviews
# without one ever judging its current head.
#
# ABSENT IS NOT ZERO. A review written by an older brief has no trailer, and
# `None` means "did not say", which every caller here reads as today's
# behaviour: held until answered. Nothing that merges today stops merging.
REVIEW_IMPORTANT_RE = re.compile(r"<!--\s*review-important:\s*(\d+)\s*-->", re.I)

# What `scripts/fleet/review.sh` writes at the end of a review it submitted, and
# the only thing that separates it from the PR author's own `gh pr review`.
#
# It carries the head sha for the same reason `ANSWER_RE` does: the marker has to
# be worth no more than the commit it was written for. A body copied forward to a
# later push -- by hand, or by an agent reusing its own text -- would otherwise
# keep counting as the review of a commit nobody read.
LOCAL_REVIEW_RE = re.compile(
    r"<!--\s*independent-review:\s*local\s+([0-9a-f]{6,40})\s*-->", re.I
)

# What `scripts/fleet/validate.sh` writes, and the successor of the marker above.
#
# A VALIDATION IS NOT A REVIEW. The review judges a diff once, at PR-open; the
# validation judges whether that review's findings were addressed and whether
# the commits answering them broke anything. They are different jobs and they
# are told apart HERE, by this trailer, because they arrive through the same
# `gh pr review --comment` call -- which they do for one reason: `guard.py`
# already refuses `gh pr review` from a fleet-owned worktree, so the trailer is
# out of the reach of the agent it judges. A `gh pr comment` route would have
# been reachable, `answer-review.sh` needs that command, and a certificate an
# agent can write about itself certifies nothing.
#
# It carries the head sha for the same reason `LOCAL_REVIEW_RE` and `ANSWER_RE`
# do: a body carried forward to a later push must not keep certifying code
# nobody validated.
#
# The verdict is `pass` or `fail`, and ANYTHING ELSE IS NEITHER -- including a
# missing trailer. `validation_verdict()` returns None for all of them and
# `evaluate()` reads None as "not validated yet", which holds the PR. That is
# the fail-closed direction, and it is the one this trailer exists to take: a
# validator that crashed writes nothing at all, and nothing at all must not read
# as consent.
VALIDATED_RE = re.compile(
    r"<!--\s*validated:\s*([0-9a-f]{6,40})\s+([a-z]+)\s*-->", re.I
)

# How `.autofleet/config` spells the knob, in either of the two shapes a shell
# config file uses: a plain `AUTOFLEET_REVIEW_MODE=local`, and the
# `: "${AUTOFLEET_REVIEW_MODE:=github}"` form `scripts/fleet/config.sh` writes
# its defaults in. Deliberately a regex and not a shell parse: this runs in CI
# over a file from the base ref, and sourcing it would be running the host
# project's shell code inside the gate that judges the host project.
# WHAT THE SHELL WOULD BE LEFT HOLDING, and nothing more. Two ways to get that
# wrong, and this file has had both.
#
# TOO NARROW: `export X=v` and `X='v'` are ordinary lines in a file config.sh
# SOURCES, so a spelling this cannot see is a repository whose shell side runs
# the local reviewer while the gate discards what it submits -- every PR blocked
# forever on a review that has already been written.
#
# TOO WIDE: `: "${X:=v}"` is the mirror image, and it is the one that was here.
# config.sh sets its own default with that shape BEFORE sourcing
# `.autofleet/config`, so by the time a `:=` in the host config is reached the
# variable already holds `github` and the assignment does nothing at all. Reading
# it as `local` made this file the only reader that thought so: `fleet.sh` would
# start no reviewer, `review.sh` would exit 4, `fleet.sh status` would name the
# github reviewer -- and the gate would sit in the weaker mode waiting for a
# review nothing was going to write. A host copying the `: "${X:=v}"` style it
# sees all over config.sh gets exactly that, which is the failure this whole mode
# exists to remove. #23 is the underlying precedence bug.
#
# So: the shapes a host config can actually override a default with, and only
# those. evals/lint.sh asserts this file and the shell agree, spelling for
# spelling, rather than trusting the two to stay in step. Found by the
# independent review of this change.
# No `[ \t]*` after the `=`: bash has no assignment with a space there, so
# matching one would be strictly more permissive than the shell it models.
REVIEW_MODE_RE = re.compile(
    r"""^[ \t]*(?:export[ \t]+)?"""
    r"""AUTOFLEET_REVIEW_MODE=["']?([A-Za-z][A-Za-z0-9_-]*)""",
    re.M,
)
REVIEW_MODES = ("github", "local")

HUMAN_ONLY_PREFIXES = (".claude/", ".github/workflows/", ".github/scripts/")

# What the PR body has to show: the local pass CLAUDE.md requires before anything
# leaves a worktree. The `.autofleet/run/reviewed-<sha>` marker that gated the
# push is per-worktree and invisible from CI, so the body is what can actually be
# checked here.
#
# BOTH passes, because both RUN. This was cut to one on the branch that replaced
# the four-review loop, on the reasoning that `/implement` ran the mattpocock
# pass itself and a second overlapping review before the PR existed was cost
# with no reader. armaatus/autofleet#51 then moved both passes OUT of the
# agent's session and into `scripts/fleet/self-review.sh`, which runs them in
# processes of their own -- so the cost argument no longer applies and the second
# pass is one a person may read findings from.
#
# The two must agree or the gate is a lie: CLAUDE.md's finishing step says a body
# naming only one is refused, `self-review.sh` runs both, and for one commit this
# tuple required one. A body can then carry half the findings and merge.
LOCAL_PASSES = (
    ("/code-review", "a local /code-review pass"),
    ("mattpocock-skills:code-review",
     "a local /mattpocock-skills:code-review pass (standards, and spec-vs-diff)"),
)


def review_mode(root=None):
    """Which independent review this repository runs: "github" or "local".

    `github` is the default and the strong one: `.github/workflows/claude-review.yml`
    submits the review from its own account, so the reviewer is not the author by
    GitHub's own reckoning and `independent_reviews()` needs no marker to tell
    them apart.

    `local` is for a project with no CLAUDE_CODE_OAUTH_TOKEN, where that workflow
    no-ops and every PR would otherwise block forever on a review that cannot
    arrive. The dispatcher runs the reviewer on the machine instead
    (`scripts/fleet/review.sh`), and it signs in as the same GitHub account that
    opened the PR. So independence in that mode is CONTEXT-level -- a process
    that never saw the conversation which produced the diff -- and not
    IDENTITY-level. That is weaker, it is the whole trade, and
    docs/CONFIGURATION.md says so in the same words.

    READ FROM THE BASE REF, never the head. `.github/workflows/merge-gate.yml`
    checks out `pull_request.base.sha`, so a pull request cannot switch its own
    repository into the weaker mode as part of the change the mode is judging.
    The environment wins over the file only so that `--selftest` and
    `tests/test_review_mode.sh` can drive both modes without writing a config.

    A missing or unreadable file is `github`, which is the safe direction: it
    refuses PRs rather than admitting them. A base predating this change has no
    `.autofleet/config` in its sparse checkout at all, and it still evaluates.
    """
    # NOT lowercased, and no whitespace stripped after the `=` in the regex
    # below. `scripts/fleet/lib.sh`'s `fleet_review_mode` -- which is what the
    # dispatcher, review.sh and the status screen all ask -- matches the literal
    # string `local` and nothing else, because that is what the shell leaves in
    # the variable. Reading `LOCAL` as local made this file the only reader that
    # thought so, and `AUTOFLEET_REVIEW_MODE= local` is not an assignment bash
    # can make at all, so tolerating it modelled nothing. Either way the two
    # readers disagree, no reviewer starts, and every PR blocks forever on a
    # review nothing will write -- which is the failure this whole mode removes.
    # Found by the independent review; the SPELLINGS list in evals/lint.sh, whose
    # job was to catch exactly this, had neither variant in it.
    env = os.environ.get("AUTOFLEET_REVIEW_MODE") or ""
    if env in REVIEW_MODES:
        return env
    if root is None:
        root = os.path.dirname(os.path.dirname(os.path.dirname(
            os.path.abspath(__file__))))
    try:
        with open(os.path.join(root, ".autofleet", "config")) as fh:
            text = fh.read()
    except OSError:
        return "github"
    # THE LAST ASSIGNMENT, and then judged -- not the last RECOGNISED one.
    #
    # Searching backwards for something valid diverges from the shell in the
    # permissive direction: `...=local` followed by `...=gihtub` leaves every
    # shell consumer holding `gihtub` (so no reviewer ever runs) while this
    # returned `local` (so the gate would accept a marked self-review). Nothing
    # would produce one, but the rule judging the PR would be the weaker one.
    # Found by the local review of the change that added this.
    found = REVIEW_MODE_RE.findall(text)
    if not found:
        return "github"
    value = found[-1]
    return value if value in REVIEW_MODES else "github"


def independent_reviews(pull_request, head_sha):
    # `head_sha=None` means "on any head". Every caller that asks whether THIS
    # commit has been reviewed passes a sha; the one caller that asks whether the
    # pull request has ever been reviewed -- the guard that stops a validation
    # standing in for a review that never happened -- passes None, because the
    # whole point of the validation is that it merges a head the review did not
    # see.
    """The reviews on `head_sha` that could be an independent review, oldest first.

    Two of the gate's conditions on WHO reviewed, in one place the fleet's own
    scripts can import. `scripts/fleet/review-status.sh` and
    `scripts/fleet/await-review.sh` both answer "has this PR been reviewed yet?",
    and both used to paraphrase this -- every paraphrase drifted the same way,
    more permissive than the gate, so the local answer said yes on a PR
    `merge-gate` then refused (#114).

    A review by the PR's own author is not an independent review. GitHub refuses
    a self-`--approve` but permits a self-`--comment`, and `gh pr review` is on
    the agent's allowlist -- so without this the author could satisfy the
    independence requirement by reviewing itself. Replying to a review THREAD
    creates one of these too, with an empty body and the replier as its author,
    which is how an agent answering findings manufactured its own review.

    The review also has to be on this head, because pushing a fix invalidates
    the review of the commit before it. For a caller waiting on a review that
    condition is strictly stronger than any freshness cut-off it could compute:
    a review cannot be submitted against a commit that does not exist yet.

    IN `local` MODE the author test cannot be the one that decides, because the
    reviewer and the author are one GitHub account (see `review_mode()`). What
    stands in for it is `LOCAL_REVIEW_RE`: a review by the author counts only if
    it carries the marker for THIS head, and only `scripts/fleet/review.sh`
    writes that. The agent under review cannot write it itself --
    `.claude/hooks/guard.py` refuses `gh pr review` from a fleet-owned worktree,
    and the dispatcher runs the reviewer from the repo root, which is not one.

    That is a checklist gate rather than a proof, exactly as
    `scripts/fleet/record-review.sh` is, and it is opt-in per repository for that
    reason. A review by a DIFFERENT account still counts in `local` mode with no
    marker at all: turning the knob on adds a way to satisfy the requirement, it
    never takes the strong one away.
    """
    pr_author = ((pull_request.get("author") or {}).get("login") or "").lower()
    local = review_mode() == "local"

    def counts(review):
        who = ((review.get("author") or {}).get("login") or "").lower()
        if who != pr_author:
            return True
        if not local:
            return False
        markers = LOCAL_REVIEW_RE.findall(review.get("body") or "")
        # `head_sha=None` asks "has this pull request been independently
        # reviewed AT ALL", on any head -- see the docstring. The marker still
        # has to be there, because in `local` mode it is the only thing that
        # separates the reviewer's verdict from the author's; what is dropped is
        # WHICH head it names.
        if head_sha is None:
            return bool(markers)
        return any(head_sha.lower().startswith(m.lower()) for m in markers)

    # A VALIDATION IS NOT A REVIEW, and it arrives through the same `gh pr review`
    # call -- so without this the validator's own record would satisfy the
    # independence requirement it exists downstream of. In `github` mode it
    # arrives from an account that is not the author, which is all `counts()`
    # asks; the PR would then be "independently reviewed" by the thing that was
    # only ever meant to check the review had been answered. See VALIDATED_RE.
    #
    # WHAT MAKES A RECORD A VALIDATION IS ITS VERDICT, not a trailer appearing
    # anywhere in its body. `not VALIDATED_RE.search(...)` was the test, and
    # `VALIDATED_RE` matches inside a code fence as readily as at the end -- so a
    # reviewer that QUOTED one of this file's own fixtures had its review
    # silently dropped, the gate reported "no independent review", and the branch
    # was held with nothing saying why. A review of the change adding these
    # fixtures is exactly the review most likely to quote one.
    #
    # `validation_verdict()` reads the LAST trailer and returns None for anything
    # it does not recognise, so a quoted example falls through to being read as
    # the ordinary review it is -- while a real `pass`/`fail` at the end is still
    # a validation and still not a second reviewer. The comment here claimed that
    # fallthrough while the code above never called the function.
    return sorted(
        (r for r in ((pull_request.get("reviews") or {}).get("nodes") or [])
         if counts(r)
         and (head_sha is None
              or (r.get("commit") or {}).get("oid") == head_sha)
         and not is_validation(r)),
        key=lambda r: r.get("submittedAt") or "",
    )


def is_validation(review):
    """Is this record a validation rather than a review?

    Both ride in a `gh pr review`, so the body is the only thing that tells them
    apart, and two readings of it are both wrong:

    `VALIDATED_RE.search(body)` -- a trailer ANYWHERE -- drops a review that
    merely QUOTES one. `VALIDATED_RE` matches inside a code fence as readily as
    at the end, so a reviewer citing one of this file's own fixtures had its
    review silently discarded, the gate reported "no independent review", and
    the branch was held with nothing saying why. The review most likely to quote
    a trailer is the review of the change that added it.

    `validation_verdict(review) is not None` -- a RECOGNISED verdict -- lets a
    record whose whole content is `<!-- validated: <sha> unknown -->` be read as
    an ordinary review, which is a garbled verdict becoming a silent second
    reviewer.

    So: POSITION, which is what REVIEW.md already requires of every trailer --
    "Nothing else follows them." A trailer is a validation when nothing but
    whitespace and other HTML comments comes after it. Prose after it means it
    was being quoted.
    """
    body = review.get("body") or ""
    last = None
    for m in VALIDATED_RE.finditer(body):
        last = m
    if last is None:
        return False
    rest = body[last.end():]
    # Other trailers may follow -- a validation body carries its own -- but text
    # may not.
    rest = re.sub(r"<!--.*?-->", "", rest, flags=re.S)
    return not rest.strip()


def validation_verdict(review):
    """`"pass"`, `"fail"`, or None for a review record that is not a validation.

    None spans three different things -- an ordinary review, a validation whose
    trailer says something this does not recognise, and a validator that died
    before writing one -- and `evaluate()` treats all three the same: not
    validated. Collapsing them is deliberate. The only alternative is to read an
    unrecognised verdict as consent, and the whole reason the verdict is written
    down is that silence must not be consent.
    """
    matches = VALIDATED_RE.findall(review.get("body") or "")
    if not matches:
        return None
    # The LAST match, for the reason `declared_findings()` reads the last
    # trailer: a validation of THIS repository quotes the format out of the
    # fixtures below, and reading the first one would let a quoted `pass` stand
    # in for a real `fail`.
    verdict = matches[-1][1].lower()
    return verdict if verdict in ("pass", "fail") else None


def validation(pull_request, head_sha):
    """The verdict of the newest validation submitted against `head_sha`.

    None when there is none -- which is every PR until the validator has run, and
    every PR whose head moved after it ran. The sha is checked twice, against the
    commit GitHub recorded the review on AND against the sha inside the trailer,
    because they answer different questions: the first is "which commit was this
    submitted on", the second is "which commit did the validator believe it was
    judging". A body copied forward satisfies the first and fails the second.
    """
    newest = None
    for r in ((pull_request.get("reviews") or {}).get("nodes") or []):
        if (r.get("commit") or {}).get("oid") != head_sha:
            continue
        # A QUOTED TRAILER IS NOT A VERDICT, and this read one as a `pass`: a
        # reviewer citing `<!-- validated: <head> pass -->` in its prose handed
        # the gate a passing validation of the head it was reviewing, which
        # discharged the answer requirement its own findings had just created.
        # Same defect as in `independent_reviews`, one function over, and found
        # by the fixture added for that one.
        if not is_validation(r):
            continue
        verdict = validation_verdict(r)
        if verdict is None:
            continue
        # THE SAME TRAILER THE VERDICT CAME FROM, which is the last one. `any(...)`
        # over every match was the test, so a body whose last trailer said `pass`
        # on an older sha, with the current head named in some earlier quoted
        # example, satisfied both halves -- and the docstring above promises the
        # opposite ("a body copied forward satisfies the first and fails the
        # second"). One trailer answers both questions or neither does.
        matches = VALIDATED_RE.findall(r.get("body") or "")
        if not head_sha.lower().startswith(matches[-1][0].lower()):
            continue
        if newest is None or (r.get("submittedAt") or "") >= (newest[0].get("submittedAt") or ""):
            newest = (r, verdict)
    return newest[1] if newest else None


def reviews_on_pr(pull_request):
    """Every record on the PR that is a REVIEW rather than a validation.

    Both ride in a `gh pr review`, so `VALIDATED_RE` is what tells them apart --
    see the comment on it. Three callers want this set and each used to filter
    inline; the third disagreed with the other two about whether an unrecognised
    verdict counts, which is the drift this function exists to stop.
    """
    return [r for r in ((pull_request.get("reviews") or {}).get("nodes") or [])
            if not is_validation(r)]


def reviewed_sha(pull_request):
    """The commit the newest substantive review judged, or None.

    The validator's scope is the diff SINCE THAT COMMIT and nothing else, and
    working it out is not something a prompt should be asked to do from the PR
    page: `gh pr view --json reviews` does not carry the commit a review was
    submitted against. So the drivers read it from here and state it.
    """
    newest = None
    for r in reviews_on_pr(pull_request):
        if not is_substantive(r):
            continue
        if newest is None or (r.get("submittedAt") or "") >= (newest.get("submittedAt") or ""):
            newest = r
    return ((newest or {}).get("commit") or {}).get("oid") or None


def needs_validation(pull_request, head_sha):
    """Whether this PR is waiting on a validation of `head_sha`.

    Two conditions, and the second is what keeps the best case at ONE post-PR
    agent run:

    NOTHING IS VALIDATED ON THIS HEAD yet -- a `pass` or a `fail` both count as
    answered, because a `fail` is waiting on the author, not on another
    validator. The next validation comes after the next push, which is a new
    head and a fresh question.

    AND SOME REVIEW ON THIS PULL REQUEST DECLARED FINDINGS. The validator's job
    is "were the findings addressed, and did the commits answering them break
    anything". A review that found nothing leaves it nothing to do, and a PR that
    merges on a clean review has cost one review and no validation at all.

    Any review on ANY head, not just the current one -- the whole reason this
    phase exists is that the commit answering the findings moves the head out
    from under the review that asked for them.

    `scripts/fleet/validate.sh` asks this rather than deciding for itself, for
    the reason `review.sh` asks `independent_reviews()`: three paraphrases of
    "what counts" drifted apart once already (#114), always in the permissive
    direction.
    """
    if validation(pull_request, head_sha) is not None:
        return False
    reviews = reviews_on_pr(pull_request)
    if not reviews:
        return False          # nothing has been reviewed; a review comes first
    # THE HEAD MOVED OUT FROM UNDER THE REVIEW. Whatever that review found, the
    # gate now wants a verdict on a commit no review judged and no second review
    # is coming -- so the validation is the only thing that can ever satisfy it.
    #
    # This case is not about findings at all, and reading it as though it were
    # is a permanent silent hold: a pull request whose review found NOTHING, then
    # rebased or pushed a CI fix, wants no validation by the findings test, gets
    # no second review by the cap, and blocks forever with nothing saying why.
    if not any((r.get("commit") or {}).get("oid") == head_sha for r in reviews):
        return True
    # ...and on the reviewed head itself, only findings are worth an agent. A
    # review that found nothing leaves nothing to check, and a PR that merges on
    # a clean review costs one review and no validation at all.
    for r in reviews:
        found = declared_findings(r)
        if found is not None and found > 0:
            return True
    return False


def is_substantive(review):
    """Whether a review record carries anything a person could act on.

    A review RECORD is not a review. PR #95 merged on one whose entire body was
    the word "test": the reviewer posted it at 02:45:34, the gate went green 13
    seconds later, and the real review -- 3812 characters, CHANGES_REQUESTED --
    arrived at 03:01, six minutes after the code was already on main.

    So a review has to carry a body with substance, or at least one inline
    comment. Empty COMMENTED records are routine and harmless in themselves --
    every thread reply creates one -- but they must not be what satisfies the
    independence requirement, nor what a waiting agent is handed as "the review".

    The bar is deliberately low. It is here to catch nothing-at-all, not to judge
    quality, which no substring test can do.
    """
    return (len((review.get("body") or "").strip()) >= MIN_REVIEW_BODY
            or ((review.get("comments") or {}).get("totalCount") or 0) > 0)


def declared_findings(review):
    """How many findings the review says it left, or None if it did not say.

    `.github/workflows/claude-review.yml` instructs the reviewer to end every
    body with `<!-- review-findings: N -->` and REVIEW.md documents it, so this
    is a promise the flow makes rather than a guess about phrasing. A review
    without one has NOT said it is clean, and `answered()`'s caller reads it
    that way -- see the asymmetry there.
    """
    # The LAST one, not the first. REVIEW.md and the review prompt both put the
    # trailer at the END of the body, and a review of THIS repository quotes
    # fixtures full of the thing -- `merge_gate.py`'s own selftest carries five
    # of them. Reading the first match would let a quoted `0` stand in for a
    # real count of 3, which fails OPEN: straight back into the race this
    # condition exists to close. Found in review of this PR.
    matches = REVIEW_FINDINGS_RE.findall(review.get("body") or "")
    return int(matches[-1]) if matches else None


def declared_important(review):
    """How many of the findings the review called Important, or None.

    Read the LAST match for the same reason `declared_findings` does: a review
    of THIS repository quotes trailers out of the fixtures below, and reading
    the first one would let a quoted `0` stand in for a real count.

    None is not zero, and the difference is the whole safety of this trailer. A
    review written before the trailer existed says nothing, and a caller that
    read that as "no Important findings" would start clearing holds on reviews
    that never claimed to be clean. Callers here ask `== 0`, never `!= 0`, so
    None falls through to the behaviour that predates this.

    It is not cross-checked against `declared_findings`. `M > N` is a reviewer
    that miscounted, and the honest thing to do with a miscount is nothing:
    every use below is a nit-only SHORTCUT, and `M > 0` -- coherent or not --
    declines the shortcut.
    """
    matches = REVIEW_IMPORTANT_RE.findall(review.get("body") or "")
    return int(matches[-1]) if matches else None


def answer_marker(head_sha):
    """The marker an answer carries, in the one place that also matches it.

    `scripts/fleet/answer-review.sh` asks this script for it rather than spelling
    it out, so the writer and the reader cannot drift into two formats -- which
    would be silent in the direction that matters: answers that satisfy nothing.
    """
    return f"<!-- review-answered {head_sha} -->"


def answer_substance(body):
    """What is left of an answer once its marker is stripped.

    `MIN_ANSWER_BODY` measures THIS, and `scripts/fleet/answer-review.sh` calls it
    rather than trimming its own way -- it used to count non-whitespace
    characters, which is a different number, so the writer could refuse an
    answer the reader would have taken. Found in review of this PR.
    """
    return ANSWER_RE.sub("", body or "").strip()


def answered(pull_request, head_sha, review):
    """Whether the PR's author has answered this review, on this head, since it.

    An answer is an issue comment carrying `<!-- review-answered <head-sha> -->`
    and something a person can read, written by the PR's author after the review
    was submitted. `scripts/fleet/answer-review.sh` posts them; the marker is not
    meant to be typed by hand.

    Three conditions, each for its own failure:

    BY THE AUTHOR, because the review job holds `pull-requests: write` and can
    comment -- the same hole `independent_reviews()` closes at the other end,
    where a reply to a thread was manufacturing the review it was replying to.

    ON THIS HEAD, because an answer is invalidated by a push for the same reason
    the review is: round one's disposition is not round two's.

    AFTER THE REVIEW, because one head can legitimately collect two reviews --
    claude-review.yml fires on `review_requested` as well as on `synchronize` --
    and an answer written before the second one existed cannot be about it.
    Without this the sha alone would let round one's answer stand over findings
    that arrived later on the same commit.

    It does not, and cannot, check that the findings were FIXED. "Addressed
    them" and "said it will not" are the same answer here: what this asserts is
    that somebody read them and decided before the branch went in.
    """
    author = ((pull_request.get("author") or {}).get("login") or "").lower()
    if not author:
        # No author, no answer. Reachable only from a payload that did not ask
        # for one -- and treating "cannot tell who the author is" as "anyone may
        # answer" would make the marker satisfiable by the reviewer itself.
        return False
    since = review.get("submittedAt") or ""
    for comment in ((pull_request.get("comments") or {}).get("nodes") or []):
        if ((comment.get("author") or {}).get("login") or "").lower() != author:
            continue
        body = comment.get("body") or ""
        # The LAST marker, for the same reason `declared_findings()` reads the
        # last trailer: an answer that quotes the format before giving the real
        # one -- explaining it to a human, or answering a finding about it --
        # would otherwise be judged on the quoted sha. This one fails CLOSED,
        # which is why it is a nit rather than the hole the other was: a correct
        # answer is read as no answer and the PR stays held. Found by the
        # independent review of this PR.
        found = list(ANSWER_RE.finditer(body))
        # A PREFIX, because `scripts/fleet/answer-review.sh` writes the full sha but
        # a person answering by hand writes the short one they were shown. Six
        # hex digits of a named PR's head is not a collision anybody can reach.
        if not found or not head_sha.lower().startswith(found[-1].group(1).lower()):
            continue
        if (comment.get("createdAt") or "") <= since:
            continue
        if len(answer_substance(body)) < MIN_ANSWER_BODY:
            continue
        return True
    return False


def thread_list_is_complete(pull_request):
    """Whether this payload's review threads are ALL of the PR's review threads.

    A page is not the list. Both readers ask for `reviewThreads(first:100)`, so
    on a longer PR the newest threads -- the ones most likely to still be open --
    fall off the end, and every thread that did come back can be resolved while
    an open one sits on page two. `.github/scripts/pr_payload.sh` pages through
    them so this is normally true; it is false when the paging ran out.

    Here rather than in each caller for the same reason the query is:
    `resolve-thread.sh` also has to decide whether "no thread is left" is a
    thing it may say, and a second copy of that judgement is a second place for
    it to drift.
    """
    threads = pull_request.get("reviewThreads") or {}
    page = threads.get("pageInfo")
    # A MISSING pageInfo is "cannot tell", not "complete". Defaulting the other
    # way is fail-open on the one property this exists to make fail closed: a
    # caller that fetched the threads without asking whether there were more
    # would be told its half-list was whole. Nothing reaches this today --
    # pr_payload.sh always sets it -- and that is exactly when a default is
    # cheap to get right.
    if not page:
        return False
    return not page.get("hasNextPage")


def unresolved_threads(pull_request):
    """The open review threads. Only meaningful if the list is complete."""
    return [t for t in ((pull_request.get("reviewThreads") or {}).get("nodes") or [])
            if not t.get("isResolved")]


def evaluate(head_sha, pull_request, changed_files):
    """Returns (ok, [lines to print])."""
    problems = []
    body = pull_request.get("body") or ""

    for needle, what in LOCAL_PASSES:
        if needle not in body:
            problems.append(
                f"the PR body does not show {what}. Nothing leaves a fleet worktree "
                "unreviewed, so its findings belong in the body where a human can "
                "read them."
            )

    # A PR that merges without a closing line closes nothing, so unblock.yml
    # relabels nothing and the fleet reports "nothing startable" with the work
    # available. CLAUDE.md's finishing steps have always said the wording
    # matters; until now nothing checked it. Any of GitHub's nine keywords
    # counts, because any of them is what GitHub itself acts on.
    if not closes(body):
        problems.append(
            "the PR body names no issue it closes. Add `Closes #N` -- so "
            "merging it unblocks whatever was waiting on that issue. GitHub "
            "accepts any of " + ", ".join(CLOSING_KEYWORDS) + ", in any case."
        )

    # THE VALIDATION, read before the review conditions because it is what
    # answers most of them.
    #
    # The loop is one review and then at most two validations. That shape has a
    # consequence this gate has to know about: the commit answering the review's
    # findings MOVES THE HEAD, and a review is bound to the commit it judged --
    # so from the first fix onward there is no review on the head and no second
    # review is coming. Every PR would block forever on a review that cannot
    # arrive, which is the failure `AUTOFLEET_REVIEW_MODE=local` exists to
    # remove, reintroduced one layer up.
    #
    # So a `pass` validation on the current head STANDS IN FOR the review: it is
    # the later, stricter statement -- this reader looked at the findings, the
    # answers, the commits since, and a full test run, and says the branch is
    # sound. What it does not stand in for is anything below: an unresolved
    # thread still holds the PR, and the enforcement-layer paths still need a
    # person. Those are deliberate, and `--selftest` has a row for each.
    verdict = validation(pull_request, head_sha)
    # A VALIDATION STANDS IN FOR A REVIEW; IT DOES NOT REPLACE ONE THAT NEVER
    # HAPPENED. `validate.yml` fires on every `synchronize`, so a push made
    # before the reviewer has run produces a perfectly honest `pass` -- it judged
    # the commits since the review, and there were no findings, because there was
    # no review. Read as satisfying the independence requirement, that merges a
    # branch nobody has looked at.
    #
    # Checked HERE rather than only in the drivers, because this is the condition
    # the merge actually turns on and a driver-side gate is one a second driver
    # can forget. `validate.yml` grew a `needs_validation` step of its own after
    # this comment was written and the comment still said it had none -- the
    # reason for a safety check must not misstate the system it guards, so it now
    # says what is actually true: two drivers, and this is the one place both of
    # them pass through.
    #
    # `independent_reviews`, NOT `reviews_on_pr`. The latter is every review
    # record including the author's own, and in `local` mode the author IS the
    # account that submits -- so a self-`--comment` plus a `pass` satisfied the
    # independence requirement this paragraph exists to state. The former applies
    # the mode's own independence test and the head check with it.
    if verdict == "pass" and not any(
            is_substantive(r) for r in independent_reviews(pull_request, None)):
        verdict = None
        problems.append(
            f"there is a validation of {head_sha[:8]} but no review for it to "
            "stand in for. A validation judges the commits written since a "
            "review -- with no review on this pull request it has judged a "
            "branch nobody has read, and it does not satisfy the independence "
            "requirement. Wait for the review."
        )
    if verdict == "fail":
        problems.append(
            f"the validation of {head_sha[:8]} failed. The validator judges two "
            "things -- were the review's findings addressed, and did the commits "
            "answering them break anything -- and it says no. Its body names "
            "which. Fix that, push, and the next validation judges the new head; "
            "`AUTOFLEET_VALIDATE_MAX` bounds how many times, and past it a person "
            "decides."
        )

    # Who counts, and what counts as a review -- both from the functions above,
    # which is what `review-status.sh` and `await-review.sh` import so that the
    # three answers cannot drift apart again.
    on_head = independent_reviews(pull_request, head_sha)
    substantive = [r for r in on_head if is_substantive(r)]
    if on_head and not substantive:
        problems.append(
            f"the only reviews on {head_sha[:8]} are empty -- no body worth "
            "reading and no inline comment. A review record is not a review: "
            "PR #95 merged on one whose body was the word \"test\". Wait for the "
            "review job to actually submit its findings."
        )
    if not on_head and verdict == "pass":
        # Validated on this head: the review requirement is met by the thing that
        # succeeded it. Nothing to add to `problems` here -- and nothing below
        # this point is skipped, because the thread and protected-path refusals
        # are not review conditions.
        pass
    elif not on_head:
        # The last sentence depends on the mode, and it is read at exactly the
        # moment somebody is working out why their review did not count. In
        # `local` mode "a review by the author does not count" is false and sends
        # them to the wrong conclusion -- the missing marker is the likely cause.
        # Found by the local review of the change that added the mode.
        if review_mode() == "local":
            why = ("A review by this PR's own author counts here only if its body "
                   "ends with `<!-- independent-review: local " + head_sha[:8] +
                   "... -->`, which `scripts/fleet/review.sh` writes and nothing "
                   "else does.")
        else:
            why = "A review by this PR's own author does not count."
        problems.append(
            f"no independent review has been submitted against the current head "
            f"({head_sha[:8]}). Pushing a fix invalidates the previous one -- "
            "re-request review. " + why
        )
    else:
        # From `substantive`, NOT from `on_head`. The same reviewer filing a real
        # CHANGES_REQUESTED and then, later on the same head, an empty COMMENTED
        # record -- which is exactly what a review job that runs and submits
        # nothing produces -- would otherwise make the empty one the review of
        # record, and `blocking` would come back empty with the findings never
        # addressed. That is PR #95's bug with the ordering reversed: an empty
        # record standing in for a review, arriving after instead of before.
        # Found in review of this PR.
        #
        # Oldest first, so the last write per author wins -- which is what
        # independent_reviews() already returns and `substantive` preserves,
        # being a filter over it. Sorting again here would be a second pass over
        # the same data for the same order.
        latest = {}
        for r in substantive:
            if r.get("state") in ("APPROVED", "CHANGES_REQUESTED", "COMMENTED"):
                latest[(r.get("author") or {}).get("login") or "?"] = r
        blocking = sorted(w for w, r in latest.items()
                          if r.get("state") == "CHANGES_REQUESTED")
        if blocking:
            problems.append(
                "the latest review from " + ", ".join(blocking) + " still requests "
                "changes. Address it and re-request review; a clean re-review "
                "supersedes it."
            )

        # ...and the same for a review that asked for nothing in particular but
        # still found something. A CHANGES_REQUESTED is caught above and an
        # inline finding is caught by the thread list; a nit in the BODY of a
        # COMMENTED review is caught by neither, and it merged four PRs out from
        # under their authors. See the module docstring.
        #
        # Only the reviews still standing -- one already superseded by a later
        # review on the same head has been answered by that review's existence,
        # and requiring an answer to it would deadlock a PR whose second review
        # was clean.
        for who, review in sorted(latest.items()):
            if review.get("state") == "CHANGES_REQUESTED":
                continue  # said above, with the remedy that belongs to it
            if review.get("state") == "APPROVED":
                # An approval asks for nothing, so there is nothing to answer.
                #
                # It is also the one verdict here that only a PERSON can give:
                # `claude-review.yml` tells the reviewer never to `--approve`,
                # and GitHub refuses a self-approval. Nothing asks a human for a
                # findings trailer, so without this a maintainer's written
                # approval reads as "did not say what it found" and holds the PR
                # -- trapping the one action that moves such a PR forward, on a
                # repository where `enforce_admins` is off precisely so it can.
                # Found by the independent review of this PR.
                continue
            found = declared_findings(review)
            if found == 0:
                # #90's property: a review that reports nothing needs no answer,
                # so the PR still merges with nobody watching. This is the whole
                # reason the requirement is conditional rather than an
                # unconditional "the agent declares done", which would put a
                # finished PR back to waiting on an agent that may be gone.
                continue
            # A `pass` validation on this head is a stronger statement than the
            # author's own answer: an independent reader saying the findings were
            # addressed, having read the answer AND the commits since.
            if verdict == "pass":
                continue
            important = declared_important(review)
            # THE AUTHOR'S WORDS CLEAR A SUGGESTION-ONLY REVIEW, AND NOTHING
            # MORE. `answered()` cannot tell "fixed it" from "I disagree" -- it
            # asserts only that somebody read the findings and decided -- and
            # that was the right bar when a second reviewer was coming to see
            # what the decision produced. One review per pull request removes
            # that reader, so whatever an answer can close here, nothing else
            # will catch.
            #
            # So above zero Important, the answer is necessary and not
            # sufficient: the validator has to agree. REVIEW.md states the same
            # rule from the reviewer's side and validator.md from the
            # validator's; this is the half that enforces it.
            #
            # `None` is "did not say", not zero -- a review written before the
            # trailer existed falls through to the behaviour that predates this,
            # which is what every other reader of this trailer does.
            if answered(pull_request, head_sha, review) and important != 0 \
                    and important is not None:
                problems.append(
                    f"the review from {who} reports {important} finding(s) it "
                    "called Important, and this PR's author has answered in "
                    "words. That clears a Suggestion; it does not clear these. "
                    "An Important finding is fixed, or a validation says why it "
                    "did not need to be -- there is no second reviewer behind "
                    "this one, so nothing else will catch what an answer closes. "
                    "Push the fix, and the validator judges the new head."
                )
                continue
            if answered(pull_request, head_sha, review):
                continue
            # A nit-only review gets a different sentence, not a different
            # decision. The hold is the same one; what changes is that the
            # remedy stops reading as "go fix these". Every agent that has hit
            # this message answered it with a commit, and a commit moves the
            # head, and a head move invalidates the review that asked for it --
            # so the fix bought a fresh full-diff review, which found one more
            # nit. Answering costs no commit and clears this line, and until
            # now nothing said so.
            problems.append(
                (f"the review from {who} reports {found} finding(s)"
                 + (", none of them Important" if important == 0 else "")
                 if found is not None else
                 f"the review from {who} does not say what it found -- no "
                 "`<!-- review-findings: N -->` trailer, so it is not read as "
                 "clean")
                + ", and this PR's author has not said what was done about "
                "them. Auto-merge is armed before the review runs, so without "
                "this the branch merges while the fixes are still being "
                "written. Address the findings, or say why you will not, and "
                "then:  ./scripts/fleet/answer-review.sh \"<what you did>\""
                # "clears this LINE", not "clears this". An unresolved review
                # thread is a separate refusal in the same list, and
                # `answer-review.sh` does not close threads -- so "the answer
                # clears it" is false for a PR that has one, which is the case
                # the reviewer's brief PREFERS. `await-review.sh` was corrected
                # for exactly this and the phrasing here was not; two files
                # saying different things about one fact is what that finding
                # was about. Found by the independent review, twice.
                + ("  --  and that alone clears this line: the answer is a "
                   "comment, not a commit. Pushing a nit fix instead moves the "
                   "head, which invalidates this review and buys another round. "
                   "Any unresolved thread is a separate line above, and the "
                   "answer does not close those."
                   if important == 0 else "")
            )

    if not thread_list_is_complete(pull_request):
        problems.append(
            "the review threads came back truncated, so whether any are still "
            "open cannot be answered from them. This is a refusal, not a "
            "failure: re-run this check, and if it persists the PR has more "
            "threads than the gather pages through."
        )
    unresolved = unresolved_threads(pull_request)
    if unresolved:
        problems.append(f"{len(unresolved)} review thread(s) are unresolved:")
        for t in unresolved[:10]:
            problems.append(f"    {t.get('path')}:{t.get('line')}")

    protected = sorted(
        f for f in changed_files if f.startswith(HUMAN_ONLY_PREFIXES)
    )
    if protected:
        problems.append(
            "this PR touches the enforcement layer, which never merges itself:"
        )
        for f in protected[:10]:
            problems.append(f"    {f}")
        problems.append(
            "    A repository admin merges it by hand -- enforce_admins is off, so "
            "that works with this check red."
        )

    if problems:
        return False, ["NOT READY TO MERGE:"] + ["  " + p for p in problems]
    return True, [
        "every gate holds: reviewed locally, reviewed independently on this head, "
        "no changes requested, no open threads."
    ]


SELFTEST = [
    (
        # A `pass` may only stand in for a review that EXISTS. Without this a
        # push before any review -- which `validate.yml` fires on, because it
        # triggers on every `synchronize` -- produces a validation of a branch
        # nobody has reviewed, and the gate reads it as reviewed.
        "a validation does not stand in for a review that never happened",
        "def456",
        {
            "body": "Closes #7\n/code-review\nmattpocock-skills:code-review\n",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-05T11:00:00Z",
                 "commit": {"oid": "def456"}, "author": {"login": "claude[bot]"},
                 "body": "Nothing was found in the commits since the review."
                 "\n<!-- validated: def456 pass -->"},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        ["src/app.c"],
        False,
        "github",
        "no independent review",
    ),
    (
        # An Important finding is FIXED, not argued away -- there is no second
        # reviewer behind this one, so whatever an answer can close here nothing
        # else will catch. The author's words clear a Suggestion-only review (the
        # row below); they do not clear this one on their own.
        "an Important finding is not cleared by the author's words alone",
        "abc123",
        {
            "body": "Closes #7\n/code-review\nmattpocock-skills:code-review\n",
            "author": {"login": "armaatus"},
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-05T10:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "claude[bot]"},
                 "body": "Important: the retry has no backoff and will spin."
                 "\n<!-- review-important: 1 -->\n<!-- review-findings: 1 -->"},
            ]},
            "comments": {"nodes": [
                {"author": {"login": "armaatus"}, "createdAt": "2026-09-05T11:00:00Z",
                 "body": "I disagree, the caller already backs off.\n"
                         "<!-- review-answered abc123 -->"},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        ["src/app.c"],
        False,
        "github",
        ("does not clear these", "there is no second reviewer"),
    ),
    (
        # ...and a validation IS what clears it. The validator read the findings,
        # the answer and the commits, and said so.
        "...and a pass validation does clear it",
        "abc123",
        {
            "body": "Closes #7\n/code-review\nmattpocock-skills:code-review\n",
            "author": {"login": "armaatus"},
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-05T10:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "claude[bot]"},
                 "body": "Important: the retry has no backoff and will spin."
                 "\n<!-- review-important: 1 -->\n<!-- review-findings: 1 -->"},
                {"state": "COMMENTED", "submittedAt": "2026-09-05T12:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "claude[bot]"},
                 "body": "The backoff argument holds; nothing else changed."
                 "\n<!-- validated: abc123 pass -->"},
            ]},
            "comments": {"nodes": [
                {"author": {"login": "armaatus"}, "createdAt": "2026-09-05T11:00:00Z",
                 "body": "I disagree, the caller already backs off.\n"
                         "<!-- review-answered abc123 -->"},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        ["src/app.c"],
        True,
    ),
    (
        # The validated trailer is the successor of the review, and it is what
        # lets a PR merge on a head the review never saw. Without this row the
        # whole one-review/two-validations shape is untested.
        "a validation pass on the head merges with no review on that head",
        "def456",
        {
            "body": "Closes #7\n/code-review\nmattpocock-skills:code-review\n",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-05T10:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "claude[bot]"},
                 "body": "The review of the commit before the fix, long enough to clear MIN_REVIEW_BODY."
                 "\n<!-- review-important: 1 -->\n<!-- review-findings: 3 -->"},
                {"state": "COMMENTED", "submittedAt": "2026-09-05T11:00:00Z",
                 "commit": {"oid": "def456"}, "author": {"login": "claude[bot]"},
                 "body": "Every finding from the review is addressed and the suite is green."
                 "\n<!-- validated: def456 pass -->"},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        ["src/app.c"],
        True,
    ),
    (
        "a validation fail on the head blocks",
        "def456",
        {
            "body": "Closes #7\n/code-review\nmattpocock-skills:code-review\n",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-05T11:00:00Z",
                 "commit": {"oid": "def456"}, "author": {"login": "claude[bot]"},
                 "body": "Finding 2 is not addressed and the suite is red on tests/test_brief.sh."
                 "\n<!-- validated: def456 fail -->"},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        ["src/app.c"],
        False,
        "github",
        "the validation of def456 failed",
    ),
    (
        # Same reason LOCAL_REVIEW_RE carries a sha: a body carried forward to a
        # later push must not keep certifying code nobody validated.
        "a validation naming an older commit does not count",
        "def456",
        {
            "body": "Closes #7\n/code-review\nmattpocock-skills:code-review\n",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-05T11:00:00Z",
                 "commit": {"oid": "def456"}, "author": {"login": "claude[bot]"},
                 "body": "Every finding from the review is addressed and the suite is green."
                 "\n<!-- validated: abc123 pass -->"},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        ["src/app.c"],
        False,
    ),
    (
        # THE OTHER DIRECTION, and it shipped broken: a reviewer that QUOTES a
        # validation trailer -- reviewing the change that added the format, which
        # is the likeliest reviewer of all -- had its review discarded, and the
        # PR was held reporting no review at all. The trailer here is inside
        # prose, which is what tells it from the row below.
        "a review that quotes a validation trailer is still a review",
        "def456",
        {
            "body": "Closes #7\n/code-review\nmattpocock-skills:code-review\n",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-05T11:00:00Z",
                 "commit": {"oid": "def456"}, "author": {"login": "claude[bot]"},
                 "body": "Important: the fixture `<!-- validated: def456 pass -->` is matched "
                 "inside a code fence, so this review would be dropped. Long enough for "
                 "MIN_REVIEW_BODY either way."
                 "\n<!-- review-important: 1 -->\n<!-- review-findings: 1 -->"},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        ["src/app.c"],
        False,
        "github",
        "has not said what was done about them",
    ),
    (
        # A validation is not a review. In github mode it arrives from an account
        # that is not the author, so without the exclusion it would satisfy the
        # independence requirement AND then demand an answer to its own findings.
        "a validation alone is not an independent review",
        "def456",
        {
            "body": "Closes #7\n/code-review\nmattpocock-skills:code-review\n",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-05T11:00:00Z",
                 "commit": {"oid": "def456"}, "author": {"login": "claude[bot]"},
                 "body": "Nothing was reviewed here; this record only carries a verdict."
                 "\n<!-- validated: def456 unknown -->"},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        ["src/app.c"],
        False,
        "github",
        "no independent review",
    ),
    (
        # A validation pass does not override an open thread. Threads were kept
        # precisely so the per-finding ledger survives; the validator resolves
        # the ones it is satisfied by, and what it leaves open still holds.
        "a validation pass does not clear an unresolved thread",
        "def456",
        {
            "body": "Closes #7\n/code-review\nmattpocock-skills:code-review\n",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-05T11:00:00Z",
                 "commit": {"oid": "def456"}, "author": {"login": "claude[bot]"},
                 "body": "Every finding from the review is addressed and the suite is green."
                 "\n<!-- validated: def456 pass -->"},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": [
                {"isResolved": False, "path": "src/app.c", "line": 12},
            ]},
        },
        ["src/app.c"],
        False,
        "github",
        "unresolved",
    ),
    (
        # BOTH local passes are required again: armaatus/autofleet#51 moved them
        # into `self-review.sh`, which runs both outside the agent's session, so
        # a body naming one carries half the findings. The row below is its
        # mirror -- one pass named, the other missing, either way round.
        "the body naming only the mattpocock pass is refused",
        "abc123",
        {
            "body": "Closes #7\n## Review findings\nmattpocock-skills:code-review\n",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-05T10:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "claude[bot]"}, "body": "A real review body, long enough to be worth reading and to clear MIN_REVIEW_BODY."
                 "\n<!-- review-findings: 0 -->"},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        ["src/app.c"],
        False,
        "github",
        "/code-review",
    ),
    (
        "the body still needs the mattpocock pass",
        "abc123",
        {
            "body": "Closes #7\n/code-review high\n",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-05T10:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "claude[bot]"}, "body": "A real review body, long enough to be worth reading and to clear MIN_REVIEW_BODY."
                 "\n<!-- review-findings: 0 -->"},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        ["src/app.c"],
        False,
        "github",
        "mattpocock-skills:code-review",
    ),
    (
        "a clean PR merges",
        "abc123",
        {
            "body": "Closes #7\n## Review findings\n/code-review high\nmattpocock-skills:code-review\n",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-05T10:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "claude[bot]"}, "body": "A real review body, long enough to be worth reading and to clear MIN_REVIEW_BODY."
                 "\n<!-- review-findings: 0 -->"},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        ["src/app.c"],
        True,
    ),
    (
        "no local review in the body",
        "abc123",
        {
            "body": "just some prose",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-05T10:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "claude[bot]"}, "body": "A real review body, long enough to be worth reading and to clear MIN_REVIEW_BODY."
                 "\n<!-- review-findings: 0 -->"},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        ["src/app.c"],
        False,
    ),
    (
        "the review is against an older commit",
        "def456",
        {
            "body": "Closes #7\n/code-review\nmattpocock-skills:code-review",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-05T10:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "claude[bot]"}, "body": "A real review body, long enough to be worth reading and to clear MIN_REVIEW_BODY."
                 "\n<!-- review-findings: 0 -->"},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        ["src/app.c"],
        False,
    ),
    (
        "changes requested, and nothing since",
        "abc123",
        {
            "body": "Closes #7\n/code-review\nmattpocock-skills:code-review",
            "reviews": {"nodes": [
                {"state": "CHANGES_REQUESTED", "submittedAt": "2026-09-05T10:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "claude[bot]"}, "body": "A real review body, long enough to be worth reading and to clear MIN_REVIEW_BODY."
                 "\n<!-- review-findings: 0 -->"},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        ["src/app.c"],
        False,
    ),
    (
        # The wedge `reviewDecision` would create, and the reason for reading the
        # latest review per author instead.
        "a clean re-review supersedes an earlier changes-requested",
        "abc123",
        {
            "body": "Closes #7\n/code-review\nmattpocock-skills:code-review",
            "reviews": {"nodes": [
                {"state": "CHANGES_REQUESTED", "submittedAt": "2026-09-05T10:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "claude[bot]"}, "body": "A real review body, long enough to be worth reading and to clear MIN_REVIEW_BODY."
                 "\n<!-- review-findings: 0 -->"},
                {"state": "COMMENTED", "submittedAt": "2026-09-05T11:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "claude[bot]"}, "body": "A real review body, long enough to be worth reading and to clear MIN_REVIEW_BODY."
                 "\n<!-- review-findings: 0 -->"},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        ["src/app.c"],
        True,
    ),
    (
        "an unresolved thread holds it",
        "abc123",
        {
            "body": "Closes #7\n/code-review\nmattpocock-skills:code-review",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-05T10:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "claude[bot]"}, "body": "A real review body, long enough to be worth reading and to clear MIN_REVIEW_BODY."
                 "\n<!-- review-findings: 0 -->"},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": [
                {"isResolved": False, "path": "src/app.c", "line": 42},
            ]},
        },
        ["src/app.c"],
        False,
    ),
    (
        "a self-review does not count as independent",
        "abc123",
        {
            "author": {"login": "armaatus"},
            "body": "Closes #7\n/code-review\nmattpocock-skills:code-review",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-05T10:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "armaatus"}, "body": "A real review body, long enough to be worth reading and to clear MIN_REVIEW_BODY."
                 "\n<!-- review-findings: 0 -->"},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        ["src/app.c"],
        False,
    ),
    (
        "...and a review from someone else does",
        "abc123",
        {
            "author": {"login": "armaatus"},
            "body": "Closes #7\n/code-review\nmattpocock-skills:code-review",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-05T10:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "claude[bot]"}, "body": "A real review body, long enough to be worth reading and to clear MIN_REVIEW_BODY."
                 "\n<!-- review-findings: 0 -->"},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        ["src/app.c"],
        True,
    ),
    (
        "the enforcement layer never merges itself",
        "abc123",
        {
            "body": "Closes #7\n/code-review\nmattpocock-skills:code-review",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-05T10:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "claude[bot]"}, "body": "A real review body, long enough to be worth reading and to clear MIN_REVIEW_BODY."
                 "\n<!-- review-findings: 0 -->"},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        [".claude/hooks/guard.py"],
        False,
    ),
    (
        "...nor a change to this gate itself",
        "abc123",
        {
            "body": "Closes #7\n/code-review\nmattpocock-skills:code-review",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-05T10:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "claude[bot]"}, "body": "A real review body, long enough to be worth reading and to clear MIN_REVIEW_BODY."
                 "\n<!-- review-findings: 0 -->"},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        [".github/scripts/merge_gate.py"],
        False,
    ),
    (
        "...and neither does a workflow change",
        "abc123",
        {
            "body": "Closes #7\n/code-review\nmattpocock-skills:code-review",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-05T10:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "claude[bot]"}, "body": "A real review body, long enough to be worth reading and to clear MIN_REVIEW_BODY."
                 "\n<!-- review-findings: 0 -->"},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        [".github/workflows/ci.yml"],
        False,
    ),
    (
        "a review with nothing in it does not count",
        "abc123",
        {
            "body": "Closes #7\n## Review findings\n/code-review high\nmattpocock-skills:code-review\n",
            "reviews": {"nodes": [
                # PR #95 merged on exactly this: body "test", no inline comments.
                {"state": "COMMENTED", "submittedAt": "2026-09-06T02:45:34Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "claude[bot]"},
                 "body": "test"},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        ["src/app.c"],
        False,
    ),
    (
        "...but an empty body with an inline comment does",
        "abc123",
        {
            "author": {"login": "armaatus"},
            "body": "Closes #7\n## Review findings\n/code-review high\nmattpocock-skills:code-review\n",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-06T02:45:34Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "claude[bot]"},
                 "body": "", "comments": {"totalCount": 1}},
            ]},
            # An empty body cannot carry a findings trailer, so this review is
            # answered instead -- which is the ordinary shape of one that put
            # everything inline.
            "comments": {"nodes": [
                {"author": {"login": "armaatus"},
                 "createdAt": "2026-09-06T03:00:00Z",
                 "body": "<!-- review-answered abc123 -->\n"
                         "Took the inline suggestion; the thread is resolved."},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        ["src/app.c"],
        True,
    ),
    (
        "an empty review does not supersede a real CHANGES_REQUESTED",
        "abc123",
        {
            "body": "Closes #7\n## Review findings\n/code-review high\nmattpocock-skills:code-review\n",
            "reviews": {"nodes": [
                {"state": "CHANGES_REQUESTED", "submittedAt": "2026-09-06T10:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "claude[bot]"},
                 "body": "A real review, long enough to clear MIN_REVIEW_BODY, "
                         "asking for changes that were never made."},
                # The review job re-ran and submitted nothing. Later, so it wins
                # on submittedAt -- and it must not.
                {"state": "COMMENTED", "submittedAt": "2026-09-06T10:30:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "claude[bot]"},
                 "body": ""},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        ["src/app.c"],
        False,
    ),
    (
        # The closing line is what unblock.yml acts on. Without it a PR merges,
        # closes nothing, and the fleet reports "nothing startable" while the
        # work it just finished sits waiting to free three more issues.
        "no closing line, so merging it would unblock nothing",
        "abc123",
        {
            "body": "## Review findings\n/code-review high\nmattpocock-skills:code-review\n",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-05T10:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "claude[bot]"}, "body": "A real review body, long enough to be worth reading and to clear MIN_REVIEW_BODY."
                 "\n<!-- review-findings: 0 -->"},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        ["src/app.c"],
        False,
    ),
    (
        # Any of GitHub's nine, in any case: what the gate requires and what
        # GitHub acts on have to be the same set, or the gate blocks a PR that
        # would have worked.
        "...and any keyword GitHub closes on satisfies it",
        "abc123",
        {
            "body": "resolved #7\n/code-review\nmattpocock-skills:code-review",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-05T10:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "claude[bot]"}, "body": "A real review body, long enough to be worth reading and to clear MIN_REVIEW_BODY."
                 "\n<!-- review-findings: 0 -->"},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        ["src/app.c"],
        True,
    ),
    (
        # The gate asked for the FIRST hundred threads and there are more. Every
        # thread it did get back is resolved, so without this it prints "no open
        # threads" from a page it knows is partial -- a verdict about a state it
        # never established.
        "a truncated thread page is not an answer",
        "abc123",
        {
            "body": "Closes #1\n/code-review\nmattpocock-skills:code-review",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-05T10:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "claude[bot]"}, "body": "A real review body, long enough to be worth reading and to clear MIN_REVIEW_BODY."
                 "\n<!-- review-findings: 0 -->"},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": True},
                              "nodes": [{"isResolved": True, "path": "a.cpp", "line": 1}]},
        },
        ["src/app.c"],
        False,
    ),
    (
        "...and a complete one still is",
        "abc123",
        {
            "body": "Closes #1\n/code-review\nmattpocock-skills:code-review",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-05T10:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "claude[bot]"}, "body": "A real review body, long enough to be worth reading and to clear MIN_REVIEW_BODY."
                 "\n<!-- review-findings: 0 -->"},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False},
                              "nodes": [{"isResolved": True, "path": "a.cpp", "line": 1}]},
        },
        ["src/app.c"],
        True,
    ),
    (
        # A payload that never said whether there were more threads. Nothing in
        # this repo produces one -- pr_payload.sh always sets pageInfo -- which
        # is why the old default read it as "complete" for sixteen fixtures
        # without anyone noticing. Fail closed: not knowing is not the same as
        # knowing there are none.
        "a thread list that does not say whether it is complete is not an answer",
        "abc123",
        {
            "body": "Closes #1\n/code-review\nmattpocock-skills:code-review",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-05T10:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "claude[bot]"}, "body": "A real review body, long enough to be worth reading and to clear MIN_REVIEW_BODY."
                 "\n<!-- review-findings: 0 -->"},
            ]},
            "reviewThreads": {"nodes": []},
        },
        ["src/app.c"],
        False,
    ),
    (
        # THE WINDOW THIS CONDITION EXISTS TO CLOSE. Auto-merge is armed when
        # the PR is created -- deliberately, because that is what stops a
        # finished PR sitting green and unmerged (#90) -- and the independent
        # review only runs afterwards. A review that returns nits as a
        # COMMENTED verdict satisfied every other gate here, so the branch
        # merged while its author was still editing. Four times: #146, #154,
        # #159, #168, and #154's took a real defect into main with it.
        "a review that found something is not merged until the author answers it",
        "abc123",
        {
            "author": {"login": "armaatus"},
            "body": "Closes #7\n/code-review\nmattpocock-skills:code-review",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-06T02:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "claude[bot]"},
                 "body": "Nit: the comment above sync_tick() says what, not why.\n"
                         "<!-- review-findings: 1 -->"},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        ["src/app.c"],
        False,
    ),
    (
        # "...or said it will not" is the same answer as "addressed them": both
        # are the author having read the findings and decided. The gate cannot
        # tell those apart and does not try -- what it requires is that somebody
        # answered before the branch went in.
        "...and merges once they have",
        "abc123",
        {
            "author": {"login": "armaatus"},
            "body": "Closes #7\n/code-review\nmattpocock-skills:code-review",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-06T02:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "claude[bot]"},
                 "body": "Nit: the comment above sync_tick() says what, not why.\n"
                         "<!-- review-findings: 1 -->"},
            ]},
            "comments": {"nodes": [
                {"author": {"login": "armaatus"},
                 "createdAt": "2026-09-06T02:06:00Z",
                 "body": "<!-- review-answered abc123 -->\n"
                         "Reworded the comment to say why. Nothing else was actionable."},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        ["src/app.c"],
        True,
    ),
    (
        # #90'S PROPERTY, KEPT. A review that says it found nothing needs no
        # answer, so the PR still merges with nobody watching -- which is the
        # whole reason auto-merge is armed early and the reason this condition
        # is conditional rather than an unconditional "the agent must declare
        # done".
        "a review that reports nothing still merges unattended",
        "abc123",
        {
            "author": {"login": "armaatus"},
            "body": "Closes #7\n/code-review\nmattpocock-skills:code-review",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-06T02:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "claude[bot]"},
                 "body": "Correctness: nothing. Portability: nothing. Spec: matches "
                         "the plan.\n<!-- review-findings: 0 -->"},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        ["src/app.c"],
        True,
    ),
    (
        # Fail CLOSED on a review that did not say. A reviewer that drops the
        # trailer is the ordinary way this degrades, and the cost of guessing
        # wrong is asymmetric: guessing "clean" re-opens the race the four PRs
        # above were lost to, guessing "found something" costs one command.
        "a review that does not say what it found is not assumed clean",
        "abc123",
        {
            "author": {"login": "armaatus"},
            "body": "Closes #7\n/code-review\nmattpocock-skills:code-review",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-06T02:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "claude[bot]"},
                 "body": "A real review body, long enough to be worth reading and to clear MIN_REVIEW_BODY."},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        ["src/app.c"],
        False,
    ),
    (
        # The answer is per-head for the same reason the review is: pushing a
        # fix invalidates both. Without the sha in it, the answer given to
        # round one would still be standing over round two's findings.
        "an answer to an earlier head does not answer this review",
        "def456",
        {
            "author": {"login": "armaatus"},
            "body": "Closes #7\n/code-review\nmattpocock-skills:code-review",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-06T03:00:00Z",
                 "commit": {"oid": "def456"}, "author": {"login": "claude[bot]"},
                 "body": "Important: the retry has no backoff.\n"
                         "<!-- review-findings: 1 -->"},
            ]},
            "comments": {"nodes": [
                {"author": {"login": "armaatus"},
                 "createdAt": "2026-09-06T03:10:00Z",
                 "body": "<!-- review-answered abc123 -->\n"
                         "Answered round one's findings on the previous commit."},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        ["src/app.c"],
        False,
    ),
    (
        # Same head, and still not an answer: claude-review.yml fires on
        # `review_requested` as well as on `synchronize`, so one commit can
        # legitimately collect a second review. An answer written before that
        # review existed cannot be about it.
        "an answer written before the review does not answer it",
        "abc123",
        {
            "author": {"login": "armaatus"},
            "body": "Closes #7\n/code-review\nmattpocock-skills:code-review",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-06T04:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "claude[bot]"},
                 "body": "Important: the retry has no backoff.\n"
                         "<!-- review-findings: 1 -->"},
            ]},
            "comments": {"nodes": [
                {"author": {"login": "armaatus"},
                 "createdAt": "2026-09-06T03:00:00Z",
                 "body": "<!-- review-answered abc123 -->\n"
                         "Answered the first review of this commit."},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        ["src/app.c"],
        False,
    ),
    (
        # The reviewer answering itself is the same hole `independent_reviews`
        # closes at the other end -- and it is reachable, because the review job
        # holds `pull-requests: write` and can comment.
        "an answer from anyone but the PR's author is not the author answering",
        "abc123",
        {
            "author": {"login": "armaatus"},
            "body": "Closes #7\n/code-review\nmattpocock-skills:code-review",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-06T02:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "claude[bot]"},
                 "body": "Important: the retry has no backoff.\n"
                         "<!-- review-findings: 1 -->"},
            ]},
            "comments": {"nodes": [
                {"author": {"login": "claude[bot]"},
                 "createdAt": "2026-09-06T02:06:00Z",
                 "body": "<!-- review-answered abc123 -->\n"
                         "Marking my own findings as dealt with."},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        ["src/app.c"],
        False,
    ),
    (
        # The one verdict a person can give here and the reviewer cannot, and
        # nothing asks a person for a trailer. Held for an answer, it would be
        # the approval itself that could not get the PR merged.
        "an approval asks for nothing, so there is nothing to answer",
        "abc123",
        {
            "author": {"login": "armaatus"},
            "body": "Closes #7\n/code-review\nmattpocock-skills:code-review",
            "reviews": {"nodes": [
                {"state": "APPROVED", "submittedAt": "2026-09-06T02:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "joris"},
                 "body": "Looks right, and the retry matches the pinned contract."},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        ["src/app.c"],
        True,
    ),
    (
        # A review of THIS repository quotes fixtures carrying the trailer --
        # every case in this list has one. Read from the front, a quoted `0`
        # stands in for the real count at the end, and the PR merges unanswered:
        # the race, reintroduced through the parser. Found in review of #170.
        "a trailer quoted inside a review body does not become its verdict",
        "abc123",
        {
            "author": {"login": "armaatus"},
            "body": "Closes #7\n/code-review\nmattpocock-skills:code-review",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-06T02:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "claude[bot]"},
                 "body": "The new fixture says `<!-- review-findings: 0 -->`, which "
                         "is right for what it stands for.\nImportant: the retry has "
                         "no backoff.\n<!-- review-findings: 1 -->"},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        ["src/app.c"],
        False,
    ),
    (
        # The mirror of the quoted-trailer case, on the answer side. An answer
        # that explains the format before giving the real one -- or answers a
        # finding ABOUT the format, which is how this was found -- must be
        # judged on the marker it ends with.
        "a marker quoted inside an answer does not become the answer's sha",
        "abc123",
        {
            "author": {"login": "armaatus"},
            "body": "Closes #7\n/code-review\nmattpocock-skills:code-review",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-06T02:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "claude[bot]"},
                 "body": "Important: the retry has no backoff.\n"
                         "<!-- review-findings: 1 -->"},
            ]},
            "comments": {"nodes": [
                {"author": {"login": "armaatus"},
                 "createdAt": "2026-09-06T02:06:00Z",
                 "body": "The marker is written `<!-- review-answered def456 -->` "
                         "for the head it answers.\nAdded the backoff.\n"
                         "<!-- review-answered abc123 -->"},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        ["src/app.c"],
        True,
    ),
    (
        # PR #95's lesson, one layer out: a record is not the thing. An answer
        # whose entire content is the marker says nothing a human reading the
        # PR could check the disposition against.
        "an answer that says nothing is not an answer",
        "abc123",
        {
            "author": {"login": "armaatus"},
            "body": "Closes #7\n/code-review\nmattpocock-skills:code-review",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-06T02:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "claude[bot]"},
                 "body": "Important: the retry has no backoff.\n"
                         "<!-- review-findings: 1 -->"},
            ]},
            "comments": {"nodes": [
                {"author": {"login": "armaatus"},
                 "createdAt": "2026-09-06T02:06:00Z",
                 "body": "<!-- review-answered abc123 -->\nok"},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        ["src/app.c"],
        False,
    ),
    # ------------------------------------------------------------ review mode
    #
    # A sixth field, and only these rows carry it: `review_mode()` reads the
    # environment before the file, so the runner below exports it around the row
    # and every other row keeps evaluating in the default `github` mode.
    (
        # The reason `local` mode exists. Without CLAUDE_CODE_OAUTH_TOKEN the
        # review workflow no-ops, the only account that can review is the one
        # that opened the PR, and every PR blocks forever on a review nothing
        # can submit. `scripts/fleet/review.sh` writes this marker.
        "in local mode, the author's own review counts when it carries the marker",
        "abc123",
        {
            "author": {"login": "armaatus"},
            "body": "Closes #7\n/code-review\nmattpocock-skills:code-review",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-10T10:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "armaatus"},
                 "body": "A real review body, long enough to be worth reading and to clear "
                         "MIN_REVIEW_BODY."
                         "\n<!-- review-findings: 0 -->"
                         "\n<!-- independent-review: local abc123 -->"},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        ["src/app.c"],
        True,
        "local",
    ),
    (
        # The marker is the whole of it. An agent that talked its way into a
        # `gh pr review --comment` on its own PR must not thereby have reviewed
        # it -- which is the hole the author test closes in `github` mode and
        # this row is what keeps closed in `local`.
        "in local mode, an unmarked self-review is still not a review",
        "abc123",
        {
            "author": {"login": "armaatus"},
            "body": "Closes #7\n/code-review\nmattpocock-skills:code-review",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-10T10:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "armaatus"},
                 "body": "A real review body, long enough to be worth reading and to clear "
                         "MIN_REVIEW_BODY."
                         "\n<!-- review-findings: 0 -->"},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        ["src/app.c"],
        False,
        "local",
    ),
    (
        # The marker names a commit, so it is worth no more than that commit.
        # A body carried forward to the next push would otherwise keep counting
        # as the review of code nobody read.
        "in local mode, a marker for another commit does not count",
        "abc123",
        {
            "author": {"login": "armaatus"},
            "body": "Closes #7\n/code-review\nmattpocock-skills:code-review",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-10T10:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "armaatus"},
                 "body": "A real review body, long enough to be worth reading and to clear "
                         "MIN_REVIEW_BODY."
                         "\n<!-- review-findings: 0 -->"
                         "\n<!-- independent-review: local def456 -->"},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        ["src/app.c"],
        False,
        "local",
    ),
    (
        # Turning the knob on is what admits it, and nothing else. A repository
        # that never opted in cannot be talked into the weaker rule by a body.
        "in github mode, the marker buys a self-review nothing",
        "abc123",
        {
            "author": {"login": "armaatus"},
            "body": "Closes #7\n/code-review\nmattpocock-skills:code-review",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-10T10:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "armaatus"},
                 "body": "A real review body, long enough to be worth reading and to clear "
                         "MIN_REVIEW_BODY."
                         "\n<!-- review-findings: 0 -->"
                         "\n<!-- independent-review: local abc123 -->"},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        ["src/app.c"],
        False,
        "github",
    ),
    (
        # And the strong route is never taken away. `local` ADDS a way to satisfy
        # the requirement; a review by another account still needs no marker.
        "in local mode, a review by another account needs no marker",
        "abc123",
        {
            "author": {"login": "armaatus"},
            "body": "Closes #7\n/code-review\nmattpocock-skills:code-review",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-10T10:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "claude[bot]"},
                 "body": "A real review body, long enough to be worth reading and to clear "
                         "MIN_REVIEW_BODY."
                         "\n<!-- review-findings: 0 -->"},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        ["src/app.c"],
        True,
        "local",
    ),
    (
        # THE FLOOR UNDER THE REVIEW LOOP, and the half of it that is NOT a
        # change in behaviour. `review-important: 0` does not discharge
        # anything on its own -- the author still has to answer. What the
        # trailer buys is the wording of the refusal, which is the only part of
        # this file an agent ever reads. Asserted because the tempting version
        # of this feature -- "nits merge themselves" -- is one `continue` away
        # from here, and it would put a reviewer's severity call in charge of
        # whether anybody looks at the answer at all.
        "a nit-only review still holds the PR until it is answered",
        "abc123",
        {
            "author": {"login": "armaatus"},
            "body": "Closes #7\n/code-review\nmattpocock-skills:code-review",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-06T02:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "claude[bot]"},
                 "body": "Nit: the comment above sync_tick() says what, not why.\n"
                         "<!-- review-important: 0 -->\n"
                         "<!-- review-findings: 1 -->"},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        ["src/app.c"],
        False,
        "github",
        ("none of them Important", "the answer is a comment, not a commit"),
    ),
    (
        # ...and clears on the answer ALONE, with no push. This is the path
        # #85, #86 and #88 all had open and none of them took:
        # `answer-review.sh` had never been run on any of them, so every nit
        # was answered with a commit, and every commit invalidated the review
        # that asked for it. Nothing in the machinery forbade this; nothing
        # said it was available either.
        "...and a comment discharges it -- the head does not move",
        "abc123",
        {
            "author": {"login": "armaatus"},
            "body": "Closes #7\n/code-review\nmattpocock-skills:code-review",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-06T02:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "claude[bot]"},
                 "body": "Nit: the comment above sync_tick() says what, not why.\n"
                         "<!-- review-important: 0 -->\n"
                         "<!-- review-findings: 1 -->"},
            ]},
            "comments": {"nodes": [
                {"author": {"login": "armaatus"},
                 "createdAt": "2026-09-06T02:06:00Z",
                 "body": "<!-- review-answered abc123 -->\n"
                         "Both are nits; filed as #99 rather than spent on a head move."},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        ["src/app.c"],
        True,
    ),
    (
        # ABSENT IS NOT ZERO. Every review submitted before this trailer
        # existed has no `review-important` line, and the failure mode to rule
        # out is the one that fails OPEN: a missing trailer read as "nothing
        # Important", quietly relaxing a PR nobody re-reviewed. `None` is not
        # `0`, the callers ask `== 0`, and this row is what says so.
        "a review with no review-important trailer behaves exactly as before",
        "abc123",
        {
            "author": {"login": "armaatus"},
            "body": "Closes #7\n/code-review\nmattpocock-skills:code-review",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-06T02:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "claude[bot]"},
                 "body": "Nit: the comment above sync_tick() says what, not why.\n"
                         "<!-- review-findings: 1 -->"},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        ["src/app.c"],
        False,
        "github",
        # The old wording, unchanged, and none of the new.
        ("reports 1 finding(s), and this PR's author has not said",
         "!none of them Important", "!not a commit"),
    ),
    (
        # A miscounted trailer declines the shortcut rather than being
        # arithmetic-checked. `declared_important` deliberately does not
        # cross-check M against N: the only thing M buys is a nit-only wording,
        # and any M above zero -- coherent with N or not -- is not nit-only.
        "an Important finding is not softened by the new trailer",
        "abc123",
        {
            "author": {"login": "armaatus"},
            "body": "Closes #7\n/code-review\nmattpocock-skills:code-review",
            "reviews": {"nodes": [
                {"state": "COMMENTED", "submittedAt": "2026-09-06T02:00:00Z",
                 "commit": {"oid": "abc123"}, "author": {"login": "claude[bot]"},
                 "body": "Important: the retry has no backoff and will spin.\n"
                         "<!-- review-important: 3 -->\n"
                         "<!-- review-findings: 1 -->"},
            ]},
            "reviewThreads": {"pageInfo": {"hasNextPage": False}, "nodes": []},
        },
        ["src/app.c"],
        False,
        "github",
        ("!none of them Important", "!not a commit"),
    ),
]


def selftest():
    failures = 0
    for row in SELFTEST:
        what, head, pr, files, want = row[:5]
        # `review_mode()` reads the environment before `.autofleet/config`, so
        # this is the same precedence a real run uses rather than a test-only
        # back door -- and a row with no mode runs in whatever the checkout says,
        # which for autofleet's own tree is now `local`. Set explicitly to
        # `github` so the rows written before the knob existed keep asserting
        # what they were written to assert.
        was = os.environ.get("AUTOFLEET_REVIEW_MODE")
        os.environ["AUTOFLEET_REVIEW_MODE"] = row[5] if len(row) > 5 else "github"
        try:
            got, lines = evaluate(head, pr, files)
        finally:
            if was is None:
                del os.environ["AUTOFLEET_REVIEW_MODE"]
            else:
                os.environ["AUTOFLEET_REVIEW_MODE"] = was
        # An optional 7th field: a substring the refusal has to contain.
        #
        # Most rows here assert only the verdict, and for most rules that is the
        # whole of the behaviour. It is not the whole of THIS one: the nit-only
        # branch deliberately does not change what the gate decides, only what it
        # says -- and what it says is the only part of this file an agent reads.
        # A row asserting `False` on a nit-only review passes just as well
        # against the code that predates the branch, which makes it no test at
        # all. Found while writing it.
        # A string, or a tuple of them -- and a string prefixed `!` must NOT
        # appear. The negative is not decoration: what distinguishes the
        # Important branch from the nit-only one is the ABSENCE of the shortcut
        # wording, and a check that can only assert presence cannot see a
        # refusal that offers a nit remedy for a data-loss bug.
        says = row[6] if len(row) > 6 else ()
        if isinstance(says, str):
            says = (says,)
        blob = "\n".join(lines)
        wrong = [w for w in says
                 if (w[1:] in blob if w.startswith("!") else w not in blob)]
        if got != want:
            print(f"FAIL: {what} (expected {want}, got {got})", file=sys.stderr)
            failures += 1
        elif wrong:
            print(f"FAIL: {what} (wrong wording: {wrong})", file=sys.stderr)
            print("\n".join("      " + line for line in lines), file=sys.stderr)
            failures += 1
        else:
            print(f"  ok: {what}")
    # `needs_validation()` is not reachable from the table above -- that drives
    # `evaluate()`, and this is what the DISPATCHER asks before it spends an
    # agent. Hard rule 3: a rule with no assertion is not shipped, and "should a
    # validator start" is a rule.
    def _review(body, oid="abc123"):
        return {"state": "COMMENTED", "submittedAt": "2026-09-05T10:00:00Z",
                "commit": {"oid": oid}, "author": {"login": "claude[bot]"},
                "body": body}

    clean = {"reviews": {"nodes": [_review("a review\n<!-- review-findings: 0 -->")]}}
    dirty = {"reviews": {"nodes": [_review("a review\n<!-- review-findings: 2 -->")]}}
    done = {"reviews": {"nodes": [
        _review("a review\n<!-- review-findings: 2 -->"),
        _review("a validation\n<!-- validated: def456 pass -->", "def456"),
    ]}}
    # ON THE QUERIED HEAD, deliberately. Off it, the head-moved rule below wants
    # a validation whatever the review said -- which is right, and is a different
    # assertion. What this one is about is a review that judged THIS commit and
    # did not say what it found.
    silent = {"reviews": {"nodes": [_review("a review with no trailer at all",
                                            "def456")]}}
    # A CLEAN review, and then a push. The review is bound to the commit it
    # judged, so the new head has none -- and no second review is coming. If this
    # does not want a validation, nothing can ever satisfy the gate again: a
    # rebase or a CI fix on a pull request whose review found nothing would hold
    # it forever, silently.
    moved = {"reviews": {"nodes": [_review("a clean review\n<!-- review-findings: 0 -->")]}}
    checks = [
        ("a clean review needs no validation -- the best case is one agent run",
         needs_validation(clean, "abc123"), False),
        ("a review with findings does", needs_validation(dirty, "def456"), True),
        ("...and stops needing one once the head is validated",
         needs_validation(done, "def456"), False),
        # A review that did not say what it found is held by `evaluate()` until
        # it is answered, and there is nothing for a validator to check against.
        # Starting one on it would spend an agent to say "no findings listed".
        ("a review that said nothing needs no validation",
         needs_validation(silent, "def456"), False),
        ("a clean review on THIS head needs no validation",
         needs_validation(clean, "abc123"), False),
        ("...but once the head moves out from under it, one is the only way out",
         needs_validation(moved, "def456"), True),
    ]
    for what, got, want in checks:
        if got != want:
            print(f"FAIL: {what} (expected {want}, got {got})", file=sys.stderr)
            failures += 1
        else:
            print(f"  ok: {what}")

    if failures:
        print(f"{failures} merge-gate assertion(s) failed", file=sys.stderr)
        return 1
    print(f"{len(SELFTEST) + len(checks)} merge-gate assertions hold")
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv[1:]:
        sys.exit(selftest())
    if len(sys.argv) != 4:
        print("usage: merge_gate.py <head-sha> <pr.json> <files.txt>  [--selftest]",
              file=sys.stderr)
        sys.exit(2)
    head_sha = sys.argv[1]
    payload = json.load(open(sys.argv[2]))
    pull_request = payload["data"]["repository"]["pullRequest"]
    with open(sys.argv[3]) as fh:
        files = [line.strip() for line in fh if line.strip()]
    ok, lines = evaluate(head_sha, pull_request, files)
    for line in lines:
        print(line)
    sys.exit(0 if ok else 1)
