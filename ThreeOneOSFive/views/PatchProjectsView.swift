import CryptoKit
import Foundation
import SwiftUI

private struct RemotePatchCatalogResponse: Decodable {
    let patches: [RemotePatchItem]
}

private struct RemotePatchItem: Decodable, Identifiable {
    let id: String
    let name: String
    let description: String
    let version: String
    let size: Int64
    let updatedAt: String
    let downloadURL: String
    let sha256: String

    private enum CodingKeys: String, CodingKey {
        case id, name, description, version, size, updatedAt, sha256
        case downloadURL = "downloadUrl"
    }
}

private struct RemotePatchAlert: Identifiable {
    let id = UUID()
    let titleKey: String
    let messageKey: String
}

private struct RemotePatchPasswordRequest: Identifiable {
    let id = UUID()
    let catalogID: String
    let patchName: String
}

@MainActor
private final class RemotePatchCatalogStore: ObservableObject {
    @Published private(set) var items: [RemotePatchItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var applyingID: String?
    @Published private(set) var installedRevision = 0
    @Published var alert: RemotePatchAlert?
    @Published var passwordRequest: RemotePatchPasswordRequest?
    @Published private(set) var passwordErrorKey: String?

    private var protectedPackageData: Data?
    private var protectedPackageSummary: PatchPackageSummary?
    private var protectedCatalogItem: RemotePatchItem?
    private var unlockedItems: [String: PatchLibraryItem] = [:]

    private static let maximumPackageBytes = 250 * 1_024 * 1_024

    var isApplying: Bool { applyingID != nil }

    func refresh() {
        guard !isLoading else { return }
        guard let catalogURL = Self.catalogURL else {
            alert = RemotePatchAlert(
                titleKey: "common.failed",
                messageKey: "patch.catalog.unavailable"
            )
            return
        }

        isLoading = true
        Task {
            do {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 30
                configuration.timeoutIntervalForResource = 60
                let session = URLSession(configuration: configuration)
                defer { session.invalidateAndCancel() }
                let (data, response) = try await session.data(from: catalogURL)
                guard let response = response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode),
                      response.url?.scheme?.lowercased() == "https",
                      response.url?.host?.lowercased() == catalogURL.host?.lowercased(),
                      data.count <= 2 * 1_024 * 1_024 else {
                    throw PatchPackageError.remoteImportFailed
                }
                let decoded = try JSONDecoder().decode(RemotePatchCatalogResponse.self, from: data)
                items = decoded.patches.sorted {
                    $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
                isLoading = false
            } catch {
                isLoading = false
                alert = RemotePatchAlert(
                    titleKey: "common.failed",
                    messageKey: "patch.catalog.load_failed"
                )
            }
        }
    }

    func installedProjectID(for item: RemotePatchItem) -> UUID? {
        if let unlocked = unlockedItems[item.id] { return unlocked.id }
        guard let raw = UserDefaults.standard.string(forKey: "inject.remote.patch.\(item.id)"),
              let id = UUID(uuidString: raw),
              PatchProjectLibrary.load().contains(where: { $0.id == id && $0.project != nil }) else {
            return nil
        }
        return id
    }

    func unlockedLibraryItem(for item: RemotePatchItem) -> PatchLibraryItem? {
        unlockedItems[item.id]
    }

    func download(_ item: RemotePatchItem) {
        guard !isApplying else { return }
        guard let baseURL = Self.baseURL,
              let downloadURL = Self.validatedDownloadURL(item.downloadURL, baseURL: baseURL) else {
            alert = RemotePatchAlert(
                titleKey: "common.failed",
                messageKey: "patch.catalog.invalid"
            )
            return
        }

        applyingID = item.id
        Task {
            do {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 600
                let session = URLSession(configuration: configuration)
                defer { session.invalidateAndCancel() }
                let (data, response) = try await session.data(from: downloadURL)
                guard let response = response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode),
                      response.url?.scheme?.lowercased() == "https",
                      response.url?.host?.lowercased() == baseURL.host?.lowercased(),
                      data.count <= Self.maximumPackageBytes,
                      Int64(data.count) == item.size,
                      Self.sha256(data) == item.sha256.lowercased() else {
                    throw CatalogApplyError.invalidPackage
                }

                let summary = try PatchPackageCodec.inspect(data)
                if summary.isPasswordProtected {
                    protectedPackageData = data
                    protectedPackageSummary = summary
                    protectedCatalogItem = item
                    passwordErrorKey = nil
                    applyingID = nil
                    passwordRequest = RemotePatchPasswordRequest(catalogID: item.id, patchName: item.name)
                    return
                }
                let libraryItem = try await install(data: data, summary: summary, password: nil)
                finishSuccess(item: item, libraryItem: libraryItem)
            } catch {
                applyingID = nil
                alert = RemotePatchAlert(
                    titleKey: "common.failed",
                    messageKey: "patch.catalog.invalid"
                )
            }
        }
    }

