#!/usr/bin/env bash
# Usage: merge-up-run.sh [--allow-behind] [-h|--help]
#
# The one mutating step of /merge-up. Merges this stream's committed work into
# its recorded parent branch (branch.<b>.exosuitParent), running the merge in
# the parent's own worktree, then fast-forwards the stream to the parent.
# Never pushes. Never stashes. Never deletes a lock or a MERGE_HEAD.
#
# Runs the sibling worktree-status.sh --gate merge-up first (located next to
# this file) and prints its output verbatim; its stderr passes through.
# Nothing is touched unless that gate ends with GATE merge-up: OK.
#
# Options:
#   --allow-behind   merge even when the parent has commits this stream lacks
#                    (a true merge). Without it that state is refused with
#                    MERGE: behind so /merge-down can run first.
#   -h, --help       print this block and exit 0
#
# Stdout, in order: the gate's thirteen "key: value" lines (branch, dir,
# parent, parent_dir, ahead, behind, dirty, parent_dirty,
# parent_merge_in_progress, remote, coordinator, peers, story), then
#   GATE merge-up: OK                       or one or more
#   GATE merge-up: FAIL — <reason>          (exit 1, nothing touched)
# then exactly one verdict line:
#   MERGE: nothing-to-merge
#   MERGE: behind — the parent has <N> commit(s) this stream lacks; run /merge-down first (or re-run with --allow-behind to merge anyway)
#   MERGE: refused — parent worktree <PDIR> no longer has <P> checked out; nothing changed
#   MERGE: locked — another git process holds the parent's index (index.lock present); nothing changed, retry in a minute
#   MERGE: blocked — untracked files in the parent worktree would be overwritten: <files>; nothing changed — move them aside there, then retry
#   MERGE: refused — <first git line> (nothing changed)
#   MERGE: refused — <first git line> (the parent worktree <PDIR> was left changed — inspect it by hand)
#   MERGE: busy — the parent worktree holds another merge in progress (not this stream's); nothing changed, retry later
#   MERGE: refused — <first git line> (the commit step was refused — pre-merge-commit, prepare-commit-msg or commit-msg hook; aborted, parent restored to <sha7>)
#   MERGE: conflict — <paths> (aborted, parent restored to <sha7>)
#   MERGE: conflict — <paths> (ABORT DID NOT FULLY RESTORE the parent worktree — inspect <PDIR> by hand)
#   MERGE: refused — parent worktree <PDIR> switched to <X> during the merge; the merge landed on <X>, not <P> — inspect <PDIR> by hand
#   MERGE: merged <sha7> <N> commit(s) <M> file(s)
# followed, after MERGE: merged only, by
#   files: <first 12 changed paths, space-joined>[ +K more]   (files: - when no path changed)
#   SYNC: ok                                                  (always the last line on success)
#   SYNC: FAIL — this stream's index is locked (index.lock present); retry: git merge --ff-only <P>
#   SYNC: FAIL — untracked files in this stream would be overwritten by the fast-forward; move them aside, then: git merge --ff-only <P>
#   SYNC: FAIL — the stream is no longer an ancestor of <P> (something committed here during the run); <first git line>
# Under MERGE: busy and MERGE: conflict, up to three lines of git's own output
# follow, each as
#   git: <line>            (indented two spaces; git's hint: lines are never printed)
#
# Stderr:
#   ERROR: unknown option <x>
#   usage: merge-up-run.sh [--allow-behind]
#   ERROR: the gate exited 0 but its output is incomplete (no 'GATE merge-up: OK' last line, or branch/parent/parent_dir unset); nothing touched
#   plus everything worktree-status.sh writes there, unchanged (for example
#   ADVISORY: session detection unavailable (...) and ERROR: not inside a git repository).
#
# Exit codes:
#   0  MERGE: nothing-to-merge, or MERGE: merged + files: + SYNC: ok
#   1  GATE merge-up: FAIL (nothing touched), or an incomplete gate block
#   2  usage error (unknown option); also relayed when the gate itself exits 2
#   3  MERGE: refused, MERGE: locked or MERGE: busy
#   4  MERGE: conflict (the merge was aborted in the parent worktree)
#   5  SYNC: FAIL (the parent merge stands; only the stream's fast-forward failed)
#   6  MERGE: behind
#   7  MERGE: blocked
#   8  reserved for a later PARENT: verification line (never produced here)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

