// GameCloud.swift - "Cloud saves" on the start screen: sign in with the store you play Cyberpunk on (GOG, Steam or
// Epic) and the phone's saves are kept in step with that store's cloud, so you carry on where you were - on the phone
// and, for GOG, back on the computer too.
// Sync is per save slot (AutoSave-3, ManualSave-0, ...): the cloud's copy comes to the phone first; after that the side
// that changed since the last sync wins (both changed: the newer one). A phone slot that gets replaced is moved to
// saves-backup-<date> first.
// GOG: what GOG Galaxy does on a computer - your account sign-in is traded for a sign-in of the game's own client
// (its credentials are read from the game's executable at runtime, never stored in this source) and the game's
// "saves" folder on cloudstorage.gog.com is read and written. Steam: Steam Cloud through the Steam connection (the
// upload steps the Steam client uses). Epic: Epic cloud saves - each upload is a manifest (snapshot of the save folder)
// plus its chunks, written like the newest one already in the cloud. Before the first upload to a store, everything it
// has is copied to Application Support/CyPort/cloud-backup-<store>-<date>.
import Foundation
import Security
import UIKit
import zlib

/// one save file in a cloud: "ManualSave-3/sav.dat", when it was saved there, and how to download it
struct CloudFile {
    let rel: String
    let modified: Date
    /// the store's own name for it (Steam), when it differs from rel
    var remote: String? = nil
    let fetch: () async throws -> Data
}

enum CloudSource: String, CaseIterable, Identifiable {
    case gog = "GOG", steam = "Steam", epic = "Epic"
    var id: String { rawValue }
    var store: StoreKind { switch self { case .gog: return .gog; case .steam: return .steam; case .epic: return .epic } }
    var signedIn: Bool { store.signedIn }
    var account: String? {
        switch self { case .gog: return GOGStore.shared.account; case .steam: return SteamStore.shared.account; case .epic: return EpicStore.shared.account }
    }
    var canSend: Bool { true }
    func signOut() {
        switch self { case .gog: GOGStore.shared.signOut(); case .steam: SteamStore.shared.signOut(); case .epic: EpicStore.shared.signOut() }
    }
    func list() async throws -> [CloudFile] {
        switch self { case .gog: return try await GOGCloud.list(); case .steam: return try await SteamCloud.list(); case .epic: return try await EpicCloud.list() }
    }
    /// sends these save slots (Epic: a new snapshot of all of them)
    func send(_ slots: [String], cloud: [CloudFile]) async throws {
        try await GameCloud.backupOnce(self, cloud)
        let files = GameCloud.localFiles().filter { f in slots.contains { f.rel.hasPrefix($0 + "/") } }
        switch self {
        case .gog: for slot in slots { try await GOGCloud.send(files.filter { $0.rel.hasPrefix(slot + "/") }) }
        case .steam: try await SteamCloud.send(files, cloud: cloud)
        case .epic: try await EpicCloud.send()
        }
    }