    func applyProtectedPatch(password: String) {
        guard applyingID == nil,
              !password.isEmpty,
              let data = protectedPackageData,
              let summary = protectedPackageSummary,
              let item = protectedCatalogItem else { return }
        passwordErrorKey = nil
        applyingID = summary.packageID.uuidString
        Task {
            do {
                let libraryItem = try await install(data: data, summary: summary, password: password)
                passwordRequest = nil
                clearProtectedPackage()
                finishSuccess(item: item, libraryItem: libraryItem)
            } catch PatchPackageError.invalidPasswordOrCorruptedPackage {
                applyingID = nil
                passwordErrorKey = "patch.catalog.password_incorrect"
            } catch {
                applyingID = nil
                passwordErrorKey = "patch.catalog.invalid"
            }
        }
    }

    func cancelPasswordRequest() {
        passwordRequest = nil
        clearProtectedPackage()
        applyingID = nil
    }

    func clearPasswordError() {
        passwordErrorKey = nil
    }

    private func install(
        data: Data,
        summary: PatchPackageSummary,
        password: String?
    ) async throws -> PatchLibraryItem {
        try await Task.detached(priority: .userInitiated) {
            let decoded = try PatchPackageCodec.decode(data, password: password)
            let existingURL = PatchProjectLibrary.load()
                .first(where: { $0.id == summary.packageID })?
                .packageURL
            if summary.isPasswordProtected {
                try PatchKeyStore.store(decoded.contentKey, for: summary)
            }
            do {
                let packageURL = try PatchProjectLibrary.installImportedPackage(
                    data: data,
                    decoded: decoded,
                    summary: summary,
                    existingURL: existingURL
                )
                return PatchLibraryItem(
                    summary: summary,
                    project: decoded.project,
                    contentKey: decoded.contentKey,
                    packageURL: packageURL
                )
            } catch {
                if summary.isPasswordProtected {
                    try? PatchKeyStore.delete(for: summary)
                }
                throw error
            }
        }.value
    }

    private func finishSuccess(item: RemotePatchItem, libraryItem: PatchLibraryItem) {
        unlockedItems[item.id] = libraryItem
        UserDefaults.standard.set(libraryItem.id.uuidString, forKey: "inject.remote.patch.\(item.id)")
        installedRevision += 1
        applyingID = nil
        alert = RemotePatchAlert(
            titleKey: "common.done",
            messageKey: "patch.catalog.downloaded"
        )
    }

    private func clearProtectedPackage() {
        protectedPackageData = nil
        protectedPackageSummary = nil
        protectedCatalogItem = nil
        passwordErrorKey = nil
    }

    private enum CatalogApplyError: Error {
        case invalidPackage
    }

