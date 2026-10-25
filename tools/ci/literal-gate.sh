#!/usr/bin/env bash
# Literal gate (79-03, D-10): counts personal literals in a tree, in gzip
# content and in a commit message. Prints COUNTS AND PATHS ONLY, never a match.
#
# Usage:  LITERALS_DIR=<dir> literal-gate.sh worktree [pathspec...]
#         LITERALS_DIR=<dir> literal-gate.sh tree <rev>
#         LITERALS_DIR=<dir> literal-gate.sh message <rev>
#         LITERALS_DIR=<dir> literal-gate.sh all <rev>        (tree + message)
#         LITERALS_DIR=<dir> literal-gate.sh dir <path>       (extracted zip)
#                            literal-gate.sh selftest         (no LITERALS_DIR)
#
#   worktree  tracked files, working-tree content; pathspecs are relative to
#             the repository root (default: everything)
#   tree      one revision (commit or tree), committed content
#   message   author, committer and body of one commit
#   dir       a plain directory outside git
#
# LITERALS_DIR holds two files, one literal per line, no empty line:
#   literals-substr.txt   matched as substring, case-insensitive
#   literals-word.txt     matched as whole word, case-insensitive
# They live OUTSIDE the repository (dir 700, files 600). Missing dir, missing,
# empty or unreadable file, or an empty line is ERROR: an empty pattern would
# match everything and a missing one nothing.
#
# Passes: substring, whole word, gzip content (every *.gz is decompressed and
# both passes run on the result; the raw .gz bytes are skipped in the first two).
# Not scanned: .planning/ and every path of release-never-ship.txt.
#
# Output:  LITERAL_HITS substr=<n> word=<n> gz=<n> message=<n|na>
#          HIT_FILE <path> <count>          (at most 20)
#          LITERAL_GATE=PASS|FAIL|ERROR
# Exit:    0 PASS, 1 FAIL, 2 ERROR
# Selftest: one line per case, "case=<name> expect=<P|F|E> got=<P|F|E>", then
#          SELFTEST=PASS cases=<n> (exit 0) or SELFTEST=FAIL ... (exit 1).

set -u
export LC_ALL=C

SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
NEVER_FILE=$(dirname "$SELF")/release-never-ship.txt

TMP=$(mktemp -d) || { echo "LITERAL_GATE=ERROR"; exit 2; }
trap 'rm -rf "$TMP"' EXIT

fail_error() {
  echo "ERROR reason=$1"
  echo "LITERAL_GATE=ERROR"
  exit 2
}

