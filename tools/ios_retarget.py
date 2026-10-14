#!/usr/bin/env python3
"""
ios_retarget.py - retarget a thin arm64 macOS Mach-O (executable or dylib) so the
iOS dyld will accept it. Header edits, plus (main executable only) two instructions in the engine's
address-space reserve functions - see patch_pool_end().

  1. LC_BUILD_VERSION platform macOS(1) -> iOS(2), sets minos / sdk
  2. rewrites LC_LOAD_DYLIB / WEAK / REEXPORT paths:
       - macOS-only frameworks (AppKit, Cocoa, IOKit, CoreGraphics, ...) -> MacShim
       - /System/Library/Frameworks/X.framework/Versions/A/X -> .../X.framework/X (iOS flat layout)
       - @executable_path/../Frameworks/...  -> @rpath/...
  3. rewrites LC_RPATH the same way
  4. leaves LC_CODE_SIGNATURE untouched (the old signature is simply invalid now;
     re-sign the result yourself with `codesign -f -s <identity>`)

Usage:  ios_retarget.py IN OUT [--minos 18.0] [--sdk 18.0]
        ios_retarget.py --info FILE
"""
import os, re, struct, sys, argparse

LC_SEGMENT_64, LC_LOAD_DYLIB, LC_ID_DYLIB = 0x19, 0x0c, 0x0d
LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LOAD_UPWARD = 0x80000018, 0x8000001f, 0x80000023
LC_RPATH, LC_CODE_SIGNATURE, LC_BUILD_VERSION, LC_VERSION_MIN_MACOSX = 0x8000001c, 0x1d, 0x32, 0x24
LC_DYLD_CHAINED_FIXUPS = 0x80000034
# libSystem calls the game makes (Mach-O names: C name + leading underscore) that must see iPad-appropriate answers; the shim exports replacements with the same names
# _mmap/_munmap/_madvise/_mprotect: the engine reserves ~118 GB of address space at startup; an iPhone gets ~65 GB even with
# extended-virtual-addressing, so the shim shrinks the big reservations (see "address-space budget" in MacShim.m)
REROUTE = {"__NSGetExecutablePath", "_sysctlbyname", "_mmap", "_munmap", "_madvise", "_mprotect",
           # case-insensitive retry for game paths (the Mac build assumes a case-insensitive file system)
           "_opendir", "_realpath$DARWIN_EXTSN", "_stat", "_access", "_fopen", "_open",
           # retry + log failed or short reads (game data on an external SSD; the engine treats a short read as fatal)
           "_read", "_close", "_lseek",
           # audio graph: logged by the shim (render sizes) and switchable off (NoAudio) while hunting a memory corruption
           "_AUGraphStart", "_AUGraphSetNodeInputCallback",
           # CPU count (CPUCount setting): the engine has only ever run on Macs with 8+ cores
           "_sysconf", "_sysctl",
           # online services (GOG Galaxy): the game dlopens libGameServices*.dylib; see MSNoGameServices in the shim
           "_dlopen",
           # Bink video (main-menu background): logged, NoVideo switch
           "_BinkOpenWithOptions", "_BinkStartAsyncThread", "_BinkDoFrameAsyncMulti", "_BinkDoFrameAsyncWait",
           "_BinkRegisterFrameBuffers", "_BinkGetFrameBuffersInfo",
           # thread priorities: Mac values park engine threads on the iPhone's efficiency cores (ThreadQoS switch)
           "_pthread_set_qos_class_self_np",
           # spinlock waits: back-to-back yields become short sleeps (less heat/throttling; YieldBackoff switch)
           "_sched_yield"}
DYLIB_CMDS = (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_LOAD_UPWARD)
PLATFORM_MACOS, PLATFORM_IOS = 1, 2

SHIM = "@rpath/libMacShim.dylib"
# Frameworks whose macOS API surface is missing on iOS: send them to the shim.
# The shim re-exports Foundation / CoreGraphics / Security, so anything iOS does have still resolves.
SHIM_FRAMEWORKS = {"AppKit", "Cocoa", "IOKit", "Carbon", "AudioUnit", "CoreAudio",
                   "CoreGraphics", "Security", "Metal"}
SHIM_DYLIBS = {"/usr/lib/libcurl.4.dylib"}   # not shipped on iOS: shim provides an offline stub