    static let key = "CyPortCloudSource"
    static var preferred: CloudSource {
        get { UserDefaults.standard.string(forKey: key).flatMap(CloudSource.init(rawValue:)) ?? .gog }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

enum GameCloud {
    static func log(_ s: String) { "cloud".withCString { a in s.withCString { MacShimLogC(a, $0) } } }
    static var appSupport: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }
    static var saves: URL { appSupport.appendingPathComponent("CD Projekt Red/Cyberpunk 2077/saves", isDirectory: true) }

    /// "…/CD Projekt Red/Cyberpunk 2077/ManualSave-3/sav.dat" -> "ManualSave-3/sav.dat" (nil if it isn't in a save slot)
    static func slotPath(_ path: String) -> String? {
        let parts = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
        guard let i = parts.lastIndex(where: isSlot), i < parts.count - 1, !parts[(i + 1)...].contains("..") else { return nil }
        return parts[i...].joined(separator: "/")
    }
    static func isSlot(_ s: String) -> Bool {
        guard let dash = s.lastIndex(of: "-") else { return false }
        let name = s[..<dash], num = s[s.index(after: dash)...]
        return name.hasSuffix("Save") && name.allSatisfy(\.isLetter) && !num.isEmpty && num.allSatisfy(\.isNumber)
    }

    // MARK: the phone's side

    struct LocalFile { let rel: String; let url: URL; let modified: Date }
    static func localFiles(in dir: URL = saves) -> [LocalFile] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return [] }
        var out: [LocalFile] = []
        for case let u as URL in e {
            guard let v = try? u.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]), v.isRegularFile == true else { continue }
            let rel = String(u.standardizedFileURL.path.dropFirst(dir.standardizedFileURL.path.count + 1))
            guard let comp = rel.split(separator: "/").first, isSlot(String(comp)), rel.contains("/"), !rel.contains("/.") else { continue }
            out.append(LocalFile(rel: rel, url: u, modified: v.contentModificationDate ?? .distantPast))
        }
        return out
    }
    static func slotTimes<T>(_ files: [T], rel: (T) -> String, date: (T) -> Date) -> [String: Date] {
        var t: [String: Date] = [:]
        for f in files { let s = String(rel(f).split(separator: "/")[0]); t[s] = max(t[s] ?? .distantPast, date(f)) }
        return t
    }
    /// changes whenever a save is written: used to wait until the game has finished writing before sending
    static func localSignature() -> String {
        localFiles().map { "\($0.rel)|\($0.modified.timeIntervalSince1970)" }.sorted().joined(separator: "\n")
    }

    private static var backupDir: URL?
    /// moves a phone slot out of the way (into this session's saves-backup-<date>) before it's replaced
    static func backUp(slot: String) throws {
        let fm = FileManager.default, src = saves.appendingPathComponent(slot)
        guard fm.fileExists(atPath: src.path) else { return }
        if backupDir == nil {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"
            backupDir = saves.deletingLastPathComponent().appendingPathComponent("saves-backup-\(f.string(from: Date()))", isDirectory: true)
        }
        let dst = backupDir!.appendingPathComponent(slot)
        try fm.createDirectory(at: backupDir!, withIntermediateDirectories: true)
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        try fm.moveItem(at: src, to: dst)
    }

    /// once: an earlier version put old phone saves back and then sent them over the cloud's. The cloud's own
    /// copies were saved in CyPort/cloud-backup-<date> right before; they go back on the phone and back to GOG.
    /// Returns the slots to send.
    static func undoPhoneRestore() -> [String] {
        let key = "CyPortUndidPhoneRestore"
        guard !UserDefaults.standard.bool(forKey: key) else { return [] }
        defer { UserDefaults.standard.set(true, forKey: key) }
        guard UserDefaults.standard.bool(forKey: "CyPortRestoredImportBackups") else { return [] }   // never happened here
        let fm = FileManager.default, dir = appSupport.appendingPathComponent("CyPort", isDirectory: true)
        guard let name = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter({ $0.hasPrefix("cloud-backup-") }).sorted().first else { return [] }
        let src = dir.appendingPathComponent(name)
        let slots = Set(localFiles(in: src).map { String($0.rel.split(separator: "/")[0]) })
        var done: [String] = []
        for slot in slots.sorted() {
            do { try backUp(slot: slot); try fm.copyItem(at: src.appendingPathComponent(slot), to: saves.appendingPathComponent(slot)); done.append(slot) }
            catch { log("undo \(slot) failed: \(error.localizedDescription)") }
        }
        log("put the cloud's saves back from \(name): \(done.count) slot(s)")
        return done
    }

    // MARK: sync

    /// what both sides looked like after the last sync, per slot (seconds since 1970)
    private static func stateURL(_ s: CloudSource) -> URL { appSupport.appendingPathComponent("CyPort/cloudsync-\(s.rawValue.lowercased()).json") }
    private static func loadState(_ s: CloudSource) -> [String: [String: Double]] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: stateURL(s)))) as? [String: [String: Double]] ?? [:]
    }
    private static func saveState(_ s: CloudSource, _ st: [String: [String: Double]]) {
        try? FileManager.default.createDirectory(at: stateURL(s).deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: st) { try? d.write(to: stateURL(s), options: .atomic) }
    }

    struct Result {
        var got = 0, sent = 0
        var summary: String {
            switch (got, sent) {
            case (0, 0): return "Up to date"
            case (_, 0): return "Got \(got) save\(got == 1 ? "" : "s") - Load Game to carry on"
            case (0, _): return "Sent \(sent) save\(sent == 1 ? "" : "s")"
            default: return "Got \(got), sent \(sent) save\(sent == 1 ? "" : "s")"
            }
        }
    }

    private static let lock = NSLock()
    private static var busy = false
    private static func claim() -> Bool { lock.withLock { if busy { return false }; busy = true; return true } }
    private static func release() { lock.withLock { busy = false } }

    /// brings the phone and the cloud in step (sending only if `send` and the store supports it)
    static func sync(_ source: CloudSource, send: Bool = true, progress: @escaping (String) -> Void = { _ in }) async throws -> Result {
        guard claim() else { return Result() }
        defer { release() }
        if GOGStore.shared.signedIn { await CDPRSignIn.give() }
        let undo = source == .gog ? undoPhoneRestore() : []
        progress("Checking your \(source.rawValue) saves…")
        let cloud = try await source.list()
        let cloudBySlot = Dictionary(grouping: cloud) { String($0.rel.split(separator: "/")[0]) }
        let cTimes = slotTimes(cloud, rel: { $0.rel }, date: { $0.modified })
        let lTimes = slotTimes(localFiles(), rel: { $0.rel }, date: { $0.modified })
        var state = loadState(source)
        var pull: [String] = [], push: [String] = []
        for slot in Set(cTimes.keys).union(lTimes.keys) {
            let c = cTimes[slot]?.timeIntervalSince1970, l = lTimes[slot]?.timeIntervalSince1970, s = state[slot]
            switch (c, l) {
            case (_?, nil): pull.append(slot)
            case (nil, _?): push.append(slot)
            case (let c?, let l?):
                guard let s else {                              // first sync of this slot: the cloud's copy wins
                    if abs(c - l) > 2 { pull.append(slot) } else { state[slot] = ["c": c, "l": l] }
                    continue
                }
                let cChanged = abs(c - (s["c"] ?? 0)) > 1, lChanged = abs(l - (s["l"] ?? 0)) > 1
                if cChanged && !lChanged { pull.append(slot) }
                else if lChanged && !cChanged { push.append(slot) }
                else if cChanged && lChanged {
                    if c > l + 2 { pull.append(slot) } else if l > c + 2 { push.append(slot) } else { state[slot] = ["c": c, "l": l] }
                }
            default: break
            }
        }
        // the undone slots: the phone now has the cloud's old copies again, they go back up (not down)
        for slot in undo where lTimes[slot] != nil { pull.removeAll { $0 == slot }; if !push.contains(slot) { push.append(slot) } }
        if !(send && source.canSend) { push = [] }
        log("\(source.rawValue): \(cloud.count) cloud file(s); get \(pull.sorted()), send \(push.sorted())")

        var r = Result()
        let fm = FileManager.default
        for (i, slot) in pull.sorted().enumerated() {
            progress("Getting save \(i + 1) of \(pull.count)…")
            var got: [(String, Data, Date)] = []
            for f in cloudBySlot[slot] ?? [] { got.append((f.rel, try await f.fetch(), f.modified)) }   // all of the slot before touching the phone's
            try backUp(slot: slot)
            for (rel, d, m) in got {
                let dst = saves.appendingPathComponent(rel)
                try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try d.write(to: dst, options: .atomic)
                try? fm.setAttributes([.modificationDate: m], ofItemAtPath: dst.path)
            }
            let l = slotTimes(localFiles().filter { $0.rel.hasPrefix(slot + "/") }, rel: { $0.rel }, date: { $0.modified })[slot]
            state[slot] = ["c": cTimes[slot]!.timeIntervalSince1970, "l": (l ?? cTimes[slot]!).timeIntervalSince1970]
            r.got += 1
        }
        if !push.isEmpty {
            progress("Sending \(push.count) save\(push.count == 1 ? "" : "s") to \(source.rawValue)…")
            try await source.send(push.sorted(), cloud: cloud)
            r.sent = push.count
            // the cloud's own times for what was just sent
            let after = slotTimes(try await source.list(), rel: { $0.rel }, date: { $0.modified })
            for slot in push { if let c = after[slot], let l = lTimes[slot] { state[slot] = ["c": c.timeIntervalSince1970, "l": l.timeIntervalSince1970] } }
        }
        saveState(source, state)
        if r.got + r.sent > 0 { log("\(source.rawValue): got \(r.got), sent \(r.sent) slot(s)") }
        return r
    }

    /// before the first upload ever to a store: a copy of everything it has, in CyPort/cloud-backup-<store>-<date>
    static func backupOnce(_ source: CloudSource, _ items: [CloudFile]) async throws {
        let key = source == .gog ? "CyPortCloudBackupDone" : "CyPortCloudBackupDone-\(source.rawValue.lowercased())"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmmss"
        let dir = appSupport.appendingPathComponent("CyPort/cloud-backup-\(source.rawValue.lowercased())-\(f.string(from: Date()))", isDirectory: true)
        for it in items {
            let dst = dir.appendingPathComponent(it.rel)
            try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await it.fetch().write(to: dst)
        }
        UserDefaults.standard.set(true, forKey: key)
        log("\(source.rawValue) cloud backed up to \(dir.lastPathComponent) (\(items.count) file(s))")
    }

    /// zlib (Epic) or gzip (GOG) compression
    static func compress(_ src: Data, gzip: Bool) throws -> Data {
        var z = z_stream()
        guard deflateInit2_(&z, Z_DEFAULT_COMPRESSION, Z_DEFLATED, gzip ? 15 + 16 : 15, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw StoreError("zlib init") }
        defer { deflateEnd(&z) }
        var out = Data(count: Int(deflateBound(&z, uLong(src.count))) + 32)
        let n: Int = try src.withUnsafeBytes { (i: UnsafeRawBufferPointer) in
            try out.withUnsafeMutableBytes { (o: UnsafeMutableRawBufferPointer) in
                z.next_in = UnsafeMutablePointer(mutating: i.bindMemory(to: Bytef.self).baseAddress); z.avail_in = uInt(src.count)
                z.next_out = o.bindMemory(to: Bytef.self).baseAddress; z.avail_out = uInt(o.count)
                guard deflate(&z, Z_FINISH) == Z_STREAM_END else { throw StoreError("compression failed") }
                return Int(z.total_out)
            }
        }
        out.count = n
        return out
    }

    // MARK: while playing

    private static var timer: DispatchSourceTimer?
    private static var sentSignature = ""
    @discardableResult private static func sent(_ v: String? = nil) -> String { lock.withLock { if let v { sentSignature = v }; return sentSignature } }
    /// after PLAY: every 20 s, once the saves stop changing (the game finished writing), send what's new; also when the
    /// app goes to the background
    static func startWatching() {
        let source = CloudSource.preferred
        guard source.canSend, source.signedIn, timer == nil else { return }
        var last = localSignature(); sent(last)
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 20, repeating: 20)
        t.setEventHandler {
            let now = localSignature()
            if now != last { last = now; return }               // still being written: wait one more round
            guard now != sent() else { return }
            sent(now)
            Task { do { _ = try await sync(source) } catch { sent(""); log("send failed: \(error.localizedDescription)") } }
        }
        t.resume(); timer = t
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            var bg = UIBackgroundTaskIdentifier.invalid
            bg = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(bg) }
            let task = bg
            Task {
                do { _ = try await sync(source); sent(localSignature()) } catch { log("send failed: \(error.localizedDescription)") }
                await MainActor.run { UIApplication.shared.endBackgroundTask(task) }
            }
        }
        log("watching for new saves to send")
    }
}

