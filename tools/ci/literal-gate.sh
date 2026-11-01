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
# Passes: substring, whole word, file names, compressed content.
#   names    every path of the scanned set (tree, worktree or dir) is matched
#            against both lists (79-64, FULL-5 WR-05); a hit counts once per
#            path and pass.
#   gz       every *.gz / *.tgz is decompressed and both passes run on the
#            result; the raw .gz bytes are skipped in the first two.
#   archive  the other compressed member types: *.bz2 *.tbz *.tbz2 (bzip2),
#            *.xz *.txz (xz), *.zst *.tzst (zstd), and the zip family *.zip
#            *.jar *.docx *.xlsx *.pptx *.odt *.ods *.odp *.epub *.apk *.whl
#            (every member's name and content, read with Perl's core
#            IO::Uncompress::Unzip). A compressed type the gate cannot open
#            (*.7z *.rar *.lz *.lz4 *.lzma *.Z *.cab *.arj) is ERROR, never
#            PASS. Archives inside archives are not opened (the release ships
#            none; today the tree ships only *.gz).
# Not scanned: .planning/ and every path of release-never-ship.txt.
# A HIT_FILE path that itself carries a literal is printed as
# "(path withheld: its name carries a literal)", never verbatim.
#
# Output:  LITERAL_HITS substr=<n> word=<n> names=<n> gz=<n> archive=<n> message=<n|na>
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
NAMES_N=0
ARCH_N=0
MSG_N=0
MSG_CHECKED=0
HITS=$TMP/hits.tsv
: > "$HITS"

# add_hit <path> <count>: a path that carries a literal is never printed
add_hit() {
  local p=$1
  if printf '%s\n' "$p" | command grep -q -i -F -f "$LIT_SUBSTR" \
     || printf '%s\n' "$p" | command grep -q -i -w -F -f "$LIT_WORD"; then
    p="(path withheld: its name carries a literal)"
  fi
  printf '%s\t%s\n' "$p" "$2" >> "$HITS"
}

# archive_kind <path>: gz | bz2 | xz | zst | zip | unsupported | none
archive_kind() {
  local p
  p=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
  case "$p" in
    *.gz|*.tgz) echo gz ;;
    *.bz2|*.tbz|*.tbz2) echo bz2 ;;
    *.xz|*.txz) echo xz ;;
    *.zst|*.tzst) echo zst ;;
    *.zip|*.jar|*.docx|*.xlsx|*.pptx|*.odt|*.ods|*.odp|*.epub|*.apk|*.whl) echo zip ;;
    *.7z|*.rar|*.lz|*.lz4|*.lzma|*.z|*.cab|*.arj) echo unsupported ;;
    *) echo none ;;
  esac
}

# Prints every member name and member content of a zip file (core Perl only).
UNZIP_PL='use strict; use IO::Uncompress::Unzip qw($UnzipError);
my $u = IO::Uncompress::Unzip->new($ARGV[0]) or exit 3;
my $st;
for ($st = 1; $st > 0; $st = $u->nextStream()) {
  my $h = $u->getHeaderInfo(); print "\n", $h->{Name}, "\n";
  my $buf; while (($st = $u->read($buf)) > 0) { print $buf } last if $st < 0;
}
exit($st < 0 ? 3 : 0);'

# expand <kind> <raw> <plain>: decompressed bytes (and zip member names) of one file
expand() {
  local kind=$1 raw=$2 plain=$3
  case "$kind" in
    gz)  gzip -dc < "$raw" > "$plain" 2> /dev/null || fail_error "a gzip file does not decompress" ;;
    bz2) command -v bzip2 > /dev/null 2>&1 || fail_error "bzip2 is missing, a .bz2 file cannot be read"
         bzip2 -dc < "$raw" > "$plain" 2> /dev/null || fail_error "a bzip2 file does not decompress" ;;
    xz)  command -v xz > /dev/null 2>&1 || fail_error "xz is missing, a .xz file cannot be read"
         xz -dc < "$raw" > "$plain" 2> /dev/null || fail_error "an xz file does not decompress" ;;
    zst) command -v zstd > /dev/null 2>&1 || fail_error "zstd is missing, a .zst file cannot be read"
         zstd -q -dc < "$raw" > "$plain" 2> /dev/null || fail_error "a zstd file does not decompress" ;;
    zip) perl -e "$UNZIP_PL" "$raw" > "$plain" 2> /dev/null || fail_error "a zip file does not open" ;;
    *)   fail_error "unsupported compressed type (the gate cannot look inside it)" ;;
  esac
}

