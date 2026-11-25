#!/bin/bash
# Assembles the mod support pack that build.sh bundles with MODS=<folder>: the plugin dylibs (signed with the app by
# Xcode / build.sh / any sideloader) and ModSupport/ (manifest, licences, and the plugins' data that the shim copies
# into the game folder at start). Plugins must be built first (tools/build-all.sh, or each fork's own iOS script).
#
#   tools/make-mod-pack.sh [out folder]          default: build/modpack
# Env: PLUGINS_ROOT (the plugin checkouts, default ../CyPort-red4ext), CODEWARE_VERSION (1.21.4),
#      AXL_BUNDLE (ArchiveXL's Bundle folder from its 1.28.8 release, default $PLUGINS_ROOT/archive-xl-bundle)
# Audioware is never packed: it has no licence upstream.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
P="${PLUGINS_ROOT:-$(dirname "$HERE")/CyPort-red4ext}"
OUT="${1:-$HERE/build/modpack}"
CODEWARE_VERSION="${CODEWARE_VERSION:-1.21.4}"
AXL_BUNDLE="${AXL_BUNDLE:-$P/archive-xl-bundle}"
GAME_UUID="7D7382D0-EADD-36F0-BA1C-CEBEC1D5BEBC"     # Steam Mac 2.5.0: the build the baked sites are for

rm -rf "$OUT"; mkdir -p "$OUT/Frameworks" "$OUT/ModSupport/licenses"
G="$OUT/ModSupport/game"; PL="$G/red4ext/plugins"
need() { [ -e "$1" ] || { echo "missing: $1 (build the plugins first)"; exit 1; }; }
PLUGINS_JSON=""
# plugin <name (folder in red4ext/plugins)> <dylib> <repo> <dylib path>
plugin() {
  need "$4"; cp "$4" "$OUT/Frameworks/$2"; mkdir -p "$PL/$1"
  local commit; commit=$(git -C "$3" rev-parse HEAD); local url; url=$(git -C "$3" remote get-url origin)
  PLUGINS_JSON+="${PLUGINS_JSON:+,}{\"name\":\"$1\",\"dylib\":\"$2\",\"source\":\"$url\",\"commit\":\"$commit\"}"
}
lic() { need "$2"; cp "$2" "$OUT/ModSupport/licenses/$1"; }

# RED4ext (the loader itself: Frameworks/RED4ext.dylib, loaded by the shim; no plugin folder)
need "$P/RED4ext-macos/build-ios/libs/RED4ext.dylib"; cp "$P/RED4ext-macos/build-ios/libs/RED4ext.dylib" "$OUT/Frameworks/"
mkdir -p "$G/red4ext/bin/x64"; cp "$P/RED4ext-macos/deps/red4ext.sdk/cyberpunk2077_addresses.json" "$G/red4ext/bin/x64/"
R4E_COMMIT=$(git -C "$P/RED4ext-macos" rev-parse HEAD); lic RED4ext.txt "$P/RED4ext-macos/LICENSE.md"

plugin TweakXL TweakXL.dylib "$P/tweak-xl" "$P/tweak-xl/build-ios/TweakXL.dylib"
mkdir -p "$PL/TweakXL/Data" "$PL/TweakXL/Scripts"
cp "$P/tweak-xl/data/ExtraFlats.dat" "$P/tweak-xl/data/InheritanceMap.dat" "$PL/TweakXL/Data/"; cp "$P/tweak-xl/scripts/"*.reds "$PL/TweakXL/Scripts/"
lic TweakXL.txt "$P/tweak-xl/LICENSE"

plugin ArchiveXL ArchiveXL.dylib "$P/archive-xl" "$P/archive-xl/build-ios/ArchiveXL.dylib"
mkdir -p "$PL/ArchiveXL/Scripts" "$PL/ArchiveXL/Bundle"; cp "$P/archive-xl/scripts/"*.reds "$PL/ArchiveXL/Scripts/"
need "$AXL_BUNDLE/ArchiveXL.archive"; find "$AXL_BUNDLE" -maxdepth 1 -type f ! -name '._*' -exec cp {} "$PL/ArchiveXL/Bundle/" \;
lic ArchiveXL.txt "$P/archive-xl/LICENSE"
[ -f "$P/archive-xl/THIRD_PARTY_LICENSES" ] && lic ArchiveXL-third-party.txt "$P/archive-xl/THIRD_PARTY_LICENSES"

