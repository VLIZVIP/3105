import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @EnvironmentObject private var patchDraftCoordinator: PatchDraftCoordinator
    @State private var tabNavigation: AppTabNavigationState
    @State private var filesUnlocked = false

    init() {
#if targetEnvironment(simulator)
        let arguments = ProcessInfo.processInfo.arguments
        let initialTab: Int
        if arguments.contains("--simulate-files-tab") {
            initialTab = 1
            _filesUnlocked = State(initialValue: true)
        } else if arguments.contains("--simulate-patch-tab") {
            initialTab = 2
        } else if arguments.contains("--simulate-cleaner-tab") {
            initialTab = 3
        } else if arguments.contains("--simulate-wallpaper-tab") {
            initialTab = 4
        } else {
            initialTab = 0
        }
        _tabNavigation = State(initialValue: AppTabNavigationState(selectedTab: initialTab))
#else
        _tabNavigation = State(initialValue: AppTabNavigationState())
#endif
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                regularLayout
            } else {
                compactLayout
            }
        }
        .tint(AppTheme.accent)
        .imageScale(.small)
        .background(AppTheme.pageBackground.ignoresSafeArea())
        .background(
            ThreeFingerDoubleTapView {
                revealFiles()
            }
        )
        .onChange(of: patchDraftCoordinator.request?.id) { requestID in
            if requestID != nil { tabNavigation.select(AppSection.patches.rawValue) }
        }
        .onChange(of: patchDraftCoordinator.importRequest?.id) { requestID in
            if requestID != nil { tabNavigation.select(AppSection.patches.rawValue) }
        }
        .onAppear {
            tabNavigation.reconcileSelection(with: featureVisibility)
        }
    }

    private var compactLayout: some View {
        TabView(selection: tabSelection) {
            ForEach(featureVisibility.visibleSections) { section in
                sectionContent(section)
                    .tabItem {
                        CompactTabLabel(
                            title: language.text(section.titleKey),
                            systemImage: section.systemImage
                        )
                    }
                    .tag(section.rawValue)
            }
        }
    }

    private var regularLayout: some View {
        NavigationSplitView {
            List {
                ForEach(featureVisibility.visibleSections) { section in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            tabNavigation.select(section.rawValue)
                        }
                    } label: {
                        Label(language.text(section.titleKey), systemImage: section.systemImage)
                            .fontWeight(section.rawValue == tabNavigation.selectedTab ? .semibold : .regular)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        section.rawValue == tabNavigation.selectedTab
                            ? AppTheme.accent.opacity(0.14)
                            : Color.clear
                    )
                    .accessibilityAddTraits(
                        section.rawValue == tabNavigation.selectedTab ? .isSelected : []
                    )
                }
            }
            .navigationTitle("INJECT IOS")
            .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
        } detail: {
            sectionContent(selectedVisibleSection)
                .id(selectedVisibleSection.rawValue)
        }
        .background(AppTheme.pageBackground.ignoresSafeArea())
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private func sectionContent(_ section: AppSection) -> some View {
        switch section {
        case .home:
            DashboardView()
        case .files:
            AppDataBrowserView(
                tabSession: filesTabSession
            )
        case .patches:
            PatchProjectsView()
        case .cleaner:
            CleanerView()
        case .wallpapers:
            WallpaperLabView()
        }
    }

    private var tabSelection: Binding<Int> {
        Binding(
            get: { tabNavigation.selectedTab },
            set: { tabNavigation.select($0) }
        )
    }

    private var filesTabSession: Binding<FilesTabSession> {
        Binding(
            get: { tabNavigation.filesTabs },
            set: { tabNavigation.setFilesTabs($0) }
        )
    }

    private var featureVisibility: FeatureVisibility {
        FeatureVisibility(filesUnlocked: filesUnlocked)
    }

    private var selectedVisibleSection: AppSection {
        guard let section = AppSection(rawValue: tabNavigation.selectedTab),
              featureVisibility.isVisible(section) else {
            return .home
        }
        return section
    }

    private func revealFiles() {
        withAnimation(.easeInOut(duration: 0.18)) {
            filesUnlocked = true
            tabNavigation.select(AppSection.files.rawValue)
        }
    }
}

