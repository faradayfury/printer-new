# HP LaserJet P1007 — ARM64 macOS Driver

A native Apple Silicon driver for the HP LaserJet P1007 (and P1005/P1006/P1008) using the open-source `foo2xqx` engine.

## The Problem

The HP LaserJet P1007 has no official driver for macOS on Apple Silicon. The open-source `foo2zjs`/`foo2xqx` project provides the conversion engine, but integrating it as a CUPS filter on modern macOS hits a major obstacle: **CUPS sandboxing**.

### What is CUPS Sandboxing?

On macOS, CUPS runs print filters inside an **App Sandbox** (seatbelt profile). This restricts what the filter process can do:

- **File system access** — filters can only read/write specific directories
- **Dynamic library loading** — `dyld` is restricted to loading `.dylib` files from approved paths only
- **Process execution** — child processes inherit the sandbox

This means a filter that works perfectly from the command line can fail silently when invoked by CUPS during an actual print job.

### How It Broke

The print pipeline is:

```
PDF → cgpdftops → pstops → foomatic-rip → printer
                              ↓
                    PostScript → gs (Ghostscript) → PBM raster → foo2xqx → XQX
```

Our `foomatic-rip` filter calls Ghostscript (`gs`) to rasterize PostScript into PBM bitmaps, then pipes that into `foo2xqx` to produce the printer's native XQX format.

**Problem 1: Dynamic library loading blocked by sandbox**

Homebrew's Ghostscript binary (`/opt/homebrew/bin/gs`) links against ~12 shared libraries via `/opt/homebrew/opt/...` symlink paths. The CUPS sandbox blocks `dyld` from following these symlinks:

```
dyld: Library not loaded: /opt/homebrew/opt/jbig2dec/lib/libjbig2dec.0.dylib
  Reason: tried: '/opt/homebrew/opt/jbig2dec/lib/libjbig2dec.0.dylib' (blocked by sandbox)
```

**Problem 2: Ghostscript resource files inaccessible**

Even after fixing library loading, `gs` couldn't find its initialization files (`gs_init.ps`, font definitions, etc.) because they live under `/opt/homebrew/Cellar/...` which the sandbox also blocks for file reads:

```
GPL Ghostscript 10.06.0: Can't find initialization file gs_init.ps.
```

### The Solution

We bundle a fully self-contained Ghostscript into `/usr/libexec/cups/filter/` — the one directory the CUPS sandbox **must** allow, since that's where it runs filters from.

The bundle consists of three parts:

1. **`gs-bundled`** — A copy of the Ghostscript binary with all dynamic library references rewritten from absolute Homebrew paths to `@loader_path/` (relative to the binary itself). This means `dyld` looks for libraries in the same directory as the binary, not in `/opt/homebrew/`.

2. **`*.dylib` files** — All of Ghostscript's Homebrew dependencies (and their transitive dependencies) copied into the same directory. Each library's internal references are also rewritten to use `@loader_path/`. Everything is re-codesigned (required on Apple Silicon).

3. **`gs-res/`** — Ghostscript's resource files (PostScript initialization scripts, font definitions, ICC profiles). The filter passes these to `gs` via `-I` flags to override the compiled-in search paths.

### What `@loader_path` Does

macOS `dyld` supports special path tokens:
- `@executable_path` — directory of the main executable
- `@loader_path` — directory of the binary/library that contains the reference

We use `@loader_path` so that when `gs-bundled` loads `libjbig2dec.0.dylib`, `dyld` resolves it to `/usr/libexec/cups/filter/libjbig2dec.0.dylib` — a path the sandbox allows.

The rewriting is done with `install_name_tool -change`:
```bash
# Before: gs links to /opt/homebrew/opt/jbig2dec/lib/libjbig2dec.0.dylib
# After:  gs links to @loader_path/libjbig2dec.0.dylib
install_name_tool -change \
    "/opt/homebrew/opt/jbig2dec/lib/libjbig2dec.0.dylib" \
    "@loader_path/libjbig2dec.0.dylib" \
    gs-bundled
```

### Dependency Chain

Ghostscript's full dependency tree that needed bundling:

