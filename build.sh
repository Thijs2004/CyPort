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
# Several game versions in ONE app: GAME_APPS="/path/2.31a/Cyberpunk2077.app|/path/2.5/Cyberpunk2077.app" - each goes into
# Games/<version>/ and the app starts the one that fits the game data it finds (see MacShimMain in shim/MacShim.m).
GAME_APPS="${GAME_APPS:-}"
if [ -n "$GAME_APPS" ]; then IFS='|' read -ra GAME_LIST <<< "$GAME_APPS"; GAME_APP="${GAME_LIST[${#GAME_LIST[@]}-1]}"; fi
GAME_APP="${GAME_APP:?set GAME_APP to the Cyberpunk2077.app folder (or GAME_APPS to several, separated by |)}"
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
  "$HERE/shim/MacShim.m" "$HERE/shim/MacShimC.c" "$HERE/shim/PadLayout.c" "$HERE/shim/StoreCodecs.c" "$HERE/shim/third_party/lzma/LzmaDec.c" $SWIFT_OBJ \
  -o "$APP/Frameworks/libMacShim.dylib"
rm -f "$APP/Frameworks/Launcher.o"

else
  echo "==> 1/4 using prebuilt MacShim (compiled from shim/*.m, *.c; REBUILD_SHIM=1 to recompile)"
  cp "$HERE/prebuilt/libMacShim.dylib" "$APP/Frameworks/libMacShim.dylib"
