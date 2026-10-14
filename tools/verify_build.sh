#!/bin/bash
# Checks (on a Mac) what the retargeted binaries import from libMacShim:
#   - symbols the shim defines itself: fine
#   - symbols the shim merely re-exports from iOS (Foundation/CoreGraphics/Security/Metal): reported, must exist on the device
set -euo pipefail
APP="$1"; T="$(mktemp -d)"
nm -gUj "$APP/Frameworks/libMacShim.dylib" | sort -u > "$T/have"
: > "$T/need"
for f in "$APP/Cyberpunk2077" "$APP"/Frameworks/lib{Bink2MacArm64,Galaxy,GameServicesGOG,REDGalaxy64}.dylib; do
  [ -f "$f" ] && { nm -m -u "$f" | grep "(from libMacShim)" | sed -E 's/.*external ([^ ]+) \(from.*/\1/' >> "$T/need" || true; }
done
sort -u "$T/need" -o "$T/need"
echo "    imports routed to shim: $(wc -l < "$T/need" | tr -d ' ')"
echo "    defined by the shim itself: $(comm -12 "$T/need" "$T/have" | wc -l | tr -d ' ')"
echo "    re-exported from iOS frameworks (checked against the iOS SDK at authoring time): $(comm -23 "$T/need" "$T/have" | wc -l | tr -d ' ')"
echo "    other libraries still referenced:"; otool -L "$APP/Cyberpunk2077" | awk 'NR>1{print "      "$1}' | grep -v libMacShim