FW_RE = re.compile(r"^/System/Library/Frameworks/(\w+)\.framework/Versions/[A-Z]/\1$")

def ver(s):
    p = [int(x) for x in s.split(".")] + [0, 0]
    return (p[0] << 16) | (p[1] << 8) | p[2]

def map_dylib(p):
    m = FW_RE.match(p)
    if m:
        return SHIM if m.group(1) in SHIM_FRAMEWORKS else "/System/Library/Frameworks/%s.framework/%s" % (m.group(1), m.group(1))
    if p in SHIM_DYLIBS:
        return SHIM
    if p.startswith("@executable_path/../Frameworks/"):
        return "@rpath/" + p[len("@executable_path/../Frameworks/"):]
    return None

def map_rpath(p):
    if p in ("@executable_path/../Frameworks", "@loader_path/../Frameworks"):
        return "@executable_path/Frameworks"
    return None

def cstr(b): return bytes(b).split(b"\0", 1)[0].decode("utf-8", "replace")

def thin_arm64(d):
    """If d is a universal (fat) file, return its plain arm64 slice; else return d."""
    if struct.unpack_from(">I", d, 0)[0] != 0xcafebabe:
        return d
    n = struct.unpack_from(">I", d, 4)[0]
    for i in range(n):
        cpu, sub, off, size, _al = struct.unpack_from(">IIIII", d, 8 + 20 * i)
        if cpu == 0x0100000c and (sub & 0xffffff) == 0:      # arm64 (not arm64e)
            return bytearray(d[off:off + size])
    raise SystemExit("universal file has no arm64 slice")

def parse(d):
    magic, cpu, sub, ftype, ncmds, szcmds, flags, _ = struct.unpack_from("<IIIIIIII", d, 0)
    if magic != 0xfeedfacf: raise SystemExit("not a 64-bit little-endian Mach-O")
    if cpu != 0x0100000c:   raise SystemExit("not arm64 (cputype=%#x)" % cpu)
    cmds, off = [], 32
    for _ in range(ncmds):
        cmd, sz = struct.unpack_from("<II", d, off); cmds.append((cmd, off, sz)); off += sz
    return dict(ftype=ftype, sub=sub, cmds=cmds)

def name_of(d, off, sz):
    no = struct.unpack_from("<I", d, off + 8)[0]; return no, cstr(d[off + no: off + sz])

def info(path):
    d = thin_arm64(open(path, "rb").read()); m = parse(d)
    print(path, "filetype=%d cpusubtype=%#x" % (m["ftype"], m["sub"] & 0xffffff))
    kinds = {LC_LOAD_DYLIB: "load", LC_LOAD_WEAK_DYLIB: "weak", LC_REEXPORT_DYLIB: "reexport", LC_ID_DYLIB: "id", LC_LOAD_UPWARD: "upward", LC_RPATH: "rpath"}
    for cmd, off, sz in m["cmds"]:
        if cmd == LC_BUILD_VERSION:
            pl, mo, sd = struct.unpack_from("<III", d, off + 8)
            print("  build_version platform=%d minos=%d.%d sdk=%d.%d" % (pl, mo >> 16, (mo >> 8) & 255, sd >> 16, (sd >> 8) & 255))
        elif cmd in kinds:
            print("  %-9s %s" % (kinds[cmd], name_of(d, off, sz)[1]))
        elif cmd == LC_CODE_SIGNATURE:
            print("  code_signature (stale after retarget; re-sign)")

