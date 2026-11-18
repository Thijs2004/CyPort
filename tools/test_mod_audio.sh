#!/bin/bash
# Checks on the Mac that the mod manager's PC-audio conversion (shim/ModManagerAudio.swift) writes the same bytes as the
# Mac converter it was ported from (convert.py + rdar.py), and that import / "Convert audio for the Mac game" use it.
# Builds the mod manager's logic (no UI) as a command-line tool: tools/test_mod_audio/main.swift. Exit 1 on any difference.
#   AUDIO_MAC   folder with convert.py, rdar.py and converted/ (the reference outputs)   [../CyPort-red4ext/audio-mac]
#   MODS        folder with the two test mods from Nexus (required)
#   MAC_HASHES  sorted u64 list of the Mac game's resources                              [$MODS/.cyport-mac-hashes.bin]
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"; T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
[ -f "$HERE/tools/local.env" ] && . "$HERE/tools/local.env"
AUDIO_MAC="${AUDIO_MAC:-$(dirname "$HERE")/CyPort-red4ext/audio-mac}"
MODS="${MODS:?set MODS to the folder with the two test mods}"
export MAC_HASHES="${MAC_HASHES:-$MODS/.cyport-mac-hashes.bin}" MAC_MEDIA="$HERE/shim/CyPortMacMedia.txt"
FAIL=0
same() { if cmp -s "$1" "$2"; then echo "  SAME   $3"; else echo "  DIFFER $3"; cmp "$1" "$2" | head -1 || true; FAIL=1; fi; }

echo "==> build"
clang -c -O1 -I"$HERE/shim" "$HERE/shim/ModManagerCore.c" -o "$T/core.o"
xcrun swiftc -O -module-name ModAudioTest "$HERE/shim/ModManager.swift" "$HERE/shim/ModManagerMore.swift" "$HERE/shim/ModManagerAudio.swift" \
  "$HERE/tools/test_mod_audio/main.swift" "$T/core.o" -larchive -o "$T/modaudio" 2>"$T/swift.log" || { cat "$T/swift.log"; exit 1; }
RUN="$T/modaudio"
cmp -s "$MAC_MEDIA" "$AUDIO_MAC/mac-media-ids.txt" && echo "  media id list = convert.py's" || { echo "  media id list differs from $AUDIO_MAC/mac-media-ids.txt"; FAIL=1; }

echo "==> 1. made-up archives: every case of convert.py (rename + re-sort, kept, foreign .bnk, unknown, both paths of one id)"
python3 -I - "$AUDIO_MAC" "$T" <<'PY'
import array, os, struct, sys
sys.path.insert(0, sys.argv[1]); out = sys.argv[2]
from rdar import fnv1a64, crc64_xz
mac = array.array("Q"); mac.frombytes(open(os.environ["MAC_HASHES"], "rb").read())
ids = [int(l) for l in open(os.environ["MAC_MEDIA"]) if l.strip() and not l.startswith("#")]
pc = lambda i: fnv1a64("base\\sound\\soundbanks\\%d.wem" % i); mc = lambda i: fnv1a64("base\\sound\\soundbanks\\media\\%d.wem" % i)
wem = b"RIFF" + struct.pack("<I", 36) + b"WAVEfmt " + struct.pack("<IHHI", 16, 0xFFFF, 2, 44100) + b"\0" * 64
bnk = lambda v: b"BKHD" + struct.pack("<II", 24, v) + b"\0" * 40
def build(name, items, junk=0):
    """items: (hash, data, zsize or None). Entries are written sorted by hash, like a real archive."""
    items = sorted(items, key=lambda x: x[0]); blob = bytearray(40); ents = b""; segs = b""
    for k, (h, data, z) in enumerate(items):
        segs += struct.pack("<QII", len(blob), len(data) if z is None else z, len(data)); blob += data
        ents += struct.pack("<QQIIIII20s", h, 0x1d0000000 + k, 0, k, k + 1, 0, 0, bytes([k & 255]) * 20)
    deps = struct.pack("<2Q", 0x1111, 0x2222)
    body = struct.pack("<III", len(items), len(items), 2) + ents + segs + deps
    idx = struct.pack("<IIQ", 8, len(body) + 8, crc64_xz(body)) + body + b"\xee" * junk
    while len(blob) % 4096: blob += b"\0"
    ipos = len(blob); blob += idx
    while len(blob) % 4096: blob += b"\0"
    struct.pack_into("<4sIQIQIQ", blob, 0, b"RDAR", 12, ipos, len(idx), 0, 0, len(blob))
    open(os.path.join(out, name), "wb").write(blob)
