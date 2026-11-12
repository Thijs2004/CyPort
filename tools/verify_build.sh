#!/bin/bash
# Checks (on a Mac) what the retargeted binaries import from libMacShim:
#   - symbols the shim defines itself: fine
#   - symbols the shim merely re-exports from iOS (Foundation/CoreGraphics/Security/Metal): reported, must exist on the device
set -euo pipefail
APP="$1"; T="$(mktemp -d)"
nm -gUj "$APP/Frameworks/libMacShim.dylib" | sort -u > "$T/have"
: > "$T/need"
for f in "$APP/Cyberpunk2077" "$APP"/Frameworks/*.dylib "$APP"/Games/*/CyberpunkGame.dylib "$APP"/Games/*/Frameworks/*.dylib; do
  [ "$(basename "$f")" = libMacShim.dylib ] && continue
  [ -f "$f" ] && { nm -m -u "$f" | grep "(from libMacShim)" | sed -E 's/.*external ([^ ]+) \(from.*/\1/' >> "$T/need" || true; }
done
sort -u "$T/need" -o "$T/need"
echo "    imports routed to shim: $(wc -l < "$T/need" | tr -d ' ')"
echo "    defined by the shim itself: $(comm -12 "$T/need" "$T/have" | wc -l | tr -d ' ')"
echo "    re-exported from iOS frameworks (checked against the iOS SDK at authoring time): $(comm -23 "$T/need" "$T/have" | wc -l | tr -d ' ')"
echo "    other libraries still referenced:"; otool -L "$APP/Cyberpunk2077" | awk 'NR>1{print "      "$1}' | grep -v libMacShim
# Anything neither defined by the shim nor exported by the iOS frameworks it re-exports makes dyld stop the app at
# launch ("Symbol not found", e.g. 2.5's NSFontAttributeName). Checked against the SDK's .tbd stubs; fails the build.
SDKP="${SDK:-$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)}"
if [ -n "$SDKP" ] && [ -d "$SDKP/System/Library/Frameworks" ]; then
  cat "$SDKP"/System/Library/Frameworks/{Foundation,CoreGraphics,Security,Metal}.framework/*.tbd 2>/dev/null | grep -oE '_[A-Za-z_$][A-Za-z0-9_$]*' | sort -u > "$T/reexp"
  comm -23 "$T/need" "$T/have" | comm -23 - "$T/reexp" > "$T/missing"
  if [ -s "$T/missing" ]; then
    echo "    MISSING (the app would stop at launch) - add these to shim/MacShim.m:"; sed 's/^/      /' "$T/missing"; exit 1
  fi
  echo "    every import resolves (shim or iOS SDK)"
fi
