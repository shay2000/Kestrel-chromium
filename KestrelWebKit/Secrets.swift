import Foundation

#if canImport(Security)
import Security
#endif

/// A read-only source of secrets. A secret is looked up by an environment
/// variable name and/or a Keychain account name. Implementations never write
/// the value anywhere and never log it.
protocol SecretProviding: Sendable {
    func secret(named environmentName: String, keychainAccount: String) -> String?
}

/// Reads secrets from the process environment. Convenient for local
/// development; nothing is written to disk.
struct EnvironmentSecretProvider: SecretProviding {
    let environment: [String: String]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    func secret(named environmentName: String, keychainAccount: String) -> String? {
        let name = environmentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let value = environment[name], !value.isEmpty else {
            return nil
        }
        return value
    }
}

/// A fixed set of secrets, for tests and previews only.
struct InMemorySecretProvider: SecretProviding {
    let secrets: [String: String]

    init(secrets: [String: String] = [:]) {
        self.secrets = secrets
    }

    func secret(named environmentName: String, keychainAccount: String) -> String? {
        for key in [keychainAccount, environmentName] where !key.isEmpty {
            if let value = secrets[key], !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

/// A secret source that refuses to answer and counts how many times it was
/// asked. It exists so a test can prove that a code path never looks a secret
/// up: on macOS a Keychain read can raise a system password prompt, so any
/// operation that does not need a credential — browsing a model list, for
/// instance — must be provably free of them.
final class FailingSecretProvider: SecretProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0

    /// How many times a secret was requested. Expected to be zero.
    var readCount: Int {
        lock.lock(); defer { lock.unlock() }
        return reads
    }

    func secret(named environmentName: String, keychainAccount: String) -> String? {
        lock.lock(); reads += 1; lock.unlock()
        return nil
    }
}

/// Tries sources in order and returns the first non-empty value.
struct CompositeSecretProvider: SecretProviding {
    let providers: [SecretProviding]

    init(_ providers: [SecretProviding]) {
        self.providers = providers
    }

    func secret(named environmentName: String, keychainAccount: String) -> String? {
        for provider in providers {
            if let value = provider.secret(named: environmentName, keychainAccount: keychainAccount) {
                return value
            }
        }
        return nil
    }
}

#if canImport(Security)
/// A secret source that can explain why its Keychain lookup returned no value.
/// Injected test and preview sources do not conform, so diagnostics never reach
/// into the host Keychain behind their backs.
protocol KeychainLookupDiagnosing {
    func keychainLookupOutcome(account: String) -> KeychainSecretStore.LookupOutcome?
}

extension CompositeSecretProvider: KeychainLookupDiagnosing {
    func keychainLookupOutcome(account: String) -> KeychainSecretStore.LookupOutcome? {
        for provider in providers {
            guard let diagnosing = provider as? KeychainLookupDiagnosing else { continue }
            if let outcome = diagnosing.keychainLookupOutcome(account: account) {
                return outcome
            }
        }
        return nil
    }
}
#endif

enum Secrets {
    /// The default chain for the running platform. On macOS the Keychain is
    /// preferred over the environment; on platforms without `Security` only the
    /// environment is consulted.
    static func defaultProvider() -> SecretProviding {
        #if canImport(Security)
        return CompositeSecretProvider([KeychainSecretStore(), EnvironmentSecretProvider()])
        #else
        return EnvironmentSecretProvider()
        #endif
    }
}

/// Cleans a stored or pasted API key before it is sent.
///
/// A key copied from a dashboard very often carries a trailing newline or
/// space. Sent in an `Authorization` header that produces the provider's own
/// "Invalid API Key" reply, which is indistinguishable from a genuinely wrong
/// key and wastes a lot of time. API keys are a single token, so every run of
/// whitespace inside the value is removed rather than only the ends.
enum APIKeyHygiene {
    static func sanitise(_ value: String) -> String {
        value.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    /// The value to put in the `Authorization` header, or nil when nothing
    /// usable remains.
    static func bearerValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = sanitise(value)
        return cleaned.isEmpty ? nil : cleaned
    }
}

#if canImport(Security)
/// Stores and reads provider secrets in the macOS Keychain. Values are held
/// only inside the system store; Kestrel reads them on demand and keeps the
/// result in memory for the lifetime of a request.
struct KeychainSecretStore: SecretProviding, KeychainLookupDiagnosing {
    static let service = "com.shayprasad.Kestrel.ai"

    let service: String

    init(service: String = KeychainSecretStore.service) {
        self.service = service
    }

    func secret(named environmentName: String, keychainAccount: String) -> String? {
        let account = keychainAccount.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.isEmpty else { return nil }
        return Self.lookupOutcome(account: account, service: service, allowInteraction: false).value
    }

    func keychainLookupOutcome(account: String) -> LookupOutcome? {
        Self.lookupOutcome(account: account, service: service, allowInteraction: false)
    }

    /// Why a lookup returned nothing. A missing item and an item the Keychain
    /// would not release are different problems with different fixes, so the
    /// caller can say which one happened instead of reporting both as "no key".
    enum LookupOutcome: Equatable {
        case found(String)
        case notFound
        case inaccessible(status: Int32)

        var value: String? {
            if case .found(let value) = self { return value }
            return nil
        }
    }

    /// The same read as `secret(named:keychainAccount:)`, but it reports the
    /// Keychain's own answer rather than flattening every failure to `nil`.
    /// Only for callers that already have a legitimate reason to read a secret;
    /// browsing a model list, for instance, must never reach this.
    static func lookupOutcome(account: String, service: String = KeychainSecretStore.service, allowInteraction: Bool = true) -> LookupOutcome {
        let trimmed = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .notFound }

        let query = lookupQuery(account: trimmed, service: service, allowInteraction: allowInteraction)

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            return status == errSecItemNotFound ? .notFound : .inaccessible(status: status)
        }
        guard let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return .notFound
        }
        return .found(value)
    }

    static func lookupQuery(account: String, service: String, allowInteraction: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if !allowInteraction {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        return query
    }

    /// A readable line for a Keychain status a user might actually meet. The
    /// raw status stays in the text so a support conversation has the number.
    static func describe(status: Int32) -> String {
        switch status {
        case errSecInteractionNotAllowed:
            return "macOS would not release it without user interaction (Keychain status \(status))"
        case errSecAuthFailed:
            return "macOS refused the Keychain authentication (Keychain status \(status))"
        case errSecUserCanceled:
            return "the Keychain request was cancelled (Keychain status \(status))"
        default:
            return "the Keychain reported status \(status)"
        }
    }

    @discardableResult
    static func setSecret(_ value: String, account: String, service: String = KeychainSecretStore.service) -> Bool {
        let trimmed = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !value.isEmpty else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: trimmed
        ]
        let valueData = Data(value.utf8)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: valueData] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return true
        }
        guard updateStatus == errSecItemNotFound else {
            return false
        }

        var attributes = query
        attributes[kSecValueData as String] = valueData
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func deleteSecret(account: String, service: String = KeychainSecretStore.service) -> Bool {
        let trimmed = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: trimmed
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
#endif
