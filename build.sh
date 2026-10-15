#!/bin/bash
# CyPort: build the iPhone/iPad app from YOUR OWN copy of Cyberpunk 2077 for Mac (GOG 2.3.1). Run on a Mac with Xcode.
#
#   GAME_APP="/path/to/Cyberpunk 2077/Cyberpunk2077.app" ./build.sh
#
# Optional env:  BUNDLE_ID=com.you.cp2077   PROFILE=/path/x.mobileprovision   SIGN_ID="Apple Development: Name (TEAMID)"
#                -> with SIGN_ID (+PROFILE) it signs here, entitlements generated from the profile; DEVICE=<udid> also installs.
#                ENT=app/entitlements-memory.plist + ENT_FROM_PROFILE=0 to use a fixed entitlements file instead.
#                Xcode on another disk: DEVELOPER_DIR=/Volumes/x/Xcode.app/Contents/Developer ./build.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GAME_APP="${GAME_APP:?set GAME_APP to the Cyberpunk2077.app folder}"
BUNDLE_ID="${BUNDLE_ID:-com.example.cyport}"
ENT="${ENT:-$HERE/app/entitlements-basic.plist}"
# Output (override with OUT=/some/folder)
OUT="${OUT:-$HERE/build}"
mkdir -p "$OUT" || { echo "cannot create $OUT"; exit 1; }
APP="$OUT/Payload/Cyberpunk2077.app"
SDK_CACHE="${SDK_CACHE:-$OUT/.ios-sdk}"
echo "==> output folder: $OUT"
[ -f "$GAME_APP/Contents/MacOS/Cyberpunk2077" ] || { echo "not found: $GAME_APP/Contents/MacOS/Cyberpunk2077"; exit 1; }
rm -rf "$OUT/Payload" "$OUT"/*.ipa; mkdir -p "$APP/Frameworks"   # only our own outputs are cleared

if [ "${REBUILD_SHIM:-0}" = "1" ] || [ ! -f "$HERE/prebuilt/libMacShim.dylib" ]; then
  command -v clang >/dev/null || { echo "Xcode command line tools required: xcode-select --install"; exit 1; }
# ---- find an iOS SDK: $SDK, Xcode, Theos, or download the standalone iPhoneOS 16.5 SDK (no Xcode needed)
find_sdk() {
  [ -n "${SDK:-}" ] && [ -d "$SDK" ] && { echo "$SDK"; return; }
  local p; p="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)"; [ -n "$p" ] && [ -d "$p" ] && { echo "$p"; return; }
  for p in /Applications/Xcode*.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk \
           "$HOME"/theos/sdks/iPhoneOS*.sdk "$SDK_CACHE"/iPhoneOS*.sdk "$HOME/.cp2077-sdk"/iPhoneOS*.sdk; do
    [ -d "$p" ] && { echo "$p"; return; }
  done
}
SDK="$(find_sdk | tail -n 1 || true)"
if [ -z "$SDK" ]; then
  echo "==> no iOS SDK found - downloading the standalone iPhoneOS16.5 SDK (github.com/theos/sdks) into $SDK_CACHE"
  command -v git >/dev/null || { echo "git missing"; exit 1; }
  rm -rf "$SDK_CACHE"
  git clone --depth 1 --filter=blob:none --sparse https://github.com/theos/sdks "$SDK_CACHE"
  git -C "$SDK_CACHE" sparse-checkout set iPhoneOS16.5.sdk
  SDK="$SDK_CACHE/iPhoneOS16.5.sdk"
fi
[ -d "$SDK/System/Library/Frameworks/UIKit.framework" ] || { echo "SDK looks wrong: $SDK"; exit 1; }
echo "==> using iOS SDK: $SDK"

  echo "==> 1/4 compile MacShim from source (AppKit/IOKit/CoreGraphics/curl stand-ins)"
LDFLAG=""; [ "$(uname)" = "Linux" ] && LDFLAG="-fuse-ld=lld"   # Linux build host: use lld (NOTE: the lld-linked shim had a
# broken two-level namespace - dyld: "Symbol not found: __dispatch_main_q ... Expected in CoreGraphics" - build on a Mac)
# the start screen is SwiftUI (shim/Launcher.swift): compiled to an object and linked into the shim
SWIFT_OBJ=""; SWIFT_LD=""
if command -v swiftc >/dev/null 2>&1 || xcrun -f swiftc >/dev/null 2>&1; then
  SWIFTC="$(xcrun -f swiftc 2>/dev/null || command -v swiftc)"; TC="$(dirname "$(dirname "$SWIFTC")")"
  "$SWIFTC" -target arm64-apple-ios16.0 -sdk "$SDK" -O -parse-as-library -emit-object -module-name MacShimUI \
    -wmo "$HERE/shim/Launcher.swift" "$HERE/shim/StoresCore.swift" "$HERE/shim/StoresUI.swift" "$HERE/shim/GameCloud.swift" -o "$APP/Frameworks/Launcher.o" && SWIFT_OBJ="$APP/Frameworks/Launcher.o" \
    && SWIFT_LD="-L$SDK/usr/lib/swift -L$TC/lib/swift/iphoneos -Xlinker -rpath -Xlinker /usr/lib/swift"
fi
clang $LDFLAG -target arm64-apple-ios16.0 -isysroot "$SDK" -dynamiclib -fobjc-arc -O2 $SWIFT_LD \
  -install_name @rpath/libMacShim.dylib -compatibility_version 9999.0.0 -current_version 9999.0.0 \
  -framework Foundation -framework UIKit -framework GameController -framework QuartzCore \
  -framework Security -framework CoreGraphics -framework CoreFoundation -framework Metal -framework UniformTypeIdentifiers -framework WebKit -lz \
  -Wl,-reexport_framework,Foundation -Wl,-reexport_framework,CoreGraphics -Wl,-reexport_framework,Security -Wl,-reexport_framework,Metal \
  "$HERE/shim/MacShim.m" "$HERE/shim/MacShimC.c" "$HERE/shim/StoreCodecs.c" "$HERE/shim/third_party/lzma/LzmaDec.c" $SWIFT_OBJ \
  -o "$APP/Frameworks/libMacShim.dylib"
rm -f "$APP/Frameworks/Launcher.o"

else
  echo "==> 1/4 using prebuilt MacShim (compiled from shim/*.m, *.c against the iPhoneOS 16.5 SDK; REBUILD_SHIM=1 to recompile)"
  cp "$HERE/prebuilt/libMacShim.dylib" "$APP/Frameworks/libMacShim.dylib"
fi
rm -rf "$APP"/Frameworks/*.dSYM
echo "==> 2/4 retarget game binary + libraries (macOS -> iOS load commands only)"
python3 "$HERE/tools/ios_retarget.py" "$GAME_APP/Contents/MacOS/Cyberpunk2077" "$APP/Cyberpunk2077" >/dev/null
chmod +x "$APP/Cyberpunk2077"
for f in "$GAME_APP"/Contents/Frameworks/*.dylib; do
  python3 "$HERE/tools/ios_retarget.py" "$f" "$APP/Frameworks/$(basename "$f")" >/dev/null
done
sed "s/__BUNDLE_ID__/$BUNDLE_ID/" "$HERE/app/Info.plist" > "$APP/Info.plist"
# first-run graphics settings (everything at its lowest); the shim copies it when the game has no UserSettings.json yet
[ -f "$HERE/app/DefaultUserSettings.json" ] && cp "$HERE/app/DefaultUserSettings.json" "$APP/DefaultUserSettings.json"
# app icon (legacy CFBundleIconFiles PNGs, see Info.plist)
[ -d "$HERE/app/icons" ] && cp "$HERE"/app/icons/AppIcon*.png "$APP/"
[ -n "${PROFILE:-}" ] && cp "$PROFILE" "$APP/embedded.mobileprovision"

echo "==> 3/4 verify every symbol the game wants from the shim is exported by it"
if command -v nm >/dev/null && command -v otool >/dev/null; then "$HERE/tools/verify_build.sh" "$APP"; else echo "    (nm/otool not available on this host - skipped)"; fi

echo "==> 4/4 sign + package"
if [ -n "${SIGN_ID:-}" ]; then
  if [ -n "${PROFILE:-}" ] && [ "${ENT_FROM_PROFILE:-1}" = "1" ]; then
    # Entitlements must match the profile: application-identifier = TEAM.BUNDLE_ID, plus the memory entitlements if the
    # profile grants them. Without extended-virtual-addressing the game dies before main() (it reserves ~118 GB of VA).
    ENT="$OUT/entitlements.plist"
    python3 - "$PROFILE" "$BUNDLE_ID" "$ENT" <<'PY'
import plistlib, subprocess, sys
prof, bid, out = sys.argv[1:]
p = plistlib.loads(subprocess.run(["security", "cms", "-D", "-i", prof], capture_output=True, check=True).stdout)
e = p["Entitlements"]; team = e["com.apple.developer.team-identifier"]; appid = e["application-identifier"]
if appid != team + ".*" and appid != team + "." + bid:
    sys.exit("profile is for %s, not %s.%s - set BUNDLE_ID to match it" % (appid, team, bid))
ent = {"application-identifier": team + "." + bid, "com.apple.developer.team-identifier": team, "get-task-allow": bool(e.get("get-task-allow", True))}
for k in ("com.apple.developer.kernel.increased-memory-limit", "com.apple.developer.kernel.extended-virtual-addressing"):
    if e.get(k): ent[k] = True
if "com.apple.developer.kernel.extended-virtual-addressing" not in ent:
    print("    note: profile has no extended-virtual-addressing - the shim uses its compact memory layout (see README)")
plistlib.dump(ent, open(out, "wb")); print("    entitlements from profile:", ", ".join(sorted(ent)))
PY
  fi
  for f in "$APP"/Frameworks/*.dylib; do codesign -f -s "$SIGN_ID" "$f"; done
  codesign -f -s "$SIGN_ID" --entitlements "$ENT" "$APP"
  codesign --verify --deep --strict "$APP" && echo "    signature OK"
  (cd "$OUT" && zip -qry CyPort.ipa Payload)
  echo "done: $OUT/CyPort.ipa"
  if [ -n "${DEVICE:-}" ]; then          # DEVICE=<udid> installs it right away (Xcode 15+ devicectl)
    xcrun devicectl device install app --device "$DEVICE" "$APP"
  fi
else
  # ad-hoc signature carrying app/entitlements-sideload.plist: the game binary still has the Mac build's signature and
  # entitlements, and SideStore/AltStore keep only entitlements the app itself lists (so the memory limit was dropped)
  if command -v codesign >/dev/null; then
    for f in "$APP"/Frameworks/*.dylib; do codesign -f -s - "$f" 2>/dev/null; done
    codesign -f -s - --entitlements "$HERE/app/entitlements-sideload.plist" "$APP" && echo "    ad-hoc signed with app/entitlements-sideload.plist"
  fi
  (cd "$OUT" && zip -qry CyPort-unsigned.ipa Payload)
  cat <<MSG
Unsigned IPA ready (sign it with Sideloadly / AltStore / iloader, or by hand): $OUT/CyPort-unsigned.ipa
Unsigned app folder: $APP
SideStore / AltStore / Sideloadly can install it as is (free Apple ID: see README "Free Apple ID").
Or sign it yourself, libraries first, then the app:
  for f in "$APP"/Frameworks/*.dylib; do codesign -f -s "<identity>" "\$f"; done
  codesign -f -s "<identity>" --entitlements "$HERE/app/entitlements-sideload.plist" "$APP"
  (cd "$OUT" && zip -qry CyPort.ipa Payload)
MSG
fi
echo "Game data goes into the app's Documents/Cyberpunk 2077/ folder - see README.md"
