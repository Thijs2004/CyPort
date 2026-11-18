#!/bin/bash
# CyPort one-step build: the four RED4ext plugins (iOS), the baked-hook table, the app (build.sh), and a deployment folder
# that mirrors the phone's "Documents/Cyberpunk 2077/".
#
#   tools/build-all.sh              build everything, stage build/deploy/Cyberpunk 2077/
#   tools/build-all.sh --install    ... then install the app and copy the staged files to the phone (xcrun devicectl)
#
# Environment (defaults in brackets). Personal values (signing identity, profile, bundle id, device, paths) go in
# tools/local.env, which is git-ignored and read first when present; tools/local.env.example shows the format.
#   GAME_APP       the Mac game (required)
#   SIGN_ID        codesign identity for the app and the plugin dylibs   [none: unsigned IPA, plugins ad-hoc signed]
#   PROFILE        provisioning profile                                  [none]
#   BUNDLE_ID      app bundle id (also the data container for --install) [com.example.cyport]
#   PLUGINS_ROOT   plugin checkouts (RED4ext-macos, tweak-xl, archive-xl, codeware) [../CyPort-red4ext, next to this repo]
#   CODEWARE_VERSION  version stamped into Codeware's composed scripts   [1.21.4]
#   CYPORT_DEVICE  device for --install (devicectl id/udid)              [required for --install]
#   BUILD_LOG      build.sh output                                       [<repo>/build.log]
#   SKIP_PLUGINS=1 / SKIP_APP=1   skip the plugin builds / the app build (staging still runs)
# DEVICE is deliberately not passed to build.sh (it would install from there); --install does that step here.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
[ -f "$HERE/tools/local.env" ] && . "$HERE/tools/local.env"

GAME_APP="${GAME_APP:?set GAME_APP to the Mac game (Cyberpunk2077.app), e.g. in tools/local.env}"
SIGN_ID="${SIGN_ID:-}"
PROFILE="${PROFILE:-}"
BUNDLE_ID="${BUNDLE_ID:-com.example.cyport}"
PLUGINS_ROOT="${PLUGINS_ROOT:-$(dirname "$HERE")/CyPort-red4ext}"
CODEWARE_VERSION="${CODEWARE_VERSION:-1.21.4}"
CYPORT_DEVICE="${CYPORT_DEVICE:-}"
export SIGN_ID   # the plugin staging scripts read it
BUILD_LOG="${BUILD_LOG:-$HERE/build.log}"
OUT="$HERE/build"
DEPLOY="$OUT/deploy/Cyberpunk 2077"

INSTALL=0
for a in "$@"; do
  case "$a" in
    --install) INSTALL=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $a"; exit 2 ;;
  esac
done

R4E="$PLUGINS_ROOT/RED4ext-macos"; TXL="$PLUGINS_ROOT/tweak-xl"; AXL="$PLUGINS_ROOT/archive-xl"; CW="$PLUGINS_ROOT/codeware"
IOS_ARGS=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT=iphoneos
          -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=18.0)

# configure <src> <build> [extra cmake args...]: only when the build folder has never been configured
configure() {
  local src="$1" bld="$2"; shift 2
  if [ ! -f "$bld/build.ninja" ]; then
    echo "==> configure $bld"
    cmake -S "$src" -B "$bld" "${IOS_ARGS[@]}" "$@"
  fi
}

if [ "${SKIP_PLUGINS:-0}" != "1" ]; then
  echo "==> plugins"
  configure "$R4E" "$R4E/build-ios"
  ninja -C "$R4E/build-ios" RED4ext.Dll
  configure "$TXL" "$TXL/build-ios"
  ninja -C "$TXL/build-ios"
  configure "$AXL/macos" "$AXL/build-ios"
  ninja -C "$AXL/build-ios"
  configure "$CW/macos" "$CW/build-ios" -DRED4EXT_SDK_DIR="$PLUGINS_ROOT/RED4ext.SDK-macos-sdk1212"
  ninja -C "$CW/build-ios"

  echo "==> Codeware scripts (minus tools/build-cache.exclude, version $CODEWARE_VERSION)"
  rm -rf "$CW/build-ios/scripts-filtered" "$CW/build-ios/Scripts"
  cp -R "$CW/scripts" "$CW/build-ios/scripts-filtered"
  # entries are "Codeware-src/<path under scripts/>", optionally followed by a # comment
  sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$CW/tools/build-cache.exclude" | grep '^Codeware-src/' | sed 's#^Codeware-src/##' |
    while IFS= read -r rel; do rm -f "$CW/build-ios/scripts-filtered/$rel"; done
  python3 "$CW/tools/compose-redscripts.py" "$CW/build-ios/Scripts" --scripts "$CW/build-ios/scripts-filtered" --version "$CODEWARE_VERSION"
fi

for f in "$R4E/build-ios/libs/RED4ext.dylib" "$TXL/build-ios/TweakXL.dylib" "$AXL/build-ios/ArchiveXL.dylib" "$CW/build-ios/Codeware.dylib" \
         "$R4E/deps/red4ext.sdk/cyberpunk2077_addresses.json" "$TXL/data/ExtraFlats.dat" "$TXL/data/InheritanceMap.dat" "$CW/data/KnownHashes.txt"; do
  [ -f "$f" ] || { echo "missing: $f"; exit 1; }
