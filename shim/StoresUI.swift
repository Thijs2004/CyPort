// The store screens: sign in to Steam / GOG / Epic, check the account owns Cyberpunk 2077, download the Mac game
// data onto the iPhone or into a folder (e.g. on the SSD). Opened from the first-run screen (MSSetupVC in MacShim.m)
// via MSStoreUI.make(...). The logic is in StoresCore.swift.
import SwiftUI
import UIKit
import WebKit
import UniformTypeIdentifiers

@objc(MSStoreUI)
final class MSStoreUI: NSObject {
    /// downloadRoot: where a download to the iPhone goes until it is complete; internalRoot: where the game is then
    /// moved (the folder the app plays from); bookmarkKey: the user-defaults key of the "play from this folder" choice.
    @MainActor @objc static func make(downloadRoot: String, internalRoot: String, bookmarkKey: String) -> UIViewController {
        let m = StoreModel(downloadRoot: URL(fileURLWithPath: downloadRoot), internalRoot: URL(fileURLWithPath: internalRoot), bookmarkKey: bookmarkKey)
        let vc = UIHostingController(rootView: StoreView(model: m))
        vc.view.backgroundColor = .black
        vc.modalPresentationStyle = .fullScreen
        return vc
    }
}

enum StoreKind: String, CaseIterable, Identifiable {
    case steam = "Steam", gog = "GOG", epic = "Epic Games"
    var id: String { rawValue }
    var signedIn: Bool {
        switch self { case .steam: return SteamStore.shared.signedIn; case .gog: return GOGStore.shared.signedIn; case .epic: return EpicStore.shared.signedIn }
    }
    var account: String? {
        switch self { case .steam: return SteamStore.shared.account; case .gog: return GOGStore.shared.account; case .epic: return EpicStore.shared.account }
    }
    func signOut() {
        switch self { case .steam: SteamStore.shared.signOut(); case .gog: GOGStore.shared.signOut(); case .epic: EpicStore.shared.signOut() }
    }
}

@MainActor
final class StoreModel: ObservableObject {
    enum Phase { case choose, preparing(String), ready, downloading, done(String), failed(String) }
    enum Destination: Equatable { case phone, folder(URL) }
    let downloadRoot: URL, internalRoot: URL, bookmarkKey: String
    @Published var phase: Phase = .choose
    @Published var store: StoreKind?
    @Published var refresh = 0                                 // bumps after sign-in/out
    @Published var gogBuilds: [GOGStore.Build] = []
    @Published var gogBuild: GOGStore.Build?
    @Published var destination: Destination = .phone
    @Published var plan: DLPlan?
    @Published var progress: Downloader.Progress?
    @Published var needBytes: Int64 = 0
    @Published var freeBytes: Int64 = 0
    private var task: Task<Void, Never>?

    init(downloadRoot: URL, internalRoot: URL, bookmarkKey: String) {
        self.downloadRoot = downloadRoot; self.internalRoot = internalRoot; self.bookmarkKey = bookmarkKey
        // a download into a folder that didn't finish: offer to continue there
        if let bm = UserDefaults.standard.data(forKey: "CyPortDownloadFolder") {
            var stale = false
            if let u = try? URL(resolvingBookmarkData: bm, bookmarkDataIsStale: &stale), u.startAccessingSecurityScopedResource() { destination = .folder(u) }
        }
    }
    var gameFolder: URL {
        switch destination { case .phone: return downloadRoot; case .folder(let u): return u.appendingPathComponent("Cyberpunk 2077", isDirectory: true) }
    }
    var resuming: Bool { FileManager.default.fileExists(atPath: gameFolder.appendingPathComponent(".cyport-download.json").path) }

