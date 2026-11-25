// Launcher.swift - the start screen (SwiftUI). Resolution + performance overlay + PLAY.
// Everything else is set in the game's own Settings menu. The shim (MacShim.m) creates it through
// MSSwiftLauncher.make(...) and gets the choices back in the onPlay callback.
// Everything that can be tapped can also be reached with a controller, the same way as on the Mods screen (ModManagerUI.swift):
//   D-pad / left stick  move      left / right  change a value      A  press / switch      B  back to PLAY      Menu  PLAY
// The two questions (Restore defaults, game data doesn't match) are drawn by this screen itself, so A / B / Y answer them.
import SwiftUI
import UIKit
import GameController

private let cyberYellow = Color(red: 0.99, green: 0.93, blue: 0.04)

private let cyberRed = Color(red: 1.0, green: 0.0, blue: 0.24)

enum MSPadKey: Hashable { case up, down, left, right, a, b, x, y, menu }

/// Reads the controllers 30 times a second (no handlers are set on them: those belong to the game and the shim) and turns
/// button presses into keys; the directions repeat while held. Used by the start screen and the store screen; the Mods
/// screen has the same loop of its own.
final class MSPadPoller {
    /// (key, repeat): repeat is true for the repeats of a held direction
    var onKey: (MSPadKey, Bool) -> Void = { _, _ in }
    var onConnected: (Bool) -> Void = { _ in }
    /// true while another screen is on top: nothing is passed on, and what is held when it ends has to be let go first
    var gate: () -> Bool = { false }
    private var timer: Timer?
    private var held: [MSPadKey: Date] = [:]
    private var swallow = true
    private var connected = false

    func start() {
        stop(); swallow = true             // a button still held from the screen before (A that opened this one) doesn't count
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.poll() }
    }
    func stop() { timer?.invalidate(); timer = nil; held.removeAll() }
    deinit { timer?.invalidate() }

    private func poll() {
        var down = Set<MSPadKey>(), any = false
        // not the shim's on-screen controller (a snapshot), and only standard gamepads: DualSense, Xbox, Switch Pro, GameSir, ...
        for c in GCController.controllers() where !c.isSnapshot {
            guard let g = c.extendedGamepad else { continue }
            any = true
            let x = g.leftThumbstick.xAxis.value, y = g.leftThumbstick.yAxis.value
            let vertical = abs(y) >= abs(x)
            if g.dpad.up.isPressed || (y > 0.6 && vertical) { down.insert(.up) }
            if g.dpad.down.isPressed || (y < -0.6 && vertical) { down.insert(.down) }
            if g.dpad.left.isPressed || (x < -0.6 && !vertical) { down.insert(.left) }
            if g.dpad.right.isPressed || (x > 0.6 && !vertical) { down.insert(.right) }
            if g.buttonA.isPressed { down.insert(.a) }
            if g.buttonB.isPressed { down.insert(.b) }
            if g.buttonX.isPressed { down.insert(.x) }
            if g.buttonY.isPressed { down.insert(.y) }
            if g.buttonMenu.isPressed { down.insert(.menu) }
        }
        if any != connected { connected = any; onConnected(any) }
        let gated = gate()
        if gated || swallow {
            // one more round after the other screen closes: its B may reach this loop a moment after it reached that screen's
            for b in down { held[b] = .distantFuture }
            for b in Array(held.keys) where !down.contains(b) { held[b] = nil }
            swallow = gated
            return
        }
        let now = Date()
        for b in down {
            if let t = held[b] {
                if b == .up || b == .down || b == .left || b == .right, now >= t { held[b] = now.addingTimeInterval(0.12); onKey(b, true) }
            } else { held[b] = now.addingTimeInterval(0.4); onKey(b, false) }
        }
        for b in Array(held.keys) where !down.contains(b) { held[b] = nil }
    }
}

/// what the controller can stand on, in the order it is on the screen
private enum LFocus: Hashable {
    case mods, resolution, overlay, smoothPacing, gameThread, lowLatency, frameGen, memoryHeadroom, phoneRumble, vibration, triggers, kbm
    case lookMode, touchHaptics, silentSound, mixAudio, sensitivity, restore, cloudStore, cloudAction, signOut, importSaves
    case play, update
}

private extension View {
    /// the controller's focus frame (the same yellow outline as on the Mods screen)
    func padFocus(_ on: Bool, color: Color = cyberYellow, radius: CGFloat = 10, width: CGFloat = 2, dx: CGFloat = 0, dy: CGFloat = 0) -> some View {
        overlay(RoundedRectangle(cornerRadius: radius).fill(on && (dx != 0 || dy != 0) ? color.opacity(0.12) : .clear)
                    .overlay(RoundedRectangle(cornerRadius: radius).stroke(on ? color : .clear, lineWidth: width))
                    .padding(.horizontal, -dx).padding(.vertical, -dy).allowsHitTesting(false))
    }
}