private struct ThreeFingerDoubleTapView: UIViewRepresentable {
    let onRecognized: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onRecognized: onRecognized)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.isHidden = true
        DispatchQueue.main.async {
            context.coordinator.installIfNeeded(from: view)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onRecognized = onRecognized
        context.coordinator.installIfNeeded(from: uiView)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onRecognized: () -> Void
        private weak var installedWindow: UIWindow?
        private weak var recognizer: UITapGestureRecognizer?

        init(onRecognized: @escaping () -> Void) {
            self.onRecognized = onRecognized
        }

        func installIfNeeded(from hostView: UIView) {
            let sceneWindows = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
            let window = hostView.window
                ?? sceneWindows.first(where: \.isKeyWindow)
                ?? sceneWindows.first

            guard let window else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak hostView] in
                    guard let hostView else { return }
                    self.installIfNeeded(from: hostView)
                }
                return
            }
            guard installedWindow !== window || recognizer == nil else { return }

            if let recognizer, let installedWindow {
                installedWindow.removeGestureRecognizer(recognizer)
            }

            let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleGesture(_:)))
            recognizer.numberOfTapsRequired = 2
            recognizer.numberOfTouchesRequired = 3
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            window.addGestureRecognizer(recognizer)
            installedWindow = window
            self.recognizer = recognizer
        }

        @objc private func handleGesture(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            onRecognized()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

private struct CompactTabLabel: View {
    let title: String
    let systemImage: String

    @ViewBuilder
    var body: some View {
        if let image = UIImage(
            systemName: systemImage,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        )?.withRenderingMode(.alwaysTemplate) {
            Image(uiImage: image)
        } else {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
        }
        Text(title)
    }
}

private extension AppSection {
    var titleKey: String {
        switch self {
        case .home: return "tab.home"
        case .files: return "tab.files"
        case .patches: return "tab.patches"
        case .cleaner: return "tab.cleaner"
        case .wallpapers: return "tab.wallpapers"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house.fill"
        case .files: return "folder.fill"
        case .patches: return "shippingbox.fill"
        case .cleaner: return "sparkles"
        case .wallpapers: return "photo.on.rectangle.angled"
        }
    }
}

private struct DashboardView: View {
    @Environment(\.appLanguage) private var language
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var appState: AppState
    @StateObject private var announcements = CustomerAnnouncements()
    @AppStorage("inject.announcements.lastSeen") private var lastSeenAnnouncement = ""
    @State private var showSettings = false
    @State private var showLogs = false
    @State private var showAnnouncements = false

    var body: some View {
        NavigationStack {
            List {
                if let newest = announcements.items.first {
                    Section("Avisos INJECT IOS") {
                        Button {
                            lastSeenAnnouncement = newest.id
                            showAnnouncements = true
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(newest.title).font(.headline)
                                    if newest.id != lastSeenAnnouncement {
                                        Circle().fill(AppTheme.accent).frame(width: 8, height: 8)
                                    }
                                }
                                Text(newest.body).font(.subheadline).lineLimit(3)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                deviceSection
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.pageBackground)
            .navigationBarTitleDisplayMode(.inline)
            .tint(AppTheme.accent)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        if let newest = announcements.items.first {
                            lastSeenAnnouncement = newest.id
                        }
                        showAnnouncements = true
                    } label: {
                        Image(systemName: announcements.items.first.map { $0.id != lastSeenAnnouncement } == true
                              ? "bell.badge" : "bell")
                    }
                    .accessibilityLabel("Avisos INJECT IOS")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showLogs = true } label: {
                        Image(systemName: "apple.terminal")
                    }
                    .accessibilityLabel(language.text("accessibility.open_logs"))
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel(language.text("accessibility.open_settings"))
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showLogs) { LogView() }
            .sheet(isPresented: $showAnnouncements) {
                NavigationStack {
                    List(announcements.items) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.title).font(.headline)
                            Text(item.body).font(.body)
                            Text(item.createdAt.prefix(10)).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                    .overlay {
                        if announcements.items.isEmpty {
                            VStack(spacing: 10) {
                                Image(systemName: "bell").font(.largeTitle)
                                Text("Sin avisos").font(.headline)
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                    .navigationTitle("Avisos INJECT IOS")
                    .toolbar {
                        Button("Cerrar") { showAnnouncements = false }
                    }
                }
            }
            .task { await announcements.refresh() }
            .onChange(of: scenePhase) { phase in
                if phase == .active { Task { await announcements.refresh() } }
            }
        }
    }

    private var deviceSection: some View {
        Section {
            LabeledContent(language.text("dashboard.hardware_model")) {
                Text(AppInfo.displayMachineName)
                    .font(.body.monospaced())
            }
            LabeledContent(language.text("settings.ios_version")) {
                Text("\(AppInfo.osVersion) (\(AppInfo.osBuild))")
                    .font(.body.monospaced())
            }
            HStack {
                Text(language.text("settings.compatibility"))
                Spacer()
                Text(language.text(appState.isSupported ? "settings.supported" : "settings.unsupported"))
                .foregroundStyle(appState.isSupported ? Color.green : Color.red)
            }

            if appState.kernelExploitApplicable && AppInfo.versionTuple.major < 26 {
                HStack {
                    Text(language.text("dashboard.kernel_status"))
                    Spacer()
                    if appState.kernelExploitRunning {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(language.text("dashboard.kernel_running"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(language.text(appState.exploitStatus.isSuccess ? "dashboard.kernel_active" : "dashboard.kernel_inactive"))
                        .foregroundStyle(appState.exploitStatus.isSuccess ? Color.green : Color.secondary)
                    }
                }
            }
        } header: {
            Text(language.text("common.device"))
        } footer: {
            Text(language.text("settings.supported_range_summary"))
        }
    }
}

private struct CustomerAnnouncement: Decodable, Identifiable {
    let id: String
    let title: String
    let body: String
    let createdAt: String
}

private struct CustomerAnnouncementResponse: Decodable {
    let announcements: [CustomerAnnouncement]
}

@MainActor
private final class CustomerAnnouncements: ObservableObject {
    @Published private(set) var items: [CustomerAnnouncement] = []

    func refresh() async {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "PatchCatalogBaseURL") as? String,
              let baseURL = URL(string: raw), baseURL.scheme == "https",
              baseURL.host != nil else { return }
        let url = baseURL.appendingPathComponent("api/announcements")
        do {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 15
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  http.url?.scheme == "https", http.url?.host == baseURL.host,
                  data.count <= 256 * 1_024 else { return }
            items = try JSONDecoder().decode(CustomerAnnouncementResponse.self, from: data).announcements
        } catch {
            // Keep the last loaded notices if the network is temporarily unavailable.
        }
    }
}