    private static var baseURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "PatchCatalogBaseURL") as? String,
              let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              url.host != nil else { return nil }
        return url
    }

    private static var catalogURL: URL? {
        baseURL?.appendingPathComponent("api/patches")
    }

    private static func validatedDownloadURL(_ raw: String, baseURL: URL) -> URL? {
        let url = URL(string: raw, relativeTo: baseURL)?.absoluteURL
        guard url?.scheme?.lowercased() == "https",
              url?.host?.lowercased() == baseURL.host?.lowercased() else { return nil }
        return url
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct PatchProjectsView: View {
    @Environment(\.appLanguage) private var language
    @StateObject private var store = RemotePatchCatalogStore()
    @StateObject private var libraryStore = PatchProjectStore()
    @State private var searchText = ""
    @State private var pendingPatch: RemotePatchItem?

    private var filteredItems: [RemotePatchItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.items }
        return store.items.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.description.localizedCaseInsensitiveContains(query)
                || $0.version.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                AppSearchField(
                    text: $searchText,
                    prompt: language.text("patch.search"),
                    clearLabel: language.text("common.clear")
                )
                Divider()
                List {
                    if store.isLoading && store.items.isEmpty {
                        loadingState.listRowSeparator(.hidden)
                    } else if store.items.isEmpty {
                        emptyState.listRowSeparator(.hidden)
                    } else if filteredItems.isEmpty {
                        searchEmptyState.listRowSeparator(.hidden)
                    } else {
                        Section(language.text("patch.catalog.available")) {
                            ForEach(filteredItems) { item in
                                remoteRow(item)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(AppTheme.pageBackground)
            }
            .navigationTitle(language.text("patch.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: store.refresh) {
                        if store.isLoading { ProgressView() }
                        else { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(store.isLoading || store.isApplying)
                    .accessibilityLabel(language.text("patch.catalog.refresh"))
                }
            }
            .confirmationDialog(
                language.text("patch.catalog.use_confirm_title"),
                isPresented: Binding(
                    get: { pendingPatch != nil },
                    set: { if !$0 { pendingPatch = nil } }
                ),
                titleVisibility: .visible
            ) {
                if let pendingPatch {
                    Button(language.text("patch.catalog.use")) {
                        store.download(pendingPatch)
                        self.pendingPatch = nil
                    }
                }
                Button(language.text("common.cancel"), role: .cancel) {
                    pendingPatch = nil
                }
            } message: {
                Text(language.text("patch.catalog.use_confirm_message"))
            }
            .alert(item: $store.alert) { alert in
                Alert(
                    title: Text(language.text(alert.titleKey)),
                    message: Text(language.text(alert.messageKey)),
                    dismissButton: .default(Text(language.text("common.ok")))
                )
            }
            .sheet(item: $store.passwordRequest) { request in
                RemotePatchPasswordView(store: store, request: request)
            }
            .task {
                if store.items.isEmpty { store.refresh() }
            }
            .onChange(of: store.installedRevision) { _ in
                store.items.forEach { remote in
                    if let unlocked = store.unlockedLibraryItem(for: remote) {
                        libraryStore.adoptUnlockedItem(unlocked)
                    }
                }
                libraryStore.reload()
                store.items.forEach { remote in
                    if let unlocked = store.unlockedLibraryItem(for: remote) {
                        libraryStore.adoptUnlockedItem(unlocked)
                    }
                }
            }
        }
        .background(AppTheme.pageBackground.ignoresSafeArea())
    }

    private func remoteRow(_ item: RemotePatchItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                AppRowIcon(systemName: "shippingbox.fill")
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name).font(.headline)
                    if !item.description.isEmpty {
                        Text(item.description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 6)
            }

            HStack(spacing: 10) {
                Label(language.text("patch.catalog.version", item.version), systemImage: "tag")
                Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let projectID = store.installedProjectID(for: item) {
                NavigationLink {
                    PatchProjectDetailView(
                        store: libraryStore,
                        projectID: projectID,
                        remoteMetadata: item
                    )
                } label: {
                    HStack {
                        Image(systemName: "arrow.right.circle.fill")
                        Text(language.text("patch.catalog.open"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    pendingPatch = item
                } label: {
                    HStack {
                        if store.applyingID == item.id {
                            ProgressView()
                            Text(language.text("patch.catalog.downloading"))
                        } else {
                            Image(systemName: "icloud.and.arrow.down.fill")
                            Text(language.text("patch.catalog.use"))
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isApplying)
            }
        }
        .padding(.vertical, 6)
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(language.text("patch.catalog.downloading"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: AppTheme.emptyIconSize, weight: .light))
                .foregroundStyle(AppTheme.accent)
            Text(language.text("patch.catalog.empty_title")).font(.headline)
            Text(language.text("patch.catalog.empty_message"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(language.text("patch.catalog.refresh"), action: store.refresh)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
    }

    private var searchEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: AppTheme.emptyIconSize, weight: .light))
                .foregroundStyle(.secondary)
            Text(language.text("patch.search_empty")).font(.headline)
            Text(language.text("patch.search_empty_message"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
    }
}

private struct PatchProjectDetailView: View {
    @Environment(\.appLanguage) private var language
    @ObservedObject var store: PatchProjectStore
    let projectID: UUID
    let remoteMetadata: RemotePatchItem
    @State private var showEditor = false
    @State private var editingRule: PatchRule?
    @State private var showApplyConfirmation = false
    @State private var showRestoreConfirmation = false
    @State private var isWorking = false
    @State private var actionAlert: PatchStoreAlert?

    private var item: PatchLibraryItem? {
        store.items.first(where: { $0.id == projectID })
    }

    private var receipt: PatchTransactionReceipt? {
        DevicePatchService.latestReceipt(projectID: projectID)
    }

    private var isWorkspaceProject: Bool {
        (item?.summary.schemaVersion ?? 1) >= 2
    }

    var body: some View {
        List {
            if let item, let project = item.project {
                Section {
                    LabeledContent(language.text("patch.catalog.name"), value: remoteMetadata.name)
                    LabeledContent(language.text("patch.catalog.version_label"), value: remoteMetadata.version)
                    if !remoteMetadata.description.isEmpty {
                        Text(remoteMetadata.description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent(
                        language.text("patch.catalog.file_size"),
                        value: ByteCountFormatter.string(fromByteCount: remoteMetadata.size, countStyle: .file)
                    )
                } header: {
                    Text(language.text("patch.catalog.download_info"))
                }

                if isWorkspaceProject {
                    Section {
                        ForEach(project.allBundleIdentifiers, id: \.self) { bundleID in
                            Label {
                                Text(bundleID).font(.subheadline.monospaced())
                            } icon: {
                                Image(systemName: "app.dashed").foregroundStyle(AppTheme.accent)
                            }
                        }
                        LabeledContent(language.text("patch.files")) { Text("\(project.rules.count)") }
                        LabeledContent(language.text("patch.folders")) { Text("\(project.directories.count)") }
                        if let workspaceURL = item.workspaceURL {
                            NavigationLink {
                                FileBrowserView(
                                    containerPath: workspaceURL.path,
                                    title: project.name,
                                    bundleID: nil
                                )
                            } label: {
                                Label(language.text("patch.open_workspace"), systemImage: "folder")
                            }
                        }
                    } header: {
                        Text(language.text("patch.workspace"))
                    } footer: {
                        Text(language.text("patch.workspace_detail_footer"))
                    }
                } else {
                    Section {
                        ForEach(project.rules) { rule in
                            Button {
                                editingRule = rule
                            } label: {
                                HStack(spacing: 10) {
                                    ruleSummary(rule)
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint(language.text("patch.edit_rule_hint"))
                        }
                    } header: {
                        Text(language.text("patch.rules"))
                    } footer: {
                        Text(language.text("patch.legacy_footer"))
                    }
                }

                Section(language.text("patch.password")) {
                    HStack(spacing: 12) {
                        Image(systemName: item.summary.isPasswordProtected ? "lock.fill" : "lock.open")
                            .foregroundStyle(AppTheme.accent)
                            .frame(width: 24)
                        Text(language.text(item.summary.isPasswordProtected
                            ? "patch.password_locked"
                            : "patch.no_password"))
                            .font(.subheadline)
                    }
                }

                Section {
                    Button { showApplyConfirmation = true } label: {
                        actionLabel("patch.apply", systemImage: "checkmark.shield.fill")
                    }
                    .disabled(isWorking)

                    if receipt != nil {
                        Button(role: .destructive) { showRestoreConfirmation = true } label: {
                            actionLabel("patch.restore", systemImage: "arrow.uturn.backward.circle")
                        }
                        .disabled(isWorking)
                    }

                } footer: {
                    Text(language.text("patch.apply_footer"))
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(remoteMetadata.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if isWorking {
                    ProgressView()
                } else if !isWorkspaceProject {
                    Button(language.text("patch.edit")) { showEditor = true }
                        .disabled(item?.project == nil)
                }
            }
        }
        .sheet(isPresented: $showEditor) {
            if let item, let project = item.project {
                PatchProjectEditorView(
                    existingProject: project,
                    passwordIsProtected: item.summary.isPasswordProtected
                ) { updatedProject, _ in
                    store.update(project: updatedProject)
                }
            }
        }
        .sheet(item: $editingRule) { rule in
            PatchRuleEditorView(rule: rule) { updatedRule in updateRule(updatedRule) }
        }
        .confirmationDialog(
            language.text("patch.apply_confirm_title"),
            isPresented: $showApplyConfirmation,
            titleVisibility: .visible
        ) {
            Button(language.text("patch.apply")) { apply() }
            Button(language.text("common.cancel"), role: .cancel) {}
        } message: {
            Text(language.text("patch.apply_confirm_message"))
        }
        .confirmationDialog(
            language.text("patch.restore_confirm_title"),
            isPresented: $showRestoreConfirmation,
            titleVisibility: .visible
        ) {
            Button(language.text("patch.restore"), role: .destructive) { restore() }
            Button(language.text("common.cancel"), role: .cancel) {}
        }
        .alert(item: $actionAlert) { alert in
            Alert(
                title: Text(language.text(alert.titleKey)),
                message: Text(alert.message(language: language)),
                dismissButton: .default(Text(language.text("common.ok")))
            )
        }
    }

    private func actionLabel(_ key: String, systemImage: String) -> some View {
        Label(language.text(key), systemImage: systemImage)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func ruleSummary(_ rule: PatchRule) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(rule.bundleID).font(.subheadline.weight(.semibold))
            Text(rule.relativePath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Label(rule.replacementFilename, systemImage: "arrow.triangle.2.circlepath")
                .font(.caption)
                .foregroundStyle(AppTheme.accent)
        }
        .padding(.vertical, 3)
    }

    private func updateRule(_ updatedRule: PatchRule) {
        guard var project = item?.project,
              let index = project.rules.firstIndex(where: { $0.id == updatedRule.id }) else { return }
        project.rules[index] = updatedRule
        project.updatedAt = Date()
        do {
            try PatchPackageCodec.validate(project)
            store.update(project: project)
        } catch let error as PatchPackageError {
            actionAlert = PatchStoreAlert(
                titleKey: "common.failed",
                messageKey: error.localizationKey,
                messageArgument: error.localizationArgument
            )
        } catch {
            actionAlert = PatchStoreAlert(titleKey: "common.failed", messageKey: "patch.error.invalid_project")
        }
    }

    private func apply() {
        guard let item, let baseProject = item.project else { return }
        isWorking = true
        Task.detached(priority: .userInitiated) {
            do {
                let project = item.summary.schemaVersion >= 2
                    ? try PatchProjectLibrary.synchronizeWorkspace(item: item)
                    : baseProject
                _ = try DevicePatchService.apply(project: project)
                await MainActor.run {
                    store.reload()
                    isWorking = false
                    actionAlert = PatchStoreAlert(titleKey: "common.done", messageKey: "patch.applied_message")
                }
            } catch let error as PatchPackageError {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(
                        titleKey: "common.failed",
                        messageKey: error.localizationKey,
                        messageArgument: error.localizationArgument
                    )
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(titleKey: "common.failed", messageKey: "patch.error.apply")
                }
            }
        }
    }

    private func restore() {
        guard let receipt else { return }
        isWorking = true
        Task.detached(priority: .userInitiated) {
            do {
                try DevicePatchService.restore(receipt: receipt)
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(titleKey: "common.done", messageKey: "patch.restored_message")
                }
            } catch let error as PatchPackageError {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(
                        titleKey: "common.failed",
                        messageKey: error.localizationKey,
                        messageArgument: error.localizationArgument
                    )
                }
            } catch {
                await MainActor.run {
                    isWorking = false
                    actionAlert = PatchStoreAlert(titleKey: "common.failed", messageKey: "patch.error.restore")
                }
            }
        }
    }
}

private struct RemotePatchPasswordView: View {
    @Environment(\.appLanguage) private var language
    @ObservedObject var store: RemotePatchCatalogStore
    let request: RemotePatchPasswordRequest
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(language.text("patch.catalog.password_prompt"), text: $password)
                        .textContentType(.password)
                        .submitLabel(.done)
                        .onSubmit(apply)
                        .onChange(of: password) { _ in store.clearPasswordError() }
                    if let errorKey = store.passwordErrorKey {
                        Text(language.text(errorKey))
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text(request.patchName)
                } footer: {
                    Text(language.text("patch.catalog.password_message"))
                }
            }
            .navigationTitle(language.text("patch.catalog.password_title"))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(store.isApplying)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(language.text("common.cancel")) { store.cancelPasswordRequest() }
                        .disabled(store.isApplying)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(language.text("patch.catalog.use"), action: apply)
                        .disabled(password.isEmpty || store.isApplying)
                }
            }
            .overlay {
                if store.isApplying {
                    ProgressView(language.text("patch.catalog.downloading"))
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
    }

    private func apply() {
        guard !password.isEmpty else { return }
        store.applyProtectedPatch(password: password)
    }
}