# --- options -----------------------------------------------------------------
ALLOW_BEHIND=0
for arg in "$@"; do
  case "$arg" in
    --allow-behind) ALLOW_BEHIND=1 ;;
    -h|--help)
      sed -n '/^# Usage:/,/^set -/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "ERROR: unknown option $arg" >&2
      echo "usage: merge-up-run.sh [--allow-behind]" >&2
      exit 2 ;;
  esac
done

# --- helpers -----------------------------------------------------------------

# val <key>: the value of one "key: value" line of the gate block on stdin.
# The first match wins, so the free-text story: line (printed last) can never
# forge an earlier key.
val () { sed -n "s/^$1: //p" | head -1; }

# anchor <dir> <path>: git rev-parse --git-path answers a path relative to the
# directory git ran in when the repository is the main worktree; make it
# absolute. An empty answer stays empty (a failed lookup must not become <dir>/).
anchor () {
  case "$2" in
    "")  printf '\n' ;;
    /*)  printf '%s\n' "$2" ;;
    *)   printf '%s/%s\n' "$1" "$2" ;;
  esac
}

# git_line <text>: the first non-empty line of git's output; hint: lines skipped.
git_line () {
  printf '%s\n' "$1" | LC_ALL=C awk '/^hint:/ { next } /^[ \t\r]*$/ { next } { print; exit }'
}

# git_lines3 <text>: up to three such lines, each as "  git: <line>".
git_lines3 () {
  printf '%s\n' "$1" | LC_ALL=C awk '/^hint:/ { next } /^[ \t\r]*$/ { next } { print "  git: " $0; if (++n == 3) exit }'
}

# tracked_clean <dir>: succeeds when no tracked file differs there. A failing
# status command counts as not clean (the verdict then says "inspect by hand").
tracked_clean () {
  local s
  s="$(git -C "$1" status --porcelain --untracked-files=no 2>/dev/null)" || return 1
  [ -z "$s" ]
}

# join_paths: stdin lines -> one line, single spaces, no trailing space.
join_paths () {
  LC_ALL=C awk '$0 != "" { printf "%s%s", (n++ ? " " : ""), $0 } END { printf "\n" }'
}

# --- gate --------------------------------------------------------------------
GATE_OUT="$(bash "$HERE/worktree-status.sh" --gate merge-up)"; RC=$?
[ -n "$GATE_OUT" ] && printf '%s\n' "$GATE_OUT"
if [ "$RC" -ne 0 ]; then
  [ "$RC" -eq 2 ] && exit 2
  exit 1
fi

B="$(printf '%s\n' "$GATE_OUT" | val branch)"
P="$(printf '%s\n' "$GATE_OUT" | val parent)"
PDIR="$(printf '%s\n' "$GATE_OUT" | val parent_dir)"
AHEAD="$(printf '%s\n' "$GATE_OUT" | val ahead)"
BEHIND="$(printf '%s\n' "$GATE_OUT" | val behind)"
LAST="$(printf '%s\n' "$GATE_OUT" | tail -1)"

if [ "$LAST" != "GATE merge-up: OK" ] || [ -z "$B" ] || [ "$B" = "HEAD" ] \
   || [ -z "$P" ] || [ "$P" = "-" ] || [ -z "$PDIR" ] || [ "$PDIR" = "-" ]; then
  echo "ERROR: the gate exited 0 but its output is incomplete (no 'GATE merge-up: OK' last line, or branch/parent/parent_dir unset); nothing touched" >&2
  exit 1
fi

# --- nothing to merge / behind ----------------------------------------------
if [ "$AHEAD" = "0" ]; then
  echo "MERGE: nothing-to-merge"
  exit 0
fi

if [ "$BEHIND" != "0" ] && [ "$ALLOW_BEHIND" -eq 0 ]; then
  echo "MERGE: behind — the parent has $BEHIND commit(s) this stream lacks; run /merge-down first (or re-run with --allow-behind to merge anyway)"
  exit 6
fi

# --- pre-merge snapshot and the re-check of the parent worktree --------------
# BEFORE = the parent's tip; BTIP = this stream's tip, captured now so the
# MERGE_HEAD ownership test below cannot be fooled by a commit made mid-run.
BEFORE="$(git -C "$PDIR" rev-parse HEAD 2>/dev/null)"
BTIP="$(git rev-parse HEAD 2>/dev/null)"
pref="$(git -C "$PDIR" symbolic-ref -q HEAD 2>/dev/null)"
if [ "$pref" != "refs/heads/$P" ] || [ -z "$BEFORE" ]; then
  echo "MERGE: refused — parent worktree $PDIR no longer has $P checked out; nothing changed"
  exit 3
fi

# --- the merge, run in the parent's worktree ---------------------------------
MERGE_OUT="$(git -C "$PDIR" merge --no-edit "refs/heads/$B" 2>&1 </dev/null)"; MRC=$?

if [ "$MRC" -ne 0 ]; then
  # A lock is judged by the file, never by git's wording.
  L="$(anchor "$PDIR" "$(git -C "$PDIR" rev-parse --git-path index.lock 2>/dev/null)")"
  if [ -n "$L" ] && [ -e "$L" ]; then
    echo "MERGE: locked — another git process holds the parent's index (index.lock present); nothing changed, retry in a minute"
    exit 3
  fi

  case "$MERGE_OUT" in
    *"would be overwritten by merge"*)
      BLOCKED="$(printf '%s\n' "$MERGE_OUT" | LC_ALL=C awk '/^[ \t]/ { sub(/^[ \t]+/, ""); print }' | join_paths)"
      echo "MERGE: blocked — untracked files in the parent worktree would be overwritten: $BLOCKED; nothing changed — move them aside there, then retry"
      exit 7 ;;
  esac

  MH="$(anchor "$PDIR" "$(git -C "$PDIR" rev-parse --git-path MERGE_HEAD 2>/dev/null)")"
  if [ -z "$MH" ] || [ ! -f "$MH" ]; then
    # Git stopped before starting a merge (merge.ff=only, gpg, disk, ...).
    LINE="$(git_line "$MERGE_OUT")"; [ -n "$LINE" ] || LINE="(no output from git)"
    NOW="$(git -C "$PDIR" rev-parse HEAD 2>/dev/null)"
    if [ "$NOW" = "$BEFORE" ] && tracked_clean "$PDIR"; then
      echo "MERGE: refused — $LINE (nothing changed)"
    else
      echo "MERGE: refused — $LINE (the parent worktree $PDIR was left changed — inspect it by hand)"
    fi
    exit 3
  fi

  # A merge is in progress there. Ours only when MERGE_HEAD is exactly the
  # stream tip captured before the merge; anything else is a sibling's and is
  # never aborted.
  MH_SHA="$(cat "$MH" 2>/dev/null)"
  if [ "$MH_SHA" != "$BTIP" ]; then
    echo "MERGE: busy — the parent worktree holds another merge in progress (not this stream's); nothing changed, retry later"
    git_lines3 "$MERGE_OUT"
    exit 3
  fi

  CONFLICTS="$(git -c core.quotePath=off -C "$PDIR" diff --name-only --diff-filter=U -- 2>/dev/null | join_paths)"
  git -C "$PDIR" merge --abort >/dev/null 2>&1
  if [ -z "$CONFLICTS" ]; then
    # The merge itself succeeded; a commit hook refused the merge commit.
    LINE="$(git_line "$MERGE_OUT")"; [ -n "$LINE" ] || LINE="(no output from git)"
    echo "MERGE: refused — $LINE (the commit step was refused — pre-merge-commit, prepare-commit-msg or commit-msg hook; aborted, parent restored to ${BEFORE:0:7})"
    exit 3
  fi
  NOW="$(git -C "$PDIR" rev-parse HEAD 2>/dev/null)"
  if [ "$NOW" = "$BEFORE" ] && tracked_clean "$PDIR"; then
    echo "MERGE: conflict — $CONFLICTS (aborted, parent restored to ${BEFORE:0:7})"
  else
    echo "MERGE: conflict — $CONFLICTS (ABORT DID NOT FULLY RESTORE the parent worktree — inspect $PDIR by hand)"
  fi
  git_lines3 "$MERGE_OUT"
  exit 4
fi

# --- post-merge assertion: the merge landed on the parent branch -------------
pref2="$(git -C "$PDIR" symbolic-ref -q HEAD 2>/dev/null)"
AFTER="$(git -C "$PDIR" rev-parse HEAD 2>/dev/null)"
PTIP="$(git rev-parse "refs/heads/$P" 2>/dev/null)"
if [ "$pref2" != "refs/heads/$P" ] || [ -z "$AFTER" ] || [ "$AFTER" != "$PTIP" ]; then
  X="${pref2#refs/heads/}"
  if [ -z "$X" ]; then
    X="a detached HEAD"
  elif [ "$X" = "$P" ]; then
    X="commit ${AFTER:0:7}"
  fi
  echo "MERGE: refused — parent worktree $PDIR switched to $X during the merge; the merge landed on $X, not $P — inspect $PDIR by hand"
  exit 3
fi

# --- merged ------------------------------------------------------------------
N="$(git -C "$PDIR" rev-list --count "$BEFORE..$AFTER" -- 2>/dev/null)"; [ -n "$N" ] || N="?"
FILES="$(git -c core.quotePath=off -C "$PDIR" diff --name-only "$BEFORE" "$AFTER" -- 2>/dev/null)"
M="$(printf '%s\n' "$FILES" | LC_ALL=C grep -c .)"
if [ "$M" -eq 0 ]; then
  FILE_LINE="-"
else
  FILE_LINE="$(printf '%s\n' "$FILES" | LC_ALL=C awk '$0 != "" { n++; if (n <= 12) printf "%s%s", (n > 1 ? " " : ""), $0 } END { if (n > 12) printf " +%d more", n - 12; printf "\n" }')"
fi
echo "MERGE: merged ${AFTER:0:7} $N commit(s) $M file(s)"
echo "files: $FILE_LINE"

# --- sync the stream back to the parent (fast-forward only) ------------------
SYNC_OUT="$(git merge --ff-only --no-edit "refs/heads/$P" 2>&1 </dev/null)"; SRC=$?
if [ "$SRC" -eq 0 ]; then
  echo "SYNC: ok"
  exit 0
fi

SL="$(anchor "$(pwd -P)" "$(git rev-parse --git-path index.lock 2>/dev/null)")"
if [ -n "$SL" ] && [ -e "$SL" ]; then
  echo "SYNC: FAIL — this stream's index is locked (index.lock present); retry: git merge --ff-only $P"
  exit 5
fi
case "$SYNC_OUT" in
  *"would be overwritten"*)
    echo "SYNC: FAIL — untracked files in this stream would be overwritten by the fast-forward; move them aside, then: git merge --ff-only $P"
    exit 5 ;;
esac
LINE="$(git_line "$SYNC_OUT")"; [ -n "$LINE" ] || LINE="(no output from git)"
echo "SYNC: FAIL — the stream is no longer an ancestor of $P (something committed here during the run); $LINE"
exit 5
