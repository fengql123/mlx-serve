#!/usr/bin/env bash
# Build llama.cpp's libllama FROM SOURCE and stage it exactly where
# scripts/fetch-llama.sh stages the prebuilt one:
#
#   lib/llama/lib/libllama.dylib   single self-contained arm64 dylib
#                                  (llama + ggml + ggml-cpu/blas/metal + mtmd),
#                                  Metal shaders EMBEDDED, install-name
#                                  @rpath/libllama.dylib, ad-hoc signed
#   lib/llama/include/*.h          the headers the XCFramework ships
#   lib/llama/.version             the tag (build.zig reads it as llama_tag)
#
# It is the macOS slice of llama.cpp's own build-xcframework.sh at the same
# tag — same CMake options, same static libs force-loaded into one dylib —
# minus the framework wrapping, the x86_64 slice and the lipo/install-name
# rewrite fetch-llama.sh needs afterwards. build.zig, app/build.sh and
# release.yml cannot tell the two stages apart.
#
# Embedded shaders (GGML_METAL_EMBED_LIBRARY=ON) embed the Metal SOURCE and
# compile it at runtime, so this needs Xcode's clang + CMake but NOT the
# separately downloaded Metal Toolchain.
#
# The tag is the one pinned in scripts/fetch-llama.sh (the single source of
# truth; LLAMA_TAG overrides both). The source is a shallow clone of that tag,
# or LLAMA_SRC=<checkout> to build an existing tree (its HEAD should be the
# tag; the stamp records what was asked for).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PINNED_TAG="$(sed -n 's/^LLAMA_TAG="\${LLAMA_TAG:-\([^}]*\)}"$/\1/p' "$SCRIPT_DIR/fetch-llama.sh")"
LLAMA_TAG="${LLAMA_TAG:-$PINNED_TAG}"
# build-xcframework.sh's MACOS_MIN_OS_VERSION at the pinned tag.
MIN_MACOS="${LLAMA_MACOS_MIN:-13.3}"

DEST="$REPO_ROOT/lib/llama"
DEST_LIB="$DEST/lib"
DEST_INC="$DEST/include"
STAMP="$DEST/.version"
BUILD_STAMP="$DEST/.build"
BUILD_ROOT="$REPO_ROOT/lib/.llama-build"
SRC="${LLAMA_SRC:-$BUILD_ROOT/src}"
BUILD="$BUILD_ROOT/build"
WANT="source tag=$LLAMA_TAG macos_min=$MIN_MACOS"

die() { echo "[build-llama] ERROR: $*" >&2; exit 1; }

[ -n "$LLAMA_TAG" ] || die "could not read LLAMA_TAG from scripts/fetch-llama.sh"

# Idempotent: skip when the staged copy is already this source build. A
# prebuilt stage (fetch-llama.sh writes no .build) is replaced.
if [ -f "$STAMP" ] && [ -f "$BUILD_STAMP" ] && [ -f "$DEST_LIB/libllama.dylib" ] && [ -f "$DEST_INC/llama.h" ]; then
  if [ "$(cat "$STAMP")" = "$LLAMA_TAG" ] && [ "$(cat "$BUILD_STAMP")" = "$WANT" ]; then
    echo "[build-llama] lib/llama already built from source at $LLAMA_TAG — nothing to do"
    exit 0
  fi
fi

command -v cmake >/dev/null 2>&1 || die "cmake not found (brew install cmake)"
xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1 || die "xcrun/macOS SDK unavailable (xcode-select --install)"

# ── Source at the pinned tag ─────────────────────────────────────────────────
if [ -z "${LLAMA_SRC:-}" ]; then
  # By ref, not `git describe`: the pinned commit can carry a second tag
  # (b10809 is also v0.4.0), and describe may name that one.
  TAG_SHA="$(git -C "$SRC" rev-parse -q --verify "refs/tags/$LLAMA_TAG^{commit}" 2>/dev/null || true)"
  if [ -z "$TAG_SHA" ] || [ "$(git -C "$SRC" rev-parse HEAD 2>/dev/null)" != "$TAG_SHA" ]; then
    rm -rf "$SRC"
    mkdir -p "$BUILD_ROOT"
    echo "[build-llama] cloning llama.cpp $LLAMA_TAG"
    git clone --quiet --depth 1 --branch "$LLAMA_TAG" https://github.com/ggml-org/llama.cpp "$SRC"
  fi
