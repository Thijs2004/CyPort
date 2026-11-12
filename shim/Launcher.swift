// Launcher.swift - the start screen (SwiftUI). Resolution + performance overlay + PLAY.
// Everything else is set in the game's own Settings menu. The shim (MacShim.m) creates it through
// MSSwiftLauncher.make(...) and gets the choices back in the onPlay callback.
import SwiftUI
import UIKit

private let cyberYellow = Color(red: 0.99, green: 0.93, blue: 0.04)

private let cyberRed = Color(red: 1.0, green: 0.0, blue: 0.24)

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
            } else {
                Button { model.updating = true } label: {
                    Label("Game files & version", systemImage: "checkmark.seal").font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .disabled(model.starting || model.gameRoot == nil)
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
    }

    /// a 300 pt wide boxed row like the Resolution button; the switch keeps its own size so it is never pushed off the edge
    private func switchRow(_ title: String, icon: String, isOn: Binding<Bool>, note: String) -> some View {
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
            Text(note)
                .font(.caption).foregroundStyle(.white.opacity(0.45))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 300, alignment: .leading)
        }
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
    @ViewBuilder private var optionRows: some View {
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
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Performance overlay", systemImage: "speedometer")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.7))
                        Picker("Performance overlay", selection: $model.overlay) {
                            Text("Off").tag(0); Text("FPS").tag(1); Text("Detailed").tag(2)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 300)
                    }

                    switchRow("Smooth frame pacing", icon: "waveform.path", isOn: $smoothPacing,
                              note: smoothPacing ? "Even frame times: holds 120, 60, 40 or 30 FPS, whatever the phone keeps up with." : "Off: the game's own frame cap only.")
                    switchRow("Smooth controls", icon: "hand.tap", isOn: $gameThread,
                              note: gameThread ? "The game runs on its own thread: touch and controller input don't wait for the game's frames." : "Off: the old way (controls follow the game's frame rate). Try this if the game won't start.")
                    switchRow("Low-latency input", icon: "bolt.horizontal", isOn: $lowLatency,
                              note: lowLatency ? "Snappier controls. Costs a few FPS when the GPU is the limit." : "Off: best frame rate.")
                    switchRow("Controller vibration", icon: "gamecontroller", isOn: $vibration,
                              note: vibration ? "Rumble on controllers that have it." : "Off: no rumble.")
                    switchRow("Adaptive triggers", icon: "l2.button.roundedtop.horizontal", isOn: $adaptiveTriggers,
                              note: adaptiveTriggers ? "PS5 controller trigger resistance." : "Off: PS5 triggers stay loose.")
                    switchRow("Touch + mouse with controller", icon: "computermouse", isOn: $kbmWithController,
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
                        Text(lookMode == 2 ? "Right side is a floating stick: hold to keep turning. Same feel at any frame rate." : "Swipe the right side: the camera follows your finger's speed.")
                            .font(.caption).foregroundStyle(.white.opacity(0.5)).frame(width: 300, alignment: .leading)
                    }
                    switchRow("Touch vibration", icon: "hand.tap", isOn: $touchHaptics,
                              note: touchHaptics ? "A short tap on each on-screen button press." : "Off: on-screen buttons are silent.")

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

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Cloud saves", systemImage: "icloud")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.7))
                        Picker("Store", selection: Binding(get: { model.source }, set: { model.setSource($0) })) {
                            ForEach(CloudSource.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented).frame(width: 300).disabled(model.syncing)
                        HStack {
                            if model.syncing { ProgressView().controlSize(.small) }
                            Text(model.cloudStatus ?? (model.cloudOn ? "Signed in\(model.source.account.map { " as \($0)" } ?? "")"
                                                                     : "Sign in to get your \(model.source.rawValue) saves (optional)"))
                                .font(.caption).foregroundStyle(model.cloudFailed ? cyberRed : .white.opacity(0.75)).lineLimit(3)
                            Spacer()
                            if model.cloudOn {
                                Button("Sync now") { model.sync() }
                                    .font(.caption.weight(.semibold)).foregroundStyle(cyberYellow).disabled(model.syncing)
                            } else {
                                Button("Sign in…") { model.signingIn = true }
                                    .font(.caption.weight(.semibold)).foregroundStyle(cyberYellow)
                            }
                        }
                        .frame(width: 300)
                        if model.cloudOn && !model.syncing {
                            HStack {
                                Text("Syncs both ways with \(model.source.rawValue) - your PC and Mac get your phone saves")
                                    .font(.caption2).foregroundStyle(.white.opacity(0.45))
                                Spacer()
                                Button("Sign out") { model.signOut() }.font(.caption2).foregroundStyle(.white.opacity(0.5))
                            }
                            .frame(width: 300)
                        }
                        HStack(alignment: .top) {
                            Text(model.importStatus ?? "Have saves from a Mac or PC? Copy the save folders to Files, then import them.")
                                .font(.caption2).foregroundStyle(.white.opacity(0.45))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("Import saves…") { model.importing = true }
                                .font(.caption.weight(.semibold)).foregroundStyle(cyberYellow).disabled(model.syncing || model.starting)
                        }
                        .frame(width: 300)
                    }

    }
    private var playButton: some View {
        Button {
                        guard !model.starting, !model.syncing else { return }
                        if model.dataNeedsUpdate { model.askUpdate = true; return }
                        model.starting = true
                        GameCloud.startWatching()
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        model.onPlay(model.resolution, model.overlay)
                    } label: {
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
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 14) { optionRows }
                                .padding(.vertical, 8).padding(.horizontal, 2)
                        }
                        noteText
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
                        }
                        ScrollView(.vertical, showsIndicators: false) {
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
        }
        .preferredColorScheme(.dark)
        .onAppear { model.sync(); model.checkData() }
        .fullScreenCover(isPresented: $model.updating, onDismiss: { GameData.reset(); model.checkData() }) {
            let r = model.gameRoot ?? URL(fileURLWithPath: NSTemporaryDirectory())
            StoreView(model: StoreModel(downloadRoot: r, internalRoot: r, bookmarkKey: "", updateRoot: r))
        }
        .alert("Game data doesn't match", isPresented: $model.askUpdate) {
            Button("Update Cyberpunk") { model.updating = true }
            Button("Play anyway", role: .destructive) {
                model.starting = true; GameCloud.startWatching(); model.onPlay(model.resolution, model.overlay)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(dataText ?? "")
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
