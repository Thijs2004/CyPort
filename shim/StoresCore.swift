// Store downloads: sign in to Steam, GOG or Epic and download the Mac version of Cyberpunk 2077's game data
// (archive, engine, r6) straight into the app - only when the account owns the game (each store refuses the
// download otherwise). The executable is not downloaded: iOS only runs code that was signed into the app, so it
// still comes from the Mac build (build.sh).
//
// Written for CyPort. The store protocols were worked out from the stores' public behaviour and from how other
// open clients (legendary, heroic-gogdl, SteamKit, playport) talk to them; no code is copied from them.
// No UIKit here (StoresUI.swift has the screens), so this file also builds for a Mac test tool.
import Foundation
import CommonCrypto
import Security
import zlib

@_silgen_name("ms_lzma_decode")
func ms_lzma_decode(_ props: UnsafePointer<UInt8>, _ src: UnsafePointer<UInt8>, _ srcLen: Int, _ dst: UnsafeMutablePointer<UInt8>, _ dstLen: Int) -> Int
@_silgen_name("ms_zstd_decode")
func ms_zstd_decode(_ src: UnsafePointer<UInt8>, _ srcLen: Int, _ dst: UnsafeMutablePointer<UInt8>, _ dstLen: Int) -> Int
@_silgen_name("MacShimLogC")
func MacShimLogC(_ what: UnsafePointer<CChar>, _ detail: UnsafePointer<CChar>)

/// macshim.log (never tokens or passwords)
func storeLog(_ s: String) { "store".withCString { a in s.withCString { MacShimLogC(a, $0) } } }

struct StoreError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

// MARK: - the game

enum Game {
    static let steamApp: UInt32 = 1091500
    static let gogProduct = "1423049311", gogPhantomLiberty = "1256837418"
    static let epicTitle = "cyberpunk 2077"
    /// the version the app's executable is (the Info.plist build.sh wrote from the game's own)
    static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }
    /// "2.3.1", "2.31a_mac", "2.31" -> "231"
    static func versionDigits(_ s: String) -> String { String(s.prefix { $0.isNumber || $0 == "." }.filter(\.isNumber)) }
}

// MARK: - bytes, hashes, crypto, compression

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
    init?(hex: String) {
        var d = Data(capacity: hex.count / 2), it = hex.makeIterator()
        while let a = it.next() { guard let b = it.next(), let v = UInt8(String([a, b]), radix: 16) else { return nil }; d.append(v) }
        self = d
    }
    /// little-endian reads; `at` counts from the first byte (also for slices)
    func u32(_ at: Int) -> UInt32 {
        withUnsafeBytes { (p: UnsafeRawBufferPointer) -> UInt32 in
            let b0 = UInt32(p[at]), b1 = UInt32(p[at + 1]), b2 = UInt32(p[at + 2]), b3 = UInt32(p[at + 3])
            return b0 | b1 << 8 | b2 << 16 | b3 << 24
        }
    }
    func u16(_ at: Int) -> UInt16 { withUnsafeBytes { (p: UnsafeRawBufferPointer) -> UInt16 in UInt16(p[at]) | UInt16(p[at + 1]) << 8 } }
    func u64(_ at: Int) -> UInt64 { UInt64(u32(at)) | UInt64(u32(at + 4)) << 32 }
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) { var x = v.littleEndian; Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) } }
}

enum Hash {
    static func md5(_ d: Data) -> Data {
        var out = Data(count: Int(CC_MD5_DIGEST_LENGTH))
        out.withUnsafeMutableBytes { o in d.withUnsafeBytes { _ = CC_MD5($0.baseAddress, CC_LONG(d.count), o.bindMemory(to: UInt8.self).baseAddress) } }
        return out
    }
    static func sha1(_ d: Data) -> Data {
        var out = Data(count: Int(CC_SHA1_DIGEST_LENGTH))
        out.withUnsafeMutableBytes { o in d.withUnsafeBytes { _ = CC_SHA1($0.baseAddress, CC_LONG(d.count), o.bindMemory(to: UInt8.self).baseAddress) } }
        return out
    }
    static func crc32(_ d: Data) -> UInt32 { d.withUnsafeBytes { UInt32(zlib.crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(d.count))) } }
    /// Steam's chunk checksum: Adler-32 seeded with 0 instead of 1
    static func steamAdler(_ d: Data) -> UInt32 { d.withUnsafeBytes { UInt32(zlib.adler32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(d.count))) } }
}

enum AES {
    private static func run(_ op: Int, _ opts: Int, key: Data, iv: Data?, _ input: Data) throws -> Data {
        var out = Data(count: input.count + kCCBlockSizeAES128), moved = 0
        let st = out.withUnsafeMutableBytes { o in input.withUnsafeBytes { i in key.withUnsafeBytes { k in
            (iv ?? Data()).withUnsafeBytes { v in
                CCCrypt(CCOperation(op), CCAlgorithm(kCCAlgorithmAES), CCOptions(opts), k.baseAddress, key.count,
                        iv == nil ? nil : v.baseAddress, i.baseAddress, input.count, o.baseAddress, o.count, &moved)
            } } } }
        guard st == kCCSuccess else { throw StoreError("decryption failed (\(st))") }
        return out.prefix(moved)
    }
    /// Steam's depot encryption: a 16-byte IV encrypted with AES-256-ECB, then the data in AES-256-CBC (PKCS#7)
    static func steamDecrypt(_ d: Data, key: Data) throws -> Data {
        guard d.count >= 32, key.count == 32 else { throw StoreError("encrypted data too short") }
        let iv = try run(kCCDecrypt, kCCOptionECBMode, key: key, iv: nil, d.prefix(16))
        return try run(kCCDecrypt, kCCOptionPKCS7Padding, key: key, iv: iv, d.dropFirst(16))
    }
}

enum Inflate {
    /// zlib (windowBits 15+32: zlib or gzip header) or raw deflate (-15)
    static func run(_ src: Data, windowBits: Int32 = 15 + 32, expected: Int? = nil) throws -> Data {
        var s = z_stream(); guard inflateInit2_(&s, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw StoreError("zlib init") }
        defer { inflateEnd(&s) }
        var out = Data(count: max(expected ?? src.count * 4, 64))
        var produced = 0, ret: Int32 = Z_OK
        try src.withUnsafeBytes { (i: UnsafeRawBufferPointer) in
            s.next_in = UnsafeMutablePointer(mutating: i.bindMemory(to: Bytef.self).baseAddress); s.avail_in = uInt(src.count)
            repeat {
                if produced == out.count { out.count *= 2 }
                ret = out.withUnsafeMutableBytes { (o: UnsafeMutableRawBufferPointer) -> Int32 in
                    s.next_out = o.bindMemory(to: Bytef.self).baseAddress! + produced; s.avail_out = uInt(o.count - produced)
                    let r = inflate(&s, Z_NO_FLUSH); produced = o.count - Int(s.avail_out); return r
                }
                if ret != Z_OK && ret != Z_STREAM_END && ret != Z_BUF_ERROR { throw StoreError("corrupt compressed data (zlib \(ret))") }
                if ret == Z_BUF_ERROR && s.avail_in == 0 { break }
            } while ret != Z_STREAM_END
        }
        return out.prefix(produced)
    }
}

/// a zip with one entry (Steam manifests, some Steam chunks)
enum Zip {
    static func firstEntry(_ z: Data) throws -> Data {
        var eocd = -1
        if z.count >= 22 { for i in stride(from: z.count - 22, through: max(0, z.count - 22 - 65535), by: -1) where z.u32(i) == 0x06054b50 { eocd = i; break } }
        guard eocd >= 0 else { throw StoreError("zip: no directory") }
        let cd = Int(z.u32(eocd + 16))
        guard cd + 46 <= z.count, z.u32(cd) == 0x02014b50 else { throw StoreError("zip: bad directory") }
        let method = z.u16(cd + 10), csize = Int(z.u32(cd + 20)), usize = Int(z.u32(cd + 24)), local = Int(z.u32(cd + 42))
        guard local + 30 <= z.count, z.u32(local) == 0x04034b50 else { throw StoreError("zip: bad entry") }
        let start = local + 30 + Int(z.u16(local + 26)) + Int(z.u16(local + 28))
        guard start + csize <= z.count else { throw StoreError("zip: truncated") }
        let body = z.subdata(in: start..<(start + csize))
        switch method {
        case 0: return body
        case 8: return try Inflate.run(body, windowBits: -15, expected: usize)
        default: throw StoreError("zip: method \(method)")
        }
    }
}

// MARK: - HTTP

/// Bytes received so far by every request, including ones still arriving (for a live download speed: chunks are up
/// to 10 MB, so counting only finished ones made the screen jump every few seconds).
final class NetMeter: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = NetMeter()
    private let l = NSLock()
    private var active: [Int: URLSessionTask] = [:]
    private var finished: Int64 = 0
    func urlSession(_ s: URLSession, didCreateTask t: URLSessionTask) { l.lock(); active[t.taskIdentifier] = t; l.unlock() }
    func urlSession(_ s: URLSession, task t: URLSessionTask, didCompleteWithError e: Error?) {
        l.lock(); if active.removeValue(forKey: t.taskIdentifier) != nil { finished += t.countOfBytesReceived }; l.unlock()
    }
    /// (all bytes received, bytes of requests still running)
    var snapshot: (total: Int64, inFlight: Int64) {
        l.lock(); defer { l.unlock() }
        var running: Int64 = 0
        for (id, t) in active {          // async requests don't always report completion to the session delegate
            if t.state == .completed { finished += t.countOfBytesReceived; active[id] = nil } else { running += t.countOfBytesReceived }
        }
        return (finished + running, running)
    }
}

