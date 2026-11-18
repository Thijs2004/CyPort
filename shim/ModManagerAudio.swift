// ModManagerAudio.swift - PC audio-replacer archives made to work on the Mac / iOS game (part of the mod manager).
//
// Why a PC audio mod does nothing here: the Mac build was cooked with a newer Wwise (bank version 150) whose loose media
// files live in a "media" subfolder:
//     PC    base\sound\soundbanks\<media id>.wem
//     Mac   base\sound\soundbanks\media\<media id>.wem
// Same media ids, same codec, another resource path and so another hash (FNV-1a 64 of the path): the game never asks for the
// hash the PC mod carries. Converting is renaming. ModAudio.convert rewrites the file table of the archive only: the hash of
// every loose PC .wem that has a Mac twin, the entries sorted by hash again (the game binary-searches the table) and the
// index checksum (CRC-64/XZ over the index from its three counts on). No sound is re-encoded, no data moves: the file keeps
// its size and differs in the index and in the index-size field of the header.
//
// It is the phone's copy of the Mac converter (CyPort-red4ext/audio-mac/convert.py + rdar.py) and writes the same bytes
// (tools/test_mod_audio.sh compares the two). Per resource:
//     PC loose .wem with a Mac twin    renamed to the Mac path
//     .bnk of another bank version     left out of the table: Wwise refuses a bank of another version (keepBnk keeps it)
//     anything else                    kept. convert.py leaves out what the Mac game has no resource for (dropUnknown does
//                                      the same); the mod manager keeps it, because a resource the game does not have may be
//                                      one the mod adds (ArchiveXL, or a new file its own replaced files point at)
// The media ids that exist under media\ in the Mac build are in the app bundle (CyPortMacMedia.txt, from shim/); without
// that list nothing is converted. "The Mac game has it" is asked of GameHashes (CyPortMacHashes.bin); without that list
// every hash that is not a PC media path counts as present.
//
// Layout (RDAR v12): 40-byte header (magic, version, indexPos u64, indexSize u32, debugPos u64, debugSize u32, fileSize u64);
// index = tableOffset u32 (8), tableSize u32, crc u64, nFiles u32, nSegments u32, nDeps u32, then file entries (56 bytes:
// hash u64, timestamp u64, nInline u32, segStart u32, segEnd u32, depStart u32, depEnd u32, sha1[20]), segments (16 bytes:
// offset u64, zsize u32, size u32) and dependency hashes (u64).
import Foundation

/// what ModAudio.inspect found in one archive
struct ModAudioInfo: Hashable {
    var sounds = 0                  // loose PC .wem entries that have a Mac twin
    var banks: [UInt32] = []        // bank versions of the .bnk entries the Mac game would refuse
    var needed: Bool { sounds > 0 || !banks.isEmpty }
}

/// what ModAudio.convert did to one archive
struct ModAudioResult {
    var renamed = 0                 // sounds moved to the Mac path
    var kept = 0
    var droppedBanks: [UInt32] = [] // bank versions of the .bnk entries left out
    var droppedOther = 0            // only with dropUnknown
    var written = false             // false: nothing would be left in the archive, the file was not changed
    /// sentences for the import preview / the details, without the archive's name
    var notes: [String] {
        var out: [String] = []
        if renamed > 0 { out.append("audio converted for the Mac game (\(renamed) sound\(renamed == 1 ? "" : "s") moved to base\\sound\\soundbanks\\media\\)") }
        if !droppedBanks.isEmpty {
            let v = Set(droppedBanks).sorted().map(String.init).joined(separator: ", ")
            out.append("\(droppedBanks.count) sound bank\(droppedBanks.count == 1 ? "" : "s") (.bnk, Wwise bank version \(v)) left out: the Mac game loads version \(ModAudio.macBankVersion) only and refuses a bank of another version")
        }
        if droppedOther > 0 { out.append("\(droppedOther) resource\(droppedOther == 1 ? "" : "s") left out: the Mac game has no such resource") }
        return out
    }
}

enum ModAudio {
    static let macBankVersion: UInt32 = 150       // BKHD version of every .bnk in the Mac 2.5.0 archives
    /// the Wwise media ids that exist as base\sound\soundbanks\media\<id>.wem in the Mac build, one per line
    static var idsPath: String? = Bundle.main.path(forResource: "CyPortMacMedia", ofType: "txt")
    /// archives with more entries than this are not searched for foreign .bnk files by inspect (convert always looks)
    static let bankCheckLimit = 4096

