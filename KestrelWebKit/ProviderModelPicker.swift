#if canImport(SwiftUI)

import SwiftUI

/// A short-lived, in-memory cache of provider model lists.
///
/// Model catalogues change rarely and the sidebar popover is rebuilt every time
/// it opens, so without this a user would re-download OpenRouter's full list on
/// every glance. Nothing is written to disk and nothing survives a relaunch.
@MainActor
final class ProviderModelCache: ObservableObject {
    static let shared = ProviderModelCache()

    /// How long a fetched list is reused before it is refreshed on next use.
    static let lifetime: TimeInterval = 600

    private var entries: [String: (models: [ProviderModel], date: Date)] = [:]
    @Published private(set) var revision = 0

    private init() {}

    func models(for key: String) -> [ProviderModel]? {
        guard let entry = entries[key] else { return nil }
        guard Date.now.timeIntervalSince(entry.date) < Self.lifetime else { return nil }
        return entry.models
    }

    func store(_ models: [ProviderModel], for key: String) {
        entries[key] = (models, .now)
        revision &+= 1
    }

    func clear(for key: String) {
        if entries.removeValue(forKey: key) != nil { revision &+= 1 }
    }

    func contextWindow(for ai: AISettings) -> Int? {
        let provider = ai.selectedProvider
        let selected = ai.settings(for: provider)
        return contextWindow(provider: provider, modelID: selected.model, configuration: selected)
    }

    func contextWindow(
        provider: AIProviderKind,
        modelID: String,
        configuration: AIProviderSettings
    ) -> Int? {
        let keys = ["compact", "regular"].map { style in
            Self.catalogueKey(provider: provider, settings: configuration, style: style)
        }
        for key in keys {
            if let model = models(for: key)?.first(where: { $0.id == modelID }),
               let contextWindow = model.contextWindow {
                return contextWindow
            }
        }
        return ProviderModelCatalogue.contextWindow(for: provider, modelID: modelID)
    }

    static func catalogueKey(provider: AIProviderKind, settings: AIProviderSettings, style: String) -> String {
        [provider.rawValue, settings.baseURL ?? "", settings.executablePath ?? "", style].joined(separator: "|")
    }
}

/// One generation owns the visible catalogue. A cancelled or slower provider
/// fetch must not overwrite a newer choice or prevent that choice loading.
@MainActor
final class ProviderModelLoadState: ObservableObject {
    @Published private(set) var models: [ProviderModel] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorText: String?
    private var generation = UUID()

    func useCached(_ models: [ProviderModel]) {
        generation = UUID()
        self.models = models
        errorText = nil
        isLoading = false
    }

    @discardableResult
    func load(_ operation: () async throws -> [ProviderModel]) async -> [ProviderModel]? {
        let request = UUID()
        generation = request
        models = []
        errorText = nil
        isLoading = true
        defer { if generation == request { isLoading = false } }
        do {
            let loaded = try await operation()
            guard generation == request, !Task.isCancelled else { return nil }
            models = loaded
            return loaded
        } catch {
            guard generation == request, !Task.isCancelled,
                  !(error is CancellationError) else { return nil }
            errorText = Redaction.redacted(error.localizedDescription)
            return nil
        }
    }
}

/// Chooses a model for one provider.
///
/// The default surface is deliberately plain-language: Free, Cheap, Fast and
/// Quality, each backed by one concrete model the provider actually publishes.
/// A "browse all" disclosure keeps the live, searchable catalogue one click
/// away, and Settings can make that list the default. The list is fetched live
/// so a model never has to be typed from memory. When it cannot be read the
/// currently selected model is left untouched and the reason is shown, while
/// the quick picks keep working, so a provider outage cannot silently change
/// the user's setup or lock them out of a known-good model.
struct ProviderModelPicker: View {
    enum Style {
        /// Fits inside the sidebar's provider popover.
        case compact
        /// Fits a Settings pane.
        case regular
    }