enum Net {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 60; c.httpMaximumConnectionsPerHost = 16; c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        return URLSession(configuration: c, delegate: NetMeter.shared, delegateQueue: nil)
    }()
    static func request(_ url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil, tries: Int = 3) async throws -> Data {
        var last: Error = StoreError("no response")
        for attempt in 0..<tries {
            if attempt > 0 { try await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000) }
            var r = URLRequest(url: url); r.httpMethod = method; r.httpBody = body
            for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
            do {
                let (d, resp) = try await session.data(for: r)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(code) { return d }
                last = StoreError("\(url.host ?? "server") answered HTTP \(code)")
                if code == 401 || code == 403 || code == 404 || code == 400 { throw last }
            } catch let e as StoreError { throw e }
            catch is CancellationError { throw CancellationError() }
            catch { last = error }
        }
        throw last
    }
    static func json(_ url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil) async throws -> [String: Any] {
        let d = try await request(url, method: method, headers: headers, body: body)
        guard let o = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw StoreError("unexpected reply from \(url.host ?? "server")") }
        return o
    }
    static func form(_ f: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        return Data(f.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&").utf8)
    }
}

// MARK: - Keychain (sign-ins survive app restarts, never written to files or the log)

enum Keychain {
    static let service = "cyport.stores"
    static func save(_ key: String, _ value: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: value) else { return }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        var add = q; add[kSecValueData as String] = d; add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
    static func load(_ key: String) -> [String: Any]? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
    }
    static func delete(_ key: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key] as CFDictionary)
    }
}

// MARK: - what gets downloaded

/// One output file, built from parts of decoded chunks in order.
struct DLPart { let chunk: Int; let offset: Int; let length: Int }
struct DLFile { var path: String; let size: Int64; let parts: [DLPart] }
/// A store's download: the files and a way to get chunk n, decoded and verified.
struct DLPlan {
    var files: [DLFile]
    var chunkCount: Int
    var version: String                 /// identifies this build (resume journal)
    var versionName: String             /// the game version as the store names it ("2.31a_mac"), for the screen
    var fetch: @Sendable (Int) async throws -> Data
    var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }
}

enum GameFiles {
    static let dataDirs = ["archive", "engine", "r6"]
    /// Keep only the game's data folders (the Mac app bundle with the executable is skipped) and make their paths
    /// relative to the game folder, wherever the store puts it.
    static func pick(_ files: [DLFile]) throws -> [DLFile] {
        var prefix: String?
        for f in files {
            let l = f.path.lowercased()
            guard let r = l.range(of: "r6/") else { continue }
            let p = String(l[..<r.lowerBound])
            guard p.isEmpty || p.hasSuffix("/") else { continue }
            if prefix == nil || p.count < prefix!.count { prefix = p }
        }
        guard let pre = prefix else { throw StoreError("This download doesn't contain the game's data folders (archive, engine, r6).") }
        var byPath: [String: DLFile] = [:], order: [String] = []
        for var f in files {
            let l = f.path.lowercased()
            guard l.hasPrefix(pre) else { continue }
            let rel = String(f.path.dropFirst(pre.count))
            guard let top = rel.split(separator: "/").first, dataDirs.contains(top.lowercased()), rel.contains("/") else { continue }
            guard !rel.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { continue }
            f.path = rel
            if byPath[rel.lowercased()] == nil { order.append(rel.lowercased()) }
            byPath[rel.lowercased()] = f                         // a later depot (DLC, language) wins
        }
        let out = order.compactMap { byPath[$0] }
        guard !out.isEmpty else { throw StoreError("This download doesn't contain the game's data folders.") }
        return out
    }
}

// MARK: - downloader (resumable; one file at a time, chunks fetched ahead in parallel, written in order)

final class Downloader: @unchecked Sendable {
    struct Progress { var done: Int64; var total: Int64; var bytesPerSecond: Double; var secondsLeft: Double; var file: String }
    private var liveDone: Int64 = 0, liveFile = ""
    private func setLive(_ d: Int64, _ f: String?) { lock.lock(); liveDone = d; if let f { liveFile = f }; lock.unlock() }
    private func live() -> (Int64, String) { lock.lock(); defer { lock.unlock() }; return (liveDone, liveFile) }
    let plan: DLPlan, dest: URL
    var parallel = 8
    private let journalURL: URL
    private var journal: [String: Int64] = [:]           // path -> bytes known good (complete files: their size)
    private let lock = NSLock()

    init(plan: DLPlan, dest: URL) {
        self.plan = plan; self.dest = dest
        journalURL = dest.appendingPathComponent(".cyport-download.json")
        if let d = try? Data(contentsOf: journalURL), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           (j["version"] as? String) == plan.version, let files = j["files"] as? [String: NSNumber] {
            journal = files.mapValues { $0.int64Value }
        }
    }
    private func setJournal(_ p: String, _ n: Int64) { lock.lock(); journal[p] = n; lock.unlock() }
    private func saveJournal() {
        lock.lock(); let files = journal; lock.unlock()
        if let d = try? JSONSerialization.data(withJSONObject: ["version": plan.version, "files": files]) { try? d.write(to: journalURL, options: .atomic) }
    }
    /// bytes still to download (for the free-space check)
    func remainingBytes() -> Int64 {
        plan.files.reduce(0) { $0 + max(0, $1.size - min(journal[$1.path] ?? 0, onDisk($1.path))) }
    }
    private func onDisk(_ p: String) -> Int64 { (try? FileManager.default.attributesOfItem(atPath: dest.appendingPathComponent(p).path)[.size] as? NSNumber)?.int64Value ?? 0 }

