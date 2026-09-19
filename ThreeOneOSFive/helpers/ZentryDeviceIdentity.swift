import CryptoKit
import Foundation
import Security

enum ZentryDeviceIdentityError: LocalizedError {
    case secureEnclaveUnavailable
    case keychain(OSStatus)
    case keyGeneration(String)
    case publicKeyUnavailable

    var errorDescription: String? {
        switch self {
        case .secureEnclaveUnavailable:
            return "Este dispositivo no permite crear una identidad segura."
        case .keychain(let status):
            return "No se pudo acceder a la identidad segura (\(status))."
        case .keyGeneration(let message):
            return "No se pudo crear la identidad segura: \(message)"
        case .publicKeyUnavailable:
            return "No se pudo leer la identidad pública del dispositivo."
        }
    }
}

/// Creates a non-exportable P-256 private key in this device's Secure Enclave.
/// Zentry receives only SHA-256(public key), never the private key itself.
enum ZentryDeviceIdentity {
    private static let applicationTag = Data("com.externalct.zentry.device-key.v1".utf8)

    static func hardwareID() throws -> String {
#if targetEnvironment(simulator)
        // Simulator-only fallback so the login UI can be developed without a phone.
        return try simulatorIdentifier()
#else
        guard SecureEnclave.isAvailable else {
            throw ZentryDeviceIdentityError.secureEnclaveUnavailable
        }

        let privateKey = try loadPrivateKey() ?? createPrivateKey()
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicRepresentation = SecKeyCopyExternalRepresentation(publicKey, nil) else {
            throw ZentryDeviceIdentityError.publicKeyUnavailable
        }
        let publicData = publicRepresentation as Data

        return SHA256.hash(data: publicData).map { String(format: "%02x", $0) }.joined()
#endif
    }

    private static func loadPrivateKey() throws -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecAttrApplicationTag as String: applicationTag,
            kSecReturnRef as String: true
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, item != nil else {
            throw ZentryDeviceIdentityError.keychain(status)
        }
        return (item as! SecKey)
    }

    private static func createPrivateKey() throws -> SecKey {
        var accessError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .privateKeyUsage,
            &accessError
        ) else {
            let message = accessError?.takeRetainedValue().localizedDescription ?? "Error de control de acceso"
            throw ZentryDeviceIdentityError.keyGeneration(message)
        }

        let privateAttributes: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: applicationTag,
            kSecAttrAccessControl as String: accessControl
        ]
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: privateAttributes
        ]

        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let message = error?.takeRetainedValue().localizedDescription ?? "Error desconocido"
            throw ZentryDeviceIdentityError.keyGeneration(message)
        }
        return key
    }

#if targetEnvironment(simulator)
    private static func simulatorIdentifier() throws -> String {
        let service = "com.externalct.zentry.simulator"
        let account = "device-id"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data,
           let value = String(data: data, encoding: .utf8) {
            return value
        }
        guard status == errSecItemNotFound else {
            throw ZentryDeviceIdentityError.keychain(status)
        }

        let value = "sim-\(UUID().uuidString.lowercased())"
        var add = query
        add.removeValue(forKey: kSecReturnData as String)
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw ZentryDeviceIdentityError.keychain(addStatus)
        }
        return value
    }
#endif
}