CW="$P/codeware"
plugin Codeware Codeware.dylib "$CW" "$CW/build-ios/Codeware.dylib"
rm -rf "$CW/build-ios/scripts-filtered" "$CW/build-ios/Scripts"; cp -R "$CW/scripts" "$CW/build-ios/scripts-filtered"
sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$CW/tools/build-cache.exclude" | grep '^Codeware-src/' | sed 's#^Codeware-src/##' |
  while IFS= read -r rel; do rm -f "$CW/build-ios/scripts-filtered/$rel"; done
python3 "$CW/tools/compose-redscripts.py" "$CW/build-ios/Scripts" --scripts "$CW/build-ios/scripts-filtered" --version "$CODEWARE_VERSION" >/dev/null
mkdir -p "$PL/Codeware/Data" "$PL/Codeware/Scripts"; cp "$CW/data/KnownHashes.txt" "$PL/Codeware/Data/"; cp "$CW/build-ios/Scripts/"*.reds "$PL/Codeware/Scripts/"
lic Codeware.txt "$CW/LICENSE"

# Cyber Engine Tweaks (GPL-3.0 upstream): dylib + its data folder (fonts, scripts); CyPort's own test mods are left out
CD="$P/cet/deploy-overlay/Cyberpunk 2077"
plugin cyber_engine_tweaks cyber_engine_tweaks.dylib "$P/cet" "$CD/red4ext/plugins/cyber_engine_tweaks/cyber_engine_tweaks.dylib"
mkdir -p "$G/bin/x64/plugins/cyber_engine_tweaks"
(cd "$CD/bin/x64/plugins/cyber_engine_tweaks" && find . -type f ! -path './mods/*' | while IFS= read -r f; do mkdir -p "$G/bin/x64/plugins/cyber_engine_tweaks/$(dirname "$f")"; cp "$f" "$G/bin/x64/plugins/cyber_engine_tweaks/$f"; done)
lic CyberEngineTweaks.txt "$P/cet/LICENSE"
curl -fsSL https://raw.githubusercontent.com/maximegmd/CyberEngineTweaks/master/LICENSE -o "$OUT/ModSupport/licenses/CyberEngineTweaks-upstream-GPL-3.0.txt"

for x in mod-settings:mod_settings input-loader:input_loader red-filesystem:RedFileSystem red-data:RedData red-httpclient:RedHttpClient; do
  repo=${x%%:*} name=${x##*:}; D="$P/$repo/deploy/Cyberpunk 2077"
  plugin "$name" "$name.dylib" "$P/$repo" "$D/red4ext/plugins/$name/$name.dylib"
  (cd "$D" && find . -type f ! -name '*.dylib' | while IFS= read -r f; do mkdir -p "$G/$(dirname "$f")"; cp "$f" "$G/$f"; done)
  for l in "$P/$repo"/LICENSE* "$P/$repo"/license*; do [ -f "$l" ] && { lic "$name.txt" "$l"; break; }; done
done
[ -f "$P/redscript/LICENSE" ] && lic redscript.txt "$P/redscript/LICENSE"

for f in "$OUT/Frameworks/"*.dylib; do codesign -f -s - "$f" 2>/dev/null; done   # replaced when the app is signed
VER="$(date +%Y%m%d%H%M)"
cat > "$OUT/ModSupport/manifest.json" <<JSON
{"pack":"$VER","gameUUID":"$GAME_UUID","red4ext":{"dylib":"RED4ext.dylib","commit":"$R4E_COMMIT"},"plugins":[$PLUGINS_JSON]}
JSON
python3 -m json.tool "$OUT/ModSupport/manifest.json" >/dev/null
echo "pack $VER: $(ls "$OUT/Frameworks" | wc -l | tr -d ' ') dylibs, $(find "$G" -type f | wc -l | tr -d ' ') data files, $(du -sh "$OUT" | cut -f1) -> $OUT"
