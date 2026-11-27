import SwiftUI
import UIKit
import AVKit
import AVFoundation

@main
struct ThreeOneOSFiveApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var patchDraftCoordinator = PatchDraftCoordinator()
    @StateObject private var fileOperationCoordinator = FileOperationCoordinator()
    @StateObject private var patchStore = PatchProjectStore()
    @StateObject private var repositoryStore = PackageRepositoryStore()
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.english.rawValue
    @State private var showOnboarding = OnboardingStore.shouldShow()
    @State private var showAttribution = false
    @State private var showSplash = true
    @State private var updateOffer: AppUpdateChecker.Offer?
    @StateObject private var license = BaypassLicense.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var remote = RemoteControl.shared

    init() {
        setupLogCapture()
        log("app: MATINO X launching — iOS \(AppInfo.osVersion) (\(AppInfo.osBuild)) \(AppInfo.machineName)")
    }

    private var language: AppLanguage {
        AppLanguage(rawValue: languageCode) ?? .english
    }

    private func checkForUpdate() {
        Task {
            guard let offer = await AppUpdateChecker.check() else { return }
            await MainActor.run { updateOffer = offer }
        }
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                ContentView()
                    .environmentObject(appState)
                    .environmentObject(patchDraftCoordinator)
                    .environmentObject(fileOperationCoordinator)
                    .environmentObject(patchStore)
                    .environmentObject(repositoryStore)
                    .environment(\.appLanguage, language)
                    .environment(\.locale, language.locale)
                    .opacity(showOnboarding || !license.isActivated ? 0 : 1)
                    .allowsHitTesting(!showOnboarding && license.isActivated)

                if showOnboarding && license.isActivated {
                    OnboardingView {
                        OnboardingStore.markCompleted()
                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
                            showOnboarding = false
                        }
                        appState.detectSupport()
                        checkForUpdate()
                    }
                    .environment(\.appLanguage, language)
                    .environment(\.locale, language.locale)
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.98))
                    )
                    .zIndex(1)
                }

                if !license.isActivated {
                    BaypassActivationView()
                        .zIndex(2)
                }

                if showSplash {
                    SplashView()
                        .zIndex(3)
                        .allowsHitTesting(false)
                }

                if remote.alertMessage != nil || remote.lockedMessage != nil {
                    RemoteMessageCard(
                        title: remote.lockedMessage != nil ? "UPDATE REQUIRED" : "MATINO X",
                        message: remote.lockedMessage ?? remote.alertMessage ?? "",
                        isLock: remote.lockedMessage != nil,
                        onDismiss: { remote.alertMessage = nil }
                    )
                    .zIndex(4)
                }



            }
            .preferredColorScheme(.dark)
            .displayIdentityAttribution(isPresented: $showAttribution, enabled: !showOnboarding && license.isActivated)
            .sheet(isPresented: $showAttribution) {
                DisplayAttributionSheet()
            }
            .alert(item: $updateOffer) { offer in
                Alert(
                    title: Text(language.text("update.title")),
                    message: Text(language.text("update.message", offer.version)),
                    primaryButton: .default(Text(language.text("update.agree"))) {
                        UIApplication.shared.open(offer.url)
                    },
                    secondaryButton: .cancel(Text(language.text("update.dismiss"))) {
                        AppUpdateChecker.dismiss(version: offer.version)
                    }
                )
            }
            .onAppear {
                license.revalidateStoredKey()
                remote.check()
                if !showOnboarding && license.isActivated {
                    appState.detectSupport()
                    checkForUpdate()
                }
            }
            .onChange(of: scenePhase) { phase in
                guard phase == .active, !showOnboarding, license.isActivated else { return }
                appState.detectSupport()
                // A key moved to another device must be revoked when we return
                // to the foreground, not only once at launch.
                license.revalidateStoredKey()
                remote.check()
            }
            .onOpenURL { url in
                patchDraftCoordinator.presentImport(url)
            }
        }
    }
}

class AppState: ObservableObject {
    @Published var exploitStatus: ExploitStatus = .notStarted
    @Published var unsupportedMessage: String?
    @Published var kernelExploitRunning = false

    private var autoRunAttempted = false

    var kernelExploitApplicable: Bool {
        KernelExploit.isApplicable(
            major: AppInfo.versionTuple.major,
            minor: AppInfo.versionTuple.minor,
            patch: AppInfo.versionTuple.patch,
            build: AppInfo.osBuild
        )
    }

