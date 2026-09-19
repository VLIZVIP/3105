import SwiftUI
import UIKit

@main
struct InjectIOSApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var authState = ZentryAuthState()
    @StateObject private var patchDraftCoordinator = PatchDraftCoordinator()
    @StateObject private var fileOperationCoordinator = FileOperationCoordinator()
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.english.rawValue
    @AppStorage(AppAppearanceKeys.font) private var fontCode = AppFontChoice.system.rawValue
    @AppStorage(AppAppearanceKeys.background) private var backgroundCode = AppBackgroundChoice.neonNight.rawValue
    @State private var showOnboarding = OnboardingStore.shouldShow()
    @State private var showAttribution = false
    @State private var updateOffer: AppUpdateChecker.Offer?
    @Environment(\.scenePhase) private var scenePhase

    init() {
        if let storedLanguage = UserDefaults.standard.string(forKey: AppLanguage.storageKey),
           AppLanguage(rawValue: storedLanguage) == nil {
            UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: AppLanguage.storageKey)
        }
        setupLogCapture()
        log("app: INJECT IOS launching — iOS \(AppInfo.osVersion) (\(AppInfo.osBuild)) \(AppInfo.machineName)")
    }

    private var language: AppLanguage {
        AppLanguage(rawValue: languageCode) ?? .english
    }

    private var fontChoice: AppFontChoice {
        AppFontChoice(rawValue: fontCode) ?? .system
    }

    private var backgroundChoice: AppBackgroundChoice {
        AppBackgroundChoice(rawValue: backgroundCode) ?? .neonNight
    }

    private func checkForUpdate() {
        Task {
            guard let offer = await AppUpdateChecker.check() else { return }
            await MainActor.run { updateOffer = offer }
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if authState.isAuthenticated {
                    ZStack {
                        ContentView()
                            .environmentObject(appState)
                            .environmentObject(patchDraftCoordinator)
                            .environmentObject(fileOperationCoordinator)
                            .environment(\.appLanguage, language)
                            .environment(\.locale, language.locale)
                            .opacity(showOnboarding ? 0 : 1)
                            .allowsHitTesting(!showOnboarding)

                        if showOnboarding {
                            OnboardingView {
                                OnboardingStore.markCompleted()
                                withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                                    showOnboarding = false
                                }
                                appState.detectSupport()
                                checkForUpdate()
                            }
                            .environment(\.appLanguage, language)
                            .environment(\.locale, language.locale)
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                            .zIndex(1)
                        }
                    }
                } else {
                    ZentryLoginView(auth: authState)
                }
            }
            .environment(\.appLanguage, language)
            .environment(\.locale, language.locale)
            .font(.system(.body, design: fontChoice.design))
            .preferredColorScheme(backgroundChoice.preferredColorScheme)
            .tint(AppTheme.accent)
            .displayIdentityAttribution(
                isPresented: $showAttribution,
                enabled: authState.isAuthenticated && !showOnboarding
            )
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
            .task {
                if authState.phase == .checking {
                    await authState.restoreSession()
                }
            }
            .onChange(of: authState.phase) { phase in
                if phase == .authenticated, !showOnboarding {
                    appState.detectSupport()
                    checkForUpdate()
                } else if phase == .locked {
                    updateOffer = nil
                    showAttribution = false
                }
            }
            .onChange(of: scenePhase) { phase in
                guard phase == .active else { return }
                Task {
                    await authState.validateForegroundSession()
                    guard authState.isAuthenticated, !showOnboarding else { return }
                    appState.detectSupport()
                }
            }
            .onOpenURL { url in
                guard authState.isAuthenticated else { return }
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