    func prepare(_ s: StoreKind) {
        store = s; plan = nil
        phase = .preparing("Checking your \(s.rawValue) library…")
        task = Task {
            do {
                let say: (String) -> Void = { m in Task { @MainActor in self.phase = .preparing(m) } }
                let p: DLPlan
                switch s {
                case .steam: p = try await SteamStore.shared.plan(progress: say)
                case .gog:
                    if gogBuilds.isEmpty { gogBuilds = try await GOGStore.shared.builds(); gogBuild = GOGStore.preferred(gogBuilds) }
                    guard let b = gogBuild else { throw StoreError("GOG lists no Mac version of the game.") }
                    p = try await GOGStore.shared.plan(build: b, progress: say)
                case .epic: p = try await EpicStore.shared.plan(progress: say)
                }
                plan = p
                updateSpace()
                phase = .ready
                storeLog("\(s.rawValue): ready, \(p.files.count) files, \(p.totalBytes / 1_000_000) MB, \(p.versionName) (\(p.version))")
            } catch is CancellationError { phase = .choose }
            catch { phase = .failed(error.localizedDescription); storeLog("\(s.rawValue): \(error.localizedDescription)") }
        }
    }
    func updateSpace() {
        guard let p = plan else { return }
        needBytes = Downloader(plan: p, dest: gameFolder).remainingBytes()
        var dir = gameFolder
        while !FileManager.default.fileExists(atPath: dir.path) && dir.pathComponents.count > 1 { dir.deleteLastPathComponent() }
        let v = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        freeBytes = Int64(v?.volumeAvailableCapacityForImportantUsage ?? Int64(v?.volumeAvailableCapacity ?? 0))
        if freeBytes == 0, let n = v?.volumeAvailableCapacity { freeBytes = Int64(n) }
    }
    func setFolder(_ u: URL) {
        _ = u.startAccessingSecurityScopedResource()
        if let bm = try? u.bookmarkData() { UserDefaults.standard.set(bm, forKey: "CyPortDownloadFolder") }
        destination = .folder(u); updateSpace()
    }
    func usePhone() { UserDefaults.standard.removeObject(forKey: "CyPortDownloadFolder"); destination = .phone; updateSpace() }

    func start() {
        guard let p = plan else { return }
        phase = .downloading; progress = nil
        UIApplication.shared.isIdleTimerDisabled = true
        let dest = gameFolder
        var bg = UIBackgroundTaskIdentifier.invalid
        bg = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(bg) }
        task = Task {
            defer { UIApplication.shared.isIdleTimerDisabled = false; UIApplication.shared.endBackgroundTask(bg) }
            do {
                let d = Downloader(plan: p, dest: dest)
                try await d.run { pr in Task { @MainActor in self.progress = pr } }
                try finish(dest)
            } catch is CancellationError { phase = .ready; updateSpace() }
            catch { phase = .failed(error.localizedDescription + "\n\nTap Download again to continue where it stopped."); storeLog("download stopped: \(error.localizedDescription)") }
        }
    }
    func cancel() { task?.cancel() }
    private func finish(_ dest: URL) throws {
        let fm = FileManager.default
        switch destination {
        case .phone:
            if fm.fileExists(atPath: internalRoot.path) { try fm.removeItem(at: internalRoot) }
            try fm.moveItem(at: dest, to: internalRoot)
            try? "ok\n".write(to: internalRoot.appendingPathComponent(".copy-complete"), atomically: true, encoding: .utf8)
            phase = .done("Cyberpunk 2077 is on this iPhone. Open the app again to play.")
        case .folder:
            let bm = try dest.bookmarkData()
            UserDefaults.standard.set(bm, forKey: bookmarkKey)
            UserDefaults.standard.removeObject(forKey: "CyPortDownloadFolder")
            phase = .done("Cyberpunk 2077 is in the folder you picked. Keep that drive plugged in and open the app again to play.")
        }
        storeLog("download installed (\(destination == .phone ? "iPhone" : "folder"))")
    }
}

// MARK: - views

