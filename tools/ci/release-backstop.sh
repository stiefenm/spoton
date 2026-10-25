#!/usr/bin/env bash
# Release candidate backstop (79-03, D-09): proves a candidate is ONE commit on
# top of the public base and that it carries no never-ship path.
#
# Usage:  release-backstop.sh <candidate> [base]      (base default: origin/main)
#         release-backstop.sh selftest
#
# Checks, in this order (the first failing one names the reason):
#   count      git rev-list --count base..candidate is exactly 1
#   ancestry   base is an ancestor of candidate (a non-descendant is refused)
#   diff       git diff --name-only --diff-filter=AMR base..candidate lists no
#              never-ship path (added, modified or renamed-to)
#   tree       every never-ship path of the candidate tree exists in base with
#              the identical blob (the public legacy planning files may stay,
#              unchanged); catches what the diff filter does not, e.g. a type
#              change
# Never-ship paths: tools/ci/release-never-ship.txt (shared with the literal
# gate and the release builder). The check is name based; the literal content
# check is tools/ci/literal-gate.sh.
#
# Output:  CHECK <count|ancestry|diff|tree> <ok|fail> paths=<n>   (one per check)
#          BACKSTOP=PASS
#          BACKSTOP=FAIL reason=<count|ancestry|tree|diff> paths=<n>
#          BACKSTOP=ERROR reason=<text>                  (unknown rev)
# Exit:    0 PASS, 1 FAIL, 2 ERROR
# Selftest: "case=<name> expect=<P|F|E> got=<P|F|E>" per case, then
#          SELFTEST=PASS cases=<n> (exit 0) or SELFTEST=FAIL ... (exit 1).

set -u
export LC_ALL=C

SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
NEVER_FILE=$(dirname "$SELF")/release-never-ship.txt

TMP=$(mktemp -d) || { echo "BACKSTOP=ERROR reason=no-tmpdir"; exit 2; }
trap 'rm -rf "$TMP"' EXIT

fail_error() {
  echo "BACKSTOP=ERROR reason=$1"
  exit 2
}

NEVER=()
load_never() {
  [ -r "$NEVER_FILE" ] || fail_error "release-never-ship.txt unreadable"
  local line
  while IFS= read -r line; do
    NEVER+=("$line")
  done < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$NEVER_FILE")
  [ "${#NEVER[@]}" -gt 0 ] || fail_error "release-never-ship.txt has no pattern"
}

