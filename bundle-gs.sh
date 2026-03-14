#!/bin/bash
#
# Bundle Ghostscript with all its Homebrew dylib dependencies
# into a self-contained directory for CUPS filter use.
#
# This resolves the CUPS sandbox issue where /opt/homebrew/opt/... symlinks
# are blocked by the sandbox's stat() restrictions.
#
# All dylibs are copied and rewritten to use @loader_path so they
# resolve relative to the binary/library that loads them.
#
set -e

# Auto-detect Ghostscript from Homebrew (survives brew upgrades)
GS_PREFIX="$(brew --prefix ghostscript 2>/dev/null)" || true
GS_SRC="${GS_PREFIX}/bin/gs"

# Put everything in the CUPS filter dir — the sandbox allows this path
BUNDLE_DIR="/usr/libexec/cups/filter"
LIB_DIR="$BUNDLE_DIR"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run with sudo"
    exit 1
fi

if [ -z "$GS_PREFIX" ] || [ ! -x "$GS_SRC" ]; then
    echo "ERROR: Ghostscript not found. Install it with: brew install ghostscript"
    exit 1
fi

# Resolve real Cellar path and version for resource files
GS_CELLAR="$(realpath "$GS_PREFIX")"
GS_VERSION="$("$GS_SRC" --version)"
echo "  Detected Ghostscript $GS_VERSION at $GS_CELLAR"

echo "=== Bundling Ghostscript for CUPS sandbox ==="

# Copy the gs binary into the filter dir as "gs-bundled"
cp "$GS_SRC" "$BUNDLE_DIR/gs-bundled"
chmod 755 "$BUNDLE_DIR/gs-bundled"

# Remove any previous bundled dylibs
rm -f "$LIB_DIR"/libjbig2dec*.dylib "$LIB_DIR"/libtiff*.dylib \
    "$LIB_DIR"/libpng*.dylib "$LIB_DIR"/libjpeg*.dylib \
    "$LIB_DIR"/liblcms2*.dylib "$LIB_DIR"/libidn*.dylib \
    "$LIB_DIR"/libfontconfig*.dylib "$LIB_DIR"/libfreetype*.dylib \
    "$LIB_DIR"/libopenjp2*.dylib "$LIB_DIR"/libtesseract*.dylib \
    "$LIB_DIR"/libarchive*.dylib "$LIB_DIR"/libleptonica*.dylib \
    "$LIB_DIR"/libwebp*.dylib "$LIB_DIR"/libsharpyuv*.dylib \
    "$LIB_DIR"/libgif*.dylib "$LIB_DIR"/libintl*.dylib \
    2>/dev/null

