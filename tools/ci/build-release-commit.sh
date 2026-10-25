#!/usr/bin/env bash
# Release candidate builder (79-09, D-09): builds ONE commit on top of the
# public base from HEAD's tree, never from the working directory.
#
# Usage:  build-release-commit.sh --label <l> --message-file <f>
#                                 [--base <rev>]                 (default origin/main)
#                                 [--legacy-planning keep|delete] (default delete, Q-c)
#                                 [--continue-here keep|delete]   (default delete, Q-c)
#         build-release-commit.sh selftest
#
# What it does:
#   1. temporary index (GIT_INDEX_FILE under mktemp -d), read-tree HEAD
#   2. removes every never-ship path (HEAD:tools/ci/release-never-ship.txt)
#   3. legacy-planning keep: re-adds the base's .planning/ entries with their
#      identical blobs; delete: they stay out
#   4. continue-here delete: removes the root .continue-here.md; keep: re-adds
#      the base's blob
#   5. .gitignore comes from the blob HEAD:tools/ci/release-overlay/gitignore.public
#      (that file is itself never-ship, so it is read from HEAD, not from the
#      candidate)
#   6. write-tree, commit-tree <tree> -p <base> -F <message file>; author and
#      committer (name, e-mail, date) are taken from HEAD's commit, so two runs
#      on the same HEAD give the identical commit
#   7. git branch -f release/<label> <commit>
#
# It never touches the working tree, the real index or any remote. A tracked
# but ignored file (e.g. the libpulse shim) stays: the tree is built from the
# index of HEAD, not from a `git add`.
#
# Output (stdout, only on success): CANDIDATE=<sha> TREE=<sha> BASE=<sha>
# Refusal (stderr): BUILD=REFUSED reason=<text>, exit 2, no CANDIDATE line.
#
# Selftest: scratch repos, `case=<name> expect=<P|F> got=<P|F>` per case
# (P = the property holds / the build succeeds, F = the builder refuses and
# prints no CANDIDATE line), then SELFTEST=PASS cases=<n> (exit 0) or
# SELFTEST=FAIL ... (exit 1).

set -eu
export LC_ALL=C
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR

SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
NEVER_REL=tools/ci/release-never-ship.txt
OVERLAY_REL=tools/ci/release-overlay/gitignore.public

refuse() {
  echo "BUILD=REFUSED reason=$1" >&2
  exit 2
}

# never_ship <path>: 0 if the path matches the never-ship list (same matcher
# as tools/ci/release-backstop.sh)
NEVER=()
tmp=
S=
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

