import Foundation

enum ZentryConfiguration {
    static let baseURL = URL(string: "https://api.zentryauth.com/v1")!
    // This is the version configured in the ZentryAuth application dashboard.
    // It is independent from CFBundleShortVersionString.
    static let apiVersion = "1.0.0"

    static var appKey: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "ZentryAppKey") as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("REPLACE_WITH") else { return nil }
        return trimmed
    }

}

struct ZentryAPIError: LocalizedError {
    let code: String
    let message: String

    var invalidatesSavedSession: Bool {
        ["INVALID_LICENSE", "EXPIRED", "HWID_MISMATCH", "SESSION_INVALID", "TOKEN_INVALID", "REVOKED"].contains(code)
    }

    var errorDescription: String? {
        let language = AppLanguage.current
        switch code {
        case "HWID_MISMATCH":
            return language.text("login.hwid_mismatch")
        case "INVALID_LICENSE":
            return language.text("login.invalid_license")
        case "EXPIRED":
            return language.text("login.expired")
        case "MAINTENANCE":
            return language.text("login.maintenance")
        case "VERSION_BLOCKED":
            return language.text("login.version_blocked")
        case "UPDATE_REQUIRED":
            return language.text("login.update_required")
        case "AUTH_MODE_MISMATCH":
            return language.text("login.auth_mode_mismatch")
        default:
            return message.isEmpty ? "Zentry rechazó la solicitud (\(code))." : message
        }
    }
}

private struct ZentryEnvelope<T: Decodable>: Decodable {
    let success: Bool
    let code: String?
    let message: String?
    let data: T?
}

private struct ZentryErrorEnvelope: Decodable {
    let success: Bool
    let code: String?
    let message: String?
}

private struct ZentryActivationData: Decodable {
    let token: String
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case token
        case expiresAt = "expires_at"
    }
}

private struct ZentryEmptyData: Decodable {}

enum ZentryClient {
    static func activate(license: String, hardwareID: String) async throws -> String {
        let payload: [String: String] = [
            "key": license,
            "hwid": hardwareID,
            "version": ZentryConfiguration.apiVersion
        ]
        let response: ZentryEnvelope<ZentryActivationData> = try await post(
            path: "license/activate",
            payload: payload
        )
        guard let token = response.data?.token, !token.isEmpty else {
            throw ZentryAPIError(code: response.code ?? "INVALID_RESPONSE", message: "Zentry no devolvió una sesión.")
        }
        return token
    }

    static func validate(token: String, hardwareID: String) async throws {
        let payload: [String: String] = [
            "token": token,
            "hwid": hardwareID,
            "version": ZentryConfiguration.apiVersion
        ]
        let _: ZentryEnvelope<ZentryEmptyData> = try await post(path: "license/validate", payload: payload)
    }

    private static func post<T: Decodable>(path: String, payload: [String: String]) async throws -> ZentryEnvelope<T> {
        guard let appKey = ZentryConfiguration.appKey else {
            throw ZentryAPIError(
                code: "NOT_CONFIGURED",
                message: "Falta configurar ZentryAppKey antes de compilar."
            )
        }

        var url = ZentryConfiguration.baseURL.appendingPathComponent(appKey)
        for component in path.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ZentryAPIError(code: "INVALID_RESPONSE", message: "Respuesta de red no válida.")
        }

        if !(200..<300).contains(http.statusCode) {
            let errorEnvelope = try? JSONDecoder().decode(ZentryErrorEnvelope.self, from: data)
            throw ZentryAPIError(
                code: errorEnvelope?.code ?? "HTTP_\(http.statusCode)",
                message: errorEnvelope?.message ?? "Solicitud rechazada."
            )
        }

        let decoded: ZentryEnvelope<T>
        do {
            decoded = try JSONDecoder().decode(ZentryEnvelope<T>.self, from: data)
        } catch {
            throw ZentryAPIError(
                code: "INVALID_RESPONSE",
                message: "Zentry devolvió una respuesta inesperada."
            )
        }
        guard decoded.success else {
            throw ZentryAPIError(
                code: decoded.code ?? "REQUEST_REJECTED",
                message: decoded.message ?? "Solicitud rechazada."
            )
        }
        return decoded
    }
}

@MainActor
final class ZentryAuthState: ObservableObject {
    enum Phase: Equatable {
        case checking
        case locked
        case authenticating
        case authenticated
    }

    @Published private(set) var phase: Phase = .checking
    @Published var errorMessage: String?
    @Published var license = ""
    private var validationInFlight = false

    var isAuthenticated: Bool { phase == .authenticated }

    func restoreSession() async {
        guard !validationInFlight else { return }
        validationInFlight = true
        defer { validationInFlight = false }
        phase = .checking
        errorMessage = nil

        do {
            guard let token = try ZentrySessionStore.load() else {
                phase = .locked
                return
            }
            let hardwareID = try ZentryDeviceIdentity.hardwareID()
            try await ZentryClient.validate(token: token, hardwareID: hardwareID)
            phase = .authenticated
        } catch {
            if (error as? ZentryAPIError)?.invalidatesSavedSession == true {
                ZentrySessionStore.clear()
            }
            phase = .locked
            errorMessage = friendlyMessage(for: error)
        }
    }

    func activate() async {
        let key = license.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !validationInFlight else { return }
        validationInFlight = true
        defer { validationInFlight = false }
        phase = .authenticating
        errorMessage = nil

        do {
            let hardwareID = try ZentryDeviceIdentity.hardwareID()
            let token = try await ZentryClient.activate(license: key, hardwareID: hardwareID)
            try ZentrySessionStore.save(token)
            license = ""
            phase = .authenticated
        } catch {
            phase = .locked
            errorMessage = friendlyMessage(for: error)
        }
    }

    func validateForegroundSession() async {
        guard phase == .authenticated, !validationInFlight else { return }
        validationInFlight = true
        defer { validationInFlight = false }

        do {
            guard let token = try ZentrySessionStore.load() else {
                phase = .locked
                return
            }
            let hardwareID = try ZentryDeviceIdentity.hardwareID()
            try await ZentryClient.validate(token: token, hardwareID: hardwareID)
        } catch {
            if (error as? ZentryAPIError)?.invalidatesSavedSession == true {
                ZentrySessionStore.clear()
            }
            phase = .locked
            errorMessage = friendlyMessage(for: error)
        }
    }

    private func friendlyMessage(for error: Error) -> String {
        let language = AppLanguage.current
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return language.text("login.no_internet")
            case .timedOut:
                return language.text("login.timeout")
            default:
                break
            }
        }
        return (error as? LocalizedError)?.errorDescription ?? language.text("login.generic_error")
    }
}
