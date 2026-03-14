# HP LaserJet P1007 — ARM64 macOS Driver

A native Apple Silicon driver for the HP LaserJet P1007 (and P1005/P1006/P1008) on macOS.

The driver is a single 85KB binary (`rastertoxqx`) that converts CUPS raster data to the printer's native XQX format using JBIG compression. It links only against system libraries and runs inside the CUPS sandbox without issues. No Ghostscript, no Homebrew dependencies.

```
PDF → cgpdftoraster (macOS built-in) → rastertoxqx → XQX → printer
```

macOS already knows how to render PDFs into raster through CoreGraphics via its built-in `cgpdftoraster` filter. `rastertoxqx` takes that raster output and wraps it in the XQX/ZjStream protocol the printer expects.

## Installation

You need macOS on Apple Silicon and Xcode Command Line Tools (`xcode-select --install`).

```bash
# Install the driver — compiles rastertoxqx, installs the filter, PPD, and firmware
sudo ./install.sh

# Set up automatic firmware upload when the printer is plugged in
sudo ./install-hotplug.sh
```

After that, go to System Settings > Printers & Scanners, add the printer, and select "HP LaserJet P1007 rastertoxqx" as the driver. Print a test page with `lp -d HP_LaserJet_P1007 testpage.pdf`.

## Firmware

The P1007 has no persistent firmware — it needs a 223KB blob uploaded over USB every time it powers on. If you ran `install-hotplug.sh`, this happens automatically when you plug the printer in. Otherwise you can do it manually:

```bash
lp -oraw /usr/local/share/foo2xqx/firmware/sihpP1005.dl
```

Wait for the printer light to flash orange (~5 seconds) before printing.

## Troubleshooting

Check the CUPS error log with `tail -f /var/log/cups/error_log`.

If the printer isn't responding, it probably needs firmware uploaded — it won't accept print jobs without it.

If you get a "filter failed" error, check that the filter is installed at `/usr/libexec/cups/filter/rastertoxqx`. If it's missing, re-run `sudo ./install.sh`.

If the output is light or outlined, make sure the PPD resolution is 1200x600dpi (the default). The P1007 needs Bpp=2 for correct rendering — 600x600dpi produces faint output.

After a macOS update, recompile and reinstall with `sudo ./install.sh`.

## Background

The XQX protocol and JBIG compression code comes from the [foo2zjs](http://foo2zjs.rkkda.com/) project by Rick Richardson, and the JBIG-KIT library by Markus Kuhn. Both are GPL v2+.

This driver replaced an earlier approach that used Ghostscript for PDF-to-raster rendering. That worked, but CUPS runs filters in a sandbox that blocks Homebrew libraries, so Ghostscript had to be bundled with all ~15 of its dylibs rewritten to use `@loader_path/`. The resulting package was ~35MB and broke on every `brew upgrade ghostscript`. Using macOS's built-in `cgpdftoraster` eliminated all of that.

## Other Printers

This driver currently works with the P1007, but the approach applies to other models too. The `rastertoxqx` binary should work as-is for these XQX-protocol printers — they just need their own PPD and firmware files:

- HP LaserJet P1005
- HP LaserJet P1006
- HP LaserJet P1008
- HP LaserJet P1505

The LaserJet 1018, 1020, and 1022 use a related protocol (ZjStream) that needs a separate filter binary, but the structure is almost identical to `rastertoxqx` and the work is scoped out.

Beyond HP, the same porting pattern could support printers from Dell, Xerox, Samsung, and Konica Minolta that the foo2zjs project already handles on Linux.

### How to help

If you have one of these printers and a Mac with Apple Silicon, I'd appreciate help testing. You don't need to be a developer.

1. [Open an issue](https://github.com/faradayfury/printer-new/issues/new) with your printer model and macOS version
2. If you're comfortable running terminal commands, try `sudo ./install.sh` and let me know if it prints

I'll work through any issues with you from there.
