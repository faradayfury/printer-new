#!/bin/sh
#
# Install a LaunchDaemon that auto-uploads firmware when the
# HP LaserJet P1007 is connected via USB.
#
# Usage: sudo ./install-hotplug.sh
#

set -e

FIRMWARE="/usr/local/share/foo2xqx/firmware/sihpP1005.dl"
PLIST_NAME="com.foo2xqx.firmware-upload"
PLIST_PATH="/Library/LaunchDaemons/$PLIST_NAME.plist"
SCRIPT_PATH="/usr/local/bin/hp-p1007-firmware-upload"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run with sudo."
    exit 1
fi

if [ ! -f "$FIRMWARE" ]; then
    echo "ERROR: Firmware not found at $FIRMWARE"
    echo "Run install.sh first."
    exit 1
fi

# Create the firmware upload script
cat > "$SCRIPT_PATH" << 'SCRIPT'
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
SCRIPT

chmod 755 "$SCRIPT_PATH"

# Create the LaunchDaemon plist
# Uses IOKit matching to trigger on exact USB device (VID 0x03f0, PID 0x4817)
cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_NAME</string>
    <key>ProgramArguments</key>
    <array>
        <string>$SCRIPT_PATH</string>
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
EOF

chmod 644 "$PLIST_PATH"

# (Re)load the daemon — unload first in case a previous version is loaded
launchctl unload "$PLIST_PATH" 2>/dev/null || true
if ! launchctl load "$PLIST_PATH" 2>&1; then
    echo "WARNING: Failed to load LaunchDaemon. You may need to reboot or load it manually:"
    echo "  sudo launchctl load $PLIST_PATH"
fi

echo "Firmware auto-upload daemon installed."
echo "  Script: $SCRIPT_PATH"
echo "  Daemon: $PLIST_PATH"
echo ""
echo "The firmware will be uploaded when the printer is detected."
echo "You can also manually upload at any time with:"
echo "  lp -oraw $FIRMWARE"
