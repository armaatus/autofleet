#!/usr/bin/env bash
# Covers the one thing install.sh does to a file the HOST owns.
#
# Everything else the installer writes is autofleet's: PAYLOAD is copied over,
# SEEDS are written once. `.gitignore` is neither -- it is the host project's own
# list, it must never be rewritten, and the payload nonetheless needs three lines
# in it. `scripts/fleet/` writes into `.autofleet/run/` (the push markers, the
# autostart log, and since armaatus/autofleet#51 the self-review findings and
# three transcripts per run), `env.sh` generates `.env`, and a review run by hand
# writes `/findings.md`, and `env.sh` writes `.env` and `.env.tmp*`. autofleet's
# own `.gitignore` names every one of them, which is
# exactly why nothing here ever noticed: in a host repo the first `git add -A`
# from a fleet agent sweeps a review marker, or a secret, into a commit.
#
#   test_install.sh ignores    the four lines are appended to a host's existing
#                              .gitignore, its own contents are untouched, and a
#                              file with no trailing newline does not have the
#                              first line welded onto its last pattern.
#   test_install.sh idempotent a second run adds nothing and reports the lines as
#                              already matching -- an installer whose re-run is
#                              not a no-op is one nobody re-runs.
#   test_install.sh dry        --dry-run writes nothing and still COUNTS what it
#                              would write. It printed "would add ..." followed
#                              by "Nothing was written", and a real run reported
#                              "0 written" having just edited a host-owned file.
#
# The other thing an upgrade does to a host is REMOVE -- `install.sh`'s RETIRED
# list, the files a v1 install left behind that v2 does not ship. That is a
# delete on somebody else's machine, so it gets the same two phases the append
# does:
#
#   test_install.sh retires     the v1 workflows are gone and named, the host's
#                               own workflows are untouched, and a re-run
#                               announces nothing.
#   test_install.sh retires_dry --dry-run deletes nothing and still says which
#                               file it would delete.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "  ok: $*"; }

WORK=""
cleanup() { [ -n "$WORK" ] && rm -rf "$WORK"; return 0; }
trap cleanup EXIT

# A host repo: a git repo that is not autofleet, with an ignore list of its own.
# `printf` WITHOUT a trailing newline, deliberately -- that is the case where a
# naive append lands on the end of somebody else's pattern and silently changes
# what it matches.
make_host() {
  WORK="$(mktemp -d)"; WORK="$(cd "$WORK" && pwd -P)"
  mkdir -p "$WORK/host"
  git -C "$WORK/host" init -q -b main
  printf 'node_modules/\n*.log' >"$WORK/host/.gitignore"
  git -C "$WORK/host" add -A
  git -C "$WORK/host" -c user.email=t@t -c user.name=t commit -qm base

  # `claude` STUBBED ON PATH. install.sh's plugin step runs
  # `claude plugin marketplace add` and `claude plugin install --scope project`,
  # and with the real binary on PATH -- which is every machine the fleet runs on
  # -- a test of the .gitignore append reached the network and mutated the
  # developer's global plugin state, or hung offline. A suite that changes the
  # machine it is measuring is worse than no suite. Found by the local
  # /code-review pass.
  mkdir -p "$WORK/bin"
  cat >"$WORK/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CLAUDE_CALLS"
exit 0
STUB
  chmod +x "$WORK/bin/claude"
  # `gh` STUBBED for the same reason, and with a sharper one: install.sh sets
  # BRANCH PROTECTION through `gh api -X PUT`, and the host fixture is a real
  # git repo. A stub that answers nothing to `repo view` keeps the installer on
  # the "could not say which repository this is" path; the real `gh` in a
  # checkout that happened to have a remote would reach for somebody's
  # repository settings from inside a test.
  cat >"$WORK/bin/gh" <<'GHSTUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALLS"
exit 1
GHSTUB
  chmod +x "$WORK/bin/gh"
  GH_CALLS="$WORK/gh-calls"; : >"$GH_CALLS"; export GH_CALLS
  CLAUDE_CALLS="$WORK/claude-calls"; : >"$CLAUDE_CALLS"; export CLAUDE_CALLS
  PATH="$WORK/bin:$PATH"; export PATH
}