struct StoreView: View {
    @ObservedObject var model: StoreModel
    @Environment(\.dismiss) private var dismiss
    @State private var login: StoreKind?
    @State private var pickFolder = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("Get the game from your store").font(.title2.bold()).foregroundColor(.white)
                        Spacer()
                        if case .downloading = model.phase {} else { Button("Close") { model.cancel(); dismiss() }.foregroundColor(.yellow) }
                    }
                    Text("Sign in to the store where you bought Cyberpunk 2077. CyPort downloads the Mac version's game data (about 90 GB with Phantom Liberty). Your app already contains the game program, built from your Mac copy (version \(Game.appVersion)).")
                        .font(.subheadline).foregroundColor(.gray)
                    content
                }
                .padding(24).frame(maxWidth: 720).frame(maxWidth: .infinity)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(item: $login) { s in
            LoginSheet(store: s) { login = nil; model.refresh += 1 }
        }
        .sheet(isPresented: $pickFolder) {
            FolderPicker { u in pickFolder = false; if let u { model.setFolder(u) } }
        }
    }

    @ViewBuilder var content: some View {
        switch model.phase {
        case .choose: storeList
        case .preparing(let m): HStack(spacing: 12) { ProgressView(); Text(m).foregroundColor(.white) }
        case .failed(let m):
            Text(m).foregroundColor(.orange)
            HStack { Button("Back") { model.phase = .choose }; if model.plan != nil { Button("Download") { model.start() }.bold() } }
        case .ready: readyView
        case .downloading: downloadingView
        case .done(let m):
            Text("Done").font(.title.bold()).foregroundColor(.green)
            Text(m).foregroundColor(.white)
            Button("Close the app") { exit(0) }.buttonStyle(.borderedProminent).tint(.yellow).foregroundColor(.black)
        }
    }

    var storeList: some View {
        VStack(spacing: 12) {
            let _ = model.refresh
            ForEach(StoreKind.allCases) { s in
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(s.rawValue).font(.headline).foregroundColor(.white)
                        Text(s.signedIn ? "Signed in\(s.account.map { " as \($0)" } ?? "")" : "Not signed in").font(.caption).foregroundColor(.gray)
                    }
                    Spacer()
                    if s.signedIn {
                        Button("Sign out") { s.signOut(); model.refresh += 1 }.font(.caption).foregroundColor(.gray)
                        Button("Download") { model.prepare(s) }.buttonStyle(.borderedProminent).tint(.yellow).foregroundColor(.black)
                    } else {
                        Button("Sign in") { login = s }.buttonStyle(.bordered).tint(.yellow)
                    }
                }
                .padding(14).background(Color.white.opacity(0.07)).cornerRadius(12)
            }
        }
    }

    var readyView: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let p = model.plan, let s = model.store {
                Text("\(s.rawValue): Cyberpunk 2077 for Mac").font(.headline).foregroundColor(.white)
                if s == .gog, model.gogBuilds.count > 1 {
                    Picker("Version", selection: Binding(get: { model.gogBuild?.id ?? "" }, set: { id in
                        model.gogBuild = model.gogBuilds.first { $0.id == id }; model.prepare(.gog) })) {
                        ForEach(model.gogBuilds, id: \.id) { b in Text("\(b.version) (\(b.date))").tag(b.id) }
                    }.pickerStyle(.menu).tint(.yellow)
                }
                Text("Version: \(p.versionName) · \(p.files.count) files · \(gb(p.totalBytes))")
                    .foregroundColor(.white)
                versionNote(s, p)
                Divider().background(Color.gray)
                Text("Save to").font(.subheadline.bold()).foregroundColor(.white)
                HStack {
                    Button { model.usePhone() } label: { Label("This iPhone", systemImage: model.destination == .phone ? "largecircle.fill.circle" : "circle") }
                    Button { pickFolder = true } label: {
                        if case .folder(let u) = model.destination { Label(u.lastPathComponent, systemImage: "largecircle.fill.circle") }
                        else { Label("A folder (SSD)…", systemImage: "circle") }
                    }
                }.tint(.yellow)
                Text("\(model.resuming ? "Continues the earlier download · " : "")Needs \(gb(model.needBytes)) · \(gb(model.freeBytes)) free")
                    .font(.caption).foregroundColor(model.needBytes > model.freeBytes ? .orange : .gray)
                Text("Keep the app open while it downloads (the screen stays on). If it stops, it continues from where it was.")
                    .font(.caption).foregroundColor(.gray)
                HStack {
                    Button("Back") { model.phase = .choose }
                    Spacer()
                    Button(model.resuming ? "Continue download" : "Download") { model.start() }
                        .buttonStyle(.borderedProminent).tint(.yellow).foregroundColor(.black)
                        .disabled(model.needBytes > model.freeBytes)
                }
            }
        }
    }

    @ViewBuilder func versionNote(_ s: StoreKind, _ p: DLPlan) -> some View {
        let digits = Game.versionDigits(p.versionName)
        if s == .steam {
            Text("Steam always has its newest version. If it's newer than \(Game.appVersion), the game may not start: then rebuild CyPort from an up-to-date Mac copy.")
                .font(.caption).foregroundColor(.orange)
        } else if digits != Game.versionDigits(Game.appVersion) {
            Text("This is not the same version as your app (\(Game.appVersion)). The game data and the game program must match: pick the matching version, or rebuild CyPort from the same version.")
                .font(.caption).foregroundColor(.orange)
        }
    }

    var downloadingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Downloading from \(model.store?.rawValue ?? "")…").font(.headline).foregroundColor(.white)
            let pr = model.progress
            ProgressView(value: Double(pr?.done ?? 0), total: Double(max(pr?.total ?? 1, 1))).tint(.yellow)
            if let pr {
                Text("\(gb(pr.done, 2)) of \(gb(pr.total)) · \(String(format: "%.1f", pr.bytesPerSecond / 1e6)) MB/s · \(timeLeft(pr.secondsLeft))")
                    .font(.caption.monospacedDigit()).foregroundColor(.white)
                Text(pr.file).font(.caption2).foregroundColor(.gray).lineLimit(1)
            } else { Text("Starting…").font(.caption).foregroundColor(.gray) }
            Button("Pause") { model.cancel() }.foregroundColor(.yellow)
        }
    }
    func gb(_ b: Int64, _ decimals: Int = 1) -> String { String(format: "%.\(decimals)f GB", Double(b) / 1e9) }
    func timeLeft(_ s: Double) -> String {
        guard s > 0, s.isFinite else { return "…" }
        let t = Int(s)
        return t >= 3600 ? "\(t / 3600) h \(t % 3600 / 60) min left" : t >= 60 ? "\(t / 60) min \(t % 60) s left" : "\(t) s left"
    }
}

