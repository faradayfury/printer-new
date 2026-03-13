# HP LaserJet P1007 — ARM64 macOS Driver

A native Apple Silicon CUPS driver for the HP LaserJet P1007 (and P1005/P1006/P1008). No Ghostscript required.

## How It Works

```
PDF → cgpdftoraster (macOS built-in) → rastertoxqx (our filter) → XQX → printer
```

The driver is a single CUPS raster filter (`rastertoxqx`) that:

1. Receives pixel data from macOS's built-in `cgpdftoraster` PDF rasterizer
2. JBIG2-compresses each page using the bundled jbig library
3. Wraps the compressed data in HP's XQX packet format
4. Streams it to the printer via USB

**No Ghostscript. No external dependencies.** The PDF-to-raster conversion is handled by `cgpdftoraster`, an Apple-signed system binary that runs inside the CUPS sandbox without issues.

### Why not Ghostscript?

An earlier version of this driver used Ghostscript to rasterize PostScript into PBM bitmaps. This required an elaborate workaround for macOS's CUPS sandboxing:

- Copying Ghostscript + 15 shared libraries into `/usr/libexec/cups/filter/`
- Rewriting every library path with `install_name_tool` + `@loader_path`
- Ad-hoc codesigning all binaries for Apple Silicon
- Bundling Ghostscript resource files (fonts, PostScript init scripts)
- Rebuilding the bundle whenever Homebrew updated Ghostscript

By switching to CUPS raster input, all of that is eliminated. Install size dropped from ~20MB to ~400KB.

## Files

| File | Purpose |
|------|---------|
| `rastertoxqx.c` | CUPS raster filter — reads raster, JBIG2 compresses, outputs XQX |
| `HP-LaserJet_P1007.ppd` | PPD file describing printer capabilities and filter to use |
| `install.sh` | Installer — compiles and installs filter + PPD + firmware |
| `install-hotplug.sh` | Sets up automatic firmware upload via IOKit USB device matching |
| `build-pkg.sh` | Builds a distributable `.pkg` installer |
| `foo2zjs/jbig.c` | JBIG2 compression library (from foo2zjs project) |
| `foo2zjs/xqx.h` | XQX packet format definitions |
| `foo2zjs/arm2hpdl.c` | Firmware image converter |
| `testpage.pdf` | Test page for verifying the driver works |

## Installation

### Prerequisites

- macOS 14+ on Apple Silicon (arm64)
- Xcode Command Line Tools: `xcode-select --install`

That's it — no Homebrew, no Ghostscript.

### Steps

```bash
# 1. Install the driver (compiles rastertoxqx, installs filter + PPD + firmware)
sudo ./install.sh

# 2. Set up automatic firmware upload (optional, triggers on USB connect)
sudo ./install-hotplug.sh

# 3. Add printer via System Settings > Printers & Scanners
#    Click +, select "HP LaserJet P1007" from USB,
#    choose "HP LaserJet P1007" as the driver

# 4. Print a test page
lp -d HP_LaserJet_P1007 testpage.pdf
```

### Package Installer

To build a distributable `.pkg` for other machines:

```bash
sudo ./build-pkg.sh

# Or with signing:
sudo ./build-pkg.sh --sign "Developer ID Installer: Your Name (TEAMID)"
```

## Firmware

The HP LaserJet P1007 has no onboard firmware storage — it requires firmware to be uploaded over USB every time it powers on.

### Automatic Upload

`install-hotplug.sh` creates a LaunchDaemon that uses IOKit USB device matching to detect the printer (VID `0x03f0`, PID `0x4817`) and automatically uploads the firmware when the printer appears.

### Manual Upload

```bash
lp -oraw /usr/local/share/foo2xqx/firmware/sihpP1005.dl
```

The printer light will flash orange for ~5 seconds while firmware loads.

## Troubleshooting

### Check CUPS error log
```bash
tail -f /var/log/cups/error_log
```

### "rastertoxqx" not found
CUPS looks for filters in `/usr/libexec/cups/filter/`. Make sure the binary is there:
```bash
ls -la /usr/libexec/cups/filter/rastertoxqx
```
If missing, re-run `sudo ./install.sh`.

### Printer not appearing
Ensure firmware has been uploaded — the printer won't enumerate properly without it.

### Blank pages or garbled output
Check the CUPS log for errors from `rastertoxqx`. The filter logs debug info to stderr which appears in the CUPS error log.

### Testing the filter manually (no printer needed)
```bash
# Generate CUPS raster from a PDF
PPD=./HP-LaserJet_P1007.ppd /usr/libexec/cups/filter/cgpdftoraster \
    1 user title 1 "" testpage.pdf > /tmp/test.ras

# Convert to XQX
./rastertoxqx 1 user title 1 "" < /tmp/test.ras > /tmp/test.xqx

# Decode and inspect the XQX structure
./xqxdecode < /tmp/test.xqx
```

## Build

```bash
# Compile the filter
clang -o rastertoxqx rastertoxqx.c foo2zjs/jbig.c foo2zjs/jbig_ar.c \
    -Ifoo2zjs -lcups -lcupsimage -Wall -O2

# Compile the XQX decoder (for debugging)
clang -o xqxdecode foo2zjs/xqxdecode.c foo2zjs/jbig.c foo2zjs/jbig_ar.c \
    -Ifoo2zjs -Wall -O2

# Compile the firmware converter
clang -o arm2hpdl foo2zjs/arm2hpdl.c -Ifoo2zjs -Wall -O2
```

## License

The JBIG2 compression library and XQX format definitions are from the [foo2zjs](http://foo2zjs.rkkda.com/) project, licensed under GPL v2 or later.