fi
rm -rf "$APP"/Frameworks/*.dSYM
# The iOS SDK version stamped into the game: iOS shows an app at a newer iPhone's real screen size only when the app says
# it was built with an SDK that knows that iPhone. Stamped "18.0", an iPhone Duo runs CyPort in a zoomed 16:9 window
# (an iPhone 8-sized screen). So stamp the SDK of the Xcode on this Mac (IOS_SDK_VERSION=x.y overrides; 18.0 without Xcode).
SDK_VER="${IOS_SDK_VERSION:-}"; SDK_NAME=""; SDK_BUILD=""
SDK_DIR="${SDK:-$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)}"
if [ -z "$SDK_VER" ] && [ -n "$SDK_DIR" ] && [ -f "$SDK_DIR/SDKSettings.plist" ]; then
  SDK_VER="$(plutil -extract Version raw "$SDK_DIR/SDKSettings.plist" 2>/dev/null || true)"
  SDK_NAME="$(plutil -extract CanonicalName raw "$SDK_DIR/SDKSettings.plist" 2>/dev/null || true)"
  SDK_BUILD="$(xcrun --sdk "$SDK_DIR" --show-sdk-build-version 2>/dev/null || true)"
fi
case "$SDK_VER" in [0-9]*.[0-9]*) ;; [0-9]*) SDK_VER="$SDK_VER.0" ;; *) SDK_VER="18.0" ;; esac
if [ "${SDK_VER%%.*}" -lt 18 ]; then SDK_VER="18.0"; fi
# iOS 27 only launches an app stamped with the iOS 27+ SDK if it uses scenes (MSSceneDelegate, in the shim since the
# iPhone Duo support). A shim without it (an older prebuilt) keeps the old stamp and no scene list, or the screen stays black.
OLD_SHIM=0
if ! grep -q MSSceneDelegate "$APP/Frameworks/libMacShim.dylib"; then
  OLD_SHIM=1; SDK_VER="18.0"; SDK_NAME=""; SDK_BUILD=""
  echo "    this MacShim predates scene support: stamping iOS SDK 18.0 (REBUILD_SHIM=1 for an iPhone Duo's real screen sizes)"
fi
if [ -n "$GAME_APPS" ]; then
echo "==> 2/4 game versions -> Games/<version>/ (one app, the starter picks the version that fits the game data)"
for ga in "${GAME_LIST[@]}"; do
  [ -f "$ga/Contents/MacOS/Cyberpunk2077" ] || { echo "not found: $ga/Contents/MacOS/Cyberpunk2077"; exit 1; }
  python3 "$HERE/tools/data_manifest.py" "$ga" "$OUT/.data.json" || { echo "every game version needs its data list (GOG build info)"; exit 1; }
  v="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"].split("_")[0])' "$OUT/.data.json")"
  G="$APP/Games/$v"; mkdir -p "$G/Frameworks"; mv "$OUT/.data.json" "$G/CyPortData.json"
  python3 "$HERE/tools/ios_retarget.py" --game-folder "$ga/Contents/MacOS/Cyberpunk2077" "$G/CyberpunkGame.dylib" >/dev/null
  for f in "$ga"/Contents/Frameworks/*.dylib; do python3 "$HERE/tools/ios_retarget.py" --game-folder "$f" "$G/Frameworks/$(basename "$f")" >/dev/null; done
  python3 - "$ga" "$G" "$v" <<'PY'
import hashlib, json, plistlib, sys
ga, G, v = sys.argv[1:]
d = json.load(open(G + "/CyPortData.json"))["files"]
info = plistlib.load(open(ga + "/Contents/Info.plist", "rb"))
digits = "".join(c for c in v.split("_")[0] if c.isdigit())
plistlib.dump({"version": v, "number": float(digits[0] + "." + digits[1:]) if digits else 0.0,
               "CyPortGameExe": hashlib.md5(open(ga + "/Contents/MacOS/Cyberpunk2077", "rb").read()).hexdigest(),
               "shortVersion": info.get("CFBundleShortVersionString", "?"), "bundleVersion": info.get("CFBundleVersion", "?"),
               "redscriptsSize": d.get("r6/cache/final.redscripts", {}).get("size", 0), "tweakdbSize": d.get("r6/cache/tweakdb.bin", {}).get("size", 0)},
              open(G + "/game.plist", "wb"))
print("    Games/%s: game program %s" % (v, info.get("CFBundleShortVersionString")))
PY
done
# the starter is the app's executable, so it carries the SDK stamp (see above): iOS 27+ SDK = real screen sizes on
# an iPhone Duo, and then UIKit insists on the scene life cycle (MSSceneDelegate); a shim without it gets 18.0
clang -target arm64-apple-ios16.0 -isysroot "$SDK_DIR" -O2 "$HERE/app/starter.c" -L"$APP/Frameworks" -lMacShim \
  -Wl,-rpath,@executable_path/Frameworks -Wl,-platform_version,ios,18.0,$SDK_VER -o "$APP/Cyberpunk2077"
echo "    starter stamped with iOS SDK $SDK_VER"
else
echo "==> 2/4 retarget game binary + libraries (macOS -> iOS load commands only, iOS SDK $SDK_VER)"
python3 "$HERE/tools/ios_retarget.py" --sdk "$SDK_VER" "$GAME_APP/Contents/MacOS/Cyberpunk2077" "$APP/Cyberpunk2077" >/dev/null
chmod +x "$APP/Cyberpunk2077"
for f in "$GAME_APP"/Contents/Frameworks/*.dylib; do
  # the libraries keep SDK 18.0: stamped newer, dyld checks them more strictly and refuses libBink2MacArm64.dylib
  # ("mis-aligned LINKEDIT string pool"); only the main executable's SDK decides the screen size
  python3 "$HERE/tools/ios_retarget.py" "$f" "$APP/Frameworks/$(basename "$f")" >/dev/null
done
fi
sed "s/__BUNDLE_ID__/$BUNDLE_ID/" "$HERE/app/Info.plist" > "$APP/Info.plist"
if [ "$OLD_SHIM" = 1 ]; then plutil -remove UIApplicationSceneManifest "$APP/Info.plist"; fi
# the same SDK in the Info.plist keys Xcode writes (iOS reads both)
plutil -replace DTPlatformName -string iphoneos "$APP/Info.plist"
plutil -replace DTPlatformVersion -string "$SDK_VER" "$APP/Info.plist"
plutil -replace DTSDKName -string "${SDK_NAME:-iphoneos$SDK_VER}" "$APP/Info.plist"
[ -n "$SDK_BUILD" ] && { plutil -replace DTSDKBuild -string "$SDK_BUILD" "$APP/Info.plist"; plutil -replace DTPlatformBuild -string "$SDK_BUILD" "$APP/Info.plist"; }
# the game's own version (the start screen and the store downloads match the game data to it)
for k in CFBundleShortVersionString CFBundleVersion; do
  v="$(/usr/libexec/PlistBuddy -c "Print :$k" "$GAME_APP/Contents/Info.plist" 2>/dev/null || true)"
  [ -n "$v" ] && /usr/libexec/PlistBuddy -c "Set :$k $v" "$APP/Info.plist"
done
# which game program this is: the shim picks its addresses inside the game by it (kMSGames in shim/MacShim.m)
# (several versions: each Games/<version>/game.plist has its own)
if [ -z "$GAME_APPS" ]; then
EXE_MD5="$(md5 -q "$GAME_APP/Contents/MacOS/Cyberpunk2077" 2>/dev/null || md5sum "$GAME_APP/Contents/MacOS/Cyberpunk2077" | cut -d' ' -f1)"
/usr/libexec/PlistBuddy -c "Add :CyPortGameExe string $EXE_MD5" "$APP/Info.plist"
grep -q "$EXE_MD5" "$HERE/shim/MacShim.m" || echo "    NOTE: game program $EXE_MD5 is not in kMSGames (shim/MacShim.m): mouse gate / controller-ready check / free hook stay off"
fi
# which game data this game program needs (sizes + checksums from GOG's public build info): the start screen checks
# the data against it, and "Update Cyberpunk" downloads only the files that differ. Skipped (with a note) when offline.
if [ "${NO_DATA_MANIFEST:-0}" != "1" ] && [ -z "$GAME_APPS" ]; then
  python3 "$HERE/tools/data_manifest.py" "$GAME_APP" "$APP/CyPortData.json" \
    || { rm -f "$APP/CyPortData.json"; echo "    (no CyPortData.json: the app won't check or update the game data)"; }
fi
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
  for f in "$APP"/Frameworks/*.dylib "$APP"/Games/*/Frameworks/*.dylib "$APP"/Games/*/CyberpunkGame.dylib; do [ -f "$f" ] && codesign -f -s "$SIGN_ID" "$f"; done
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
    for f in "$APP"/Frameworks/*.dylib "$APP"/Games/*/Frameworks/*.dylib "$APP"/Games/*/CyberpunkGame.dylib; do [ -f "$f" ] && codesign -f -s - "$f" 2>/dev/null; done
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
