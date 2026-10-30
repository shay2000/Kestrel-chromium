import Foundation

/// Placeholder defaults, gathered in one place so they are easy to review and
/// change. Kestrel does not treat these as fixed: every value here can be
/// overridden in Settings. No token or model is compiled in as a secret.
enum AIDefaults {
    // Model identifiers are starting points, not commitments. OpenRouter
    // starts on its zero-cost free router so a new user has a working answer
    // before entering any credit; Mistral has no free API tier, so it starts on
    // its fastest balanced route.
    static let openRouterModel = ProviderModelCatalogue.openRouterFreeRouterID
    static let mistralModel = "mistral-small-latest"
    static let geminiModel = "gemini-3.8-flash"
    static let groqModel = "openai/gpt-oss-20b"
    static let deepSeekModel = "deepseek-flash"
    static let xAIModel = "grok-4.7"
    static let customOpenAIModel = "gpt-6-luna"
    static let codexExecutable = "codex"
    static let kiloExecutable = "kilo"

    /// OpenRouter's public API root.
    static let openRouterBaseURL = "https://openrouter.ai/api/v1"
    /// Mistral's public API root.
    static let mistralBaseURL = "https://api.mistral.ai/v1"
    /// Google's OpenAI-compatibility surface for the Gemini API.
    static let geminiBaseURL = "https://generativelanguage.googleapis.com/v1beta/openai"
    /// Groq's OpenAI-compatible API root.
    static let groqBaseURL = "https://api.groq.com/openai/v1"
    /// DeepSeek's OpenAI-compatible API root.
    static let deepSeekBaseURL = "https://api.deepseek.com"
    /// xAI's OpenAI-compatible API root.
    static let xAIBaseURL = "https://api.x.ai/v1"
    /// The generic OpenAI-compatible slot starts at OpenAI itself and can be
    /// repointed at any compatible server.
    static let customOpenAIBaseURL = "https://api.openai.com/v1"

    /// Environment variable names consulted for local development. These are
    /// names only; values are never written to disk or logged.
    static let openRouterAPIKeyEnvironment = "OPENROUTER_API_KEY"
    static let mistralAPIKeyEnvironment = "MISTRAL_API_KEY"
    static let geminiAPIKeyEnvironment = "GEMINI_API_KEY"
    static let groqAPIKeyEnvironment = "GROQ_API_KEY"
    static let deepSeekAPIKeyEnvironment = "DEEPSEEK_API_KEY"
    static let xAIAPIKeyEnvironment = "XAI_API_KEY"
    static let customOpenAIAPIKeyEnvironment = "OPENAI_API_KEY"

    /// Keychain account names for the same secrets on macOS.
    static let openRouterKeychainAccount = "openrouter.api-key"
    static let mistralKeychainAccount = "mistral.api-key"
    static let geminiKeychainAccount = "google-gemini.api-key"
    static let groqKeychainAccount = "groq.api-key"
    static let deepSeekKeychainAccount = "deepseek.api-key"
    static let xAIKeychainAccount = "xai.api-key"
    static let customOpenAIKeychainAccount = "openai-compatible.api-key"
}

/// Non-secret configuration for one provider. Secrets are never stored here.
struct AIProviderSettings: Codable, Equatable, Sendable {
    var kind: AIProviderKind
    var model: String
    var baseURL: String?
    var executablePath: String?
    /// Arguments passed to a CLI provider. `{prompt}` and `{model}` are the
    /// only placeholders substituted; each becomes a single argv element, so
    /// nothing is ever interpreted by a shell.
    var argumentTemplate: [String]
    /// The name of an environment variable to consult for local development.
    var apiKeyEnvironmentVariable: String
    /// The Keychain account name used on macOS. Not a secret.
    var keychainAccount: String

