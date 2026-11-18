// ModManager.swift - the in-app mod manager's logic (no UI; the screen is shim/ModManagerUI.swift).
//
// Folders (GAME = the game folder the shim uses, e.g. Documents/Cyberpunk 2077; CYPORT = the folder "CyPort" next to it,
// so on the phone's own storage Documents/CyPort, and on an SSD beside the game so that turning a mod off never copies
// gigabytes between disks):
//   CYPORT/mods/<id>.json            one manifest per mod (name, source archive, installed files, kind, frameworks, enabled)
//   CYPORT/disabled/<id>/<path>      the files of a mod that is turned off, at the same relative path they have in GAME
//   CYPORT/disabled-plugins/<Name>/  a RED4ext plugin folder that is turned off (from GAME/red4ext/plugins/<Name>)
//   CYPORT/final.redscripts.original the game's own script blob: every compile starts from it
//   CYPORT/final.redscripts.previous the blob that was in use before the last successful compile
//   CYPORT/tmp/                      unpack + compiler scratch (emptied when the manager opens)
//
// Where a mod's files go (the same rules as the Mac installer, Mods Nexus/cyport-mod.py):
//   *.archive, *.archive.xl / *.xl   -> archive/Mac/mod/            (the zips say archive/pc/mod; the Mac game reads archive/Mac)
//   r6/tweaks/** .yaml .yml .tweak   -> r6/tweaks/**                (TweakXL)
//   r6/input/*.xml                   -> r6/input/                   (Input Loader)
//   r6/scripts/** .reds              -> r6/scripts/<Mod>/**         (compiled on the phone, see compileScripts)
//   .../cyber_engine_tweaks/mods/<Mod>/** -> bin/x64/plugins/cyber_engine_tweaks/mods/<Mod>/**   (CET Lua mods)
// REDmod packages (mods/<name>/info.json; REDmod is off in the Mac game) are converted on import:
//   archives/*.archive -> archive/Mac/mod/zz_redmod_<name>_*   scripts/**.reds -> r6/scripts/<name>/   tweaks/** -> r6/tweaks/<name>/
//   scripts/**.script (whole copies of game scripts, for redMod.exe) and customSounds are left out, with the reason.
// PC audio-replacer archives (loose .wem at base\sound\soundbanks\<id>.wem) are converted to the Mac layout on import, and
// on request for archives that are already installed: ModManagerAudio.swift.
// Refused: Windows .dll / .exe / .asi, RED4ext plugin packages, CET itself, engine .ini, Audioware sound files.
// Dependencies, conflicts + load order, profiles, save backups, "since the last Play": ModManagerMore.swift.
// Nothing from an archive is ever executed; macOS "._*" files are skipped; unsafe paths are refused (ModManagerCore.c).
//
// The original script blob ("pristine"): redscript marks every blob it writes with a "$REDSCRIPT_SIGNATURE" name, so a blob
// without it is the game's own. ensurePristine() takes the first unmarked one of: CYPORT/final.redscripts.original,
// r6/cache/final.redscripts.bk (what the Mac flow / scc leave behind), r6/cache/final.redscripts. If all are compiled blobs
// the user has to supply the original (adoptOriginal, "Choose original scripts…" on the screen).
import Foundation

@_silgen_name("MSModExtract")
private func MSModExtract(_ src: UnsafePointer<CChar>, _ dst: UnsafePointer<CChar>, _ maxBytes: Int64,
                          _ err: UnsafeMutablePointer<CChar>, _ cap: Int) -> Int32
@_silgen_name("MSModExtractProgress") func MSModExtractProgress() -> Int64
@_silgen_name("MSModExtractCancel") func MSModExtractCancel()
@_silgen_name("MSModCompile")
private func MSModCompile(_ lib: UnsafePointer<CChar>, _ r6: UnsafePointer<CChar>, _ inBlob: UnsafePointer<CChar>,
                          _ outBlob: UnsafePointer<CChar>, _ paths: UnsafePointer<UnsafePointer<CChar>?>?, _ n: Int32,
                          _ err: UnsafeMutablePointer<CChar>, _ cap: Int) -> Int32

func modLog(_ s: String) { "mods".withCString { a in s.withCString { MacShimLogC(a, $0) } } }

struct ModError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

struct ModFile: Codable, Hashable {
    var path: String            // relative to the game folder
    var size: Int64
}

struct ModFramework: Codable, Hashable {
    var name: String
    var why: String
    var optional: Bool
}

struct ModManifest: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var source: String          // the archive it came from ("" for files CyPort did not install)
    var installed: Date
    var managed: Bool           // false: files that were already in the game folder
    var enabled: Bool
    var kinds: [String]         // archive, archivexl, tweak, input, redscript, cet
    var frameworks: [ModFramework]
    var files: [ModFile]
    var notes: [String]         // what the archives replace / add
    var skipped: [String]       // parts of the archive that were not installed, with the reason
    var version: String?        // from a REDmod info.json
    var size: Int64 { files.reduce(0) { $0 + $1.size } }
    var hasScripts: Bool { kinds.contains("redscript") }
}

struct ModPlugin: Identifiable, Hashable {
    var name: String            // folder name under red4ext/plugins
    var enabled: Bool
    var size: Int64
    var scriptFiles: Int        // .reds in its Scripts folder
    var usedBy: [String]        // names of installed mods that use it
    var id: String { name }
}

struct ModList {
    var mods: [ModManifest] = []          // installed by CyPort
    var unmanaged: [ModManifest] = []     // found in the game folder
    var plugins: [ModPlugin] = []
    // filled by ModStore.decorate (ModManagerMore.swift)
    var deps: [String: [ModDep]] = [:]            // mod id -> the frameworks it uses and whether they are there
    var conflicts: [String: [ModConflict]] = [:]  // mod id -> what it shares with other mods
    var orderActive = false                       // the archives carry CyPort's load-order numbers
    var profiles: [ModProfile] = []
    var backups: [ModBackup] = []
    var changes: [String]?                        // since the last Play (nil: no Play recorded yet)
    var audio: [String: ModAudioInfo] = [:]       // mod id -> PC sounds its archives still carry (ModManagerAudio.swift)
    var settings = ModSettings()
}