    var isSupported: Bool { unsupportedMessage == nil }

    func detectSupport() {
        let v = AppInfo.versionTuple
        let supported = ExploitSupportPolicy.isSupported(
            major: v.major,
            minor: v.minor,
            patch: v.patch,
            build: AppInfo.osBuild
        )
#if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--simulate-access") {
            exploitStatus = .success(method: "Simulator preview")
        }
#endif

        unsupportedMessage = supported ? nil : "iOS \(AppInfo.osVersion) (\(AppInfo.osBuild))"
        if let unsupportedMessage {
            exploitStatus = .unsupported(unsupportedMessage)
            return
        }

        let applicable = KernelExploit.isApplicable(
            major: v.major,
            minor: v.minor,
            patch: v.patch,
            build: AppInfo.osBuild
        )
        guard applicable else { return }

        refreshKernelExploitStatus()
        maybeAutoRunKernelExploit()
    }

    private func maybeAutoRunKernelExploit() {
        guard !kernelExploitRunning,
              !exploitStatus.isSuccess,
              !exploitStatus.isFailed,
              !autoRunAttempted else { return }
        autoRunAttempted = true
        log("app: starting kernel exploit automatically")
        runKernelExploitIfNeeded()
    }

    private func refreshKernelExploitStatus() {
        guard !kernelExploitRunning else { return }

        // iOS < 26: kernel R/W success persists (no sandbox probe)
        // iOS >= 26: verify full sandbox escape is still active
        if KernelExploit.requiresSandboxEscape {
            if KernelExploit.hasSandboxAccess() {
                if !exploitStatus.isSuccess {
                    exploitStatus = .success(method: "kexploit")
                    log("app: existing sandbox access is still active; skipping kernel exploit")
                }
            } else if exploitStatus.isSuccess {
                exploitStatus = .notStarted
                log("app: sandbox access is no longer active")
            }
        }
    }

    func runKernelExploitIfNeeded() {
        refreshKernelExploitStatus()
        guard !kernelExploitRunning,
              !exploitStatus.isSuccess,
              !exploitStatus.isFailed else { return }
        kernelExploitRunning = true
        exploitStatus = .notStarted
        log("app: running kernel exploit on background...")
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = KernelExploit.run()
            DispatchQueue.main.async {
                self.kernelExploitRunning = false
                if ok {
                    self.exploitStatus = .success(method: "kexploit")
                    if KernelExploit.requiresSandboxEscape {
                        log("app: kernel exploit success — sandbox access verified")
                    } else {
                        log("app: kernel exploit success — kernel access active")
                    }
                } else {
                    self.exploitStatus = .failed(method: "kexploit", code: -1)
                    log("app: kernel exploit failed — relaunch the app before retrying")
                }
            }
        }
    }
}

/// MATINO X: launch splash - video at native size (no stretch/crop), screen blend.
struct SplashView: View {
    @State private var player: AVPlayer?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.clear.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .blendMode(.screen)
                    .opacity(0.6)
                    .onAppear {
                        player.play()
                    }
            }
        }
        .onAppear {
            if player == nil,
               let url = EmbeddedMedia.url(EmbeddedMedia.snow, filename: "snow_overlay.mp4") {
                let p = AVPlayer(url: url)
                p.isMuted = true
                p.actionAtItemEnd = .none
                self.player = p
                NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: p.currentItem,
                    queue: .main
                ) { _ in
                    p.seek(to: .zero)
                    p.play()
                }
                p.play()
            }
        }
        // Resume when returning from background - video must keep playing.
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                player?.play()
            }
        }
    }
}

// MATINO X: animated strip shown across all tabs (AIM/HOLOGRAM/SKIN/Settings).



// MARK: - Remote control from the secure console (build lock + owner message)

struct RemoteCommand: Codable {
    let activeBuildID: String?
    let targetBuildID: String?
    let message: String?
    let messageID: String?
    let sound: String?
    let disabled: Bool?
    let updateMessage: String?
}

final class RemoteControl: ObservableObject {
    static let shared = RemoteControl()

    @Published var alertMessage: String?
    @Published var lockedMessage: String?