install_it() { (cd "$WORK/host" && "$REPO_ROOT/install.sh" "$@" . 2>&1); }

has_line() { grep -qxF -- "$1" "$WORK/host/.gitignore"; }

# BOTH, and `.env.tmp*` most of all: it has the sharpest reason -- `env.sh`
# writes the temporary file and renames it, so a `git add -A` racing a
# worktree's setup commits the half-written secret -- and it was the one line no
# phase covered, in the suite added because this is the one thing in the payload
# that edits a file the host owns.
#
# It was four. `.autofleet/run/` held the push markers and `/findings.md` was
# what the self-review passes wrote; armaatus/autofleet#152 removed both, and a
# line for a file nothing writes is a line a host has to wonder about.
WANT=(".env" ".env.tmp*")

case "${1:-}" in

  ignores)
  make_host
  out="$(install_it)" || fail "install.sh failed: $out"

  for line in "${WANT[@]}"; do
    has_line "$line" || fail "install.sh did not add '$line' to the host's .gitignore"
  done
  ok "every line the payload needs is in the host's .gitignore"

  # The host's own list survives, and the last pattern is still its own pattern.
  has_line 'node_modules/' || fail "the host's own .gitignore entry was lost"
  has_line '*.log' \
    || fail "the host's last line had no trailing newline and the append was welded onto it"
  ok "the host's own entries are untouched, including the one with no newline after it"

  # It is an APPEND, not a rewrite: the host's lines come first, in order.
  # NOT `head -1 ... | grep -q`. CLAUDE.md bans piping an assertion into `grep -q`
  # outright: `-q` exits on the first match, the producer dies of EPIPE, and
  # `pipefail` turns a check that HELD into a failure. Nothing scans for it --
  # `.autofleet/review.md` names the shape for a reviewer instead. Found by the
  # local /code-review pass.
  first="$(head -1 "$WORK/host/.gitignore")"
  [ "$first" = 'node_modules/' ] \
    || fail "the host's .gitignore was rewritten rather than appended to"
  ok "appended, never rewritten"

  # ...and nothing reached the real `claude`. If the stub is ever bypassed this
  # phase is touching the machine's plugin state, which is what the stub exists
  # to prevent -- so assert the calls landed on the stub rather than nowhere.
  grep -q . "$CLAUDE_CALLS" \
    || fail "install.sh never called claude, so the plugin step is not being stubbed here at all"
  ok "the plugin step went to the stub, not to the network"
  ;;

  idempotent)
  make_host
  install_it >/dev/null || fail "the first install failed"
  before="$(cat "$WORK/host/.gitignore")"
  out="$(install_it)" || fail "the second install failed: $out"

  [ "$(cat "$WORK/host/.gitignore")" = "$before" ] \
    || fail "a second run changed the .gitignore again"
  ok "a second run adds nothing"

  # ...and says nothing about adding them, because it added nothing. The summary
  # line is `"$changed written, $kept unchanged"`, and a line already present is
  # counted as kept -- which is what makes the count on the DRY run below mean
  # something.
  # `.gitignore +=` is what `ensure_ignored` prints. The first spelling of this
  # assertion looked for "added to .gitignore", a message that died with the
  # duplicate appender this branch deleted -- so it could never fail, which is
  # hard rule 3 in a test. Found by the local /code-review pass.
  grep -qF -- '.gitignore +=' <<<"$out" \
    && fail "the second run claims to have added lines that were already there: $out"
  grep -qE '[0-9]+ unchanged' <<<"$out" \
    || fail "the second run does not report a summary: $out"
  ok "it adds nothing and says nothing about adding"
  ;;

  dry)
  make_host
  before="$(cat "$WORK/host/.gitignore")"
  out="$(install_it --dry-run)" || fail "--dry-run failed: $out"

  [ "$(cat "$WORK/host/.gitignore")" = "$before" ] \
    || fail "--dry-run edited the host's .gitignore"
  ok "--dry-run writes nothing"

  grep -qF -- 'would add to .gitignore' <<<"$out" \
    || fail "--dry-run does not say it would touch the .gitignore: $out"
  # THE COUNT. This is the regression: the lines were appended without
  # incrementing `changed`, so the summary said "Nothing was written" under a
  # list of things it would write, and a real run reported "0 written" having
  # mutated a file autofleet does not own.
  # ANCHORED. `grep -qF '0 would change'` also matches "30 would change", so the
  # assertion passed for the wrong reason the moment the payload grew a file --
  # it is looking for a ZERO count, and every count ending in zero satisfied it.
  grep -qE '(^|[^0-9])0 would change' <<<"$out" \
    && fail "--dry-run lists .gitignore changes and then counts zero of them: $out"
  ok "...and counts them, so the summary is not a contradiction"
  ;;

  retires)
  # WHAT A v1 INSTALL LEFT BEHIND. `claude-review.yml` and `validate.yml`
  # shipped in PAYLOAD until armaatus/autofleet#152 and do not any more -- and
  # an upgrade that only ever COPIES leaves both on the host, running. A host
  # with `claude-review.yml` still on it gets two reviews per pull request in
  # two verdict formats, one of them from a rule set nothing updates; that is
  # armaatus/rommsync-nx today, which is the host #154 opens its first night on.
  # Dropping a path out of PAYLOAD is not a removal, and the comment in
  # install.sh that says why they are gone is what this list makes executable.
  make_host
  mkdir -p "$WORK/host/.github/workflows"
  for w in claude-review validate; do
    printf 'name: %s\n' "$w" >"$WORK/host/.github/workflows/$w.yml"
  done
  # ...and the host's OWN workflow, which the installer has no business touching.
  printf 'name: ci\n' >"$WORK/host/.github/workflows/ci.yml"

  out="$(install_it)" || fail "install.sh failed: $out"

  for w in claude-review validate; do
    [ -e "$WORK/host/.github/workflows/$w.yml" ] \
      && fail "$w.yml is still on the host, so it still runs: $out"
    grep -qF ".github/workflows/$w.yml" <<<"$out" \
      || fail "install.sh removed $w.yml without saying so: $out"
  done
  ok "the v1 workflows are removed from the host, and named"

  [ -e "$WORK/host/.github/workflows/ci.yml" ] \
    || fail "install.sh removed a workflow that was the host's own"
  ok "...and the host's own workflows are untouched"

  # A SECOND RUN SAYS NOTHING. They are gone; an installer that announces a
  # removal it did not make is one nobody can read the output of.
  out="$(install_it)" || fail "the second install failed: $out"
  grep -qF '.github/workflows/claude-review.yml' <<<"$out" \
    && fail "the second run announced a removal of a file that was already gone: $out"
  ok "...and a re-run announces nothing"
  ;;

  retires_dry)
  # --dry-run ANNOUNCES AND LEAVES. Same rule the copy follows: a dry run that
  # deletes is the worst possible reading of the flag, and one that stays silent
  # about what it would delete is the bug f5817b8 fixed for the seeds.
  make_host
  mkdir -p "$WORK/host/.github/workflows"
  printf 'name: claude-review\n' >"$WORK/host/.github/workflows/claude-review.yml"

  out="$(install_it --dry-run)" || fail "--dry-run failed: $out"

  [ -e "$WORK/host/.github/workflows/claude-review.yml" ] \
    || fail "--dry-run deleted a file from the host: $out"
  ok "--dry-run removes nothing"

  grep -qF 'would remove .github/workflows/claude-review.yml' <<<"$out" \
    || fail "--dry-run does not say which file it would remove: $out"
  ok "...and still says which file it would remove"
  ;;

  *) echo "usage: $0 {ignores|idempotent|dry|retires|retires_dry}" >&2; exit 2 ;;
esac
