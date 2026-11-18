#!/usr/bin/env python3
"""Baked hook sites: game functions whose entry is rewritten at build time so they can be hooked on iOS.

One table feeds both halves:
  tools/ios_retarget.py (patch_baked_hooks)  rewrites each entry to  adrp x16,slot ; ldr x16,[x16,#off] ; br x16
  shim/BakedSites.inc (generated here)        the slot order, names, and a pass-through trampoline per site that
                                              replays the three displaced instructions and continues at entry+12.
Displaced instructions that are PC-relative (b.cond, cbz/cbnz, tbz/tbnz, b, bl, adr, adrp, ldr literal) are rewritten
in the trampoline to reach the same absolute target through g_bhAux (filled with the slid address at start).

Regenerate the include after editing SITES:   python3 tools/baked_sites.py > shim/BakedSites.inc
Addresses are for Cyberpunk 2077 2.5.0 (Steam Mac, UUID 7D7382D0-EADD-36F0-BA1C-CEBEC1D5BEBC); each site is checked
against the expected words at build time, so another game build is left untouched (and the shim then skips it).
"""
import os, re, sys

SITES = [   # identifier, entry, first three instruction words, description
    ("LOADSCRIPTS",   0x104D7ABBC, (0xd10303ff, 0xa90767fa, 0xa9085ff8), "scripts blob (LoadScripts?)"),
    ("ADDSTATE",      0x104D6A27C, (0xd10143ff, 0xa9034ff4, 0xa9047bfd), "CGameApplication::AddState"),
    ("WINMAIN",       0x104E3274C, (0xd10303ff, 0xa9085ff8, 0xa90957f6), "Main (engine init, RED4ext WinMain)"),
    ("VALIDATE",      0x1011A7E28, (0xd10243ff, 0xa90467fa, 0xa9055ff8), "ScriptValidator::Validate"),
    # TweakXL (cp2077-tweak-xl mac-v1-2.5, lib/Support/macOS/TweakXLAddressResolver.cpp)
    ("TXL_TRYLOAD",   0x1037D60CC, None, "TweakDB::TryLoad"),
    ("TXL_INIT",      0x101EF64C8, None, "TweakDB init job"),
    ("TXL_STATS",     0x1023B2F68, None, "StatsDataSystem::InitializeRecords"),
    ("TXL_CHECKFLAG", 0x1023B3438, None, "StatsDataSystem::CheckStatFlag"),
    ("TXL_GETFLAGS",  0x1023B34B4, None, "StatsDataSystem::GetStatFlags"),
    ("TXL_STATRANGE", 0x1023B3CB0, None, "StatsDataSystem::GetStatRange"),
]
SLOTS_FROM_END = 0x1000          # slots at __DATA end - 0x1000 + 8*i (the free hook uses end - 0x100)
MAX_SITES = (SLOTS_FROM_END - 0x100) // 8

# the Steam Mac 2.5.0 game executable: GAME_APP=<Cyberpunk2077.app> (tools/build-all.sh passes it) or CYPORT_GAME_EXE=<executable>
GAME = os.environ.get("CYPORT_GAME_EXE") or (os.path.join(os.environ["GAME_APP"], "Contents/MacOS/Cyberpunk2077")
                                             if os.environ.get("GAME_APP") else None)


GAME_UUID = bytes.fromhex("7D7382D0EADD36F0BA1CCEBEC1D5BEBC")   # Steam Mac 2.5.0: the only build these addresses are for
SITE_FILES = "sites"   # tools/sites/*.txt: one "0x<image offset>  # Name" per line (plugin hook lists, e.g. ArchiveXL's)


def _macho(d):
    import struct
    ncmds = struct.unpack_from("<I", d, 16)[0]; off = 32; uuid = fstarts = None
    for _ in range(ncmds):
        cmd, sz = struct.unpack_from("<II", d, off)
        if cmd == 0x1b: uuid = d[off + 8:off + 24]
        if cmd == 0x26: fstarts = struct.unpack_from("<II", d, off + 8)
        off += sz
    starts = []; p, end = fstarts; end += p; a = 0x100000000
    while p < end:
        v = sh = 0
        while True:
            x = d[p]; p += 1; v |= (x & 0x7f) << sh; sh += 7
            if not x & 0x80: break
        if v == 0: break
        a += v; starts.append(a)
    return uuid, starts