    func run(progress: @escaping (Progress) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let total = plan.totalBytes
        var done: Int64 = 0
        // where each file starts again: whole parts only, never past what is on disk
        var starts: [(file: Int, part: Int, offset: Int64)] = []
        for (i, f) in plan.files.enumerated() {
            let good = min(journal[f.path] ?? 0, onDisk(f.path))
            var part = 0, off: Int64 = 0
            while part < f.parts.count, off + Int64(f.parts[part].length) <= good { off += Int64(f.parts[part].length); part += 1 }
            if f.size == 0 { part = 0; off = 0 }
            starts.append((i, part, off)); done += off
        }
        storeLog("download: \(plan.files.count) files, \(total / 1_000_000) MB, \(done / 1_000_000) MB already there, build \(plan.version)")
        // reference counts: a chunk used by several parts is kept until its last use
        var uses = [Int](repeating: 0, count: plan.chunkCount)
        for s in starts { for p in plan.files[s.file].parts[s.part...] { uses[p.chunk] += 1 } }
        var cache: [Int: Data] = [:], inflight: [Int: Task<Data, Error>] = [:]
        let fetch = plan.fetch
        // the queue of parts still to write, in order
        var queue: [(file: Int, part: Int)] = []
        for s in starts { for p in s.part..<plan.files[s.file].parts.count { queue.append((s.file, p)) } }
        var ahead = 0                                       // next queue index to start fetching
        func pump() {
            while ahead < queue.count && inflight.count < parallel {
                let c = plan.files[queue[ahead].file].parts[queue[ahead].part].chunk
                ahead += 1
                if cache[c] != nil || inflight[c] != nil { continue }
                inflight[c] = Task { try await fetch(c) }
            }
        }
        var lastSave = Date()
        setLive(done, nil)
        // the screen: 4 updates a second; speed = network bytes over the last 3 s, time left from that speed
        let ticker = Task { [weak self] in
            var samples: [(Double, Int64)] = [], speed = 0.0, shown: Int64 = 0
            while !Task.isCancelled, let self {
                let now = CFAbsoluteTimeGetCurrent(), net = NetMeter.shared.snapshot
                samples.append((now, net.total)); samples.removeAll { now - $0.0 > 3 }
                if let first = samples.first, now - first.0 > 0.2 {
                    let s = Double(net.total - first.1) / (now - first.0)
                    speed = speed == 0 ? s : speed * 0.6 + s * 0.4
                }
                let (written, file) = self.live(); shown = max(shown, min(total, written + net.inFlight)); let d = shown
                progress(Progress(done: d, total: total, bytesPerSecond: speed, secondsLeft: speed > 1000 ? Double(total - d) / speed : 0, file: file))
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        defer { ticker.cancel() }
        var current: FileHandle?, currentFile = -1, fileWritten: Int64 = 0
        defer { try? current?.close() }
        var qi = 0
        // files that already finished (or are empty) still need to exist
        for s in starts where plan.files[s.file].parts.isEmpty || s.part == plan.files[s.file].parts.count {
            let u = dest.appendingPathComponent(plan.files[s.file].path)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: u.path) { fm.createFile(atPath: u.path, contents: nil) }
        }
        while qi < queue.count {
            try Task.checkCancellation()
            pump()
            let (fi, pi) = queue[qi]; let f = plan.files[fi], part = f.parts[pi]
            if fi != currentFile {
                try current?.synchronize(); try current?.close(); current = nil
                let u = dest.appendingPathComponent(f.path)
                try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !fm.fileExists(atPath: u.path) { fm.createFile(atPath: u.path, contents: nil) }
                let h = try FileHandle(forWritingTo: u)
                let start = starts[fi].offset
                try h.truncate(atOffset: UInt64(start)); try h.seek(toOffset: UInt64(start))
                current = h; currentFile = fi; fileWritten = start
            }
            let data: Data
            if let d = cache[part.chunk] { data = d }
            else {
                let t = inflight[part.chunk] ?? Task { try await fetch(part.chunk) }
                inflight[part.chunk] = nil
                data = try await t.value
            }
            uses[part.chunk] -= 1
            if uses[part.chunk] > 0 { cache[part.chunk] = data } else { cache[part.chunk] = nil }
            guard part.offset + part.length <= data.count else { throw StoreError("a downloaded chunk is shorter than the manifest says") }
            do { try current!.write(contentsOf: data.subdata(in: part.offset..<(part.offset + part.length))) }
            catch { throw StoreError("Writing \(f.path) failed: \(error.localizedDescription). Is the storage full?") }
            done += Int64(part.length)
            setLive(done, f.path)
            fileWritten += Int64(part.length)
            setJournal(f.path, fileWritten)
            if pi + 1 == f.parts.count { try current?.synchronize(); try current?.close(); current = nil; currentFile = -1; saveJournal() }
            qi += 1
            let now = Date()
            if now.timeIntervalSince(lastSave) > 5 { try current?.synchronize(); saveJournal(); lastSave = now }
            // keep the decoded-chunk cache bounded (Epic chunks can be shared between far-apart files)
            if cache.count > 256 { for k in cache.keys.prefix(cache.count - 192) { cache[k] = nil } }
        }
        try? fm.removeItem(at: journalURL)
        ticker.cancel()
        progress(Progress(done: total, total: total, bytesPerSecond: 0, secondsLeft: 0, file: ""))
        storeLog("download complete")
    }
}

// MARK: - minimal protobuf (Steam)

struct PBWriter {
    var data = Data()
    private mutating func varint(_ v: UInt64) { var v = v; while v >= 0x80 { data.append(UInt8(v & 0x7f) | 0x80); v >>= 7 }; data.append(UInt8(v)) }
    private mutating func key(_ f: Int, _ t: Int) { varint(UInt64(f << 3 | t)) }
    mutating func u(_ f: Int, _ v: UInt64) { key(f, 0); varint(v) }
    mutating func i(_ f: Int, _ v: Int64) { key(f, 0); varint(UInt64(bitPattern: v)) }
    mutating func b(_ f: Int, _ v: Bool) { u(f, v ? 1 : 0) }
    mutating func bytes(_ f: Int, _ v: Data) { key(f, 2); varint(UInt64(v.count)); data.append(v) }
    mutating func s(_ f: Int, _ v: String) { bytes(f, Data(v.utf8)) }
    mutating func fixed64(_ f: Int, _ v: UInt64) { key(f, 1); data.appendLE(v) }
    mutating func msg(_ f: Int, _ m: PBWriter) { bytes(f, m.data) }
}
struct PBMessage {
    enum Value { case varint(UInt64), fixed64(UInt64), bytes(Data), fixed32(UInt32) }
    var fields: [Int: [Value]] = [:]
    init(_ d: Data) throws {
        var p = d.startIndex
        func varint() throws -> UInt64 {
            var r: UInt64 = 0, shift: UInt64 = 0
            while true {
                guard p < d.endIndex, shift < 64 else { throw StoreError("protobuf: truncated") }
                let b = d[p]; p += 1; r |= UInt64(b & 0x7f) << shift; shift += 7
                if b < 0x80 { return r }
            }
        }
        while p < d.endIndex {
            let k = try varint(), f = Int(k >> 3)
            switch k & 7 {
            case 0: fields[f, default: []].append(.varint(try varint()))
            case 1: guard p + 8 <= d.endIndex else { throw StoreError("protobuf: truncated") }
                fields[f, default: []].append(.fixed64(Data([UInt8](d[p..<p + 8])).u64(0))); p += 8
            case 2: let n = Int(try varint()); guard n >= 0, p + n <= d.endIndex else { throw StoreError("protobuf: truncated") }
                fields[f, default: []].append(.bytes(Data([UInt8](d[p..<p + n])))); p += n
            case 5: guard p + 4 <= d.endIndex else { throw StoreError("protobuf: truncated") }
                fields[f, default: []].append(.fixed32(Data([UInt8](d[p..<p + 4])).u32(0))); p += 4
            default: throw StoreError("protobuf: wire type \(k & 7)")
            }
        }
    }
    func u(_ f: Int) -> UInt64? {
        switch fields[f]?.last { case .varint(let v)?: return v; case .fixed64(let v)?: return v; case .fixed32(let v)?: return UInt64(v); default: return nil }
    }
    func i32(_ f: Int) -> Int32? { u(f).map { Int32(truncatingIfNeeded: Int64(bitPattern: $0)) } }
    func data(_ f: Int) -> Data? { if case .bytes(let d)? = fields[f]?.last { return d }; return nil }
    func s(_ f: Int) -> String? { data(f).map { String(decoding: $0, as: UTF8.self) } }
    func all(_ f: Int) -> [Data] { (fields[f] ?? []).compactMap { if case .bytes(let d) = $0 { return d }; return nil } }
    func f32(_ f: Int) -> Float? { if case .fixed32(let v)? = fields[f]?.last { return Float(bitPattern: v) }; return nil }
}

// MARK: - Valve KeyValues text (app info)

final class KV {
    var value: String?
    var children: [(String, KV)] = []
    subscript(_ k: String) -> KV? { children.first { $0.0.caseInsensitiveCompare(k) == .orderedSame }?.1 }
    var string: String? { value }
    static func parse(_ text: String) -> KV {
        let root = KV(); var stack = [root]; var pendingKey: String?
        let it = Array(text.unicodeScalars); var i = 0
        func token() -> String? {
            while i < it.count {
                let c = it[i]
                if c == "/" && i + 1 < it.count && it[i + 1] == "/" { while i < it.count && it[i] != "\n" { i += 1 }; continue }
                if c.properties.isWhitespace || c == "\0" { i += 1; continue }
                break
            }
            guard i < it.count else { return nil }
            if it[i] == "{" || it[i] == "}" { i += 1; return String(it[i - 1]) }
            var s = String.UnicodeScalarView()
            if it[i] == "\"" {
                i += 1
                while i < it.count && it[i] != "\"" {
                    if it[i] == "\\" && i + 1 < it.count {
                        i += 1
                        switch it[i] { case "n": s.append("\n"); case "t": s.append("\t"); default: s.append(it[i]) }
                    } else { s.append(it[i]) }
                    i += 1
                }
                i += 1
                return "\"" + String(s)
            }
            while i < it.count && !it[i].properties.isWhitespace && it[i] != "{" && it[i] != "}" && it[i] != "\"" { s.append(it[i]); i += 1 }
            return "\"" + String(s)
        }
        while let t = token() {
            if t == "{" { let n = KV(); stack.last!.children.append((pendingKey ?? "", n)); stack.append(n); pendingKey = nil }
            else if t == "}" { if stack.count > 1 { stack.removeLast() } }
            else if let k = pendingKey { let n = KV(); n.value = String(t.dropFirst()); stack.last!.children.append((k, n)); pendingKey = nil }
            else { pendingKey = String(t.dropFirst()) }
        }
        return root
    }
}

// MARK: - Steam: CM connection over WebSocket

actor SteamCM {
    enum EMsg: UInt32 {
        case multi = 1, serviceMethodResponse = 147, serviceMethodCallFromClient = 151, clientHeartBeat = 703, clientLogOnResponse = 751,
             clientLoggedOff = 757, clientGetDepotDecryptionKey = 5438, clientGetDepotDecryptionKeyResponse = 5439, clientLogon = 5514,
             picsProductInfoRequest = 8903, picsProductInfoResponse = 8904, picsAccessTokenRequest = 8905, picsAccessTokenResponse = 8906, clientUFSGetFileListForApp = 5914,
             serviceMethodCallFromClientNonAuthed = 9804, clientHello = 9805
    }
    struct Packet { let emsg: UInt32; let header: PBMessage; let body: Data }
    static let protocolVersion: UInt64 = 65580
    private var ws: URLSessionWebSocketTask?
    private var nextJob: UInt64 = 1
    private var jobWaiters: [UInt64: CheckedContinuation<Packet, Error>] = [:]
    private var jobQueue: [UInt64: [Packet]] = [:]
    private var emsgWaiters: [UInt32: CheckedContinuation<Packet, Error>] = [:]
    private var failure: Error?
    private(set) var steamID: UInt64 = 0
    private(set) var sessionID: Int32 = 0
    private(set) var cellID: UInt32 = 0
    private var heartbeat: Task<Void, Never>?

    func connect() async throws {
        let o = try await Net.json(URL(string: "https://api.steampowered.com/ISteamDirectory/GetCMListForConnect/v1/?cellid=0&cmtype=websockets&maxcount=10")!)
        let list = ((o["response"] as? [String: Any])?["serverlist"] as? [[String: Any]] ?? []).compactMap { $0["endpoint"] as? String }
        guard !list.isEmpty else { throw StoreError("Steam gave no server to connect to") }
        var last: Error = StoreError("couldn't reach Steam")
        for ep in list.prefix(4) {
            do {
                let t = Net.session.webSocketTask(with: URL(string: "wss://\(ep)/cmsocket/")!)
                t.maximumMessageSize = 64 << 20
                t.resume(); ws = t; failure = nil
                Task { await self.receiveLoop(t) }
                var hello = PBWriter(); hello.u(1, Self.protocolVersion)
                try await send(.clientHello, hello, steamID: 0, session: 0)
                storeLog("steam: connected to \(ep)")
                return
            } catch { last = error; ws?.cancel(); ws = nil }
        }
        throw last
    }
    func close() { heartbeat?.cancel(); ws?.cancel(with: .goingAway, reason: nil); ws = nil }

    private func receiveLoop(_ t: URLSessionWebSocketTask) async {
        while true {
            do {
                let m = try await t.receive()
                guard case .data(let d) = m else { continue }
                try handle(d)
            } catch {
                fail(StoreError("Steam connection closed (\(error.localizedDescription))")); return
            }
        }
    }
    private func handle(_ d: Data) throws {
        guard d.count >= 8 else { return }
        let raw = d.u32(0), emsg = raw & 0x7fffffff
        guard raw & 0x80000000 != 0 else { return }                       // not protobuf: nothing we use
        let hl = Int(d.u32(4)); guard 8 + hl <= d.count else { return }
        let header = try PBMessage(d.subdata(in: 8..<(8 + hl)))
        let p = Packet(emsg: emsg, header: header, body: d.subdata(in: (8 + hl)..<d.count))
        if emsg == EMsg.multi.rawValue {
            let m = try PBMessage(p.body)
            var inner = m.data(2) ?? Data()
            if (m.u(1) ?? 0) > 0 { inner = try Inflate.run(inner, windowBits: 15 + 32, expected: Int(m.u(1)!)) }
            var at = 0
            while at + 4 <= inner.count {
                let n = Int(inner.u32(at)); at += 4
                guard at + n <= inner.count else { break }
                try handle(inner.subdata(in: at..<(at + n))); at += n
            }
            return
        }
        if emsg == EMsg.clientLogOnResponse.rawValue {
            if let s = header.u(1) { steamID = s }
            if let s = header.i32(2) { sessionID = s }
        }
        if emsg == EMsg.clientLoggedOff.rawValue { fail(StoreError("Steam logged this session off")); return }
        if let job = header.u(11), job != UInt64.max {
            if let c = jobWaiters.removeValue(forKey: job) { c.resume(returning: p) } else { jobQueue[job, default: []].append(p) }
            return
        }
        if let c = emsgWaiters.removeValue(forKey: emsg) { c.resume(returning: p) }
    }
    private func fail(_ e: Error) {
        guard failure == nil else { return }
        failure = e; heartbeat?.cancel()
        for (_, c) in jobWaiters { c.resume(throwing: e) }
        for (_, c) in emsgWaiters { c.resume(throwing: e) }
        jobWaiters = [:]; emsgWaiters = [:]
    }
    private func send(_ e: EMsg, _ body: PBWriter, job: UInt64? = nil, target: String? = nil, steamID sid: UInt64? = nil, session: Int32? = nil) async throws {
        if let failure { throw failure }
        guard let ws else { throw StoreError("not connected to Steam") }
        var h = PBWriter()
        h.fixed64(1, sid ?? steamID)
        h.i(2, Int64(session ?? sessionID))
        if let job { h.fixed64(10, job) }
        if let target { h.s(12, target) }
        var d = Data(); d.appendLE(e.rawValue | 0x80000000); d.appendLE(UInt32(h.data.count)); d.append(h.data); d.append(body.data)
        try await ws.send(.data(d))
    }
    private func waitJob(_ job: UInt64, timeout: Double) async throws -> Packet {
        if var q = jobQueue[job], !q.isEmpty { let p = q.removeFirst(); jobQueue[job] = q; return p }
        if let failure { throw failure }
        let timer = Task { try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9)); self.timeoutJob(job) }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { jobWaiters[job] = $0 }
    }
    private func timeoutJob(_ job: UInt64) { jobWaiters.removeValue(forKey: job)?.resume(throwing: StoreError("Steam didn't answer in time")) }
    private func waitEMsg(_ e: EMsg, timeout: Double) async throws -> Packet {
        if let failure { throw failure }
        let timer = Task { try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9)); self.timeoutEMsg(e.rawValue) }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { emsgWaiters[e.rawValue] = $0 }
    }
    private func timeoutEMsg(_ e: UInt32) { emsgWaiters.removeValue(forKey: e)?.resume(throwing: StoreError("Steam didn't answer in time")) }

    /// a request answered with a job reply (the reply's header names our job)
    func call(_ e: EMsg, _ body: PBWriter, timeout: Double = 30) async throws -> Packet {
        let job = nextJob; nextJob += 1
        try await send(e, body, job: job)
        return try await waitJob(job, timeout: timeout)
    }
    /// further replies to the same job (PICS answers in parts)
    func more(_ job: UInt64, timeout: Double = 30) async throws -> Packet { try await waitJob(job, timeout: timeout) }
    func callMulti(_ e: EMsg, _ body: PBWriter, timeout: Double = 30) async throws -> (UInt64, Packet) {
        let job = nextJob; nextJob += 1
        try await send(e, body, job: job)
        return (job, try await waitJob(job, timeout: timeout))
    }
    /// a unified service method ("Authentication.X#1"); returns the reply body or throws Steam's result
    func service(_ method: String, _ body: PBWriter, authed: Bool, timeout: Double = 30) async throws -> PBMessage {
        let job = nextJob; nextJob += 1
        try await send(authed ? .serviceMethodCallFromClient : .serviceMethodCallFromClientNonAuthed, body, job: job, target: method,
                       steamID: authed ? nil : 0, session: authed ? nil : 0)
        let p = try await waitJob(job, timeout: timeout)
        let r = p.header.i32(13) ?? 1
        if r != 1 { throw SteamResult(code: r, message: p.header.s(14)) }
        return try PBMessage(p.body)
    }
    func logOn(_ body: PBWriter, steamID sid: UInt64) async throws -> PBMessage {
        try await send(.clientLogon, body, steamID: sid, session: 0)
        let p = try await waitEMsg(.clientLogOnResponse, timeout: 30)
        let m = try PBMessage(p.body)
        if let c = m.u(7) { cellID = UInt32(c) }
        let r = m.i32(1) ?? 2
        if r == 1 {
            let hb = max(5, Int(m.i32(3) ?? 9))
            heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(hb) * 1_000_000_000)
                    try? await self?.send(.clientHeartBeat, PBWriter())
                }
            }
        }
        return m
    }
}