# ---------------------------------------------------------------- never-ship
NEVER=()
load_never() {
  [ -r "$NEVER_FILE" ] || fail_error "release-never-ship.txt unreadable"
  local line
  while IFS= read -r line; do
    NEVER+=("$line")
  done < <(sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$NEVER_FILE")
  [ "${#NEVER[@]}" -gt 0 ] || fail_error "release-never-ship.txt has no pattern"
}

# never_ship <path>: 0 if the path is excluded (planning data or never-ship list)
never_ship() {
  local p=$1 pat
  case "$p" in .planning/*) return 0 ;; esac
  for pat in "${NEVER[@]}"; do
    case "$pat" in
      */) [[ "$p" == $pat* ]] && return 0 ;;
      *)  [[ "$p" == $pat || "$p" == */$pat || "$p" == $pat/* || "$p" == */$pat/* ]] && return 0 ;;
    esac
  done
  return 1
}

# ------------------------------------------------------------------ literals
LIT_SUBSTR=
LIT_WORD=
need_literals() {
  [ -n "${LITERALS_DIR:-}" ] || fail_error "LITERALS_DIR is not set"
  [ -d "$LITERALS_DIR" ] || fail_error "LITERALS_DIR is not a directory"
  local f
  for f in literals-substr.txt literals-word.txt; do
    [ -f "$LITERALS_DIR/$f" ] || fail_error "$f is missing"
    [ -r "$LITERALS_DIR/$f" ] || fail_error "$f is unreadable"
    [ -s "$LITERALS_DIR/$f" ] || fail_error "$f is empty"
    awk 'length($0) == 0 { bad = 1 } END { exit bad }' "$LITERALS_DIR/$f" \
      || fail_error "$f has an empty line"
  done
  LIT_SUBSTR=$LITERALS_DIR/literals-substr.txt
  LIT_WORD=$LITERALS_DIR/literals-word.txt
}

# ------------------------------------------------------------------- counters
SUBSTR_N=0
WORD_N=0
GZ_N=0
MSG_N=0
MSG_CHECKED=0
HITS=$TMP/hits.tsv
: > "$HITS"

add_hit() { printf '%s\t%s\n' "$1" "$2" >> "$HITS"; }

# grep_count <file>: prints "<substr> <word>" for the content of one file
grep_count() {
  local s w
  s=$(command grep -a -i -c -F -f "$LIT_SUBSTR" -- "$1")
  w=$(command grep -a -i -c -w -F -f "$LIT_WORD" -- "$1")
  echo "${s:-0} ${w:-0}"
}

# parse_counts <file> <strip-prefix> <passname>: reads "name\0count\n" records
parse_counts() {
  local file=$1 prefix=$2 pass=$3 name cnt path
  while IFS= read -r -d '' name && IFS= read -r cnt; do
    path=${name#"$prefix"}
    [ "${cnt:-0}" -gt 0 ] 2>/dev/null || continue
    never_ship "$path" && continue
    case "$path" in *.gz) continue ;; esac
    if [ "$pass" = substr ]; then SUBSTR_N=$((SUBSTR_N + cnt)); else WORD_N=$((WORD_N + cnt)); fi
    add_hit "$path" "$cnt"
  done < "$file"
}

# scan_git <rev|""> <pathspec...>: substring and word pass over a git tree
scan_git() {
  local rev=$1 rc out
  shift
  local -a paths=("$@")
  [ "${#paths[@]}" -gt 0 ] || paths=(.)
  local -a revarg=()
  [ -n "$rev" ] && revarg=("$rev")

  out=$TMP/g-substr.out
  git grep -c -z -a -i -F -f "$LIT_SUBSTR" ${revarg[@]+"${revarg[@]}"} -- "${paths[@]}" \
    ':(exclude).planning' ':(exclude)*.gz' > "$out" 2> "$TMP/g.err"
  rc=$?
  [ "$rc" -le 1 ] || fail_error "git grep failed (substring pass, rc=$rc)"
  parse_counts "$out" "${rev:+$rev:}" substr

  out=$TMP/g-word.out
  git grep -c -z -a -i -w -F -f "$LIT_WORD" ${revarg[@]+"${revarg[@]}"} -- "${paths[@]}" \
    ':(exclude).planning' ':(exclude)*.gz' > "$out" 2> "$TMP/g.err"
  rc=$?
  [ "$rc" -le 1 ] || fail_error "git grep failed (word pass, rc=$rc)"
  parse_counts "$out" "${rev:+$rev:}" word
}

# scan_gz_git <rev|""> <pathspec...>: gzip content of tracked *.gz files
scan_gz_git() {
  local rev=$1 path pair s w
  shift
  local -a paths=("$@")
  [ "${#paths[@]}" -gt 0 ] || paths=(.)
  local list=$TMP/gz.list
  if [ -n "$rev" ]; then
    git ls-tree -r -z --name-only "$rev" -- "${paths[@]}" > "$list" || fail_error "git ls-tree failed"
  else
    git ls-files -z -- "${paths[@]}" > "$list" || fail_error "git ls-files failed"
  fi
  while IFS= read -r -d '' path; do
    case "$path" in *.gz) ;; *) continue ;; esac
    never_ship "$path" && continue
    if [ -n "$rev" ]; then
      git show "$rev:$path" > "$TMP/gz.raw" 2> /dev/null || fail_error "cannot read a gzip file"
    else
      [ -f "$path" ] || continue
      cp -- "$path" "$TMP/gz.raw" || fail_error "cannot read a gzip file"
    fi
    gzip -dc < "$TMP/gz.raw" > "$TMP/gz.plain" 2> /dev/null || fail_error "a gzip file does not decompress"
    pair=$(grep_count "$TMP/gz.plain")
    s=${pair% *}
    w=${pair#* }
    if [ $((s + w)) -gt 0 ]; then
      GZ_N=$((GZ_N + s + w))
      add_hit "$path" $((s + w))
    fi
  done < "$list"
}

scan_message() {
  local rev=$1 pair s w
  git log -1 --format='%an%n%ae%n%cn%n%ce%n%B' "$rev" > "$TMP/msg.txt" 2> /dev/null \
    || fail_error "cannot read the commit message"
  pair=$(grep_count "$TMP/msg.txt")
  s=${pair% *}
  w=${pair#* }
  MSG_N=$((MSG_N + s + w))
  MSG_CHECKED=1
  if [ $((s + w)) -gt 0 ]; then add_hit "(commit message $rev)" $((s + w)); fi
}

scan_dir() {
  local dir=${1%/} rc out f rel
  [ -d "$dir" ] || fail_error "not a directory"
  for pass in substr word; do
    out=$TMP/d-$pass.out
    if [ "$pass" = substr ]; then
      command grep -r -c -Z -a -i -F -f "$LIT_SUBSTR" -- "$dir" > "$out" 2> /dev/null
    else
      command grep -r -c -Z -a -i -w -F -f "$LIT_WORD" -- "$dir" > "$out" 2> /dev/null
    fi
    rc=$?
    [ "$rc" -le 1 ] || fail_error "grep failed on the directory ($pass pass, rc=$rc)"
    parse_counts "$out" "$dir/" "$pass"
  done
  while IFS= read -r -d '' f; do
    rel=${f#"$dir"/}
    never_ship "$rel" && continue
    gzip -dc < "$f" > "$TMP/gz.plain" 2> /dev/null || fail_error "a gzip file does not decompress"
    local pair s w
    pair=$(grep_count "$TMP/gz.plain")
    s=${pair% *}
    w=${pair#* }
    if [ $((s + w)) -gt 0 ]; then
      GZ_N=$((GZ_N + s + w))
      add_hit "$rel" $((s + w))
    fi
  done < <(find "$dir" -type f -name '*.gz' -print0)
}

# ------------------------------------------------------------------- report
report() {
  local total=$((SUBSTR_N + WORD_N + GZ_N + MSG_N)) msg=na n
  [ "$MSG_CHECKED" = 1 ] && msg=$MSG_N
  echo "LITERAL_HITS substr=$SUBSTR_N word=$WORD_N gz=$GZ_N message=$msg"
  if [ -s "$HITS" ]; then
    awk -F '\t' '{ c[$1] += $2 } END { for (p in c) printf "%s\t%d\n", p, c[p] }' "$HITS" \
      | sort -t "$(printf '\t')" -k1,1 > "$TMP/hits.agg"
    n=$(wc -l < "$TMP/hits.agg")
    head -n 20 "$TMP/hits.agg" | awk -F '\t' '{ printf "HIT_FILE %s %s\n", $1, $2 }'
    [ "$n" -le 20 ] || echo "HIT_FILES_TRUNCATED more=$((n - 20))"
  fi
  if [ "$total" -gt 0 ]; then
    echo "LITERAL_GATE=FAIL"
    return 1
  fi
  echo "LITERAL_GATE=PASS"
  return 0
}

# ------------------------------------------------------------------ selftest
SELFTEST_CASES=0
SELFTEST_BAD=0

# run_case <name> <expect P|F|E> <class|-> <repo-cwd> <literals-dir|-> <args...>
run_case() {
  local name=$1 expect=$2 class=$3 cwd=$4 ldir=$5 out rc got=X hits v
  shift 5
  if [ "$ldir" = - ]; then
    out=$(cd "$cwd" && env -u LITERALS_DIR bash "$SELF" "$@" 2>&1)
  else
    out=$(cd "$cwd" && LITERALS_DIR=$ldir bash "$SELF" "$@" 2>&1)
  fi
  rc=$?
  case "$rc" in
    0) printf '%s\n' "$out" | command grep -q '^LITERAL_GATE=PASS$' && got=P ;;
    1) printf '%s\n' "$out" | command grep -q '^LITERAL_GATE=FAIL$' && got=F ;;
    2) printf '%s\n' "$out" | command grep -q '^LITERAL_GATE=ERROR$' && got=E ;;
  esac
  # a MUST-FAIL case counts only when the intended pass saw the hit
  if [ "$got" = F ] && [ "$class" != - ]; then
    hits=$(printf '%s\n' "$out" | command grep '^LITERAL_HITS ')
    v=$(printf '%s\n' "$hits" | sed -n "s/.* $class=\([0-9]*\).*/\1/p")
    [ "${v:-0}" -gt 0 ] || got=X
  fi
  # a leak check: no output line may carry a synthetic literal
  if printf '%s\n' "$out" | command grep -q -i -e 'zqlit'; then got=X; fi
  printf 'case=%s expect=%s got=%s\n' "$name" "$expect" "$got"
  SELFTEST_CASES=$((SELFTEST_CASES + 1))
  [ "$expect" = "$got" ] || SELFTEST_BAD=$((SELFTEST_BAD + 1))
}

# mkrepo <dir>: scratch repo helper functions use this
GITC=(git -c user.name=t -c user.email=t@t -c commit.gpgsign=false -c core.hooksPath=/dev/null)
repo_init() { mkdir -p "$1" && git -C "$1" init -q; }
repo_commit() { # <dir> <msg> [extra -c opts as one string]
  git -C "$1" add -A -f && "${GITC[@]}" -C "$1" commit -q --allow-empty -m "$2"
}

selftest() {
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
  command -v git > /dev/null 2>&1 || { echo "SELFTEST=FAIL reason=no-git"; exit 1; }
  local S=$TMP/self
  rm -rf "$S"
  mkdir -p "$S/lits" "$S/lits-empty" "$S/lits-nowords"
  local SUB=zqlit-sub-7731 WRD=zqlitword7731
  printf '%s\n' "$SUB" > "$S/lits/literals-substr.txt"
  printf '%s\n' "$WRD" > "$S/lits/literals-word.txt"
  printf '%s\n\n%s\n' "$SUB" "$SUB-x" > "$S/lits-empty/literals-substr.txt"
  printf '%s\n' "$WRD" > "$S/lits-empty/literals-word.txt"
  printf '%s\n' "$SUB" > "$S/lits-nowords/literals-substr.txt"
  local L=$S/lits R

  # clean repo: innocuous text, an innocuous gzip, a literal only under .planning/
  R=$S/clean; repo_init "$R"
  printf 'nothing to see\n' > "$R/a.txt"
  printf 'plain text\n' | gzip -n > "$R/ok.txt.gz"
  mkdir -p "$R/.planning" && printf 'x %s x\n' "$SUB" > "$R/.planning/n.md"
  repo_commit "$R" "clean commit"
  run_case clean-tree            P - "$R" "$L" tree HEAD
  run_case clean-all             P - "$R" "$L" all HEAD
  run_case clean-worktree        P - "$R" "$L" worktree
  run_case planning-is-excluded  P - "$R" "$L" tree HEAD

  # never-ship names are not scanned: they do not ship
  R=$S/neverlist; repo_init "$R"
  mkdir -p "$R/soloist-releases/x86_64-linux" "$R/sub"
  printf 'x %s x\n' "$SUB" > "$R/soloist-releases/x86_64-linux/a.txt"
  printf 'x %s x\n' "$SUB" > "$R/sub/k.key"
  printf 'fine\n' > "$R/b.txt"
  repo_commit "$R" "never-ship names"
  run_case never-ship-excluded   P - "$R" "$L" tree HEAD

  # substring pass, case-insensitive
  R=$S/plain; repo_init "$R"
  printf 'x %s x\n' "$SUB" > "$R/a.txt"
  repo_commit "$R" "plain hit"
  run_case plain-substr          F substr "$R" "$L" tree HEAD
  R=$S/upper; repo_init "$R"
  printf 'x %s x\n' "$(printf '%s' "$SUB" | tr 'a-z' 'A-Z')" > "$R/a.txt"
  repo_commit "$R" "upper hit"
  run_case case-insensitive      F substr "$R" "$L" tree HEAD

  # gzip content: invisible to the byte passes, caught by the gz pass
  R=$S/gz; repo_init "$R"
  printf 'x %s x\n' "$SUB" | gzip -n > "$R/d.txt.gz"
  repo_commit "$R" "gzip hit"
  run_case gzip-content          F gz "$R" "$L" tree HEAD
  run_case gzip-content-worktree F gz "$R" "$L" worktree

  # whole-word pass
  R=$S/word; repo_init "$R"
  printf 'x %s x\n' "$WRD" > "$R/w.txt"
  repo_commit "$R" "word hit"
  run_case word-hit              F word "$R" "$L" tree HEAD
  R=$S/longer; repo_init "$R"
  printf 'x %sx and y%s\n' "$WRD" "$WRD" > "$R/w.txt"
  repo_commit "$R" "word inside a longer word"
  run_case word-in-longer-word   P - "$R" "$L" tree HEAD

  # commit message: body, and author name
  R=$S/msg; repo_init "$R"
  printf 'fine\n' > "$R/a.txt"
  repo_commit "$R" "subject with $SUB inside"
  run_case message-body          F message "$R" "$L" message HEAD
  run_case message-body-tree-clean P - "$R" "$L" tree HEAD
  run_case message-all           F message "$R" "$L" all HEAD
  R=$S/author; repo_init "$R"
  printf 'fine\n' > "$R/a.txt"
  git -C "$R" add -A && git -C "$R" -c user.name="$WRD" -c user.email=t@t -c commit.gpgsign=false \
    -c core.hooksPath=/dev/null commit -q -m "clean subject"
  run_case message-author-name   F message "$R" "$L" message HEAD

  # worktree mode: uncommitted tracked change, pathspec, untracked file
  R=$S/dirty; repo_init "$R"
  printf 'fine\n' > "$R/a.txt"
  printf 'fine\n' > "$R/b.txt"
  repo_commit "$R" "base"
  printf 'x %s x\n' "$SUB" >> "$R/a.txt"
  run_case worktree-dirty        F substr "$R" "$L" worktree
  run_case dirty-tree-head-clean P - "$R" "$L" tree HEAD
  run_case worktree-pathspec-clean P - "$R" "$L" worktree b.txt
  run_case worktree-pathspec-dirty F substr "$R" "$L" worktree a.txt
  R=$S/untracked; repo_init "$R"
  printf 'fine\n' > "$R/a.txt"
  repo_commit "$R" "base"
  printf 'x %s x\n' "$SUB" > "$R/new.txt"
  run_case untracked-not-scanned P - "$R" "$L" worktree

  # plain directory (extracted zip)
  mkdir -p "$S/dir-bad/p" "$S/dir-ok/p" "$S/dir-gz"
  printf 'x %s x\n' "$SUB" > "$S/dir-bad/p/a.txt"
  printf 'fine\n' > "$S/dir-ok/p/a.txt"
  printf 'x %s x\n' "$SUB" | gzip -n > "$S/dir-gz/d.txt.gz"
  run_case dir-hit               F substr "$S" "$L" dir "$S/dir-bad"
  run_case dir-clean             P - "$S" "$L" dir "$S/dir-ok"
  run_case dir-gzip              F gz "$S" "$L" dir "$S/dir-gz"

  # ERROR paths: a gate that cannot look must say so, never PASS
  run_case no-literals-dir       E - "$R" - worktree
  run_case literal-empty-line    E - "$R" "$S/lits-empty" worktree
  run_case literal-file-missing  E - "$R" "$S/lits-nowords" worktree
  run_case literals-dir-absent   E - "$R" "$S/does-not-exist" worktree
  run_case unknown-rev           E - "$R" "$L" tree no-such-rev-79

  if [ "$SELFTEST_BAD" = 0 ]; then
    echo "SELFTEST=PASS cases=$SELFTEST_CASES"
    exit 0
  fi
  echo "SELFTEST=FAIL cases=$SELFTEST_CASES mismatches=$SELFTEST_BAD"
  exit 1
}

# ---------------------------------------------------------------------- main
MODE=${1:-}
[ -n "$MODE" ] || fail_error "usage: literal-gate.sh selftest|worktree|tree|message|all|dir"
shift

if [ "$MODE" = selftest ]; then
  load_never
  selftest
fi

load_never
need_literals

case "$MODE" in
  worktree)
    top=$(git rev-parse --show-toplevel 2> /dev/null) || fail_error "not inside a git work tree"
    cd "$top" || fail_error "cannot enter the work tree"
    scan_git "" "$@"
    scan_gz_git "" "$@"
    ;;
  tree|all)
    [ $# -eq 1 ] || fail_error "$MODE needs exactly one rev"
    git rev-parse --verify -q "$1^{tree}" > /dev/null 2>&1 || fail_error "unknown rev"
    top=$(git rev-parse --show-toplevel 2> /dev/null) || fail_error "not inside a git work tree"
    cd "$top" || fail_error "cannot enter the work tree"
    scan_git "$1"
    scan_gz_git "$1"
    [ "$MODE" = all ] && scan_message "$1"
    ;;
  message)
    [ $# -eq 1 ] || fail_error "message needs exactly one rev"
    git rev-parse --verify -q "$1^{commit}" > /dev/null 2>&1 || fail_error "unknown rev"
    scan_message "$1"
    ;;
  dir)
    [ $# -eq 1 ] || fail_error "dir needs exactly one path"
    scan_dir "$1"
    ;;
  *)
    fail_error "unknown mode"
    ;;
esac

report
exit $?