some = ids[:40] + ids[-40:]
build("many.archive", [(pc(i), wem, None) for i in some])                                        # every entry moves, the order changes
build("mixed.archive", [(pc(i), wem, None) for i in ids[100:130]] + [(mac[k], b"CR2W" + b"\0" * 60, None) for k in range(5, 5000, 199)]
      + [(mac[7], bnk(134), None), (mac[9], bnk(150), None), (mac[11], bnk(135), 20), (mac[13], b"KARK" + bnk(134), None)]
      + [(0x0123456789abcdef, b"x" * 32, None), (0xfedcba9876543210, wem, None)], junk=24)
build("twin.archive", [(pc(ids[5]), wem, None), (mc(ids[5]), wem + b"!", None), (pc(ids[6]), wem, None)])   # PC and Mac path of one id
build("bankonly.archive", [(mac[7], bnk(134), None)])
PY
for a in many mixed twin; do
  for flags in "" "--keep-bnk"; do
    rm -rf "$T/ref"; python3 -I "$AUDIO_MAC/convert.py" "$T/$a.archive" -o "$T/ref" --hashes "$MAC_HASHES" $flags >"$T/ref.log"
    cp "$T/$a.archive" "$T/mine.archive"; S="$("$RUN" convert "$T/mine.archive" --drop-unknown $flags | head -1)"
    same "$T/mine.archive" "$T/ref/archive/Mac/mod/$a.archive" "$a.archive ${flags:-(default)}: $S  | convert.py: $(tail -2 "$T/ref.log" | head -1 | sed 's/.*(\(.*\))/\1/')"
  done
done
python3 -I "$AUDIO_MAC/convert.py" "$T/bankonly.archive" -o "$T/ref2" --hashes "$MAC_HASHES" >/dev/null && { echo "  convert.py wrote bankonly?"; FAIL=1; } || true
cp "$T/bankonly.archive" "$T/mine.archive"; "$RUN" convert "$T/mine.archive" | head -1 | grep -q "false$" && same "$T/mine.archive" "$T/bankonly.archive" "bankonly.archive: nothing left, file not touched (convert.py writes none)"
cp "$T/mixed.archive" "$T/mine.archive"; echo "  mixed.archive the way the app converts it (unknown resources stay): $("$RUN" convert "$T/mine.archive" | head -1)"

echo "==> 2. Import mod… of the two Nexus mods into an empty game folder, against convert.py's files"
n=0
for pair in "No Menu Music-2345-1-0-1618610260.zip|NoMenuMusic|basegame_Menu_NoMusic.archive" "Cyb77 Dark Sytnh Main Menu theme-12329-1-0-1705266419.zip|DarkSynthMenu|menuReplacerDarkSynth.archive"; do
  IFS='|' read -r zip dir arc <<<"$pair"; n=$((n + 1)); G="$T/g$n/Cyberpunk 2077"; mkdir -p "$G/archive/Mac/mod"
  [ -f "$MODS/$zip" ] || { echo "  missing $MODS/$zip"; FAIL=1; continue; }
  "$RUN" import "$MODS/$zip" "$G" 2>/dev/null | sed 's/^/    /'
  same "$G/archive/Mac/mod/$arc" "$AUDIO_MAC/converted/$dir/archive/Mac/mod/$arc" "$arc = converted/$dir (import)"
  rm -rf "$T/ref"; python3 -I "$AUDIO_MAC/convert.py" "$MODS/$zip" -o "$T/ref" --hashes "$MAC_HASHES" >/dev/null
  same "$G/archive/Mac/mod/$arc" "$T/ref/archive/Mac/mod/$arc" "$arc = convert.py run now"
  # 3. the PC archive copied in by hand, then "Convert audio for the Mac game"
  G="$T/h$n/Cyberpunk 2077"; mkdir -p "$G/archive/Mac/mod"; unzip -qjo "$MODS/$zip" "*.archive" -d "$G/archive/Mac/mod"
  "$RUN" installed "$G" 2>/dev/null | sed 's/^/    /'
  same "$G/archive/Mac/mod/$arc" "$AUDIO_MAC/converted/$dir/archive/Mac/mod/$arc" "$arc = converted/$dir (installed by hand, then converted)"
  [ -z "$(ls "$G/archive/Mac/mod" | grep -v "^$arc$")" ] || { echo "  left-over files in archive/Mac/mod"; FAIL=1; }
done
[ $FAIL = 0 ] && echo "ALL SAME" || { echo "FAILED"; exit 1; }