def _branch_target(w, pc):
    if (w & 0x7c000000) == 0x14000000: return pc + 4 * sx(w & 0x3ffffff, 26)
    if (w & 0xff000010) == 0x54000000 or (w & 0x7e000000) == 0x34000000: return pc + 4 * sx((w >> 5) & 0x7ffff, 19)
    if (w & 0x7e000000) == 0x36000000: return pc + 4 * sx((w >> 5) & 0x3fff, 14)
    return None


def all_sites():
    """SITES plus every tools/sites/*.txt entry not already listed (identifier from the file and the name)."""
    import glob, os
    out = list(SITES); seen = {e for _, e, _, _ in SITES}
    for f in sorted(glob.glob(os.path.join(os.path.dirname(os.path.abspath(__file__)), SITE_FILES, "*.txt"))):
        tag = re.sub(r"\W+", "_", os.path.splitext(os.path.basename(f))[0]).upper()
        for line in open(f):
            m = re.match(r"\s*(0x[0-9a-fA-F]+)\s*(?:#\s*(.*))?", line)
            if not m: continue
            entry = int(m.group(1), 16) + 0x100000000; name = (m.group(2) or "").strip()
            if entry in seen: continue
            seen.add(entry)
            ident = "%s_%s" % (tag, re.sub(r"\W+", "_", name.split()[0] if name else "%x" % entry).upper())
            out.append((ident, entry, None, name or hex(entry)))
    return out


def fill_words(binary=GAME):
    """Every site with its three entry words read from the 2.5.0 binary, after the checks that make a baked hook safe:
    the binary is 2.5.0, the entry is a function start, the function is at least 12 bytes, and nothing in the
    surrounding 256 KiB branches to entry+4 or entry+8. A site failing a check is left out (both halves agree)."""
    import bisect, struct
    if not binary: raise SystemExit("baked hooks: set GAME_APP=<Cyberpunk2077.app> (or CYPORT_GAME_EXE=<executable>)")
    d = open(binary, "rb").read()
    uuid, starts = _macho(d)
    if uuid != GAME_UUID: raise SystemExit("baked hooks: not the Steam Mac 2.5.0 game binary (UUID %s)" % (uuid.hex() if uuid else "?"))
    out = []; idents = set()
    for ident, entry, words, desc in all_sites():
        fo = entry - 0x100000000; cur = struct.unpack_from("<3I", d, fo)
        if words is not None and tuple(words) != cur: sys.stderr.write("baked site %s: unexpected code, left out\n" % ident); continue
        i = bisect.bisect_left(starts, entry)
        if i == len(starts) or starts[i] != entry or (i + 1 < len(starts) and starts[i + 1] - entry < 12):
            sys.stderr.write("baked site %s: not a function start of 12+ bytes, left out\n" % ident); continue
        lo = max(0, fo - 0x20000); hi = min(len(d) - 4, fo + 0x20000)
        if any(_branch_target(struct.unpack_from("<I", d, o)[0], o + 0x100000000) in (entry + 4, entry + 8) for o in range(lo, hi, 4)):
            sys.stderr.write("baked site %s: something branches into its first 12 bytes, left out\n" % ident); continue
        while ident in idents: ident += "_"
        idents.add(ident); out.append((ident, entry, cur, desc))
    return out


CONDS = ["eq", "ne", "hs", "lo", "mi", "pl", "vs", "vc", "hi", "ls", "ge", "lt", "gt", "le"]


def sx(v, bits): return v - (1 << bits) if v & (1 << (bits - 1)) else v