fi
[ -f "$SRC/CMakeLists.txt" ] || die "no llama.cpp source at $SRC"

# ── Configure + build the static libs (build-xcframework.sh's macOS options) ─
rm -rf "$BUILD"
cmake -S "$SRC" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN_MACOS" \
  -DBUILD_SHARED_LIBS=OFF \
  -DLLAMA_BUILD_APP=OFF \
  -DLLAMA_BUILD_COMMON=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_TOOLS=OFF \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_SERVER=OFF \
  -DLLAMA_BUILD_MTMD=ON \
  -DLLAMA_OPENSSL=OFF \
  -DGGML_METAL=ON \
  -DGGML_METAL_EMBED_LIBRARY=ON \
  -DGGML_BLAS_DEFAULT=ON \
  -DGGML_NATIVE=OFF \
  -DGGML_OPENMP=OFF
cmake --build "$BUILD" --config Release -j "$(sysctl -n hw.logicalcpu)"

LIBS=(
  "$BUILD/src/libllama.a"
  "$BUILD/ggml/src/libggml.a"
  "$BUILD/ggml/src/libggml-base.a"
  "$BUILD/ggml/src/libggml-cpu.a"
  "$BUILD/ggml/src/ggml-metal/libggml-metal.a"
  "$BUILD/ggml/src/ggml-blas/libggml-blas.a"
  "$BUILD/tools/mtmd/libmtmd.a"
  "$BUILD/vendor/hash/libvendor-hash.a"
)
for l in "${LIBS[@]}"; do [ -f "$l" ] || die "expected static lib missing: $l"; done

# ── One self-contained dylib, like the XCFramework's (combine_static_libraries) ─
rm -rf "$DEST_LIB" "$DEST_INC"
mkdir -p "$DEST_LIB" "$DEST_INC"
xcrun libtool -static -o "$BUILD/combined.a" "${LIBS[@]}" 2>/dev/null
xcrun -sdk macosx clang++ -dynamiclib \
  -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
  -arch arm64 \
  -mmacosx-version-min="$MIN_MACOS" \
  -Wl,-force_load,"$BUILD/combined.a" \
  -framework Foundation -framework Metal -framework Accelerate \
  -install_name "@rpath/libllama.dylib" \
  -o "$DEST_LIB/libllama.dylib"
xcrun strip -S "$DEST_LIB/libllama.dylib"
# strip invalidates the linker's ad-hoc signature; dyld refuses an unsigned
# arm64 dylib. Bundle steps re-sign with the Developer ID later.
codesign --force --sign - "$DEST_LIB/libllama.dylib"

# The header set build-xcframework.sh copies into llama.framework/Headers.
for h in include/llama.h ggml/include/ggml.h ggml/include/ggml-opt.h \
         ggml/include/ggml-alloc.h ggml/include/ggml-backend.h ggml/include/ggml-metal.h \
         ggml/include/ggml-cpu.h ggml/include/ggml-blas.h ggml/include/gguf.h \
         tools/mtmd/mtmd.h tools/mtmd/mtmd-helper.h; do
  cp "$SRC/$h" "$DEST_INC/"
done

# ── Assert the point of the exercise: API exported, shaders embedded ─────────
SYMS="$(nm -gU "$DEST_LIB/libllama.dylib")"
grep -q " _llama_backend_init$" <<<"$SYMS" || die "libllama.dylib does not export llama_backend_init"
EMBEDDED="$(grep -c "_ggml_metallib_.*_start$" <<<"$SYMS" || true)"
[ "$EMBEDDED" -gt 0 ] || die "no embedded Metal library in libllama.dylib (GGML_METAL_EMBED_LIBRARY did not take)"

echo "$LLAMA_TAG" > "$STAMP"
echo "$WANT" > "$BUILD_STAMP"

echo "[build-llama] staged libllama built from source ($LLAMA_TAG):"
echo "  $DEST_LIB/libllama.dylib ($(du -h "$DEST_LIB/libllama.dylib" | cut -f1), $EMBEDDED embedded Metal sources)"
echo "  $(ls "$DEST_INC" | wc -l | tr -d ' ') headers in $DEST_INC"