def retarget(src, dst, minos, sdk):
    d = bytearray(thin_arm64(open(src, "rb").read())); m = parse(d); log = []; seen = False
    for cmd, off, sz in m["cmds"]:
        if cmd == LC_VERSION_MIN_MACOSX:
            raise SystemExit("legacy LC_VERSION_MIN_MACOSX binary: unsupported")
        if cmd == LC_BUILD_VERSION:
            seen = True
            if struct.unpack_from("<I", d, off + 8)[0] == PLATFORM_MACOS:
                struct.pack_into("<III", d, off + 8, PLATFORM_IOS, ver(minos), ver(sdk))
                log.append("build_version: macOS -> iOS (minos %s, sdk %s)" % (minos, sdk))
        elif cmd in DYLIB_CMDS or cmd == LC_RPATH or cmd == LC_ID_DYLIB:
            no, old = name_of(d, off, sz)
            new = map_rpath(old) if cmd == LC_RPATH else map_dylib(old)
            if new and new != old:
                nb = new.encode() + b"\0"
                if no + len(nb) > sz: raise SystemExit("replacement too long: %s -> %s" % (old, new))
                d[off + no: off + sz] = nb + b"\0" * (sz - no - len(nb))
                log.append("%s -> %s" % (old, new))
    if not seen: raise SystemExit("no LC_BUILD_VERSION: not a modern macOS build")
    log += reroute_imports(d, m)
    if m["ftype"] == 2: log += patch_pool_end(d, m) + patch_watchdog(d, m) + patch_pool_sizes(d, m) + patch_free_hook(d, m)      # MH_EXECUTE
    open(dst, "wb").write(d)
    return log

def reroute_imports(d, m):
    """Chained-fixups images: make `_NSGetExecutablePath` / `_sysctlbyname` bind to the shim instead of libSystem
    (changes only the lib-ordinal byte of those two import records). Replaces fragile dyld interposing."""
    ordinal, n = None, 0
    for cmd, off, sz in m["cmds"]:
        if cmd in DYLIB_CMDS:
            n += 1
            if ordinal is None and cstr(d[off + struct.unpack_from("<I", d, off + 8)[0]: off + sz]) == SHIM: ordinal = n
    fx = [(off, sz) for cmd, off, sz in m["cmds"] if cmd == LC_DYLD_CHAINED_FIXUPS]
    if not fx or ordinal is None or ordinal > 250: return []
    dataoff, datasize = struct.unpack_from("<II", d, fx[0][0] + 8)
    ver, starts, imp_off, sym_off, count, fmt, symfmt = struct.unpack_from("<IIIIIII", d, dataoff)
    if fmt not in (1, 2, 3) or symfmt != 0: return ["chained fixups format %d not handled; not rerouted" % fmt]
    size = {1: 4, 2: 8, 3: 16}[fmt]; done = []
    for i in range(count):
        p = dataoff + imp_off + i * size
        if fmt == 3:
            v = struct.unpack_from("<Q", d, p)[0]; name_off = v >> 32; lib = v & 0xffff
        else:
            v = struct.unpack_from("<I", d, p)[0]; name_off = v >> 9; lib = v & 0xff
        s = dataoff + sym_off + name_off; name = cstr(d[s:s + 64])
        if name in REROUTE:
            if fmt == 3: struct.pack_into("<Q", d, p, (v & ~0xffff) | ordinal)
            else:        struct.pack_into("<I", d, p, (v & ~0xff) | ordinal)
            done.append(name)
    return ["rerouted to shim (ordinal %d): %s" % (ordinal, ", ".join(sorted(set(done))))] if done else []

ARM_NOP, ARM_CMN_X0_1, ARM_ADD_X1_X0_X19 = 0xd503201f, 0xb100041f, 0x8b130001

def patch_pool_end(d, m):
    """The engine reserves its memory pools with   bl mmap ; cmn x0,#1 ; b.eq fail ; add x1,x0,x19 ; ret
    i.e. pool = [base, base + requested size). iOS has far less address space than the ~130 GB it asks for, and
    a pool whose recorded end lies past its real mapping overlaps whatever gets mapped there later (GPU driver
    buffers, malloc). The `add` is replaced by a NOP so x1 (the pool end) is whatever the shim's mmap returned
    in x1: base + the size it really mapped. Applied only if exactly the two known sites match."""
    text = None
    for cmd, off, sz in m["cmds"]:
        if cmd != LC_SEGMENT_64 or cstr(d[off + 8:off + 24]) != "__TEXT": continue
        nsects = struct.unpack_from("<I", d, off + 64)[0]
        for i in range(nsects):
            so = off + 72 + 80 * i
            if cstr(d[so:so + 16]) == "__text": text = struct.unpack_from("<QQI", d, so + 32)
    if not text: return ["pool-end patch: no __text section; not applied"]
    addr, size, foff = text; sites = []; bl_targets = set()
    for i in range(foff + 4, foff + size - 8, 4):
        if struct.unpack_from("<I", d, i)[0] != ARM_CMN_X0_1: continue
        bl, beq, add = struct.unpack_from("<I", d, i - 4)[0], struct.unpack_from("<I", d, i + 4)[0], struct.unpack_from("<I", d, i + 8)[0]
        if bl >> 26 == 0b100101 and beq & 0xff00001f == 0x54000000 and add in (ARM_ADD_X1_X0_X19, ARM_NOP):
            imm = bl & 0x3ffffff; imm -= (1 << 26) if imm & (1 << 25) else 0
            bl_targets.add(addr + (i - 4 - foff) + imm * 4); sites.append(i + 8)
    if len(sites) != 2 or len(bl_targets) != 1:
        return ["pool-end patch: expected 2 sites, found %d; NOT applied (shim keeps the old address-space layout)" % len(sites)]
    for s in sites: struct.pack_into("<I", d, s, ARM_NOP)
    return ["pool-end patch: add x1,x0,x19 -> nop at " + ", ".join(hex(addr + s - foff) for s in sites)]