    static func fnv1a64(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }
    /// PC hash -> Mac hash, for every loose media file of the Mac build
    static let table: [UInt64: UInt64] = {
        guard let p = idsPath, let d = FileManager.default.contents(atPath: p) else { return [:] }
        var out: [UInt64: UInt64] = [:]
        for line in String(decoding: d, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), let id = UInt32(t) else { continue }
            out[fnv1a64("base\\sound\\soundbanks\\\(id).wem")] = fnv1a64("base\\sound\\soundbanks\\media\\\(id).wem")
        }
        return out
    }()
    static var available: Bool { !table.isEmpty }
    private static func inMac(_ h: UInt64) -> Bool { GameHashes.shared.map { $0.contains(h) } ?? (table[h] == nil) }
    /// the Mac hash of an entry that is a loose PC sound
    private static func macTwin(_ h: UInt64) -> UInt64? { table[h].flatMap { inMac(h) ? nil : $0 } }
    /// how many of an archive's resources are loose PC sounds
    static func sounds(in hashes: [UInt64]) -> Int { available ? hashes.reduce(0) { $0 + (macTwin($1) == nil ? 0 : 1) } : 0 }

    private static let crcTable: [UInt64] = (0..<256).map { i -> UInt64 in
        var c = UInt64(i)
        for _ in 0..<8 { c = c & 1 != 0 ? (c >> 1) ^ 0xC96C5795D7870F42 : c >> 1 }
        return c
    }
    static func crc64xz(_ data: [UInt8]) -> UInt64 {
        var c: UInt64 = ~0
        crcTable.withUnsafeBufferPointer { t in for x in data { c = t[Int((c ^ UInt64(x)) & 0xff)] ^ (c >> 8) } }
        return ~c
    }

    // ---------------------------------------------------------------- reading
    private static func u32(_ b: [UInt8], _ o: Int) -> UInt32 { b.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt32.self)) } }
    private static func u64(_ b: [UInt8], _ o: Int) -> UInt64 { b.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: o, as: UInt64.self)) } }
    private static func put<T: FixedWidthInteger>(_ v: T, _ b: inout [UInt8]) { withUnsafeBytes(of: v.littleEndian) { b.append(contentsOf: $0) } }
    private static func read(_ fd: Int32, _ off: UInt64, _ n: Int) -> [UInt8] {
        guard n > 0, off <= UInt64(Int64.max) else { return [] }
        var b = [UInt8](repeating: 0, count: n), got = 0
        while got < n {
            let r = b.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + got, n - got, off_t(off) + off_t(got)) }
            if r <= 0 { break }
            got += r
        }
        return got == n ? b : Array(b[0..<got])
    }
    private static func write(_ fd: Int32, _ off: UInt64, _ b: [UInt8]) throws {
        var done = 0
        while done < b.count {
            let r = b.withUnsafeBytes { pwrite(fd, $0.baseAddress! + done, b.count - done, off_t(off) + off_t(done)) }
            guard r > 0 else { throw ModError("can't write the archive: \(String(cString: strerror(errno)))") }
            done += r
        }
    }

    private struct Index {
        var ipos: UInt64 = 0
        var bytes: [UInt8] = []     // the whole index, as the header sizes it
        var nf = 0, ns = 0, nd = 0
    }
    private static func index(_ fd: Int32) throws -> Index {
        let head = read(fd, 0, 40)
        guard head.count == 40, Array(head[0..<4]) == Array("RDAR".utf8) else { throw ModError("not a Cyberpunk .archive") }
        var x = Index()
        x.ipos = u64(head, 8)
        let isz = Int(u32(head, 16))
        guard isz >= 28, isz <= 1 << 30 else { throw ModError("damaged index") }
        x.bytes = read(fd, x.ipos, isz)
        guard x.bytes.count == isz else { throw ModError("cut short") }
        x.nf = Int(u32(x.bytes, 16)); x.ns = Int(u32(x.bytes, 20)); x.nd = Int(u32(x.bytes, 24))
        guard x.nf <= 4_000_000, x.ns <= 64_000_000, x.nd <= 64_000_000, 28 + 56 * x.nf + 16 * x.ns + 8 * x.nd <= isz else { throw ModError("damaged index") }
        return x
    }
    /// the bank version when the entry's data starts with a Wwise bank header (BKHD), stored uncompressed
    private static func bankVersion(_ fd: Int32, _ x: Index, entry i: Int) throws -> UInt32? {
        let seg0 = Int(u32(x.bytes, 28 + 56 * i + 20))
        guard seg0 < x.ns else { throw ModError("damaged index") }
        let s = 28 + 56 * x.nf + 16 * seg0
        let head = read(fd, u64(x.bytes, s), min(12, Int(u32(x.bytes, s + 8))))
        guard head.count == 12, Array(head[0..<4]) == Array("BKHD".utf8) else { return nil }
        return u32(head, 8)
    }

    /// what `convert` would find in an archive, without changing it (the .bnk search is skipped for very large archives)
    static func inspect(_ path: String) throws -> ModAudioInfo {
        var info = ModAudioInfo()
        guard available else { return info }
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { throw ModError("can't open the archive") }
        defer { close(fd) }
        let x = try index(fd)
        for i in 0..<x.nf {
            let h = u64(x.bytes, 28 + 56 * i)
            if macTwin(h) != nil { info.sounds += 1 }
            else if x.nf <= bankCheckLimit, inMac(h), let v = try bankVersion(fd, x, entry: i), v != macBankVersion { info.banks.append(v) }
        }
        return info
    }

    /// Rewrites the file table of the archive at `path` in place (see the top of this file). Give it a copy.
    @discardableResult
    static func convert(_ path: String, keepBnk: Bool = false, dropUnknown: Bool = false) throws -> ModAudioResult {
        guard available else { throw ModError("this build has no list of the Mac game's sounds") }
        let fd = open(path, O_RDWR)
        guard fd >= 0 else { throw ModError("can't open the archive") }
        defer { close(fd) }
        let x = try index(fd)
        var r = ModAudioResult()
        var keep: [(hash: UInt64, pos: Int)] = []
        keep.reserveCapacity(x.nf)
        for i in 0..<x.nf {
            let h = u64(x.bytes, 28 + 56 * i)
            if let mac = macTwin(h) { keep.append((mac, i)); r.renamed += 1 }
            else if inMac(h) {
                if !keepBnk, let v = try bankVersion(fd, x, entry: i), v != macBankVersion { r.droppedBanks.append(v); continue }
                keep.append((h, i)); r.kept += 1
            } else if dropUnknown { r.droppedOther += 1 }
            else { keep.append((h, i)); r.kept += 1 }
        }
        guard !keep.isEmpty else { return r }
        keep.sort { $0.hash != $1.hash ? $0.hash < $1.hash : $0.pos < $1.pos }       // by hash; equal hashes stay in their order
        var body: [UInt8] = []
        body.reserveCapacity(x.bytes.count)
        put(UInt32(keep.count), &body); put(UInt32(x.ns), &body); put(UInt32(x.nd), &body)
        for k in keep {
            put(k.hash, &body)
            body.append(contentsOf: x.bytes[(28 + 56 * k.pos + 8)..<(28 + 56 * k.pos + 56)])
        }
        body.append(contentsOf: x.bytes[(28 + 56 * x.nf)...])                          // segments + dependencies, unchanged
        var idx: [UInt8] = []
        idx.reserveCapacity(x.bytes.count)
        put(UInt32(8), &idx); put(UInt32(body.count + 8), &idx); put(crc64xz(body), &idx)
        idx.append(contentsOf: body)
        let size = UInt32(idx.count)
        idx.append(contentsOf: [UInt8](repeating: 0, count: x.bytes.count - idx.count))
        try write(fd, x.ipos, idx)
        var sz: [UInt8] = []; put(size, &sz)
        try write(fd, 16, sz)
        // read it back: the table the game will search
        let back = try index(fd)
        guard back.nf == keep.count, (0..<back.nf).allSatisfy({ u64(back.bytes, 28 + 56 * $0) == keep[$0].hash }) else { throw ModError("the converted archive did not read back") }
        r.written = true
        return r
    }
}