# scan_member <path> <kind> <raw>: both passes over the expanded content
scan_member() {
  local path=$1 kind=$2 raw=$3 pair s w
  expand "$kind" "$raw" "$TMP/arch.plain"
  pair=$(grep_count "$TMP/arch.plain")
  s=${pair% *}
  w=${pair#* }
  if [ $((s + w)) -gt 0 ]; then
    if [ "$kind" = gz ]; then GZ_N=$((GZ_N + s + w)); else ARCH_N=$((ARCH_N + s + w)); fi
    add_hit "$path" $((s + w))
  fi
}

# scan_names <nul-list> <strip-prefix>: literals in path names
scan_names() {
  local list=$1 prefix=$2 cand path n
  cand=$TMP/names.cand
  # cheap prefilter first; never_ship only runs on the few candidates
  tr '\0' '\n' < "$list" | sed "s|^$(printf '%s' "$prefix" | sed 's/[][\.*^$|]/\\&/g')||" > "$TMP/names.all"
  { command grep -i -F -f "$LIT_SUBSTR" "$TMP/names.all"; command grep -i -w -F -f "$LIT_WORD" "$TMP/names.all"; } \
    | sort -u > "$cand"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    never_ship "$path" && continue
    n=0
    printf '%s\n' "$path" | command grep -q -i -F -f "$LIT_SUBSTR" && n=$((n + 1))
    printf '%s\n' "$path" | command grep -q -i -w -F -f "$LIT_WORD" && n=$((n + 1))
    [ "$n" -gt 0 ] || continue
    NAMES_N=$((NAMES_N + n))
    add_hit "$path" "$n"
  done < "$cand"
}

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

# scan_files_git <rev|""> <pathspec...>: names and compressed content of the
# tracked set
scan_files_git() {
  local rev=$1 path kind
  shift
  local -a paths=("$@")
  [ "${#paths[@]}" -gt 0 ] || paths=(.)
  local list=$TMP/files.list
  if [ -n "$rev" ]; then
    git ls-tree -r -z --name-only "$rev" -- "${paths[@]}" > "$list" || fail_error "git ls-tree failed"
  else
    git ls-files -z -- "${paths[@]}" > "$list" || fail_error "git ls-files failed"
  fi
  scan_names "$list" ""
  while IFS= read -r -d '' path; do
    kind=$(archive_kind "$path")
    [ "$kind" = none ] && continue
    never_ship "$path" && continue
    if [ -n "$rev" ]; then
      git show "$rev:$path" > "$TMP/arch.raw" 2> /dev/null || fail_error "cannot read a compressed file"
    else
      [ -f "$path" ] || continue
      cp -- "$path" "$TMP/arch.raw" || fail_error "cannot read a compressed file"
    fi
    scan_member "$path" "$kind" "$TMP/arch.raw"
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
  find "$dir" \( -type f -o -type l \) -print0 > "$TMP/dir.list" || fail_error "cannot list the directory"
  scan_names "$TMP/dir.list" "$dir/"
  local kind
  while IFS= read -r -d '' f; do
    [ -f "$f" ] || continue
    rel=${f#"$dir"/}
    kind=$(archive_kind "$rel")
    [ "$kind" = none ] && continue
    never_ship "$rel" && continue
    scan_member "$rel" "$kind" "$f"
  done < "$TMP/dir.list"
}

# ------------------------------------------------------------------- report
report() {
  local total=$((SUBSTR_N + WORD_N + NAMES_N + GZ_N + ARCH_N + MSG_N)) msg=na n
  [ "$MSG_CHECKED" = 1 ] && msg=$MSG_N
  echo "LITERAL_HITS substr=$SUBSTR_N word=$WORD_N names=$NAMES_N gz=$GZ_N archive=$ARCH_N message=$msg"
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

  # 79-64 FULL-5 WR-05: literals in file names and in non-gz compressed members
  local ZIPMK='use IO::Compress::Zip qw(zip $ZipError); my ($f, $m, $c) = @ARGV; zip(\$c => $f, Name => $m) or die $ZipError;'
  R=$S/name-sub; repo_init "$R"
  mkdir -p "$R/tools/uat" && printf 'fine\n' > "$R/tools/uat/$SUB-probe.sh"
  repo_commit "$R" "literal in a file name"
  run_case literal-in-filename   F names "$R" "$L" tree HEAD
  run_case literal-in-filename-worktree F names "$R" "$L" worktree
  R=$S/name-word; repo_init "$R"
  mkdir -p "$R/t/fixtures/$WRD" && printf 'fine\n' > "$R/t/fixtures/$WRD/run1.txt"
  repo_commit "$R" "word literal in a directory name"
  run_case word-in-dirname       F names "$R" "$L" tree HEAD
  R=$S/name-never; repo_init "$R"
  mkdir -p "$R/soloist-releases" && printf 'fine\n' > "$R/soloist-releases/$SUB.txt"
  printf 'fine\n' > "$R/a.txt"
  repo_commit "$R" "literal name on a never-ship path"
  run_case filename-never-ship   P - "$R" "$L" tree HEAD
  R=$S/zip; repo_init "$R"
  perl -e "$ZIPMK" "$R/bundle.zip" inner.txt "$(printf 'x%.0s' $(seq 1 200)) $SUB $(printf 'y%.0s' $(seq 1 200))"
  repo_commit "$R" "zip member hit"
  run_case zip-member            F archive "$R" "$L" tree HEAD
  run_case zip-member-worktree   F archive "$R" "$L" worktree
  R=$S/zip-ok; repo_init "$R"
  perl -e "$ZIPMK" "$R/bundle.zip" inner.txt "nothing to see"
  printf 'plain\n' | xz > "$R/ok.txt.xz" 2> /dev/null || printf 'plain\n' | gzip -n > "$R/ok.txt.gz"
  repo_commit "$R" "clean zip"
  run_case zip-clean             P - "$R" "$L" tree HEAD
  R=$S/xz; repo_init "$R"
  if command -v xz > /dev/null 2>&1; then
    printf 'x %s x\n' "$SUB" | xz > "$R/d.txt.xz"
    repo_commit "$R" "xz hit"
    run_case xz-content          F archive "$R" "$L" tree HEAD
  fi
  R=$S/sevenz; repo_init "$R"
  printf 'not really 7z\n' > "$R/x.7z"
  repo_commit "$R" "unsupported archive"
  run_case unsupported-archive   E - "$R" "$L" tree HEAD
  R=$S/withheld; repo_init "$R"
  printf 'x %s x\n' "$SUB" > "$R/$SUB.txt"
  repo_commit "$R" "content hit in a file whose name carries the literal"
  run_case hit-path-withheld     F names "$R" "$L" tree HEAD
  mkdir -p "$S/dir-name/p" "$S/dir-zip"
  printf 'fine\n' > "$S/dir-name/p/$SUB.txt"
  perl -e "$ZIPMK" "$S/dir-zip/m.zip" m.txt "$(printf 'x%.0s' $(seq 1 200)) $WRD $(printf 'y%.0s' $(seq 1 200))"
  run_case dir-filename          F names "$S" "$L" dir "$S/dir-name"
  run_case dir-zip-member        F archive "$S" "$L" dir "$S/dir-zip"

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
    scan_files_git "" "$@"
    ;;
  tree|all)
    [ $# -eq 1 ] || fail_error "$MODE needs exactly one rev"
    git rev-parse --verify -q "$1^{tree}" > /dev/null 2>&1 || fail_error "unknown rev"
    top=$(git rev-parse --show-toplevel 2> /dev/null) || fail_error "not inside a git work tree"
    cd "$top" || fail_error "cannot enter the work tree"
    scan_git "$1"
    scan_files_git "$1"
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
