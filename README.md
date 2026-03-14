# HP LaserJet P1007 — ARM64 macOS Driver

A native Apple Silicon driver for the HP LaserJet P1007 (and P1005/P1006/P1008) on macOS. No Ghostscript, no Homebrew dependencies, no sandbox hacks.

## How It Works

```
PDF → cgpdftoraster (macOS built-in) → rastertoxqx → XQX → printer
```

macOS ships with `cgpdftoraster`, a built-in CUPS filter that converts PDF to raster using CoreGraphics. Our `rastertoxqx` filter converts that raster to the printer's native XQX/ZjStream format using JBIG compression.

The entire driver is a single **85KB binary** that links only against system libraries (`libcups`, `libcupsimage`, `libSystem`). It runs inside the CUPS sandbox with zero issues.

## Installation

### Prerequisites

- macOS on Apple Silicon (arm64)
- Xcode Command Line Tools: `xcode-select --install`

### Steps

```bash
# 1. Install the driver (compiles rastertoxqx, installs filter + PPD + firmware)
sudo ./install.sh

# 2. Set up automatic firmware upload on USB connect
sudo ./install-hotplug.sh

# 3. Plug in the printer and add it via System Settings > Printers & Scanners
#    Select "HP LaserJet P1007 rastertoxqx" as the driver

# 4. Print a test page
lp -d HP_LaserJet_P1007 testpage.pdf
```

That's it. No Ghostscript bundling, no dylib rewriting, no extra steps.

### Firmware

The P1007 requires firmware uploaded via USB every time it powers on. If you ran `install-hotplug.sh`, this happens automatically when the printer is plugged in. Otherwise, upload manually:

```bash
lp -oraw /usr/local/share/foo2xqx/firmware/sihpP1005.dl
```

Wait for the printer light to flash orange (~5 seconds) before printing.

## Files

| File | Purpose |
|------|---------|
| `rastertoxqx.c` | CUPS raster filter — converts CUPS raster to XQX via JBIG compression |
| `HP-LaserJet_P1007.ppd` | PPD file describing printer capabilities |
| `install.sh` | Main installer — compiles and installs everything |
| `install-hotplug.sh` | Sets up automatic firmware upload via IOKit USB matching |
| `build-pkg.sh` | Builds a distributable .pkg installer |
| `foo2zjs/` | Source: JBIG library, XQX protocol headers, firmware tools |
| `testpage.pdf` | Test page for verifying the driver works |

### Legacy files (from previous Ghostscript-based approach)

| File | Purpose |
|------|---------|
| `bundle-gs.sh` | Previously bundled Ghostscript — no longer needed |
| `foomatic-rip` | Previous CUPS filter using gs pipeline — replaced by rastertoxqx |
| `foo2xqx-filter` | Alternative filter — replaced by rastertoxqx |
| `foo2xqx-wrapper` | Wrapper script — replaced by rastertoxqx |

## Troubleshooting

### Check CUPS error log
```bash
tail -f /var/log/cups/error_log
```

### Printer not responding
Upload firmware first — the P1007 won't accept print jobs without it:
```bash
lp -oraw /usr/local/share/foo2xqx/firmware/sihpP1005.dl
```

### "Filter failed" error
Verify the filter is installed:
```bash
ls -la /usr/libexec/cups/filter/rastertoxqx
```
If missing, re-run `sudo ./install.sh`.

### Output is light or outlined
Make sure the PPD resolution is set to 1200x600dpi (the default). The P1007 requires Bpp=2 for correct rendering — 600x600dpi produces faint output.

### After macOS update
Recompile and reinstall:
```bash
sudo ./install.sh
```

## Technical Details

The XQX protocol and JBIG compression code is derived from the open-source [foo2zjs](http://foo2zjs.rkkda.com/) project by Rick Richardson. The JBIG-KIT library is by Markus Kuhn. Both are GPL v2+.

The key insight is that macOS's `cgpdftoraster` handles all the PDF rendering natively (using CoreGraphics), so we don't need Ghostscript at all. The `rastertoxqx` filter just reads the CUPS raster stream, JBIG-compresses each page, and wraps it in the XQX protocol with PJL headers.

### Previous approach (and why it was replaced)

The original driver used Ghostscript to rasterize PostScript to PBM bitmaps. But CUPS runs filters in a sandbox that blocks loading Homebrew dylibs. The workaround was `bundle-gs.sh` — a script that copied Ghostscript + 15 dylibs into the CUPS filter directory, rewrote all library paths with `install_name_tool`, and re-codesigned everything. This ~35MB bundle broke on every `brew upgrade ghostscript`.

The new approach eliminates all of that.