    private let controlURL = URL(string:
        "https://raw.githubusercontent.com/nari2122mh-design/matino-x/main/BundledFiles/app_control.json")!
    private let lastMessageKey = "matino.remote.lastMessageID"
    private let commandCacheKey = "matino.remote.command"

    /// Unique id of this IPA, written into the bundle by the build workflow.
    var buildID: String {
        if let url = Bundle.main.url(forResource: "build_id", withExtension: "txt"),
           let text = try? String(contentsOf: url).trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty { return text }
        return Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }

    func check() {
        var request = URLRequest(url: controlURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 12
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self else { return }
            if let data,
               let command = try? JSONDecoder().decode(RemoteCommand.self, from: data) {
                // Cache the last command so deleting it from the site does
                // not hide it from the device.
                UserDefaults.standard.set(data, forKey: self.commandCacheKey)
                DispatchQueue.main.async { self.apply(command) }
            } else if let cached = UserDefaults.standard.data(forKey: self.commandCacheKey),
                      let command = try? JSONDecoder().decode(RemoteCommand.self, from: cached) {
                DispatchQueue.main.async { self.apply(command) }
            }
        }.resume()
    }

    private func apply(_ command: RemoteCommand) {
        if command.disabled == true {
            BaypassLicense.shared.deactivate()
            return
        }
        if let active = command.activeBuildID, !active.isEmpty, active != buildID {
            let custom = (command.updateMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            lockedMessage = custom.isEmpty
                ? "You must update MATINO X to the latest version."
                : custom
            BaypassLicense.shared.deactivate()
            return
        }
        if let target = command.targetBuildID, !target.isEmpty, target != buildID { return }
        if command.message != nil, (command.targetBuildID ?? "").isEmpty { return }
        if let message = command.message, !message.isEmpty {
            let id = command.messageID ?? message
            if UserDefaults.standard.string(forKey: lastMessageKey) != id {
                UserDefaults.standard.set(id, forKey: lastMessageKey)
                alertMessage = message
                playSound(command.sound)
            }
        }
    }

    var lockedBinding: Binding<Bool> {
        Binding(get: { self.lockedMessage != nil }, set: { if !$0 { self.lockedMessage = nil } })
    }

    var messageBinding: Binding<Bool> {
        Binding(get: { self.alertMessage != nil }, set: { if !$0 { self.alertMessage = nil } })
    }

    private func playSound(_ name: String?) {
        let parts: [String]?
        switch name {
        case "tap": parts = EmbeddedMedia.tap
        case "applied": parts = EmbeddedMedia.applied
        case "restored": parts = EmbeddedMedia.restored
        default: parts = nil
        }
        guard let parts, let url = EmbeddedMedia.url(parts, filename: (name ?? "tap") + ".m4a") else { return }
        let player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        player?.play()
    }
}



// MARK: - Remote message card (persistent, custom design)

struct RemoteMessageCard: View {
    @Environment(\.openURL) private var openURL
    let title: String
    let message: String
    let isLock: Bool
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        ZStack {
            Color.black.opacity(0.72)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.black)
                        .frame(width: 62, height: 62)
                    Image(systemName: isLock ? "arrow.up.circle.fill" : "bell.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                }
                .padding(.top, 24)

                Text(title)
                    .font(.system(size: 21, weight: .heavy))
                    .tracking(0.6)
                    .padding(.top, 18)

                Text(message)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.top, 10)
                    .padding(.bottom, 22)

                Divider()
                    .background(Color.white.opacity(0.12))

                if isLock {
                    Text("INSTALL THE LATEST IPA TO CONTINUE")
                        .font(.caption2.weight(.bold))
                        .tracking(0.5)
                        .foregroundStyle(.orange)
                        .padding(.vertical, 17)
                } else {
                    VStack(spacing: 10) {
                        Button {
                            if let link = URL(string: "https://t.me/DYNASTY_212") {
                                openURL(link)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "paperplane.fill")
                                Text("OWNER TELEGRAM  @DYNASTY_212")
                            }
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color(white: 0.12))
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)

                        Button(action: { onDismiss?() }) {
                            Text("OK")
                                .font(.system(size: 16, weight: .bold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 46)
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
            .frame(maxWidth: 350)
            .background(AppTheme.consoleBackground)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.6), radius: 30, y: 10)
            .padding(.horizontal, 28)
        }
    }
}