/// one file of an archive that can be installed
struct ModPlanItem: Identifiable {
    let id: Int
    let src: String             // absolute path in the unpack folder
    let rel: String             // path inside the archive
    var dest: String            // path relative to the game folder
    let kind: String
    let size: Int64
    var verdict: String = ""    // archives: what it replaces / adds
    var good = true             // archives: false = replaces nothing on the Mac game
    var selected = true
    var audio: [String] = []    // archives: what the audio conversion did (ModManagerAudio.swift)
}

struct ModPlan {
    var id: String
    var name: String
    var source: String
    var tmp: String
    var items: [ModPlanItem] = []
    var unsupported: [(why: String, files: [String])] = []
    var ignored: [String] = []
    var frameworks: [ModFramework] = []
    var deps: [ModDep] = []               // the same, with what is on the phone
    var enablePlugins = true              // install also turns on the needed plugins that are off
    var conflicts: [String] = []          // what it shares with the mods that are on
    var notes: [String] = []              // conversions (REDmod)
    var version: String?
    var variants = false                  // archives in several folders: usually "pick one"
    var updates = false                   // a mod with this id is installed: it is replaced
    var hashesChecked = false
    var installable: Bool { !items.isEmpty }
    var hasScripts: Bool { items.contains { $0.kind == "redscript" } }
}

struct ModCompileResult {
    var ok: Bool
    var message: String         // one line
    var detail: String          // the compiler's error text / log
}

final class ModStore: @unchecked Sendable {
    let game: String
    let cyport: String
    let fm = FileManager.default
    /// the sorted u64 list of every resource in the Mac game's archives (the app bundle's CyPortMacHashes.bin)
    static var hashesPath: String? = Bundle.main.path(forResource: "CyPortMacHashes", ofType: "bin")
    static var sccLibPath: String = (Bundle.main.privateFrameworksPath ?? "") + "/libscc_lib.dylib"

    static let archiveArea = "archive/Mac/mod", tweakArea = "r6/tweaks", inputArea = "r6/input", scriptArea = "r6/scripts"
    static let cetArea = "bin/x64/plugins/cyber_engine_tweaks/mods", pluginArea = "red4ext/plugins"
    /// RED4ext plugins with no iOS build (their script natives would be missing on the phone)
    static let notPorted: Set<String> = ["redfilesystem", "reddata", "redhttpclient", "audioware", "modsettingsmodule",
                                         "cyberpunkmp", "radioext", "musicapi"]
    /// plugins whose scripts must be part of every compile while the plugin is on
    static let scriptPlugins: Set<String> = ["tweakxl", "archivexl", "codeware", "modsettings"]

    init(gameRoot: String) {
        game = (gameRoot as NSString).standardizingPath
        var c = ((game as NSString).deletingLastPathComponent as NSString).appendingPathComponent("CyPort")
        if !ModStore.canWrite(c) {
            let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory()
            c = (docs as NSString).appendingPathComponent("CyPort")
        }
        cyport = c
        for d in ["mods", "disabled", "disabled-plugins", "profiles", "save-backups"] { try? fm.createDirectory(atPath: cyport + "/" + d, withIntermediateDirectories: true) }
        try? fm.removeItem(atPath: cyport + "/tmp")
    }
    private static func canWrite(_ dir: String) -> Bool {
        let fm = FileManager.default
        do { try fm.createDirectory(atPath: dir, withIntermediateDirectories: true) } catch { return false }
        let probe = dir + "/.probe"
        guard fm.createFile(atPath: probe, contents: Data()) else { return false }
        try? fm.removeItem(atPath: probe)
        return true
    }