struct SteamResult: LocalizedError {
    let code: Int32; let message: String?
    var errorDescription: String? {
        switch code {
        case 5: return "Wrong Steam account name or password."
        case 15: return "Steam refused access to this download (does this account own Cyberpunk 2077?)."
        case 63, 65, 88: return "That Steam Guard code wasn't accepted. Try again."
        case 84, 87: return "Steam is rate-limiting sign-ins. Wait a few minutes and try again."
        case 9: return "Steam doesn't know this item (file not found)."
        default: return "Steam answered with result \(code)\(message.map { " (\($0))" } ?? "")."
        }
    }
}

// MARK: - Steam: sign-in, app info, download plan

final class SteamStore: @unchecked Sendable {
    static let shared = SteamStore()
    let cm = SteamCM()
    private var loggedOn = false
    var account: String? { Keychain.load("steam")?["account"] as? String }
    var signedIn: Bool { account != nil }
    private var deviceName: String { "CyPort" }
    private func machineID() -> Data {
        if let s = UserDefaults.standard.string(forKey: "CyPortSteamMachineID") { return Data(s.utf8) }
        var b = [UInt8](repeating: 0, count: 20); _ = SecRandomCopyBytes(kSecRandomDefault, 20, &b)
        let s = b.map { String(format: "%02X", $0) }.joined()
        UserDefaults.standard.set(s, forKey: "CyPortSteamMachineID"); return Data(s.utf8)
    }

    enum Guard { case none, emailCode(String), deviceCode, deviceConfirmation }
    struct PendingLogin { let clientID: UInt64; let requestID: Data; let steamID: UInt64; let interval: Double; let account: String; let guards: [Guard] }

    /// step 1: account + password (RSA-encrypted with Steam's key, never stored)
    func beginLogin(account: String, password: String) async throws -> PendingLogin {
        try await reconnect()
        var kq = PBWriter(); kq.s(1, account)
        let key = try await cm.service("Authentication.GetPasswordRSAPublicKey#1", kq, authed: false)
        guard let mod = key.s(1), let exp = key.s(2), let ts = key.u(3) else { throw StoreError("Steam sent no password key") }
        let enc = try Self.rsaEncrypt(Data(password.utf8), modHex: mod, expHex: exp)
        var b = PBWriter()
        b.s(1, deviceName); b.s(2, account); b.s(3, enc.base64EncodedString()); b.u(4, ts); b.b(5, true)
        b.u(6, 1)                                  // platform: Steam client (tokens that can log on to a CM)
        b.u(7, 1)                                  // persistent session
        b.s(8, "Client")
        var dev = PBWriter(); dev.s(1, deviceName); dev.u(2, 1); dev.i(3, 16); b.msg(9, dev)
        if let g = Keychain.load("steamguard")?[account.lowercased()] as? String { b.s(10, g) }
        let r = try await cm.service("Authentication.BeginAuthSessionViaCredentials#1", b, authed: false)
        guard let cid = r.u(1), let rid = r.data(2), let sid = r.u(5) else { throw StoreError("Steam sign-in: unexpected reply") }
        var guards: [Guard] = []
        for c in r.all(4) {
            let m = try PBMessage(c)
            switch m.u(1) ?? 0 {
            case 1: guards.append(.none)
            case 2: guards.append(.emailCode(m.s(2) ?? "your email"))
            case 3: guards.append(.deviceCode)
            case 4: guards.append(.deviceConfirmation)
            default: break
            }
        }
        storeLog("steam: sign-in started (\(guards.count) confirmation types)")
        return PendingLogin(clientID: cid, requestID: rid, steamID: sid, interval: Double(r.f32(3) ?? 5), account: account, guards: guards)
    }
    /// step 2 (when asked): the Steam Guard code from the email or the Steam app
    func submitCode(_ p: PendingLogin, code: String, email: Bool) async throws {
        var b = PBWriter(); b.u(1, p.clientID); b.fixed64(2, p.steamID); b.s(3, code.trimmingCharacters(in: .whitespaces).uppercased()); b.u(4, email ? 2 : 3)
        _ = try await unauthed("Authentication.UpdateAuthSessionWithSteamGuardCode#1", b)
    }
    /// step 3: wait until Steam hands out the token (code accepted, or approved in the Steam app)
    /// A sign-in session lives at Steam, not in the connection: when iOS suspended the app (the user went to the
    /// Steam app to approve) and the connection died, connect again and carry on with the same session.
    private func unauthed(_ method: String, _ b: PBWriter) async throws -> PBMessage {
        do { return try await cm.service(method, b, authed: false) }
        catch let e as SteamResult { throw e }
        catch {
            storeLog("steam: \(method.split(separator: ".").last ?? "") failed (\(error.localizedDescription)), reconnecting")
            try await reconnect()
            return try await cm.service(method, b, authed: false)
        }
    }
    func poll(_ p: PendingLogin) async throws -> Bool {
        var b = PBWriter(); b.u(1, p.clientID); b.bytes(2, p.requestID)
        let r = try await unauthed("Authentication.PollAuthSessionStatus#1", b)
        guard let refresh = r.s(3), !refresh.isEmpty else { return false }
        let name = r.s(6) ?? p.account
        Keychain.save("steam", ["account": name, "steamid": String(p.steamID), "refresh": refresh])
        if let g = r.s(7), !g.isEmpty { var all = Keychain.load("steamguard") ?? [:]; all[name.lowercased()] = g; Keychain.save("steamguard", all) }
        storeLog("steam: signed in")
        try await logOn()
        return true
    }
    func signOut() { Keychain.delete("steam"); loggedOn = false; Task { await cm.close() } }