# Resolve an @rpath reference by searching known Homebrew lib dirs
resolve_rpath() {
    local libname="$1"
    local bare
    bare=$(basename "$libname")
    for search_dir in \
        /opt/homebrew/lib \
        /opt/homebrew/Cellar/webp/*/lib \
        /opt/homebrew/Cellar/ghostscript/*/lib \
        /opt/homebrew/Cellar/*/lib; do
        for candidate in $search_dir/$bare; do
            if [ -f "$candidate" ]; then
                echo "$candidate"
                return 0
            fi
        done
    done
    return 1
}

# Recursively find and copy all Homebrew dylib dependencies
collect_deps() {
    local binary="$1"
    # Skip first line (binary name with colon), only grab .dylib paths
    otool -L "$binary" 2>/dev/null | tail -n +2 | awk '{print $1}' | while read -r dep; do
        local real_dep=""
        local basename=""

        case "$dep" in
            /opt/homebrew/*.dylib)
                real_dep=$(realpath "$dep" 2>/dev/null || echo "$dep")
                basename=$(basename "$dep")
                ;;
            @rpath/*.dylib)
                # Resolve @rpath to a real Homebrew path
                real_dep=$(resolve_rpath "$dep" 2>/dev/null) || true
                basename=$(basename "$dep")
                ;;
            *)
                continue
                ;;
        esac

        if [ -n "$real_dep" ] && [ -n "$basename" ] && [ ! -f "$LIB_DIR/$basename" ]; then
            echo "  Copying: $basename (from $real_dep)"
            cp "$real_dep" "$LIB_DIR/$basename"
            chmod 644 "$LIB_DIR/$basename"
            # Recurse into this library's deps
            collect_deps "$LIB_DIR/$basename"
        fi
    done
}

echo ""
echo "Collecting dependencies..."
collect_deps "$BUNDLE_DIR/gs-bundled"

echo ""
echo "Rewriting library paths..."

# Rewrite the gs binary's references
for dep in $(otool -L "$BUNDLE_DIR/gs-bundled" | tail -n +2 | awk '{print $1}' | grep '^/opt/homebrew/'); do
    local_name=$(basename "$dep")
    echo "  gs-bundled: $dep -> @loader_path/$local_name"
    install_name_tool -change "$dep" "@loader_path/$local_name" "$BUNDLE_DIR/gs-bundled"
done

# Rewrite each library's references (both its own ID and its deps)
for lib in "$LIB_DIR"/*.dylib; do
    libname=$(basename "$lib")

    # Fix the library's own install name
    old_id=$(otool -D "$lib" 2>/dev/null | tail -1)
    if echo "$old_id" | grep -q '^/opt/homebrew/'; then
        if ! install_name_tool -id "@loader_path/$libname" "$lib" 2>/dev/null; then
            echo "  WARNING: Failed to rewrite install name for $libname" >&2
        fi
    fi

    # Fix references to other Homebrew libraries and @rpath references
    for dep in $(otool -L "$lib" | tail -n +2 | awk '{print $1}' | grep -E '^(/opt/homebrew/|@rpath/)'); do
        dep_name=$(basename "$dep")
        if [ -f "$LIB_DIR/$dep_name" ]; then
            echo "  $libname: $dep -> @loader_path/$dep_name"
            if ! install_name_tool -change "$dep" "@loader_path/$dep_name" "$lib" 2>/dev/null; then
                echo "  WARNING: Failed to rewrite $dep in $libname" >&2
            fi
        fi
    done
done

# --- Copy Ghostscript resource files ---
GS_SHARE="$GS_CELLAR/share/ghostscript"
GS_RES_DST="$BUNDLE_DIR/gs-res"

echo ""
echo "Copying Ghostscript resources..."
rm -rf "$GS_RES_DST"
mkdir -p "$GS_RES_DST"
cp -R "$GS_SHARE/Resource" "$GS_RES_DST/"
cp -R "$GS_SHARE/$GS_VERSION/lib" "$GS_RES_DST/"
# Copy fonts if present
[ -d "$GS_SHARE/$GS_VERSION/fonts" ] && cp -R "$GS_SHARE/$GS_VERSION/fonts" "$GS_RES_DST/"
[ -d "$GS_SHARE/$GS_VERSION/iccprofiles" ] && cp -R "$GS_SHARE/$GS_VERSION/iccprofiles" "$GS_RES_DST/"
echo "  Installed to $GS_RES_DST/ ($(du -sh "$GS_RES_DST" | awk '{print $1}'))"

echo ""
echo "Codesigning..."
# Ad-hoc codesign everything (required on Apple Silicon)
if ! codesign --force --sign - "$BUNDLE_DIR/gs-bundled" 2>/dev/null; then
    echo "  WARNING: Failed to codesign gs-bundled" >&2
fi
for lib in "$LIB_DIR"/*.dylib; do
    if ! codesign --force --sign - "$lib" 2>/dev/null; then
        echo "  WARNING: Failed to codesign $(basename "$lib")" >&2
    fi
done

echo ""
echo "Verifying..."
echo "  gs binary: $BUNDLE_DIR/gs-bundled"
echo "  Bundled dylibs:"
ls "$LIB_DIR"/*.dylib 2>/dev/null | xargs -I{} basename {}
echo ""
echo "  gs-bundled dependencies after rewrite:"
otool -L "$BUNDLE_DIR/gs-bundled"

echo ""
echo "  Quick test (should print GS version):"
"$BUNDLE_DIR/gs-bundled" --version 2>&1 || echo "  FAILED - check errors above"

echo ""
echo "=== Done ==="
echo ""
echo "Update your foomatic-rip filter to use: $BUNDLE_DIR/gs-bundled"
