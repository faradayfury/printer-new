#!/bin/bash
#
# Build a .pkg installer for the HP LaserJet P1007 ARM64 driver.
#
# Compiles rastertoxqx from source and assembles everything into
# a distributable .pkg that anyone can double-click to install.
#
# Prerequisites:
#   - Xcode Command Line Tools
#   - Must be run on Apple Silicon (arm64)
#
# Usage: sudo ./build-pkg.sh
#
# Optional: sudo ./build-pkg.sh --sign "Developer ID Installer: Your Name (TEAMID)"
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
PKG_ROOT="$BUILD_DIR/pkg-root"
SCRIPTS_DIR="$BUILD_DIR/scripts"
RESOURCES_DIR="$BUILD_DIR/resources"

PKG_ID="com.foo2xqx.hp-laserjet-p1007"
PKG_VERSION="2.0.0"
OUTPUT_NAME="HP-LaserJet-P1007-Driver.pkg"

FOO2ZJS_DIR="$SCRIPT_DIR/foo2zjs"

# Signing identity (optional)
SIGN_IDENTITY=""
if [ "$1" = "--sign" ] && [ -n "$2" ]; then
    SIGN_IDENTITY="$2"
fi

# ── Helpers ──────────────────────────────────────────────────────────────────

log()  { echo "==> $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# ── Step 0: Checks ──────────────────────────────────────────────────────────

if [ "$(id -u)" -ne 0 ]; then
    die "Run with sudo:  sudo $0 $*"
fi

if [ "$(uname -m)" != "arm64" ]; then
    die "This must be built on an Apple Silicon Mac (arm64)."
fi

which clang >/dev/null 2>&1 || die "Xcode Command Line Tools required: xcode-select --install"

log "Validating source files..."
[ -f "$SCRIPT_DIR/rastertoxqx.c" ] || die "rastertoxqx.c not found"
[ -f "$FOO2ZJS_DIR/jbig.c" ]       || die "foo2zjs/jbig.c not found"
[ -f "$FOO2ZJS_DIR/xqx.h" ]        || die "foo2zjs/xqx.h not found"
[ -f "$FOO2ZJS_DIR/arm2hpdl.c" ]   || die "foo2zjs/arm2hpdl.c not found"
[ -f "$FOO2ZJS_DIR/sihpP1005.img" ] || die "foo2zjs/sihpP1005.img not found"
[ -f "$SCRIPT_DIR/HP-LaserJet_P1007.ppd" ] || die "HP-LaserJet_P1007.ppd not found"

# ── Step 1: Compile ──────────────────────────────────────────────────────────

mkdir -p "$BUILD_DIR"

log "Compiling rastertoxqx..."
cd "$SCRIPT_DIR"
clang -o "$BUILD_DIR/rastertoxqx" rastertoxqx.c foo2zjs/jbig.c foo2zjs/jbig_ar.c \
    -Ifoo2zjs -lcups -lcupsimage -Wall -O2
codesign --force --sign - "$BUILD_DIR/rastertoxqx"

log "Compiling arm2hpdl and generating firmware..."
clang -o "$BUILD_DIR/arm2hpdl" foo2zjs/arm2hpdl.c -Ifoo2zjs -Wall -O2
"$BUILD_DIR/arm2hpdl" foo2zjs/sihpP1005.img > "$BUILD_DIR/sihpP1005.dl"

# ── Step 2: Clean & create build directory ───────────────────────────────────

log "Preparing package layout..."
rm -rf "$PKG_ROOT"
mkdir -p "$PKG_ROOT/usr/libexec/cups/filter"
mkdir -p "$PKG_ROOT/Library/Printers/PPDs/Contents/Resources"
mkdir -p "$PKG_ROOT/usr/local/share/foo2xqx/firmware"
mkdir -p "$PKG_ROOT/usr/local/bin"
mkdir -p "$PKG_ROOT/Library/LaunchDaemons"
mkdir -p "$SCRIPTS_DIR"
mkdir -p "$RESOURCES_DIR"

# ── Step 3: Assemble payload ────────────────────────────────────────────────

log "Assembling payload..."

cp "$BUILD_DIR/rastertoxqx" "$PKG_ROOT/usr/libexec/cups/filter/rastertoxqx"
cp "$SCRIPT_DIR/HP-LaserJet_P1007.ppd" "$PKG_ROOT/Library/Printers/PPDs/Contents/Resources/HP-LaserJet_P1007.ppd"
cp "$BUILD_DIR/sihpP1005.dl" "$PKG_ROOT/usr/local/share/foo2xqx/firmware/sihpP1005.dl"

log "Generating firmware upload script..."
cat > "$PKG_ROOT/usr/local/bin/hp-p1007-firmware-upload" << 'UPLOAD_SCRIPT'
#!/bin/sh
#
# Upload firmware to HP LaserJet P1007 when it appears on USB.
# Called by launchd via IOKit USB device matching.
#
LOG="/tmp/hp-p1007-firmware.log"
FIRMWARE="/usr/local/share/foo2xqx/firmware/sihpP1005.dl"
STAMP="/tmp/hp-p1007-firmware.stamp"

# Debounce: skip if firmware was uploaded in the last 120 seconds.
if [ -f "$STAMP" ]; then
    last=$(stat -f %m "$STAMP" 2>/dev/null || echo 0)
    now=$(date +%s)
    elapsed=$(( now - last ))
    if [ "$elapsed" -lt 120 ]; then
        exit 0
    fi
fi

echo "$(date): HP LaserJet P1007 USB connect detected, uploading firmware..." >> "$LOG"
sleep 2

if command -v lp >/dev/null 2>&1; then
    lp -d HP_LaserJet_P1007 -oraw "$FIRMWARE" >> "$LOG" 2>&1
    echo "$(date): Firmware upload complete (exit code: $?)" >> "$LOG"
    touch "$STAMP"
else
    echo "$(date): ERROR: lp command not found" >> "$LOG"
fi
UPLOAD_SCRIPT

log "Generating LaunchDaemon plist..."
cat > "$PKG_ROOT/Library/LaunchDaemons/com.foo2xqx.firmware-upload.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.foo2xqx.firmware-upload</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/hp-p1007-firmware-upload</string>
    </array>
    <key>LaunchEvents</key>
    <dict>
        <key>com.apple.iokit.matching</key>
        <dict>
            <key>com.foo2xqx.hp-p1007-usb</key>
            <dict>
                <key>IOProviderClass</key>
                <string>IOUSBDevice</string>
                <key>idVendor</key>
                <integer>1008</integer>
                <key>idProduct</key>
                <integer>18455</integer>
                <key>IOMatchLaunchStream</key>
                <true/>
            </dict>
        </dict>
    </dict>
</dict>
</plist>
PLIST

# ── Step 4: Set permissions ──────────────────────────────────────────────────

log "Setting permissions..."

chmod 755 "$PKG_ROOT/usr/libexec/cups/filter/rastertoxqx"
chmod 755 "$PKG_ROOT/usr/local/bin/hp-p1007-firmware-upload"
chmod 644 "$PKG_ROOT/Library/Printers/PPDs/Contents/Resources/HP-LaserJet_P1007.ppd"
chmod 644 "$PKG_ROOT/usr/local/share/foo2xqx/firmware/sihpP1005.dl"
chmod 644 "$PKG_ROOT/Library/LaunchDaemons/com.foo2xqx.firmware-upload.plist"

chown -R root:wheel "$PKG_ROOT"

# ── Step 5: Create installer scripts ────────────────────────────────────────

log "Creating installer scripts..."

cat > "$SCRIPTS_DIR/preinstall" << 'PREINSTALL'
#!/bin/bash
if [ "$(uname -m)" != "arm64" ]; then
    echo "ERROR: This driver requires Apple Silicon (arm64)." >&2
    exit 1
fi

# Pause existing printer queue if present
if lpstat -p HP_LaserJet_P1007 >/dev/null 2>&1; then
    cupsdisable HP_LaserJet_P1007 2>/dev/null || true
fi

# Clean up old Ghostscript bundle if present
FILTER_DIR="/usr/libexec/cups/filter"
rm -f "$FILTER_DIR/gs-bundled" 2>/dev/null
rm -rf "$FILTER_DIR/gs-res" 2>/dev/null
rm -f "$FILTER_DIR"/libjbig2dec*.dylib "$FILTER_DIR"/libtiff*.dylib \
      "$FILTER_DIR"/libpng*.dylib "$FILTER_DIR"/libjpeg*.dylib \
      "$FILTER_DIR"/liblcms2*.dylib "$FILTER_DIR"/libfontconfig*.dylib \
      "$FILTER_DIR"/libfreetype*.dylib "$FILTER_DIR"/libopenjp2*.dylib \
      "$FILTER_DIR"/libtesseract*.dylib "$FILTER_DIR"/libarchive*.dylib \
      "$FILTER_DIR"/libleptonica*.dylib "$FILTER_DIR"/libwebp*.dylib \
      "$FILTER_DIR"/libsharpyuv*.dylib "$FILTER_DIR"/libgif*.dylib \
      "$FILTER_DIR"/libintl*.dylib "$FILTER_DIR"/libidn*.dylib \
      2>/dev/null
rm -f "$FILTER_DIR/foomatic-rip" 2>/dev/null

exit 0
PREINSTALL

cat > "$SCRIPTS_DIR/postinstall" << 'POSTINSTALL'
#!/bin/bash
FILTER_DIR="/usr/libexec/cups/filter"

# Fix permissions
chown root:wheel "$FILTER_DIR/rastertoxqx"
chmod 755 "$FILTER_DIR/rastertoxqx"

chown root:wheel /usr/local/bin/hp-p1007-firmware-upload
chmod 755 /usr/local/bin/hp-p1007-firmware-upload

chown root:wheel /Library/LaunchDaemons/com.foo2xqx.firmware-upload.plist
chmod 644 /Library/LaunchDaemons/com.foo2xqx.firmware-upload.plist

# Re-codesign (Installer may invalidate signatures)
codesign --force --sign - "$FILTER_DIR/rastertoxqx" 2>/dev/null || true

# Load the firmware upload LaunchDaemon
launchctl unload /Library/LaunchDaemons/com.foo2xqx.firmware-upload.plist 2>/dev/null || true
launchctl load /Library/LaunchDaemons/com.foo2xqx.firmware-upload.plist 2>/dev/null || true

# Re-enable printer queue if it exists
if lpstat -p HP_LaserJet_P1007 >/dev/null 2>&1; then
    cupsenable HP_LaserJet_P1007 2>/dev/null || true
fi

# Restart CUPS
launchctl stop org.cups.cupsd 2>/dev/null || true
launchctl start org.cups.cupsd 2>/dev/null || true

exit 0
POSTINSTALL

chmod 755 "$SCRIPTS_DIR/preinstall"
chmod 755 "$SCRIPTS_DIR/postinstall"

# ── Step 6: Create Distribution XML and resources ────────────────────────────

log "Creating Distribution XML..."

cat > "$BUILD_DIR/Distribution.xml" << 'DISTXML'
<?xml version="1.0" encoding="utf-8" standalone="no"?>
<installer-gui-script minSpecVersion="2">
    <title>HP LaserJet P1007 Driver</title>
    <welcome file="welcome.html" />
    <readme file="readme.html" />
    <options customize="never" require-scripts="false" hostArchitectures="arm64" />
    <os-version min="14.0" />
    <choices-outline>
        <line choice="default">
            <line choice="com.foo2xqx.hp-laserjet-p1007" />
        </line>
    </choices-outline>
    <choice id="default" />
    <choice id="com.foo2xqx.hp-laserjet-p1007"
            visible="false"
            title="HP LaserJet P1007 Driver"
            description="CUPS raster driver for HP LaserJet P1007 on Apple Silicon">
        <pkg-ref id="com.foo2xqx.hp-laserjet-p1007" />
    </choice>
    <pkg-ref id="com.foo2xqx.hp-laserjet-p1007"
             version="2.0.0"
             onConclusion="none">component.pkg</pkg-ref>
</installer-gui-script>
DISTXML

log "Creating installer resources..."

cat > "$RESOURCES_DIR/welcome.html" << 'WELCOME'
<!DOCTYPE html>
<html>
<head>
<style>
    body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 20px; color: #1d1d1f; }
    h1 { font-size: 22px; font-weight: 600; }
    p { font-size: 14px; line-height: 1.5; color: #424245; }
    .note { background: #f5f5f7; padding: 12px; border-radius: 8px; margin-top: 16px; }
</style>
</head>
<body>
<h1>HP LaserJet P1007 Driver</h1>
<p>This installs a native Apple Silicon driver for the HP LaserJet P1007 printer.</p>
<p>No additional software is required &mdash; the driver uses macOS's built-in PDF rendering.</p>
<div class="note">
<p><strong>What gets installed:</strong></p>
<ul>
    <li>CUPS raster filter (rastertoxqx)</li>
    <li>Printer description file (PPD)</li>
    <li>Firmware and auto-upload service</li>
</ul>
</div>
</body>
</html>
WELCOME

cat > "$RESOURCES_DIR/readme.html" << 'README'
<!DOCTYPE html>
<html>
<head>
<style>
    body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 20px; color: #1d1d1f; }
    h2 { font-size: 18px; font-weight: 600; margin-top: 20px; }
    p, li { font-size: 14px; line-height: 1.6; color: #424245; }
    ol { padding-left: 20px; }
    code { background: #f5f5f7; padding: 2px 6px; border-radius: 4px; font-size: 13px; }
    .important { background: #fff3cd; padding: 12px; border-radius: 8px; margin: 16px 0; }
</style>
</head>
<body>
<h2>After Installation</h2>
<ol>
    <li><strong>Connect</strong> your HP LaserJet P1007 via USB.</li>
    <li><strong>Wait ~5 seconds</strong> &mdash; firmware uploads automatically when the printer is detected.</li>
    <li><strong>Add the printer</strong> in System Settings &gt; Printers &amp; Scanners:
        <br>Click <strong>+</strong>, select <strong>HP LaserJet P1007</strong>, and choose
        <strong>&ldquo;HP LaserJet P1007 rastertoxqx&rdquo;</strong> as the driver.</li>
    <li><strong>Print!</strong></li>
</ol>
<div class="important">
<p><strong>Note:</strong> The printer requires firmware every time it powers on. A background service handles this automatically. If auto-upload doesn't work, run in Terminal:</p>
<p><code>lp -oraw /usr/local/share/foo2xqx/firmware/sihpP1005.dl</code></p>
</div>
</body>
</html>
README

# ── Step 7: Build the package ────────────────────────────────────────────────

log "Building component package..."
pkgbuild \
    --root "$PKG_ROOT" \
    --scripts "$SCRIPTS_DIR" \
    --identifier "$PKG_ID" \
    --version "$PKG_VERSION" \
    --ownership preserve \
    "$BUILD_DIR/component.pkg"

log "Building product archive..."
PRODUCTBUILD_ARGS=(
    --distribution "$BUILD_DIR/Distribution.xml"
    --package-path "$BUILD_DIR/"
    --resources "$RESOURCES_DIR"
)

if [ -n "$SIGN_IDENTITY" ]; then
    log "Signing with: $SIGN_IDENTITY"
    PRODUCTBUILD_ARGS+=(--sign "$SIGN_IDENTITY")
fi

PRODUCTBUILD_ARGS+=("$SCRIPT_DIR/$OUTPUT_NAME")

productbuild "${PRODUCTBUILD_ARGS[@]}"

# ── Cleanup build intermediates ──────────────────────────────────────────────

rm -rf "$BUILD_DIR"

# ── Done ─────────────────────────────────────────────────────────────────────

PKG_SIZE=$(du -sh "$SCRIPT_DIR/$OUTPUT_NAME" | awk '{print $1}')

echo ""
echo "================================================"
echo "  Package built successfully!"
echo "  $SCRIPT_DIR/$OUTPUT_NAME ($PKG_SIZE)"
echo "================================================"
echo ""
echo "To install:  Double-click the .pkg, or:"
echo "  sudo installer -pkg '$SCRIPT_DIR/$OUTPUT_NAME' -target /"
echo ""
echo "To verify contents:"
echo "  pkgutil --payload-files '$SCRIPT_DIR/$OUTPUT_NAME'"
echo ""
if [ -z "$SIGN_IDENTITY" ]; then
    echo "Note: This package is unsigned. Recipients will need to"
    echo "right-click > Open to bypass Gatekeeper, or sign it with:"
    echo "  productsign --sign 'Developer ID Installer: ...' \\"
    echo "    '$OUTPUT_NAME' '${OUTPUT_NAME%.pkg}-signed.pkg'"
    echo ""
fi
