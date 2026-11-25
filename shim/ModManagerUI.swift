// ModManagerUI.swift - the Mods screen (SwiftUI), opened from the start screen (Launcher.swift). The work is in
// ModManager.swift and ModManagerMore.swift (ModStore). Everything that can be tapped can also be reached with a controller:
//   D-pad / left stick  move      A  turn on/off (or press the button)      X  details      Y  import a mod      B  back / close
// The panels (details, import preview, load order, profiles, questions, compiler errors) are drawn by this screen itself
// rather than as system sheets and alerts, so the controller works in them too; each button shows the controller button
// that presses it. Only the Files picker and the keyboard (search box, profile name) are the system's.
import SwiftUI
import UIKit
import GameController
import UniformTypeIdentifiers

private let mmYellow = Color(red: 0.99, green: 0.93, blue: 0.04)
private let mmRed = Color(red: 1.0, green: 0.0, blue: 0.24)
private let mmOrange = Color(red: 1.0, green: 0.55, blue: 0.1)

private func mmSize(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
private func mmJoin(_ a: String, _ note: String) -> String { note.isEmpty ? a : a + " " + note }
private func mmCount(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
private func mmKind(_ k: String) -> String {
    switch k {
    case "archive": return "Archive"
    case "archivexl": return "ArchiveXL"
    case "tweak": return "TweakXL"
    case "input": return "Input"
    case "redscript": return "Scripts"
    case "cet": return "CET Lua"
    default: return k
    }
}
private func mmIcon(_ kinds: [String]) -> String {
    if kinds.contains("redscript") { return "chevron.left.forwardslash.chevron.right" }
    if kinds.contains("cet") { return "terminal" }
    if kinds.contains("tweak") { return "slider.horizontal.3" }
    if kinds.contains("input") { return "keyboard" }
    return "shippingbox"
}
private let mmSorts = [("name", "Name"), ("size", "Size"), ("newest", "Newest"), ("on", "On first")]
private let mmFilters = [("all", "All"), ("on", "On"), ("off", "Off"), ("problems", "Problems")]
private let mmKeeps = [3, 5, 10, 20]
/// "2026-11-17_20-49-04" -> "17 Nov 2026 at 20:49"
private func mmBackupDate(_ name: String) -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    guard name.count >= 19, let d = f.date(from: String(name.prefix(19))) else { return name }
    return d.formatted(date: .abbreviated, time: .shortened) + (name.contains("before-restore") ? "  (from before a restore)" : "")
}

private struct MMQuestion {
    var title: String
    var message: String
    var yes: String
    var destructive = false
    var backupOffer = false         // shows the "back up saves first" switch (X)
    var action: () -> Void
}
private struct MMError {
    var title: String
    var text: String
    var bad = true
}
private enum MMRow: Hashable {
    case search, sort, filter, importMod, changes, mod(String), plugin(String), order, modlist, saveProfile, profile(String)
    case recompile, restore, original, backupToggle, backupKeep, backupNow, backup(String)
}
private enum MMPick { case mod, original }
private enum MMPad { case up, down, a, b, x, y }

@MainActor private final class ModManagerModel: ObservableObject {
    let store: ModStore
    @Published var list = ModList()
    @Published var loaded = false
    @Published var busy: String?
    @Published var status: String?
    @Published var statusBad = false
    @Published var hasPristine = true
    @Published var plan: ModPlan?
    @Published var detailID: String?
    @Published var deleteArmed = false
    @Published var question: MMQuestion?
    @Published var error: MMError?
    @Published var picking = false
    @Published var focus: MMRow?
    @Published var search = ""
    @Published var typing = false                   // the search box has the keyboard
    @Published var order: [ModManifest]?            // the load order panel: the mods with archives, first = loads first
    @Published var orderFocus = 0
    @Published var orderGrab = false                // the focused mod moves with up / down
    @Published var profileID: String?               // the profile panel
    @Published var naming: String?                  // the "save profile" panel: the name
    @Published var panelStep = 0                    // details / import preview: the section the controller scrolled to
    var pick = MMPick.mod
    var close: () -> Void = {}
    private let q = DispatchQueue(label: "cyport.mods", qos: .userInitiated)
    private var padTimer: Timer?, progressTimer: Timer?
    private var held: [MMPad: Date] = [:]

    init(gameRoot: String) { store = ModStore(gameRoot: gameRoot) }

    var all: [ModManifest] { list.mods + list.unmanaged }
    var detail: ModManifest? { detailID.flatMap { id in all.first { $0.id == id } } }
    var profile: ModProfile? { profileID.flatMap { id in list.profiles.first { $0.id == id } } }
    var archiveMods: [ModManifest] { store.archiveMods(list) }
    /// the sections of the details panel and of the import preview, top to bottom (up / down on the controller steps through them)
    func sections(_ m: ModManifest) -> [String] {
        ["top"] + [((list.deps[m.id] ?? []).isEmpty, "uses"), ((list.conflicts[m.id] ?? []).isEmpty, "conflicts"), (list.audio[m.id] == nil, "audio"), (m.notes.isEmpty, "notes"),
                   (m.skipped.isEmpty, "skipped"), (false, "files")].filter { !$0.0 }.map(\.1)
    }
    func sections(_ p: ModPlan) -> [String] {
        ["top"] + [(p.deps.isEmpty, "uses"), (p.conflicts.isEmpty, "conflicts"), (!p.items.contains { $0.kind == "archive" }, "archives"),
                   (!p.items.contains { $0.kind != "archive" }, "others"), (p.unsupported.isEmpty, "skipped")].filter { !$0.0 }.map(\.1)
    }
    private func step(_ d: Int, _ count: Int) { panelStep = max(0, min(count - 1, panelStep + d)) }
    var panelOpen: Bool { detail != nil || plan != nil || question != nil || error != nil || order != nil || profile != nil || naming != nil }

    // ---------------------------------------------------------------- search / filter / sort
    func hasProblem(_ m: ModManifest) -> Bool {
        (list.deps[m.id] ?? []).contains(where: \.problem) || !(list.conflicts[m.id] ?? []).isEmpty || list.audio[m.id] != nil
    }
    func shown(_ mods: [ModManifest]) -> [ModManifest] {
        var out = mods
        let s = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !s.isEmpty {
            out = out.filter { m in m.name.lowercased().contains(s) || m.source.lowercased().contains(s) || m.kinds.contains { mmKind($0).lowercased().contains(s) } }
        }
        switch list.settings.filter {
        case "on": out = out.filter(\.enabled)
        case "off": out = out.filter { !$0.enabled }
        case "problems": out = out.filter(hasProblem)
        default: break
        }
        switch list.settings.sort {
        case "size": out.sort { $0.size > $1.size }
        case "newest": out.sort { $0.installed > $1.installed }
        case "on": out.sort { $0.enabled != $1.enabled ? $0.enabled : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        default: break
        }
        return out
    }
    var filtered: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty || list.settings.filter != "all" }
    func set(_ change: (inout ModSettings) -> Void) {
        var s = list.settings
        change(&s)
        list.settings = s
        store.settings = s
    }
    func nextSort() { let i = mmSorts.firstIndex { $0.0 == list.settings.sort } ?? 0; set { $0.sort = mmSorts[(i + 1) % mmSorts.count].0 } }
    func nextFilter() { let i = mmFilters.firstIndex { $0.0 == list.settings.filter } ?? 0; set { $0.filter = mmFilters[(i + 1) % mmFilters.count].0 } }
    func nextKeep() { let i = mmKeeps.firstIndex(of: list.settings.keepBackups) ?? 0; set { $0.keepBackups = mmKeeps[(i + 1) % mmKeeps.count] } }

    var rows: [MMRow] {
        var r: [MMRow] = [.search, .sort, .filter, .importMod]
        if let c = list.changes, !c.isEmpty { r.append(.changes) }
        r += shown(list.mods).map { .mod($0.id) } + shown(list.unmanaged).map { .mod($0.id) } + list.plugins.map { .plugin($0.name) }
        if !archiveMods.isEmpty { r += [.order, .modlist] }
        r += [.saveProfile] + list.profiles.map { .profile($0.id) }
        r += [.recompile, .restore, .original, .backupToggle, .backupKeep, .backupNow] + list.backups.map { .backup($0.id) }
        return r
    }

    // ---------------------------------------------------------------- work
    struct Outcome { var status: String; var bad = false; var detail: String? }
    /// runs `work` off the main thread (one job at a time), then shows what happened and reads the folders again
    func run(_ label: String, _ work: @escaping (ModStore) throws -> Outcome) {
        guard busy == nil else { return }
        busy = label
        let s = store
        q.async {
            var out: Outcome
            do { out = try work(s) } catch { out = Outcome(status: error.localizedDescription, bad: true) }
            let l = s.scan(), p = s.hasPristine
            DispatchQueue.main.async {
                self.list = l; self.hasPristine = p; self.loaded = true; self.busy = nil
                if !out.status.isEmpty { self.status = out.status; self.statusBad = out.bad }
                if let d = out.detail, !d.isEmpty { self.error = MMError(title: out.status, text: d) }
                if out.bad { UINotificationFeedbackGenerator().notificationOccurred(.error) }
            }
        }
    }
    func refresh() { run("Reading the game folder…") { _ in Outcome(status: "") } }
    /// asks first when a compile would lose something (plugin scripts not on the phone, Mac-compiled script mods)
    private func beforeCompile(_ needed: Bool, _ what: String, _ go: @escaping () -> Void) {
        let w = needed ? store.compileWarnings() : []
        if w.isEmpty { go(); return }
        question = MMQuestion(title: "Scripts will be recompiled", message: what + "\n\n" + w.joined(separator: "\n\n"), yes: "Continue", destructive: true, backupOffer: true, action: go)
    }
    private func pluginHasScripts(_ name: String) -> Bool {
        ModStore.scriptPlugins.contains(ModStore.norm(name)) || (list.plugins.first { $0.name == name }?.scriptFiles ?? 0) > 0
    }

    func toggle(_ m: ModManifest) {
        let on = !m.enabled
        // plugins the mod needs that are on the phone but turned off: offered together with the mod
        let need = on ? (list.deps[m.id] ?? []).filter { $0.problem && $0.state == .off }.compactMap(\.plugin) : []
        let compile = m.hasScripts || need.contains(where: pluginHasScripts)
        let go = {
            self.run(compile ? "Turning \(m.name) \(on ? "on" : "off") and compiling scripts…" : "Moving files…") { s in
                let note = compile || !need.isEmpty ? s.backupSaves() : ""
                var turned: [String] = []
                func undoPlugins() { for n in turned { try? s.setPluginEnabled(n, false) } }
                let m2: ModManifest
                do {
                    for n in need { try s.setPluginEnabled(n, true); turned.append(n) }
                    m2 = try s.setEnabled(m, on)
                } catch { undoPlugins(); throw error }
                let what = "\(m.name) is \(on ? "on" : "off")" + (need.isEmpty ? "." : ", and so \(need.count == 1 ? "is" : "are") \(need.joined(separator: ", ")).")
                guard compile else { return Outcome(status: mmJoin(what, note)) }
                let r = s.compileScripts()
                if r.ok { return Outcome(status: mmJoin("\(what) \(r.message)", note)) }
                _ = try? s.setEnabled(m2, !on); undoPlugins()
                return Outcome(status: "\(m.name) stays \(on ? "off" : "on"): \(r.message)", bad: true, detail: r.detail)
            }
        }
        let ask = { self.beforeCompile(compile, "\(m.name) has scripts, so turning it \(on ? "on" : "off") recompiles the game's scripts.", go) }
        if need.isEmpty { ask(); return }
        question = MMQuestion(title: "Turn on \(need.joined(separator: ", ")) too?",
                              message: "\(m.name) needs \(need.joined(separator: ", ")), which \(need.count == 1 ? "is" : "are") on the phone but turned off. Both are turned on." + (compile ? "\n\nThe game's scripts are recompiled (a few seconds)." : ""),
                              yes: "Turn on both", backupOffer: true, action: ask)
    }
    func delete(_ m: ModManifest) {
        detailID = nil; deleteArmed = false
        let compile = m.enabled && m.hasScripts
        beforeCompile(compile, "\(m.name) has scripts, so deleting it recompiles the game's scripts.") {
            self.run("Deleting \(m.name)…") { s in
                guard compile else { try s.delete(m); return Outcome(status: "\(m.name) deleted.") }
                let note = s.backupSaves()
                let off = try s.setEnabled(m, false)
                let r = s.compileScripts()
                if !r.ok { _ = try? s.setEnabled(off, true); return Outcome(status: "\(m.name) was not deleted: \(r.message)", bad: true, detail: r.detail) }
                try s.delete(off)
                return Outcome(status: mmJoin("\(m.name) deleted. \(r.message)", note))
            }
        }
    }
    func togglePlugin(_ p: ModPlugin) {
        let on = !p.enabled
        let compile = p.scriptFiles > 0 || ModStore.scriptPlugins.contains(ModStore.norm(p.name))
        var msg = on ? "\(p.name) loads again the next time you press Play."
                     : "\(p.name) will not load. Mods that need it stop working" + (p.usedBy.isEmpty ? "." : ": " + p.usedBy.joined(separator: ", ") + ".")
        if compile { msg += "\n\nIts scripts are part of the game's compiled scripts, so the scripts are recompiled now (a few seconds)." }
        let w = compile ? store.compileWarnings().filter { !$0.hasPrefix(p.name + " is on") } : []
        if !w.isEmpty { msg += "\n\n" + w.joined(separator: "\n\n") }
        question = MMQuestion(title: "Turn \(p.name) \(on ? "on" : "off")?", message: msg, yes: on ? "Turn on" : "Turn off", destructive: !on, backupOffer: true) {
            self.run(compile ? "Moving \(p.name) and compiling scripts…" : "Moving \(p.name)…") { s in
                let note = s.backupSaves()
                try s.setPluginEnabled(p.name, on)
                guard compile else { return Outcome(status: mmJoin("\(p.name) is \(on ? "on" : "off").", note)) }
                let r = s.compileScripts()
                if r.ok { return Outcome(status: mmJoin("\(p.name) is \(on ? "on" : "off"). \(r.message)", note)) }
                try? s.setPluginEnabled(p.name, !on)
                return Outcome(status: "\(p.name) stays \(on ? "off" : "on"): \(r.message)", bad: true, detail: r.detail)
            }
        }
    }
    func recompile() {
        beforeCompile(true, "Compiles every script mod that is on, plus the scripts of the plugins that are on.") {
            self.run("Compiling scripts…") { s in
                let note = s.backupSaves()
                let r = s.compileScripts()
                return Outcome(status: r.ok ? mmJoin(r.message, note) : r.message, bad: !r.ok, detail: r.detail)
            }
        }
    }
    func restoreOriginal() {
        question = MMQuestion(title: "Restore original scripts?", message: "The game goes back to its own scripts: script mods stop applying, and plugins that bring scripts (TweakXL, ArchiveXL, Codeware, Mod Settings) lose their script side until you recompile. Nothing is deleted.", yes: "Restore", destructive: true, backupOffer: true) {
            self.run("Restoring…") { s in
                let note = s.backupSaves()
                try s.restoreOriginalScripts()
                return Outcome(status: mmJoin("Original scripts restored. Recompile scripts to bring the mods back.", note))
            }
        }
    }

    // ---------------------------------------------------------------- import
    func picked(_ r: Result<[URL], Error>) {
        guard case .success(let urls) = r, let url = urls.first else {
            if case .failure(let e) = r { status = e.localizedDescription; statusBad = true }
            return
        }
        let scoped = url.startAccessingSecurityScopedResource()
        let done = { if scoped { url.stopAccessingSecurityScopedResource() } }
        if pick == .original {
            run("Checking the file…") { s in defer { done() }; try s.adoptOriginal(from: url.path); return Outcome(status: "Original scripts saved.") }
            return
        }
        guard busy == nil else { done(); return }
        let name = url.lastPathComponent
        busy = "Unpacking \(name)…"
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in guard let self, self.plan == nil, self.busy != nil else { return }
                let b = MSModExtractProgress(); if b > 0 { self.busy = "Unpacking \(name)… \(mmSize(b))" } }
        }
        let s = store
        q.async {
            let res = Result { try s.analyze(file: url.path, displayName: name) }
            done()
            DispatchQueue.main.async {
                self.progressTimer?.invalidate(); self.progressTimer = nil; self.busy = nil
                switch res {
                case .success(let p): self.panelStep = 0; self.plan = p
                case .failure(let e): self.status = "\(name): \(e.localizedDescription)"; self.statusBad = true
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
            }
        }
    }
    func cancelPlan() { if let p = plan { let s = store; q.async { s.discard(p) } }; plan = nil }
    /// the plugins an import needs that are on the phone but turned off
    func planOffPlugins(_ p: ModPlan) -> [String] { p.deps.filter { $0.problem && $0.state == .off }.compactMap(\.plugin) }
    func installPlan() {
        guard let p = plan, p.items.contains(where: \.selected) else { return }
        let scripts = p.items.contains { $0.selected && $0.kind == "redscript" }
        let need = p.enablePlugins ? planOffPlugins(p) : []
        let compile = scripts || need.contains(where: pluginHasScripts)
        beforeCompile(compile, scripts ? "\(p.name) has scripts, so installing it recompiles the game's scripts." : "Turning on \(need.joined(separator: ", ")) recompiles the game's scripts.") {
            self.plan = nil
            self.run(compile ? "Installing \(p.name) and compiling scripts…" : "Installing \(p.name)…") { s in
                let note = compile || !need.isEmpty ? s.backupSaves() : ""
                let m = try s.install(p)
                var turned: [String] = []
                for n in need { if (try? s.setPluginEnabled(n, true)) != nil { turned.append(n) } }
                let plus = turned.isEmpty ? "" : " \(turned.joined(separator: ", ")) turned on."
                guard compile else { return Outcome(status: mmJoin("\(m.name) installed (\(mmCount(m.files.count, "file"))).\(plus) It loads the next time you press Play.", note)) }
                let r = s.compileScripts()
                if r.ok { return Outcome(status: mmJoin("\(m.name) installed.\(plus) \(r.message)", note)) }
                _ = try? s.setEnabled(m, false)
                for n in turned { try? s.setPluginEnabled(n, false) }
                return Outcome(status: "\(m.name) was installed but is turned off: \(r.message)", bad: true, detail: r.detail)
            }
        }
    }

    // ---------------------------------------------------------------- load order
    func openOrder() {
        let a = archiveMods
        guard busy == nil, !a.isEmpty else { return }
        detailID = nil; order = a; orderFocus = 0; orderGrab = false
    }
    func orderMove(_ d: Int) {
        guard var o = order, o.indices.contains(orderFocus), o.indices.contains(orderFocus + d) else { return }
        o.swapAt(orderFocus, orderFocus + d)
        order = o; orderFocus += d
    }
    func applyOrder() {
        guard let o = order else { return }
        order = nil
        let ids = o.map(\.id)
        run("Renaming archives…") { s in
            let failed = try s.applyOrder(ids, list: s.scan(full: false))
            return Outcome(status: failed.isEmpty ? "Load order set (\(mmCount(ids.count, "mod")) numbered). It applies the next time you press Play."
                                                  : "Load order set, but these could not be renamed: \(failed.joined(separator: ", "))", bad: !failed.isEmpty)
        }
    }
    func resetOrder() {
        order = nil
        run("Renaming archives…") { s in
            let failed = try s.applyOrder(nil, list: s.scan(full: false))
            return Outcome(status: failed.isEmpty ? "Numbers removed: the archives have their own names again and load in name order."
                                                  : "These could not be renamed back: \(failed.joined(separator: ", "))", bad: !failed.isEmpty)
        }
    }

    // ---------------------------------------------------------------- profiles
    func startNaming() { guard busy == nil else { return }; naming = store.freeProfileName() }
    func saveProfile() {
        guard let n = naming?.trimmingCharacters(in: .whitespaces), !n.isEmpty else { return }
        naming = nil
        run("Saving \(n)…") { s in
            let p = try s.saveProfile(name: n)
            return Outcome(status: "Saved the profile \(p.name): \(mmCount(p.mods.count, "mod")) and \(mmCount(p.plugins.count, "plugin")) on.")
        }
    }
    func profileSummary(_ p: ModProfile) -> String {
        let d = store.profileDiff(p, list)
        var s: [String] = []
        if !d.on.isEmpty { s.append("Turns on: " + d.on.map(\.name).joined(separator: ", ")) }
        if !d.off.isEmpty { s.append("Turns off: " + d.off.map(\.name).joined(separator: ", ")) }
        if !d.pluginsOn.isEmpty { s.append("Plugins on: " + d.pluginsOn.map(\.name).joined(separator: ", ")) }
        if !d.pluginsOff.isEmpty { s.append("Plugins off: " + d.pluginsOff.map(\.name).joined(separator: ", ")) }
        if !d.gone.isEmpty { s.append("No longer installed (skipped): " + d.gone.joined(separator: ", ")) }
        if s.isEmpty { s.append("Everything is already set the way this profile says.") }
        else if store.profileNeedsCompile(p, list) { s.append("The game's scripts are recompiled (a few seconds). If they don't compile, nothing is changed.") }
        return s.joined(separator: "\n")
    }
    func loadProfile(_ p: ModProfile) {
        question = MMQuestion(title: "Load \(p.name)?", message: profileSummary(p), yes: "Load", backupOffer: true) {
            self.profileID = nil
            self.run("Loading \(p.name)…") { s in
                let r = s.applyProfile(p)
                return Outcome(status: r.message, bad: !r.ok, detail: r.detail)
            }
        }
    }
    func overwriteProfile(_ p: ModProfile) {
        question = MMQuestion(title: "Save the current setup as \(p.name)?", message: "The profile is replaced by the mods and plugins that are on right now.", yes: "Save") {
            self.profileID = nil
            self.run("Saving \(p.name)…") { s in _ = try s.saveProfile(name: p.name); return Outcome(status: "Profile \(p.name) saved again.") }
        }
    }
    func deleteProfile(_ p: ModProfile) {
        question = MMQuestion(title: "Delete the profile \(p.name)?", message: "Only the saved list is deleted. No mod is removed or switched.", yes: "Delete", destructive: true) {
            self.profileID = nil
            self.run("Deleting \(p.name)…") { s in s.deleteProfile(p); return Outcome(status: "Profile \(p.name) deleted.") }
        }
    }

    // ---------------------------------------------------------------- save backups
    func backupNow() {
        run("Backing up saves…") { s in
            let note = s.backupSaves(force: true)
            return Outcome(status: note, bad: note.contains("could not"))
        }
    }
    func restoreBackup(_ b: ModBackup) {
        question = MMQuestion(title: "Restore the saves from \(mmBackupDate(b.name))?", message: "The saves folder is replaced by this backup (\(mmCount(b.files, "file")), \(mmSize(b.size))). The saves that are there now are kept as a backup of their own first. With cloud saves on, the next sync compares them with the cloud as usual.", yes: "Restore", destructive: true) {
            self.run("Restoring saves…") { s in try s.restoreBackup(b); return Outcome(status: "Saves restored from \(mmBackupDate(b.name)).") }
        }
    }
    func showChanges() {
        guard let c = list.changes else { return }
        error = MMError(title: "Changed since the last Play", text: c.isEmpty ? "Nothing." : c.map { "•  " + $0 }.joined(separator: "\n\n"), bad: false)
    }

    // ---------------------------------------------------------------- controller
    func startPad() {
        padTimer?.invalidate()
        padTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in Task { @MainActor in self?.pollPad() } }
    }
    func stopPad() { padTimer?.invalidate(); padTimer = nil }
    private func pollPad() {
        var down = Set<MMPad>()
        for c in GCController.controllers() {
            guard let g = c.extendedGamepad else { continue }
            if g.dpad.up.isPressed || g.leftThumbstick.yAxis.value > 0.6 { down.insert(.up) }
            if g.dpad.down.isPressed || g.leftThumbstick.yAxis.value < -0.6 { down.insert(.down) }
            if g.buttonA.isPressed { down.insert(.a) }
            if g.buttonB.isPressed { down.insert(.b) }
            if g.buttonX.isPressed { down.insert(.x) }
            if g.buttonY.isPressed { down.insert(.y) }
        }
        let now = Date()
        for b in down {
            if let t = held[b] {
                // up / down repeat while held
                if (b == .up || b == .down), now.timeIntervalSince(t) > 0 { held[b] = now.addingTimeInterval(0.12); pad(b) }
            } else { held[b] = now.addingTimeInterval(0.4); pad(b) }
        }
        for b in held.keys where !down.contains(b) { held[b] = nil }
    }
    /// "Convert audio for the Mac game": a PC audio mod that is already in the game folder gets the Mac file table
    func convertAudio(_ m: ModManifest) {
        run("Converting the audio of \(m.name)…") { s in Outcome(status: try s.convertAudio(m)) }
    }
    /// what the details say about a mod whose archives still carry PC sounds
    func audioText(_ a: ModAudioInfo) -> String {
        var t: [String] = []
        if a.sounds > 0 { t.append("\(mmCount(a.sounds, "sound")) of this mod \(a.sounds == 1 ? "is" : "are") at the PC path (base\\sound\\soundbanks\\<id>.wem). The Mac game reads base\\sound\\soundbanks\\media\\<id>.wem, so \(a.sounds == 1 ? "it is" : "they are") never played.") }
        if !a.banks.isEmpty { t.append("\(mmCount(a.banks.count, "sound bank")) (.bnk) \(a.banks.count == 1 ? "is" : "are") of another Wwise version; the Mac game loads bank version \(ModAudio.macBankVersion) only.") }
        return t.joined(separator: " ") + " \"Convert audio for the Mac game\" rewrites the file table of the archive (the sounds themselves are untouched)."
    }
    /// the one extra action of the details panel (X): turn on a plugin the mod needs, convert PC audio, or open the load order
    func detailExtra(_ m: ModManifest) -> (title: String, action: () -> Void)? {
        if let d = (list.deps[m.id] ?? []).first(where: { $0.problem && $0.state == .off }), let n = d.plugin, let p = list.plugins.first(where: { $0.name == n }) {
            return ("Turn on \(n)", { self.togglePlugin(p) })
        }
        if list.audio[m.id] != nil { return ("Convert audio for the Mac game", { self.convertAudio(m) }) }
        if (list.conflicts[m.id] ?? []).contains(where: { $0.kind == "archive" }) { return ("Load order…", { self.openOrder() }) }
        return nil
    }
    private func pad(_ b: MMPad) {
        guard !picking else { return }
        if typing { if b == .b || b == .a { typing = false }; return }
        if error != nil { if b == .b || b == .a { error = nil }; return }
        if let qn = question {
            if b == .a { question = nil; qn.action() } else if b == .b { question = nil }
            else if b == .x, qn.backupOffer { set { $0.backupSaves.toggle() } }
            return
        }
        guard busy == nil else { return }
        if naming != nil { if b == .a { saveProfile() } else if b == .b { naming = nil }; return }
        if let p = plan {
            switch b {
            case .a: installPlan()
            case .b: cancelPlan()
            case .x: if !planOffPlugins(p).isEmpty { plan?.enablePlugins.toggle() }
            case .up: step(-1, sections(p).count)
            case .down: step(1, sections(p).count)
            default: break
            }
            return
        }
        if let o = order {
            switch b {
            case .up: if orderGrab { orderMove(-1) } else { orderFocus = max(0, orderFocus - 1) }
            case .down: if orderGrab { orderMove(1) } else { orderFocus = min(o.count - 1, orderFocus + 1) }
            case .a: orderGrab.toggle()
            case .x: applyOrder()
            case .y: if list.orderActive { resetOrder() }
            case .b: if orderGrab { orderGrab = false } else { order = nil }
            }
            return
        }
        if let p = profile {
            switch b {
            case .a: loadProfile(p)
            case .x: overwriteProfile(p)
            case .y: deleteProfile(p)
            case .b: profileID = nil
            default: break
            }
            return
        }
        if let d = detail {
            switch b {
            case .a: toggle(d)
            case .x: if !deleteArmed { detailExtra(d)?.action() }
            case .y: if deleteArmed { delete(d) } else { deleteArmed = true }
            case .b: if deleteArmed { deleteArmed = false } else { detailID = nil }
            case .up: step(-1, sections(d).count)
            case .down: step(1, sections(d).count)
            }
            return
        }
        let r = rows
        switch b {
        case .up, .down:
            guard let f = focus, let i = r.firstIndex(of: f) else { focus = r.contains(.importMod) ? .importMod : r.first; return }
            focus = r[max(0, min(r.count - 1, i + (b == .down ? 1 : -1)))]
        case .a: if let f = focus, r.contains(f) { activate(f) } else { focus = .importMod }
        case .x: if case .mod(let id)? = focus { deleteArmed = false; panelStep = 0; detailID = id }
        case .y: startPick(.mod)
        case .b: close()
        }
    }
    func activate(_ r: MMRow) {
        switch r {
        case .search: typing = true
        case .sort: nextSort()
        case .filter: nextFilter()
        case .importMod: startPick(.mod)
        case .changes: showChanges()
        case .mod(let id): if let m = all.first(where: { $0.id == id }) { toggle(m) }
        case .plugin(let n): if let p = list.plugins.first(where: { $0.name == n }) { togglePlugin(p) }
        case .order: openOrder()
        case .modlist:
            set { $0.writeModlist.toggle() }
            run("Updating modlist.txt…") { _ in Outcome(status: "") }             // the next read of the folders writes or removes modlist.txt
        case .saveProfile: startNaming()
        case .profile(let id): if busy == nil { profileID = id }
        case .recompile: recompile()
        case .restore: restoreOriginal()
        case .original: startPick(.original)
        case .backupToggle: set { $0.backupSaves.toggle() }
        case .backupKeep: nextKeep()
        case .backupNow: backupNow()
        case .backup(let id): if let b = list.backups.first(where: { $0.id == id }) { restoreBackup(b) }
        }
    }
    func startPick(_ what: MMPick) { guard busy == nil else { return }; pick = what; picking = true }
}

