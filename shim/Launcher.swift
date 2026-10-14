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
    let onPlay: (Int, Int) -> Void
    init(resolutions: [String], notes: [String], resolution: Int, overlay: Int, onPlay: @escaping (Int, Int) -> Void) {
        self.resolutions = resolutions; self.notes = notes; self.resolution = resolution; self.overlay = overlay; self.onPlay = onPlay
    }
}

private struct LauncherView: View {
    @ObservedObject var model: LauncherModel

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

                VStack(alignment: .leading, spacing: 18) {
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

                    Button {
                        guard !model.starting else { return }
                        model.starting = true
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
                    .disabled(model.starting)
                    .padding(.top, 4)
                }
            }
            .padding(.horizontal, 24)
        }
        .preferredColorScheme(.dark)
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