    private func reconnect() async throws { await cm.close(); loggedOn = false; try await cm.connect() }
    func logOn() async throws {
        guard let s = Keychain.load("steam"), let name = s["account"] as? String, let refresh = s["refresh"] as? String else { throw StoreError("Sign in to Steam first.") }
        let sid = UInt64(s["steamid"] as? String ?? "") ?? 0x0110_0001_0000_0000
        try await reconnect()
        var b = PBWriter()
        b.u(1, SteamCM.protocolVersion); b.u(3, 0); b.u(5, 1771); b.s(6, "english"); b.u(7, 16); b.b(8, true)
        b.bytes(30, machineID()); b.s(50, name); b.s(96, deviceName); b.b(102, true); b.s(108, refresh)
        let r = try await cm.logOn(b, steamID: sid)
        let res = r.i32(1) ?? 2
        guard res == 1 else {
            if res == 5 || res == 27 || res == 85 || res == 107 { Keychain.delete("steam"); throw StoreError("Your Steam sign-in expired. Sign in again.") }
            throw SteamResult(code: res, message: nil)
        }
        loggedOn = true
        storeLog("steam: logged on")
    }
    /// anonymous logon (Mac test tool: public app info without an account)
    func logOnAnonymous() async throws {
        try await reconnect()
        var b = PBWriter(); b.u(1, SteamCM.protocolVersion); b.u(3, 0); b.s(6, "english"); b.u(7, 16); b.bytes(30, machineID())
        let r = try await cm.logOn(b, steamID: 0x01A0_0000_0000_0000)
        guard (r.i32(1) ?? 2) == 1 else { throw SteamResult(code: r.i32(1) ?? 2, message: nil) }
        loggedOn = true
    }

    static func rsaEncrypt(_ d: Data, modHex: String, expHex: String) throws -> Data {
        guard var mod = Data(hex: modHex), var exp = Data(hex: expHex) else { throw StoreError("bad Steam key") }
        if let f = mod.first, f & 0x80 != 0 { mod.insert(0, at: 0) }
        if let f = exp.first, f & 0x80 != 0 { exp.insert(0, at: 0) }
        func der(_ tag: UInt8, _ body: Data) -> Data {
            var o = Data([tag]); let n = body.count
            if n < 0x80 { o.append(UInt8(n)) } else if n < 0x100 { o.append(contentsOf: [0x81, UInt8(n)]) } else { o.append(contentsOf: [0x82, UInt8(n >> 8), UInt8(n & 0xff)]) }
            return o + body
        }
        let pkcs1 = der(0x30, der(0x02, mod) + der(0x02, exp))
        var err: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(pkcs1 as CFData, [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary, &err),
              let out = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, d as CFData, &err) else { throw StoreError("couldn't encrypt the password") }
        return out as Data
    }

    struct Depot { let id: UInt32; let gid: UInt64; let name: String; let dlc: UInt32? }

    /// the app's Mac depots (base game, owned DLC, English) from Steam's app info
    func macDepots(app: UInt32 = Game.steamApp) async throws -> (depots: [Depot], buildID: String) {
        if !loggedOn { try await logOn() }
        var tq = PBWriter(); tq.u(2, UInt64(app))
        let tr = try PBMessage(try await cm.call(.picsAccessTokenRequest, tq).body)
        var token: UInt64 = 0
        for t in tr.all(3) { let m = try PBMessage(t); if m.u(1) == UInt64(app) { token = m.u(2) ?? 0 } }
        var q = PBWriter(); var a = PBWriter(); a.u(1, UInt64(app)); if token != 0 { a.u(2, token) }; q.msg(2, a); q.b(7, true)
        let (job, first) = try await cm.callMulti(.picsProductInfoRequest, q, timeout: 60)
        var buffer: Data?, p = first
        while true {
            let m = try PBMessage(p.body)
            for x in m.all(1) { let am = try PBMessage(x); if am.u(1) == UInt64(app), let b = am.data(5) { buffer = b } }
            if m.u(6) ?? 0 == 0 || buffer != nil { break }
            p = try await cm.more(job, timeout: 60)
        }
        guard let buf = buffer else { throw StoreError("Steam sent no app info for Cyberpunk 2077") }
        let root = KV.parse(String(decoding: buf, as: UTF8.self))
        let info = root["appinfo"] ?? root.children.first?.1 ?? root
        guard let depots = info["depots"] else { throw StoreError("Steam app info has no depots") }
        let build = depots["branches"]?["public"]?["buildid"]?.string ?? "?"
        var out: [Depot] = []
        for (k, d) in depots.children {
            guard let id = UInt32(k) else { continue }
            let cfg = d["config"]
            let os = (cfg?["oslist"]?.string ?? "").lowercased()
            let lang = (cfg?["language"]?.string ?? "").lowercased()
            guard os.split(separator: ",").contains("macos") else { continue }
            guard lang.isEmpty || lang == "english" else { continue }
            guard d["depotfromapp"] == nil else { continue }
            guard (cfg?["lowviolence"]?.string ?? "0") != "1" else { continue }
            let pub = d["manifests"]?["public"]
            guard let gs = pub?["gid"]?.string ?? pub?.string, let gid = UInt64(gs) else { continue }
            out.append(Depot(id: id, gid: gid, name: d["name"]?.string ?? k, dlc: d["dlcappid"]?.string.flatMap { UInt32($0) }))
        }
        storeLog("steam: Mac depots \(out.map { "\($0.id)\($0.dlc != nil ? "(dlc)" : "")" }.joined(separator: ",")), build \(build)")
        guard !out.isEmpty else { throw StoreError("Steam lists no Mac download for Cyberpunk 2077.") }
        return (out, build)
    }

    struct Server { let host: String }
    func servers() async throws -> [Server] {
        var b = PBWriter(); b.u(1, UInt64(await cm.cellID)); b.u(2, 20)
        let r = try await cm.service("ContentServerDirectory.GetServersForSteamPipe#1", b, authed: true)
        var out: [(Server, UInt64, Float)] = []
        for x in r.all(1) {
            let m = try PBMessage(x)
            let type = m.s(1) ?? "", https = m.s(12) ?? ""
            guard type == "SteamCache" || type == "CDN", https != "unavailable", let v = m.s(9) ?? m.s(8) else { continue }
            if let allowed = m.fields[13], !allowed.isEmpty {
                let ids = allowed.compactMap { if case .varint(let v) = $0 { return v }; return nil }
                if !ids.isEmpty && !ids.contains(UInt64(Game.steamApp)) { continue }
            }
            out.append((Server(host: v), m.u(15) ?? 0, m.f32(5) ?? 0))
        }
        out.sort { ($0.1, $0.2) < ($1.1, $1.2) }
        guard !out.isEmpty else { throw StoreError("Steam gave no download server") }
        return out.map(\.0)
    }

    /// the whole download: every owned Mac depot's files, chunk by chunk
    func plan(progress: @escaping (String) -> Void) async throws -> DLPlan {
        let (depots, build) = try await macDepots()
        let servers = try await servers()
        storeLog("steam: \(servers.count) download servers")
        struct ChunkRef { let depot: UInt32; let sha: Data; let crc: UInt32; let size: Int; let csize: Int }
        var chunks: [ChunkRef] = [], index: [Data: Int] = [:], files: [DLFile] = [], keys: [UInt32: Data] = [:]
        var ownedAny = false
        for d in depots {
            progress("Reading Steam depot \(d.id)…")
            var kb = PBWriter(); kb.u(1, UInt64(d.id)); kb.u(2, UInt64(Game.steamApp))
            let kr = try PBMessage(try await cm.call(.clientGetDepotDecryptionKey, kb).body)
            guard (kr.i32(1) ?? 2) == 1, let key = kr.data(3), key.count == 32 else {
                storeLog("steam: depot \(d.id) not available to this account (result \(kr.i32(1) ?? 2))"); continue
            }
            keys[d.id] = key; if d.dlc == nil { ownedAny = true }
            var cb = PBWriter(); cb.u(1, UInt64(Game.steamApp)); cb.u(2, UInt64(d.id)); cb.u(3, d.gid); cb.s(4, "public")
            let code = try await cm.service("ContentServerDirectory.GetManifestRequestCode#1", cb, authed: true).u(1) ?? 0
            var manifest: Data?
            var last: Error = StoreError("no server")
            for s in servers.prefix(4) {
                do {
                    let url = URL(string: "https://\(s.host)/depot/\(d.id)/manifest/\(d.gid)/5\(code != 0 ? "/\(code)" : "")")!
                    manifest = try Zip.firstEntry(try await Net.request(url)); break
                } catch { last = error }
            }
            guard let raw = manifest else { throw last }
            for f in try Self.parseManifest(raw, key: key) {
                var parts: [DLPart] = []
                for c in f.chunks.sorted(by: { $0.offset < $1.offset }) {
                    let k: Int
                    if let have = index[c.sha] { k = have } else {
                        k = chunks.count; index[c.sha] = k
                        chunks.append(ChunkRef(depot: d.id, sha: c.sha, crc: c.crc, size: c.size, csize: c.csize))
                    }
                    parts.append(DLPart(chunk: k, offset: 0, length: c.size))
                }
                files.append(DLFile(path: f.path, size: f.size, parts: parts))
            }
        }
        guard ownedAny else { throw StoreError("This Steam account doesn't own Cyberpunk 2077 (Steam refused the download key).") }
        let picked = try GameFiles.pick(files)
        let refs = chunks, ks = keys, hosts = servers.map(\.host)
        let counter = Counter()
        return DLPlan(files: picked, chunkCount: refs.count, version: "steam-\(build)", versionName: "Steam build \(build)", fetch: { i in
            let c = refs[i]; var last: Error = StoreError("chunk")
            for attempt in 0..<6 {
                let host = hosts[(counter.next() + attempt) % hosts.count]
                do {
                    let enc = try await Net.request(URL(string: "https://\(host)/depot/\(c.depot)/chunk/\(c.sha.hex)")!, tries: 1)
                    let plain = try Self.decodeChunk(enc, key: ks[c.depot]!, size: c.size)
                    guard Hash.steamAdler(plain) == c.crc else { throw StoreError("chunk checksum mismatch") }
                    return plain
                } catch is CancellationError { throw CancellationError() } catch { last = error }
                try await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
            }
            throw last
        })
    }

