#!/bin/sh
#
# HP LaserJet P1007 - Apple Silicon Native Driver Installer
#
# Installs a CUPS raster driver that uses macOS's built-in cgpdftoraster.
# No Ghostscript required.
#
# Usage: sudo ./install.sh
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FILTER_DIR="/usr/libexec/cups/filter"
FIRMWARE_DIR="/usr/local/share/foo2xqx/firmware"
PPD_DIR="/Library/Printers/PPDs/Contents/Resources"
FOO2ZJS_DIR="$SCRIPT_DIR/foo2zjs"

echo "=== HP LaserJet P1007 - ARM64 Native Driver Installer ==="
echo ""

# Check we're running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root (use sudo)."
    echo "  sudo $0"
    exit 1
fi

# Check architecture
ARCH=$(uname -m)
if [ "$ARCH" != "arm64" ]; then
    echo "WARNING: This driver is built for Apple Silicon (arm64)."
    echo "  Detected architecture: $ARCH"
    echo ""
fi

# Step 1: Compile rastertoxqx
echo "[1/5] Compiling rastertoxqx..."
if [ ! -f "$SCRIPT_DIR/rastertoxqx" ] || [ "$(file -b "$SCRIPT_DIR/rastertoxqx" | grep -c arm64)" -eq 0 ]; then
    clang -o "$SCRIPT_DIR/rastertoxqx" \
        "$SCRIPT_DIR/rastertoxqx.c" \
        "$FOO2ZJS_DIR/jbig.c" "$FOO2ZJS_DIR/jbig_ar.c" \
        -I"$FOO2ZJS_DIR" -lcups -lcupsimage -Wall -O2
fi
echo "  rastertoxqx: $(file -b "$SCRIPT_DIR/rastertoxqx")"

# Step 2: Generate firmware
echo "[2/5] Preparing firmware..."
if [ ! -f "$FOO2ZJS_DIR/sihpP1005.dl" ]; then
    if [ ! -f "$FOO2ZJS_DIR/arm2hpdl" ]; then
        clang -o "$FOO2ZJS_DIR/arm2hpdl" "$FOO2ZJS_DIR/arm2hpdl.c" -I"$FOO2ZJS_DIR" -Wall -O2
    fi
    "$FOO2ZJS_DIR/arm2hpdl" "$FOO2ZJS_DIR/sihpP1005.img" > "$FOO2ZJS_DIR/sihpP1005.dl"
fi
echo "  Firmware: sihpP1005.dl ($(wc -c < "$FOO2ZJS_DIR/sihpP1005.dl" | tr -d ' ') bytes)"

# Step 3: Install filter
echo "[3/5] Installing CUPS filter..."
mkdir -p "$FILTER_DIR"
cp "$SCRIPT_DIR/rastertoxqx" "$FILTER_DIR/rastertoxqx"
chmod 755 "$FILTER_DIR/rastertoxqx"
codesign --force --sign - "$FILTER_DIR/rastertoxqx" 2>/dev/null || true
echo "  Installed rastertoxqx to $FILTER_DIR/"

# Step 4: Install firmware
echo "[4/5] Installing firmware..."
mkdir -p "$FIRMWARE_DIR"
cp "$FOO2ZJS_DIR/sihpP1005.dl" "$FIRMWARE_DIR/sihpP1005.dl"
chmod 644 "$FIRMWARE_DIR/sihpP1005.dl"
echo "  Installed to $FIRMWARE_DIR/"

# Step 5: Install PPD
echo "[5/5] Installing PPD..."
mkdir -p "$PPD_DIR"
cp "$SCRIPT_DIR/HP-LaserJet_P1007.ppd" "$PPD_DIR/HP-LaserJet_P1007.ppd"
chmod 644 "$PPD_DIR/HP-LaserJet_P1007.ppd"
echo "  Installed to $PPD_DIR/"

echo ""
echo "=== Installation complete! ==="
echo ""
echo "Next steps:"
echo ""
echo "1. PLUG IN your HP LaserJet P1007 via USB"
echo ""
echo "2. UPLOAD FIRMWARE (required every time the printer powers on):"
echo "   lp -oraw $FIRMWARE_DIR/sihpP1005.dl"
echo "   (The printer light should flash orange for ~5 seconds)"
echo ""
echo "3. ADD THE PRINTER via System Settings > Printers & Scanners"
echo "   - Click '+' to add a printer"
echo "   - Select 'HP LaserJet P1007' from USB"
echo "   - Choose 'HP LaserJet P1007' as the driver"
echo ""
echo "   OR add via command line:"
echo "   lpadmin -p HP_LaserJet_P1007 -E \\"
echo "     -v 'usb://HP/LaserJet%20P1007' \\"
echo "     -P '$PPD_DIR/HP-LaserJet_P1007.ppd'"
echo ""
echo "4. PRINT A TEST PAGE:"
echo "   lp -d HP_LaserJet_P1007 /path/to/file.pdf"
echo ""
echo "Tip: To auto-upload firmware on printer connect, run:"
echo "   sudo $SCRIPT_DIR/install-hotplug.sh"
echo ""