extension ModStore {
    private static let audioLock = NSLock()
    private static var audioCache: [String: (stamp: String, info: ModAudioInfo)] = [:]
    /// ModAudio.inspect, remembered until the file changes
    func audioInfo(_ path: String) -> ModAudioInfo {
        guard ModAudio.available else { return ModAudioInfo() }
        let st = stamp(path)
        ModStore.audioLock.lock(); let hit = ModStore.audioCache[path]; ModStore.audioLock.unlock()
        if let h = hit, h.stamp == st { return h.info }
        let info = (try? ModAudio.inspect(path)) ?? ModAudioInfo()
        ModStore.audioLock.lock(); ModStore.audioCache[path] = (st, info); ModStore.audioLock.unlock()
        return info
    }
    /// the installed mods (on or off) with an archive that "Convert audio for the Mac game" would change
    func audioNeeds(_ list: ModList) -> [String: ModAudioInfo] {
        var out: [String: ModAudioInfo] = [:]
        for m in list.mods + list.unmanaged {
            let base = m.enabled ? game : cyport + "/disabled/" + m.id
            var sum = ModAudioInfo()
            for f in m.files where isArchive(f) { let i = audioInfo(base + "/" + f.path); sum.sounds += i.sounds; sum.banks += i.banks }
            if sum.needed { out[m.id] = sum }
        }
        return out
    }
    /// what an archive replaces / adds, against the list of the Mac game's resources (the line under it in the import preview)
    static func archiveVerdict(_ hs: [UInt64], size: Int64, addsNew: Bool) -> (text: String, good: Bool) {
        let n = hs.count, mb = String(format: "%.1f MB", Double(size) / 1e6)
        guard let g = GameHashes.shared else { return ("\(n) resources (\(mb)); not checked against the game", true) }
        let hit = hs.reduce(0) { $0 + (g.contains($1) ? 1 : 0) }
        if n > 0 && hit == n { return ("OK: replaces \(n) game resource\(n == 1 ? "" : "s") (\(mb))", true) }
        if addsNew && hit == 0 { return ("OK: adds \(n) new resource\(n == 1 ? "" : "s"), registered by ArchiveXL / TweakXL (\(mb))", true) }
        if addsNew { return ("OK: replaces \(hit), adds \(n - hit) new (\(mb))", true) }
        if n > 0 && 100 * hit / n >= 80 { return ("Probably OK: \(hit) of \(n) resources exist in the Mac game (\(mb))", true) }
        if hit > 0 { return ("Partial: \(hit) of \(n) exist in the Mac game; the rest are new files nothing refers to (\(mb))", true) }
        return ("Replaces nothing: 0 of \(n) resources exist in the Mac game (PC-only files?)", false)
    }