def patch_pool_sizes(d, m):
    """The engine's memory setup asks for three big pools with constant sizes (16, 64 and 32 GB): mov x8/x9,#size<<32
    followed by the store into the pool descriptor. iOS gives an app 64 GB of address space in total, so the shim used to
    map 8 GB and hand back the real end - but the engine still keeps the requested size, and with neighbouring pools
    inside each other's requested range it frees memory into the wrong pool (double allocations, crashes ~1 min in on
    the main menu). The constants are lowered to POOL_GB (8) so requested == mapped."""
    gb = int(os.environ.get("POOL_GB", "8"))
    new = lambda reg: 0xd2c00000 | (((gb << 30) >> 32) << 5) | reg     # movz xN, #(gb/4), lsl #32
    pats = [(0xd2c00088, 0xf90023e8, 8, "16 GB"), (0xd2c00209, 0xa90227e8, 9, "64 GB"), (0xd2c00109, 0xa900a7e8, 9, "32 GB")]
    out = []
    for mov, nxt, reg, name in pats:
        key = struct.pack("<II", mov, nxt); j = d.find(key)
        if j < 0 or d.find(key, j + 1) >= 0:
            already = struct.pack("<II", new(reg), nxt)
            out.append("pool-size patch: %s %s" % (name, "already patched" if d.find(already) >= 0 else "NOT found; not applied")); continue
        struct.pack_into("<I", d, j, new(reg)); out.append("pool-size patch: %s pool -> %d GB" % (name, gb))
    return out

def patch_watchdog(d, m):
    """The engine's WatchdogThread aborts the game (brk) when the main loop hasn't ticked for N seconds. On a phone,
    loading from an external SSD (throttled reads, waits while the drive reconnects) easily exceeds that, so the
    timeout path is skipped:   tbnz w0,#0,out ; adrp x1,"!!! EngineWatchdog timeout!" ; ...   -> the adrp becomes b out."""
    secs = {}
    for cmd, off, sz in m["cmds"]:
        if cmd != LC_SEGMENT_64: continue
        for i in range(struct.unpack_from("<I", d, off + 64)[0]):
            so = off + 72 + 80 * i
            secs[cstr(d[so:so + 16])] = struct.unpack_from("<QQI", d, so + 32)
    if "__text" not in secs or "__cstring" not in secs: return ["watchdog patch: sections missing; not applied"]
    caddr, csize, cfoff = secs["__cstring"]
    j = d.find(b"!!! EngineWatchdog timeout!\n\0", cfoff, cfoff + csize)
    if j < 0: return ["watchdog patch: message not found; NOT applied"]
    target = caddr + j - cfoff
    addr, size, foff = secs["__text"]; sites = []
    for i in range(foff + 4, foff + size - 8, 4):
        adrp = struct.unpack_from("<I", d, i)[0]
        if adrp & 0x9f00001f != 0x90000001: continue                       # adrp x1
        add = struct.unpack_from("<I", d, i + 4)[0]
        if add & 0xffc003ff != 0x91000021: continue                         # add x1,x1,#imm
        pc = addr + i - foff
        imm = ((adrp >> 29) & 3) | (((adrp >> 5) & 0x7ffff) << 2); imm -= (1 << 21) if imm & (1 << 20) else 0
        if (pc & ~0xfff) + (imm << 12) + ((add >> 10) & 0xfff) != target: continue
        tb = struct.unpack_from("<I", d, i - 4)[0]
        if tb & 0xff00001f != 0x37000000: continue                          # tbnz w0,#0,out
        o = (tb >> 5) & 0x3fff; o -= (1 << 14) if o & (1 << 13) else 0
        sites.append((i, o - 1))                                            # out, relative to the adrp
    if len(sites) != 1: return ["watchdog patch: expected 1 site, found %d; NOT applied" % len(sites)]
    i, rel = sites[0]
    struct.pack_into("<I", d, i, 0x14000000 | (rel & 0x3ffffff))
    return ["watchdog patch: engine watchdog timeout skipped at " + hex(addr + i - foff)]