    // ---------------------------------------------------------------- paths
    static func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
    static func safeName(_ n: String) -> String {
        String(n.map { ($0.isLetter || $0.isNumber || "._-#".contains($0)) ? $0 : "_" })
    }
    /// `rel` under the game folder with the capitalisation of what is already there (iOS file names are case-sensitive:
    /// the game folder has archive/Mac/mod, a zip may say archive/pc/mod or R6/Scripts)
    func resolve(_ rel: String) -> String {
        var dir = game, out: [String] = []
        for comp in rel.split(separator: "/").map(String.init) {
            var use = comp
            if !fm.fileExists(atPath: dir + "/" + comp),
               let hit = (try? fm.contentsOfDirectory(atPath: dir))?.first(where: { $0.caseInsensitiveCompare(comp) == .orderedSame }) { use = hit }
            out.append(use); dir += "/" + use
        }
        return out.joined(separator: "/")
    }
    func isDir(_ p: String) -> Bool { var d: ObjCBool = false; return fm.fileExists(atPath: p, isDirectory: &d) && d.boolValue }
    func fileSize(_ p: String) -> Int64 { ((try? fm.attributesOfItem(atPath: p))?[.size] as? NSNumber)?.int64Value ?? 0 }
    /// every regular file under dir, as paths relative to it (links are not followed and not listed)
    func filesUnder(_ dir: String) -> [String] {
        guard let e = fm.enumerator(atPath: dir) else { return [] }
        var out: [String] = []
        for case let rel as String in e {
            let name = (rel as NSString).lastPathComponent
            if name.hasPrefix("._") || name == ".DS_Store" { continue }
            if (e.fileAttributes?[.type] as? FileAttributeType) == .typeRegular { out.append(rel) }
        }
        return out.sorted()
    }
    func dirSize(_ dir: String) -> Int64 { filesUnder(dir).reduce(0) { $0 + fileSize(dir + "/" + $1) } }
    /// removes folders left empty by a move, from `rel`'s folder upwards; never the mod folders themselves
    func pruneEmpty(root: String, rel: String, keep: Int) {
        var parts = rel.split(separator: "/").map(String.init); parts.removeLast()
        while parts.count > keep {
            let p = root + "/" + parts.joined(separator: "/")
            guard let c = try? fm.contentsOfDirectory(atPath: p), c.filter({ $0 != ".DS_Store" }).isEmpty else { return }
            try? fm.removeItem(atPath: p); parts.removeLast()
        }
    }
    func keepDepth(_ rel: String) -> Int {
        let l = rel.lowercased()
        for a in [ModStore.archiveArea, ModStore.tweakArea, ModStore.inputArea, ModStore.scriptArea, ModStore.cetArea, ModStore.pluginArea]
        where l.hasPrefix(a.lowercased() + "/") { return a.split(separator: "/").count }
        return 1
    }
    func move(_ from: String, _ to: String) throws {
        try fm.createDirectory(atPath: (to as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if fm.fileExists(atPath: to) { try fm.removeItem(atPath: to) }
        try fm.moveItem(atPath: from, toPath: to)
    }

    // ---------------------------------------------------------------- manifests
    func manifestPath(_ id: String) -> String { cyport + "/mods/" + id + ".json" }
    func save(_ m: ModManifest) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        try enc.encode(m).write(to: URL(fileURLWithPath: manifestPath(m.id)), options: .atomic)
    }
    func manifests() -> [ModManifest] {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let names = ((try? fm.contentsOfDirectory(atPath: cyport + "/mods")) ?? []).filter { $0.hasSuffix(".json") && !$0.hasPrefix("._") }
        return names.compactMap { n in
            guard let d = fm.contents(atPath: cyport + "/mods/" + n), let m = try? dec.decode(ModManifest.self, from: d) else { return nil }
            return m
        }
    }

    // ---------------------------------------------------------------- list
    /// full: also the dependency states, conflicts, profiles, save backups and the changes since the last Play
    func scan(full: Bool = true) -> ModList {
        var list = ModList()
        var all = manifests()
        // a file that is gone (deleted in Files) leaves the manifest; one whose files are all gone is dropped
        all = all.compactMap { m in
            var m = m
            let base = m.enabled ? game : cyport + "/disabled/" + m.id
            m.files = m.files.filter { fm.fileExists(atPath: base + "/" + $0.path) }
            if m.files.isEmpty { try? fm.removeItem(atPath: manifestPath(m.id)); try? fm.removeItem(atPath: cyport + "/disabled/" + m.id); return nil }
            return m
        }
        var claimed = Set<String>()
        for m in all where m.enabled { for f in m.files { claimed.insert(f.path.lowercased()) } }
        var ids = Set(all.map(\.id))
        list.mods = all.filter(\.managed).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        var un = all.filter { !$0.managed }

        func found(_ area: String, tag: String, kind: (String) -> String?, group: (String) -> String) {
            let areaRel = resolve(area), dir = game + "/" + areaRel
            var groups: [String: [ModFile]] = [:], kinds: [String: Set<String>] = [:], names: [String: String] = [:]
            for rel in filesUnder(dir) {
                let path = areaRel + "/" + rel
                guard !claimed.contains(path.lowercased()), let k = kind(rel) else { continue }
                let g = group(rel), key = g.lowercased()
                groups[key, default: []].append(ModFile(path: path, size: fileSize(game + "/" + path)))
                kinds[key, default: []].insert(k); if names[key] == nil { names[key] = g }
            }
            for (key, files) in groups {
                var id = "u." + tag + "." + ModStore.safeName(names[key] ?? key)
                var n = 2; while ids.contains(id) { id = "u." + tag + "." + ModStore.safeName(names[key] ?? key) + "-\(n)"; n += 1 }
                ids.insert(id)
                un.append(ModManifest(id: id, name: names[key] ?? key, source: "", installed: Date(timeIntervalSince1970: 0), managed: false,
                                      enabled: true, kinds: kinds[key, default: []].sorted(), frameworks: [], files: files, notes: [], skipped: []))
            }
        }
        let first: (String) -> String = { String($0.split(separator: "/").first ?? "") }
        found(ModStore.archiveArea, tag: "archive", kind: { r in
            let l = r.lowercased(); if r.contains("/") { return nil }
            return l.hasSuffix(".archive") ? "archive" : (l.hasSuffix(".xl") ? "archivexl" : nil)
        }, group: { r in
            var s = ModStore.stripOrder(r); for suf in [".archive.xl", ".xl", ".archive"] where s.lowercased().hasSuffix(suf) { s = String(s.dropLast(suf.count)); break }
            return s
        })
        found(ModStore.tweakArea, tag: "tweak", kind: { r in
            let l = r.lowercased(); return (l.hasSuffix(".yaml") || l.hasSuffix(".yml") || l.hasSuffix(".tweak")) ? "tweak" : nil }, group: first)
        found(ModStore.inputArea, tag: "input", kind: { $0.lowercased().hasSuffix(".xml") ? "input" : nil }, group: first)
        found(ModStore.scriptArea, tag: "script", kind: { $0.lowercased().hasSuffix(".reds") ? "redscript" : nil }, group: first)
        found(ModStore.cetArea, tag: "cet", kind: { $0.contains("/") ? "cet" : nil }, group: first)
        list.unmanaged = un.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let everything = list.mods + list.unmanaged
        func plugins(_ dir: String, enabled: Bool) {
            for n in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted() where isDir(dir + "/" + n) && !n.hasPrefix(".") {
                let users = everything.filter { m in m.frameworks.contains { !$0.optional && ModStore.frameworkKeys($0.name).contains(ModStore.norm(n)) } }.map(\.name)
                list.plugins.append(ModPlugin(name: n, enabled: enabled, size: dirSize(dir + "/" + n),
                                              scriptFiles: pluginScripts(dir + "/" + n).map { filesUnder($0).filter { $0.lowercased().hasSuffix(".reds") }.count } ?? 0,
                                              usedBy: users))
            }
        }
        plugins(game + "/" + resolve(ModStore.pluginArea), enabled: true)
        plugins(cyport + "/disabled-plugins", enabled: false)
        if full { decorate(&list) }
        return list
    }
    /// <plugin folder>/Scripts (any capitalisation), if it is there
    func pluginScripts(_ dir: String) -> String? {
        guard let n = (try? fm.contentsOfDirectory(atPath: dir))?.first(where: { $0.lowercased() == "scripts" }), isDir(dir + "/" + n) else { return nil }
        return dir + "/" + n
    }
    /// names (normalised) of what is on the phone and turned on: the RED4ext plugins + redscript
    func available() -> Set<String> {
        let dir = game + "/" + resolve(ModStore.pluginArea)
        var s = Set(((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { isDir(dir + "/" + $0) }.map(ModStore.norm))
        s.insert("redscript"); s.insert("red4ext")
        if s.contains("cyberenginetweaks") { s.insert("cet") }
        return s
    }

    // ---------------------------------------------------------------- on / off / delete
    func setEnabled(_ mod: ModManifest, _ on: Bool) throws -> ModManifest {
        var m = mod
        guard m.enabled != on else { return m }
        let off = cyport + "/disabled/" + m.id
        if on {
            let clash = m.files.filter { fm.fileExists(atPath: game + "/" + $0.path) }
            if let c = clash.first { throw ModError("Can't turn it on: \(c.path) already exists in the game folder (another mod has a file with the same name).") }
            for f in m.files where fm.fileExists(atPath: off + "/" + f.path) { try move(off + "/" + f.path, game + "/" + f.path) }
            try? fm.removeItem(atPath: off)
        } else {
            for f in m.files where fm.fileExists(atPath: game + "/" + f.path) {
                try move(game + "/" + f.path, off + "/" + f.path)
                pruneEmpty(root: game, rel: f.path, keep: keepDepth(f.path))
            }
        }
        m.enabled = on
        try save(m)
        modLog("\(on ? "enabled" : "disabled") \(m.id) (\(m.files.count) files)")
        return m
    }
    func delete(_ m: ModManifest) throws {
        let base = m.enabled ? game : cyport + "/disabled/" + m.id
        for f in m.files where fm.fileExists(atPath: base + "/" + f.path) {
            try fm.removeItem(atPath: base + "/" + f.path)
            if m.enabled { pruneEmpty(root: game, rel: f.path, keep: keepDepth(f.path)) }
        }
        try? fm.removeItem(atPath: cyport + "/disabled/" + m.id)
        try? fm.removeItem(atPath: manifestPath(m.id))
        modLog("deleted \(m.id) (\(m.files.count) files)")
    }
    func setPluginEnabled(_ name: String, _ on: Bool) throws {
        let live = game + "/" + resolve(ModStore.pluginArea) + "/" + name, off = cyport + "/disabled-plugins/" + name
        let (from, to) = on ? (off, live) : (live, off)
        guard isDir(from) else { throw ModError("Plugin folder not found: \(name)") }
        if fm.fileExists(atPath: to) { throw ModError("A folder named \(name) is already at the destination.") }
        try fm.createDirectory(atPath: (to as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try fm.moveItem(atPath: from, toPath: to)
        modLog("plugin \(name) \(on ? "enabled" : "disabled")")
    }

    // ---------------------------------------------------------------- import: unpack + sort
    static func modName(_ file: String) -> String {
        let base = (file as NSString).deletingPathExtension
        // Nexus names: "Name-1234-1-0-1700000000" or "Name 1234 1.0 2026-01-01T00-00Z abcdef"
        for pat in [#"^(.*?)-\d+(?:-\w+)*-\d{9,}$"#, #"^(.*?) \d+ \S+ \d{4}-\d\d-\d\dT\S+ \S+$"#] {
            if let re = try? NSRegularExpression(pattern: pat), let m = re.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)),
               let r = Range(m.range(at: 1), in: base), !base[r].trimmingCharacters(in: .whitespaces).isEmpty {
                return base[r].trimmingCharacters(in: .whitespaces)
            }
        }
        return base
    }
    func freeSpace() -> Int64 {
        let v = try? URL(fileURLWithPath: cyport).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return max(v?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(v?.volumeAvailableCapacity ?? 0))
    }

    /// Unpacks `file` (zip / 7z / rar / a bare .archive) into a scratch folder and sorts what is inside. Nothing in the
    /// game folder changes; install(plan) or discard(plan) must follow.
    func analyze(file: String, displayName: String? = nil) throws -> ModPlan {
        let fileName = displayName ?? (file as NSString).lastPathComponent
        let tmp = cyport + "/tmp/import-" + UUID().uuidString
        try fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        do {
            if fileName.lowercased().hasSuffix(".archive") {
                try fm.copyItem(atPath: file, toPath: tmp + "/" + ModStore.safeName(fileName))
            } else {
                var err = [CChar](repeating: 0, count: 1024)
                let room = max(freeSpace() - 300_000_000, 50_000_000)
                let n = MSModExtract(file, tmp, room, &err, err.count)
                if n < 0 { throw ModError(String(cString: err)) }
                modLog("unpacked \(fileName): \(n) files")
            }
            return try sort(tmp: tmp, fileName: fileName)
        } catch { try? fm.removeItem(atPath: tmp); throw error }
    }
    func discard(_ plan: ModPlan) { try? fm.removeItem(atPath: plan.tmp) }

    private func sort(tmp: String, fileName: String) throws -> ModPlan {
        let name = ModStore.modName(fileName), id = ModStore.safeName(name)
        var plan = ModPlan(id: id, name: name, source: fileName, tmp: tmp)
        plan.updates = fm.fileExists(atPath: manifestPath(id))
        let have = available()
        let files = filesUnder(tmp).filter { !$0.lowercased().contains("__macosx") }
        var unsupported: [String: [String]] = [:], order: [String] = []
        func no(_ why: String, _ rel: String) { if unsupported[why] == nil { order.append(why) }; unsupported[why, default: []].append(rel) }
        let redmods = redmodPackages(tmp: tmp, files: files)
        let archArea = resolve(ModStore.archiveArea), tweakArea = resolve(ModStore.tweakArea), inputArea = resolve(ModStore.inputArea)
        let scriptArea = resolve(ModStore.scriptArea), cetArea = resolve(ModStore.cetArea)
        var reds: [String] = [], audioware = false
        func add(_ rel: String, _ dest: String, _ kind: String) {
            plan.items.append(ModPlanItem(id: plan.items.count, src: tmp + "/" + rel, rel: rel, dest: dest, kind: kind, size: fileSize(tmp + "/" + rel)))
        }
        for rel in files.sorted(by: { $0.lowercased() < $1.lowercased() }) {
            let parts = rel.split(separator: "/").map(String.init), lp = parts.map { $0.lowercased() }, fn = lp[lp.count - 1]
            let r6 = lp.count >= 3 ? (0..<(lp.count - 2)).first(where: { lp[$0] == "r6" }) : nil
            let area = r6.map { lp[$0 + 1] }, sub = r6.map { Array(parts[($0 + 2)...]) } ?? []
            let native = [".dll", ".exe", ".asi", ".dylib", ".so", ".bat", ".cmd", ".ps1", ".sh"].contains { fn.hasSuffix($0) }
            if let pkg = redmods.first(where: { rel.hasPrefix($0.root) }) {
                // REDmod is off in the Mac game: the package's parts go where the classic loaders read them
                let inner = Array(parts[pkg.depth...]), top = inner.count > 1 ? inner[0].lowercased() : ""
                let sound = [".wav", ".wem", ".ogg", ".mp3", ".flac", ".bnk"].contains { fn.hasSuffix($0) }
                if native { no("Programs inside a REDmod package (.dll/.exe/...): never installed", rel) }
                else if top == "customsounds" || top == "sound" || top == "sounds" || sound {
                    no("REDmod custom sounds (\(pkg.name)): not converted. Sound mods need the game's audio modding path, which CyPort does not have yet", rel)
                } else if top == "archives", fn.hasSuffix(".archive") {
                    // the prefix keeps REDmod's own order: after the classic archives, packages by name
                    add(rel, archArea + "/" + ModStore.safeName("zz_redmod_" + pkg.name + "_" + parts[parts.count - 1]), "archive")
                } else if top == "archives", fn.hasSuffix(".xl") {
                    add(rel, archArea + "/" + ModStore.safeName("zz_redmod_" + pkg.name + "_" + parts[parts.count - 1]), "archivexl")
                } else if top == "scripts", fn.hasSuffix(".reds") {
                    add(rel, scriptArea + "/" + ([pkg.name] + inner.dropFirst()).map(ModStore.safeName).joined(separator: "/"), "redscript"); reds.append(tmp + "/" + rel)
                } else if top == "scripts", fn.hasSuffix(".script") || fn.hasSuffix(".ws") {
                    no("REDmod .script files (\(pkg.name)): whole copies of the game's own script files, which only REDmod's compiler (redMod.exe, Windows) can merge. Look for the mod's redscript (.reds) version", rel)
                } else if top == "tweaks", fn.hasSuffix(".tweak") || fn.hasSuffix(".yaml") || fn.hasSuffix(".yml") {
                    add(rel, tweakArea + "/" + ([pkg.name] + inner.dropFirst()).map(ModStore.safeName).joined(separator: "/"), "tweak")
                } else { plan.ignored.append(rel) }
            } else if let c = lp.firstIndex(of: "cyber_engine_tweaks") {
                // .../cyber_engine_tweaks/mods/<Mod>/<files>: a CET Lua mod
                if c + 3 < lp.count, lp[c + 1] == "mods" {
                    if native { no("Programs inside a CET mod (.dll/.exe/...): never installed", rel) }
                    else { add(rel, cetArea + "/" + parts[(c + 2)...].joined(separator: "/"), "cet") }
                } else { no("Cyber Engine Tweaks itself: CyPort has its own build", rel) }
            } else if fn.hasSuffix(".asi") {
                no("Windows .asi loader: cannot run on iOS", rel)
            } else if fn.hasSuffix(".dll") {
                if let i = lp.firstIndex(of: "red4ext") {
                    let pname = (i + 2 < parts.count - 1 && lp[i + 1] == "plugins") ? parts[i + 2] : parts[parts.count - 1]
                    no(have.contains(ModStore.norm(pname)) ? "RED4ext plugin '\(pname)' (Windows .dll): its iOS build is already on the phone, this package is not needed"
                                                           : "RED4ext plugin '\(pname)' (Windows .dll): needs an iOS build first", rel)
                } else { no("Windows native code (.dll): cannot run on iOS", rel) }
            } else if lp.contains("red4ext"), let i = lp.firstIndex(of: "plugins") {
                let pname = i + 1 < parts.count - 1 ? parts[i + 1] : "?"
                no(have.contains(ModStore.norm(pname)) ? "Files of RED4ext plugin '\(pname)': already on the phone with its iOS build"
                                                       : "Files of RED4ext plugin '\(pname)': need the plugin's iOS build first", rel)
            } else if lp[0] == "bin", lp.contains("x64") {
                no("bin/x64 files (Windows loaders): not supported", rel)
            } else if native {
                no("Programs / scripts for Windows (.exe, .bat, ...): never installed", rel)
            } else if fn.hasSuffix(".archive") {
                add(rel, archArea + "/" + ModStore.safeName(parts[parts.count - 1]), "archive")
            } else if fn.hasSuffix(".xl"), lp.contains("archive") {
                add(rel, archArea + "/" + ModStore.safeName(parts[parts.count - 1]), "archivexl")
            } else if area == "tweaks", fn.hasSuffix(".yaml") || fn.hasSuffix(".yml") || fn.hasSuffix(".tweak") {
                add(rel, tweakArea + "/" + sub.map(ModStore.safeName).joined(separator: "/"), "tweak")
            } else if area == "input", fn.hasSuffix(".xml") {
                add(rel, inputArea + "/" + ModStore.safeName(sub.joined(separator: "_")), "input")
            } else if area == "scripts", fn.hasSuffix(".reds") {
                // loose files of r6/scripts get a folder of their own, so the mod can be told apart later
                let s = sub.count == 1 ? [id] + sub : sub
                add(rel, scriptArea + "/" + s.map(ModStore.safeName).joined(separator: "/"), "redscript"); reds.append(tmp + "/" + rel)
            } else if lp.contains("audioware"), r6 != nil || lp[0] == "audioware" {
                no("Audioware sound files (r6/audioware): not installed. Audioware is not on CyPort yet", rel); audioware = true
            } else if [".yaml", ".yml", ".tweak", ".reds", ".xl", ".lua"].contains(where: { fn.hasSuffix($0) }) {
                plan.ignored.append(rel + " (not in the usual folder, skipped)")
            } else if fn.hasSuffix(".ini"), lp.contains("engine") {
                no("engine/config .ini (Windows config tweaks): not handled", rel)
            } else {
                plan.ignored.append(rel)
            }
        }
        plan.unsupported = order.map { ($0, unsupported[$0] ?? []) }

        for pkg in redmods {
            let n = plan.items.filter { $0.rel.hasPrefix(pkg.root) }.count
            plan.notes.append("REDmod package \"\(pkg.name)\"\(pkg.version.map { " " + $0 } ?? ""): \(n) file\(n == 1 ? "" : "s") converted (archives to archive/Mac/mod, .reds to r6/scripts, tweaks to r6/tweaks for TweakXL)" + (pkg.sounds > 0 ? "; its \(pkg.sounds) custom sound\(pkg.sounds == 1 ? "" : "s") left out" : ""))
            if plan.version == nil { plan.version = pkg.version }
        }
        plan.frameworks = detectFrameworks(plan: plan, tmp: tmp, files: files, reds: reds, audioware: audioware, redmod: !redmods.isEmpty)
        plan.deps = deps(for: plan.frameworks, plugins: pluginStates())

        // what the archives replace, against the list of the Mac game's resources
        let hashes = GameHashes.shared
        plan.hashesChecked = hashes != nil
        let addsNew = plan.items.contains { $0.kind == "archivexl" || $0.kind == "tweak" }
        var seenDest = Set<String>()
        var dirs = Set<String>()
        var planHashes: [(name: String, hashes: [UInt64])] = []
        var audioSounds = 0
        for i in plan.items.indices where plan.items[i].kind == "archive" {
            dirs.insert((plan.items[i].rel as NSString).deletingLastPathComponent)
            do {
                // a PC audio mod: the scratch copy gets the Mac file table before anything is counted (ModManagerAudio.swift)
                var onlyBanks = false
                if let info = try? ModAudio.inspect(plan.items[i].src), info.needed {
                    let r = try ModAudio.convert(plan.items[i].src)
                    plan.items[i].audio = r.notes
                    audioSounds += r.renamed; onlyBanks = !r.written
                }
                let hs = try ModStore.archiveHashes(plan.items[i].src)
                planHashes.append(((plan.items[i].dest as NSString).lastPathComponent, hs))
                if onlyBanks {
                    plan.items[i].verdict = "Does nothing on the Mac game: it only has a sound bank (.bnk) of another Wwise version, which the game refuses (it loads bank version \(ModAudio.macBankVersion) only)"
                    plan.items[i].good = false
                } else {
                    let v = ModStore.archiveVerdict(hs, size: plan.items[i].size, addsNew: addsNew)
                    plan.items[i].verdict = ([v.text] + plan.items[i].audio).joined(separator: "\n"); plan.items[i].good = v.good
                }
            } catch { plan.items[i].verdict = "Not a Cyberpunk .archive: \(error.localizedDescription)"; plan.items[i].good = false }
            plan.items[i].selected = plan.items[i].good
        }
        if audioSounds > 0 {
            plan.notes.append("Audio: \(audioSounds) sound\(audioSounds == 1 ? "" : "s") converted for the Mac game. PC mods keep loose sounds at base\\sound\\soundbanks\\<id>.wem; the Mac game reads base\\sound\\soundbanks\\media\\<id>.wem. Only the archive's file table is rewritten, the sound itself is untouched.")
        }
        plan.variants = dirs.count > 1
        // a folder that says "choose one": only its first good archive is pre-selected
        var pickedIn = Set<String>()
        for i in plan.items.indices where plan.items[i].kind == "archive" && plan.items[i].selected {
            let dir = (plan.items[i].rel as NSString).deletingLastPathComponent.lowercased()
            guard ["choose one", "choose only one", "pick one", "select one", "only one", "one of"].contains(where: { dir.contains($0) }) else { continue }
            if !pickedIn.insert(dir).inserted { plan.items[i].selected = false }
        }
        // two files that would get the same name (variants): only the first is pre-selected
        for i in plan.items.indices where plan.items[i].selected {
            if !seenDest.insert(plan.items[i].dest.lowercased()).inserted { plan.items[i].selected = false; plan.variants = true }
        }
        plan.conflicts = planConflicts(plan, hashes: planHashes)
        return plan
    }

    /// the resource hashes in a .archive (RDAR): header <4s I Q I>, at the index <I I Q I I I> + 56-byte entries
    static func archiveHashes(_ path: String) throws -> [UInt64] {
        guard let f = FileHandle(forReadingAtPath: path) else { throw ModError("can't open") }
        defer { try? f.close() }
        let head = f.readData(ofLength: 40)
        guard head.count >= 20, head.prefix(4) == Data("RDAR".utf8) else { throw ModError("wrong file type") }
        func u32(_ d: Data, _ o: Int) -> UInt32 { d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) } }
        func u64(_ d: Data, _ o: Int) -> UInt64 { d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt64.self) } }
        let ipos = u64(head, 8)
        try f.seek(toOffset: ipos)
        let ih = f.readData(ofLength: 28)
        guard ih.count == 28 else { throw ModError("cut short") }
        let n = Int(u32(ih, 16))
        guard n <= 4_000_000 else { throw ModError("damaged index") }
        var out: [UInt64] = []; out.reserveCapacity(n)
        var left = n
        while left > 0 {
            let take = min(left, 16384), d = f.readData(ofLength: take * 56)
            guard d.count == take * 56 else { throw ModError("cut short") }
            for i in 0..<take { out.append(u64(d, i * 56)) }
            left -= take
        }
        return out
    }

    /// Installs the selected files of a plan (they are moved out of the scratch folder) and writes the manifest.
    func install(_ plan: ModPlan) throws -> ModManifest {
        defer { discard(plan) }
        // an .archive.xl goes with its .archive: not installed when that archive was left out
        let skippedArchives = Set(plan.items.filter { $0.kind == "archive" && !$0.selected }.map { ($0.rel as NSString).lastPathComponent.lowercased() })
            .subtracting(plan.items.filter { $0.kind == "archive" && $0.selected }.map { ($0.rel as NSString).lastPathComponent.lowercased() })
        var chosen = plan.items.filter { it in
            guard it.selected else { return false }
            if it.kind == "archivexl" {
                let n = (it.rel as NSString).lastPathComponent.lowercased()
                if n.hasSuffix(".archive.xl"), skippedArchives.contains(String(n.dropLast(3))) { return false }
            }
            return true
        }
        guard !chosen.isEmpty else { throw ModError("Nothing selected to install.") }
        var seen = Set<String>()
        for it in chosen where !seen.insert(it.dest.lowercased()).inserted {
            throw ModError("Two selected files would get the same name (\((it.dest as NSString).lastPathComponent)). They are variants: pick one.")
        }
        var others = manifests()
        // archives keep CyPort's load-order number: the one this mod had, or the next free one when numbering is in use
        var prefix = ""
        if let old = others.first(where: { $0.id == plan.id }) {
            prefix = old.files.compactMap { ModStore.orderPrefix(($0.path as NSString).lastPathComponent) }.first ?? ""
            try delete(old); others.removeAll { $0.id == plan.id }
        }
        if prefix.isEmpty, let top = highestOrderNumber(others) { prefix = String(format: "%03d__", min(top + 1, 999)) }
        chosen = chosen.map { it -> ModPlanItem in
            guard !prefix.isEmpty, it.kind == "archive" || it.kind == "archivexl" else { return it }
            let d = it.dest as NSString
            var out = it
            out.dest = d.deletingLastPathComponent + "/" + prefix + d.lastPathComponent
            return out
        }
        var files: [ModFile] = []
        do {
            for it in chosen {
                // a file another mod installed under the same name is replaced, and leaves that mod's list
                for var o in others where o.enabled && o.files.contains(where: { $0.path.lowercased() == it.dest.lowercased() }) {
                    o.files.removeAll { $0.path.lowercased() == it.dest.lowercased() }
                    if o.files.isEmpty { try? fm.removeItem(atPath: manifestPath(o.id)) } else { try save(o) }
                    if let k = others.firstIndex(where: { $0.id == o.id }) { others[k] = o }
                }
                try move(it.src, game + "/" + it.dest)
                files.append(ModFile(path: it.dest, size: it.size))
            }
        } catch {
            for f in files { try? fm.removeItem(atPath: game + "/" + f.path); pruneEmpty(root: game, rel: f.path, keep: keepDepth(f.path)) }
            throw error
        }
        var skipped = plan.unsupported.map { "\($0.why) (\($0.files.count) file\($0.files.count == 1 ? "" : "s"))" }
        let left = plan.items.filter { it in !chosen.contains { $0.id == it.id } }
        if !left.isEmpty { skipped.append("Not selected: " + left.map { ($0.rel as NSString).lastPathComponent }.joined(separator: ", ")) }
        var kinds: [String] = []
        for it in chosen where !kinds.contains(it.kind) { kinds.append(it.kind) }
        let m = ModManifest(id: plan.id, name: plan.name, source: plan.source, installed: Date(), managed: true, enabled: true, kinds: kinds,
                            frameworks: plan.frameworks, files: files,
                            notes: plan.notes + chosen.filter { !$0.verdict.isEmpty }.flatMap { it in it.verdict.split(separator: "\n").map { (it.rel as NSString).lastPathComponent + ": " + $0 } },
                            skipped: skipped, version: plan.version)
        try save(m)
        modLog("installed \(m.id) from \(m.source): \(files.count) files, kinds \(kinds.joined(separator: ","))")
        return m
    }

    // ---------------------------------------------------------------- scripts
    static let signature = Data("$REDSCRIPT_SIGNATURE".utf8)
    /// true for a script blob that redscript did not write (= the game's own)
    static func isPristine(_ path: String) -> Bool {
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped), d.count > 1_000_000,
              d.prefix(4) == Data("REDS".utf8) else { return false }
        return d.range(of: signature) == nil
    }
    var pristinePath: String { cyport + "/final.redscripts.original" }
    var cacheDir: String { game + "/" + resolve("r6/cache") }
    var hasPristine: Bool {
        ModStore.isPristine(pristinePath) || ModStore.isPristine(cacheDir + "/final.redscripts.bk") || ModStore.isPristine(cacheDir + "/final.redscripts")
    }
    /// makes sure CYPORT/final.redscripts.original is the game's own blob (see the top of this file)
    func ensurePristine() throws -> String {
        if ModStore.isPristine(pristinePath) { return pristinePath }
        for c in [cacheDir + "/final.redscripts.bk", cacheDir + "/final.redscripts"] where ModStore.isPristine(c) {
            try? fm.removeItem(atPath: pristinePath)
            try fm.copyItem(atPath: c, toPath: pristinePath)
            modLog("original scripts kept from \((c as NSString).lastPathComponent) (\(fileSize(pristinePath)) bytes)")
            return pristinePath
        }
        throw ModError("The game's original scripts are not on the phone: every final.redscripts here was already compiled with mods. Use \"Choose original scripts…\" and pick the original final.redscripts (from the game's r6/cache folder on the Mac, or your backup).")
    }
    /// "Choose original scripts…": a file the user picked becomes the pristine blob, if it is one
    func adoptOriginal(from file: String) throws {
        guard ModStore.isPristine(file) else { throw ModError("That file is not the game's original final.redscripts (it is not a script blob, or it was already compiled with mods).") }
        try? fm.removeItem(atPath: pristinePath)
        try fm.copyItem(atPath: file, toPath: pristinePath)
        modLog("original scripts set by the user (\(fileSize(pristinePath)) bytes)")
    }
    /// script folders of the plugins that are turned on (red4ext/plugins/<Name>/Scripts)
    func pluginScriptDirs() -> [String] {
        let dir = game + "/" + resolve(ModStore.pluginArea)
        return ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted().compactMap { n in
            // only a plugin that can load (its .dylib is there): scripts declare the plugin's natives, and the game stops
            // while loading scripts when a native has nothing behind it
            guard ((try? fm.contentsOfDirectory(atPath: dir + "/" + n)) ?? []).contains(where: { $0.lowercased().hasSuffix(".dylib") }),
                  let s = pluginScripts(dir + "/" + n), filesUnder(s).contains(where: { $0.lowercased().hasSuffix(".reds") }) else { return nil }
            return s
        }
    }
    /// things the user should know before a compile replaces the current scripts
    func compileWarnings() -> [String] {
        var w: [String] = []
        let dir = game + "/" + resolve(ModStore.pluginArea)
        for n in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted() where ModStore.scriptPlugins.contains(ModStore.norm(n)) {
            let s = pluginScripts(dir + "/" + n)
            if s == nil || !filesUnder(s!).contains(where: { $0.lowercased().hasSuffix(".reds") }) {
                w.append("\(n) is on, but its scripts are not on the phone (red4ext/plugins/\(n)/Scripts is empty). Compiling now leaves its script API out: mods that use it stop working and the game may stop while loading.")
            }
        }
        let cur = cacheDir + "/final.redscripts"
        let modReds = filesUnder(game + "/" + resolve(ModStore.scriptArea)).filter { $0.lowercased().hasSuffix(".reds") }.count
        if fm.fileExists(atPath: cur), !ModStore.isPristine(cur), !fm.fileExists(atPath: cyport + "/compiled-here"), modReds == 0 {
            w.append("The scripts in use were compiled on the Mac. No script mod (.reds) is in r6/scripts on the phone, so compiling here drops the script mods that were compiled in. Import those mods here first to keep them.")
        }
        return w
    }

    /// Compiles r6/scripts + the enabled plugins' Scripts against the original blob. The game's final.redscripts is
    /// replaced only when the compile succeeds (written beside it, then renamed over it); on failure nothing changes.
    func compileScripts() -> ModCompileResult {
        let t0 = Date()
        do {
            let pristine = try ensurePristine()
            let r6 = game + "/" + resolve("r6")
            try fm.createDirectory(atPath: game + "/" + resolve(ModStore.scriptArea), withIntermediateDirectories: true)
            try fm.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
            // scc keeps a .bk / .ts beside its input and "restores" a backup over it: it gets a private copy every time
            let work = cyport + "/tmp/scc"
            try? fm.removeItem(atPath: work)
            try fm.createDirectory(atPath: work, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: work) }
            let input = work + "/final.redscripts", output = cacheDir + "/final.redscripts.new", final = cacheDir + "/final.redscripts"
            try fm.copyItem(atPath: pristine, toPath: input)
            try? fm.removeItem(atPath: output)
            let logPath = r6 + "/logs/redscript_rCURRENT.log"
            try? fm.removeItem(atPath: logPath)
            let extra = pluginScriptDirs()
            modLog("compile: r6 \(r6), \(extra.count) plugin script folders: \(extra.map { (($0 as NSString).deletingLastPathComponent as NSString).lastPathComponent }.joined(separator: ", "))")
            var err = [CChar](repeating: 0, count: 1 << 16)
            let cs = extra.map { strdup($0) }
            defer { cs.forEach { free($0) } }
            let ptrs = cs.map { UnsafePointer<CChar>($0) }
            let rc = ptrs.withUnsafeBufferPointer { MSModCompile(ModStore.sccLibPath, r6, input, output, $0.baseAddress, Int32(extra.count), &err, err.count) }
            let log = (fm.contents(atPath: logPath)).map { String(decoding: $0, as: UTF8.self) } ?? ""
            if rc != 0 || fileSize(output) < 1_000_000 || log.contains("[ERROR") {
                try? fm.removeItem(atPath: output)
                var text = String(cString: err)
                let lines = log.split(separator: "\n").map(String.init)
                if let i = lines.firstIndex(where: { $0.contains("[ERROR") }) {
                    let tail = lines[i...].joined(separator: "\n")
                    if !text.isEmpty, !tail.contains(text.prefix(60)) { text += "\n\n" + tail } else { text = tail }
                }
                if text.isEmpty { text = "The compiler gave no reason (no log written)." }
                text = text.replacingOccurrences(of: game + "/", with: "").replacingOccurrences(of: game.replacingOccurrences(of: "/private/", with: "/") + "/", with: "")
                modLog("compile FAILED: \(text.prefix(300))")
                return ModCompileResult(ok: false, message: "Scripts did not compile. The game keeps the scripts it had.", detail: text)
            }
            if fm.fileExists(atPath: final) {
                try? fm.removeItem(atPath: cyport + "/final.redscripts.previous")
                try? fm.copyItem(atPath: final, toPath: cyport + "/final.redscripts.previous")
            }
            guard rename(output, final) == 0 else { throw ModError("Couldn't put the new scripts in place: \(String(cString: strerror(errno)))") }
            fm.createFile(atPath: cyport + "/compiled-here", contents: Data())
            let secs = Date().timeIntervalSince(t0)
            let warn = log.split(separator: "\n").filter { $0.contains("[WARN") }.count
            modLog(String(format: "compile ok: %lld bytes in %.1f s, %d warnings", fileSize(final), secs, warn))
            return ModCompileResult(ok: true, message: String(format: "Scripts compiled in %.1f s%@.", secs, warn > 0 ? " (\(warn) warning\(warn == 1 ? "" : "s"))" : ""), detail: "")
        } catch {
            modLog("compile not run: \(error.localizedDescription)")
            return ModCompileResult(ok: false, message: "Scripts were not compiled.", detail: error.localizedDescription)
        }
    }
    /// "Restore original scripts": the game's own blob back in place (script mods and plugin scripts stop applying)
    func restoreOriginalScripts() throws {
        let p = try ensurePristine(), final = cacheDir + "/final.redscripts", tmp = cacheDir + "/final.redscripts.new"
        try? fm.removeItem(atPath: tmp)
        try fm.copyItem(atPath: p, toPath: tmp)
        guard rename(tmp, final) == 0 else { throw ModError("Couldn't restore: \(String(cString: strerror(errno)))") }
        try? fm.removeItem(atPath: cyport + "/compiled-here")
        modLog("original scripts restored")
    }
}

/// the Mac game's resource hashes (sorted u64, little endian), memory-mapped
final class GameHashes {
    static let shared: GameHashes? = {
        guard let p = ModStore.hashesPath, let d = try? Data(contentsOf: URL(fileURLWithPath: p), options: .alwaysMapped), d.count >= 8 else { return nil }
        return GameHashes(d)
    }()
    private let data: Data
    private let count: Int
    private init(_ d: Data) { data = d; count = d.count / 8 }
    func contains(_ h: UInt64) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            var lo = 0, hi = count
            while lo < hi {
                let mid = (lo + hi) / 2, v = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: mid * 8, as: UInt64.self))
                if v < h { lo = mid + 1 } else { hi = mid }
            }
            return lo < count && UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: lo * 8, as: UInt64.self)) == h
        }
    }
}
