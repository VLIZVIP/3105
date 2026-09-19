import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var language
    @EnvironmentObject private var appState: AppState
    @AppStorage(AppLanguage.storageKey) private var languageCode = AppLanguage.english.rawValue
    @AppStorage(AppAppearanceKeys.accent) private var accentCode = AppAccentChoice.neonBlue.rawValue
    @AppStorage(AppAppearanceKeys.font) private var fontCode = AppFontChoice.system.rawValue
    @AppStorage(AppAppearanceKeys.background) private var backgroundCode = AppBackgroundChoice.neonNight.rawValue

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 14) {
                        AnimatedBrandGIF()
                            .frame(height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 24, style: .continuous)
                                    .stroke(AppTheme.accent.opacity(0.55), lineWidth: 1)
                            )
                            .shadow(color: AppTheme.neonBlue.opacity(0.45), radius: 18)
                            .shadow(color: AppTheme.neonGreen.opacity(0.25), radius: 30)

                        VStack(spacing: 3) {
                            Text("INJECT IOS")
                                .font(.title2.bold())
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [AppTheme.neonBlue, AppTheme.neonGreen, AppTheme.neonRed],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                            Text(language.text("common.version", appVersion))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section(language.text("settings.language")) {
                    Picker(language.text("settings.language"), selection: $languageCode) {
                        ForEach(AppLanguage.allCases) { option in
                            Text(option.displayName).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Section {
                    Picker(language.text("appearance.accent"), selection: $accentCode) {
                        ForEach(AppAccentChoice.allCases) { option in
                            Text("\(option.marker)  \(language.text(option.titleKey))")
                                .tag(option.rawValue)
                        }
                    }

                    Picker(language.text("appearance.font"), selection: $fontCode) {
                        ForEach(AppFontChoice.allCases) { option in
                            Text(language.text(option.titleKey)).tag(option.rawValue)
                        }
                    }

                    Picker(language.text("appearance.background"), selection: $backgroundCode) {
                        ForEach(AppBackgroundChoice.allCases) { option in
                            Text(language.text(option.titleKey)).tag(option.rawValue)
                        }
                    }
                } header: {
                    Text(language.text("appearance.title"))
                } footer: {
                    Text(language.text("appearance.footer"))
                }

                Section(language.text("common.device")) {
                    LabeledContent(language.text("dashboard.hardware_model"), value: AppInfo.displayMachineName)
                    LabeledContent(language.text("settings.ios_version"), value: "\(AppInfo.osVersion) (\(AppInfo.osBuild))")
                }

                Section {
                    HStack {
                        Text(language.text("settings.current_version"))
                        Spacer()
                        Text(language.text(appState.isSupported ? "settings.supported" : "settings.unsupported"))
                        .foregroundStyle(appState.isSupported ? Color.green : Color.red)
                    }
                    LabeledContent("iOS 17", value: ExploitSupportPolicy.verifiedIOS17Range)
                    LabeledContent("iOS 18", value: ExploitSupportPolicy.verifiedIOS18Range)
                    LabeledContent("iOS 26", value: ExploitSupportPolicy.verifiedIOS26Range)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("iOS 27.0")
                            .font(.body)
                        ForEach(ExploitSupportPolicy.verifiedIOS27Builds, id: \.build) { version in
                            Text(versionLabel(version))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text(language.text("settings.verified_versions"))
                } footer: {
                    Text(language.text("settings.supported_versions_footer"))
                }

                Section(language.text("settings.social_media")) {
                    creditsRow(
                        name: "Discord VLIZ_VIP",
                        role: language.text("social.discord_role"),
                        url: "https://discord.gg/8fd7c3kR4r"
                    )
                }

                Section(language.text("settings.credits")) {
                    creditsRow(
                        name: "VLIZ_VIP",
                        role: language.text("credit.vliz_vip"),
                        url: "https://guns.lol/vliz.vip"
                    )
                    creditsRow(
                        name: "Sádico",
                        role: language.text("credit.sadico_tester"),
                        url: "https://www.instagram.com/sadico_qm/"
                    )
                    creditsRow(
                        name: "Donsito",
                        role: language.text("credit.sadico_tester"),
                        url: "https://www.instagram.com/dxntsito.ex3/"
                    )
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppTheme.pageBackground)
            .tint(AppTheme.accent)
            .navigationTitle(language.text("settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(language.text("common.done")) { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "AppReleaseDisplayVersion") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "1.0"
    }

    private func versionLabel(
        _ version: (beta: Int, publicBeta: Int?, build: String)
    ) -> String {
        if let publicBeta = version.publicBeta {
            return language.text(
                "settings.developer_public_beta_build",
                Int64(version.beta),
                Int64(publicBeta),
                version.build
            )
        }
        return language.text(
            "settings.developer_beta_build",
            Int64(version.beta),
            version.build
        )
    }

    @ViewBuilder
    private func creditsRow(name: String, role: String, url: String) -> some View {
        if let destination = URL(string: url) {
            Link(destination: destination) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(role)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(AppTheme.accent)
                        .frame(width: 28, height: 28)
                }
                .contentShape(Rectangle())
            }
            .accessibilityLabel(language.text("accessibility.open_profile", name))
        }
    }
}