# never_ship <path>: 0 if the path matches the never-ship list
never_ship() {
  local p=$1 pat
  for pat in "${NEVER[@]}"; do
    case "$pat" in
      */) [[ "$p" == $pat* ]] && return 0 ;;
      *)  [[ "$p" == $pat || "$p" == */$pat || "$p" == $pat/* || "$p" == */$pat/* ]] && return 0 ;;
    esac
  done
  return 1
}

# backstop <candidate> <base>: prints CHECK lines and the verdict; returns 0/1/2
backstop() {
  local cand_in=$1 base_in=$2 cand base n path first_reason= first_paths=0
  cand=$(git rev-parse --verify -q "$cand_in^{commit}" 2> /dev/null) || fail_error "unknown-candidate"
  base=$(git rev-parse --verify -q "$base_in^{commit}" 2> /dev/null) || fail_error "unknown-base"

  note_fail() { # <name> <paths>
    echo "CHECK $1 fail paths=$2"
    if [ -z "$first_reason" ]; then first_reason=$1; first_paths=$2; fi
  }

  # count
  n=$(git rev-list --count "$base..$cand") || fail_error "rev-list-failed"
  if [ "$n" = 1 ]; then echo "CHECK count ok paths=0"; else note_fail count "$n"; fi

  # ancestry
  if git merge-base --is-ancestor "$base" "$cand" 2> /dev/null; then
    echo "CHECK ancestry ok paths=0"
  else
    note_fail ancestry 0
  fi

  # diff: never-ship paths added, modified or renamed-to
  n=0
  git diff --name-only --no-renames --diff-filter=AMR -z "$base" "$cand" > "$TMP/diff.z" \
    || fail_error "diff-failed"
  while IFS= read -r -d '' path; do
    never_ship "$path" && n=$((n + 1))
  done < "$TMP/diff.z"
  if [ "$n" = 0 ]; then echo "CHECK diff ok paths=0"; else note_fail diff "$n"; fi

  # tree: never-ship paths of the candidate must be identical to base
  n=0
  git ls-tree -r -z "$cand" > "$TMP/tree.z" || fail_error "ls-tree-failed"
  local meta blob
  while IFS= read -r -d '' meta; do
    path=${meta#*$'\t'}
    blob=$(printf '%s' "${meta%%$'\t'*}" | awk '{ print $3 }')
    never_ship "$path" || continue
    if [ "$(git rev-parse --verify -q "$base:$path" 2> /dev/null)" != "$blob" ]; then
      n=$((n + 1))
    fi
  done < "$TMP/tree.z"
  if [ "$n" = 0 ]; then echo "CHECK tree ok paths=0"; else note_fail tree "$n"; fi

  if [ -z "$first_reason" ]; then
    echo "BACKSTOP=PASS"
    return 0
  fi
  echo "BACKSTOP=FAIL reason=$first_reason paths=$first_paths"
  return 1
}

# ------------------------------------------------------------------ selftest
SELFTEST_CASES=0
SELFTEST_BAD=0

GITC=(git -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c core.hooksPath=/dev/null)
gitc() { local d=$1; shift; "${GITC[@]}" -C "$d" "$@"; }

# run_case <name> <expect P|F|E> <reason|-> <repo> <args...>
run_case() {
  local name=$1 expect=$2 reason=$3 repo=$4 out rc got=X
  shift 4
  out=$(cd "$repo" && bash "$SELF" "$@" 2>&1)
  rc=$?
  case "$rc" in
    0) printf '%s\n' "$out" | command grep -q '^BACKSTOP=PASS$' && got=P ;;
    1) printf '%s\n' "$out" | command grep -q '^BACKSTOP=FAIL reason=' && got=F ;;
    2) printf '%s\n' "$out" | command grep -q '^BACKSTOP=ERROR reason=' && got=E ;;
  esac
  # a MUST-FAIL case counts only when it fails for the intended reason
  if [ "$got" = F ] && [ "$reason" != - ]; then
    printf '%s\n' "$out" | command grep -q "^BACKSTOP=FAIL reason=$reason " || got=X
  fi
  printf 'case=%s expect=%s got=%s\n' "$name" "$expect" "$got"
  SELFTEST_CASES=$((SELFTEST_CASES + 1))
  [ "$expect" = "$got" ] || SELFTEST_BAD=$((SELFTEST_BAD + 1))
}

# new_base <dir>: repo with branch base0 holding a legacy planning file
new_base() {
  mkdir -p "$1/.planning" "$1/src"
  git -C "$1" init -q
  printf 'legacy planning file\n' > "$1/.planning/legacy.md"
  printf 'plugin\n' > "$1/src/a.txt"
  git -C "$1" add -A && gitc "$1" commit -q -m base
  git -C "$1" branch -M base0
}

# candidate <dir> <name> : branch off base0, ready for edits (no commit yet)
cand_start() { git -C "$1" checkout -q -B "$2" base0; }
cand_commit() { git -C "$1" add -A -f && gitc "$1" commit -q -m "candidate $2"; }

selftest() {
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
  command -v git > /dev/null 2>&1 || { echo "SELFTEST=FAIL reason=no-git"; exit 1; }
  local S=$TMP/self R
  rm -rf "$S"
  mkdir -p "$S"

  # base with a public legacy planning file
  R=$S/r1; new_base "$R"

  cand_start "$R" c-clean; printf 'new\n' > "$R/src/b.txt"; cand_commit "$R" c-clean
  run_case clean-single-commit            P - "$R" c-clean base0

  cand_start "$R" c-planning; mkdir -p "$R/.planning"; printf 'x\n' > "$R/.planning/x.md"; cand_commit "$R" c-planning
  run_case planted-planning               F diff "$R" c-planning base0

  cand_start "$R" c-releases; mkdir -p "$R/soloist-releases/x86_64-linux"
  printf 'x\n' > "$R/soloist-releases/x86_64-linux/a.tar.gz"; cand_commit "$R" c-releases
  run_case planted-soloist-releases       F diff "$R" c-releases base0

  cand_start "$R" c-claude; printf 'x\n' > "$R/CLAUDE.md"; cand_commit "$R" c-claude
  run_case planted-claude-md              F diff "$R" c-claude base0

  cand_start "$R" c-key; mkdir -p "$R/a"; printf 'x\n' > "$R/a/b.key"; cand_commit "$R" c-key
  run_case planted-nested-key             F diff "$R" c-key base0

  cand_start "$R" c-modlegacy; printf 'changed\n' >> "$R/.planning/legacy.md"; cand_commit "$R" c-modlegacy
  run_case modified-legacy-planning       F diff "$R" c-modlegacy base0

  cand_start "$R" c-typechange; rm "$R/.planning/legacy.md"; ln -s src/a.txt "$R/.planning/legacy.md"; cand_commit "$R" c-typechange
  run_case typechanged-legacy-planning    F tree "$R" c-typechange base0

  cand_start "$R" c-two; printf 'one\n' > "$R/src/c1.txt"; cand_commit "$R" c-two-1
  printf 'two\n' > "$R/src/c2.txt"; cand_commit "$R" c-two-2
  run_case two-commits                    F count "$R" c-two base0

  run_case zero-commits                   F count "$R" base0 base0

  git -C "$R" checkout -q --orphan c-unrelated && git -C "$R" rm -rq --cached . > /dev/null 2>&1
  printf 'unrelated\n' > "$R/unrelated.txt"
  git -C "$R" add unrelated.txt && gitc "$R" commit -q -m unrelated
  run_case non-descendant                 F ancestry "$R" c-unrelated base0

  # a base without any planning file
  local R2=$S/r2
  mkdir -p "$R2/src"; git -C "$R2" init -q; printf 'plugin\n' > "$R2/src/a.txt"
  git -C "$R2" add -A && gitc "$R2" commit -q -m base && git -C "$R2" branch -M base0
  git -C "$R2" checkout -q -B c-clean base0; printf 'new\n' > "$R2/src/b.txt"; cand_commit "$R2" c-clean
  run_case clean-without-legacy           P - "$R2" c-clean base0

  run_case unknown-candidate              E - "$R" no-such-candidate-79 base0
  run_case unknown-base                   E - "$R" c-clean no-such-base-79

  if [ "$SELFTEST_BAD" = 0 ]; then
    echo "SELFTEST=PASS cases=$SELFTEST_CASES"
    exit 0
  fi
  echo "SELFTEST=FAIL cases=$SELFTEST_CASES mismatches=$SELFTEST_BAD"
  exit 1
}

# ---------------------------------------------------------------------- main
CAND=${1:-}
[ -n "$CAND" ] || fail_error "usage: release-backstop.sh <candidate> [base] | selftest"
load_never
if [ "$CAND" = selftest ]; then
  selftest
fi
BASE=${2:-origin/main}
git rev-parse --git-dir > /dev/null 2>&1 || fail_error "not inside a git repository"
backstop "$CAND" "$BASE"
exit $?