    struct MFile { let path: String; let size: Int64; let chunks: [(sha: Data, crc: UInt32, offset: UInt64, size: Int, csize: Int)] }
    static func parseManifest(_ d: Data, key: Data) throws -> [MFile] {
        var at = 0, payload: Data?, encrypted = false
        while at + 8 <= d.count {
            let magic = d.u32(at), n = Int(d.u32(at + 4)); at += 8
            if magic == 0x32C415AB { break }
            guard at + n <= d.count else { throw StoreError("Steam manifest truncated") }
            let sec = d.subdata(in: at..<(at + n)); at += n
            if magic == 0x71F617D0 { payload = sec }
            if magic == 0x1F4812BE { encrypted = (try PBMessage(sec).u(4) ?? 0) != 0 }
        }
        guard let pl = payload else { throw StoreError("Steam manifest has no file list") }
        var out: [MFile] = []
        for m in try PBMessage(pl).all(1) {
            let f = try PBMessage(m)
            let flags = f.u(3) ?? 0
            if flags & 64 != 0 { continue }                               // folder
            guard var name = f.s(1) else { continue }
            if encrypted {
                guard let raw = Data(base64Encoded: name.filter { !$0.isWhitespace }) else { throw StoreError("Steam manifest: bad file name") }
                name = String(decoding: try AES.steamDecrypt(raw, key: key), as: UTF8.self)
                while name.hasSuffix("\0") { name.removeLast() }
            }
            if f.s(7).map({ !$0.isEmpty }) ?? false { continue }           // symlink
            name = name.replacingOccurrences(of: "\\", with: "/")
            var cs: [(Data, UInt32, UInt64, Int, Int)] = []
            for c in f.all(6) {
                let cm = try PBMessage(c)
                guard let sha = cm.data(1), sha.count == 20 else { continue }
                cs.append((sha, UInt32(cm.u(2) ?? 0), cm.u(3) ?? 0, Int(cm.u(4) ?? 0), Int(cm.u(5) ?? 0)))
            }
            out.append(MFile(path: name, size: Int64(f.u(2) ?? 0), chunks: cs))
        }
        return out
    }
    static func decodeChunk(_ enc: Data, key: Data, size: Int) throws -> Data {
        let b = try AES.steamDecrypt(enc, key: key)
        guard b.count >= 16 else { throw StoreError("chunk too short") }
        let h = [UInt8](b.prefix(4))
        var out = Data(count: size)
        if h == [0x56, 0x53, 0x5A, 0x61] {                                // VSZa: zstd
            guard b.count >= 23, b[b.endIndex - 3] == 0x7A, b[b.endIndex - 2] == 0x73, b[b.endIndex - 1] == 0x76 else { throw StoreError("zstd chunk footer") }
            let src = b.subdata(in: (b.startIndex + 8)..<(b.endIndex - 15))
            let n = out.withUnsafeMutableBytes { o in src.withUnsafeBytes { ms_zstd_decode($0.bindMemory(to: UInt8.self).baseAddress!, src.count, o.bindMemory(to: UInt8.self).baseAddress!, size) } }
            guard n == size else { throw StoreError("zstd chunk failed") }
            return out
        }
        if h[0] == 0x56 && h[1] == 0x5A && h[2] == 0x61 {                // VZa: LZMA
            let d = Data(b)
            guard d.count >= 22, d[d.count - 2] == 0x7A, d[d.count - 1] == 0x76 else { throw StoreError("lzma chunk footer") }
            let props = d.subdata(in: 7..<12), src = d.subdata(in: 12..<(d.count - 10))
            let n = out.withUnsafeMutableBytes { o in src.withUnsafeBytes { s in props.withUnsafeBytes { p in
                ms_lzma_decode(p.bindMemory(to: UInt8.self).baseAddress!, s.bindMemory(to: UInt8.self).baseAddress!, src.count, o.bindMemory(to: UInt8.self).baseAddress!, size) } } }
            guard n == size else { throw StoreError("lzma chunk failed") }
            return out
        }
        if h == [0x50, 0x4B, 0x03, 0x04] { return try Zip.firstEntry(Data(b)) }
        throw StoreError("unknown chunk format")
    }
}

final class Counter: @unchecked Sendable {
    private var n = 0; private let l = NSLock()
    func next() -> Int { l.lock(); defer { l.unlock() }; n &+= 1; return n & 0x7fffffff }
}

// MARK: - GOG

final class GOGStore: @unchecked Sendable {
    static let shared = GOGStore()
    static let clientID = "46899977096215655"
    static let clientSecret = "9d85c43b1482497dbbce61f6e4aa173a433796eeae2ca8c5f6129f2dc4de46d9"
    static let redirect = "https://embed.gog.com/on_login_success?origin=client"
    static var loginURL: URL {
        var c = URLComponents(string: "https://auth.gog.com/auth")!
        c.queryItems = [.init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: redirect),
                        .init(name: "response_type", value: "code"), .init(name: "layout", value: "client2")]
        return c.url!
    }
    /// the code in the page the login lands on, or nil
    static func code(from url: URL) -> String? {
        guard url.host == "embed.gog.com", url.path == "/on_login_success" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "code" }?.value
    }
    var signedIn: Bool { Keychain.load("gog") != nil }
    var account: String? { Keychain.load("gog")?["name"] as? String }

    private func token(_ grant: [String: String]) async throws {
        var c = URLComponents(string: "https://auth.gog.com/token")!
        c.queryItems = ([("client_id", Self.clientID), ("client_secret", Self.clientSecret)] + grant.map { ($0.key, $0.value) }).map { URLQueryItem(name: $0.0, value: $0.1) }
        let o = try await Net.json(c.url!)
        guard let a = o["access_token"] as? String, let r = o["refresh_token"] as? String else { throw StoreError("GOG sign-in failed") }
        var t: [String: Any] = ["access": a, "refresh": r, "expires": Date().timeIntervalSince1970 + ((o["expires_in"] as? Double) ?? 3600)]
        if let n = Keychain.load("gog")?["name"] { t["name"] = n }
        Keychain.save("gog", t)
    }
    func signIn(code: String) async throws {
        try await token(["grant_type": "authorization_code", "code": code, "redirect_uri": Self.redirect])
        if let u = try? await Net.json(URL(string: "https://embed.gog.com/userData.json")!, headers: try await auth()), let n = u["username"] as? String {
            var t = Keychain.load("gog") ?? [:]; t["name"] = n; Keychain.save("gog", t)
        }
        storeLog("gog: signed in")
    }
    func signOut() { Keychain.delete("gog") }
    func auth() async throws -> [String: String] {
        guard let t = Keychain.load("gog"), let r = t["refresh"] as? String else { throw StoreError("Sign in to GOG first.") }
        if (t["expires"] as? Double ?? 0) - Date().timeIntervalSince1970 < 300 {
            do { try await token(["grant_type": "refresh_token", "refresh_token": r]) }
            catch { Keychain.delete("gog"); throw StoreError("Your GOG sign-in expired. Sign in again.") }
        }
        return ["Authorization": "Bearer \(Keychain.load("gog")?["access"] as? String ?? "")"]
    }
    func owned() async throws -> Set<String> {
        let o = try await Net.json(URL(string: "https://embed.gog.com/user/data/games")!, headers: try await auth())
        return Set((o["owned"] as? [Any] ?? []).map { "\($0)" })
    }

    struct Build { let id: String; let version: String; let date: String; let link: URL }
    /// the Mac builds, newest first
    func builds() async throws -> [Build] {
        let o = try await Net.json(URL(string: "https://content-system.gog.com/products/\(Game.gogProduct)/os/osx/builds?generation=2")!)
        return (o["items"] as? [[String: Any]] ?? []).compactMap { i in
            guard let l = i["link"] as? String, let u = URL(string: l) else { return nil }
            return Build(id: "\(i["build_id"] ?? "")", version: i["version_name"] as? String ?? "?", date: String((i["date_published"] as? String ?? "").prefix(10)), link: u)
        }
    }
    /// the build matching the app's executable, else the newest
    static func preferred(_ b: [Build]) -> Build? {
        let want = Game.versionDigits(Game.appVersion)
        return b.first { Game.versionDigits($0.version) == want } ?? b.first
    }
    static func meta(_ d: Data) throws -> [String: Any] {
        let raw = (d.first == UInt8(ascii: "{")) ? d : try Inflate.run(d)
        guard let o = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else { throw StoreError("GOG: unexpected data") }
        return o
    }

    func plan(build: Build, progress: @escaping (String) -> Void) async throws -> DLPlan {
        let owned = try await owned()
        guard owned.contains(Game.gogProduct) else { throw StoreError("This GOG account doesn't own Cyberpunk 2077.") }
        progress("Reading the GOG build…")
        let b = try Self.meta(try await Net.request(build.link))
        let depots = (b["depots"] as? [[String: Any]] ?? []).filter { d in
            let langs = d["languages"] as? [String] ?? ["*"], pid = "\(d["productId"] ?? "")"
            return (d["isGogDepot"] as? Bool) != true && (langs.contains("*") || langs.contains("en-US") || langs.contains("en"))
                && (pid == Game.gogProduct || owned.contains(pid))
        }
        struct ChunkRef { let product: String; let cmd5: String; let md5: String; let size: Int; let csize: Int }
        var chunks: [ChunkRef] = [], files: [DLFile] = []
        let host = build.link.host ?? "gog-cdn-fastly.gog.com"
        for d in depots {
            guard let m = d["manifest"] as? String, m.count > 4 else { continue }
            let pid = "\(d["productId"] ?? "")"
            progress("Reading GOG depot \(m.prefix(8))…")
            let mu = URL(string: "https://\(host)/content-system/v2/meta/\(m.prefix(2))/\(m.dropFirst(2).prefix(2))/\(m)")!
            let dm = try Self.meta(try await Net.request(mu))
            for it in ((dm["depot"] as? [String: Any])?["items"] as? [[String: Any]] ?? []) where (it["type"] as? String) == "DepotFile" {
                guard let path = it["path"] as? String else { continue }
                var parts: [DLPart] = [], size: Int64 = 0
                for c in it["chunks"] as? [[String: Any]] ?? [] {
                    guard let cm = c["compressedMd5"] as? String, let md = c["md5"] as? String,
                          let s = (c["size"] as? NSNumber)?.intValue, let cs = (c["compressedSize"] as? NSNumber)?.intValue else { continue }
                    parts.append(DLPart(chunk: chunks.count, offset: 0, length: s)); size += Int64(s)
                    chunks.append(ChunkRef(product: pid, cmd5: cm, md5: md, size: s, csize: cs))
                }
                files.append(DLFile(path: path.replacingOccurrences(of: "\\", with: "/"), size: size, parts: parts))
            }
        }
        let picked = try GameFiles.pick(files)
        let refs = chunks, links = GOGLinks(store: self)
        return DLPlan(files: picked, chunkCount: refs.count, version: "gog-\(build.id)", versionName: build.version, fetch: { i in
            let c = refs[i]; var last: Error = StoreError("chunk")
            for attempt in 0..<5 {
                do {
                    let url = try await links.url(product: c.product, path: "/\(c.cmd5.prefix(2))/\(c.cmd5.dropFirst(2).prefix(2))/\(c.cmd5)", renew: attempt > 1)
                    let z = try await Net.request(url, tries: 1)
                    guard Hash.md5(z).hex == c.cmd5 else { throw StoreError("GOG chunk damaged in transit") }
                    let plain = try Inflate.run(z, expected: c.size)
                    guard plain.count == c.size, Hash.md5(plain).hex == c.md5 else { throw StoreError("GOG chunk doesn't match its checksum") }
                    return plain
                } catch is CancellationError { throw CancellationError() } catch { last = error }
                try await Task.sleep(nanoseconds: UInt64(attempt) * 700_000_000)
            }
            throw last
        })
    }
}