done

echo "==> shim/BakedSites.inc"
GAME_APP="$GAME_APP" python3 "$HERE/tools/baked_sites.py" > "$HERE/shim/BakedSites.inc.tmp"
mv "$HERE/shim/BakedSites.inc.tmp" "$HERE/shim/BakedSites.inc"

if [ "${SKIP_APP:-0}" != "1" ]; then
  echo "==> app (build.sh, log: $BUILD_LOG)"
  if ! ( cd "$HERE" && env -u DEVICE SSL_CERT_FILE="${SSL_CERT_FILE:-/etc/ssl/cert.pem}" REBUILD_SHIM=1 NO_DATA_MANIFEST=1 \
         RED4EXT_DYLIB="$R4E/build-ios/libs/RED4ext.dylib" GAME_APP="$GAME_APP" BUNDLE_ID="$BUNDLE_ID" PROFILE="$PROFILE" \
         SIGN_ID="$SIGN_ID" ./build.sh > "$BUILD_LOG" 2>&1 ); then
    echo "build.sh failed:"; tail -n 30 "$BUILD_LOG"; exit 1
  fi
  tail -n 3 "$BUILD_LOG"
  # the build-time ArchiveXL world widget limit patch (tools/ios_retarget.py patch_worldwidget_limit): cmp x22,#9 ; nop
  n=$(python3 -c 'import sys; d=open(sys.argv[1],"rb").read(); print(d.count(bytes.fromhex("df2600f11f2003d5")))' "$OUT/Payload/Cyberpunk2077.app/Cyberpunk2077")
  [ "$n" = "1" ] && echo "    world widget limit patch present" || echo "    WARNING: world widget limit patch not found in the app binary ($n)"
fi
[ -d "$OUT/Payload/Cyberpunk2077.app" ] || { echo "no app at $OUT/Payload/Cyberpunk2077.app"; exit 1; }

echo "==> stage $DEPLOY"
rm -rf "$OUT/deploy"
P="$DEPLOY/red4ext/plugins"
mkdir -p "$DEPLOY/red4ext/bin/x64" "$P/TweakXL/Data" "$P/ArchiveXL" "$P/Codeware/Data" "$P/Codeware/Scripts"
cp "$R4E/deps/red4ext.sdk/cyberpunk2077_addresses.json" "$DEPLOY/red4ext/bin/x64/"
cp "$TXL/build-ios/TweakXL.dylib" "$P/TweakXL/"
cp "$TXL/data/ExtraFlats.dat" "$TXL/data/InheritanceMap.dat" "$P/TweakXL/Data/"
# plugin scripts for the on-phone script compiler (the Mods screen passes every enabled plugin's Scripts folder to scc)
mkdir -p "$P/TweakXL/Scripts" "$P/ArchiveXL/Scripts"
cp "$TXL/scripts/"*.reds "$P/TweakXL/Scripts/"
cp "$AXL/scripts/"*.reds "$P/ArchiveXL/Scripts/"
cp "$AXL/build-ios/ArchiveXL.dylib" "$P/ArchiveXL/"
# ArchiveXL's Bundle (ArchiveXL.archive + .xl files; the 1.28.8 release bundle works with the 1.27.4 port)
AXL_BUNDLE="${AXL_BUNDLE:-$PLUGINS_ROOT/archive-xl-bundle}"
if [ -d "$AXL_BUNDLE" ]; then mkdir -p "$P/ArchiveXL/Bundle"; find "$AXL_BUNDLE" -maxdepth 1 -type f ! -name '._*' -exec cp {} "$P/ArchiveXL/Bundle/" \; ; fi
cp "$CW/build-ios/Codeware.dylib" "$P/Codeware/"
cp "$CW/data/KnownHashes.txt" "$P/Codeware/Data/"
cp "$CW/build-ios/Scripts/"*.reds "$P/Codeware/Scripts/"
for f in "$P/TweakXL/TweakXL.dylib" "$P/ArchiveXL/ArchiveXL.dylib" "$P/Codeware/Codeware.dylib"; do
  codesign -f -s "${SIGN_ID:--}" "$f"
done
(cd "$DEPLOY" && find . -type f | sort | sed 's#^\./#    #')

if [ "$INSTALL" = "1" ]; then
  [ -n "$CYPORT_DEVICE" ] || { echo "--install needs CYPORT_DEVICE (xcrun devicectl list devices)"; exit 2; }
  echo "==> install on $CYPORT_DEVICE"
  xcrun devicectl device install app --device "$CYPORT_DEVICE" "$OUT/Payload/Cyberpunk2077.app"
  (cd "$DEPLOY" && find . -type f | sed 's#^\./##' | sort) | while IFS= read -r rel; do
    echo "    -> Documents/Cyberpunk 2077/$rel"
    xcrun devicectl device copy to --device "$CYPORT_DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
      --source "$DEPLOY/$rel" --destination "Documents/Cyberpunk 2077/$rel"
  done
fi
echo "==> done: app $OUT/Payload/Cyberpunk2077.app, files $DEPLOY"