// MARK: - the game's own sign-in (CD PROJEKT RED cross-progression cloud saves, inside the game)

/// In the game, the cloud saves of your CD PROJEKT RED account (the ones the Mac shows in Load Game) only appear when
/// the game is signed in. It signs itself in with a refresh token it keeps in saves/user.gls; on a computer GOG Galaxy
/// provides it. The game-client token CyPort gets for GOG sync is that same token, so it's put there before the game
/// starts. The game refreshes it and writes it back itself.
enum CDPRSignIn {
    static let tokenKey = fnv1a64("GameServicesGalaxy.RefreshToken")
    static func fnv1a64(_ s: String) -> UInt64 { s.utf8.reduce(0xcbf29ce484222325) { ($0 ^ UInt64($1)) &* 0x100000001b3 } }
    static var file: URL { GameCloud.saves.appendingPathComponent("user.gls") }

    static func give() async {
        do {
            let t = try await GOGCloud.session().refresh
            guard !t.isEmpty else { GameCloud.log("CDPR: no refresh token from the sign-in"); return }
            describe(t)
            var g = (try? Data(contentsOf: file)).flatMap(GLS.init) ?? GLS()
            g[tokenKey] = Data(t.utf8)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try g.encoded().write(to: file, options: .atomic)
            GameCloud.log("CDPR: the game will sign in by itself (user.gls updated)")
        } catch { GameCloud.log("CDPR: couldn't give the game its sign-in: \(error.localizedDescription)") }
    }
    /// logs what kind of token it is (issuer, client, scopes) - never the token
    private static func describe(_ t: String) {
        let p = t.split(separator: ".")
        guard p.count == 3, let d = Data(base64Encoded: String(p[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                .padding(toLength: (p[1].count + 3) / 4 * 4, withPad: "=", startingAt: 0)),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { GameCloud.log("CDPR: token is not a JWT (\(t.count) chars)"); return }
        GameCloud.log("CDPR: token iss=\(o["iss"] ?? "?") azp=\(o["azp"] ?? "?") typ=\(o["typ"] ?? "?") saves-scope=\((o["scope"] as? String ?? "").contains("aud_game_saves"))")
    }
}

/// saves/user.gls: "SLGR", u32 version, u32 count, count x {u64 key hash (FNV-1a 64), u32 length, bytes}, u32 CRC32 of
/// all before it
struct GLS {
    var version: UInt32 = 1
    var entries: [(key: UInt64, value: Data)] = []
    init() {}
    init?(_ d: Data) {
        let b = [UInt8](d)
        func u32(_ o: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(b[o + $1]) << (8 * $1) } }
        func u64(_ o: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(b[o + $1]) << (8 * $1) } }
        guard b.count >= 16, b[0..<4].elementsEqual("SLGR".utf8) else { return nil }
        version = u32(4)
        var o = 12
        for _ in 0..<u32(8) {
            guard o + 12 <= b.count - 4 else { return nil }
            let n = Int(u32(o + 8)); guard o + 12 + n <= b.count - 4 else { return nil }
            entries.append((u64(o), Data(b[(o + 12)..<(o + 12 + n)]))); o += 12 + n
        }
        guard o == b.count - 4, u32(o) == UInt32(crc32(0, b, uInt(o))) else { return nil }
    }
    func encoded() -> Data {
        var b = [UInt8]("SLGR".utf8)
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { b += $0 } }
        put(version); put(UInt32(entries.count))
        for e in entries { put(e.key); put(UInt32(e.value.count)); b += e.value }
        put(UInt32(crc32(0, b, uInt(b.count))))
        return Data(b)
    }
    subscript(key: UInt64) -> Data? {
        get { entries.first { $0.key == key }?.value }
        set {
            entries.removeAll { $0.key == key }
            if let v = newValue { entries.append((key, v)) }
        }
    }
}