FREE_ENTRY = 0x100012cac        # the engine allocator's core Free(allocator, Block&) (all PoolStorageProxy::Free go through it)
FREE_PROLOGUE = (0xa9bd57f6, 0xa9014ff4, 0xa9027bfd, 0x910083fd, 0xaa0103f3, 0xaa0003f4)   # stp;stp;stp;add x29;mov x19,x1;mov x20,x0

def patch_free_hook(d, m):
    """Use-after-free writes in the engine corrupt memory a few seconds after the main menu loads (freed blocks are
    reused and then written to through stale pointers). The shim delays frees (quarantine) so those late writes land
    in memory nobody owns yet. The core Free's first three instructions become  adrp x16,slot ; ldr x16,[x16] ; br x16
    where slot is an 8-byte pointer in the zero-filled padding at the end of __DATA (past __common); the shim stores
    its hook there at load and re-runs the three replaced stp's itself before jumping back to entry+12.
    Slot = __DATA vmaddr + vmsize - 0x100 (the shim computes the same address)."""
    segs = {}; text = None; last_end = 0
    for cmd, off, sz in m["cmds"]:
        if cmd != LC_SEGMENT_64: continue
        name = cstr(d[off + 8:off + 24]); vmaddr, vmsize = struct.unpack_from("<QQ", d, off + 24)
        segs[name] = (vmaddr, vmsize)
        for i in range(struct.unpack_from("<I", d, off + 64)[0]):
            so = off + 72 + 80 * i; sa, ss, sf = struct.unpack_from("<QQI", d, so + 32)
            if cstr(d[so:so + 16]) == "__text": text = (sa, ss, sf)
            if name == "__DATA": last_end = max(last_end, sa + ss)
    if not text or "__DATA" not in segs: return ["free hook: segments missing; NOT applied"]
    slot = segs["__DATA"][0] + segs["__DATA"][1] - 0x100
    if slot < last_end: return ["free hook: no padding after the last __DATA section; NOT applied"]
    addr, size, foff = text
    if not (addr <= FREE_ENTRY < addr + size): return ["free hook: entry outside __text; NOT applied"]
    fo = foff + FREE_ENTRY - addr
    cur = struct.unpack_from("<6I", d, fo)
    if cur[3:] != FREE_PROLOGUE[3:] or (cur[:3] != FREE_PROLOGUE[:3] and cur[0] & 0x9f00001f != 0x90000010):
        return ["free hook: unexpected code at %#x; NOT applied" % FREE_ENTRY]
    imm = ((slot & ~0xfff) - (FREE_ENTRY & ~0xfff)) >> 12
    adrp = 0x90000010 | ((imm & 3) << 29) | (((imm >> 2) & 0x7ffff) << 5)
    ldr = 0xf9400210 | (((slot & 0xfff) // 8) << 10)
    struct.pack_into("<3I", d, fo, adrp, ldr, 0xd61f0200)
    return ["free hook: engine Free %#x -> through slot %#x (shim quarantine)" % (FREE_ENTRY, slot)]

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("src", nargs="?"); ap.add_argument("dst", nargs="?")
    ap.add_argument("--info"); ap.add_argument("--minos", default="18.0"); ap.add_argument("--sdk", default="18.0")
    a = ap.parse_args()
    if a.info: info(a.info); sys.exit(0)
    if not (a.src and a.dst): ap.error("need IN OUT")
    for l in retarget(a.src, a.dst, a.minos, a.sdk): print("  " + l)