private final class LauncherModel: ObservableObject {
    let resolutions: [String]
    let notes: [String]
    @Published var resolution: Int
    @Published var overlay: Int
    @Published var starting = false
    @Published var source = CloudSource.preferred
    @Published var cloudOn = CloudSource.preferred.signedIn
    @Published var cloudStatus: String?
    @Published var cloudFailed = false
    @Published var syncing = false
    @Published var signingIn = false
    func setSource(_ s: CloudSource) {
        CloudSource.preferred = s; source = s; cloudOn = s.signedIn; cloudStatus = nil; cloudFailed = false
        if cloudOn { sync() }
    }
    /// runs when the start screen opens and after signing in: the phone gets what's new in the cloud (and, for GOG,
    /// the cloud gets what's new on the phone)
    func sync() {
        guard cloudOn, !syncing else { return }
        syncing = true; cloudFailed = false
        let s = source
        Task { @MainActor in
            do {
                let r = try await GameCloud.sync(s) { p in Task { @MainActor in self.cloudStatus = p } }
                cloudStatus = r.summary
            } catch {
                cloudStatus = error.localizedDescription; cloudFailed = true
                GameCloud.log("\(s.rawValue) sync failed: \(error.localizedDescription)")
            }
            syncing = false
        }
    }
    // Import saves… (own save files from a Mac or PC, through Files)
    @Published var importing = false
    @Published var importStatus: String?
    func importSaves(_ r: Result<[URL], Error>) {
        switch r {
        case .failure(let e): importStatus = e.localizedDescription
        case .success(let urls):
            do {
                let n = try GameCloud.importSaves(from: urls)
                importStatus = n == 0 ? "No saves found there. Pick a save folder (like ManualSave-3) or the folder that holds them."
                                      : "Imported \(n) save\(n == 1 ? "" : "s"). Load them from Load Game in the game."
                if n > 0, cloudOn { sync() }
            } catch {
                importStatus = "Import failed: \(error.localizedDescription)"
                GameCloud.log("import saves failed: \(error.localizedDescription)")
            }
        }
    }
    func signedInNow() { signingIn = false; cloudOn = source.signedIn; if cloudOn { sync() } }
    func signOut() { source.signOut(); cloudOn = false; cloudStatus = nil; cloudFailed = false }
    // game data version (Update Cyberpunk)
    @Published var dataStatus = GameData.Status.unknown
    @Published var newerVersion: String?                      // a newer Cyberpunk on GOG than this CyPort plays
    @Published var updating = false
    @Published var askUpdate = false
    var gameRoot: URL? { MSSwiftLauncher.gameRoot.isEmpty ? nil : URL(fileURLWithPath: MSSwiftLauncher.gameRoot, isDirectory: true) }
    func checkData() {
        let root = gameRoot
        Task.detached(priority: .utility) {
            let st = GameData.quick(root)
            await MainActor.run { self.dataStatus = st }
            storeLog("start screen: game data \(st), this CyPort plays \(GameData.appVersionName)")
        }
        Task { @MainActor in
            guard newerVersion == nil, let b = try? await GOGStore.shared.builds(), let top = b.first else { return }
            let newestHere = max(GameData.versions.map(\.number).max() ?? 0, GameData.number(GameData.appVersionName))
            if GameData.number(top.version) > newestHere { newerVersion = top.version }
        }
    }
    var dataNeedsUpdate: Bool { switch dataStatus { case .update, .windows, .missing: return true; default: return false } }
    let onPlay: (Int, Int) -> Void

