#!/bin/sh
#
# HP LaserJet P1007 - Apple Silicon Native Driver Installer
#
# This installs an ARM64-native driver for the HP LaserJet P1007
# using the rastertoxqx CUPS raster filter.
#
# No Ghostscript dependency — uses macOS built-in cgpdftoraster
# for PDF rendering.
#
# Usage: sudo ./install.sh
#

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CUPS_FILTER_DIR="/usr/libexec/cups/filter"
LOCAL_FILTER_DIR="/usr/local/libexec/cups/filter"
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

# Step 1: Compile rastertoxqx (the CUPS raster filter)
echo "[1/5] Compiling rastertoxqx..."
cd "$SCRIPT_DIR"
clang -o rastertoxqx rastertoxqx.c foo2zjs/jbig.c foo2zjs/jbig_ar.c \
    -Ifoo2zjs -lcups -lcupsimage -Wall -O2
echo "  rastertoxqx: $(file -b rastertoxqx)"

# Step 2: Compile arm2hpdl and generate firmware
echo "[2/5] Preparing firmware..."
if [ ! -f "$FOO2ZJS_DIR/arm2hpdl" ] || [ "$(file -b "$FOO2ZJS_DIR/arm2hpdl" | grep -c arm64)" -eq 0 ]; then
    cd "$FOO2ZJS_DIR"
    clang -o arm2hpdl arm2hpdl.c -I. -Wall -O2
    cd "$SCRIPT_DIR"
fi
if [ ! -f "$FOO2ZJS_DIR/sihpP1005.dl" ]; then
    cd "$FOO2ZJS_DIR"
    ./arm2hpdl sihpP1005.img > sihpP1005.dl
    cd "$SCRIPT_DIR"
fi
echo "  Firmware: sihpP1005.dl ($(wc -c < "$FOO2ZJS_DIR/sihpP1005.dl" | tr -d ' ') bytes)"

# Step 3: Install the rastertoxqx filter
echo "[3/5] Installing CUPS filter..."
mkdir -p "$CUPS_FILTER_DIR"
cp "$SCRIPT_DIR/rastertoxqx" "$CUPS_FILTER_DIR/rastertoxqx"
chmod 755 "$CUPS_FILTER_DIR/rastertoxqx"
echo "  Installed to $CUPS_FILTER_DIR/rastertoxqx"

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

# Clean up old Ghostscript bundle if present
if [ -f "$CUPS_FILTER_DIR/gs-bundled" ]; then
    echo ""
    echo "Cleaning up old Ghostscript bundle..."
    rm -f "$CUPS_FILTER_DIR/gs-bundled"
    rm -rf "$CUPS_FILTER_DIR/gs-res"
    # Remove bundled dylibs (only the ones we know we put there)
    rm -f "$CUPS_FILTER_DIR"/libjbig2dec*.dylib \
          "$CUPS_FILTER_DIR"/libtiff*.dylib \
          "$CUPS_FILTER_DIR"/libpng*.dylib \
          "$CUPS_FILTER_DIR"/libjpeg*.dylib \
          "$CUPS_FILTER_DIR"/liblcms2*.dylib \
          "$CUPS_FILTER_DIR"/libidn*.dylib \
          "$CUPS_FILTER_DIR"/libfontconfig*.dylib \
          "$CUPS_FILTER_DIR"/libfreetype*.dylib \
          "$CUPS_FILTER_DIR"/libopenjp2*.dylib \
          "$CUPS_FILTER_DIR"/libtesseract*.dylib \
          "$CUPS_FILTER_DIR"/libarchive*.dylib \
          "$CUPS_FILTER_DIR"/libleptonica*.dylib \
          "$CUPS_FILTER_DIR"/libwebp*.dylib \
          "$CUPS_FILTER_DIR"/libsharpyuv*.dylib \
          "$CUPS_FILTER_DIR"/libgif*.dylib \
          "$CUPS_FILTER_DIR"/libintl*.dylib \
          2>/dev/null
    echo "  Removed gs-bundled, dylibs, and gs-res/"
fi
if [ -f "$CUPS_FILTER_DIR/foomatic-rip" ]; then
    rm -f "$CUPS_FILTER_DIR/foomatic-rip"
    echo "  Removed old foomatic-rip"
fi

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
echo "   - Choose 'HP LaserJet P1007 rastertoxqx' as the driver"
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