def relocate(w, pc, aux):
    """Assembly lines that do what instruction w does at address pc, from anywhere. aux(target) -> aux index."""
    load = lambda reg, k: ["adrp %s, _g_bhAux@PAGE" % reg, "add %s, %s, _g_bhAux@PAGEOFF" % (reg, reg), "ldr %s, [%s, #%d]" % (reg, reg, 8 * k)]
    if (w & 0xff000010) == 0x54000000:                                   # b.cond
        tgt = pc + 4 * sx((w >> 5) & 0x7ffff, 19); c = w & 0xf
        if c >= 14: return load("x16", aux(tgt)) + ["br x16"]
        return ["b.%s 1f" % CONDS[c ^ 1]] + load("x16", aux(tgt)) + ["br x16", "1:"]
    if (w & 0x7e000000) == 0x34000000:                                   # cbz / cbnz
        tgt = pc + 4 * sx((w >> 5) & 0x7ffff, 19); r = ("x%d" if w >> 31 else "w%d") % (w & 31)
        return ["%s %s, 1f" % ("cbz" if w & (1 << 24) else "cbnz", r)] + load("x16", aux(tgt)) + ["br x16", "1:"]
    if (w & 0x7e000000) == 0x36000000:                                   # tbz / tbnz
        tgt = pc + 4 * sx((w >> 5) & 0x3fff, 14); bit = ((w >> 31) << 5) | ((w >> 19) & 31)
        r = ("x%d" if bit >= 32 else "w%d") % (w & 31)
        return ["%s %s, #%d, 1f" % ("tbz" if w & (1 << 24) else "tbnz", r, bit)] + load("x16", aux(tgt)) + ["br x16", "1:"]
    if (w & 0x7c000000) == 0x14000000:                                   # b / bl
        tgt = pc + 4 * sx(w & 0x3ffffff, 26)
        return load("x16", aux(tgt)) + ["blr x16" if w & 0x80000000 else "br x16"]
    if (w & 0x1f000000) == 0x10000000:                                   # adr / adrp
        imm = sx(((w >> 5) & 0x7ffff) << 2 | ((w >> 29) & 3), 21); rd = w & 31
        tgt = ((pc & ~0xfff) + (imm << 12)) if w >> 31 else pc + imm
        if rd in (16, 17): raise SystemExit("adr/adrp into x16/x17 at %#x not supported" % pc)
        return load("x%d" % rd, aux(tgt))
    if (w & 0x3b000000) == 0x18000000:                                   # ldr literal
        raise SystemExit("ldr literal in a displaced instruction at %#x: not supported yet" % pc)
    return [".long %#010x" % w]


def generate():
    sites = fill_words()
    if len(sites) > MAX_SITES: raise SystemExit("too many sites")
    auxv = []
    def aux(t):
        if t not in auxv: auxv.append(t)
        return auxv.index(t)
    asm = []
    for i, (ident, entry, words, desc) in enumerate(sites):
        lines = []
        for k, w in enumerate(words): lines += relocate(w, entry + 4 * k, aux)
        lines += ["adrp x16, _g_bhCont@PAGE", "add x16, x16, _g_bhCont@PAGEOFF", "ldr x16, [x16, #%d]" % (8 * i), "br x16"]
        asm.append((i, ident, desc, lines))
    o = ["/* generated by tools/baked_sites.py - do not edit */",
         "enum { %s, MS_BH_COUNT };" % ", ".join("MS_BH_%s" % s[0] for s in sites),
         "#define MS_BH_SLOTS_FROM_END %#x" % SLOTS_FROM_END,
         "#define MS_BH_AUX_COUNT %d" % max(1, len(auxv)),
         "static const struct { const char *name; uint64_t entry; } kMSBakedHooks[MS_BH_COUNT] = {"]
    cstr = lambda t: " ".join(t.split()).replace("\\", "\\\\").replace('"', '\\"')   # one line, C-escaped
    o += ['    { "%s", %#x },' % (cstr(s[3]), s[1]) for s in sites]
    o += ["};",
          "__attribute__((used, visibility(\"hidden\"))) uintptr_t g_bhCont[MS_BH_COUNT];   /* entry + 12, slid */",
          "__attribute__((used, visibility(\"hidden\"))) uintptr_t g_bhAux[MS_BH_AUX_COUNT];   /* slid targets, set by MSInstallBakedHooks */",
          "static const uint64_t kMSBakedAuxUnslid[MS_BH_AUX_COUNT] = { %s };" % (", ".join("%#x" % t for t in auxv) or "0")]
    o += ["void ms_bh_orig_%d(void);" % i for i in range(len(sites))]
    o.append('__asm__(".text\\n"')
    for i, ident, desc, lines in asm:
        o.append('    ".p2align 2\\n.private_extern _ms_bh_orig_%d\\n.globl _ms_bh_orig_%d\\n_ms_bh_orig_%d:   ; %s\\n"' % (i, i, i, ident))
        o += ['    "  %s\\n"' % l for l in lines]
    o.append(");")
    o.append("static const void *const kMSBakedOrig[MS_BH_COUNT] = { %s };" % ", ".join("(const void *)ms_bh_orig_%d" % i for i in range(len(sites))))
    return "\n".join(o) + "\n"


if __name__ == "__main__":
    sys.stdout.write(generate())
