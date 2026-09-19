import SwiftUI

struct ZentryLoginView: View {
    @ObservedObject var auth: ZentryAuthState
    @Environment(\.appLanguage) private var language
    @FocusState private var licenseFocused: Bool

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.black,
                    AppTheme.pageBackground,
                    AppTheme.neonBlue.opacity(0.30),
                    AppTheme.neonRed.opacity(0.18),
                    AppTheme.neonGreen.opacity(0.18)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                AppLogo(size: 92)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(7)
                            .background(AppTheme.neonGreen, in: Circle())
                    }
                    .shadow(color: AppTheme.neonBlue.opacity(0.65), radius: 18)
                    .shadow(color: AppTheme.neonGreen.opacity(0.45), radius: 34)
                    .shadow(color: AppTheme.neonRed.opacity(0.30), radius: 50)

                VStack(spacing: 8) {
                    Text(language.text("login.title"))
                        .font(.largeTitle.bold())
                        .foregroundStyle(
                            LinearGradient(
                                colors: [AppTheme.neonBlue, AppTheme.neonGreen, AppTheme.neonRed],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                    Text(language.text("login.subtitle"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if auth.phase == .checking {
                    ProgressView(language.text("login.checking"))
                        .tint(AppTheme.accent)
                } else {
                    VStack(spacing: 14) {
                        SecureField(language.text("login.license"), text: $auth.license)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .textContentType(.password)
                            .submitLabel(.go)
                            .focused($licenseFocused)
                            .onSubmit { Task { await auth.activate() } }
                            .padding(14)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))

                        if let error = auth.errorMessage {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .multilineTextAlignment(.center)
                        }

                        Button {
                            Task { await auth.activate() }
                        } label: {
                            HStack {
                                if auth.phase == .authenticating {
                                    ProgressView().tint(.white)
                                }
                                Text(language.text(auth.phase == .authenticating ? "login.validating" : "login.sign_in"))
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.accent)
                        .disabled(auth.license.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || auth.phase == .authenticating)

                        Button(language.text("login.retry")) {
                            Task { await auth.restoreSession() }
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .disabled(auth.phase == .authenticating)
                    }
                    .frame(maxWidth: 430)
                }

                Spacer()

                Text(language.text("login.device_binding"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(28)
            .foregroundStyle(.white)
        }
        .onAppear {
            if auth.phase == .locked { licenseFocused = true }
        }
    }
}