// MARK: - sign-in sheets

struct LoginSheet: View {
    let store: StoreKind
    let done: () -> Void
    var body: some View {
        NavigationView {
            Group {
                switch store {
                case .steam: SteamLoginView(done: done)
                case .gog: WebLoginView(url: GOGStore.loginURL, store: .gog, done: done)
                case .epic: WebLoginView(url: EpicStore.loginURL, store: .epic, done: done)
                }
            }
            .navigationTitle("Sign in to \(store.rawValue)").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { done() } } }
        }
        .navigationViewStyle(.stack).preferredColorScheme(.dark)
    }
}

struct SteamLoginView: View {
    let done: () -> Void
    @State private var account = ""
    @State private var password = ""
    @State private var code = ""
    @State private var pending: SteamStore.PendingLogin?
    @State private var busy = false
    @State private var message: String?
    @State private var poller: Task<Void, Never>?

    var body: some View {
        Form {
            if pending == nil {
                Section(footer: Text("Your password goes to Steam only (encrypted with Steam's key) and is not stored. CyPort keeps Steam's sign-in token in the iPhone's Keychain.")) {
                    TextField("Steam account name", text: $account).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Password", text: $password)
                    Button(busy ? "Signing in…" : "Sign in") { begin() }.disabled(busy || account.isEmpty || password.isEmpty)
                }
            } else if let p = pending {
                Section(header: Text("Steam Guard")) {
                    if p.guards.contains(where: { if case .deviceConfirmation = $0 { return true }; return false }) {
                        Label("Approve this sign-in in the Steam app on your phone, or enter a code below.", systemImage: "iphone")
                    }
                    if let e = p.guards.compactMap({ if case .emailCode(let d) = $0 { return d }; return nil }).first {
                        Text("Enter the code Steam sent to \(e).")
                    } else if p.guards.contains(where: { if case .deviceCode = $0 { return true }; return false }) {
                        Text("Enter the code from the Steam app (Steam Guard).")
                    }
                    TextField("Code", text: $code).textInputAutocapitalization(.characters).autocorrectionDisabled()
                    Button(busy ? "Checking…" : "Submit code") { submit() }.disabled(busy || code.count < 5)
                }
            }
            if let message { Section { Text(message).foregroundColor(.orange) } }
        }
        .onDisappear { poller?.cancel() }
    }
    private func begin() {
        busy = true; message = nil
        Task {
            do {
                let p = try await SteamStore.shared.beginLogin(account: account, password: password)
                password = ""
                pending = p
                startPolling(p)
            } catch { message = error.localizedDescription }
            busy = false
        }
    }
    private func startPolling(_ p: SteamStore.PendingLogin) {
        poller?.cancel()
        // a little time in the background (approving in the Steam app); after that iOS suspends the app and the poll
        // reconnects when it comes back
        var bg = UIBackgroundTaskIdentifier.invalid
        bg = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(bg); bg = .invalid }
        poller = Task {
            defer { if bg != .invalid { UIApplication.shared.endBackgroundTask(bg) } }
            var failures = 0
            while !Task.isCancelled {
                do {
                    if try await SteamStore.shared.poll(p) { done(); return }
                    failures = 0; message = nil
                } catch let e as SteamResult {
                    // Steam ended the sign-in (denied, expired): start over
                    message = e.code == 9 || e.code == 27 ? "The sign-in was denied or expired. Sign in again." : e.localizedDescription
                    pending = nil; return
                } catch {
                    failures += 1
                    message = "Reconnecting to Steam…"
                    if failures >= 5 { message = error.localizedDescription; pending = nil; return }
                }
                try? await Task.sleep(nanoseconds: UInt64(max(p.interval, 2) * 1e9))
            }
        }
    }
    private func submit() {
        guard let p = pending else { return }
        busy = true; message = nil
        let email = p.guards.contains { if case .emailCode = $0 { return true }; return false }
        Task {
            do { try await SteamStore.shared.submitCode(p, code: code, email: email) }
            catch { message = error.localizedDescription }
            busy = false
        }
    }
}

