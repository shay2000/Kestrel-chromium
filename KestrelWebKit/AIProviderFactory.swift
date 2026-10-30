import Foundation

/// Turns settings and a secret source into a concrete provider. Keeping this
/// small and synchronous makes it easy to unit-test which provider gets built
/// and which configuration error is reported.
enum AIProviderFactory {
    static func makeProvider(for settings: AISettings, secretProvider: SecretProviding) throws -> AIProvider {
        let provider = settings.settings(for: settings.selectedProvider)

        if settings.selectedProvider == .appleLocalModel {
            if let issue = AppleLocalModelProvider.availabilityIssue {
                throw AIProviderError.notConfigured(issue)
            }
            return AppleLocalModelProvider()
        }

        if settings.selectedProvider == .codexCLI, CodexRuntime.executableURL != nil {
            return CodexAccountProvider(model: provider.model, reasoningEffort: settings.reasoning.rawValue)
        }

        if settings.selectedProvider.isCommandLine {
            let executable = provider.executablePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !executable.isEmpty else {
                throw AIProviderError.invalidConfiguration(
                    "Set the \(settings.selectedProvider.displayName) executable in Settings."
                )
            }
            return CLIProvider(
                configuration: CLIProviderConfiguration(
                    kind: settings.selectedProvider,
                    executablePath: executable,
                    argumentTemplate: provider.argumentTemplate,
                    model: provider.model,
                    outputFormat: settings.selectedProvider == .workBuddyCLI ? .codeBuddyJSON : (settings.selectedProvider == .codexCLI ? .codexJSON : .plainText),
                    reasoningEffort: settings.reasoning.rawValue
                )
            )
        }

        guard let baseURL = provider.baseURL, URLNormalisation.isHTTPSURL(baseURL) else {
            throw AIProviderError.invalidConfiguration(
                "Set a valid HTTPS base URL for \(settings.selectedProvider.displayName)."
            )
        }
        guard !provider.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIProviderError.invalidConfiguration(
                "Set a model name for \(settings.selectedProvider.displayName)."
            )
        }
        guard let rawKey = secretProvider.secret(
            named: provider.apiKeyEnvironmentVariable,
            keychainAccount: provider.keychainAccount
        ), let apiKey = APIKeyHygiene.bearerValue(rawKey) else {
            // A Keychain item that exists but cannot be released (usual after
            // the app is rebuilt with a different signature) is a different
            // problem with a different fix from a key that was never saved, so
            // say which one happened instead of a flat "no key".
            #if canImport(Security)
            if let outcome = (secretProvider as? KeychainLookupDiagnosing)?
                .keychainLookupOutcome(account: provider.keychainAccount),
               case .inaccessible(let status) = outcome {
                throw AIProviderError.missingSecret(
                    "The \(settings.selectedProvider.displayName) key is in the Keychain, but \(KeychainSecretStore.describe(status: status)). "
                        + "Open Settings, save the key again from this copy of Kestrel, then try once more."
                )
            }
            #endif
            throw AIProviderError.missingSecret(
                "No API key found for \(settings.selectedProvider.displayName). Add one in Settings, or set \(provider.apiKeyEnvironmentVariable) for local development."
            )
        }

        return HTTPChatProvider(
            configuration: HTTPChatProviderConfiguration(
                kind: settings.selectedProvider,
                baseURL: baseURL,
                model: provider.model,
                apiKey: apiKey,
                additionalHeaders: defaultHeaders(for: settings.selectedProvider)
            )
        )
    }

    /// The provider used when a specific kind is requested, regardless of the
    /// currently selected one. Used by tests and by the settings preview.
    static func makeProvider(
        kind: AIProviderKind,
        settings: AISettings,
        secretProvider: SecretProviding
    ) throws -> AIProvider {
        var copy = settings
        copy.selectedProvider = kind
        return try makeProvider(for: copy, secretProvider: secretProvider)
    }

    static func defaultHeaders(for kind: AIProviderKind) -> [String: String] {
        switch kind {
        case .openRouter:
            // OpenRouter documents these as optional attribution headers.
            return ["X-Title": "Kestrel"]
        case .googleGemini, .mistral, .groq, .deepSeek, .xAI, .customOpenAI,
             .codexCLI, .workBuddyCLI, .kiloCLI, .appleLocalModel:
            return [:]
        }
    }
}