    @ObservedObject var settings: AppSettings
    @ObservedObject private var cache = ProviderModelCache.shared
    let provider: AIProviderKind
    var style: Style = .compact
    /// Returns true when the requested selection was applied immediately. An
    /// assistant composer can return false while a smaller file limit awaits
    /// confirmation; Settings leaves this nil and keeps its direct behaviour.
    var onModelSelectionRequested: ((AIProviderKind, String) -> Bool)?
    /// Called after a model is chosen from a row or a quick pick, so a popover
    /// can close itself. Manual typing does not call this.
    var onModelChosen: (() -> Void)?

    @StateObject private var catalogue = ProviderModelLoadState()
    private var models: [ProviderModel] { catalogue.models }
    private var isLoading: Bool { catalogue.isLoading }
    private var errorText: String? { catalogue.errorText }
    @State private var query = ""
    @State private var showsManualEntry = false
    @State private var showsAllModels = false
    @State private var manualModelDraft = ""

    private var providerSettings: AIProviderSettings {
        settings.ai.settings(for: provider)
    }

    private var selectedModelID: String {
        providerSettings.model
    }

    private var recommended: [RecommendedModel] {
        ProviderModelCatalogue.recommendedModels(for: provider)
    }

    private var hasQuickPicks: Bool { !recommended.isEmpty }

    private var selectedModel: Binding<String> {
        Binding(
            get: { settings.ai.settings(for: provider).model },
            set: { model in
                var updated = settings.ai
                var providerSettings = updated.settings(for: provider)
                providerSettings.model = model
                updated.update(providerSettings)
                settings.ai = updated
            }
        )
    }

    private var manualModelBinding: Binding<String> {
        guard onModelSelectionRequested != nil else { return selectedModel }
        return Binding(
            get: { manualModelDraft },
            set: { manualModelDraft = $0 }
        )
    }

    /// Identifies the configuration a fetched list belongs to. It deliberately
    /// excludes the model, so choosing a model does not trigger another fetch.
    private var loadKey: String {
        ProviderModelCache.catalogueKey(
            provider: provider,
            settings: providerSettings,
            style: style == .regular ? "regular" : "compact"
        )
    }

