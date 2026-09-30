#!/usr/bin/env bash
# Rebuild lib/jinja_cpp/libjinja.a (the Jinja2 chat-template engine build.zig
# links) from the vendored sources in lib/jinja_cpp — the command build.zig
# documents, as a script. Run it after any lib/jinja_cpp/*.cpp change, or to
# build from source instead of using the committed archive. It rewrites the
# tracked obj/*.o and libjinja.a.
#
# C++17 against the system libc++ (Xcode clang++), as the archive always was.
# Overrides: CXX and AR (commands, word-split, e.g. "zig c++ -target ..."),
# JINJA_OBJ_DIR and JINJA_OUT (build elsewhere, e.g. to try it on Linux
# without touching the tracked files).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
JINJA_DIR="$REPO_ROOT/lib/jinja_cpp"
OBJ_DIR="${JINJA_OBJ_DIR:-$JINJA_DIR/obj}"
OUT="${JINJA_OUT:-$JINJA_DIR/libjinja.a}"
CXX="${CXX:-clang++}"
AR="${AR:-ar}"

mkdir -p "$OBJ_DIR"
for f in jinja_wrapper caps lexer parser runtime jinja_string value; do
  echo "[build-jinja] $f.cpp"
  # shellcheck disable=SC2086 # CXX may carry arguments
  $CXX -std=c++17 -O2 -DNDEBUG -I "$JINJA_DIR" -c "$JINJA_DIR/$f.cpp" -o "$OBJ_DIR/$f.o"
done
# Fresh archive: `ar rcs` into an existing one would keep members it no longer lists.
rm -f "$OUT"
# shellcheck disable=SC2086
$AR rcs "$OUT" "$OBJ_DIR"/jinja_wrapper.o "$OBJ_DIR"/caps.o "$OBJ_DIR"/lexer.o \
  "$OBJ_DIR"/parser.o "$OBJ_DIR"/runtime.o "$OBJ_DIR"/jinja_string.o "$OBJ_DIR"/value.o
echo "[build-jinja] $OUT ($(du -h "$OUT" | cut -f1))"