    static func defaultSettings(for kind: AIProviderKind) -> AIProviderSettings {
        switch kind {
        case .codexCLI:
            return AIProviderSettings(
                kind: kind,
                // Empty means "use the model already configured for Codex".
                model: "",
                baseURL: nil,
                executablePath: AIDefaults.codexExecutable,
                // `codex exec` is a full agent. These arguments keep it
                // non-interactive, read-only, outside a Git checkout and
                // machine-readable, so Kestrel can show the answer rather than
                // the tool's event log. Without `--skip-git-repo-check` the
                // command refuses to run at all outside a trusted directory.
                argumentTemplate: [
                    "exec",
                    "--json",
                    "--skip-git-repo-check",
                    "--sandbox", "read-only",
                    "--ephemeral",
                    "--color", "never",
                    "-m", "{model}",
                    "{prompt}"
                ],
                apiKeyEnvironmentVariable: "",
                keychainAccount: ""
            )
        case .workBuddyCLI:
            return AIProviderSettings(kind: kind, model: "deepseek-v4.1-flash", baseURL: nil,
                executablePath: "/opt/homebrew/bin/codebuddy", argumentTemplate: [],
                apiKeyEnvironmentVariable: "", keychainAccount: "")
        case .kiloCLI:
            return AIProviderSettings(
                kind: kind,
                model: "",
                baseURL: nil,
                executablePath: AIDefaults.kiloExecutable,
                argumentTemplate: ["run", "{prompt}"],
                apiKeyEnvironmentVariable: "",
                keychainAccount: ""
            )
        case .openRouter:
            return AIProviderSettings(
                kind: kind,
                model: AIDefaults.openRouterModel,
                baseURL: AIDefaults.openRouterBaseURL,
                executablePath: nil,
                argumentTemplate: [],
                apiKeyEnvironmentVariable: AIDefaults.openRouterAPIKeyEnvironment,
                keychainAccount: AIDefaults.openRouterKeychainAccount
            )
        case .mistral:
            return AIProviderSettings(
                kind: kind,
                model: AIDefaults.mistralModel,
                baseURL: AIDefaults.mistralBaseURL,
                executablePath: nil,
                argumentTemplate: [],
                apiKeyEnvironmentVariable: AIDefaults.mistralAPIKeyEnvironment,
                keychainAccount: AIDefaults.mistralKeychainAccount
            )
        case .googleGemini:
            return AIProviderSettings(
                kind: kind,
                model: AIDefaults.geminiModel,
                baseURL: AIDefaults.geminiBaseURL,
                executablePath: nil,
                argumentTemplate: [],
                apiKeyEnvironmentVariable: AIDefaults.geminiAPIKeyEnvironment,
                keychainAccount: AIDefaults.geminiKeychainAccount
            )
        case .groq:
            return AIProviderSettings(
                kind: kind,
                model: AIDefaults.groqModel,
                baseURL: AIDefaults.groqBaseURL,
                executablePath: nil,
                argumentTemplate: [],
                apiKeyEnvironmentVariable: AIDefaults.groqAPIKeyEnvironment,
                keychainAccount: AIDefaults.groqKeychainAccount
            )
        case .deepSeek:
            return AIProviderSettings(
                kind: kind,
                model: AIDefaults.deepSeekModel,
                baseURL: AIDefaults.deepSeekBaseURL,
                executablePath: nil,
                argumentTemplate: [],
                apiKeyEnvironmentVariable: AIDefaults.deepSeekAPIKeyEnvironment,
                keychainAccount: AIDefaults.deepSeekKeychainAccount
            )
        case .xAI:
            return AIProviderSettings(
                kind: kind,
                model: AIDefaults.xAIModel,
                baseURL: AIDefaults.xAIBaseURL,
                executablePath: nil,
                argumentTemplate: [],
                apiKeyEnvironmentVariable: AIDefaults.xAIAPIKeyEnvironment,
                keychainAccount: AIDefaults.xAIKeychainAccount
            )
        case .customOpenAI:
            return AIProviderSettings(
                kind: kind,
                model: AIDefaults.customOpenAIModel,
                baseURL: AIDefaults.customOpenAIBaseURL,
                executablePath: nil,
                argumentTemplate: [],
                apiKeyEnvironmentVariable: AIDefaults.customOpenAIAPIKeyEnvironment,
                keychainAccount: AIDefaults.customOpenAIKeychainAccount
            )
        case .appleLocalModel:
            return AIProviderSettings(
                kind: kind,
                model: "system-default",
                baseURL: nil,
                executablePath: nil,
                argumentTemplate: [],
                apiKeyEnvironmentVariable: "",
                keychainAccount: ""
            )
        }
    }
}

/// Everything the AI sidebar needs to choose and describe a provider. Persisted
/// as JSON in `UserDefaults` by `AppSettings`; contains no secret values.
enum AssistantReasoning: String, Codable, CaseIterable, Identifiable, Sendable {
    case low, medium, high
    var id: String { rawValue }
    var title: String { switch self { case .low: return "Fast"; case .medium: return "Balanced"; case .high: return "Thorough" } }
}