// MARK: - GOG (cloudstorage.gog.com, read + write)

enum GOGCloud {
    static let clientID = "53652320436400298"

    /// the game's client secret: the 64 hex characters stored right after its client id in the executable
    static func clientSecret() throws -> String {
        guard let exe = Bundle.main.executableURL, let d = try? Data(contentsOf: exe, options: .alwaysMapped) else {
            throw StoreError("Couldn't read the game's executable.")
        }
        let id = Data((clientID + "\0").utf8)
        var from = d.startIndex
        while let r = d.range(of: id, in: from..<d.endIndex) {
            let s = d[r.upperBound...].prefix(64)
            if s.count == 64, s.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) { return String(decoding: s, as: UTF8.self) }
            from = r.upperBound
        }
        throw StoreError("Couldn't find the game's cloud settings in its executable.")
    }

    struct Session { let access: String; let refresh: String; let user: String }
    private static var cached: (Session, Date)?
    /// your account sign-in -> a sign-in of the game itself (what GOG Galaxy hands the game on a computer)
    static func session() async throws -> Session {
        if let (c, until) = cached, until > Date() { return c }
        _ = try await GOGStore.shared.auth()                       // refreshes the account sign-in if it's about to expire
        guard let r = Keychain.load("gog")?["refresh"] as? String else { throw StoreError("Sign in to GOG first.") }
        var c = URLComponents(string: "https://auth.gog.com/token")!
        c.queryItems = [.init(name: "client_id", value: clientID), .init(name: "client_secret", value: try clientSecret()),
                        .init(name: "grant_type", value: "refresh_token"), .init(name: "refresh_token", value: r),
                        .init(name: "without_new_session", value: "1")]
        let o = try await Net.json(c.url!)
        guard let a = o["access_token"] as? String else { throw StoreError("The game's cloud sign-in failed.") }
        let user = (o["user_id"] as? String) ?? (o["user_id"].map { "\($0)" } ?? "")
        guard !user.isEmpty else { throw StoreError("The game's cloud sign-in gave no user.") }
        let ses = Session(access: a, refresh: o["refresh_token"] as? String ?? "", user: user)
        cached = (ses, Date().addingTimeInterval(((o["expires_in"] as? Double) ?? 3600) - 300))
        GameCloud.log("GOG: game sign-in ok (user \(user))")
        return ses
    }
    static func headers(_ s: Session) -> [String: String] {
        ["Authorization": "Bearer \(s.access)", "Accept": "application/json",
         "User-Agent": "GOGGalaxyCommunicationService/2.0.0 (iOS) dont_sync_marker/true"]
    }
    static func url(_ s: Session, _ name: String = "") -> URL {
        let base = URL(string: "https://cloudstorage.gog.com/v1/\(s.user)/\(clientID)")!
        return name.isEmpty ? base : base.appendingPathComponent(name)
    }

    static func list() async throws -> [CloudFile] {
        let s = try await session()
        let d = try await Net.request(url(s), headers: headers(s))
        guard let a = try JSONSerialization.jsonObject(with: d) as? [[String: Any]] else { throw StoreError("Unexpected reply from the GOG cloud.") }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let iso2 = ISO8601DateFormatter()
        return a.compactMap { f in
            guard let n = f["name"] as? String, n.hasPrefix("saves/"), let rel = GameCloud.slotPath(n) else { return nil }
            let m = (f["last_modified"] as? String).flatMap { iso.date(from: $0) ?? iso2.date(from: $0) } ?? .distantPast
            return CloudFile(rel: rel, modified: m) {
                var d = try await Net.request(url(s, n), headers: headers(s))
                if d.count >= 2, d[d.startIndex] == 0x1f, d[d.startIndex + 1] == 0x8b { d = try Inflate.run(d) }   // stored gzipped
                return d
            }
        }
    }

    /// uploads the files of one slot
    static func send(_ files: [GameCloud.LocalFile]) async throws {
        let s = try await session()
        let iso = ISO8601DateFormatter()
        for f in files {
            let gz = try GameCloud.compress(try Data(contentsOf: f.url), gzip: true)
            var h = headers(s)
            h["Content-Encoding"] = "gzip"; h["Content-Type"] = "application/octet-stream"
            h["Etag"] = Hash.md5(gz).hex
            h["X-Object-Meta-LocalLastModified"] = iso.string(from: f.modified)
            _ = try await Net.request(url(s, "saves/" + f.rel), method: "PUT", headers: h, body: gz)
        }
    }
}