    /// the PLAY button (and the controller's Menu button)
    func play() {
        guard !starting, !syncing else { return }
        if dataNeedsUpdate { askUpdate = true; return }
        start(haptic: true)
    }
    func start(haptic: Bool) {
        starting = true
        stopPad()                                              // from here on the controller is the game's
        GameCloud.startWatching()
        ModStore.notePlay(gameRoot: MSSwiftLauncher.gameRoot)  // for the Mods screen's "since the last Play"
        if haptic { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
        onPlay(resolution, overlay)
    }

    // ---------------------------------------------------------------- controller
    @Published var focus: LFocus?
    @Published var padConnected = false
    @Published var askRestore = false
    @Published var showMods = false
    /// set by the view: A / left / right on the rows whose values live in the view (@AppStorage), and "Restore defaults"
    var act: (LFocus, MSPadKey, Bool) -> Void = { _, _, _ in }
    var restore: () -> Void = {}
    private let pad = MSPadPoller()

    var rows: [LFocus] {
        var r: [LFocus] = [.mods, .resolution, .overlay, .smoothPacing, .gameThread, .lowLatency, .frameGen, .memoryHeadroom, .phoneRumble,
                           .vibration,                           .triggers, .kbm, .lookMode, .touchHaptics, .silentSound, .mixAudio, .sensitivity, .restore, .cloudStore, .cloudAction]
        if cloudOn && !syncing { r.append(.signOut) }
        return r + [.importSaves, .play, .update]
    }
    func startPad() {
        guard !starting else { return }
        // the Mods screen and the update screen read the controller themselves; the Files picker is the system's
        pad.gate = { [weak self] in guard let s = self else { return true }; return s.showMods || s.updating || s.importing }
        pad.onKey = { [weak self] k, rep in self?.key(k, rep) }
        pad.onConnected = { [weak self] on in
            guard let s = self else { return }
            s.padConnected = on
            if on, s.focus == nil { s.focus = .play }
        }
        pad.start()
    }
    func stopPad() { pad.stop() }
    private func key(_ k: MSPadKey, _ rep: Bool) {
        guard !starting else { return }
        if signingIn { if k == .b { signedInNow() }; return }       // the sign-in sheet: B is its Cancel
        if askRestore {
            if k == .a { askRestore = false; restore() } else if k == .b { askRestore = false }
            return
        }
        if askUpdate {
            switch k {
            case .a: askUpdate = false; updating = true
            case .y: askUpdate = false; start(haptic: false)
            case .b: askUpdate = false
            default: break
            }
            return
        }
        let r = rows
        switch k {
        case .up, .down:
            guard let f = focus, let i = r.firstIndex(of: f) else { focus = .play; return }
            var n = i + (k == .down ? 1 : -1)
            // past the end: around to the other end, but a held direction stops there
            if n < 0 || n >= r.count { if rep { return }; n = (n + r.count) % r.count }
            focus = r[n]
        case .menu: play()
        case .b: focus = .play
        case .a, .left, .right:
            guard let f = focus, r.contains(f) else { focus = .play; return }
            activate(f, k, rep)
        default: break
        }
    }
    /// A steps to the next value and starts over after the last one; left / right stop at the ends
    private func activate(_ f: LFocus, _ k: MSPadKey, _ rep: Bool) {
        let d = k == .left ? -1 : 1
        switch f {
        case .play: if k == .a { play() }
        case .update: if k == .a, gameRoot != nil { updating = true }
        case .mods: if k == .a, gameRoot != nil { showMods = true }
        case .resolution:
            let n = resolutions.count
            if n > 0 { resolution = k == .a ? (resolution + 1) % n : max(0, min(n - 1, resolution + d)) }
        case .overlay: overlay = k == .a ? (overlay + 1) % 3 : max(0, min(2, overlay + d))
        case .restore: if k == .a { askRestore = true }
        case .cloudStore:
            let all = CloudSource.allCases
            guard !syncing, let i = all.firstIndex(of: source) else { return }
            let n = k == .a ? (i + 1) % all.count : max(0, min(all.count - 1, i + d))
            if n != i { setSource(all[n]) }
        case .cloudAction:
            guard k == .a else { return }
            if !cloudOn { signingIn = true } else if !syncing { sync() }
        case .signOut: if k == .a { signOut(); focus = .cloudAction }
        case .importSaves: if k == .a, !syncing { importing = true }
        default: act(f, k, rep)
        }
    }
    init(resolutions: [String], notes: [String], resolution: Int, overlay: Int, onPlay: @escaping (Int, Int) -> Void) {
        self.resolutions = resolutions; self.notes = notes; self.resolution = resolution; self.overlay = overlay; self.onPlay = onPlay
    }
}

private struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    /// swipe-to-look speed, read by the shim when the game starts (MSLookSensitivity)
    @AppStorage("CyPortLookSensitivity") private var lookSensitivity = 1.5
    /// read by the shim when the game starts (MSLowLatencyOn): 2 drawables + input read once the render thread is ready
    @AppStorage("CyPortLowLatency") private var lowLatency = false
    /* read by the shim at PLAY (g_offMain): the game on its own thread, the main thread free for touches and controllers */
    @AppStorage("CyPortGameThread") private var gameThread = true
    /// read by the shim (MSSmoothOn): hold the game to an even 120/60/40/30 it can keep up with
    @AppStorage("CyPortSmoothPacing") private var smoothPacing = true
    /// read by the shim (MSRumbleOn / MSTriggersOn): controller rumble and PS5 adaptive trigger effects
    @AppStorage("CyPortVibration") private var vibration = true
    @AppStorage("CyPortAdaptiveTriggers") private var adaptiveTriggers = true
    /// read by the shim (MSPadOnly): with a controller connected the game gets no touch, mouse or keyboard input
    @AppStorage("CyPortKBMWithController") private var kbmWithController = false
    /// read by the shim (MSLookMode): 2 = floating right stick (like DK Bananza / Mario Kart World), 1 = swipe
    @AppStorage("CyPortLookMode") private var lookMode = 2
    /// read by the shim (MSPadView msFeel): a short tap on each on-screen button press
    @AppStorage("CyPortTouchHaptics") private var touchHaptics = true
    /// read by the shim (MSAudioSessionSetup): game sound plays with the ring/silent switch on silent
    @AppStorage("CyPortSilentModeSound") private var silentModeSound = true
    /// read by the shim (MSAudioSessionSetup): music from other apps keeps playing under the game
    @AppStorage("CyPortMixAudio") private var mixAudio = false
    /// read by the shim (MSMacOS26On): the game sees macOS 26 and Apple's MetalFX frame generation is switched on in it.
    /// Off by default; the shim turns it off again when frame generation is turned off in the game's menu
    @AppStorage("CyPortAppleFrameGen") private var appleFrameGen = false
    /// read by the shim (MSPhoneRumbleOn): with touch controls the game's controller rumble plays on the phone
    @AppStorage("CyPortPhoneRumble") private var phoneRumble = true
    /// read by the shim (MSHeadroomOn): the game is told 6 GB of RAM and at most 5 GB for the GPU (long sessions on 12 GB phones)
    @AppStorage("CyPortMemoryHeadroom") private var memoryHeadroom = false