struct AISettings: Codable, Equatable, Sendable {
    var reasoning: AssistantReasoning = .medium
    var selectedProvider: AIProviderKind
    var includeAgentPageImages = false
    var codex: AIProviderSettings
    var workBuddy: AIProviderSettings = .defaultSettings(for: .workBuddyCLI)
    var kilo: AIProviderSettings
    var openRouter: AIProviderSettings
    var mistral: AIProviderSettings
    var googleGemini: AIProviderSettings
    var groq: AIProviderSettings
    var deepSeek: AIProviderSettings
    var xAI: AIProviderSettings
    var customOpenAI: AIProviderSettings

    /// A saved configuration that predates a newer provider simply lacks that
    /// provider's block. Decoding tolerantly means adding providers never
    /// throws away a user's existing keys, models and shortcuts: a missing
    /// block falls back to its shipped default instead of failing the whole
    /// decode (which `AppSettings` would then treat as "use defaults").
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func provider(_ key: CodingKeys, _ kind: AIProviderKind) -> AIProviderSettings {
            (try? container.decodeIfPresent(AIProviderSettings.self, forKey: key))
                ?? .defaultSettings(for: kind)
        }
        selectedProvider = (try? container.decodeIfPresent(AIProviderKind.self, forKey: .selectedProvider))
            ?? .codexCLI
        reasoning = (try? container.decodeIfPresent(AssistantReasoning.self, forKey: .reasoning)) ?? .medium
        includeAgentPageImages = (try? container.decodeIfPresent(Bool.self, forKey: .includeAgentPageImages)) ?? false
        codex = provider(.codex, .codexCLI)
        kilo = provider(.kilo, .kiloCLI)
        workBuddy = provider(.workBuddy, .workBuddyCLI)
        openRouter = provider(.openRouter, .openRouter)
        mistral = provider(.mistral, .mistral)
        googleGemini = provider(.googleGemini, .googleGemini)
        groq = provider(.groq, .groq)
        deepSeek = provider(.deepSeek, .deepSeek)
        xAI = provider(.xAI, .xAI)
        customOpenAI = provider(.customOpenAI, .customOpenAI)
    }

    init(
        selectedProvider: AIProviderKind,
        codex: AIProviderSettings,
        kilo: AIProviderSettings,
        openRouter: AIProviderSettings,
        mistral: AIProviderSettings,
        googleGemini: AIProviderSettings,
        groq: AIProviderSettings,
        deepSeek: AIProviderSettings,
        xAI: AIProviderSettings,
        customOpenAI: AIProviderSettings
    ) {
        self.selectedProvider = selectedProvider
        self.codex = codex
        self.kilo = kilo
        self.openRouter = openRouter
        self.mistral = mistral
        self.googleGemini = googleGemini
        self.groq = groq
        self.deepSeek = deepSeek
        self.xAI = xAI
        self.customOpenAI = customOpenAI
    }

    /// Compatibility for the sidebar while its status copy is being updated.
    /// Assistant page context is always included when it can be read.
    var allowsAutomaticPageReads: Bool { true }

    /// A bounded budget selected from the active provider and model. Model IDs
    /// with an explicit context-window suffix are used when available;
    /// otherwise PageContextBuilder applies a conservative provider default.
    var automaticPageContextCharacterLimit: Int {
        PageContextBuilder.automaticCharacterLimit(
            for: selectedProvider,
            model: settings(for: selectedProvider).model
        )
    }

    static let `default`: AISettings = {
        AISettings(
            selectedProvider: .codexCLI,
            codex: .defaultSettings(for: .codexCLI),
            kilo: .defaultSettings(for: .kiloCLI),
            openRouter: .defaultSettings(for: .openRouter),
            mistral: .defaultSettings(for: .mistral),
            googleGemini: .defaultSettings(for: .googleGemini),
            groq: .defaultSettings(for: .groq),
            deepSeek: .defaultSettings(for: .deepSeek),
            xAI: .defaultSettings(for: .xAI),
            customOpenAI: .defaultSettings(for: .customOpenAI)
        )
    }()

    func settings(for kind: AIProviderKind) -> AIProviderSettings {
        switch kind {
        case .codexCLI: return codex
        case .workBuddyCLI: return workBuddy
        case .kiloCLI: return kilo
        case .openRouter: return openRouter
        case .mistral: return mistral
        case .googleGemini: return googleGemini
        case .groq: return groq
        case .deepSeek: return deepSeek
        case .xAI: return xAI
        case .customOpenAI: return customOpenAI
        case .appleLocalModel: return .defaultSettings(for: .appleLocalModel)
        }
    }

    mutating func update(_ settings: AIProviderSettings) {
        switch settings.kind {
        case .codexCLI: codex = settings
        case .workBuddyCLI: workBuddy = settings
        case .kiloCLI: kilo = settings
        case .openRouter: openRouter = settings
        case .mistral: mistral = settings
        case .googleGemini: googleGemini = settings
        case .groq: groq = settings
        case .deepSeek: deepSeek = settings
        case .xAI: xAI = settings
        case .customOpenAI: customOpenAI = settings
        case .appleLocalModel: break
        }
    }

    /// The Codex argument template shipped before the connection was fixed.
    /// `codex exec` refuses to start outside a trusted directory unless
    /// `--skip-git-repo-check` is passed, so the old value never worked.
    static let legacyCodexArgumentTemplate = ["exec", "{prompt}"]

    /// The OpenRouter model shipped before the free router became the default.
    /// Only the exact old default is replaced, so a model the user chose is
    /// left alone.
    static let legacyOpenRouterModel = "openai/gpt-4o-mini"

    /// Gemini restricted the 2.5 generation for projects that did not already
    /// use it, so an untouched shipped default must move to a current model.
    static let legacyGeminiModel = "gemini-2.5-flash"

    /// The previous xAI quick-pick was removed from the public API catalogue.
    static let legacyXAIModel = "grok-4.3"

    /// Upgrades a saved configuration that predates a fix. Only the exact old
    /// default is replaced, so a template or model the user has edited is left
    /// alone.
    mutating func migrateLegacyDefaults() {
        if codex.argumentTemplate == Self.legacyCodexArgumentTemplate {
            codex.argumentTemplate = AIProviderSettings.defaultSettings(for: .codexCLI).argumentTemplate
        }
        if openRouter.model == Self.legacyOpenRouterModel {
            openRouter.model = AIDefaults.openRouterModel
        }
        if googleGemini.model == Self.legacyGeminiModel {
            googleGemini.model = AIDefaults.geminiModel
        }
        if xAI.model == Self.legacyXAIModel {
            xAI.model = AIDefaults.xAIModel
        }
    }

    /// A readable reason the current provider cannot answer yet, or nil when it
    /// looks ready. This is what backs the sidebar's honest setup state.
    func configurationIssue(secretProvider: SecretProviding) -> String? {
        if selectedProvider == .appleLocalModel {
            return AppleLocalModelProvider.availabilityIssue
        }

        let provider = settings(for: selectedProvider)
        if selectedProvider.isHTTP {
            guard let baseURL = provider.baseURL, URLNormalisation.isHTTPSURL(baseURL) else {
                return "Set a valid HTTPS base URL for \(selectedProvider.displayName)."
            }
            guard !provider.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "Set a model name for \(selectedProvider.displayName)."
            }
            guard let secret = secretProvider.secret(
                named: provider.apiKeyEnvironmentVariable,
                keychainAccount: provider.keychainAccount
            ), !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "No API key found. Add one in Settings, or set \(provider.apiKeyEnvironmentVariable) for local development."
            }
            return nil
        }

        let executable = provider.executablePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !executable.isEmpty else {
            return "Set the \(selectedProvider.displayName) executable in Settings."
        }
        return nil
    }

    /// Checks only settings that are already in memory. Rendering the chat page
    /// must not make a synchronous Keychain request: on macOS that can block
    /// SwiftUI while a protected item is being released. Credentials are still
    /// checked when the user sends a request and when they open provider setup
    /// in Settings.
    func displayConfigurationIssueWithoutReadingSecrets() -> String? {
        if selectedProvider == .appleLocalModel {
            return AppleLocalModelProvider.availabilityIssue
        }

        let provider = settings(for: selectedProvider)
        if selectedProvider.isHTTP {
            guard let baseURL = provider.baseURL, URLNormalisation.isHTTPSURL(baseURL) else {
                return "Set a valid HTTPS base URL for \(selectedProvider.displayName)."
            }
            guard !provider.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "Set a model name for \(selectedProvider.displayName)."
            }
            return nil
        }

        guard let executable = provider.executablePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !executable.isEmpty else {
            return "Set the \(selectedProvider.displayName) executable in Settings."
        }
        return nil
    }
}
