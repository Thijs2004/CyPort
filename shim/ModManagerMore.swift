// ModManagerMore.swift - the parts of the mod manager around the basic install / on / off (ModManager.swift):
//   REDmod packages    which folders of an unpacked archive are REDmod packages (the conversion itself is in ModStore.sort)
//   dependencies       the frameworks a mod uses (from its files, its readme / json metadata) and whether each one is on the phone
//   conflicts          two mods that are on and ship the same archive resource (RDAR index), replace the same script method,
//                      or a mod that is off whose file name is taken; load order of archive/Mac/mod by a numeric name prefix
//   profiles           CYPORT/profiles/<name>.json: a named set of enabled mods + plugins
//   save backups       CYPORT/save-backups/<date>/: a copy of the saves folder before scripts or plugins change
//   since last Play    CYPORT/last-play.json, written when Play is pressed (Launcher.swift)
//   settings           CYPORT/settings.json
// PC audio mods (loose .wem at the PC path) are converted in ModManagerAudio.swift.
//
// Load order: the game reads archive/Mac/mod in name order and the first archive that has a resource wins. "Load order" on
// the screen renames every mod archive to "NNN__<name>" (NNN = its place); "Remove numbers" renames them back. With the
// setting on, the same order is also written to archive/Mac/mod/modlist.txt (the Mac game has the code that reads it; that it
// honours it was not seen running, so it is off by default and the numbers alone decide).
import Foundation

struct ModDep: Hashable {
    enum State: String { case on, off, missing, unknown }
    var name: String
    var why: String
    var optional: Bool
    var state: State
    var plugin: String?         // its folder in red4ext/plugins (or CyPort/disabled-plugins) when it is on the phone
    var problem: Bool { !optional && (state == .off || state == .missing) }
}

struct ModConflict: Hashable {
    var other: String           // the other mod's id
    var otherName: String
    var kind: String            // archive, script, file
    var count: Int
    var detail: String
    var wins: Bool?             // archives: this mod's copy is the one the game uses
}

struct ModSettings: Codable, Hashable {
    var backupSaves = true      // copy the saves before scripts are recompiled or a plugin is switched
    var keepBackups = 5
    var sort = "name"           // name, size, newest, on
    var filter = "all"          // all, on, off, problems
    var writeModlist = false
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        backupSaves = try c.decodeIfPresent(Bool.self, forKey: .backupSaves) ?? true
        keepBackups = max(1, try c.decodeIfPresent(Int.self, forKey: .keepBackups) ?? 5)
        sort = try c.decodeIfPresent(String.self, forKey: .sort) ?? "name"
        filter = try c.decodeIfPresent(String.self, forKey: .filter) ?? "all"
        writeModlist = try c.decodeIfPresent(Bool.self, forKey: .writeModlist) ?? false
    }
}

struct ModProfile: Codable, Identifiable, Hashable {
    var name: String
    var saved: Date
    var mods: [String]          // ids of the mods that were on
    var known: [String]         // ids of every mod that was installed (a mod added later is left as it is)
    var plugins: [String]       // plugin folders that were on
    var knownPlugins: [String]
    var id: String { name }
}

struct ModBackup: Identifiable, Hashable {
    var name: String            // folder name = date
    var size: Int64
    var files: Int
    var id: String { name }
}

struct ModProfileResult {
    var ok: Bool
    var message: String
    var detail: String = ""
}

struct RedmodPackage {
    var root: String            // "mods/<name>/" inside the archive ("" when info.json is at the top)
    var depth: Int              // path components in root
    var name: String
    var version: String?
    var sounds: Int             // customSounds entries in info.json
}

/// what the mods looked like when Play was last pressed
private struct ModPlaySnapshot: Codable {
    struct Mod: Codable { var name: String; var enabled: Bool; var installed: Date; var size: Int64 }
    var date: Date
    var mods: [String: Mod]
    var plugins: [String: Bool]
    var scripts: String
    var order: [String]
}