// MARK: - Steam Cloud

enum SteamCloud {
    static func list() async throws -> [CloudFile] {
        try await SteamStore.shared.logOn()
        let cm = SteamStore.shared.cm
        var q = PBWriter(); q.u(1, UInt64(Game.steamApp)); q.b(2, true)
        let p = try await cm.call(.clientUFSGetFileListForApp, q)
        let m = try PBMessage(p.body)
        let prefixes = m.all(2).map { String(decoding: $0, as: UTF8.self) }
        var out: [CloudFile] = []
        for raw in m.all(1) {
            let f = try PBMessage(raw)
            guard let name = f.s(2), (f.u(6) ?? 0) == 0 else { continue }              // skip deleted files
            let prefix = f.u(8).flatMap { Int($0) < prefixes.count ? prefixes[Int($0)] : nil } ?? ""
            guard let rel = GameCloud.slotPath(prefix + name) else { continue }
            let when = Date(timeIntervalSince1970: TimeInterval(f.u(4) ?? 0))
            out.append(CloudFile(rel: rel, modified: when, remote: prefix + name) { try await download(prefix.isEmpty ? [name] : [prefix + name, name]) })
        }
        GameCloud.log("Steam: \(out.count) save file(s) in Steam Cloud")
        return out
    }
    /// Steam Cloud upload, the way the Steam client does it: begin a batch, per file begin -> send its blocks to the
    /// hosts Steam names -> commit, then complete the batch
    static func send(_ files: [GameCloud.LocalFile], cloud: [CloudFile]) async throws {
        guard !files.isEmpty else { return }
        var remoteByRel: [String: String] = [:]
        for c in cloud { if let r = c.remote { remoteByRel[c.rel] = r } }
        // a new file goes where the existing saves are (same path prefix, e.g. "%WinSavedGames%CD Projekt Red/Cyberpunk 2077/")
        let prefix = cloud.lazy.compactMap { c in c.remote.flatMap { $0.hasSuffix(c.rel) ? String($0.dropLast(c.rel.count)) : nil } }.first
        let named: [(GameCloud.LocalFile, String)] = try files.map { f in
            if let r = remoteByRel[f.rel] { return (f, r) }
            guard let p = prefix else { throw StoreError("Steam Cloud has no Cyberpunk saves yet - play once on a computer with Steam first.") }
            return (f, p + f.rel)
        }
        let cm = SteamStore.shared.cm, app = UInt64(Game.steamApp)
        var b = PBWriter(); b.u(1, app); b.s(2, "CyPort (iPhone)")
        for (_, n) in named { b.s(3, n) }
        let batch = try await cm.service("Cloud.BeginAppUploadBatch#1", b, authed: true).u(1) ?? 0
        func complete(_ ok: Bool) async {
            var c = PBWriter(); c.u(1, app); c.u(2, batch); c.u(3, ok ? 1 : 2)
            _ = try? await cm.service("Cloud.CompleteAppUploadBatchBlocking#1", c, authed: true)
        }
        do {
            for (f, name) in named {
                let data = try Data(contentsOf: f.url), sha = Hash.sha1(data)
                var q = PBWriter()
                q.u(1, app); q.u(2, UInt64(data.count)); q.u(3, UInt64(data.count)); q.bytes(4, sha)
                q.u(5, UInt64(max(0, f.modified.timeIntervalSince1970))); q.s(6, name); q.u(7, 0xFFFF_FFFF)
                q.b(10, false); q.u(13, batch)
                let r = try await cm.service("Cloud.ClientBeginFileUpload#1", q, authed: true)
                for raw in r.all(2) {
                    let blk = try PBMessage(raw)
                    guard let host = blk.s(1), let path = blk.s(2) else { throw StoreError("Steam Cloud gave no upload address") }
                    let off = Int(blk.u(6) ?? 0), len = Int(blk.u(7) ?? UInt64(data.count))
                    let body = blk.data(8) ?? data.subdata(in: off..<min(data.count, off + len))
                    var h: [String: String] = [:]
                    for hr in blk.all(5) { if let hm = try? PBMessage(hr), let k = hm.s(1), let v = hm.s(2) { h[k] = v } }
                    let method = ["", "GET", "HEAD", "POST", "PUT", "DELETE"][min(5, Int(blk.u(4) ?? 4))]
                    guard let u = URL(string: "\((blk.u(3) ?? 1) != 0 ? "https" : "http")://\(host)\(path)") else { throw StoreError("Steam Cloud: bad upload address") }
                    _ = try await Net.request(u, method: method.isEmpty ? "PUT" : method, headers: h, body: body)
                }
                var c = PBWriter(); c.b(1, true); c.u(2, app); c.bytes(3, sha); c.s(4, name)
                let committed = try await cm.service("Cloud.ClientCommitFileUpload#1", c, authed: true)
                guard (committed.u(1) ?? 0) != 0 else { throw StoreError("Steam Cloud didn't accept \(f.rel)") }
            }
        } catch { await complete(false); throw error }
        await complete(true)
        GameCloud.log("Steam: sent \(named.count) file(s)")
    }

