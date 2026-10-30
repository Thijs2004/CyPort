#!/bin/bash
# Checks (on a Mac) what the retargeted binaries import from libMacShim:
#   - symbols the shim defines itself: fine
#   - symbols the shim re-exports from iOS (Foundation/CoreGraphics/Security/Metal): checked against the iOS SDK;
#     anything in neither is a symbol dyld can't bind, so the game would quit at launch ("Symbol not found") - fails the build
set -euo pipefail
APP="$1"; T="$(mktemp -d)"
nm -gUj "$APP/Frameworks/libMacShim.dylib" | sort -u > "$T/have"
: > "$T/need"
for f in "$APP/Cyberpunk2077" "$APP"/Frameworks/*.dylib; do
  [ "$(basename "$f")" = libMacShim.dylib ] && continue
  [ -f "$f" ] && { nm -m -u "$f" | grep "(from libMacShim)" | sed -E 's/.*external ([^ ]+) \(from.*/\1/' >> "$T/need" || true; }
done
sort -u "$T/need" -o "$T/need"
comm -23 "$T/need" "$T/have" > "$T/reexported"
echo "    imports routed to shim: $(wc -l < "$T/need" | tr -d ' ')"
echo "    defined by the shim itself: $(comm -12 "$T/need" "$T/have" | wc -l | tr -d ' ')"
SDK="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)"
if [ -n "$SDK" ]; then
  for fw in Foundation CoreGraphics Security Metal; do
    grep -oE '_[A-Za-z0-9_$]+' "$SDK/System/Library/Frameworks/$fw.framework/$fw.tbd" || true
  done | sort -u > "$T/ios"
  comm -23 "$T/reexported" "$T/ios" > "$T/missing"
  echo "    re-exported from iOS frameworks: $(comm -12 "$T/reexported" "$T/ios" | wc -l | tr -d ' ')"
  if [ -s "$T/missing" ]; then
    echo "    MISSING - not in the shim and not in iOS Foundation/CoreGraphics/Security/Metal (add them to shim/MacShim.m):"
    sed 's/^/      /' "$T/missing"
    exit 1
  fi
else
  echo "    re-exported from iOS frameworks (not checked: no iPhoneOS SDK found): $(wc -l < "$T/reexported" | tr -d ' ')"
fi
echo "    other libraries still referenced:"; otool -L "$APP/Cyberpunk2077" | awk 'NR>1{print "      "$1}' | grep -v libMacShim
