#!/usr/bin/env bash
# Project-local SqueezePlay build (Ralph Irving's maintained fork).
# Everything lands under tools/uat/squeezeplay/build/ (git-ignored). No sudo,
# no install into /usr, /usr/local or ~/.local. Idempotent: re-running reuses
# the clone and make's incremental state. Never starts the binary.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_URL="https://github.com/ralph-irving/squeezeplay"
PIN_SHA="758bc110e16de4a61905e19d012a0ad25d97859b"   # 2026-09-25, merge of PR #59
BUILD="$HERE/build"
SRC="$BUILD/src/squeezeplay"
PREFIX="$BUILD/prefix"
LOG="$BUILD/build.log"
mkdir -p "$BUILD/src" "$PREFIX"

fail() { echo "SQUEEZEPLAY_BUILD=FAIL $*"; exit 1; }
: >> "$LOG"

# --- host tools: only report, never install ---------------------------------
missing=""
for t in gcc make patch flex bison python3 git pkg-config; do
  command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
done
[ -z "$missing" ] || fail "missing host tools:$missing (system packages needed, ask the user)"
for h in X11/Xlib.h alsa/asoundlib.h; do
  [ -e "/usr/include/$h" ] || fail "missing dev header $h (libx11-dev / libasound2-dev)"
done

# --- source, pinned ---------------------------------------------------------
if [ ! -d "$SRC/.git" ]; then
  git clone -q "$REPO_URL" "$SRC" >>"$LOG" 2>&1 || fail "git clone"
fi
cur="$(git -C "$SRC" rev-parse HEAD 2>/dev/null)"
if [ "$cur" != "$PIN_SHA" ]; then
  git -C "$SRC" fetch -q origin >>"$LOG" 2>&1
  git -C "$SRC" checkout -q "$PIN_SHA" >>"$LOG" 2>&1 || fail "checkout $PIN_SHA"
fi
[ "$(git -C "$SRC" rev-parse HEAD)" = "$PIN_SHA" ] || fail "pin mismatch"

SP="$SRC/src"
cd "$SP" || fail "no src dir"

# --- local build adjustments (inside the git-ignored clone only) ------------
# 1. lua: LUA_USE_LINUX pulls in libreadline for the stand-alone interpreter,
#    which we do not need. Use the POSIX+dlopen flavour (as the squeezeos target).
if [ ! -e "$BUILD/.patched-lua2" ]; then
  sed -i '/^linux:/{n;s/-DLUA_USE_LINUX/-DLUA_USE_POSIX -DLUA_USE_DLOPEN/;s/-lcurses//}' lua-5.1.5/src/Makefile
  touch "$BUILD/.patched-lua2"
fi

export PATH="$PREFIX/bin:$PATH"
# gcc 15 defaults to C23; this code base is 2007-2012 C.
EXTRA="-std=gnu99 -fcommon -Wno-implicit-function-declaration -Wno-int-conversion -Wno-incompatible-pointer-types -Wno-return-mismatch -Wno-implicit-int -Wno-error"
# Derive a private makefile: relocate BUILD_TOP and swap the compiler flags.
# (Flags go in the makefile, not on the make command line - a command-line
# CFLAGS would override the sub-projects' own CFLAGS, e.g. freetype's "-c".)
sed -e "s|^export BUILD_TOP=.*|export BUILD_TOP=$PREFIX|" \
    -e "s|^export CFLAGS=.*|export CFLAGS=-I\${PREFIX}/include -I\${PREFIX}/include/SDL -I\${PREFIX}/include/freetype2 -O2 -fPIC $EXTRA|" \
    Makefile.linux > Makefile.spoton
MK=(make -f Makefile.spoton)

# tolua++ normally needs scons (not installed). Build it by hand: same sources
# and result as the SCons recipe (libtolua++.so + bin/tolua++ + tolua++.h).
build_tolua() {
  local T="$SP/tolua++-1.0.92"
  [ -x "$PREFIX/bin/tolua++" ] && [ -e "$PREFIX/lib/libtolua++.so" ] && return 0
  mkdir -p "$PREFIX/bin" "$PREFIX/lib" "$PREFIX/include"
  ( cd "$T" &&
    gcc -O2 -fPIC $EXTRA -Iinclude -I"$PREFIX/include" -shared -o "$PREFIX/lib/libtolua++.so" src/lib/*.c \
        -L"$PREFIX/lib" -Wl,-rpath,"$PREFIX/lib" -llua -lm -ldl &&
    gcc -O2 $EXTRA -Iinclude -I"$PREFIX/include" -o "$PREFIX/bin/tolua++" src/bin/tolua.c src/bin/toluabind.c \
        -L"$PREFIX/lib" -Wl,-rpath,"$PREFIX/lib" -ltolua++ -llua -lm -ldl &&
    cp include/tolua++.h "$PREFIX/include/" ) >>"$LOG" 2>&1
}

# lua-all without tolua++ (done above), plus the squeezeplay app stages.
LUA_ALL="lua luasocket slnunicode luacjson loop luaexpat luafilesystem luaprofiler luazipfilter luamd5"
for tgt in ${SP_TARGETS:-sdl-all $LUA_ALL tolua app}; do
  if [ "$tgt" = tolua ]; then
    echo "== tolua++ (manual)" | tee -a "$LOG"
    build_tolua || fail "tolua++ manual build (see $LOG)"
    continue
  fi
  echo "== make $tgt" | tee -a "$LOG"
  "${MK[@]}" "$tgt" >>"$LOG" 2>&1 || fail "make $tgt (see $LOG)"
done

BIN="$(find "$PREFIX" -type f -name jive -perm -u+x 2>/dev/null | head -1)"
[ -n "$BIN" ] || fail "no jive binary produced"
if ldd "$BIN" 2>/dev/null | command grep -q "not found"; then
  fail "unresolved libs: $(ldd "$BIN" | command grep 'not found' | tr -s ' \t' ' ' | tr '\n' ';')"
fi
echo "SQUEEZEPLAY_BUILD=PASS $BIN"