    private static func download(_ names: [String]) async throws -> Data {
        var last: Error = StoreError("Steam Cloud: no file")
        for n in names {
            do {
                var q = PBWriter(); q.u(1, UInt64(Game.steamApp)); q.s(2, n); q.u(3, 1)
                let r = try await SteamStore.shared.cm.service("Cloud.ClientFileDownload#1", q, authed: true)
                guard let host = r.s(7), let path = r.s(8) else { throw StoreError("Steam Cloud gave no download for \(n)") }
                var headers: [String: String] = [:]
                for h in r.all(10) { if let hm = try? PBMessage(h), let k = hm.s(1), let v = hm.s(2) { headers[k] = v } }
                let scheme = (r.u(9) ?? 0) != 0 ? "https" : "http"
                guard let u = URL(string: "\(scheme)://\(host)\(path)") else { throw StoreError("Steam Cloud: bad link") }
                var d = try await Net.request(u, headers: headers)
                if let size = r.u(2), let rawSize = r.u(3), size != rawSize || (d.count >= 4 && d.u32(0) == 0x04034b50) { d = try Zip.firstEntry(d) }
                return d
            } catch { last = error }
        }
        throw last
    }
}

// MARK: - Epic cloud saves

enum EpicCloud {
    /// what the last listing found: needed to write a new snapshot like the newest one
    struct Context {
        let base: URL                       // …/savesync/<account>/<app>/
        let files: [String: [String: Any]]  // the store's file list (name -> readLink, lastModified, …)
        let newest: EpicManifest
        let newestName: String
        let fetch: (EpicManifest.File) async throws -> Data
    }
    private static var context: Context?