struct WebLoginView: View {
    let url: URL
    let store: StoreKind
    let done: () -> Void
    @State private var message: String?
    @State private var pasted = ""
    @State private var busy = false
    var body: some View {
        VStack(spacing: 0) {
            if busy { ProgressView("Signing in…").padding() }
            if let message { Text(message).foregroundColor(.orange).padding(8) }
            WebView(url: url, store: store) { code in finish(code) }
            if store == .epic {
                // Epic sometimes refuses embedded sign-in pages: sign in in Safari instead and paste the code
                HStack {
                    TextField("…or paste the authorizationCode from Safari", text: $pasted).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Open in Safari") { UIApplication.shared.open(EpicStore.loginURL) }
                    Button("Use") { if let c = EpicStore.code(fromPage: pasted) { finish(c) } else { message = "That isn't an Epic authorization code." } }
                }.padding(10).font(.caption)
            }
        }
    }
    private func finish(_ code: String) {
        guard !busy else { return }
        busy = true
        Task {
            do {
                if store == .gog { try await GOGStore.shared.signIn(code: code) } else { try await EpicStore.shared.signIn(code: code) }
                done()
            } catch { message = error.localizedDescription; busy = false }
        }
    }
}

struct WebView: UIViewRepresentable {
    let url: URL
    let store: StoreKind
    let onCode: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> WKWebView {
        let w = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        w.navigationDelegate = context.coordinator
        w.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
        w.load(URLRequest(url: url))
        return w
    }
    func updateUIView(_ v: WKWebView, context: Context) {}
    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: WebView; var sent = false
        init(_ p: WebView) { parent = p }
        func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if parent.store == .gog, let u = a.request.url, let c = GOGStore.code(from: u) { decisionHandler(.cancel); send(c); return }
            decisionHandler(.allow)
        }
        func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
            guard parent.store == .epic, let u = w.url, EpicStore.isRedirect(u) else { return }
            w.evaluateJavaScript("document.body.innerText") { r, _ in
                if let s = r as? String, let c = EpicStore.code(fromPage: s) { self.send(c) }
            }
        }
        private func send(_ c: String) { guard !sent else { return }; sent = true; parent.onCode(c) }
    }
}

struct FolderPicker: UIViewControllerRepresentable {
    let done: (URL?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(done) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let p = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder])
        p.delegate = context.coordinator; p.allowsMultipleSelection = false
        return p
    }
    func updateUIViewController(_ v: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let done: (URL?) -> Void
        init(_ d: @escaping (URL?) -> Void) { done = d }
        func documentPicker(_ c: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { done(urls.first) }
        func documentPickerWasCancelled(_ c: UIDocumentPickerViewController) { done(nil) }
    }
}
