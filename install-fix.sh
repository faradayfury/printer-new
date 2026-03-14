#!/bin/bash
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Step 2: Install binaries to /usr/local/bin ==="
sudo cp "$DIR/foo2xqx-wrapper" /usr/local/bin/foo2xqx-wrapper
sudo cp "$DIR/foo2zjs/foo2xqx" /usr/local/bin/foo2xqx
sudo chmod +x /usr/local/bin/foo2xqx-wrapper /usr/local/bin/foo2xqx
echo "  Installed foo2xqx-wrapper and foo2xqx"

echo "=== Step 3: Install original PPD (foomatic-rip + foo2xqx-wrapper) ==="
sudo cp "$DIR/foo2zjs/PPD/HP-LaserJet_P1007.ppd" /private/etc/cups/ppd/HP_LaserJet_P1007.ppd
echo "  PPD installed"

echo "=== Step 4: Clear stuck jobs and test ==="
cancel -a HP_LaserJet_P1007 2>/dev/null || true
echo "  Cleared print queue"

echo ""
echo "=== Verification ==="
echo "  foo2xqx-wrapper: $(which foo2xqx-wrapper)"
echo "  foo2xqx:         $(which foo2xqx)"
echo "  foomatic-rip:    $(ls /usr/libexec/cups/filter/foomatic-rip 2>/dev/null || echo 'NOT FOUND')"
echo ""
echo "=== Sending test page ==="
lp -d HP_LaserJet_P1007 "$DIR/testpage.pdf"
echo ""
echo "Watch CUPS log with: tail -f /var/log/cups/error_log"
