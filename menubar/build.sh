#!/bin/bash
# Builds "DNS Switch.app" into ~/Applications and launches it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$(cd "$HERE/.." && pwd)/dns-switch.sh"
APP="$HOME/Applications/DNS Switch.app"

# VPN_GATEWAYS comes from the private local/.env, so gateway names stay out of the code.
source "$(dirname "$SCRIPT")/local/.env"
GATEWAYS_XML=""
for g in "${VPN_GATEWAYS[@]}"; do GATEWAYS_XML+="<string>$g</string>"; done

pkill -x DNSSwitch 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -o "$APP/Contents/MacOS/DNSSwitch" "$HERE/DNSSwitch.swift"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>DNSSwitch</string>
  <key>CFBundleIdentifier</key><string>local.dns-switch.menubar</string>
  <key>CFBundleName</key><string>DNS Switch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>DNSSwitchScript</key><string>$SCRIPT</string>
  <key>VPNGateways</key><array>$GATEWAYS_XML</array>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"
open "$APP"
echo "Installed: $APP"