    private func on(_ f: LFocus) -> Bool { model.padConnected && model.focus == f }
    /// the controller on the rows whose values are stored here
    private func padAct(_ f: LFocus, _ k: MSPadKey, _ rep: Bool) {
        func flip(_ b: Binding<Bool>) { if k == .a { b.wrappedValue.toggle() } else { b.wrappedValue = k == .right } }
        switch f {
        case .smoothPacing: flip($smoothPacing)
        case .gameThread: flip($gameThread)
        case .lowLatency: flip($lowLatency)
        case .frameGen: flip($appleFrameGen)
        case .memoryHeadroom: flip($memoryHeadroom)
        case .phoneRumble: flip($phoneRumble)
        case .vibration: flip($vibration)
        case .triggers: flip($adaptiveTriggers)
        case .kbm: flip($kbmWithController)
        case .touchHaptics: flip($touchHaptics)
        case .silentSound: flip($silentModeSound)
        case .mixAudio: flip($mixAudio)
        case .lookMode: lookMode = k == .a ? (lookMode == 2 ? 1 : 2) : (k == .right ? 1 : 2)        // Stick (2) is on the left
        case .sensitivity:
            guard k != .a else { return }
            let step = (rep ? 0.1 : 0.05) * (k == .right ? 1 : -1)
            lookSensitivity = min(4, max(0.25, ((lookSensitivity + step) * 20).rounded() / 20))
        default: break
        }
    }

