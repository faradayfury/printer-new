#!/bin/bash
#
# Build a .pkg installer for the HP LaserJet P1007 ARM64 driver.
#
# Assembles all pre-built components from the current working installation
# into a distributable .pkg that anyone can double-click to install.
#
# Prerequisites:
#   - Driver already installed and working (gs-bundled, dylibs, etc. in /usr/libexec/cups/filter/)
#   - foo2zjs/sihpP1005.dl firmware file exists
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
PKG_VERSION="1.0.0"
OUTPUT_NAME="HP-LaserJet-P1007-Driver.pkg"

# Installed driver locations
FILTER_DIR="/usr/libexec/cups/filter"

# Source locations
PPD_SRC="$SCRIPT_DIR/foo2zjs/PPD/HP-LaserJet_P1007.ppd"
FIRMWARE_SRC="$SCRIPT_DIR/foo2zjs/sihpP1005.dl"
FOOMATIC_SRC="$SCRIPT_DIR/foomatic-rip"

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

log "Validating prerequisites..."

[ -x "$FILTER_DIR/gs-bundled" ]  || die "gs-bundled not found at $FILTER_DIR/gs-bundled — run bundle-gs.sh first"
[ -d "$FILTER_DIR/gs-res" ]      || die "gs-res not found at $FILTER_DIR/gs-res — run bundle-gs.sh first"
[ -x "$FILTER_DIR/foo2xqx" ]    || die "foo2xqx not found at $FILTER_DIR/foo2xqx — run install.sh first"
[ -f "$PPD_SRC" ]                || die "PPD not found at $PPD_SRC"
[ -f "$FIRMWARE_SRC" ]           || die "Firmware not found at $FIRMWARE_SRC"
[ -f "$FOOMATIC_SRC" ]           || die "foomatic-rip not found at $FOOMATIC_SRC"