    /// "Convert audio for the Mac game" for a mod that is already installed (or was copied into the game folder by hand):
    /// each of its archives that needs it is converted on a copy beside it, which then takes its place.
    func convertAudio(_ mod: ModManifest) throws -> String {
        var m = mod
        let base = m.enabled ? game : cyport + "/disabled/" + m.id
        let addsNew = m.kinds.contains("archivexl") || m.kinds.contains("tweak")
        var sounds = 0, banks = 0, changed = 0, useless: [String] = []
        for f in m.files where isArchive(f) {
            let path = base + "/" + f.path, file = (f.path as NSString).lastPathComponent, name = ModStore.stripOrder(file)
            guard audioInfo(path).needed else { continue }
            let tmp = path + ".cyport-audio"
            try? fm.removeItem(atPath: tmp)
            try fm.copyItem(atPath: path, toPath: tmp)
            let r: ModAudioResult
            do {
                r = try ModAudio.convert(tmp)
                if r.written { guard rename(tmp, path) == 0 else { throw ModError("Couldn't put the converted \(file) in place: \(String(cString: strerror(errno)))") } }
                else { try? fm.removeItem(atPath: tmp) }
            } catch { try? fm.removeItem(atPath: tmp); throw ModError("\(file): \(error.localizedDescription)") }
            guard r.written else { useless.append(file); continue }
            sounds += r.renamed; banks += r.droppedBanks.count; changed += 1
            // the manifest's lines about this archive are written again
            m.notes.removeAll { $0.hasPrefix(name + ": ") || $0.hasPrefix(file + ": ") }
            if let hs = try? ModStore.archiveHashes(path) { m.notes.append(name + ": " + ModStore.archiveVerdict(hs, size: f.size, addsNew: addsNew).text) }
            m.notes += r.notes.map { name + ": " + $0 }
            modLog("audio converted in \(f.path): \(r.renamed) renamed, \(r.kept) kept, \(r.droppedBanks.count) banks left out")
        }
        if changed > 0, fm.fileExists(atPath: manifestPath(m.id)) { try save(m) }
        var msg: [String] = []
        if changed > 0 {
            var what: [String] = []
            if sounds > 0 { what.append("\(sounds) sound\(sounds == 1 ? "" : "s") converted for the Mac game") }
            if banks > 0 { what.append("\(banks) sound bank\(banks == 1 ? "" : "s") of another Wwise version left out") }
            msg.append("\(m.name): " + what.joined(separator: ", ") + ". It applies the next time you press Play.")
        }
        if !useless.isEmpty { msg.append("\(useless.joined(separator: ", ")) only \(useless.count == 1 ? "has" : "have") a sound bank the Mac game refuses (it loads Wwise bank version \(ModAudio.macBankVersion) only): left as \(useless.count == 1 ? "it is" : "they are"), the mod does nothing here.") }
        return msg.isEmpty ? "\(m.name): nothing to convert." : msg.joined(separator: " ")
    }
}
