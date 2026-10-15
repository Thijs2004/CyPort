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
    func signedInNow() { signingIn = false; cloudOn = source.signedIn; if cloudOn { sync() } }
    func signOut() { source.signOut(); cloudOn = false; cloudStatus = nil; cloudFailed = false }
    let onPlay: (Int, Int) -> Void
    init(resolutions: [String], notes: [String], resolution: Int, overlay: Int, onPlay: @escaping (Int, Int) -> Void) {
        self.resolutions = resolutions; self.notes = notes; self.resolution = resolution; self.overlay = overlay; self.onPlay = onPlay
    }
}

private struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    /// swipe-to-look speed, read by the shim when the game starts (MSLookSensitivity)
    @AppStorage("CyPortLookSensitivity") private var lookSensitivity = 1.5

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.black, Color(red: 0.08, green: 0.02, blue: 0.06)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            // thin neon accents
            VStack { Rectangle().fill(cyberYellow).frame(height: 3); Spacer(); Rectangle().fill(cyberRed.opacity(0.8)).frame(height: 2) }
                .ignoresSafeArea()

            HStack(alignment: .center, spacing: 40) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("CYPORT")
                        .font(.system(size: 52, weight: .black, design: .default))
                        .italic()
                        .foregroundStyle(cyberYellow)
                        .shadow(color: cyberRed.opacity(0.6), radius: 0, x: 3, y: 2)
                    Text("RUNS YOUR OWN COPY OF THE GAME")
                        .font(.system(size: 13, weight: .heavy, design: .monospaced))
                        .tracking(3)
                        .foregroundStyle(.white.opacity(0.85))
                    Text("Other graphics settings are in the game's own Settings menu - they're kept between launches.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: 300, alignment: .leading)
                        .padding(.top, 14)
                }

                ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
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
                    }

                    Button {
                        guard !model.starting, !model.syncing else { return }
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
                    .padding(.top, 4)
                }
                .padding(.vertical, 16)
                }
            }
            .padding(.horizontal, 24)
        }
        .preferredColorScheme(.dark)
        .onAppear { model.sync() }
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
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
}

@objc(MSSwiftLauncher) public final class MSSwiftLauncher: NSObject {
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