DYLIB_COUNT=$(ls "$FILTER_DIR"/*.dylib 2>/dev/null | wc -l | tr -d ' ')
[ "$DYLIB_COUNT" -gt 0 ] || die "No dylibs found in $FILTER_DIR — run bundle-gs.sh first"
log "  Found $DYLIB_COUNT bundled dylibs"

# ── Step 1: Clean & create build directory ───────────────────────────────────

log "Preparing build directory..."
rm -rf "$BUILD_DIR"
mkdir -p "$PKG_ROOT/usr/libexec/cups/filter"
mkdir -p "$PKG_ROOT/Library/Printers/PPDs/Contents/Resources"
mkdir -p "$PKG_ROOT/usr/local/share/foo2xqx/firmware"
mkdir -p "$PKG_ROOT/usr/local/bin"
mkdir -p "$PKG_ROOT/Library/LaunchDaemons"
mkdir -p "$SCRIPTS_DIR"
mkdir -p "$RESOURCES_DIR"

# ── Step 2: Assemble payload ────────────────────────────────────────────────

log "Copying CUPS filters..."

# gs-bundled binary
cp "$FILTER_DIR/gs-bundled" "$PKG_ROOT/usr/libexec/cups/filter/gs-bundled"

# All bundled dylibs
cp "$FILTER_DIR"/*.dylib "$PKG_ROOT/usr/libexec/cups/filter/"

# gs-res resource directory
cp -R "$FILTER_DIR/gs-res" "$PKG_ROOT/usr/libexec/cups/filter/gs-res"

# foo2xqx binary
cp "$FILTER_DIR/foo2xqx" "$PKG_ROOT/usr/libexec/cups/filter/foo2xqx"

# foomatic-rip filter script
cp "$FOOMATIC_SRC" "$PKG_ROOT/usr/libexec/cups/filter/foomatic-rip"

log "Copying PPD..."
cp "$PPD_SRC" "$PKG_ROOT/Library/Printers/PPDs/Contents/Resources/HP-LaserJet_P1007.ppd"

log "Copying firmware..."
cp "$FIRMWARE_SRC" "$PKG_ROOT/usr/local/share/foo2xqx/firmware/sihpP1005.dl"

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
# launchd re-triggers every ~10s since a shell script cannot consume
# the XPC event stream. 120s is plenty — firmware is once per power cycle.
if [ -f "$STAMP" ]; then
    last=$(stat -f %m "$STAMP" 2>/dev/null || echo 0)
    now=$(date +%s)
    elapsed=$(( now - last ))
    if [ "$elapsed" -lt 120 ]; then
        exit 0
    fi
fi

echo "$(date): HP LaserJet P1007 USB connect detected, uploading firmware..." >> "$LOG"

# Wait briefly for the USB device to be fully ready
sleep 2

# Send firmware to the printer queue
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

# ── Step 3: Set permissions & codesign ──────────────────────────────────────

log "Setting permissions..."

# Executables: 755, root:wheel
chmod 755 "$PKG_ROOT/usr/libexec/cups/filter/gs-bundled"
chmod 755 "$PKG_ROOT/usr/libexec/cups/filter/foo2xqx"
chmod 755 "$PKG_ROOT/usr/libexec/cups/filter/foomatic-rip"
chmod 755 "$PKG_ROOT/usr/local/bin/hp-p1007-firmware-upload"

# Dylibs: 644
chmod 644 "$PKG_ROOT/usr/libexec/cups/filter/"*.dylib

# Data files: 644
chmod 644 "$PKG_ROOT/Library/Printers/PPDs/Contents/Resources/HP-LaserJet_P1007.ppd"
chmod 644 "$PKG_ROOT/usr/local/share/foo2xqx/firmware/sihpP1005.dl"
chmod 644 "$PKG_ROOT/Library/LaunchDaemons/com.foo2xqx.firmware-upload.plist"

# Ownership (must be root to do this)
chown -R root:wheel "$PKG_ROOT"

log "Codesigning binaries..."
codesign --force --sign - "$PKG_ROOT/usr/libexec/cups/filter/gs-bundled"
codesign --force --sign - "$PKG_ROOT/usr/libexec/cups/filter/foo2xqx"
for lib in "$PKG_ROOT/usr/libexec/cups/filter/"*.dylib; do
    codesign --force --sign - "$lib"
done

# ── Step 4: Create installer scripts ────────────────────────────────────────

log "Creating installer scripts..."

cat > "$SCRIPTS_DIR/preinstall" << 'PREINSTALL'
#!/bin/bash
# Verify ARM64 architecture
if [ "$(uname -m)" != "arm64" ]; then
    echo "ERROR: This driver requires Apple Silicon (arm64)." >&2
    echo "Your Mac has a $(uname -m) processor." >&2
    exit 1
fi

# Pause existing printer queue if present (non-fatal)
if lpstat -p HP_LaserJet_P1007 >/dev/null 2>&1; then
    cupsdisable HP_LaserJet_P1007 2>/dev/null || true
fi

exit 0
PREINSTALL

cat > "$SCRIPTS_DIR/postinstall" << 'POSTINSTALL'
#!/bin/bash
FILTER_DIR="/usr/libexec/cups/filter"

# Fix permissions (Installer may reset them)
chown root:wheel "$FILTER_DIR/gs-bundled" "$FILTER_DIR/foo2xqx" "$FILTER_DIR/foomatic-rip"
chmod 755 "$FILTER_DIR/gs-bundled" "$FILTER_DIR/foo2xqx" "$FILTER_DIR/foomatic-rip"
chown root:wheel "$FILTER_DIR"/*.dylib
chmod 644 "$FILTER_DIR"/*.dylib

chown root:wheel /usr/local/bin/hp-p1007-firmware-upload
chmod 755 /usr/local/bin/hp-p1007-firmware-upload

chown root:wheel /Library/LaunchDaemons/com.foo2xqx.firmware-upload.plist
chmod 644 /Library/LaunchDaemons/com.foo2xqx.firmware-upload.plist

# Re-codesign (Installer may invalidate signatures)
codesign --force --sign - "$FILTER_DIR/gs-bundled" 2>/dev/null || true
codesign --force --sign - "$FILTER_DIR/foo2xqx" 2>/dev/null || true
for lib in "$FILTER_DIR"/*.dylib; do
    codesign --force --sign - "$lib" 2>/dev/null || true
done

# Load the firmware upload LaunchDaemon
launchctl unload /Library/LaunchDaemons/com.foo2xqx.firmware-upload.plist 2>/dev/null || true
launchctl load /Library/LaunchDaemons/com.foo2xqx.firmware-upload.plist 2>/dev/null || true

# Re-enable printer queue if it exists
if lpstat -p HP_LaserJet_P1007 >/dev/null 2>&1; then
    cupsenable HP_LaserJet_P1007 2>/dev/null || true
fi

# Restart CUPS to pick up new filters
launchctl stop org.cups.cupsd 2>/dev/null || true
launchctl start org.cups.cupsd 2>/dev/null || true

exit 0
POSTINSTALL

chmod 755 "$SCRIPTS_DIR/preinstall"
chmod 755 "$SCRIPTS_DIR/postinstall"

# ── Step 5: Create Distribution XML and resources ────────────────────────────

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
            description="CUPS driver for HP LaserJet P1007 on Apple Silicon">
        <pkg-ref id="com.foo2xqx.hp-laserjet-p1007" />
    </choice>
    <pkg-ref id="com.foo2xqx.hp-laserjet-p1007"
             version="1.0.0"
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
<p>This installs a native ARM64 driver for the HP LaserJet P1007 printer on Apple Silicon Macs.</p>
<p>The driver uses the open-source <strong>foo2xqx</strong> engine with a bundled Ghostscript for PostScript rendering.</p>
<div class="note">
<p><strong>What gets installed:</strong></p>
<ul>
    <li>CUPS filter and Ghostscript engine</li>
    <li>Printer description file (PPD)</li>
    <li>Firmware upload utility</li>
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
    <li><strong>Upload firmware</strong> — the printer requires firmware every time it powers on:
        <br>Open Terminal and run: <code>lp -oraw /usr/local/share/foo2xqx/firmware/sihpP1005.dl</code>
        <br>The printer light will flash orange for about 5 seconds.</li>
    <li><strong>Add the printer</strong> in System Settings &gt; Printers &amp; Scanners:
        <br>Click <strong>+</strong>, select <strong>HP LaserJet P1007</strong> from USB, and choose <strong>"HP LaserJet P1007 foo2xqx"</strong> as the driver.</li>
    <li><strong>Print a test page</strong> to verify everything works.</li>
</ol>
<div class="important">
<p><strong>Note:</strong> A background service is installed that will attempt to auto-upload firmware when the printer is detected. If auto-upload doesn't work, use the manual <code>lp -oraw</code> command above.</p>
</div>
</body>
</html>
README

# ── Step 6: Build the package ────────────────────────────────────────────────

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

# ── Done ─────────────────────────────────────────────────────────────────────

PKG_SIZE=$(du -sh "$SCRIPT_DIR/$OUTPUT_NAME" | awk '{print $1}')

echo ""
echo "================================================"
echo "  Package built successfully!"
echo "  $SCRIPT_DIR/$OUTPUT_NAME ($PKG_SIZE)"
echo "================================================"
echo ""
echo "To verify contents:"
echo "  pkgutil --payload-files '$SCRIPT_DIR/$OUTPUT_NAME'"
echo ""
echo "To test on a clean system:"
echo "  1. sudo pkgutil --forget $PKG_ID"
echo "  2. Remove installed files manually"
echo "  3. Double-click the .pkg to reinstall"
echo ""
if [ -z "$SIGN_IDENTITY" ]; then
    echo "Note: This package is unsigned. Recipients will need to"
    echo "right-click > Open to bypass Gatekeeper, or sign it with:"
    echo "  productsign --sign 'Developer ID Installer: ...' \\"
    echo "    '$OUTPUT_NAME' '${OUTPUT_NAME%.pkg}-signed.pkg'"
    echo ""
fi