build() {
  local label= msgfile= base=origin/main legacy=delete cont=delete
  while [ $# -gt 0 ]; do
    case "$1" in
      --label)            [ $# -ge 2 ] || refuse "missing-value-label"; label=$2; shift 2 ;;
      --message-file)     [ $# -ge 2 ] || refuse "missing-value-message-file"; msgfile=$2; shift 2 ;;
      --base)             [ $# -ge 2 ] || refuse "missing-value-base"; base=$2; shift 2 ;;
      --legacy-planning)  [ $# -ge 2 ] || refuse "missing-value-legacy-planning"; legacy=$2; shift 2 ;;
      --continue-here)    [ $# -ge 2 ] || refuse "missing-value-continue-here"; cont=$2; shift 2 ;;
      *) refuse "unknown-argument" ;;
    esac
  done
  [ -n "$label" ] || refuse "no-label"
  case "$label" in
    *[!A-Za-z0-9._-]*) refuse "bad-label" ;;
  esac
  [ -n "$msgfile" ] || refuse "no-message-file"
  [ -r "$msgfile" ] && [ -s "$msgfile" ] || refuse "message-file-missing-or-empty"
  case "$legacy" in keep | delete) ;; *) refuse "bad-legacy-planning-value" ;; esac
  case "$cont" in keep | delete) ;; *) refuse "bad-continue-here-value" ;; esac

  local root
  root=$(git rev-parse --show-toplevel 2> /dev/null) || refuse "not-inside-a-git-repository"
  cd "$root"

  local head base_c
  head=$(git rev-parse --verify -q 'HEAD^{commit}' 2> /dev/null) || refuse "no-head"
  base_c=$(git rev-parse --verify -q "$base^{commit}" 2> /dev/null) || refuse "unknown-base"

  # inputs come from HEAD's tree
  local overlay_blob never_blob
  never_blob=$(git rev-parse --verify -q "HEAD:$NEVER_REL" 2> /dev/null) || refuse "head-without-never-ship-list"
  overlay_blob=$(git rev-parse --verify -q "HEAD:$OVERLAY_REL" 2> /dev/null) || refuse "head-without-public-gitignore-overlay"

  tmp=$(mktemp -d) || refuse "no-tmpdir"
  trap 'rm -rf "$tmp"' EXIT

  local line
  while IFS= read -r line; do
    NEVER+=("$line")
  done < <(git cat-file blob "$never_blob" | sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d')
  [ "${#NEVER[@]}" -gt 0 ] || refuse "never-ship-list-empty"

  # author / committer from HEAD's commit (determinism)
  local an ae ad cn ce cdt
  an=$(git log -1 --format=%an "$head"); ae=$(git log -1 --format=%ae "$head"); ad=$(git log -1 --format=%ad --date=raw "$head")
  cn=$(git log -1 --format=%cn "$head"); ce=$(git log -1 --format=%ce "$head"); cdt=$(git log -1 --format=%cd --date=raw "$head")

  export GIT_INDEX_FILE=$tmp/release.idx
  git read-tree "$head"

  # 2. remove every never-ship path
  local path
  git ls-files -z > "$tmp/all.z"
  : > "$tmp/remove.z"
  while IFS= read -r -d '' path; do
    never_ship "$path" && printf '%s\0' "$path" >> "$tmp/remove.z"
  done < "$tmp/all.z"
  git update-index --force-remove -z --stdin < "$tmp/remove.z"

  # 3. legacy planning entries of the base
  if [ "$legacy" = keep ]; then
    local meta mode blob
    git ls-tree -r -z "$base_c" -- .planning > "$tmp/legacy.z"
    : > "$tmp/legacy.idx"
    while IFS= read -r -d '' meta; do
      path=${meta#*$'\t'}
      mode=${meta%% *}
      blob=$(printf '%s' "${meta%%$'\t'*}" | awk '{ print $3 }')
      printf '%s %s\t%s\0' "$mode" "$blob" "$path" >> "$tmp/legacy.idx"
    done < "$tmp/legacy.z"
    git update-index --add -z --index-info < "$tmp/legacy.idx"
  fi

  # 4. root .continue-here.md
  if [ "$cont" = delete ]; then
    git update-index --force-remove -- .continue-here.md
  else
    local cblob
    if cblob=$(git rev-parse --verify -q "$base_c:.continue-here.md" 2> /dev/null); then
      git update-index --add --cacheinfo "100644,$cblob,.continue-here.md"
    else
      git update-index --force-remove -- .continue-here.md
    fi
  fi

  # 5. public .gitignore from the overlay blob of HEAD
  git update-index --add --cacheinfo "100644,$overlay_blob,.gitignore"

  # 6. tree and commit
  local tree commit
  tree=$(git write-tree)
  commit=$(GIT_AUTHOR_NAME=$an GIT_AUTHOR_EMAIL=$ae GIT_AUTHOR_DATE=$ad \
    GIT_COMMITTER_NAME=$cn GIT_COMMITTER_EMAIL=$ce GIT_COMMITTER_DATE=$cdt \
    git -c commit.gpgsign=false -c core.hooksPath=/dev/null commit-tree "$tree" -p "$base_c" -F "$msgfile")
  [ -n "$commit" ] || refuse "commit-tree-failed"

  # 7. local branch only
  unset GIT_INDEX_FILE
  git branch -f "release/$label" "$commit" > /dev/null 2>&1 || refuse "branch-update-failed"

  printf 'CANDIDATE=%s TREE=%s BASE=%s\n' "$commit" "$tree" "$base_c"
}

# ------------------------------------------------------------------ selftest
SELFTEST_CASES=0
SELFTEST_BAD=0
GITC=(git -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c core.hooksPath=/dev/null)
gitc() { local d=$1; shift; "${GITC[@]}" -C "$d" "$@"; }

# report <name> <expect P|F> <got P|F>
report() {
  printf 'case=%s expect=%s got=%s\n' "$1" "$2" "$3"
  SELFTEST_CASES=$((SELFTEST_CASES + 1))
  [ "$2" = "$3" ] || SELFTEST_BAD=$((SELFTEST_BAD + 1))
}

# run the builder in <repo>; sets B_OUT, B_RC
BOUT=
BRC=0
brun() {
  local repo=$1; shift
  BRC=0
  BOUT=$(cd "$repo" && bash "$SELF" "$@" 2> /dev/null) || BRC=$?
}

cand_of() { printf '%s\n' "$BOUT" | sed -n 's/^CANDIDATE=\([0-9a-f]*\) .*/\1/p'; }
tree_of() { printf '%s\n' "$BOUT" | sed -n 's/^CANDIDATE=[0-9a-f]* TREE=\([0-9a-f]*\) .*/\1/p'; }

# prop <name> <command...>: P if the command succeeds
prop() {
  local name=$1; shift
  if "$@" > /dev/null 2>&1; then report "$name" P P; else report "$name" P F; fi
}
# refuse_case <name> <repo> <args...>: F if the builder exited non-zero and printed no CANDIDATE line
refuse_case() {
  local name=$1 repo=$2 got=P; shift 2
  brun "$repo" "$@"
  if [ "$BRC" != 0 ] && ! printf '%s\n' "$BOUT" | command grep -q '^CANDIDATE='; then got=F; fi
  report "$name" F "$got"
}

mkbase() { # <dir> : repo with branch base0 (public legacy) and branch work (HEAD) on top
  local d=$1
  mkdir -p "$d/.planning" "$d/src" "$d/tools/ci/release-overlay"
  git -C "$d" init -q
  printf 'legacy planning\n' > "$d/.planning/legacy.md"
  printf 'public continue\n' > "$d/.continue-here.md"
  printf 'plugin\n' > "$d/src/a.txt"
  printf 'old gitignore\n' > "$d/.gitignore"
  gitc "$d" add -A && gitc "$d" commit -q -m base
  git -C "$d" branch -M base0
  git -C "$d" checkout -q -b work
  mkdir -p "$d/Bin"
  printf 'shim\n' > "$d/Bin/shim.so"
  printf 'Bin/*\n' > "$d/.gitignore"
  printf '.planning/\nCLAUDE.md\ngitignore.public\n' > "$d/tools/ci/release-never-ship.txt"
  printf 'public overlay gitignore\n' > "$d/tools/ci/release-overlay/gitignore.public"
  printf 'new planning\n' > "$d/.planning/new.md"
  printf 'private\n' > "$d/CLAUDE.md"
  printf 'private continue\n' > "$d/.continue-here.md"
  printf 'feature\n' > "$d/src/b.txt"
  gitc "$d" add -A
  gitc "$d" add -f Bin/shim.so 2> /dev/null || git -C "$d" add -f Bin/shim.so
  gitc "$d" commit -q -m work
  # untracked junk in the working directory must never reach the candidate
  mkdir -p "$d/tmpjunk"
  printf 'junk\n' > "$d/tmpjunk/x.txt"
  printf 'junk\n' > "$d/untracked-root.txt"
}

selftest() {
  command -v git > /dev/null 2>&1 || { echo "SELFTEST=FAIL reason=no-git"; exit 1; }
  local R M C T C2 T2 st_before st_after
  S=$(mktemp -d) || { echo "SELFTEST=FAIL reason=no-tmpdir"; exit 1; }
  trap 'rm -rf "$S"' EXIT
  R=$S/r1
  mkbase "$R"
  M=$S/msg.txt
  printf 'Release test\n\nBody paragraph.\n' > "$M"

  st_before=$(cd "$R" && git status --porcelain --untracked-files=all; git diff --cached --name-status)
  brun "$R" --label t1 --message-file "$M" --base base0
  C=$(cand_of); T=$(tree_of)
  st_after=$(cd "$R" && git status --porcelain --untracked-files=all; git diff --cached --name-status)
  if [ "$BRC" = 0 ] && [ -n "$C" ]; then report builds-with-defaults P P; else report builds-with-defaults P F; fi

  prop one-parent-is-base bash -c '[ "$(git -C "$1" rev-list --parents -n1 "$2" | wc -w)" = 2 ] && [ "$(git -C "$1" rev-parse "$2^")" = "$(git -C "$1" rev-parse base0)" ]' _ "$R" "$C"
  prop never-ship-removed bash -c '! git -C "$1" cat-file -e "$2:CLAUDE.md" && ! git -C "$1" cat-file -e "$2:.planning/new.md" && ! git -C "$1" cat-file -e "$2:tools/ci/release-overlay/gitignore.public"' _ "$R" "$C"
  prop overlay-applied bash -c '[ "$(git -C "$1" rev-parse "$2:.gitignore")" = "$(git -C "$1" rev-parse HEAD:tools/ci/release-overlay/gitignore.public)" ]' _ "$R" "$C"
  prop legacy-delete-default bash -c '! git -C "$1" cat-file -e "$2:.planning/legacy.md"' _ "$R" "$C"
  prop continue-here-delete-default bash -c '! git -C "$1" cat-file -e "$2:.continue-here.md"' _ "$R" "$C"
  prop ignored-but-tracked-kept bash -c 'git -C "$1" cat-file -e "$2:Bin/shim.so"' _ "$R" "$C"
  prop working-directory-junk-absent bash -c '! git -C "$1" cat-file -e "$2:tmpjunk/x.txt" && ! git -C "$1" cat-file -e "$2:untracked-root.txt"' _ "$R" "$C"
  prop feature-file-kept bash -c 'git -C "$1" cat-file -e "$2:src/b.txt" && git -C "$1" cat-file -e "$2:tools/ci/release-never-ship.txt"' _ "$R" "$C"
  prop branch-created bash -c '[ "$(git -C "$1" rev-parse refs/heads/release/t1)" = "$2" ]' _ "$R" "$C"
  prop worktree-and-index-untouched bash -c '[ "$1" = "$2" ]' _ "$st_before" "$st_after"

  sleep 1 # a wall-clock date in the commit would differ now
  brun "$R" --label t1 --message-file "$M" --base base0
  C2=$(cand_of); T2=$(tree_of)
  prop two-runs-identical bash -c '[ -n "$1" ] && [ "$1" = "$2" ] && [ "$3" = "$4" ]' _ "$C" "$C2" "$T" "$T2"

  brun "$R" --label t2 --message-file "$M" --base base0 --legacy-planning keep
  C2=$(cand_of)
  prop legacy-keep bash -c '[ -n "$2" ] && [ "$(git -C "$1" rev-parse "$2:.planning/legacy.md")" = "$(git -C "$1" rev-parse base0:.planning/legacy.md)" ] && ! git -C "$1" cat-file -e "$2:.planning/new.md"' _ "$R" "$C2"

  brun "$R" --label t3 --message-file "$M" --base base0 --continue-here keep
  C2=$(cand_of)
  prop continue-here-keep bash -c '[ -n "$2" ] && [ "$(git -C "$1" rev-parse "$2:.continue-here.md")" = "$(git -C "$1" rev-parse base0:.continue-here.md)" ]' _ "$R" "$C2"

  refuse_case missing-message-file "$R" --label t4 --message-file "$S/no-such-message.txt" --base base0
  refuse_case unknown-base "$R" --label t5 --message-file "$M" --base no-such-base-79
  refuse_case bad-legacy-value "$R" --label t6 --message-file "$M" --base base0 --legacy-planning maybe
  prop no-branch-after-refusal bash -c '! git -C "$1" rev-parse -q --verify refs/heads/release/t4 && ! git -C "$1" rev-parse -q --verify refs/heads/release/t5' _ "$R"

  # a HEAD without the public .gitignore overlay never becomes a candidate
  local R2=$S/r2
  mkbase "$R2"
  gitc "$R2" rm -q tools/ci/release-overlay/gitignore.public
  gitc "$R2" commit -q -m "drop overlay"
  refuse_case head-without-overlay "$R2" --label t7 --message-file "$M" --base base0

  if [ "$SELFTEST_BAD" = 0 ]; then
    echo "SELFTEST=PASS cases=$SELFTEST_CASES"
    exit 0
  fi
  echo "SELFTEST=FAIL cases=$SELFTEST_CASES mismatches=$SELFTEST_BAD"
  exit 1
}

# ---------------------------------------------------------------------- main
if [ "${1:-}" = selftest ]; then
  selftest
fi
[ $# -gt 0 ] || refuse "usage: build-release-commit.sh --label <l> --message-file <f> [--base <rev>] [--legacy-planning keep|delete] [--continue-here keep|delete] | selftest"
build "$@"