extension ModStore {
    // ---------------------------------------------------------------- frameworks
    /// display name, the names it goes by (normalised: plugin folder, script module), how a readme spells it
    static let catalog: [(name: String, keys: [String], pattern: String)] = [
        ("ArchiveXL", ["archivexl"], #"archive ?xl"#),
        ("TweakXL", ["tweakxl"], #"tweak ?xl"#),
        ("Codeware", ["codeware"], #"codeware"#),
        ("CET", ["cet", "cyberenginetweaks"], #"cyber ?engine ?tweaks|\bcet\b"#),
        ("Mod Settings", ["modsettings", "modsettingsmodule"], #"mod ?settings"#),
        ("Input Loader", ["inputloader"], #"input ?loader"#),
        ("RedFileSystem", ["redfilesystem", "redfs"], #"red ?file ?system|\bredfs\b"#),
        ("RedData", ["reddata"], #"\breddata\b"#),
        ("RedHttpClient", ["redhttpclient"], #"red ?http ?client"#),
        ("Audioware", ["audioware"], #"audioware"#),
        ("RED4ext", ["red4ext"], #"red4ext"#),
        ("redscript", ["redscript"], #"redscript"#),
    ]
    static func frameworkKeys(_ name: String) -> [String] {
        let n = norm(name)
        return catalog.first { $0.keys.contains(n) }?.keys ?? [n]
    }
    static func frameworkName(_ name: String) -> String {
        let n = norm(name)
        return catalog.first { $0.keys.contains(n) }?.name ?? name
    }

    /// the plugin folders on the phone: on (red4ext/plugins) and off (CyPort/disabled-plugins)
    func pluginStates() -> [(name: String, enabled: Bool)] {
        var out: [(String, Bool)] = []
        for (dir, on) in [(game + "/" + resolve(ModStore.pluginArea), true), (cyport + "/disabled-plugins", false)] {
            for n in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted() where isDir(dir + "/" + n) && !n.hasPrefix(".") { out.append((n, on)) }
        }
        return out
    }
    func deps(for fw: [ModFramework], plugins: [(name: String, enabled: Bool)]) -> [ModDep] {
        fw.map { f in
            let keys = ModStore.frameworkKeys(f.name), known = ModStore.catalog.contains { $0.keys.contains(ModStore.norm(f.name)) }
            var state = ModDep.State.unknown, plugin: String?
            if keys.contains("redscript") { state = fm.fileExists(atPath: ModStore.sccLibPath) ? .on : .missing }
            else if keys.contains("red4ext") { state = .on }
            else if let p = plugins.first(where: { $0.enabled && keys.contains(ModStore.norm($0.name)) }) { state = .on; plugin = p.name }
            else if let p = plugins.first(where: { !$0.enabled && keys.contains(ModStore.norm($0.name)) }) { state = .off; plugin = p.name }
            else if known { state = .missing }
            return ModDep(name: ModStore.frameworkName(f.name), why: f.why, optional: f.optional, state: state, plugin: plugin)
        }
    }
    /// a mod found in the game folder has no list of frameworks: the kinds of its files say the obvious ones
    func frameworks(of m: ModManifest) -> [ModFramework] {
        if !m.frameworks.isEmpty { return m.frameworks }
        var fw: [ModFramework] = []
        for (k, n, why) in [("archivexl", "ArchiveXL", ".xl files"), ("tweak", "TweakXL", "r6/tweaks files"), ("input", "Input Loader", "r6/input .xml"),
                            ("cet", "CET", "Cyber Engine Tweaks Lua mod"), ("redscript", "redscript", ".reds scripts")] where m.kinds.contains(k) {
            fw.append(ModFramework(name: n, why: why, optional: false))
        }
        return fw
    }

    private static func matches(_ pat: String, _ s: String, _ opts: NSRegularExpression.Options = [.anchorsMatchLines]) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pat, options: opts) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
            Range(m.range(at: m.numberOfRanges > 1 ? 1 : 0), in: s).map { String(s[$0]) }
        }
    }
    private func text(_ path: String, max: Int) -> String? {
        guard fileSize(path) <= Int64(max), let d = fm.contents(atPath: path) else { return nil }
        return String(decoding: d, as: UTF8.self)
    }

    /// the frameworks an unpacked mod uses: from the kinds of its files, its scripts, and what its readme / json files name
    func detectFrameworks(plan: ModPlan, tmp: String, files: [String], reds: [String], audioware: Bool, redmod: Bool) -> [ModFramework] {
        var fw: [ModFramework] = []
        func use(_ n: String, _ why: String, _ opt: Bool = false) {
            let name = ModStore.frameworkName(n)
            if let i = fw.firstIndex(where: { $0.name == name }) {
                if fw[i].optional && !opt { fw[i] = ModFramework(name: name, why: why, optional: false) }
            } else { fw.append(ModFramework(name: name, why: why, optional: opt)) }
        }
        if plan.items.contains(where: { $0.kind == "archivexl" }) { use("ArchiveXL", ".archive.xl files") }
        if plan.items.contains(where: { $0.kind == "tweak" }) { use("TweakXL", redmod ? "tweak files (REDmod .tweak files are read by TweakXL)" : "r6/tweaks files") }
        if plan.items.contains(where: { $0.kind == "input" }) { use("Input Loader", "r6/input .xml") }
        if plan.items.contains(where: { $0.kind == "cet" }) { use("CET", "Cyber Engine Tweaks Lua mod") }
        if audioware { use("Audioware", "r6/audioware sound files") }
        if !reds.isEmpty { use("redscript", ".reds scripts (compiled on the phone)") }
        var own = Set<String>(), imports = Set<String>(), optional = Set<String>()
        for p in reds {
            guard let src = text(p, max: 8_000_000) else { continue }
            own.formUnion(ModStore.matches(#"^\s*module\s+([\w.]+)"#, src).map { String($0.split(separator: ".")[0]) })
            imports.formUnion(ModStore.matches(#"^\s*import\s+([\w.]+)"#, src).map { String($0.split(separator: ".")[0]) })
            optional.formUnion(ModStore.matches(#"ModuleExists\(\s*"([^"]+)""#, src).map { String($0.split(separator: ".")[0]) })
            if src.contains("@runtimeProperty(\"ModSettings") { optional.insert("ModSettings") }
        }
        for m in imports.subtracting(own).sorted() { use(m, "import \(m) in .reds") }
        for m in optional.subtracting(imports).subtracting(own).sorted() { use(m, "optional: used only if present", true) }
        // CET Lua mods name the native frameworks they call
        let luaNames = ModStore.catalog.filter { !["CET", "redscript", "RED4ext", "Mod Settings", "Input Loader"].contains($0.name) }
        for it in plan.items where it.kind == "cet" && it.rel.lowercased().hasSuffix(".lua") {
            guard let src = text(it.src, max: 1_000_000) else { continue }
            for c in luaNames where !ModStore.matches("\\b" + c.name + "\\b", src, []).isEmpty { use(c.name, "named in its Lua code", true) }
        }
        // readme / requirements text and json metadata (the Nexus requirements list itself is not in the download)
        for rel in files {
            let l = rel.lowercased(), fn = (l as NSString).lastPathComponent
            let isText = fn.hasSuffix(".txt") || fn.hasSuffix(".md") || fn.hasPrefix("readme") || fn == "meta.ini" || fn == "info.xml"
            let isJson = fn.hasSuffix(".json") && !l.contains("cyber_engine_tweaks")
            guard isText || isJson, let src = text(tmp + "/" + rel, max: 300_000) else { continue }
            var lines: [String] = []
            if isJson, let j = try? JSONSerialization.jsonObject(with: Data(src.utf8)) {
                // "dependencies" / "requires" / "requirements": a list of names, or an object whose keys are the names
                func walk(_ v: Any, _ inside: Bool) {
                    if let d = v as? [String: Any] {
                        for (k, x) in d {
                            let kk = k.lowercased(), dep = kk.contains("depend") || kk.contains("requir")
                            if inside { lines.append("requires " + k) }
                            walk(x, dep)
                        }
                    } else if let a = v as? [Any] { for x in a { walk(x, inside) } }
                    else if let t = v as? String, inside { lines.append("requires " + t) }
                }
                walk(j, false)
            } else {
                lines = src.split(whereSeparator: \.isNewline).map(String.init).filter { $0.count < 400 }
                // a "Requirements:" heading covers the list lines right under it
                var out: [String] = [], carry = 0
                for ln in lines {
                    let t = ln.trimmingCharacters(in: .whitespaces)
                    if !ModStore.matches(#"requir|depend|prerequisite|\bneeds?\b"#, t, [.caseInsensitive]).isEmpty { out.append(t); carry = t.hasSuffix(":") || t.count < 30 ? 8 : 0 }
                    else if carry > 0 { if t.isEmpty { carry = 0 } else { out.append("requires " + t); carry -= 1 } }
                }
                lines = out
            }
            for ln in lines {
                if !ModStore.matches(#"\bnot?\b|n't|without|no longer|incompatib|conflict"#, ln, [.caseInsensitive]).isEmpty { continue }
                let opt = !ModStore.matches(#"optional|recommend|compatib|support|suggest"#, ln, [.caseInsensitive]).isEmpty
                for c in ModStore.catalog where !ModStore.matches(c.pattern, ln, [.caseInsensitive]).isEmpty {
                    use(c.name, "named as a requirement in \((rel as NSString).lastPathComponent)", opt)
                }
            }
        }
        return fw
    }

    // ---------------------------------------------------------------- REDmod
    /// the REDmod packages in an unpacked archive: mods/<name>/info.json, or an info.json with a name beside archives/ scripts/ tweaks/
    func redmodPackages(tmp: String, files: [String]) -> [RedmodPackage] {
        var out: [RedmodPackage] = []
        let lower = files.map { $0.lowercased() }
        for rel in files {
            let parts = rel.split(separator: "/").map(String.init), lp = parts.map { $0.lowercased() }
            guard lp.last == "info.json", !lp.contains("cyber_engine_tweaks"), !lp.contains("red4ext"), !lp.contains("r6") else { continue }
            let root = parts.count > 1 ? parts.dropLast().joined(separator: "/") + "/" : "", lroot = root.lowercased()
            let underMods = lp.count >= 3 && lp[lp.count - 3] == "mods"
            let hasParts = lower.contains { f in ["archives/", "scripts/", "tweaks/", "customsounds/"].contains { f.hasPrefix(lroot + $0) } }
            var name = parts.count > 1 ? parts[parts.count - 2] : "", version: String?, sounds = 0, named = false
            if let src = text(tmp + "/" + rel, max: 4_000_000), let j = (try? JSONSerialization.jsonObject(with: Data(src.utf8))) as? [String: Any] {
                if let n = j["name"] as? String, !n.isEmpty { named = true; if name.isEmpty { name = n } }
                if let v = j["version"] as? String, !v.isEmpty { version = v } else if let v = j["version"] as? NSNumber { version = v.stringValue }
                sounds = (j["customSounds"] as? [Any])?.count ?? 0
            }
            guard underMods || (hasParts && named), !name.isEmpty else { continue }
            out.append(RedmodPackage(root: root, depth: parts.count - 1, name: name, version: version, sounds: sounds))
        }
        // the deepest root first, so a package inside another folder with an info.json is matched before it
        return out.sorted { $0.depth > $1.depth }
    }

    // ---------------------------------------------------------------- settings
    private var settingsPath: String { cyport + "/settings.json" }
    var settings: ModSettings {
        get { fm.contents(atPath: settingsPath).flatMap { try? JSONDecoder().decode(ModSettings.self, from: $0) } ?? ModSettings() }
        set {
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? enc.encode(newValue).write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
        }
    }

    // ---------------------------------------------------------------- everything the screen shows besides the lists
    func decorate(_ list: inout ModList) {
        let ps = list.plugins.map { (name: $0.name, enabled: $0.enabled) }
        for m in list.mods + list.unmanaged {
            let d = deps(for: frameworks(of: m), plugins: ps)
            if !d.isEmpty { list.deps[m.id] = d }
        }
        list.conflicts = conflicts(list)
        list.audio = audioNeeds(list)
        list.orderActive = (list.mods + list.unmanaged).contains { m in m.files.contains { ModStore.orderPrefix(($0.path as NSString).lastPathComponent) != nil } }
        list.settings = settings
        list.profiles = profiles()
        list.backups = backups()
        list.changes = changesSincePlay(list)
        syncModlist(list)
    }

    // ---------------------------------------------------------------- conflicts
    private static let cacheLock = NSLock()
    private static var hashCache: [String: (stamp: String, hashes: [UInt64])] = [:]
    private static var methodCache: [String: (stamp: String, methods: [String])] = [:]
    func stamp(_ path: String) -> String {
        let a = try? fm.attributesOfItem(atPath: path)
        return "\((a?[.size] as? NSNumber)?.int64Value ?? -1)|\((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
    }
    func cachedHashes(_ path: String) -> [UInt64] {
        let st = stamp(path)
        ModStore.cacheLock.lock(); let hit = ModStore.hashCache[path]; ModStore.cacheLock.unlock()
        if let h = hit, h.stamp == st { return h.hashes }
        let hs = (try? ModStore.archiveHashes(path)) ?? []
        ModStore.cacheLock.lock(); ModStore.hashCache[path] = (st, hs); ModStore.cacheLock.unlock()
        return hs
    }
    /// "Class.Method" of every @replaceMethod in a .reds file
    private func cachedMethods(_ path: String) -> [String] {
        let st = stamp(path)
        ModStore.cacheLock.lock(); let hit = ModStore.methodCache[path]; ModStore.cacheLock.unlock()
        if let h = hit, h.stamp == st { return h.methods }
        var out: [String] = []
        if let src = text(path, max: 8_000_000), src.contains("@replaceMethod"),
           let re = try? NSRegularExpression(pattern: #"@replaceMethod\(\s*([\w.]+)\s*\)[^{};]{0,300}?\bfunc\s+(\w+)"#, options: [.dotMatchesLineSeparators]) {
            for m in re.matches(in: src, range: NSRange(src.startIndex..., in: src)) {
                if let a = Range(m.range(at: 1), in: src), let b = Range(m.range(at: 2), in: src) { out.append(String(src[a]) + "." + String(src[b])) }
            }
        }
        ModStore.cacheLock.lock(); ModStore.methodCache[path] = (st, out); ModStore.cacheLock.unlock()
        return out
    }
    /// the game's order for two archive names: by bytes ("!" and digits before letters, capitals before small letters)
    static func loadsBefore(_ a: String, _ b: String) -> Bool { Array(a.utf8).lexicographicallyPrecedes(Array(b.utf8)) }
    func isArchive(_ f: ModFile) -> Bool {
        f.path.lowercased().hasSuffix(".archive") && f.path.lowercased().hasPrefix(ModStore.archiveArea.lowercased() + "/")
    }

    func conflicts(_ list: ModList) -> [String: [ModConflict]] {
        let all = list.mods + list.unmanaged, on = all.filter(\.enabled)
        var out: [String: [ModConflict]] = [:]
        // archives: the same resource hash in two mods that are on
        var arcs: [(mod: Int, name: String)] = []
        var owner: [UInt64: Int32] = [:]
        var pairs: [UInt64: Int] = [:]                    // (first archive, second archive) -> shared resources
        for (mi, m) in on.enumerated() {
            for f in m.files where isArchive(f) {
                let ai = arcs.count
                arcs.append((mi, (f.path as NSString).lastPathComponent))
                for h in cachedHashes(game + "/" + f.path) {
                    if let o = owner[h] { if arcs[Int(o)].mod != mi { pairs[UInt64(o) << 32 | UInt64(ai), default: 0] += 1 } }
                    else { owner[h] = Int32(ai) }
                }
            }
        }
        var byMods: [String: (a: Int, b: Int, count: Int, top: Int, aFirst: Bool)] = [:]
        for (k, n) in pairs {
            let x = arcs[Int(k >> 32)], y = arcs[Int(k & 0xffff_ffff)]
            let (a, b, an, bn) = x.mod < y.mod ? (x.mod, y.mod, x.name, y.name) : (y.mod, x.mod, y.name, x.name)
            let key = "\(a)|\(b)"
            var e = byMods[key] ?? (a, b, 0, 0, true)
            e.count += n
            if n > e.top { e.top = n; e.aFirst = ModStore.loadsBefore(an, bn) }       // the pair of archives that shares the most decides who "wins"
            byMods[key] = e
        }
        for e in byMods.values {
            let a = on[e.a], b = on[e.b], what = "\(e.count) archive resource\(e.count == 1 ? "" : "s")"
            out[a.id, default: []].append(ModConflict(other: b.id, otherName: b.name, kind: "archive", count: e.count,
                detail: "Shares \(what) with \(b.name). " + (e.aFirst ? "This mod loads first, so its version is used." : "\(b.name) loads first, so its version is used, not this mod's."), wins: e.aFirst))
            out[b.id, default: []].append(ModConflict(other: a.id, otherName: a.name, kind: "archive", count: e.count,
                detail: "Shares \(what) with \(a.name). " + (e.aFirst ? "\(a.name) loads first, so its version is used, not this mod's." : "This mod loads first, so its version is used."), wins: !e.aFirst))
        }
        // scripts: the same method replaced (@replaceMethod) by two mods that are on - only one replacement can apply
        var methods: [String: [Int]] = [:]
        for (mi, m) in on.enumerated() where m.hasScripts {
            var seen = Set<String>()
            for f in m.files where f.path.lowercased().hasSuffix(".reds") {
                for k in cachedMethods(game + "/" + f.path) where seen.insert(k).inserted { methods[k, default: []].append(mi) }
            }
        }
        var scriptPairs: [String: [String]] = [:]
        for (k, ms) in methods where ms.count > 1 {
            for i in 0..<ms.count { for j in (i + 1)..<ms.count { scriptPairs["\(ms[i])|\(ms[j])", default: []].append(k) } }
        }
        for (key, ks) in scriptPairs {
            let p = key.split(separator: "|").compactMap { Int($0) }, a = on[p[0]], b = on[p[1]], names = ks.sorted()
            let what = names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " and \(names.count - 3) more" : "")
            out[a.id, default: []].append(ModConflict(other: b.id, otherName: b.name, kind: "script", count: names.count,
                detail: "Replaces the same script method\(names.count == 1 ? "" : "s") as \(b.name) (\(what)). Only one replacement applies; use one of the two mods.", wins: nil))
            out[b.id, default: []].append(ModConflict(other: a.id, otherName: a.name, kind: "script", count: names.count,
                detail: "Replaces the same script method\(names.count == 1 ? "" : "s") as \(a.name) (\(what)). Only one replacement applies; use one of the two mods.", wins: nil))
        }
        // a mod that is off whose file names are taken in the game folder: it can't be turned on beside the mod that has them
        var holder: [String: Int] = [:]
        for (mi, m) in on.enumerated() { for f in m.files { holder[f.path.lowercased()] = mi } }
        for m in all where !m.enabled {
            var hit: [Int: [String]] = [:]
            for f in m.files { if let o = holder[f.path.lowercased()] { hit[o, default: []].append((f.path as NSString).lastPathComponent) } }
            for (o, names) in hit {
                out[m.id, default: []].append(ModConflict(other: on[o].id, otherName: on[o].name, kind: "file", count: names.count,
                    detail: "Installs the same file\(names.count == 1 ? "" : "s") as \(on[o].name) (\(names.prefix(3).joined(separator: ", "))\(names.count > 3 ? ", …" : "")). Turn \(on[o].name) off before turning this on.", wins: nil))
            }
        }
        return out.mapValues { $0.sorted { ($0.kind, $0.otherName) < ($1.kind, $1.otherName) } }
    }

    /// what an import would share with the mods that are on (shown before it is installed)
    func planConflicts(_ plan: ModPlan, hashes: [(name: String, hashes: [UInt64])]) -> [String] {
        var out: [String] = []
        let on = manifests().filter { $0.enabled && $0.id != plan.id }
        for it in plan.items {
            if let m = on.first(where: { $0.files.contains { $0.path.lowercased() == it.dest.lowercased() } }) {
                out.append("\((it.dest as NSString).lastPathComponent) replaces the file of the same name installed by \(m.name).")
            }
        }
        guard !hashes.isEmpty else { return out }
        var mine: [UInt64: Int] = [:]
        for (i, a) in hashes.enumerated() { for h in a.hashes where mine[h] == nil { mine[h] = i } }
        let numbered = highestOrderNumber(on) != nil
        for m in on {
            var n = 0, first: Bool?
            for f in m.files where isArchive(f) {
                let theirs = (f.path as NSString).lastPathComponent
                var k = 0, idx = 0
                for h in cachedHashes(game + "/" + f.path) { if let i = mine[h] { k += 1; idx = i } }
                if k > 0 { n += k; if first == nil { first = numbered ? false : ModStore.loadsBefore(hashes[idx].name, theirs) } }
            }
            if n > 0 {
                out.append("Shares \(n) archive resource\(n == 1 ? "" : "s") with \(m.name): " + ((first ?? false) ? "this mod would load first and win." : "\(m.name) loads first and wins.") + " The order can be changed under Load order.")
            }
        }
        return out
    }

    // ---------------------------------------------------------------- load order
    private static let orderRE = try? NSRegularExpression(pattern: #"^(\d{3})__"#)
    /// "007__" when the file name carries CyPort's load-order number
    static func orderPrefix(_ name: String) -> String? {
        guard let m = orderRE?.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)), let r = Range(m.range, in: name) else { return nil }
        return String(name[r])
    }
    static func stripOrder(_ name: String) -> String { orderPrefix(name).map { String(name.dropFirst($0.count)) } ?? name }
    /// the highest load-order number in use (nil: the archives are not numbered)
    func highestOrderNumber(_ mods: [ModManifest]) -> Int? {
        var names = mods.flatMap { $0.files.map { ($0.path as NSString).lastPathComponent } }
        names += (try? fm.contentsOfDirectory(atPath: game + "/" + resolve(ModStore.archiveArea))) ?? []
        return names.compactMap { ModStore.orderPrefix($0).flatMap { Int($0.prefix(3)) } }.max()
    }
    private func ordered(_ f: ModFile) -> Bool {
        let l = f.path.lowercased()
        return l.hasPrefix(ModStore.archiveArea.lowercased() + "/") && (l.hasSuffix(".archive") || l.hasSuffix(".xl"))
            && !l.dropFirst(ModStore.archiveArea.count + 1).contains("/")
    }
    /// the mods with archives, in the order the game loads them (a mod with several archives stands where its first one does)
    func archiveMods(_ list: ModList) -> [ModManifest] {
        func key(_ m: ModManifest) -> String? {
            m.files.filter { isArchive($0) }.map { ($0.path as NSString).lastPathComponent }.min { ModStore.loadsBefore($0, $1) }
        }
        return (list.mods + list.unmanaged).compactMap { m in key(m).map { (m, $0) } }.sorted { ModStore.loadsBefore($0.1, $1.1) }.map(\.0)
    }
    /// Renames the archives (and their .xl files) so the mods load in the order of `ids`: "001__name.archive", "002__…".
    /// ids == nil takes the numbers off again. Returns the names that could not be renamed.
    @discardableResult
    func applyOrder(_ ids: [String]?, list: ModList) throws -> [String] {
        let all = list.mods + list.unmanaged
        var failed: [String] = []
        let saved = Set(manifests().map(\.id))
        let targets: [(ModManifest, String)] = ids.map { ids in
            ids.enumerated().compactMap { i, id in all.first { $0.id == id }.map { ($0, String(format: "%03d__", min(i + 1, 999))) } }
        } ?? all.map { ($0, "") }
        for (mod, prefix) in targets {
            var m = mod, changed = false
            let base = m.enabled ? game : cyport + "/disabled/" + m.id
            for i in m.files.indices where ordered(m.files[i]) {
                let p = m.files[i].path as NSString
                let name = prefix + ModStore.stripOrder(p.lastPathComponent)
                guard name != p.lastPathComponent else { continue }
                let to = p.deletingLastPathComponent + "/" + name
                if fm.fileExists(atPath: base + "/" + to) { failed.append(p.lastPathComponent); continue }
                try fm.moveItem(atPath: base + "/" + (p as String), toPath: base + "/" + to)
                m.files[i].path = to; changed = true
            }
            // a mod found in the game folder has no manifest while it is on: its files are simply found again under the new names
            if changed, saved.contains(m.id) { try save(m) }
        }
        modLog(ids == nil ? "load order: numbers removed" : "load order set: \(ids!.joined(separator: ", "))")
        return failed
    }
    /// archive/Mac/mod/modlist.txt with the archives in load order, while the setting is on (removed again when it is off)
    func syncModlist(_ list: ModList) {
        let dir = game + "/" + resolve(ModStore.archiveArea), path = dir + "/modlist.txt", mark = cyport + "/modlist-written"
        if settings.writeModlist {
            let names = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.lowercased().hasSuffix(".archive") && !$0.hasPrefix("._") }
                .sorted { ModStore.loadsBefore($0, $1) }
            let text = names.joined(separator: "\n") + (names.isEmpty ? "" : "\n")
            if names.isEmpty { if fm.fileExists(atPath: mark) { try? fm.removeItem(atPath: path) }; return }
            if fm.fileExists(atPath: path), !fm.fileExists(atPath: mark) { return }                  // someone else's modlist.txt: left alone
            if (fm.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) }) != text {
                try? Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
                fm.createFile(atPath: mark, contents: Data())
            }
        } else if fm.fileExists(atPath: mark) {
            try? fm.removeItem(atPath: path); try? fm.removeItem(atPath: mark)
        }
    }

    // ---------------------------------------------------------------- profiles
    private var profileDir: String { cyport + "/profiles" }
    private func profilePath(_ name: String) -> String { profileDir + "/" + ModStore.safeName(name) + ".json" }
    func profiles() -> [ModProfile] {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return ((try? fm.contentsOfDirectory(atPath: profileDir)) ?? []).filter { $0.hasSuffix(".json") && !$0.hasPrefix("._") }.compactMap { n in
            fm.contents(atPath: profileDir + "/" + n).flatMap { try? dec.decode(ModProfile.self, from: $0) }
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    /// a name no saved profile has: "Profile 1", "Profile 2", …
    func freeProfileName() -> String {
        let have = Set(profiles().map { ModStore.safeName($0.name).lowercased() })
        var n = 1
        while have.contains("profile_\(n)") { n += 1 }
        return "Profile \(n)"
    }
    @discardableResult
    func saveProfile(name: String) throws -> ModProfile {
        let nm = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nm.isEmpty else { throw ModError("Give the profile a name.") }
        let l = scan(full: false), all = l.mods + l.unmanaged
        let p = ModProfile(name: nm, saved: Date(), mods: all.filter(\.enabled).map(\.id).sorted(), known: all.map(\.id).sorted(),
                           plugins: l.plugins.filter(\.enabled).map(\.name).sorted(), knownPlugins: l.plugins.map(\.name).sorted())
        try fm.createDirectory(atPath: profileDir, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        try enc.encode(p).write(to: URL(fileURLWithPath: profilePath(nm)), options: .atomic)
        modLog("profile saved: \(nm) (\(p.mods.count) mods on, \(p.plugins.count) plugins on)")
        return p
    }
    func deleteProfile(_ p: ModProfile) { try? fm.removeItem(atPath: profilePath(p.name)); modLog("profile deleted: \(p.name)") }
    /// what loading a profile would change: (mods to turn off, mods to turn on, plugins off, plugins on, mods it names that are gone)
    func profileDiff(_ p: ModProfile, _ l: ModList) -> (off: [ModManifest], on: [ModManifest], pluginsOff: [ModPlugin], pluginsOn: [ModPlugin], gone: [String]) {
        let all = l.mods + l.unmanaged, want = Set(p.mods), known = Set(p.known)
        let wantP = Set(p.plugins.map(ModStore.norm)), knownP = Set(p.knownPlugins.map(ModStore.norm))
        return (all.filter { $0.enabled && known.contains($0.id) && !want.contains($0.id) },
                all.filter { !$0.enabled && want.contains($0.id) },
                l.plugins.filter { $0.enabled && knownP.contains(ModStore.norm($0.name)) && !wantP.contains(ModStore.norm($0.name)) },
                l.plugins.filter { !$0.enabled && wantP.contains(ModStore.norm($0.name)) },
                p.mods.filter { id in !all.contains { $0.id == id } })
    }
    private func pluginHasScripts(_ p: ModPlugin) -> Bool { p.scriptFiles > 0 || ModStore.scriptPlugins.contains(ModStore.norm(p.name)) }
    func profileNeedsCompile(_ p: ModProfile, _ l: ModList) -> Bool {
        let d = profileDiff(p, l)
        return (d.off + d.on).contains(where: \.hasScripts) || (d.pluginsOff + d.pluginsOn).contains(where: pluginHasScripts)
    }
    /// Switches mods and plugins to what the profile says and recompiles the scripts when a script mod or a plugin with
    /// scripts changed. If the scripts don't compile, every switch is undone.
    func applyProfile(_ p: ModProfile) -> ModProfileResult {
        let l = scan(full: false), d = profileDiff(p, l)
        if d.off.isEmpty && d.on.isEmpty && d.pluginsOff.isEmpty && d.pluginsOn.isEmpty {
            return ModProfileResult(ok: true, message: "\(p.name): everything is already set this way." + (d.gone.isEmpty ? "" : " \(d.gone.count) mod\(d.gone.count == 1 ? "" : "s") of the profile \(d.gone.count == 1 ? "is" : "are") no longer installed."))
        }
        let compile = profileNeedsCompile(p, l)
        var note = ""
        if compile || !d.pluginsOff.isEmpty || !d.pluginsOn.isEmpty { note = backupSaves() }
        var undo: [() -> Void] = []
        func rollback() { for u in undo.reversed() { u() } }
        do {
            // off first, so a file name two mods share is free before the other one is turned on
            for m in d.off { let m2 = try setEnabled(m, false); undo.append { _ = try? self.setEnabled(m2, true) } }
            for pl in d.pluginsOff { try setPluginEnabled(pl.name, false); undo.append { try? self.setPluginEnabled(pl.name, true) } }
            for pl in d.pluginsOn { try setPluginEnabled(pl.name, true); undo.append { try? self.setPluginEnabled(pl.name, false) } }
            for m in d.on { let m2 = try setEnabled(m, true); undo.append { _ = try? self.setEnabled(m2, false) } }
        } catch {
            rollback()
            return ModProfileResult(ok: false, message: "\(p.name) was not loaded: \(error.localizedDescription)")
        }
        var msg = "\(p.name) loaded: \(d.on.count) mod\(d.on.count == 1 ? "" : "s") on, \(d.off.count) off"
        if !d.pluginsOn.isEmpty || !d.pluginsOff.isEmpty { msg += ", \(d.pluginsOn.count) plugin\(d.pluginsOn.count == 1 ? "" : "s") on, \(d.pluginsOff.count) off" }
        msg += "."
        if compile {
            let r = compileScripts()
            if !r.ok { rollback(); return ModProfileResult(ok: false, message: "\(p.name) was not loaded: \(r.message)", detail: r.detail) }
            msg += " " + r.message
        }
        if !d.gone.isEmpty { msg += " Not installed any more: \(d.gone.joined(separator: ", "))." }
        if !note.isEmpty { msg += " " + note }
        modLog("profile loaded: \(p.name)")
        return ModProfileResult(ok: true, message: msg)
    }

    // ---------------------------------------------------------------- save backups
    /// the game's saves: <app container>/Library/Application Support/CD Projekt Red/Cyberpunk 2077/saves (the same folder as GameCloud.saves)
    static var savesPath: String = (NSSearchPathForDirectoriesInDomains(.applicationSupportDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory())
        + "/CD Projekt Red/Cyberpunk 2077/saves"
    private var backupDir: String { cyport + "/save-backups" }
    private func savesSignature() -> (sig: String, files: Int, size: Int64) {
        var n = 0, size: Int64 = 0, newest = 0.0
        for rel in filesUnder(ModStore.savesPath) {
            let a = try? fm.attributesOfItem(atPath: ModStore.savesPath + "/" + rel)
            n += 1; size += (a?[.size] as? NSNumber)?.int64Value ?? 0
            newest = max(newest, (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        }
        return ("\(n)|\(size)|\(Int64(newest))", n, size)
    }
    func backups() -> [ModBackup] {
        ((try? fm.contentsOfDirectory(atPath: backupDir)) ?? []).filter { isDir(backupDir + "/" + $0) && !$0.hasPrefix(".") }.sorted(by: >).map { n in
            let files = filesUnder(backupDir + "/" + n)
            return ModBackup(name: n, size: files.reduce(0) { $0 + fileSize(backupDir + "/" + n + "/" + $1) }, files: files.count)
        }
    }
    private func pruneBackups() {
        let keep = max(1, settings.keepBackups)
        for b in backups().dropFirst(keep) { try? fm.removeItem(atPath: backupDir + "/" + b.name); modLog("save backup removed (keeping \(keep)): \(b.name)") }
    }
    /// Copies the saves folder to CYPORT/save-backups/<date>/ when the setting is on (always with force), unless nothing in
    /// it changed since the newest backup. Returns a sentence for the status line ("" when nothing was copied).
    @discardableResult
    func backupSaves(force: Bool = false, tag: String = "") -> String {
        guard force || settings.backupSaves else { return "" }
        let s = savesSignature()
        guard s.files > 0 else { return force ? "There are no saves to back up yet." : "" }
        let sigName = ".cyport-saves"
        if let last = backups().first, let d = fm.contents(atPath: backupDir + "/" + last.name + "/" + sigName), String(decoding: d, as: UTF8.self) == s.sig {
            return force ? "The saves have not changed since the last backup (\(last.name))." : ""
        }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        var name = f.string(from: Date()) + tag, k = 2
        while fm.fileExists(atPath: backupDir + "/" + name) { name = f.string(from: Date()) + tag + "-\(k)"; k += 1 }
        do {
            try fm.createDirectory(atPath: backupDir, withIntermediateDirectories: true)
            try fm.copyItem(atPath: ModStore.savesPath, toPath: backupDir + "/" + name)
            try? Data(s.sig.utf8).write(to: URL(fileURLWithPath: backupDir + "/" + name + "/" + sigName))
        } catch {
            try? fm.removeItem(atPath: backupDir + "/" + name)
            modLog("save backup FAILED: \(error.localizedDescription)")
            return "The saves could not be backed up (\(error.localizedDescription))."
        }
        modLog("saves backed up to save-backups/\(name) (\(s.files) files, \(s.size) bytes)")
        pruneBackups()
        return "Saves backed up (\(name))."
    }
    /// Puts a backup back as the saves folder. The saves that were there are kept as a backup of their own first.
    func restoreBackup(_ b: ModBackup) throws {
        let src = backupDir + "/" + b.name
        guard isDir(src) else { throw ModError("That backup is gone.") }
        backupSaves(force: true, tag: "_before-restore")
        let tmp = ModStore.savesPath + ".restoring"
        try? fm.removeItem(atPath: tmp)
        try fm.createDirectory(atPath: (ModStore.savesPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try fm.copyItem(atPath: src, toPath: tmp)
        try? fm.removeItem(atPath: tmp + "/.cyport-saves")
        if fm.fileExists(atPath: ModStore.savesPath) { try fm.removeItem(atPath: ModStore.savesPath) }
        try fm.moveItem(atPath: tmp, toPath: ModStore.savesPath)
        modLog("saves restored from save-backups/\(b.name)")
    }

    // ---------------------------------------------------------------- since the last Play
    private var playPath: String { cyport + "/last-play.json" }
    private func snapshot(_ l: ModList) -> ModPlaySnapshot {
        var mods: [String: ModPlaySnapshot.Mod] = [:]
        for m in l.mods + l.unmanaged { mods[m.id] = .init(name: m.name, enabled: m.enabled, installed: m.installed, size: m.size) }
        let blob = game + "/" + resolve("r6/cache") + "/final.redscripts"
        return ModPlaySnapshot(date: Date(), mods: mods, plugins: Dictionary(l.plugins.map { ($0.name, $0.enabled) }, uniquingKeysWith: { a, _ in a }),
                               scripts: fm.fileExists(atPath: blob) ? stamp(blob) : "", order: archiveMods(l).filter(\.enabled).map(\.id))
    }
    /// called when Play is pressed: remembers what is installed and on, for "since the last Play"
    static func notePlay(gameRoot: String) {
        guard !gameRoot.isEmpty else { return }
        let s = ModStore(gameRoot: gameRoot)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try? enc.encode(s.snapshot(s.scan(full: false))).write(to: URL(fileURLWithPath: s.playPath), options: .atomic)
    }
    func changesSincePlay(_ l: ModList) -> [String]? {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let d = fm.contents(atPath: playPath), let old = try? dec.decode(ModPlaySnapshot.self, from: d) else { return nil }
        let now = snapshot(l)
        var out: [String] = []
        func names(_ ids: [String], _ from: [String: ModPlaySnapshot.Mod]) -> String { ids.compactMap { from[$0]?.name }.sorted().joined(separator: ", ") }
        let added = now.mods.keys.filter { old.mods[$0] == nil }, removed = old.mods.keys.filter { now.mods[$0] == nil }
        let both = now.mods.keys.filter { old.mods[$0] != nil }
        let turnedOn = both.filter { now.mods[$0]!.enabled && !old.mods[$0]!.enabled }, turnedOff = both.filter { !now.mods[$0]!.enabled && old.mods[$0]!.enabled }
        let updated = both.filter { abs(now.mods[$0]!.installed.timeIntervalSince(old.mods[$0]!.installed)) > 1 || now.mods[$0]!.size != old.mods[$0]!.size }
        if !added.isEmpty { out.append("Added: " + names(added, now.mods) + (added.contains { !now.mods[$0]!.enabled } ? " (not all are on)" : "")) }
        if !removed.isEmpty { out.append("Removed: " + names(removed, old.mods)) }
        if !turnedOn.isEmpty { out.append("Turned on: " + names(turnedOn, now.mods)) }
        if !turnedOff.isEmpty { out.append("Turned off: " + names(turnedOff, now.mods)) }
        if !updated.isEmpty { out.append("Replaced with another version: " + names(updated, now.mods)) }
        let pOn = now.plugins.filter { $0.value && old.plugins[$0.key] == false }.keys.sorted(), pOff = now.plugins.filter { !$0.value && old.plugins[$0.key] == true }.keys.sorted()
        let pNew = now.plugins.keys.filter { old.plugins[$0] == nil }.sorted(), pGone = old.plugins.keys.filter { now.plugins[$0] == nil }.sorted()
        if !pOn.isEmpty { out.append("Plugins turned on: " + pOn.joined(separator: ", ")) }
        if !pOff.isEmpty { out.append("Plugins turned off: " + pOff.joined(separator: ", ")) }
        if !pNew.isEmpty { out.append("New plugins: " + pNew.joined(separator: ", ")) }
        if !pGone.isEmpty { out.append("Plugins removed: " + pGone.joined(separator: ", ")) }
        let common = Set(now.order).intersection(old.order)
        if now.order.filter(common.contains) != old.order.filter(common.contains) { out.append("The archive load order changed") }
        if now.scripts != old.scripts { out.append(now.scripts.isEmpty ? "The compiled scripts are gone" : "Scripts were recompiled") }
        return out
    }
}