/// GOG's signed CDN links: one per product, renewed before they expire
actor GOGLinks {
    let store: GOGStore
    private var links: [String: (format: String, params: [String: String], expires: Double)] = [:]
    init(store: GOGStore) { self.store = store }
    func url(product: String, path: String, renew: Bool) async throws -> URL {
        if renew || links[product] == nil || links[product]!.expires - Date().timeIntervalSince1970 < 120 {
            let u = URL(string: "https://content-system.gog.com/products/\(product)/secure_link?generation=2&_version=2&path=/")!
            let o = try await Net.json(u, headers: try await store.auth())
            let eps = (o["urls"] as? [[String: Any]] ?? []).filter { !(($0["fallback_only"] as? Bool) ?? false) }
                .sorted { ($0["priority"] as? Int ?? 0) > ($1["priority"] as? Int ?? 0) }
            guard let e = eps.first ?? (o["urls"] as? [[String: Any]])?.first, let f = e["url_format"] as? String,
                  let p = e["parameters"] as? [String: Any] else { throw StoreError("GOG gave no download link (do you own the game?)") }
            links[product] = (f, p.mapValues { "\($0)" }, (p["expires_at"] as? Double) ?? Date().timeIntervalSince1970 + 3000)
        }
        let l = links[product]!
        var p = l.params; p["path"] = (p["path"] ?? "") + path
        var s = l.format.contains("{path}") ? l.format : l.format + "{path}"
        for (k, v) in p { s = s.replacingOccurrences(of: "{\(k)}", with: v) }
        guard let u = URL(string: s) else { throw StoreError("GOG download link format changed") }
        return u
    }
}

// MARK: - Epic

final class EpicStore: @unchecked Sendable {
    static let shared = EpicStore()
    static let clientID = "34a02cf8f4414e29b15921876da36f9a", clientSecret = "daafbccc737745039dffe53d94fc76cf"
    static let userAgent = "UELauncher/11.0.1-14907503+++Portal+Release-Live Windows/10.0.19041.1.256.64bit"
    static var redirectURL: URL { URL(string: "https://www.epicgames.com/id/api/redirect?clientId=\(clientID)&responseType=code")! }
    static var loginURL: URL {
        var c = URLComponents(string: "https://www.epicgames.com/id/login")!
        c.queryItems = [.init(name: "redirectUrl", value: redirectURL.absoluteString)]
        return c.url!
    }
    static func isRedirect(_ u: URL) -> Bool { u.host == "www.epicgames.com" && u.path == "/id/api/redirect" }
    /// the code from the redirect page's JSON (or pasted by hand)
    static func code(fromPage s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let o = try? JSONSerialization.jsonObject(with: Data(t.utf8)) as? [String: Any], let c = o["authorizationCode"] as? String, !c.isEmpty { return c }
        if t.count == 32, t.allSatisfy({ $0.isHexDigit }) { return t }
        return nil
    }
    var signedIn: Bool { Keychain.load("epic") != nil }
    var account: String? { Keychain.load("epic")?["name"] as? String }

    private func token(_ form: [String: String]) async throws {
        var f = form; f["token_type"] = "eg1"
        let basic = Data("\(Self.clientID):\(Self.clientSecret)".utf8).base64EncodedString()
        let o = try await Net.json(URL(string: "https://account-public-service-prod03.ol.epicgames.com/account/api/oauth/token")!, method: "POST",
                                   headers: ["Authorization": "basic \(basic)", "Content-Type": "application/x-www-form-urlencoded", "User-Agent": Self.userAgent],
                                   body: Net.form(f))
        guard let a = o["access_token"] as? String, let r = o["refresh_token"] as? String else { throw StoreError("Epic sign-in failed") }
        Keychain.save("epic", ["access": a, "refresh": r, "expires": Date().timeIntervalSince1970 + ((o["expires_in"] as? Double) ?? 7200),
                               "name": o["displayName"] as? String ?? "Epic account", "accountID": o["account_id"] as? String ?? ""])
    }
    func signIn(code: String) async throws { try await token(["grant_type": "authorization_code", "code": code]); storeLog("epic: signed in") }
    func signOut() { Keychain.delete("epic") }
    /// the signed-in account's id (older sign-ins didn't keep it: asked for once)
    func accountID() async throws -> String {
        let h = try await auth()
        if let a = Keychain.load("epic")?["accountID"] as? String, !a.isEmpty { return a }
        let o = try await Net.json(URL(string: "https://account-public-service-prod03.ol.epicgames.com/account/api/oauth/verify")!, headers: h)
        guard let a = o["account_id"] as? String else { throw StoreError("Epic didn't say which account this is.") }
        var t = Keychain.load("epic") ?? [:]; t["accountID"] = a; Keychain.save("epic", t)
        return a
    }
    func auth() async throws -> [String: String] {
        guard let t = Keychain.load("epic"), let r = t["refresh"] as? String else { throw StoreError("Sign in to Epic first.") }
        if (t["expires"] as? Double ?? 0) - Date().timeIntervalSince1970 < 300 {
            do { try await token(["grant_type": "refresh_token", "refresh_token": r]) }
            catch { Keychain.delete("epic"); throw StoreError("Your Epic sign-in expired. Sign in again.") }
        }
        return ["Authorization": "bearer \(Keychain.load("epic")?["access"] as? String ?? "")", "User-Agent": Self.userAgent]
    }

    struct Item { let app: String; let ns: String; let catalog: String; let title: String }
    /// Cyberpunk 2077 and its DLC in the account's library
    func ownedItems() async throws -> [Item] {
        var recs: [[String: Any]] = [], cursor: String?, pages = 0
        repeat {
            var c = URLComponents(string: "https://library-service.live.use1a.on.epicgames.com/library/api/public/items")!
            c.queryItems = [.init(name: "includeMetadata", value: "true")] + (cursor.map { [.init(name: "cursor", value: $0)] } ?? [])
            let o = try await Net.json(c.url!, headers: try await auth())
            recs += o["records"] as? [[String: Any]] ?? []
            cursor = (o["responseMetadata"] as? [String: Any])?["nextCursor"] as? String
            pages += 1
        } while cursor != nil && pages < 100
        var out: [Item] = []
        for (ns, group) in Dictionary(grouping: recs.filter { ($0["namespace"] as? String ?? "ue") != "ue" }, by: { $0["namespace"] as? String ?? "" }) {
            var c = URLComponents(string: "https://catalog-public-service-prod06.ol.epicgames.com/catalog/api/shared/namespace/\(ns)/bulk/items")!
            c.queryItems = Set(group.compactMap { $0["catalogItemId"] as? String }).sorted().map { .init(name: "id", value: $0) }
                + [.init(name: "country", value: "US"), .init(name: "locale", value: "en-US"), .init(name: "includeMainGameDetails", value: "true")]
            guard let items = try? await Net.json(c.url!, headers: try await auth()) else { continue }
            for r in group {
                guard let cid = r["catalogItemId"] as? String, let app = r["appName"] as? String, let it = items[cid] as? [String: Any],
                      let title = it["title"] as? String, title.lowercased().contains(Game.epicTitle) else { continue }
                out.append(Item(app: app, ns: ns, catalog: cid, title: title))
            }
        }
        storeLog("epic: owned items \(out.map(\.title))")
        return out
    }