    /// "Restore defaults": every start screen option back to what works best on most phones, the on-screen buttons back to
    /// their standard places, and at Play the game's graphics + display settings back to the phone defaults (MSResetGameGraphics).
    /// Saves, cloud sign-in, game files and the game's audio / controls / gameplay settings are left alone.
    private func restoreDefaults() {
        if let i = model.notes.firstIndex(of: "recommended") { model.resolution = i }
        model.overlay = 1
        smoothPacing = true; gameThread = true; lowLatency = false; appleFrameGen = false
        vibration = true; adaptiveTriggers = true; kbmWithController = false; phoneRumble = true; memoryHeadroom = false
        lookMode = 2; touchHaptics = true; lookSensitivity = 1.5
        silentModeSound = true; mixAudio = false
        let d = UserDefaults.standard
        for k in d.dictionaryRepresentation().keys where k.hasPrefix("CyPortTouchLayout-") { d.removeObject(forKey: k) }
        d.set(true, forKey: "CyPortResetGameGraphics")     // the shim resets the game's graphics settings at Play
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        storeLog("start screen: options restored to defaults")
    }
    private var restoreButton: some View {
        Button { model.askRestore = true } label: {
            Label("Restore defaults", systemImage: "arrow.counterclockwise")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 300, height: 40)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.15)))
        }
        .disabled(model.starting)
        .padFocus(on(.restore)).id(LFocus.restore)
    }

    private var dataText: String? {
        let v = GameData.appVersionName
        switch model.dataStatus {
        case .unknown: return nil
        case .ok: return "Game data: Cyberpunk \(v) ✓"
        case .missing: return "No game data found. Tap Update Cyberpunk to download it (Cyberpunk \(v))."
        case .windows: return "These are the Windows version's files. CyPort needs the Mac version's data, which comes with your Steam or GOG purchase: tap Update Cyberpunk to get it (Cyberpunk \(v))."
        case .update(let n, let b):
            return String(format: "Your game data isn't the version this CyPort plays (Cyberpunk %@): %d file%@ to update (up to %.1f GB). Tap Update Cyberpunk.", v, n, n == 1 ? "" : "s", Double(b) / 1e9)
        }
    }
    @ViewBuilder private var updateSection: some View {
        VStack(spacing: 6) {
            // the big button only when the data needs it; otherwise: a small link to the
            // same screen (verify files, pick the game version)
            if model.dataNeedsUpdate {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    model.updating = true
                } label: {
                    Label("UPDATE CYBERPUNK", systemImage: "arrow.down.circle")
                        .font(.subheadline.weight(.heavy)).tracking(1)
                        .foregroundStyle(model.dataNeedsUpdate ? .black : cyberYellow)
                        .frame(width: 300, height: 42)
                        .background(model.dataNeedsUpdate ? cyberYellow : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(cyberYellow.opacity(0.6)))
                }
                .disabled(model.starting || model.gameRoot == nil)
                .padFocus(on(.update), color: .white, width: 3)
            } else {
                Button { model.updating = true } label: {
                    Label("Game files & version", systemImage: "checkmark.seal").font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .disabled(model.starting || model.gameRoot == nil)
                .padFocus(on(.update), radius: 6, dx: 6, dy: 4)
            }
            if let t = dataText {
                Text(t).font(.caption).foregroundStyle(model.dataNeedsUpdate ? cyberRed : .white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true).frame(width: 300, alignment: .leading)
            }
            if let n = model.newerVersion {
                Text("Cyberpunk \(n.prefix { $0 != "_" }) is out. This CyPort plays \(GameData.appVersionName); playing \(n.prefix { $0 != "_" }) needs the CyPort build for it. Your saves carry over.")
                    .font(.caption).foregroundStyle(cyberYellow.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true).frame(width: 300, alignment: .leading)
            }
        }
        .id(LFocus.update)
    }

    /// a 300 pt wide boxed row like the Resolution button; the switch keeps its own size so it is never pushed off the edge
    private func switchRow(_ row: LFocus, _ title: String, icon: String, isOn: Binding<Bool>, note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label(title, systemImage: icon)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                Toggle(title, isOn: isOn).labelsHidden().tint(cyberYellow).fixedSize()
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(width: 300)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.15)))
            .padFocus(on(row))
            Text(note)
                .font(.caption).foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 300, alignment: .leading)
        }
        .id(row)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
                    Text("CYPORT")
                        .font(.system(size: 52, weight: .black, design: .default))
                        .italic()
                        .foregroundStyle(cyberYellow)
                        .shadow(color: cyberRed.opacity(0.6), radius: 0, x: 3, y: 2)
                        .lineLimit(1).minimumScaleFactor(0.6)   // narrow screens (iPhone Duo folded): smaller, never wrapped
                    Text("RUNS YOUR OWN COPY OF THE GAME")
                        .font(.system(size: 13, weight: .heavy, design: .monospaced))
                        .tracking(3)
                        .foregroundStyle(.white.opacity(0.85))
        }
    }
    private var noteText: some View {
        Text("Other graphics settings are in the game's own Settings menu - they're kept between launches.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: 300, alignment: .leading)
    }
    @ViewBuilder private var padHint: some View {
        if model.padConnected {
            Text("Controller:  D-pad move  ·  left / right change  ·  A select  ·  Menu play")
                .font(.caption2).foregroundStyle(.white.opacity(0.35)).frame(maxWidth: 300, alignment: .leading)
        }
    }
    /// the options list; it follows the controller's focus
    private func scroller<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        let content = c()
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) { content }
                .onChange(of: model.focus) { f in if let f { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(f, anchor: .center) } } }
        }
    }
    @ViewBuilder private var optionRows: some View {
                    // the mod manager (shim/ModManagerUI.swift): list, on/off, delete, import from Files, plugin switches
                    Button { model.showMods = true } label: {
                        HStack {
                            Label("Mods", systemImage: "puzzlepiece.extension").font(.subheadline.weight(.semibold))
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.bold))
                        }
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 14).frame(width: 300, height: 44)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(cyberYellow.opacity(0.6)))
                    }
                    .disabled(model.starting || model.gameRoot == nil)
                    .padFocus(on(.mods)).id(LFocus.mods)
                    .fullScreenCover(isPresented: $model.showMods) { ModManagerView(gameRoot: MSSwiftLauncher.gameRoot) }

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Resolution", systemImage: "rectangle.on.rectangle")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.7))
                        Menu {
                            Picker("Resolution", selection: $model.resolution) {
                                ForEach(Array(model.resolutions.enumerated()).reversed(), id: \.offset) { i, r in
                                    Text(model.notes[i].isEmpty ? r : "\(r)  ·  \(model.notes[i])").tag(i)
                                }
                            }
                        } label: {
                            HStack {
                                Text(model.resolutions[model.resolution]).font(.headline.monospacedDigit())
                                if !model.notes[model.resolution].isEmpty {
                                    Text(model.notes[model.resolution]).font(.caption).foregroundStyle(.black.opacity(0.6))
                                        .padding(.horizontal, 6).padding(.vertical, 2).background(cyberYellow.opacity(0.85), in: Capsule())
                                }
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.bold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .frame(width: 300)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.15)))
                        }
                        .padFocus(on(.resolution))
                    }
                    .id(LFocus.resolution)

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Performance overlay", systemImage: "speedometer")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.7))
                        Picker("Performance overlay", selection: $model.overlay) {
                            Text("Off").tag(0); Text("FPS").tag(1); Text("Detailed").tag(2)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 300)
                        .padFocus(on(.overlay), radius: 9)
                    }
                    .id(LFocus.overlay)

                    switchRow(.smoothPacing, "Smooth frame pacing", icon: "waveform.path", isOn: $smoothPacing,
                              note: smoothPacing ? "Even frame times: holds 120, 60, 40 or 30 FPS, whatever the phone keeps up with." : (appleFrameGen ? "Off: best with frame generation (it turns off when frame generation goes on)." : "Off: the game's own frame cap only."))
                    switchRow(.gameThread, "Smooth controls", icon: "hand.tap", isOn: $gameThread,
                              note: gameThread ? "The game runs on its own thread: touch and controller input don't wait for the game's frames." : "Off: the old way (controls follow the game's frame rate). Try this if the game won't start.")
                    switchRow(.lowLatency, "Low-latency input", icon: "bolt.horizontal", isOn: $lowLatency,
                              note: lowLatency ? "Snappier controls. Costs a few FPS when the GPU is the limit." : "Off: best frame rate.")
                    switchRow(.frameGen, "Apple frame generation", icon: "sparkles.tv", isOn: $appleFrameGen,
                              note: appleFrameGen ? "Apple's MetalFX frame generation is on in the game. Turning it off in the game turns this off too." : "Off: no Apple frame generation.")
                    switchRow(.memoryHeadroom, "Memory headroom", icon: "memorychip", isOn: $memoryHeadroom,
                              note: memoryHeadroom ? "The game plans with less memory, so iOS is less likely to close it in long sessions. Takes full effect the next time you open the app." : "Off: the game uses what Metal recommends. Turn on if the game closes by itself after a while.")
                    switchRow(.phoneRumble, "Phone vibration", icon: "iphone.radiowaves.left.and.right", isOn: $phoneRumble,
                              note: phoneRumble ? "With touch controls the phone rumbles like a controller would (explosions, gunfire, crashes). Off while a controller is connected." : "Off: the phone doesn't rumble.")
                    switchRow(.vibration, "Controller vibration", icon: "gamecontroller", isOn: $vibration,
                              note: vibration ? "Rumble on controllers that have it." : "Off: no rumble.")
                    switchRow(.triggers, "Adaptive triggers", icon: "l2.button.roundedtop.horizontal", isOn: $adaptiveTriggers,
                              note: adaptiveTriggers ? "PS5 controller trigger resistance." : "Off: PS5 triggers stay loose.")
                    switchRow(.kbm, "Touch + mouse with controller", icon: "computermouse", isOn: $kbmWithController,
                              note: kbmWithController ? "Screen, mouse and keyboard still reach the game while a controller is connected." : "Off: with a controller connected, only the controller controls the game.")

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Touch camera", systemImage: "camera.viewfinder")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.7))
                        Picker("Touch camera", selection: $lookMode) {
                            Text("Stick").tag(2)
                            Text("Swipe").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 300)
                        .padFocus(on(.lookMode), radius: 9)
                        Text(lookMode == 2 ? "Right side is a floating stick: hold to keep turning. Same feel at any frame rate." : "Swipe the right side: the camera follows your finger's speed.")
                            .font(.caption).foregroundStyle(.white.opacity(0.5)).frame(width: 300, alignment: .leading)
                    }
                    .id(LFocus.lookMode)
                    switchRow(.touchHaptics, "Touch vibration", icon: "hand.tap", isOn: $touchHaptics,
                              note: touchHaptics ? "A short tap on each on-screen button press." : "Off: on-screen buttons are silent.")
                    switchRow(.silentSound, "Sound in silent mode", icon: "speaker.wave.2", isOn: $silentModeSound,
                              note: silentModeSound ? "Game sound plays even with the silent switch on." : "Off: the silent switch mutes the game.")
                    switchRow(.mixAudio, "Mix with other audio", icon: "music.note", isOn: $mixAudio,
                              note: mixAudio ? "Music from other apps keeps playing under the game." : "Off: the game stops other apps' audio.")

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("Look sensitivity", systemImage: "hand.draw")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.7))
                            Spacer()
                            Text(String(format: "%.1f×", lookSensitivity)).font(.subheadline.monospacedDigit().weight(.semibold)).foregroundStyle(cyberYellow)
                        }
                        .frame(width: 300)
                        Slider(value: $lookSensitivity, in: 0.25...4, step: 0.05)
                            .tint(cyberYellow).frame(width: 300)
                    }
                    .padFocus(on(.sensitivity), dx: 1, dy: 5).id(LFocus.sensitivity)
                    restoreButton

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Cloud saves", systemImage: "icloud")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.7))
                        Picker("Store", selection: Binding(get: { model.source }, set: { model.setSource($0) })) {
                            ForEach(CloudSource.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented).frame(width: 300).disabled(model.syncing)
                        .padFocus(on(.cloudStore), radius: 9).id(LFocus.cloudStore)
                        HStack {
                            if model.syncing { ProgressView().controlSize(.small) }
                            Text(model.cloudStatus ?? (model.cloudOn ? "Signed in\(model.source.account.map { " as \($0)" } ?? "")"
                                                                     : "Sign in to get your \(model.source.rawValue) saves (optional)"))
                                .font(.caption).foregroundStyle(model.cloudFailed ? cyberRed : .white.opacity(0.75)).lineLimit(3)
                            Spacer()
                            if model.cloudOn {
                                Button("Sync now") { model.sync() }
                                    .font(.caption.weight(.semibold)).foregroundStyle(cyberYellow).disabled(model.syncing)
                                    .padFocus(on(.cloudAction), radius: 6, dx: 1, dy: 4)
                            } else {
                                Button("Sign in…") { model.signingIn = true }
                                    .font(.caption.weight(.semibold)).foregroundStyle(cyberYellow)
                                    .padFocus(on(.cloudAction), radius: 6, dx: 1, dy: 4)
                            }
                        }
                        .frame(width: 300).id(LFocus.cloudAction)
                        if model.cloudOn && !model.syncing {
                            HStack {
                                Text("Syncs both ways with \(model.source.rawValue) - your PC and Mac get your phone saves")
                                    .font(.caption2).foregroundStyle(.white.opacity(0.45))
                                Spacer()
                                Button("Sign out") { model.signOut() }.font(.caption2).foregroundStyle(.white.opacity(0.5))
                                    .padFocus(on(.signOut), radius: 6, dx: 1, dy: 4)
                            }
                            .frame(width: 300).id(LFocus.signOut)
                        }
                        HStack(alignment: .top) {
                            Text(model.importStatus ?? "Have saves from a Mac or PC? Copy the save folders to Files, then import them.")
                                .font(.caption2).foregroundStyle(.white.opacity(0.45))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("Import saves…") { model.importing = true }
                                .font(.caption.weight(.semibold)).foregroundStyle(cyberYellow).disabled(model.syncing || model.starting)
                                .padFocus(on(.importSaves), radius: 6, dx: 1, dy: 4)
                        }
                        .frame(width: 300).id(LFocus.importSaves)
                    }

    }
    private var playButton: some View {
        Button { model.play() } label: {
                        HStack(spacing: 10) {
                            if model.starting { ProgressView().tint(.black) } else { Image(systemName: "play.fill") }
                            Text(model.starting ? "STARTING…" : "PLAY").font(.title3.weight(.black)).tracking(2)
                        }
                        .foregroundStyle(.black)
                        .frame(width: 300, height: 52)
                        .background(cyberYellow, in: RoundedRectangle(cornerRadius: 12))
                        .shadow(color: cyberYellow.opacity(0.35), radius: 12)
                    }
                    .disabled(model.starting || model.syncing)
                    .padFocus(on(.play), color: .white, radius: 12, width: 3).id(LFocus.play)
    }

    // ---------------------------------------------------------------- questions (drawn here so the controller can answer; same look as the Mods screen's)
    private func bigButton(_ t: String, pad: String, style: Int, _ action: @escaping () -> Void) -> some View {
        // style 0 = plain, 1 = yellow, 2 = red
        Button(action: action) {
            HStack(spacing: 8) {
                Text(t).font(.subheadline.weight(.heavy)).lineLimit(1)
                Text(pad).font(.caption2.weight(.bold)).padding(.horizontal, 5).padding(.vertical, 1).overlay(Capsule().stroke(lineWidth: 1)).opacity(0.6)
            }
            .foregroundStyle(style == 1 ? Color.black : .white).padding(.horizontal, 16).frame(minWidth: 110, minHeight: 44)
            .background(style == 1 ? cyberYellow : (style == 2 ? cyberRed.opacity(0.85) : Color.white.opacity(0.12)), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
    private func questionPanel<B: View, S: View>(_ title: String, _ message: String, @ViewBuilder wide: () -> B, @ViewBuilder stacked: () -> S) -> some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.title3.weight(.heavy)).foregroundStyle(.white)
                let text = Text(message).font(.caption).foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                ViewThatFits(in: .vertical) { text; ScrollView { text } }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { wide() }
                    VStack(alignment: .leading, spacing: 8) { stacked() }       // upright (iPhone Duo): one under the other
                }
            }
            .padding(18).frame(maxWidth: 640)
            .background(Color(red: 0.09, green: 0.07, blue: 0.09), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(cyberYellow.opacity(0.5)))
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
    }
    private var restorePanel: some View {
        let yes = bigButton("Restore", pad: "A", style: 2) { model.askRestore = false; restoreDefaults() }
        let no = bigButton("Cancel", pad: "B", style: 0) { model.askRestore = false }
        return questionPanel("Restore defaults?", "All options on this screen go back to the recommended settings, the on-screen buttons back to their standard places, and the game's graphics settings back to the phone defaults when you press Play. Your saves, cloud sign-in, game files and the game's audio, controls and gameplay settings stay as they are.",
                             wide: { yes; Spacer(); no }, stacked: { yes; no })
    }
    private var updatePanel: some View {
        let update = bigButton("Update Cyberpunk", pad: "A", style: 1) { model.askUpdate = false; model.updating = true }
        let play = bigButton("Play anyway", pad: "Y", style: 2) { model.askUpdate = false; model.start(haptic: false) }
        let no = bigButton("Cancel", pad: "B", style: 0) { model.askUpdate = false }
        return questionPanel("Game data doesn't match", dataText ?? "", wide: { update; play; Spacer(); no }, stacked: { update; play; no })
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.black, Color(red: 0.08, green: 0.02, blue: 0.06)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            // thin neon accents
            VStack { Rectangle().fill(cyberYellow).frame(height: 3); Spacer(); Rectangle().fill(cyberRed.opacity(0.8)).frame(height: 2) }
                .ignoresSafeArea()

            GeometryReader { geo in
                if geo.size.height > geo.size.width {
                    // upright (iPhone Duo): title on top, the options under it, PLAY at the bottom under the thumbs
                    VStack(alignment: .leading, spacing: 12) {
                        titleBlock
                        scroller {
                            VStack(alignment: .leading, spacing: 14) { optionRows }
                                .padding(.vertical, 8).padding(.horizontal, 2)
                        }
                        noteText
                        padHint
                        playButton
                        updateSection
                    }
                    .frame(width: 304)
                    .padding(.vertical, 20)
                    .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    HStack(alignment: .center, spacing: 40) {
                        VStack(alignment: .leading, spacing: 6) {
                            titleBlock
                            noteText.padding(.top, 14)
                            padHint
                        }
                        scroller {
                        VStack(alignment: .leading, spacing: 14) {
                            optionRows
                            playButton.padding(.top, 4)
                            updateSection
                        }
                        .padding(.vertical, 16).padding(.horizontal, 2)
                        }
                        .frame(width: 304)           // never narrower than the 300 pt rows (+ their outline)
                    }
                    .padding(.horizontal, 24)
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .accessibilityHidden(model.askRestore || model.askUpdate)
            if model.askRestore { restorePanel }
            if model.askUpdate { updatePanel }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            model.sync(); model.checkData()
            model.act = { f, k, rep in padAct(f, k, rep) }
            model.restore = { restoreDefaults() }
            model.startPad()
        }
        .onChange(of: appleFrameGen) { on in
            // frame generation on: smooth pacing would see the made-up frames and drop to 30 - off once, can be turned on again
            guard on, smoothPacing else { return }
            smoothPacing = false
            UserDefaults.standard.set(true, forKey: "CyPortFGWasOn")      // the shim won't turn it off a second time at Play
        }
        .fullScreenCover(isPresented: $model.updating, onDismiss: { GameData.reset(); model.checkData() }) {
            let r = model.gameRoot ?? URL(fileURLWithPath: NSTemporaryDirectory())
            StoreView(model: StoreModel(downloadRoot: r, internalRoot: r, bookmarkKey: "", updateRoot: r))
        }
        .fileImporter(isPresented: $model.importing, allowedContentTypes: [.folder], allowsMultipleSelection: true) { model.importSaves($0) }
        .sheet(isPresented: $model.signingIn) {
            LoginSheet(store: model.source.store) { model.signedInNow() }
        }
        .persistentSystemOverlays(.hidden)
        .statusBarHidden(true)
    }
}

private final class LauncherHostingController: UIHostingController<LauncherView> {
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { MacShimAllowUpright() != 0 ? .allButUpsideDown : .landscape }
}
@_silgen_name("MacShimAllowUpright") private func MacShimAllowUpright() -> Int32   // shim/MacShim.m: an iPhone Duo

@objc(MSSwiftLauncher) public final class MSSwiftLauncher: NSObject {
    /// the game folder in use (set by the shim before make): the data version check and Update Cyberpunk work on it
    @objc public static var gameRoot = ""
    /// resolutions/notes indexed like the shim's display modes (smallest first); onPlay(resolutionIndex, overlay)
    @objc public static func make(resolutions: [String], notes: [String], current: Int, overlay: Int,
                                  onPlay: @escaping (Int, Int) -> Void) -> UIViewController {
        let model = LauncherModel(resolutions: resolutions, notes: notes,
                                  resolution: max(0, min(current, resolutions.count - 1)), overlay: max(0, min(overlay, 2)), onPlay: onPlay)
        let vc = LauncherHostingController(rootView: LauncherView(model: model))
        vc.view.backgroundColor = .black
        return vc
    }
}