    private var visibleModels: [ProviderModel] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return models }
        return models.filter {
            $0.id.localizedCaseInsensitiveContains(trimmed)
                || $0.name.localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// The active model, shown even when the fetched list does not contain it,
    /// so the current choice is never invisible.
    private var selectionIsListed: Bool {
        models.contains { $0.id == selectedModelID }
    }

    private var selectedDisplayName: String {
        if let match = models.first(where: { $0.id == selectedModelID }) {
            return match.name
        }
        if let match = recommended.first(where: { $0.modelID == selectedModelID }) {
            return match.name
        }
        return selectedModelID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: style == .regular ? 10 : 8) {
            heading

            if provider == .appleLocalModel {
                automaticRow
            } else {
                if hasQuickPicks {
                    quickPicks
                }
                modelBrowsingSection
                statusLine
                manualEntry
            }
        }
        .task(id: loadKey) { await reloadForCurrentProvider() }
        .onAppear {
            // Settings can promote the full list to the default surface; the
            // disclosure remains available either way.
            if settings.advancedModelPicking { showsAllModels = true }
            manualModelDraft = selectedModelID
        }
        .onChange(of: selectedModelID) { manualModelDraft = selectedModelID }
    }

    // MARK: - Pieces

    private var heading: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                ProviderMark(provider: provider, size: style == .regular ? 16 : 14)
                Text("Model")
                    .font(style == .regular ? KestrelTypography.body.weight(.semibold) : KestrelTypography.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                if provider != .appleLocalModel {
                    Button {
                        Task { await load(force: true) }
                    } label: {
                        if isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 10, weight: .medium))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(isLoading)
                    .help("Reload the model list from \(provider.displayName)")
                    .accessibilityLabel("Reload models")
                }
            }

            if provider != .appleLocalModel {
                Text(selectedModelID.isEmpty ? "No model selected" : "Using \(selectedDisplayName)")
                    .font(KestrelTypography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityLabel("Current model: \(selectedModelID.isEmpty ? "none" : selectedDisplayName)")
            }
            if provider == .codexCLI || provider == .workBuddyCLI {
                Text("Thinking: \(settings.ai.reasoning.title)")
                    .font(KestrelTypography.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var automaticRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text("Automatic")
                    .font(KestrelTypography.callout)
                Text("Apple chooses the on-device model.")
                    .font(KestrelTypography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Automatic. Apple chooses the on-device model.")
    }

    /// Plain-language choices, each backed by a concrete model. Tiles rather
    /// than a list keep the whole picker short enough that it cannot be
    /// squeezed into an unusable sliver inside a popover.
    private var quickPicks: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Quick picks")
                .font(KestrelTypography.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 6),
                    GridItem(.flexible(), spacing: 6)
                ],
                spacing: 6
            ) {
                ForEach(recommended) { recommendation in
                    quickPickTile(recommendation)
                }
            }
        }
    }

    private func quickPickTile(_ recommendation: RecommendedModel) -> some View {
        let isSelected = recommendation.modelID == selectedModelID
        return Button {
            choose(recommendation.modelID)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: recommendation.tier.symbol)
                        .font(.system(size: 10, weight: .semibold))
                    Text(recommendation.tier.title)
                        .font(KestrelTypography.callout.weight(.semibold))
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(recommendation.name)
                    .font(KestrelTypography.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(recommendation.tier.blurb)
                    .font(KestrelTypography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .background(
                isSelected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06),
                        lineWidth: 0.8
                    )
            }
        }
        .buttonStyle(.plain)
        .help("\(recommendation.name) — \(recommendation.modelID)")
        .accessibilityLabel("\(recommendation.tier.title): \(recommendation.name). \(recommendation.detail)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// The live catalogue, either open by default (advanced picking, or a
    /// provider with no quick picks) or behind one disclosure.
    @ViewBuilder
    private var modelBrowsingSection: some View {
        if hasQuickPicks, !settings.advancedModelPicking {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.snappy(duration: 0.16)) { showsAllModels.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: showsAllModels ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                        Text(models.isEmpty ? "Browse all models" : "Browse all \(models.count) models")
                            .font(KestrelTypography.caption)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Browse all models from \(provider.displayName)")

                if showsAllModels {
                    searchField
                    modelList
                }
            }
        } else {
            searchField
            modelList
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            TextField(models.isEmpty ? "Search models" : "Search \(models.count) models", text: $query)
                .textFieldStyle(.plain)
                .font(KestrelTypography.footnote)
                .help("Filter the available models by name or model ID")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear the model search")
                .accessibilityLabel("Clear model search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityLabel("Search models")
    }

    @ViewBuilder
    private var modelList: some View {
        if !models.isEmpty || !selectedModelID.isEmpty {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !selectionIsListed, !selectedModelID.isEmpty {
                        modelRow(
                            ProviderModel(
                                id: selectedModelID,
                                name: selectedDisplayName,
                                detail: "Currently selected"
                            )
                        )
                        if !models.isEmpty {
                            Divider().padding(.vertical, 3)
                        }
                    }

                    ForEach(visibleModels) { model in
                        modelRow(model)
                    }

                    if visibleModels.isEmpty, !models.isEmpty {
                        Text("No model matches “\(query)”.")
                            .font(KestrelTypography.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.visible)
            // A definite height, not `maxHeight`: a ScrollView has no intrinsic
            // height, so inside a popover that sizes to its content it collapses
            // to nothing. That was the "crushed" model list.
            .frame(height: listHeight)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Models from \(provider.displayName)")
        }
    }

    /// Enough for a few rows, capped so the popover stays on screen. A handful
    /// of results does not leave a large empty well.
    private var listHeight: CGFloat {
        let maximumRows = style == .regular ? 6 : 4
        let extra = selectionIsListed || selectedModelID.isEmpty ? 0 : 1
        let rows = min(max(visibleModels.count + extra, 1), maximumRows)
        return CGFloat(rows) * 44 + 6
    }

    private func modelRow(_ model: ProviderModel) -> some View {
        let isSelected = model.id == selectedModelID
        return Button {
            choose(model.id)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 11)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(model.name)
                            .font(KestrelTypography.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if model.isFree {
                            Text("Free")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.green)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.green.opacity(0.12), in: Capsule())
                        }
                    }
                    if model.name != model.id {
                        Text(model.id)
                            .font(KestrelTypography.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if let detail = model.detail {
                        Text(detail)
                            .font(KestrelTypography.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .background(
                isSelected ? Color.accentColor.opacity(0.10) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .help(model.id)
        .accessibilityLabel("\(model.name)\(model.isFree ? ", free" : "")")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private var statusLine: some View {
        if let errorText {
            VStack(alignment: .leading, spacing: 3) {
                Label("Couldn’t load models", systemImage: "exclamationmark.triangle")
                    .font(KestrelTypography.chromeDetail.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(errorText)
                    .font(KestrelTypography.chromeDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if selectedModelID.isEmpty {
                    Text(hasQuickPicks
                         ? "Pick a quick option above, type a model name below, or fix the connection and reload."
                         : "Type a model name below, or fix the connection and reload.")
                        .font(KestrelTypography.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if isLoading, models.isEmpty {
            Text("Loading models from \(provider.displayName)…")
                .font(KestrelTypography.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var manualEntry: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy(duration: 0.16)) { showsManualEntry.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: showsManualEntry ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                    Text("Enter a model name manually")
                        .font(KestrelTypography.caption)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Enter a provider model ID that is not shown in the catalogue")

            if showsManualEntry {
                TextField("Model ID", text: manualModelBinding)
                    .textFieldStyle(.plain)
                    .font(KestrelTypography.code)
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background(
                        Color.primary.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .help("Type the model ID exactly as the provider documents it")
                    .accessibilityLabel("Model ID for \(provider.displayName)")

                if onModelSelectionRequested != nil {
                    Button("Use model") { choose(manualModelDraft.trimmingCharacters(in: .whitespacesAndNewlines)) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Use this model ID with the selected provider")
                        .disabled(manualModelDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Text(manualEntryHint)
                    .font(KestrelTypography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var manualEntryHint: String {
        switch provider {
        case .codexCLI:
            return "Leave this empty to use the model already configured for Codex."
        case .workBuddyCLI:
            return "WorkBuddy uses CodeBuddy model identifiers. DeepSeek v4.1 Flash is the default. Choose Thinking in the model picker."
        case .kiloCLI:
            return "Kilo does not publish a model list, so type the name it expects."
        case .openRouter:
            return "Use the provider's own identifier, for example openai/gpt-4o-mini."
        case .mistral:
            return "Use a Mistral model identifier, for example mistral-small-latest."
        case .googleGemini:
            return "Use a Gemini model identifier, for example gemini-3.8-flash."
        case .groq:
            return "Use a Groq model identifier, for example openai/gpt-oss-20b."
        case .deepSeek:
            return "Use a DeepSeek model identifier, for example deepseek-flash."
        case .xAI:
            return "Use an xAI model identifier, for example grok-4.7."
        case .customOpenAI:
            return "Use the model name your endpoint expects, for example gpt-6-luna."
        case .appleLocalModel:
            return ""
        }
    }

    // MARK: - Loading

    private func choose(_ modelID: String) {
        let accepted: Bool
        if let onModelSelectionRequested {
            accepted = onModelSelectionRequested(provider, modelID)
        } else {
            selectedModel.wrappedValue = modelID
            accepted = true
        }
        if accepted { onModelChosen?() }
    }

    private func reloadForCurrentProvider() async {
        query = ""
        if let cached = cache.models(for: loadKey) {
            catalogue.useCached(cached)
        } else {
            await load(force: false)
        }
    }

    private func load(force: Bool) async {
        // Capture the configuration before suspension. A provider switch must
        // never cache an old result under the new provider's key.
        let key = loadKey
        let configuration = providerSettings
        let kind = provider
        if force { cache.clear(for: key) }
        if let loaded = await catalogue.load({
            try await ProviderModelCatalogue.load(
                kind: kind, settings: configuration, secretProvider: settings.secrets
            )
        }) {
            cache.store(loaded, for: key)
        }
    }

}

#endif