    static func list() async throws -> [CloudFile] {
        let epic = EpicStore.shared
        let account = try await epic.accountID()
        guard let app = try await epic.ownedItems().first(where: { $0.title.lowercased() == Game.epicTitle })?.app else {
            throw StoreError("This Epic account doesn't own Cyberpunk 2077.")
        }
        let base = URL(string: "https://datastorage-public-service-liveegs.live.use1a.on.epicgames.com/api/v1/access/egstore/savesync/\(account)/\(app)/")!
        let o = try await Net.json(base, headers: try await epic.auth())
        let files = o["files"] as? [String: [String: Any]] ?? [:]
        // every manifest is a snapshot of the save folder; newer snapshots win per file
        let manifests = files.filter { $0.key.hasSuffix(".manifest") }.sorted { date($0.value) < date($1.value) }
        var byRel: [String: CloudFile] = [:]
        context = nil
        for (name, f) in manifests {
            guard let link = (f["readLink"] as? String).flatMap(URL.init(string:)) else { continue }
            let m: EpicManifest
            do { m = try EpicManifest(try await Net.request(link)) } catch { GameCloud.log("Epic: \(name): \(error.localizedDescription)"); continue }
            let fetch = fetcher(m, files)
            context = Context(base: base, files: files, newest: m, newestName: name, fetch: fetch)
            for file in m.files where file.link.isEmpty {
                guard let rel = GameCloud.slotPath(file.path) else { continue }
                byRel[rel] = CloudFile(rel: rel, modified: date(f)) { try await fetch(file) }
            }
        }
        GameCloud.log("Epic: \(byRel.count) save file(s) in \(manifests.count) cloud snapshot(s)")
        return Array(byRel.values)
    }
    static func date(_ f: [String: Any]) -> Date {
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return (f["lastModified"] as? String).flatMap { iso.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) } ?? .distantPast
    }
    /// the chunk files sit next to the manifests; their names end with the chunk's path from the manifest
    static func chunkKey(_ m: EpicManifest, _ c: EpicManifest.Chunk, _ files: [String: [String: Any]]) -> String? {
        let p = m.path(c), tail = String(p.split(separator: "/").last ?? "")
        return files.keys.first { $0.hasSuffix(p) } ?? files.keys.first { $0.hasSuffix(tail) }
    }
    static func fetcher(_ m: EpicManifest, _ files: [String: [String: Any]]) -> (EpicManifest.File) async throws -> Data {
        { file in
            var out = Data(), cache: [Int: Data] = [:]
            for p in file.parts {
                if cache[p.chunk] == nil {
                    let c = m.chunks[p.chunk]
                    guard let k = chunkKey(m, c, files), let u = (files[k]?["readLink"] as? String).flatMap(URL.init(string:)) else {
                        throw StoreError("Epic cloud: a piece of \(file.path) is missing")
                    }
                    cache[p.chunk] = try EpicManifest.decodeChunk(try await Net.request(u), guid: c.guid, sha1: c.sha1, window: c.window)
                }
                let d = cache[p.chunk]!
                guard p.offset + p.size <= d.count else { throw StoreError("Epic cloud: damaged piece of \(file.path)") }
                out.append(d.subdata(in: p.offset..<(p.offset + p.size)))
            }
            return out
        }
    }

    /// uploads a new snapshot: every save slot on the phone (plus any other files the newest snapshot had), written
    /// like the newest snapshot (same app info and settings, same place for the chunks)
    static func send() async throws {
        if context == nil { _ = try await list() }
        guard let ctx = context else { throw StoreError("Epic has no Cyberpunk cloud saves yet - play once on a computer with Epic first.") }
        // where saves sit inside a snapshot ("" or a folder in front of the slot folders)
        let pathPrefix = ctx.newest.files.lazy.compactMap { f in GameCloud.slotPath(f.path).map { String(f.path.dropLast($0.count)) } }.first ?? ""
        var out: [(String, Data)] = []
        for f in ctx.newest.files where f.link.isEmpty && GameCloud.slotPath(f.path) == nil { out.append((f.path, try await ctx.fetch(f))) }
        for f in GameCloud.localFiles().sorted(by: { $0.rel < $1.rel }) { out.append((pathPrefix + f.rel, try Data(contentsOf: f.url))) }
        let (manifest, model, chunks) = try EpicManifest.write(like: ctx.newest, files: out)

        // names: the new manifest next to the newest one, chunks where that one's chunks are
        let dir = ctx.newestName.contains("/") ? String(ctx.newestName[...ctx.newestName.lastIndex(of: "/")!]) : ""
        let chunkRoot: String = {
            if let c = ctx.newest.chunks.first, let k = chunkKey(ctx.newest, c, ctx.files) { return String(k.dropLast(ctx.newest.path(c).count)) }
            return dir.hasSuffix("manifests/") ? String(dir.dropLast("manifests/".count)) : dir
        }()
        let f = DateFormatter(); f.dateFormat = "yyyy.MM.dd-HH.mm.ss"; f.timeZone = TimeZone(identifier: "UTC")
        let manifestName = dir + f.string(from: Date()) + ".manifest"
        var uploads: [(String, Data)] = chunks.map { (chunkRoot + model.path($0.0), $0.1) }
        uploads.append((manifestName, manifest))                      // the manifest last: it only counts once its chunks are there

        let links = try await writeLinks(ctx, uploads.map(\.0))
        for (i, (name, data)) in uploads.enumerated() {
            guard let u = links[name] else { throw StoreError("Epic gave no upload address for \(name)") }
            _ = try await Net.request(u, method: "PUT", headers: ["Content-Type": "application/octet-stream"], body: data)
            if i % 4 == 0 { GameCloud.log("Epic: sent \(i + 1) of \(uploads.count)") }
        }
        context = nil
        GameCloud.log("Epic: sent snapshot \(manifestName) (\(out.count) file(s), \(chunks.count) chunk(s))")
    }
    /// asks Epic where to put these files; the names are given the way Epic lists them
    private static func writeLinks(_ ctx: Context, _ names: [String]) async throws -> [String: URL] {
        func ask(_ n: [String]) async throws -> [String: URL] {
            var h = try await EpicStore.shared.auth(); h["Content-Type"] = "application/json"
            let body = try JSONSerialization.data(withJSONObject: ["files": n])
            let o = try await Net.json(ctx.base, method: "POST", headers: h, body: body)
            var out: [String: URL] = [:]
            for (k, v) in o["files"] as? [String: [String: Any]] ?? [:] { if let u = (v["writeLink"] as? String).flatMap(URL.init(string:)) { out[k] = u } }
            return out
        }
        let got = try await ask(names)
        if names.allSatisfy({ got[$0] != nil }) { return got }
        // Epic may want the names without the "<account>/<app>/" in front: try that and map back
        let comps = ctx.base.pathComponents.suffix(2).joined(separator: "/") + "/"
        let short = names.map { $0.hasPrefix(comps) ? String($0.dropFirst(comps.count)) : $0 }
        let got2 = try await ask(short)
        var out: [String: URL] = [:]
        for (n, sn) in zip(names, short) { if let u = got2[sn] ?? got2[n] ?? got[n] { out[n] = u } }
        return out
    }
}