struct ModManagerView: View {
    @StateObject private var model: ModManagerModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFocused: Bool
    @FocusState private var nameFocused: Bool

    init(gameRoot: String) { _model = StateObject(wrappedValue: ModManagerModel(gameRoot: gameRoot)) }

    // ---------------------------------------------------------------- pieces
    private func box(_ focused: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10).fill(.white.opacity(focused ? 0.14 : 0.08))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(focused ? mmYellow : .white.opacity(0.15), lineWidth: focused ? 2 : 1))
    }
    private func chip(_ t: String, _ color: Color = .white.opacity(0.14)) -> some View {
        Text(t).font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 2).background(color, in: Capsule())
    }
    private func header(_ t: String, _ note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t).font(.system(size: 13, weight: .heavy, design: .monospaced)).tracking(2).foregroundStyle(mmYellow)
            if let n = note { Text(n).font(.caption).foregroundStyle(.white.opacity(0.5)).fixedSize(horizontal: false, vertical: true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 14)
    }
    private func switchView(_ on: Bool) -> some View {
        // drawn, not a Toggle: the whole right side of the row is the button, and the controller's A does the same
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule().fill(on ? mmYellow : Color.white.opacity(0.2)).frame(width: 52, height: 30)
            Circle().fill(on ? Color.black : Color.white).frame(width: 24, height: 24).padding(3)
        }
    }
    /// the red / orange badges of a mod: frameworks it needs that are missing or off, and conflicts
    @ViewBuilder private func badges(_ m: ModManifest) -> some View {
        let bad = (model.list.deps[m.id] ?? []).filter(\.problem)
        let conf = model.list.conflicts[m.id] ?? []
        let audio = model.list.audio[m.id]
        if !bad.isEmpty || !conf.isEmpty || audio != nil {
            HStack(spacing: 5) {
                if audio != nil { chip("PC audio: convert it in the details", mmOrange.opacity(0.85)) }
                if !bad.isEmpty { chip("Needs " + bad.map { $0.name + ($0.state == .off ? " (off)" : "") }.joined(separator: ", "), mmRed.opacity(0.85)) }
                if !conf.isEmpty {
                    let loses = conf.contains { $0.wins != true }
                    chip(loses ? "Conflict: \(conf.map(\.otherName).first ?? "")\(conf.count > 1 ? " +\(conf.count - 1)" : "")" : "Conflict (this one wins)", mmOrange.opacity(loses ? 0.85 : 0.45))
                }
            }
        }
    }
    private func modRow(_ m: ModManifest) -> some View {
        let focused = model.focus == .mod(m.id)
        return HStack(spacing: 0) {
            Button { model.deleteArmed = false; model.panelStep = 0; model.detailID = m.id } label: {
                HStack(spacing: 12) {
                    Image(systemName: mmIcon(m.kinds)).font(.title3).foregroundStyle(m.enabled ? mmYellow : .white.opacity(0.35)).frame(width: 30)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(m.name).font(.headline).foregroundStyle(.white.opacity(m.enabled ? 1 : 0.5)).lineLimit(1)
                        HStack(spacing: 5) {
                            ForEach(m.kinds, id: \.self) { chip(mmKind($0)) }
                            Text("\(mmSize(m.size)) · \(mmCount(m.files.count, "file"))").font(.caption).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                        }
                        badges(m)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "info.circle").foregroundStyle(.white.opacity(0.35))
                }
                .padding(.leading, 14).padding(.vertical, 10).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { model.focus = nil; model.toggle(m) } label: { switchView(m.enabled).padding(.horizontal, 14).frame(maxHeight: .infinity).contentShape(Rectangle()) }
                .buttonStyle(.plain)
        }
        .frame(minHeight: 64).background(box(focused)).id(MMRow.mod(m.id))
    }
    private func pluginRow(_ p: ModPlugin) -> some View {
        let focused = model.focus == .plugin(p.name)
        return Button { model.focus = nil; model.togglePlugin(p) } label: {
            HStack(spacing: 12) {
                Image(systemName: "puzzlepiece.extension").font(.title3).foregroundStyle(p.enabled ? mmYellow : .white.opacity(0.35)).frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(p.name).font(.headline).foregroundStyle(.white.opacity(p.enabled ? 1 : 0.5)).lineLimit(1)
                    Text([mmSize(p.size), p.scriptFiles > 0 ? "\(p.scriptFiles) script files" : nil,
                          p.usedBy.isEmpty ? nil : "used by \(mmCount(p.usedBy.count, "mod"))"].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
                Spacer(minLength: 8)
                switchView(p.enabled)
            }
            .padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: 64).contentShape(Rectangle())
        }
        .buttonStyle(.plain).background(box(focused)).id(MMRow.plugin(p.name))
    }
    /// a row that does something (chevron), shows a value, or is a switch
    private func actionRow(_ row: MMRow, _ title: String, _ icon: String, _ note: String, strong: Bool = false, value: String? = nil, on: Bool? = nil) -> some View {
        let focused = model.focus == row
        return Button { model.focus = nil; model.activate(row) } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.title3).frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).multilineTextAlignment(.leading)
                    Text(note).font(.caption).opacity(0.65).fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                if let on { switchView(on) }
                else if let value { Text(value).font(.subheadline.weight(.heavy)).foregroundStyle(mmYellow) }
                else { Image(systemName: "chevron.right").font(.caption.weight(.bold)).opacity(0.5) }
            }
            .foregroundStyle(strong ? Color.black : Color.white.opacity(0.9))
            .padding(.horizontal, 14).padding(.vertical, 10).frame(minHeight: 60).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(strong ? AnyView(RoundedRectangle(cornerRadius: 10).fill(mmYellow)
                                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(focused ? Color.white : .clear, lineWidth: 3)))
                           : AnyView(box(focused)))
        .id(row)
    }
    /// search box + sort + filter, three things the controller stops on one after the other
    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.5))
                TextField("Search mods", text: $model.search)
                    .focused($searchFocused).textInputAutocapitalization(.never).autocorrectionDisabled(true).submitLabel(.done)
                    .foregroundStyle(.white).tint(mmYellow)
                if !model.search.isEmpty {
                    Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.5)) }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).frame(height: 44).background(box(model.focus == .search || searchFocused)).id(MMRow.search)
            pickButton(.sort, "arrow.up.arrow.down", mmSorts.first { $0.0 == model.list.settings.sort }?.1 ?? "Name")
            pickButton(.filter, "line.3.horizontal.decrease", mmFilters.first { $0.0 == model.list.settings.filter }?.1 ?? "All")
        }
    }
    private func pickButton(_ row: MMRow, _ icon: String, _ value: String) -> some View {
        Button { model.focus = nil; model.activate(row) } label: {
            Label(value, systemImage: icon).font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                .padding(.horizontal, 12).frame(height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).background(box(model.focus == row)).id(row)
    }
    /// "12 mods · 9 on (1.2 GB) · 3 off (300 MB)"
    private var totals: String? {
        let all = model.all
        guard model.loaded, !all.isEmpty else { return nil }
        let on = all.filter(\.enabled), off = all.filter { !$0.enabled }
        var s = "\(mmCount(all.count, "mod")) · \(on.count) on (\(mmSize(on.reduce(0) { $0 + $1.size })))"
        if !off.isEmpty { s += " · \(off.count) off (\(mmSize(off.reduce(0) { $0 + $1.size })))" }
        let bad = all.filter(model.hasProblem).count
        if bad > 0 { s += " · \(bad) with a problem" }
        if model.filtered { s += " · showing \(model.shown(model.list.mods).count + model.shown(model.list.unmanaged).count)" }
        return s
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Button { dismiss() } label: {
                Label("Back", systemImage: "chevron.left").font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 14).frame(height: 40).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            Text("MODS").font(.system(size: 30, weight: .black)).italic().foregroundStyle(mmYellow)
                .shadow(color: mmRed.opacity(0.6), radius: 0, x: 2, y: 1)
            Spacer()
            if model.busy != nil { ProgressView().tint(mmYellow) }
            Text(model.busy ?? model.status ?? "Changes apply the next time you press Play.")
                .font(.caption).foregroundStyle(model.busy == nil && model.statusBad ? mmRed : .white.opacity(0.7))
                .lineLimit(3).multilineTextAlignment(.trailing).frame(maxWidth: 380, alignment: .trailing)
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 8)
    }
    @ViewBuilder private var modSections: some View {
        let mods = model.shown(model.list.mods), found = model.shown(model.list.unmanaged)
        header("INSTALLED MODS", totals ?? (model.loaded ? "None yet. Mods you import show up here." : nil))
        ForEach(mods) { modRow($0) }
        if model.filtered && mods.isEmpty && found.isEmpty && !model.all.isEmpty {
            Text("No mod matches the search or the filter.").font(.caption).foregroundStyle(.white.opacity(0.5)).padding(.vertical, 6)
        }
        if !found.isEmpty {
            header("FOUND IN THE GAME FOLDER", "Files that were copied there another way. They can be turned off or deleted the same way.")
            ForEach(found) { modRow($0) }
        }
    }
    @ViewBuilder private var orderSection: some View {
        let arch = model.archiveMods
        if !arch.isEmpty {
            let n = model.all.filter { m in (model.list.conflicts[m.id] ?? []).contains { $0.kind == "archive" } }.count
            header("LOAD ORDER", "When two mods change the same game resource, the one whose archive loads first is used.")
            actionRow(.order, "Load order…", "list.number",
                      (n > 0 ? "\(mmCount(n, "mod")) share resources with another mod. " : "No archive conflicts. ")
                      + (model.list.orderActive ? "The archives are numbered by CyPort (001__, 002__, …)." : "The archives load in name order."))
            actionRow(.modlist, "Also write modlist.txt", "doc.plaintext", "Writes the same order to archive/Mac/mod/modlist.txt. The game has code that reads it, but that it follows it was never confirmed: the numbers decide either way.", on: model.list.settings.writeModlist)
        }
    }
    @ViewBuilder private var profileSection: some View {
        header("PROFILES", "A profile is a saved set of which mods and plugins are on.")
        actionRow(.saveProfile, "Save current setup as a profile…", "square.and.arrow.down.on.square", "\(model.all.filter(\.enabled).count) mods and \(model.list.plugins.filter(\.enabled).count) plugins are on.")
        ForEach(model.list.profiles) { p in
            actionRow(.profile(p.id), p.name, "person.crop.rectangle.stack", "\(mmCount(p.mods.count, "mod")) and \(mmCount(p.plugins.count, "plugin")) on · saved \(p.saved.formatted(date: .abbreviated, time: .shortened))")
        }
    }
    @ViewBuilder private var backupSection: some View {
        let st = model.list.settings
        header("SAVE BACKUPS", "Kept in CyPort/save-backups (Files → CyPort). A new copy is only made when the saves changed since the last one.")
        actionRow(.backupToggle, "Back up saves before changes", "externaldrive.badge.timemachine", "Before the scripts are recompiled or a plugin is switched, the saves folder is copied.", on: st.backupSaves)
        actionRow(.backupKeep, "Backups to keep", "tray.full", "Older ones are deleted when a new one is made.", value: "\(st.keepBackups)")
        actionRow(.backupNow, "Back up saves now", "arrow.down.doc", model.list.backups.isEmpty ? "No backup yet." : "\(mmCount(model.list.backups.count, "backup")), \(mmSize(model.list.backups.reduce(0) { $0 + $1.size })).")
        ForEach(model.list.backups) { b in
            actionRow(.backup(b.id), mmBackupDate(b.name), "clock.arrow.circlepath", "\(mmCount(b.files, "file")) · \(mmSize(b.size)) · restore…")
        }
    }
    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 8) {
                    searchBar
                    actionRow(.importMod, "Import mod…", "square.and.arrow.down", "Pick a .zip, .7z, .rar or .archive from Files. You see what will be installed before anything changes.", strong: true)
                    if let c = model.list.changes {
                        if c.isEmpty { Text("Nothing changed since the last Play.").font(.caption).foregroundStyle(.white.opacity(0.45)).padding(.leading, 4) }
                        else { actionRow(.changes, "Changed since the last Play", "clock.badge.exclamationmark", c.prefix(2).joined(separator: " · ") + (c.count > 2 ? " · and \(c.count - 2) more" : "")) }
                    }
                    modSections
                    header("PLUGINS (RED4EXT)", pluginsNote)
                    ForEach(model.list.plugins) { pluginRow($0) }
                    orderSection
                    profileSection
                    header("SCRIPTS", model.hasPristine ? "Script mods (.reds) and plugin scripts are compiled on the phone, always starting from the game's original scripts."
                                                        : "The game's original scripts were not found on the phone. Script mods can't be compiled until you choose them.")
                    actionRow(.recompile, "Recompile scripts", "hammer", "Runs by itself when a script mod or a plugin is turned on or off.")
                    actionRow(.restore, "Restore original scripts", "arrow.uturn.backward", "Puts the game's own scripts back (if the game stops while loading scripts).")
                    actionRow(.original, "Choose original scripts…", "doc.badge.gearshape", model.hasPristine ? "Saved. Pick another original final.redscripts only after a game update." : "Pick the game's original final.redscripts in Files.")
                    backupSection
                    Text("Controller:  D-pad move  ·  A on/off or press  ·  X details  ·  Y import  ·  B back")
                        .font(.caption2).foregroundStyle(.white.opacity(0.35)).frame(maxWidth: .infinity).padding(.vertical, 14)
                }
                .frame(maxWidth: 720).padding(.horizontal, 20).frame(maxWidth: .infinity)
            }
            .onChange(of: model.focus) { f in if let f { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(f, anchor: .center) } } }
        }
    }

    // ---------------------------------------------------------------- panels
    private func panel<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()
            c().padding(18).frame(maxWidth: 640)
                .background(Color(red: 0.09, green: 0.07, blue: 0.09), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(mmYellow.opacity(0.5)))
                .padding(.horizontal, 20).padding(.vertical, 14)
        }
    }
    private func bigButton(_ t: String, pad: String, style: Int, _ action: @escaping () -> Void) -> some View {
        // style 0 = plain, 1 = yellow, 2 = red
        Button(action: action) {
            HStack(spacing: 8) {
                Text(t).font(.subheadline.weight(.heavy)).lineLimit(1).minimumScaleFactor(0.7)
                if !pad.isEmpty { Text(pad).font(.caption2.weight(.bold)).padding(.horizontal, 5).padding(.vertical, 1).overlay(Capsule().stroke(lineWidth: 1)).opacity(0.6) }
            }
            .foregroundStyle(style == 1 ? Color.black : .white).padding(.horizontal, 14).frame(minWidth: 96, minHeight: 44)
            .background(style == 1 ? mmYellow : (style == 2 ? mmRed.opacity(0.85) : Color.white.opacity(0.12)), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
    private func line(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.5)).frame(width: 90, alignment: .leading)
            Text(v).font(.caption).foregroundStyle(.white.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
    private func small(_ t: String, _ c: Color = .white.opacity(0.75)) -> some View {
        Text(t).font(.caption).foregroundStyle(c).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func sub(_ t: String, _ section: String? = nil) -> some View {
        Text(t).font(.caption.weight(.heavy)).tracking(1).foregroundStyle(mmYellow.opacity(0.9)).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            .id(section ?? t)
    }
    /// a panel's scrolling part; the controller's up / down jump from section to section (model.panelStep)
    private func sectionScroll<C: View>(_ sections: [String], @ViewBuilder _ c: () -> C) -> some View {
        let content = c()
        return ScrollViewReader { proxy in
            ScrollView { content }
                .onChange(of: model.panelStep) { i in if sections.indices.contains(i) { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(sections[i], anchor: .top) } } }
        }
    }
    /// one framework a mod uses: there and on / on the phone but off / not on the phone
    private func depLine(_ d: ModDep) -> some View {
        var mark = "✓", tail = "", color = Color.white.opacity(0.75)
        switch d.state {
        case .on: break
        case .off:
            mark = d.optional ? "–" : "✗"
            tail = ": on the phone but turned off" + (d.optional ? " (the mod works without it)" : "")
            if !d.optional { color = mmRed }
        case .missing:
            mark = d.optional ? "–" : "✗"
            tail = d.optional ? ": not on the phone (the mod works without it)"
                              : (d.name == "redscript" ? ": this build of the app has no script compiler" : ": not on the phone. It needs the plugin's iOS build in red4ext/plugins")
            if !d.optional { color = mmRed }
        case .unknown:
            mark = "?"; tail = ": not a framework CyPort knows (another mod's script module?)"; color = .white.opacity(0.55)
        }
        return small("\(mark) \(d.name)  (\(d.why))\(tail)", color)
    }

    private func detailPanel(_ m: ModManifest) -> some View {
        let deps = model.list.deps[m.id] ?? [], conf = model.list.conflicts[m.id] ?? []
        let extra = model.detailExtra(m)
        return panel {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(m.name).font(.title3.weight(.heavy)).foregroundStyle(.white).lineLimit(2)
                    Spacer()
                    chip(m.enabled ? "ON" : "OFF", m.enabled ? mmYellow.opacity(0.35) : .white.opacity(0.14))
                }
                sectionScroll(model.sections(m)) {
                    VStack(alignment: .leading, spacing: 5) {
                        line("Source", m.managed ? m.source : "Found in the game folder (not installed by CyPort)").id("top")
                        if let v = m.version { line("Version", v) }
                        if m.managed { line("Installed", m.installed.formatted(date: .abbreviated, time: .shortened)) }
                        line("Size", "\(mmSize(m.size)) in \(mmCount(m.files.count, "file"))")
                        line("Kind", m.kinds.map(mmKind).joined(separator: ", "))
                        if !deps.isEmpty { sub("USES", "uses"); ForEach(deps, id: \.self) { depLine($0) } }
                        if !conf.isEmpty {
                            sub("CONFLICTS", "conflicts")
                            ForEach(conf, id: \.self) { c in small(c.detail, c.wins == true ? .white.opacity(0.75) : mmOrange) }
                            if conf.contains(where: { $0.kind == "archive" }) { small("Which mod loads first can be changed under Load order.", .white.opacity(0.5)) }
                        }
                        if let a = model.list.audio[m.id] { sub("AUDIO", "audio"); small(model.audioText(a), mmOrange) }
                        if !m.notes.isEmpty { sub("WHAT IT REPLACES / ADDS", "notes"); ForEach(m.notes, id: \.self) { small($0) } }
                        if !m.skipped.isEmpty { sub("NOT INSTALLED FROM THE ARCHIVE", "skipped"); ForEach(m.skipped, id: \.self) { small($0) } }
                        sub("FILES" + (m.enabled ? "" : " (moved to CyPort/disabled while off)"), "files")
                        ForEach(m.files.prefix(150), id: \.self) { f in
                            Text("\(f.path)  ·  \(mmSize(f.size))").font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
                                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if m.files.count > 150 { small("… and \(m.files.count - 150) more") }
                    }
                }
                HStack(spacing: 8) {
                    if model.deleteArmed {
                        bigButton("Delete for good", pad: "Y", style: 2) { model.delete(m) }
                        bigButton("Keep", pad: "B", style: 0) { model.deleteArmed = false }
                        Text("The files are removed from the phone.").font(.caption).foregroundStyle(.white.opacity(0.6))
                    } else {
                        bigButton(m.enabled ? "Turn off" : "Turn on", pad: "A", style: 1) { model.toggle(m) }
                        if let e = extra { bigButton(e.title, pad: "X", style: 0, e.action) }
                        bigButton("Delete…", pad: "Y", style: 0) { model.deleteArmed = true }
                        Spacer(minLength: 0)
                        bigButton("Close", pad: "B", style: 0) { model.detailID = nil }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder private func planDeps(_ p: ModPlan) -> some View {
        let off = model.planOffPlugins(p), gone = p.deps.filter { $0.problem && $0.state == .missing }
        if !p.deps.isEmpty { sub("USES", "uses"); ForEach(p.deps, id: \.self) { depLine($0) } }
        if !gone.isEmpty {
            small("\(gone.map(\.name).joined(separator: ", ")) \(gone.count == 1 ? "is" : "are") not on the phone. The mod can be installed, but the parts that need \(gone.count == 1 ? "it" : "them") won't work until \(gone.count == 1 ? "it is" : "they are") there.", mmRed)
        }
        if !off.isEmpty {
            Button { model.plan?.enablePlugins.toggle() } label: {
                HStack(spacing: 10) {
                    Image(systemName: p.enablePlugins ? "checkmark.square.fill" : "square").font(.title3).foregroundStyle(p.enablePlugins ? mmYellow : .white.opacity(0.4))
                    Text("Turn on \(off.joined(separator: ", ")) with the install (\(off.count == 1 ? "it is" : "they are") turned off now)").font(.caption).foregroundStyle(.white.opacity(0.9)).multilineTextAlignment(.leading)
                    Text("X").font(.caption2.weight(.bold)).padding(.horizontal, 5).padding(.vertical, 1).overlay(Capsule().stroke(lineWidth: 1)).opacity(0.6).foregroundStyle(.white)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
    @ViewBuilder private func planArchives(_ p: ModPlan) -> some View {
        let archives = p.items.filter { $0.kind == "archive" }
        if !archives.isEmpty {
            sub("ARCHIVES  → archive/Mac/mod", "archives")
            if p.variants { small("The archives are in different folders or share a name: these are usually variants. Pick ONE of each kind.", mmYellow) }
            ForEach(archives) { it in
                Button { model.plan?.items[it.id].selected.toggle() } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: it.selected ? "checkmark.square.fill" : "square").font(.title3).foregroundStyle(it.selected ? mmYellow : .white.opacity(0.4))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(it.rel).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.9)).multilineTextAlignment(.leading)
                            Text(it.verdict).font(.caption).foregroundStyle(it.good ? .white.opacity(0.6) : mmRed).multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
    private func planPanel(_ p: ModPlan) -> some View {
        let anySelected = p.items.contains(where: \.selected)
        let others = p.items.filter { $0.kind != "archive" }
        return panel {
            VStack(alignment: .leading, spacing: 8) {
                Text(p.installable ? "Import \(p.name)?" : "\(p.name) can't be installed").font(.title3.weight(.heavy)).foregroundStyle(.white).lineLimit(2)
                sectionScroll(model.sections(p)) {
                    VStack(alignment: .leading, spacing: 5) {
                        line("File", p.source).id("top")
                        if !p.installable { small("Nothing in this archive can run on CyPort.", mmRed) }
                        if p.updates { small("A mod with this name is installed: it is replaced by this one.", mmYellow) }
                        ForEach(p.notes, id: \.self) { small($0, mmYellow) }
                        planDeps(p)
                        if !p.conflicts.isEmpty { sub("CONFLICTS WITH INSTALLED MODS", "conflicts"); ForEach(p.conflicts, id: \.self) { small($0, mmOrange) } }
                        planArchives(p)
                        if !others.isEmpty {
                            sub("OTHER FILES", "others")
                            ForEach(others.prefix(60)) { it in
                                Text("\(mmKind(it.kind)):  \(it.dest)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.75))
                                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if others.count > 60 { small("… and \(others.count - 60) more") }
                        }
                        if p.hasScripts { small("It has scripts: the game's scripts are recompiled right after installing (a few seconds). If they don't compile, the mod is turned off again and the game keeps the scripts it had.") }
                        if !p.unsupported.isEmpty {
                            sub("SKIPPED", "skipped")
                            ForEach(p.unsupported, id: \.why) { u in
                                small("\(u.why)", mmYellow.opacity(0.9))
                                small(u.files.prefix(4).joined(separator: "\n") + (u.files.count > 4 ? "\n… and \(u.files.count - 4) more" : ""), .white.opacity(0.5))
                            }
                        }
                        if !p.ignored.isEmpty { small("Ignored (readme, images, …): \(mmCount(p.ignored.count, "file"))", .white.opacity(0.45)) }
                        if !p.hashesChecked && p.items.contains(where: { $0.kind == "archive" }) { small("This build has no list of the Mac game's resources, so the archives were not checked.", .white.opacity(0.45)) }
                    }
                }
                HStack(spacing: 10) {
                    if p.installable { bigButton("Install", pad: "A", style: 1) { model.installPlan() }.opacity(anySelected ? 1 : 0.4).disabled(!anySelected) }
                    Spacer()
                    bigButton(p.installable ? "Cancel" : "Close", pad: "B", style: 0) { model.cancelPlan() }
                }
                .padding(.top, 4)
            }
        }
    }

    private func orderPanel(_ mods: [ModManifest]) -> some View {
        panel {
            VStack(alignment: .leading, spacing: 8) {
                Text("Load order").font(.title3.weight(.heavy)).foregroundStyle(.white)
                small("The mod at the top loads first and wins when two mods change the same resource. Apply renames the archives to 001__name, 002__name, … so the game reads them in this order.", .white.opacity(0.65))
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(Array(mods.enumerated()), id: \.element.id) { i, m in orderRow(i, m, count: mods.count) }
                        }
                    }
                    .onChange(of: model.orderFocus) { i in if mods.indices.contains(i) { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(mods[i].id, anchor: .center) } } }
                }
                small(model.orderGrab ? "Moving: up / down carries the mod, A drops it." : "Controller: A picks a mod up to move it.", .white.opacity(0.45))
                HStack(spacing: 8) {
                    bigButton("Apply", pad: "X", style: 1) { model.applyOrder() }
                    if model.list.orderActive { bigButton("Remove numbers", pad: "Y", style: 0) { model.resetOrder() } }
                    Spacer(minLength: 0)
                    bigButton("Cancel", pad: "B", style: 0) { model.order = nil }
                }
            }
        }
    }
    private func orderRow(_ i: Int, _ m: ModManifest, count: Int) -> some View {
        let focused = model.orderFocus == i, grabbed = focused && model.orderGrab
        let conf = (model.list.conflicts[m.id] ?? []).filter { $0.kind == "archive" }
        return HStack(spacing: 10) {
            Text(String(format: "%03d", i + 1)).font(.system(size: 13, weight: .heavy, design: .monospaced)).foregroundStyle(mmYellow).frame(width: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(m.name).font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(m.enabled ? 1 : 0.5)).lineLimit(1)
                Text((m.enabled ? "" : "off · ") + (conf.isEmpty ? mmCount(m.files.filter { $0.path.lowercased().hasSuffix(".archive") }.count, "archive")
                                                               : "shares resources with " + conf.map(\.otherName).joined(separator: ", ")))
                    .font(.caption).foregroundStyle(conf.isEmpty ? .white.opacity(0.5) : mmOrange).lineLimit(1)
            }
            Spacer(minLength: 6)
            Button { model.orderFocus = i; model.orderGrab = false; model.orderMove(-1) } label: { Image(systemName: "arrow.up").frame(width: 40, height: 36).contentShape(Rectangle()) }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(i == 0 ? 0.2 : 0.9)).disabled(i == 0)
            Button { model.orderFocus = i; model.orderGrab = false; model.orderMove(1) } label: { Image(systemName: "arrow.down").frame(width: 40, height: 36).contentShape(Rectangle()) }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(i == count - 1 ? 0.2 : 0.9)).disabled(i == count - 1)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10).fill(grabbed ? mmYellow.opacity(0.25) : .white.opacity(focused ? 0.14 : 0.06))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(focused ? mmYellow : .white.opacity(0.12), lineWidth: focused ? 2 : 1)))
        .contentShape(Rectangle()).onTapGesture { model.orderFocus = i; model.orderGrab = false }
        .id(m.id)
    }

    private func profilePanel(_ p: ModProfile) -> some View {
        panel {
            VStack(alignment: .leading, spacing: 8) {
                Text(p.name).font(.title3.weight(.heavy)).foregroundStyle(.white).lineLimit(2)
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        line("Saved", p.saved.formatted(date: .abbreviated, time: .shortened))
                        line("On", "\(mmCount(p.mods.count, "mod")), \(mmCount(p.plugins.count, "plugin"))")
                        sub("LOADING IT NOW")
                        small(model.profileSummary(p))
                        sub("PLUGINS ON IN THIS PROFILE")
                        small(p.plugins.isEmpty ? "None" : p.plugins.joined(separator: ", "))
                    }
                }
                HStack(spacing: 8) {
                    bigButton("Load", pad: "A", style: 1) { model.loadProfile(p) }
                    bigButton("Save over it", pad: "X", style: 0) { model.overwriteProfile(p) }
                    bigButton("Delete…", pad: "Y", style: 0) { model.deleteProfile(p) }
                    Spacer(minLength: 0)
                    bigButton("Close", pad: "B", style: 0) { model.profileID = nil }
                }
                .padding(.top, 4)
            }
        }
    }
    private func namingPanel(_ name: String) -> some View {
        let taken = model.list.profiles.contains { ModStore.safeName($0.name).lowercased() == ModStore.safeName(name.trimmingCharacters(in: .whitespaces)).lowercased() }
        return panel {
            VStack(alignment: .leading, spacing: 10) {
                Text("Save profile").font(.title3.weight(.heavy)).foregroundStyle(.white)
                small("Remembers which mods and plugins are on right now (\(model.all.filter(\.enabled).count) mods, \(model.list.plugins.filter(\.enabled).count) plugins).", .white.opacity(0.75))
                TextField("Name", text: Binding(get: { model.naming ?? "" }, set: { model.naming = $0 }))
                    .focused($nameFocused).submitLabel(.done).foregroundStyle(.white).tint(mmYellow)
                    .padding(.horizontal, 12).frame(height: 44).background(box(nameFocused))
                    .onSubmit { nameFocused = false }
                if taken { small("A profile with this name exists: it is replaced.", mmYellow) }
                HStack(spacing: 10) {
                    bigButton("Save", pad: "A", style: 1) { nameFocused = false; model.saveProfile() }
                        .opacity(name.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
                    Spacer()
                    bigButton("Cancel", pad: "B", style: 0) { nameFocused = false; model.naming = nil }
                }
            }
        }
    }
    private func questionPanel(_ qn: MMQuestion) -> some View {
        panel {
            VStack(alignment: .leading, spacing: 10) {
                Text(qn.title).font(.title3.weight(.heavy)).foregroundStyle(.white)
                ViewThatFits(in: .vertical) {
                    small(qn.message, .white.opacity(0.85))
                    ScrollView { small(qn.message, .white.opacity(0.85)) }
                }
                if qn.backupOffer {
                    let on = model.list.settings.backupSaves
                    Button { model.set { $0.backupSaves.toggle() } } label: {
                        HStack(spacing: 10) {
                            Image(systemName: on ? "checkmark.square.fill" : "square").font(.title3).foregroundStyle(on ? mmYellow : .white.opacity(0.4))
                            Text("Back up the saves first" + (on ? "" : " (off)")).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.9))
                            Text("X").font(.caption2.weight(.bold)).padding(.horizontal, 5).padding(.vertical, 1).overlay(Capsule().stroke(lineWidth: 1)).opacity(0.6).foregroundStyle(.white)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 10) {
                    bigButton(qn.yes, pad: "A", style: qn.destructive ? 2 : 1) { model.question = nil; qn.action() }
                    Spacer()
                    bigButton("Cancel", pad: "B", style: 0) { model.question = nil }
                }
            }
        }
    }
    private func errorPanel(_ e: MMError) -> some View {
        panel {
            VStack(alignment: .leading, spacing: 10) {
                Text(e.title).font(.headline).foregroundStyle(e.bad ? mmRed : mmYellow).fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    Text(e.text).font(e.bad ? .system(size: 11, design: .monospaced) : .subheadline).foregroundStyle(.white.opacity(0.85))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 10) {
                    if e.bad { Button { UIPasteboard.general.string = e.text } label: { Label("Copy", systemImage: "doc.on.doc").font(.caption.weight(.semibold)).foregroundStyle(mmYellow) } }
                    Spacer()
                    bigButton("Close", pad: "B", style: 0) { model.error = nil }
                }
            }
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.black, Color(red: 0.08, green: 0.02, blue: 0.06)], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
            VStack { Rectangle().fill(mmYellow).frame(height: 3); Spacer(); Rectangle().fill(mmRed.opacity(0.8)).frame(height: 2) }.ignoresSafeArea()
            VStack(spacing: 0) { topBar; content }
                .disabled(model.busy != nil)
                .accessibilityHidden(model.panelOpen)
            if let m = model.detail { detailPanel(m) }
            if let p = model.profile { profilePanel(p) }
            if let o = model.order { orderPanel(o) }
            if let p = model.plan { planPanel(p) }
            if let n = model.naming { namingPanel(n) }
            if let qn = model.question { questionPanel(qn) }
            if let e = model.error { errorPanel(e) }
        }
        .preferredColorScheme(.dark)
        .onAppear { model.close = { dismiss() }; model.refresh(); model.startPad() }
        .onDisappear { model.stopPad() }
        // the keyboard of the search box follows the model (the controller's A opens it, A or B closes it)
        .onChange(of: model.typing) { t in if searchFocused != t { searchFocused = t } }
        .onChange(of: searchFocused) { f in if model.typing != f { model.typing = f } }
        .fileImporter(isPresented: $model.picking, allowedContentTypes: [.item], allowsMultipleSelection: false) { model.picked($0) }
        .persistentSystemOverlays(.hidden)
        .statusBarHidden(true)
    }
}

extension ModManagerView {
    /// the bundled plugins (ModSupport/) need the Steam 2.5.0 game program; the shim says at start whether they can load
    var pluginsNote: String {
        if UserDefaults.standard.string(forKey: "CyPortModPlugins") == "nohooks" {
            return "RED4ext, Cyber Engine Tweaks, TweakXL, ArchiveXL, Codeware and the other plugins are in this app, but they only run with Cyberpunk 2.5.0 from Steam (an app built for that one version). Plain .archive and script mods work without them."
        }
        return model.list.plugins.isEmpty ? "No plugin folders in red4ext/plugins." : "All plugins start off. Turn on the ones your mods need (importing a mod offers it); turning one off moves its folder out of the game and mods that need it stop working."
    }
}