    struct Asset { let version: String; let manifests: [(URL, URL)]; let sha1: String? }
    func macAsset(_ i: Item) async throws -> Asset {
        let u = URL(string: "https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/public/assets/v2/platform/Mac/namespace/\(i.ns)/catalogItem/\(i.catalog)/app/\(i.app)/label/Live")!
        let o = try await Net.json(u, headers: try await auth())
        guard let e = (o["elements"] as? [[String: Any]])?.first, let ms = e["manifests"] as? [[String: Any]] else { throw StoreError("Epic lists no Mac download for \(i.title).") }
        let urls: [(URL, URL)] = ms.compactMap { m in
            guard let s = m["uri"] as? String, var c = URLComponents(string: s) else { return nil }
            c.query = nil; guard let base = c.url?.deletingLastPathComponent() else { return nil }
            if let q = m["queryParams"] as? [[String: String]], !q.isEmpty { c.queryItems = q.map { URLQueryItem(name: $0["name"] ?? "", value: $0["value"]) } }
            return c.url.map { ($0, base) }
        }
        return Asset(version: e["buildVersion"] as? String ?? "?", manifests: urls, sha1: e["hash"] as? String)
    }

    func plan(progress: @escaping (String) -> Void) async throws -> DLPlan {
        let items = try await ownedItems()
        guard !items.isEmpty else { throw StoreError("This Epic account doesn't own Cyberpunk 2077.") }
        struct ChunkRef { let url: URL; let guid: Data; let sha1: Data; let window: Int }
        var chunks: [ChunkRef] = [], files: [DLFile] = [], version = ""
        // base game first, DLC after it (a DLC file replaces the base game's)
        for it in items.sorted(by: { $0.title.count < $1.title.count }) {
            progress("Reading \(it.title) from Epic…")
            let a: Asset
            do { a = try await macAsset(it) } catch { storeLog("epic: \(it.title): \(error.localizedDescription)"); if it.title.lowercased() == Game.epicTitle { throw error }; continue }
            if version.isEmpty { version = a.version }
            var raw: Data?, base: URL?, last: Error = StoreError("no manifest")
            for (m, b) in a.manifests {
                do {
                    let d = try await Net.request(m)
                    if let h = a.sha1, h.count == 40, Hash.sha1(d).hex != h.lowercased() { throw StoreError("Epic manifest damaged") }
                    raw = d; base = b; break
                } catch { last = error }
            }
            guard let man = raw, let b = base else { throw last }
            let m = try EpicManifest(man)
            var idx: [Int: Int] = [:]
            for f in m.files where f.link.isEmpty {
                var parts: [DLPart] = []
                for p in f.parts {
                    let k: Int
                    if let have = idx[p.chunk] { k = have } else {
                        let c = m.chunks[p.chunk]; k = chunks.count; idx[p.chunk] = k
                        chunks.append(ChunkRef(url: b.appendingPathComponent(m.path(c)), guid: c.guid, sha1: c.sha1, window: c.window))
                    }
                    parts.append(DLPart(chunk: k, offset: p.offset, length: p.size))
                }
                files.append(DLFile(path: f.path, size: parts.reduce(0) { $0 + Int64($1.length) }, parts: parts))
            }
        }
        let picked = try GameFiles.pick(files)
        let refs = chunks
        return DLPlan(files: picked, chunkCount: refs.count, version: "epic-\(version)", versionName: version, fetch: { i in
            let c = refs[i]; var last: Error = StoreError("chunk")
            for attempt in 0..<5 {
                do { return try EpicManifest.decodeChunk(try await Net.request(c.url, headers: ["User-Agent": EpicStore.userAgent], tries: 1), guid: c.guid, sha1: c.sha1, window: c.window) }
                catch is CancellationError { throw CancellationError() } catch { last = error }
                try await Task.sleep(nanoseconds: UInt64(attempt) * 700_000_000)
            }
            throw last
        })
    }
}

/// Epic's binary manifest (header + zlib body: meta, chunk list, file list)
struct EpicManifest {
    struct Chunk { let guid: Data; let hash: UInt64; let sha1: Data; let group: UInt8; let window: Int }
    struct Part { let chunk: Int; let offset: Int; let size: Int }
    struct File { let path: String; let link: String; let parts: [Part] }
    var featureLevel: UInt32 = 0, chunks: [Chunk] = [], files: [File] = []
    /// kept so a new manifest can be written like this one (cloud saves): header version, meta and custom-field sections
    var version: UInt32 = 0, rawMeta = Data(), rawCustom = Data()

    struct R {
        let d: Data; var at = 0
        mutating func need(_ n: Int) throws { guard n >= 0, at + n <= d.count else { throw StoreError("Epic manifest truncated") } }
        mutating func u8() throws -> UInt8 { try need(1); defer { at += 1 }; return d[d.startIndex + at] }
        mutating func u32() throws -> UInt32 { try need(4); defer { at += 4 }; return d.u32(at) }
        mutating func u64() throws -> UInt64 { try need(8); defer { at += 8 }; return d.u64(at) }
        mutating func bytes(_ n: Int) throws -> Data { try need(n); defer { at += n }; return d.subdata(in: at..<(at + n)) }
        mutating func count() throws -> Int { let n = Int(try u32()); guard n <= d.count else { throw StoreError("Epic manifest: bad count") }; return n }
        mutating func str() throws -> String {
            let n = Int(Int32(bitPattern: try u32()))
            if n == 0 { return "" }
            if n > 0 { return String(decoding: try bytes(n).dropLast(), as: UTF8.self) }
            let b = try bytes(-n * 2)
            let units = stride(from: 0, to: b.count - 2, by: 2).map { UInt16(b[$0]) | UInt16(b[$0 + 1]) << 8 }
            return String(decoding: units, as: UTF16.self)
        }
        mutating func seek(_ start: Int, _ size: Int) throws { guard start + size <= d.count, start + size >= at else { throw StoreError("Epic manifest: bad section") }; at = start + size }
    }

    init(_ raw: Data) throws {
        let data = Data([UInt8](raw))
        guard data.count > 41, data.u32(0) == 0x44BEC00C else {
            throw StoreError(data.first == UInt8(ascii: "{") ? "Epic sent an old-style (JSON) manifest, which CyPort can't read yet." : "Epic manifest unreadable")
        }
        let hs = Int(data.u32(4)), plain = Int(data.u32(8)), stored = Int(data.u32(12)), sha = data.subdata(in: 16..<36), how = data[36]
        guard how & 2 == 0 else { throw StoreError("Epic manifest is encrypted") }
        guard hs + stored <= data.count else { throw StoreError("Epic manifest truncated") }
        var body = data.subdata(in: hs..<(hs + stored))
        if how & 1 != 0 { body = try Inflate.run(body, expected: plain) }
        guard Hash.sha1(body) == sha else { throw StoreError("Epic manifest damaged") }
        if hs >= 41 { version = data.u32(37) }
        var r = R(d: body)
        // meta
        var start = r.at, size = Int(try r.u32())
        _ = try r.u8(); featureLevel = try r.u32()
        try r.seek(start, size)
        rawMeta = body.subdata(in: start..<(start + size))
        // chunk list
        start = r.at; size = Int(try r.u32()); _ = try r.u8()
        let nc = try r.count()
        let guids = try (0..<nc).map { _ in try r.bytes(16) }, hashes = try (0..<nc).map { _ in try r.u64() }
        let shas = try (0..<nc).map { _ in try r.bytes(20) }, groups = try (0..<nc).map { _ in try r.u8() }
        let windows = try (0..<nc).map { _ in Int(try r.u32()) }
        _ = try (0..<nc).map { _ in try r.u64() }                      // compressed file sizes
        try r.seek(start, size)
        var byGUID: [Data: Int] = [:]
        for i in 0..<nc { byGUID[guids[i]] = i; chunks.append(Chunk(guid: guids[i], hash: hashes[i], sha1: shas[i], group: groups[i], window: windows[i])) }
        // file list
        start = r.at; size = Int(try r.u32()); _ = try r.u8()
        let fileListEnd = start + size
        let nf = try r.count()
        let names = try (0..<nf).map { _ in try r.str() }, links = try (0..<nf).map { _ in try r.str() }
        _ = try (0..<nf).map { _ in try r.bytes(20) }; _ = try (0..<nf).map { _ in try r.u8() }
        _ = try (0..<nf).map { _ in try (0..<r.count()).map { _ in try r.str() } }
        for i in 0..<nf {
            var parts: [Part] = []
            for _ in 0..<(try r.count()) {
                let ps = r.at, psize = Int(try r.u32())
                let g = try r.bytes(16), off = Int(try r.u32()), len = Int(try r.u32())
                try r.seek(ps, psize)
                guard let k = byGUID[g], off + len <= chunks[k].window else { throw StoreError("Epic manifest: file part outside its chunk") }
                parts.append(Part(chunk: k, offset: off, size: len))
            }
            files.append(File(path: names[i].replacingOccurrences(of: "\\", with: "/"), link: links[i], parts: parts))
        }
        if fileListEnd < body.count { rawCustom = body.subdata(in: fileListEnd..<body.count) }
    }
    func path(_ c: Chunk) -> String {
        let dir = featureLevel >= 15 ? "ChunksV4" : featureLevel >= 6 ? "ChunksV3" : featureLevel >= 3 ? "ChunksV2" : "Chunks"
        let g = stride(from: 0, to: 16, by: 4).map { String(format: "%08X", c.guid.u32($0)) }.joined()
        return "\(dir)/" + String(format: "%02d/%016llX_", Int(c.group), c.hash) + g + ".chunk"
    }
    static func decodeChunk(_ d: Data, guid: Data, sha1: Data, window: Int) throws -> Data {
        guard d.count >= 41, d.u32(0) == 0xB1FE3AA2 else { throw StoreError("Epic chunk unreadable") }
        let hs = Int(d.u32(8)), stored = Int(d.u32(12))
        guard d.subdata(in: 16..<32) == guid else { throw StoreError("Epic sent the wrong chunk") }
        let how = d[40]
        guard how & 2 == 0 else { throw StoreError("Epic chunk is encrypted") }
        guard hs + stored <= d.count else { throw StoreError("Epic chunk truncated") }
        var body = d.subdata(in: hs..<(hs + stored))
        if how & 1 != 0 { body = try Inflate.run(body, expected: window) }
        guard body.count == window, Hash.sha1(body) == sha1 else { throw StoreError("Epic chunk doesn't match its checksum") }
        return body
    }
}