```
gs-bundled
├── libjbig2dec.0.dylib          (JBIG2 decoder)
├── libtiff.6.dylib              (TIFF support)
├── libpng16.16.dylib            (PNG support)
├── libjpeg.8.dylib              (JPEG support)
├── liblcms2.2.dylib             (color management)
├── libidn.12.dylib              (internationalized domain names)
├── libfontconfig.1.dylib        (font configuration)
│   ├── libfreetype.6.dylib      (font rendering)
│   │   └── libpng16.16.dylib    (shared with above)
│   └── libintl.8.dylib          (gettext)
├── libfreetype.6.dylib          (font rendering)
├── libopenjp2.7.dylib           (JPEG 2000)
├── libtesseract.5.dylib         (OCR)
│   └── libleptonica.6.dylib     (image processing)
│       ├── libgif.dylib         (GIF support)
│       ├── libwebp.7.dylib      (WebP support)
│       │   └── libsharpyuv.0.dylib  (@rpath dep)
│       └── libwebpmux.3.dylib   (WebP muxing)
│           └── libsharpyuv.0.dylib  (@rpath dep)
└── libarchive.13.dylib          (archive support)
```

Note: Some libraries use `@rpath` references instead of absolute paths (e.g., `libsharpyuv`). The bundle script handles both patterns.

## Files

| File | Purpose |
|------|---------|
| `install.sh` | Main installer — compiles foo2xqx, installs filter + PPD + firmware |
| `bundle-gs.sh` | Bundles Ghostscript with all deps for CUPS sandbox compatibility |
| `foomatic-rip` | CUPS filter — reads PPD options, runs gs→foo2xqx pipeline |
| `foo2xqx-filter` | Alternative simpler CUPS filter |
| `foo2xqx-wrapper` | Wrapper for foomatic-rip→foo2xqx pipeline |
| `HP-LaserJet_P1007.ppd` | PPD file describing printer capabilities |
| `install-hotplug.sh` | Sets up automatic firmware upload via IOKit USB device matching |
| `build-pkg.sh` | Builds a distributable .pkg installer |
| `install-fix.sh` | Quick reinstall of binaries and PPD |
| `foo2zjs/` | Source code for foo2xqx and related tools |
| `testpage.pdf` | Test page for verifying the driver works |

## Installation

### Prerequisites

- macOS on Apple Silicon (arm64)
- Homebrew with Ghostscript: `brew install ghostscript`
- Xcode Command Line Tools: `xcode-select --install`

### Steps

```bash
# 1. Install the driver (compiles foo2xqx, installs filter + PPD + firmware)
sudo ./install.sh

# 2. Bundle Ghostscript for CUPS sandbox compatibility
sudo bash ./bundle-gs.sh

# 3. Install the foomatic-rip filter
sudo cp foomatic-rip /usr/libexec/cups/filter/foomatic-rip
sudo chmod 755 /usr/libexec/cups/filter/foomatic-rip

# 4. Set up automatic firmware upload (triggers on USB connect via IOKit matching)
sudo ./install-hotplug.sh

# 5. Add printer via System Settings > Printers & Scanners
#    Select "HP LaserJet P1007 foo2xqx" as the driver

# 6. Print a test page
lp -d HP_LaserJet_P1007 testpage.pdf
```

## Troubleshooting

### Check CUPS error log
```bash
tail -f /var/log/cups/error_log
```

### "Library not loaded" / "blocked by sandbox"
Re-run `bundle-gs.sh`. If Ghostscript was updated via Homebrew, the Cellar path will have changed and the bundle needs to be regenerated.

### "Can't find initialization file gs_init.ps"
The `gs-res/` directory is missing or the `-I` paths in `foomatic-rip` are wrong. Re-run `bundle-gs.sh`.

### "Not a pbm file!"
Ghostscript failed to produce output. Check the lines above this error in the log for the root cause (usually a sandbox or missing resource issue).

### Filter works from terminal but fails when printing
This is the sandbox. Verify the bundled gs works:
```bash
/usr/libexec/cups/filter/gs-bundled --version
```

### Ghostscript updated via Homebrew
After `brew upgrade ghostscript`, re-run `bundle-gs.sh` to rebundle with the new version.