// MARK: - writing an Epic manifest + chunks (cloud save snapshots)

extension EpicManifest {
    static let chunkWindow = 1 << 20

    /// Epic's 64-bit rolling hash of a chunk's data
    private static let hashTable: [UInt64] = (0..<256).map { i -> UInt64 in
        var v = UInt64(i)
        for _ in 0..<8 { v = v & 1 != 0 ? (v >> 1) ^ 0xC96C_5795_D787_0F42 : v >> 1 }
        return v
    }
    static func rollingHash(_ d: Data) -> UInt64 {
        var h: UInt64 = 0
        for b in d { h = ((h << 1) | (h >> 63)) ^ hashTable[Int(b)] }
        return h
    }
    private static func fstring(_ s: String) -> Data {
        var d = Data()
        if s.isEmpty { d.appendLE(Int32(0)); return d }
        if s.allSatisfy(\.isASCII) { d.appendLE(Int32(s.utf8.count + 1)); d.append(contentsOf: Array(s.utf8)); d.append(0); return d }
        let u = Array(s.utf16); d.appendLE(Int32(-(u.count + 1))); for c in u { d.appendLE(c) }; d.appendLE(UInt16(0)); return d
    }
    private static func section(_ version: UInt8, _ body: Data) -> Data {
        var d = Data(); d.appendLE(UInt32(4 + 1 + body.count)); d.append(version); d.append(body); return d
    }

    /// a manifest for these files, with the app info and settings of `base`. Returns the manifest file, a model of it
    /// (for chunk paths) and the chunk files.
    static func write(like base: EpicManifest, files: [(String, Data)]) throws -> (Data, EpicManifest, [(Chunk, Data)]) {
        // pack the files one after the other into 1 MiB chunks
        var bufs: [Data] = [], parts: [[Part]] = []
        for (_, data) in files {
            var ps: [Part] = [], off = 0
            while off < data.count {
                if bufs.isEmpty || bufs[bufs.count - 1].count == chunkWindow { bufs.append(Data()) }
                let ci = bufs.count - 1, n = min(chunkWindow - bufs[ci].count, data.count - off)
                ps.append(Part(chunk: ci, offset: bufs[ci].count, size: n))
                bufs[ci].append(data.subdata(in: off..<(off + n))); off += n
            }
            parts.append(ps)
        }
        var chunks: [Chunk] = [], chunkFiles: [(Chunk, Data)] = []
        for var b in bufs {
            if b.count < chunkWindow { b.append(Data(count: chunkWindow - b.count)) }
            var g = [UInt8](repeating: 0, count: 16); _ = SecRandomCopyBytes(kSecRandomDefault, 16, &g)
            let guid = Data(g), sha = Hash.sha1(b), hash = rollingHash(b)
            let c = Chunk(guid: guid, hash: hash, sha1: sha, group: UInt8(Hash.crc32(guid) % 100), window: chunkWindow)
            let z = try GameCloud.compress(b, gzip: false)
            var f = Data()
            f.appendLE(UInt32(0xB1FE_3AA2)); f.appendLE(UInt32(3)); f.appendLE(UInt32(66)); f.appendLE(UInt32(z.count))
            f.append(guid); f.appendLE(hash); f.append(1); f.append(sha); f.append(3); f.appendLE(UInt32(chunkWindow))
            f.append(z)
            chunks.append(c); chunkFiles.append((c, f))
        }
        // chunk list
        var cdl = Data(); cdl.appendLE(UInt32(chunks.count))
        for c in chunks { cdl.append(c.guid) }
        for c in chunks { cdl.appendLE(c.hash) }
        for c in chunks { cdl.append(c.sha1) }
        for c in chunks { cdl.append(c.group) }
        for c in chunks { cdl.appendLE(UInt32(c.window)) }
        for (_, f) in chunkFiles { cdl.appendLE(Int64(f.count)) }
        // file list
        var fml = Data(); fml.appendLE(UInt32(files.count))
        for (name, _) in files { fml.append(fstring(name)) }
        for _ in files { fml.append(fstring("")) }                      // symlink targets
        for (_, data) in files { fml.append(Hash.sha1(data)) }
        for _ in files { fml.append(0) }                                // flags
        for _ in files { fml.appendLE(UInt32(0)) }                      // install tags
        for ps in parts {
            fml.appendLE(UInt32(ps.count))
            for p in ps { fml.appendLE(UInt32(28)); fml.append(chunks[p.chunk].guid); fml.appendLE(UInt32(p.offset)); fml.appendLE(UInt32(p.size)) }
        }
        let body = base.rawMeta + section(0, cdl) + section(0, fml) + base.rawCustom
        let z = try GameCloud.compress(body, gzip: false)
        var m = Data()
        m.appendLE(UInt32(0x44BE_C00C)); m.appendLE(UInt32(41)); m.appendLE(UInt32(body.count)); m.appendLE(UInt32(z.count))
        m.append(Hash.sha1(body)); m.append(1); m.appendLE(base.version == 0 ? UInt32(18) : base.version)
        m.append(z)
        let model = try EpicManifest(m)                                   // read back: proves it parses, and gives chunk paths
        return (m, model, chunkFiles)
    }
}
