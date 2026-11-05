#if canImport(SwiftUI)

import SwiftUI
import AppKit
import UniformTypeIdentifiers
#if canImport(Security)
import Security
#endif

/// Kestrel's settings window. It holds provider selection, non-secret provider
/// configuration, the Keychain-backed API key field, the operator options and
/// the extension capability state. No secret value is ever displayed.
struct SettingsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private enum Page: String, CaseIterable, Identifiable {
        case general
        case personalisation
        case shortcuts
        case assistant
        case privacy
        case connections
        case extensions

        var id: String { rawValue }

        var title: String {
            switch self {
            case .shortcuts: "Shortcuts"
            case .general: "General"
            case .personalisation: "About me"
            case .assistant: "Assistant"
            case .privacy: "Privacy"
            case .connections: "Connections"
            case .extensions: "Extensions"
            }
        }

        var symbol: String {
            switch self {
            case .shortcuts: "keyboard"
            case .general: "slider.horizontal.3"
            case .personalisation: "person.crop.circle"
            case .assistant: "sparkles"
            case .privacy: "hand.raised"
            case .connections: "point.3.connected.trianglepath.dotted"
            case .extensions: "puzzlepiece.extension"
            }
        }

        var subtitle: String {
            switch self {
            case .shortcuts: "Choose your keys for browser actions"
            case .general: "Appearance, search and bookmarks"
            case .personalisation: "Personalisation and delivery details, saved on this Mac"
            case .assistant: "Choose and configure your assistant"
            case .privacy: "Page context and passkey access"
            case .connections: "Web search and coding agents"
            case .extensions: "Manage WebExtension support"
            }
        }
    }

    private enum FileImportPurpose: Equatable {
        case browserBookmarks
        case webExtension
    }

    @ObservedObject var settings: AppSettings
    @ObservedObject var mcpServer: KestrelMCPServer
    @ObservedObject private var extensionHost = BrowserExtensionHost.shared

    @State private var profileDraft = PersonalProfile()
    @State private var profileStatus: String?
    @State private var confirmsProfileRemoval = false
    @State private var shortcutMessage: String?
    @State private var shortcutQuery = ""
    @State private var selectedPage: Page? = .general
    @State private var keyDraft = ""
    @State private var keyStatusMessage: String?
    @State private var exaKeyDraft = ""
    @State private var exaKeyStatus: String?
    @State private var mcpConnectionMessage: String?
    @State private var isTestingMCP = false
    @State private var isConnectingCodex = false
    @State private var isCodexRegistered = false
    @StateObject private var codexAccount = CodexAccountController()

    // Extension import and approval state. Nothing is granted until the user
    // presses the approval button, and every checkbox starts off.
    @State private var isImportingFile = false
    @State private var fileImportPurpose: FileImportPurpose = .webExtension
    @State private var browserBookmarkMessage: String?
    @State private var isStagingExtension = false
    @State private var stagedPreview: ExtensionInstallPreview?
    @State private var stagedID: UUID?
    @State private var securityScopedExtensionURL: URL?
    @State private var selectedPermissions: Set<String> = []
    @State private var selectedHostPatterns: Set<String> = []
    @State private var extensionStatusMessage: String?

    var body: some View {
        HStack(spacing: 0) {
            List(Page.allCases, selection: $selectedPage) { page in
                HStack(spacing: 10) {
                    Image(systemName: page.symbol)
                        .foregroundStyle(.primary)
                        .opacity(selectedPage == page ? 1 : 0.65)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    Text(page.title)
                }
                    .font(KestrelTypography.chromeLabel)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(page.title)
                    .tag(page)
                    .padding(.vertical, 6)
                    .listRowSeparator(.hidden)
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selectedPage == page ? ComposerAccessoryPalette.lavenderInk.opacity(0.12) : .clear)
                    )
            }
            .listStyle(.sidebar)
            .accentColor(ComposerAccessoryPalette.lavenderInk)
            .scrollContentBackground(.hidden)
            .padding(.top, 12)
            .frame(width: 190)

            Divider()

            VStack(spacing: 0) {
                pageHeader

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        pageSections
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.top, 4)
                    .padding(.bottom, 24)
                }
                // Each category opens at its own top, never at the previous
                // category's scroll offset or with a field still recording.
                .id(currentPage)
                .transition(.opacity)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: currentPage)
        }
        .font(KestrelTypography.chromeLabel)
        .controlSize(.regular)
        .tint(ComposerAccessoryPalette.lavenderInk)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: settings.appearanceMode)
        .frame(minWidth: 800, idealWidth: 900, minHeight: 600, idealHeight: 680)
        .navigationTitle("Kestrel Settings")
        .onAppear {
            profileDraft = settings.personalProfile
        }
        .confirmationDialog("Remove your saved personal details?", isPresented: $confirmsProfileRemoval) {
            Button("Remove details", role: .destructive) {
                settings.personalProfile = .init()
                profileDraft = .init()
                profileStatus = "Personal details removed from Kestrel."
            }
        } message: {
            Text("This removes your local profile, including unsaved changes. It does not clear information you previously copied to the clipboard or entered on websites.")
        }
        .onDisappear { settings.recordingShortcut = nil }
        .onChange(of: selectedPage) { _, _ in settings.recordingShortcut = nil }
        .onChange(of: shortcutQuery) { _, _ in settings.recordingShortcut = nil }
        .fileImporter(
            isPresented: $isImportingFile,
            allowedContentTypes: fileImportPurpose == .browserBookmarks
                ? browserBookmarkImportContentTypes
                : extensionImportContentTypes,
            allowsMultipleSelection: false,
            onCompletion: { result in
                switch fileImportPurpose {
                case .browserBookmarks:
                    handleBrowserBookmarkSelection(result)
                case .webExtension:
                    handleImportSelection(result)
                }
            }
        )
        .sheet(item: $stagedPreview, onDismiss: discardStagedIfNeeded) { preview in
            ExtensionApprovalSheet(
                preview: preview,
                selectedPermissions: $selectedPermissions,
                selectedHostPatterns: $selectedHostPatterns,
                onApprove: { approveStagedExtension(preview) },
                onDiscard: { discardStagedExtension(preview) }
            )
        }
    }

    private var currentPage: Page { selectedPage ?? .general }

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(currentPage.title)
                .font(.system(size: 22, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text(currentPage.subtitle)
                .font(KestrelTypography.chromeDetail)
                .foregroundStyle(Color.primary.opacity(0.66))
        }
        .frame(maxWidth: 720, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private var pageSections: some View {
        switch currentPage {
        case .general:
            appearanceSection
            newTabAssistantSection
            searchSection
            browserDataSection
        case .personalisation:
            personalisationSection
        case .shortcuts:
            browserShortcutsSection
        case .assistant:
            assistantSection
            providerSection
            secretSection
            assistantBehaviourSection
        case .privacy:
            operatorSection
            passkeysSection
        case .connections:
            exaSection
            agentMCPSection
        case .extensions:
            extensionsSection
        }
    }

    private func profileField(_ title: String, _ key: WritableKeyPath<PersonalProfile, String>, prompt: String) -> some View {
        SettingsRow(title) {
            HStack(spacing: 6) {
                TextField(prompt, text: Binding(get: { profileDraft[keyPath: key] }, set: {
                    profileDraft[keyPath: key] = String($0.prefix(key == \PersonalProfile.preferences ? 2_000 : 512))
                    profileStatus = nil
                }))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(title)
                .frame(width: 300)
            }
        }
    }

    private var personalisationSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard("About me & personalisation") {
                Text("Keep your contact and delivery details handy for checkout. Fields are optional. Details are stored in Kestrel’s local preferences on this Mac, not in the Keychain or synced by Kestrel.")
                    .font(KestrelTypography.chromeDetail).foregroundStyle(.secondary)
                Text("Saving keeps these details on this Mac. Ask Agent mode to fill a contact or address form; review the exact values and destination, then approve each fill. Details go to the website, not the model prompt. Nothing is submitted. Do not enter passwords or payment-card details here.")
                    .font(KestrelTypography.chromeDetail).foregroundStyle(.secondary)
            }
            SettingsCard("Contact details") {
                profileField("Full name", \.name, prompt: "Your name")
                profileField("Email", \.email, prompt: "you@example.com")
                profileField("Phone number", \.phone, prompt: "Include country code")
            }
            SettingsCard("Delivery address") {
                profileField("Address line 1", \.addressLine1, prompt: "House number and street")
                profileField("Address line 2", \.addressLine2, prompt: "Flat, building or locality")
                profileField("Town or city", \.city, prompt: "Town or city")
                profileField("County or region", \.county, prompt: "County, state or region")
                profileField("Postcode", \.postcode, prompt: "Postcode or ZIP code")
                profileField("Country", \.country, prompt: "Country")
            }
            SettingsCard("Preferences") {
                profileField("Personal preferences", \.preferences, prompt: "For example, preferred delivery options")
                Text("A local note for now; preferences are not copied with delivery details or used to personalise model responses automatically.")
                    .font(KestrelTypography.chromeDetail).foregroundStyle(.secondary)
            }
            HStack {
                Button("Save details") {
                    settings.personalProfile = profileDraft.normalised
                    profileDraft = settings.personalProfile
                    profileStatus = "Saved on this Mac."
                }.buttonStyle(.borderedProminent)
                    .disabled(profileDraft.normalised == settings.personalProfile)
                Button("Copy delivery details") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(settings.personalProfile.deliveryText, forType: .string)
                    profileStatus = "Saved delivery details copied to the clipboard."
                }.disabled(settings.personalProfile.deliveryText.isEmpty)
                Spacer()
                Button("Clear details", role: .destructive) { confirmsProfileRemoval = true }
                    .disabled(settings.personalProfile == PersonalProfile() && profileDraft == PersonalProfile())
            }
            if let profileStatus { Text(profileStatus).font(KestrelTypography.chromeDetail).foregroundStyle(.secondary) }
            if profileDraft.normalised != settings.personalProfile {
                Text("You have unsaved changes. Copy uses your saved details.")
                    .font(KestrelTypography.chromeDetail).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - General

    private var appearanceSection: some View {
        SettingsCard("Appearance") {
            SettingsRow("Colour scheme", detail: "Follow macOS or choose a fixed appearance.") {
                Picker("Appearance", selection: $settings.appearanceMode) {
                    ForEach(KestrelAppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)
                .help("Choose System, Light or Dark appearance for Kestrel")
            }
            Divider()
            SettingsToggle("Translucent browser chrome",
                           detail: "Tint the backing and sidebars to match your appearance.",
                           isOn: $settings.translucentChromeEnabled)
                .help("Use Safari-style translucent backing and sidebars, tinted for the current appearance")
        }
    }

    private var newTabAssistantSection: some View {
        SettingsCard("New Tab") {
            SettingsRow("Assistant replies", detail: "Choose where questions from New Tab open.") {
                Picker("Assistant reply location", selection: $settings.newTabAssistantDestination) {
                    ForEach(NewTabAssistantDestination.allCases) { destination in
                        Text(destination.title).tag(destination)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)
                .accessibilityLabel("New Tab assistant reply location")
                .help("Choose whether an AI question from New Tab opens the Assistant page or the sidebar")
            }
            Text("New tabs open the dashboard. Press ⌘Return in its search bar to ask the Assistant.")
                .settingsSupportingCopy()
        }
    }

    private var searchSection: some View {
        SettingsCard("Search") {
            SettingsRow("Default search engine", detail: "Also provides suggestions as you type.") {
                Picker("Default search engine", selection: $settings.searchEngine) {
                    ForEach(SearchEngine.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
                .help("Choose which search provider handles address-bar and New Tab searches")
            }
        }
    }

    private var browserDataSection: some View {
        SettingsCard("Browser data") {
            SettingsRow("Bookmarks", detail: "Import an export from Safari, Chrome, Firefox or Edge.") {
                Button("Import bookmarks…") {
                    fileImportPurpose = .browserBookmarks
                    isImportingFile = true
                }
                .help("Choose an exported bookmarks file to add safe HTTP or HTTPS links to Kestrel")
            }
            Text("Only HTTP(S) bookmarks are added. Passwords, cookies and browsing history are not imported.")
                .settingsSupportingCopy()
            Divider()
            SettingsRow("Recent searches", detail: "\(settings.recentSearches.count) saved on this Mac") {
                Button("Clear history", role: .destructive) {
                    settings.clearSearchHistory()
                }
                .help("Remove saved recent searches from this Mac")
                .disabled(settings.recentSearches.isEmpty)
            }
            if let browserBookmarkMessage {
                Text(browserBookmarkMessage).settingsSupportingCopy()
            }
        }
    }

    private var browserBookmarkImportContentTypes: [UTType] {
        [.html, .json, .propertyList, .data]
    }

    private func handleBrowserBookmarkSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            browserBookmarkMessage = "The bookmark file could not be selected: \(error.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            let hasSecurityScope = url.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
            }
            do {
                if let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                   fileSize > BrowserBookmarkImporter.maximumFileBytes {
                    throw BrowserBookmarkImporter.ImportError.fileTooLarge
                }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let imported = try BrowserBookmarkImporter.parse(data: data, filename: url.lastPathComponent)
                let count = settings.importBookmarks(imported)
                browserBookmarkMessage = count == 0
                    ? "No new HTTP(S) bookmarks were found in that file."
                    : "Imported \(count) bookmark\(count == 1 ? "" : "s")."
            } catch {
                browserBookmarkMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Assistant

    private var assistantSection: some View {
        SettingsCard("Provider") {
            SettingsRow("Assistant service", detail: settings.ai.selectedProvider.summary) {
                Picker("Provider", selection: $settings.ai.selectedProvider) {
                    ForEach(AIProviderKind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 220)
                .help("Choose which assistant service handles new questions")
            }

        }
    }

    private var assistantBehaviourSection: some View {
        SettingsCard("Behaviour") {
            SettingsToggle("Include webpage images in Agent mode",
                           detail: "Send a temporary image of the current page to an image-capable hosted model or WorkBuddy. Form fields are covered; images can still contain private page content. Images are never saved in chats.",
                           isOn: $settings.ai.includeAgentPageImages)
                .help("Include a bounded page image with each Agent mode step. Apple On-Device and other CLI providers receive text only.")
            SettingsToggle("Allow web search",
                           detail: "Search for current information. Agent mode remains a separate choice to control a page.",
                           isOn: $settings.assistantWebSearchEnabled)
                .help("Let the Assistant search the web when a question needs current information")
            Divider()
            SettingsToggle("Advanced model picking",
                           detail: "Open the full catalogue instead of quick picks. All models remain available either way.",
                           isOn: $settings.advancedModelPicking)
                .help("Open the full searchable model catalogue by default instead of the quick picks")
            Divider()
            SettingsToggle("Include my region in requests",
                           detail: "Use this Mac’s country and time zone for local results. Never your precise location.",
                           isOn: $settings.shareRegionWithAssistant)
                .help("Send a coarse country or region from this Mac so local searches, prices and units are relevant")
            Divider()
            SettingsToggle("Auto-approve safe browsing",
                           detail: "After you choose Agent mode, safe navigation and searches can continue. Auto also handles supported routine shopping controls; uncertain changes and saved-detail fills still need approval.",
                           isOn: $settings.autoApproveSafeBrowsing)
                .help("Skip approval for low-risk navigation and searches; uncertain changes and saved-detail fills still need approval")
            Text("Chats are saved on this Mac. Page snapshots and browser-action approvals are not saved with them.")
                .settingsSupportingCopy()
        }
    }

    private var matchingShortcuts: [BrowserCommand] {
        let query = shortcutQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        return BrowserCommand.allCases.filter {
            query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
                || $0.settingsGroup.localizedCaseInsensitiveContains(query)
        }
    }

    private var browserShortcutsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                TextField("Find a shortcut", text: $shortcutQuery)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Find a shortcut")
                Button("Reset all") {
                    settings.recordingShortcut = nil
                    settings.browserShortcuts = [:]
                    settings.assistantSidebarShortcut = .default
                    shortcutMessage = nil
                }
                .help("Restore Kestrel's default keyboard shortcuts")
            }
            Text("Click a binding and press your keys. Use Command, Option or Control; arrow keys work too. Escape cancels. Changes save immediately.")
                .settingsSupportingCopy()
            if let shortcutMessage {
                Label(shortcutMessage, systemImage: "exclamationmark.circle")
                    .font(KestrelTypography.chromeDetail)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Shortcut not changed. " + shortcutMessage)
            }
            if matchingShortcuts.isEmpty {
                Text("No shortcuts match “\(shortcutQuery)”.")
                    .settingsSupportingCopy()
                    .padding(.vertical, 20)
            }
            ForEach(["Tabs", "Split view", "Navigation", "Assistant", "Tab selection"], id: \.self) { group in
                let commands = matchingShortcuts.filter { $0.settingsGroup == group }
                if !commands.isEmpty {
                    SettingsCard(group) {
                        VStack(spacing: 6) {
                            ForEach(commands) { command in
                                if command != commands.first { Divider() }
                                shortcutRow(command)
                            }
                        }
                    }
                }
            }
        }
    }

    private func shortcutRow(_ command: BrowserCommand) -> some View {
        HStack(spacing: 12) {
            Text(command.title)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            KeyboardShortcutRecorder(
                isRecording: Binding(
                    get: { settings.recordingShortcut == command },
                    set: { recording in
                        settings.recordingShortcut = recording ? command : nil
                        if recording { shortcutMessage = nil }
                    }
                ),
                shortcut: settings.shortcut(for: command),
                label: command.title,
                onRecord: { shortcut in
                    shortcutMessage = settings.setShortcut(shortcut, for: command)
                    return shortcutMessage == nil
                }
            )
            .frame(width: 145, height: 28)
            Button {
                settings.recordingShortcut = nil
                shortcutMessage = settings.resetShortcut(command)
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .frame(width: 18, height: 18)
            }
            .accessibilityLabel("Reset " + command.title)
            .help("Restore the default shortcut for " + command.title)
            .disabled(settings.shortcut(for: command) == command.defaultShortcut)
        }
    }

    // MARK: - Provider configuration

    private var providerSection: some View {
        SettingsCard("Model and connection") {
            if settings.ai.selectedProvider == .appleLocalModel {
                Label("Runs on this Mac", systemImage: "desktopcomputer")
                    .font(KestrelTypography.chromeLabel.weight(.medium))
                Text("No API key, account login or Kestrel network request is used. Apple chooses the system model automatically. Requires macOS 26 or later, compatible hardware and Apple Intelligence availability.")
                    .settingsSupportingCopy()
            } else {
                ProviderModelPicker(
                    settings: settings,
                    provider: settings.ai.selectedProvider,
                    style: .regular
                )
                if settings.ai.selectedProvider == .codexCLI {
                    codexAccountSection
                } else if settings.ai.selectedProvider == .workBuddyCLI {
                    Text("WorkBuddy uses the opt-in Mac CLI helper to run your configured CodeBuddy executable with its existing sign-in. Only this signed Kestrel build can request it; tools and MCP remain disabled.").settingsSupportingCopy()
                    if CodexRuntime.executableURL != nil {
                        Button("Enable or refresh Mac CLI helper") { codexAccount.enable(refreshCodexAccount: false) }.disabled(codexAccount.isBusy)
                        if codexAccount.isEnabled {
                            Button("Disable Mac CLI helper") { codexAccount.disable() }.disabled(codexAccount.isBusy)
                        }
                        Button("Helper approval in Login Items…") { codexAccount.openApprovalSettings() }
                        if !codexAccount.helperStatus.isEmpty { Text(codexAccount.helperStatus).settingsSupportingCopy() }
                    } else {
                        Text("This build does not include the Mac CLI helper. Install a helper-enabled Kestrel build; direct host execution may be blocked by the sandbox.").settingsSupportingCopy()
                    }
                }
                Divider()
                DisclosureGroup("Connection details") {
                    VStack(alignment: .leading, spacing: 14) {
                        providerConnectionFields
                    }
                    .padding(.top, 10)
                }
            }

            if let issue = settings.ai.displayConfigurationIssueWithoutReadingSecrets() {
                Label(issue, systemImage: "exclamationmark.triangle")
                    .font(KestrelTypography.chromeDetail)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var codexAccountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if CodexRuntime.executableURL != nil {
                Text(codexAccount.status).settingsSupportingCopy()
                HStack {
                    if codexAccount.isBusy {
                        ProgressView().controlSize(.small)
                    } else if codexAccount.requiresApproval {
                        Button("Allow helper in Login Items…") { codexAccount.openApprovalSettings() }
                        Button("Refresh connection") { Task { await codexAccount.refresh() } }
                    } else if codexAccount.helperReady {
                        Button("Refresh connection") { Task { await codexAccount.refresh() } }
                    } else {
                        Button("Use existing Codex sign-in") { codexAccount.enable() }
                            .buttonStyle(.borderedProminent)
                    }
                    if codexAccount.isEnabled && !codexAccount.isBusy {
                        Button("Disable Codex helper") { codexAccount.disable() }
                    }
                }
                Text("Use Agent mode in the Assistant to control the current page. A local Mac helper runs the packaged official Codex runtime using its existing sign-in. Kestrel sends bounded page context and retains its action approvals. The helper accepts only this signed Kestrel build; Kestrel does not read or copy Codex credentials.")
                    .settingsSupportingCopy()
            } else {
                Text("This developer build does not include the Codex runtime. The executable settings below are a fallback for an accessible CLI. Install a build with Codex included to use your existing Codex sign-in.")
                    .settingsSupportingCopy()
            }
        }
        .task { await codexAccount.refresh() }

    }

    @ViewBuilder
    private var providerConnectionFields: some View {
        if settings.ai.selectedProvider == .codexCLI, CodexRuntime.executableURL != nil {
            Text("Uses the official Codex runtime packaged with Kestrel. No API key is needed. Authentication remains managed by Codex in its existing account storage.").settingsSupportingCopy()
        } else if settings.ai.selectedProvider.isCommandLine {
            SettingsField("Executable") {
                TextField("Executable", text: cliExecutableBinding)
                    .help("Path or command name for the CLI executable Kestrel may launch")
            }
            if settings.ai.selectedProvider == .workBuddyCLI {
                Text("Uses your existing CodeBuddy CLI sign-in. Reasoning is medium. Tools, MCP connections and session persistence are disabled; Kestrel owns Agent mode actions and approvals. Host CLI execution may be blocked by the app sandbox.").settingsSupportingCopy()
            } else {
            SettingsField("Arguments") {
                TextEditor(text: argumentTemplateBinding)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 64)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                            .allowsHitTesting(false)
                    }
                    .help("Arguments passed directly to the CLI. Use {prompt} and {model} as placeholders")
            }
            Text("Arguments are passed directly, never through a shell. Use {prompt} and {model} as placeholders. If {prompt} is omitted it is appended. Adjust these defaults for your installed tool if needed.")
                .settingsSupportingCopy()
            }
        } else {
            SettingsField("Base URL") {
                TextField("Base URL", text: optionalStringBinding(\.baseURL))
                    .help("API endpoint for this OpenAI-compatible provider")
            }
            SettingsField("API key environment variable") {
                TextField("API key environment variable", text: stringBinding(\.apiKeyEnvironmentVariable))
                    .help("Environment variable name Kestrel checks for this provider's API key")
            }
            Text("For local development. Only the variable’s name is stored, never its value. The default is \(settings.ai.selectedProvider.defaultEnvironmentVariable).")
                .settingsSupportingCopy()
        }
    }

    // MARK: - Secrets

    private var exaSection: some View {
        SettingsCard("Exa web search") {
            SettingsToggle("Search with Exa", detail: "Use Exa for research when Allow web search is on in Assistant settings.", isOn: $settings.exaSearchEnabled)
                .help("Choose Exa for assistant research searches. Allow web search in Assistant settings must also be on.")
            Text("Image searches and page navigation continue to use the browser.")
                .settingsSupportingCopy()
            HStack(spacing: 7) {
                Circle()
                    .fill(settings.exaSearchEnabled ? ComposerAccessoryPalette.lavender : Color.secondary.opacity(0.45))
                    .frame(width: 7, height: 7)
                Text(!settings.exaSearchEnabled
                    ? "Exa is off; enabled web searches use the browser search engine."
                    : (settings.assistantWebSearchEnabled
                       ? "Exa is enabled for assistant research searches."
                       : "Exa is selected, but web search is off in Assistant settings."))
                    .font(KestrelTypography.chromeDetail.weight(.medium))
                    .foregroundStyle(Color.primary.opacity(0.66))
            }
            Divider()
            SettingsField("Exa API key") {
                SecureField("Paste a new API key", text: $exaKeyDraft)
                    .help("Enter the Exa key to save it in macOS Keychain")
            }
            HStack {
                Button("Save key") {
                    let value = exaKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    let saved = KeychainSecretStore.setSecret(value, account: ExaSearchProvider.keychainAccount)
                    exaKeyDraft = ""
                    exaKeyStatus = saved ? "Saved to Keychain." : "The Keychain rejected the item."
                }
                .help("Store the Exa key in macOS Keychain")
                .disabled(exaKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Remove key") {
                    let removed = KeychainSecretStore.deleteSecret(account: ExaSearchProvider.keychainAccount)
                    exaKeyStatus = removed ? "Removed from Keychain." : "No key was removed."
                }
                .help("Delete the saved Exa key from macOS Keychain")
            }
            if let exaKeyStatus {
                Text(exaKeyStatus).font(KestrelTypography.chromeDetail).foregroundStyle(Color.primary.opacity(0.66))
            }
            Text("Result excerpts and source links go to your selected model. The key stays in Keychain; \(ExaSearchProvider.apiKeyEnvironmentVariable) is also supported for development. Exa may charge for searches. Missing keys and failed requests are shown without silently switching services.")
                .settingsSupportingCopy()
        }
    }

    @ViewBuilder
    private var secretSection: some View {
        if settings.ai.selectedProvider.isHTTP {
            SettingsCard("\(settings.ai.selectedProvider.displayName) API key") {
                #if canImport(Security)
                let provider = settings.ai.settings(for: settings.ai.selectedProvider)
                Text("Saved keys are checked only when you send a request. Opening Settings does not unlock Keychain.")
                    .font(KestrelTypography.chromeDetail)
                    .foregroundStyle(Color.primary.opacity(0.66))

                SettingsField("New API key") {
                    SecureField("Paste a new API key", text: $keyDraft)
                        .help("Enter a replacement key for the selected provider; Kestrel stores it in macOS Keychain")
                }

                HStack {
                    Button("Save to Keychain") { saveKey() }
                        .help("Store this provider key in macOS Keychain")
                        .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Remove from Keychain") { removeKey() }
                        .help("Delete this provider key from macOS Keychain")
                        .disabled(provider.keychainAccount.isEmpty)
                    Spacer()
                }

                if let keyStatusMessage {
                    Text(keyStatusMessage)
                        .font(KestrelTypography.chromeDetail)
                        .foregroundStyle(Color.primary.opacity(0.66))
                }

                Text("The key is written only to the macOS Keychain under the service “\(KeychainSecretStore.service)”. It is never stored in UserDefaults, written to disk by Kestrel, or shown again. Kestrel also reads \(provider.apiKeyEnvironmentVariable) from the environment when no Keychain item exists.")
                    .settingsSupportingCopy()
                #else
                Text("Keychain storage is unavailable on this platform. Set \(settings.ai.settings(for: settings.ai.selectedProvider).apiKeyEnvironmentVariable) in the environment instead.")
                    .settingsSupportingCopy()
                #endif
            }
        }
    }

    // MARK: - Operator

    private var operatorSection: some View {
        SettingsCard("Page context") {
            Text("Visible text from the current page is included when available. Web searches can also include readable results; the amount adjusts to your selected model.")
                .font(KestrelTypography.chromeLabel)

            DisclosureGroup("Privacy details") {
                Text("Page text may be sent to your selected provider, including an online provider. Credential-shaped strings are redacted on a best-effort basis, but this can miss sensitive text. Cookies, storage and hidden form values are not captured.")
                    .settingsSupportingCopy()
                Text("Safe-browsing approval covers low-risk navigation and searches. Auto also handles supported routine shopping controls; uncertain changes and saved-detail fills still require approval.")
                    .settingsSupportingCopy()
            }
        }
    }

    // MARK: - Agent connection

    private var agentMCPSection: some View {
        SettingsCard("Connect Codex") {
            Text("Control Kestrel from the Codex app or Terminal. Connect below, restart Codex, then ask it to use Kestrel’s browser tools. For browsing inside Kestrel, choose Codex in Assistant settings and enable its local helper.")
                .settingsSupportingCopy()

            Text("For example: ‘Use Kestrel to inspect the current page.’ Enable the separate page-text permission below if you want Codex to read it. Requested page changes wait for approval in Kestrel’s Assistant.")
                .settingsSupportingCopy()

            Label("Codex’s config contains a local access token. Treat the file as sensitive.", systemImage: "lock.shield")
                .settingsSupportingCopy()

            Button(isConnectingCodex ? "Connecting…" : "Connect Codex") {
                connectCodex()
            }
            .buttonStyle(.borderedProminent)
            .tint(ComposerAccessoryPalette.lavenderInk)
            .help("Add Kestrel's local browser tools to Codex's managed configuration")
            .disabled(isConnectingCodex)
            .keyboardShortcut(.defaultAction)

            if isCodexRegistered {
                Button("Disconnect Codex", role: .destructive) {
                    disconnectCodex()
                }
                .help("Remove Kestrel's managed browser-tool entry from Codex")
                .disabled(isConnectingCodex)
            }

            Divider()
            SettingsToggle("Enable local MCP connections", detail: "Connect explicitly each launch to unlock the token. Opening Kestrel never reads this Keychain item.", isOn: mcpEnabledBinding)
                .help("Start or stop the loopback-only browser-tool server")
            Label(mcpServer.statusMessage, systemImage: mcpServer.isRunning ? "checkmark.circle" : "network")
                .font(KestrelTypography.chromeDetail)
                .foregroundStyle(mcpServer.isRunning ? .green : .secondary)

            if mcpServer.isRunning, mcpServer.endpointURL != nil {
                LabeledContent("Local endpoint") {
                    Text(mcpServer.displayEndpoint)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .multilineTextAlignment(.trailing)
                }

                SettingsToggle("Share the active tab title and address", isOn: activeTabMetadataBinding)
                    .help("Let connected agents read the active tab's title and address")
                SettingsToggle("Allow agents to read visible page text", isOn: mcpPageReadsBinding)
                    .help("Allow connected agents to request redacted visible text from the active page")

                Text("The endpoint listens only on this Mac. Its random token is kept in Keychain and embedded in Codex's managed config entry. Tab details and page text stay off until enabled here. Page-changing actions always wait for approval in Kestrel.")
                    .settingsSupportingCopy()
            }

            DisclosureGroup("Manual setup and other MCP clients") {
                Text("Kestrel edits only its exact managed entry in ~/.codex/config.toml; it does not read Codex login data. The entry includes the local access token, so protect the config file. If automatic setup is unavailable, copy the local endpoint or CLI command below.")
                    .settingsSupportingCopy()

                if mcpServer.isRunning, let endpoint = mcpServer.endpointURL {
                    HStack {
                        Button("Copy server URL") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(endpoint, forType: .string)
                            mcpConnectionMessage = "Copied the local MCP endpoint. Treat it like a password."
                        }
                            .help("Copy the local MCP endpoint, which includes its access token")

                        Button("Copy CLI command") {
                            let command = KestrelMCPServer.codexSetupCommand(endpointURL: endpoint)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                            mcpConnectionMessage = "Copied. Paste into Terminal, then restart Codex."
                        }
                            .help("Copy the command for adding the local browser tools to Codex")
                    }

                    Button(isTestingMCP ? "Testing…" : "Test Kestrel server", action: testMCPConnection)
                        .help("Check Kestrel's local MCP handshake")
                        .disabled(isTestingMCP)
                    Text("The test checks Kestrel's local MCP handshake; it does not test Codex itself.")
                        .settingsSupportingCopy()
                } else {
                    Text("Connect Codex or enable the local server first to reveal its endpoint.")
                        .settingsSupportingCopy()
                }
            }

            if let mcpConnectionMessage {
                Text(mcpConnectionMessage)
                    .font(KestrelTypography.chromeDetail)
                    .foregroundStyle(Color.primary.opacity(0.66))
            }
        }
    }

    private var mcpEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.agentMCP.isEnabled },
            set: { enabled in
                settings.agentMCP.isEnabled = enabled
                if enabled { mcpServer.start() } else { mcpServer.stop() }
                mcpConnectionMessage = nil
            }
        )
    }

    private func connectCodex() {
        guard !isConnectingCodex else { return }
        isConnectingCodex = true
        mcpConnectionMessage = nil

        let serverWasEnabled = settings.agentMCP.isEnabled
        settings.agentMCP.isEnabled = true
        mcpServer.start()

        Task { @MainActor in
            defer { isConnectingCodex = false }
            for _ in 0..<100 where !mcpServer.isRunning {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            guard mcpServer.isRunning, let endpoint = mcpServer.endpointURL else {
                if !serverWasEnabled {
                    settings.agentMCP.isEnabled = false
                    mcpServer.stop()
                }
                mcpConnectionMessage = "Kestrel could not start its local server: \(mcpServer.statusMessage)"
                return
            }

            do {
                let update = try CodexMCPConfigManager.connect(endpointURL: endpoint)
                isCodexRegistered = true
                switch update {
                case .added, .updated:
                    mcpConnectionMessage = "Kestrel was added to Codex. Restart Codex to load the browser tools."
                case .unchanged:
                    mcpConnectionMessage = "Kestrel is already in Codex. Restart Codex if its tools are not visible yet."
                }
            } catch {
                if !serverWasEnabled {
                    settings.agentMCP.isEnabled = false
                    mcpServer.stop()
                }
                mcpConnectionMessage = error.localizedDescription
            }
        }
    }

    private func disconnectCodex() {
        do {
            let removedEntry = try CodexMCPConfigManager.disconnect()
            isCodexRegistered = false
            if removedEntry {
                settings.agentMCP.isEnabled = false
                mcpServer.stop()
                mcpConnectionMessage = "Removed Kestrel's managed Codex entry and stopped its local server."
            } else {
                mcpConnectionMessage = "No Kestrel-managed entry was found in Codex's config. The local server was left unchanged."
            }
        } catch {
            mcpConnectionMessage = error.localizedDescription
        }
    }

    private var activeTabMetadataBinding: Binding<Bool> {
        Binding(
            get: { settings.agentMCP.sharesActiveTabMetadata },
            set: { settings.agentMCP.sharesActiveTabMetadata = $0 }
        )
    }

    private var mcpPageReadsBinding: Binding<Bool> {
        Binding(
            get: { settings.agentMCP.allowsPageReads },
            set: { settings.agentMCP.allowsPageReads = $0 }
        )
    }

    // MARK: - Passkeys

    @ViewBuilder
    private var passkeysSection: some View {
        SettingsCard("Passkeys") {
            Text("The Chromium engine can receive website WebAuthn requests, but passkey registration and sign-in have not been verified in Kestrel. Apple credential-provider access may require browser capabilities in the signed app.")
                .font(KestrelTypography.chromeDetail)
                .foregroundStyle(Color.primary.opacity(0.66))
            Text("Kestrel does not read or store credentials. If an explicit passkey attempt fails, it can offer to open the page in your default browser.")
                .font(KestrelTypography.chromeDetail)
                .foregroundStyle(Color.primary.opacity(0.66))
        }
    }

    // MARK: - Extensions

    private var extensionsSection: some View {
        SettingsCard("WebExtensions") {
            Label(ExtensionSupport.statusDescription, systemImage: "puzzlepiece.extension")
                .font(KestrelTypography.chromeDetail)
            Divider()
            SettingsToggle("Show the Extensions command menu", isOn: $settings.extensions.menuBarVisible)
                .help("Show or hide the Extensions menu in Kestrel's menu bar")
            #if canImport(CefKit)
            ExtensionPlacementSettings(settings: settings)
            #endif
            SettingsToggle("Allow WebExtension imports", isOn: unpackedBinding)
                .help("Enable importing unpacked folders, ZIP archives and Chromium CRX packages")
                .disabled(!ExtensionSupport.supportsUnpackedWebExtensionDirectories)
            extensionImportControls
            DisclosureGroup("Compatibility and permissions") {
                Text("Kestrel runs extensions in Chromium's Chrome runtime. It accepts Manifest V3 extension folders, ZIP archives and CRX packages. Chromium controls extension APIs, site access prompts and extension lifecycle. Extensions are never exposed to the AI operator.")
                    .settingsSupportingCopy()
                Text("Imports are staged first. Every requested API permission and site pattern starts unselected. Approval stores the extension locally; restart Kestrel to load it into Chromium.")
                    .settingsSupportingCopy()
            }
            if let extensionStatusMessage {
                Text(extensionStatusMessage)
                    .font(KestrelTypography.chromeDetail)
                    .foregroundStyle(Color.primary.opacity(0.66))
            }
        }
    }

    /// Importing is opt-in and always opens the explicit permission review.
    @ViewBuilder
    private var extensionImportControls: some View {
        HStack(spacing: 8) {
            Button("Import WebExtension…") {
                fileImportPurpose = .webExtension
                isImportingFile = true
            }
                .help("Choose an unpacked folder, ZIP archive or Chromium CRX package to review")
                .disabled(!settings.extensions.allowsUnpackedImports || isStagingExtension)
            if isStagingExtension {
                ProgressView().controlSize(.small)
            }
            Spacer()
        }
        Text("Choose a Manifest V3 extension folder, .zip or .crx file. Kestrel copies approved packages to this Mac and loads them after the next restart.")
            .font(KestrelTypography.chromeDetail)
            .foregroundStyle(Color.primary.opacity(0.66))
            if !extensionHost.installed.isEmpty {
                Divider()
                Text("Approved extensions")
                    .font(KestrelTypography.chromeLabel)
                ForEach(extensionHost.installed) { item in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.displayName).font(KestrelTypography.chromeDetail)
                            if let version = item.version {
                                Text("Version \(version)")
                                    .font(KestrelTypography.chromeDetail)
                                    .foregroundStyle(Color.primary.opacity(0.58))
                            }
                        }
                        Spacer(minLength: 8)
                        Button("Remove") { removeInstalledExtension(item) }
                            .buttonStyle(.borderless)
                            .help("Remove this extension from Kestrel and stop loading it after restart")
                    }
                }
                Text("Extensions removed in Chromium's manager can return after restart. Remove them here to remove the approved local package.")
                    .font(KestrelTypography.chromeDetail)
                    .foregroundStyle(Color.primary.opacity(0.66))
            }
    }

    private var extensionImportContentTypes: [UTType] {
        [.folder, .zip] + [UTType(filenameExtension: "crx")].compactMap { $0 }
    }

    private func handleImportSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            extensionStatusMessage = "The package could not be selected: \(error.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            stageImport(url)
        }
    }

    private func testMCPConnection() {
        isTestingMCP = true
        mcpConnectionMessage = "Checking the local MCP endpoint…"
        Task {
            defer { isTestingMCP = false }
            do {
                let toolCount = try await mcpServer.testConnection()
                mcpConnectionMessage = "Kestrel is responding to MCP. \(toolCount) tool(s) are available under the current permissions."
            } catch {
                mcpConnectionMessage = error.localizedDescription
            }
        }
    }

    private func stageImport(_ url: URL) {
        isStagingExtension = true
        extensionStatusMessage = nil
        // `fileImporter` hands back a security-scoped URL. Keep that scope
        // alive while the package waits in the approval sheet.
        if url.startAccessingSecurityScopedResource() {
            securityScopedExtensionURL = url
        }
        Task {
            let resolution = await BrowserExtensionHost.shared.stage(url: url)
            isStagingExtension = false
            switch resolution {
            case .pendingApproval(let preview):
                selectedPermissions = []
                selectedHostPatterns = []
                stagedID = preview.id
                stagedPreview = preview
                extensionStatusMessage = nil
            case .unsupported(let reason), .rejected(let reason):
                endSecurityScope()
                extensionStatusMessage = reason
            }
        }
    }

    private func approveStagedExtension(_ preview: ExtensionInstallPreview) {
        defer {
            stagedPreview = nil
            stagedID = nil
            endSecurityScope()
        }
        do {
            let approved = try BrowserExtensionHost.shared.approve(
                id: preview.id,
                granting: selectedPermissions,
                hostPatterns: selectedHostPatterns
            )
            let version = approved.version.map { " \($0)" } ?? ""
            extensionStatusMessage = "Approved \(approved.displayName)\(version). Granted \(selectedPermissions.count) permission(s) and \(selectedHostPatterns.count) site pattern(s). Restart Kestrel to load it into Chromium."
        } catch {
            BrowserExtensionHost.shared.discard(id: preview.id)
            extensionStatusMessage = "Could not load \(preview.displayName): \(error.localizedDescription)"
        }
    }

    private func removeInstalledExtension(_ item: InstalledChromiumExtension) {
        do {
            try extensionHost.removeInstalled(path: item.path)
            extensionStatusMessage = "Removed \(item.displayName). Restart Kestrel to apply the change to Chromium."
        } catch {
            extensionStatusMessage = "Could not remove \(item.displayName): \(error.localizedDescription)"
        }
    }

    private func discardStagedExtension(_ preview: ExtensionInstallPreview) {
        BrowserExtensionHost.shared.discard(id: preview.id)
        extensionStatusMessage = "Discarded \(preview.displayName) without loading it."
        stagedPreview = nil
        stagedID = nil
        endSecurityScope()
    }

    /// Runs when the sheet is dismissed by any means. If the package was never
    /// approved, it is forgotten without loading.
    private func discardStagedIfNeeded() {
        guard let id = stagedID else { return }
        BrowserExtensionHost.shared.discard(id: id)
        stagedID = nil
        endSecurityScope()
    }

    private func endSecurityScope() {
        guard let url = securityScopedExtensionURL else { return }
        url.stopAccessingSecurityScopedResource()
        securityScopedExtensionURL = nil
    }

    // MARK: - Bindings

    private func stringBinding(_ keyPath: WritableKeyPath<AIProviderSettings, String>) -> Binding<String> {
        Binding(
            get: { settings.ai.settings(for: settings.ai.selectedProvider)[keyPath: keyPath] },
            set: { newValue in
                var provider = settings.ai.settings(for: settings.ai.selectedProvider)
                provider[keyPath: keyPath] = newValue
                settings.ai.update(provider)
            }
        )
    }

    private func optionalStringBinding(_ keyPath: WritableKeyPath<AIProviderSettings, String?>) -> Binding<String> {
        Binding(
            get: { settings.ai.settings(for: settings.ai.selectedProvider)[keyPath: keyPath] ?? "" },
            set: { newValue in
                var provider = settings.ai.settings(for: settings.ai.selectedProvider)
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                provider[keyPath: keyPath] = trimmed.isEmpty ? nil : newValue
                settings.ai.update(provider)
            }
        )
    }

    private var cliExecutableBinding: Binding<String> {
        Binding(
            get: { settings.ai.settings(for: settings.ai.selectedProvider).executablePath ?? "" },
            set: { newValue in
                var provider = settings.ai.settings(for: settings.ai.selectedProvider)
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let value = trimmed.isEmpty ? nil : newValue
                provider.executablePath = value
                settings.ai.update(provider)
            }
        )
    }

    private var argumentTemplateBinding: Binding<String> {
        Binding(
            get: {
                settings.ai.settings(for: settings.ai.selectedProvider).argumentTemplate.joined(separator: " ")
            },
            set: { newValue in
                var provider = settings.ai.settings(for: settings.ai.selectedProvider)
                provider.argumentTemplate = newValue
                    .split(whereSeparator: { $0.isWhitespace })
                    .map(String.init)
                settings.ai.update(provider)
            }
        )
    }

    private var unpackedBinding: Binding<Bool> {
        Binding(
            get: { settings.extensions.allowsUnpackedImports },
            set: { settings.extensions.allowsUnpackedImports = $0 }
        )
    }

    // MARK: - Secrets actions

    private func saveKey() {
        #if canImport(Security)
        let provider = settings.ai.settings(for: settings.ai.selectedProvider)
        // A pasted key often carries a trailing newline; store the cleaned value
        // so the "Invalid API Key" reply is about the key, not the paste.
        let value = APIKeyHygiene.sanitise(keyDraft)
        let saved = KeychainSecretStore.setSecret(value, account: provider.keychainAccount)
        keyDraft = ""
        keyStatusMessage = saved ? "Saved to the Keychain." : "The Keychain rejected the item."
        #endif
    }

    private func removeKey() {
        #if canImport(Security)
        let provider = settings.ai.settings(for: settings.ai.selectedProvider)
        let removed = KeychainSecretStore.deleteSecret(account: provider.keychainAccount)
        keyStatusMessage = removed ? "Removed from the Keychain." : "Nothing was removed."
        #endif
    }
}

private extension View {
    func settingsSupportingCopy() -> some View {
        font(KestrelTypography.chromeDetail)
            .foregroundStyle(Color.primary.opacity(0.66))
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
    }
}

/// A shared text column keeps controls and descriptions aligned across pages.
private struct SettingsRow<Control: View>: View {
    let title: String
    let detail: String?
    let control: Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(KestrelTypography.chromeLabel)
                if let detail { Text(detail).settingsSupportingCopy() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            control.fixedSize(horizontal: true, vertical: false)
        }
    }
}

struct SettingsToggle: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool

    init(_ title: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self._isOn = isOn
    }

    var body: some View {
        SettingsRow(title, detail: detail) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel(title)
        }
    }
}

/// Text fields keep a visible label after a value has been entered.
private struct SettingsField<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(KestrelTypography.chromeLabel)
            content
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(title)
        }
    }
}

/// Soft directional light gives each section depth without glass refraction
/// or competing with the native controls inside it.
private struct SettingsCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        let isDark = colorScheme == .dark
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(KestrelTypography.chromeLabel.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                shape.fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .white.opacity(isDark ? 0.025 : 0.65), radius: 4, x: -2, y: -2)
                    .shadow(color: .black.opacity(isDark ? 0.16 : 0.055), radius: 5, x: 2, y: 3)
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(isDark ? 0.10 : 0.85), .primary.opacity(0.035)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.75
                )
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension BrowserCommand {
    var settingsGroup: String {
        switch self {
        case .newTab, .closeTab, .reopenTab, .nextTab, .previousTab, .toggleSidebar:
            "Tabs"
        case .splitLeft, .splitRight, .separateSplit, .equalSplit:
            "Split view"
        case .focusAddress, .find, .reload, .back, .forward, .zoomIn, .zoomOut, .actualSize, .openDefaultBrowser:
            "Navigation"
        case .assistant, .assistantPage, .clearConversation:
            "Assistant"
        case .tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .tab9:
            "Tab selection"
        }
    }
}

/// The explicit permission-approval sheet for a staged WebExtension.
///
/// It shows the extension's name and version, any parse-time warnings and the
/// complete list of requested API permissions and host patterns. Every
/// checkbox starts off, the extension is loaded only by the approval button,
/// and Cancel discards the staged package without loading it.
private struct ExtensionApprovalSheet: View {
    let preview: ExtensionInstallPreview
    @Binding var selectedPermissions: Set<String>
    @Binding var selectedHostPatterns: Set<String>
    let onApprove: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(preview.displayName)
                    .font(.headline)
                if let extensionID = preview.signedExtensionID {
                    Text("Signed extension ID: \(extensionID)")
                        .font(KestrelTypography.chromeDetail)
                        .textSelection(.enabled)
                }
                Text(preview.version.map { "Version \($0)" } ?? "Version not declared")
                    .font(KestrelTypography.chromeDetail)
                    .foregroundStyle(Color.primary.opacity(0.66))
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !preview.warnings.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Warnings", systemImage: "exclamationmark.triangle")
                                .font(KestrelTypography.chromeLabel.weight(.semibold))
                            ForEach(preview.warnings, id: \.self) { warning in
                                Text(warning).font(KestrelTypography.chromeDetail)
                            }
                        }
                        .foregroundStyle(.orange)
                    }

                    Text("Nothing is loaded until you approve all required permissions and site patterns. Approved extensions load when Kestrel next starts.")
                        .settingsSupportingCopy()

                    if preview.requested.isEmpty {
                        Text("This extension does not request any API permissions or site access. You can approve it as is.")
                            .font(KestrelTypography.chromeLabel)
                    } else {
                        permissionGroup
                        hostPatternGroup
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            HStack {
                Button("Cancel", role: .cancel, action: onDiscard)
                    .help("Discard this staged extension")
                Spacer()
                Button("Approve Import", action: onApprove)
                    .buttonStyle(.borderedProminent)
                    .help("Approve all required permissions and load the extension on the next start")
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .font(KestrelTypography.chromeLabel)
        .tint(ComposerAccessoryPalette.lavenderInk)
        .frame(width: 540, height: preview.requested.isEmpty && preview.warnings.isEmpty ? 260 : 440)
    }

    @ViewBuilder
    private var permissionGroup: some View {
        if !preview.requested.permissions.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Requested API permissions")
                    .font(KestrelTypography.chromeLabel.weight(.semibold))
                ForEach(preview.requested.permissions, id: \.self) { permission in
                    Toggle(permission, isOn: binding(for: permission, in: $selectedPermissions))
                        .font(KestrelTypography.chromeLabel)
                        .help("Allow the extension to use the \(permission) capability")
                }
            }
        }
    }

    @ViewBuilder
    private var hostPatternGroup: some View {
        if !preview.requested.hostPatterns.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Requested site access")
                    .font(KestrelTypography.chromeLabel.weight(.semibold))
                ForEach(preview.requested.hostPatterns, id: \.self) { pattern in
                    Toggle(pattern, isOn: binding(for: pattern, in: $selectedHostPatterns))
                        .font(KestrelTypography.chromeLabel)
                        .help("Allow the extension to run on \(pattern)")
                }
            }
        }
    }

    private func binding(for value: String, in set: Binding<Set<String>>) -> Binding<Bool> {
        Binding(
            get: { set.wrappedValue.contains(value) },
            set: { isOn in
                if isOn {
                    set.wrappedValue.insert(value)
                } else {
                    set.wrappedValue.remove(value)
                }
            }
        )
    }
}

private extension AIProviderKind {
    var defaultEnvironmentVariable: String {
        switch self {
        case .openRouter: return AIDefaults.openRouterAPIKeyEnvironment
        case .mistral: return AIDefaults.mistralAPIKeyEnvironment
        case .googleGemini: return AIDefaults.geminiAPIKeyEnvironment
        case .groq: return AIDefaults.groqAPIKeyEnvironment
        case .deepSeek: return AIDefaults.deepSeekAPIKeyEnvironment
        case .xAI: return AIDefaults.xAIAPIKeyEnvironment
        case .customOpenAI: return AIDefaults.customOpenAIAPIKeyEnvironment
        case .codexCLI, .workBuddyCLI, .kiloCLI: return "not needed"
        case .appleLocalModel: return "not needed"
        }
    }
}

struct KeyboardShortcutRecorder: NSViewRepresentable {
    @Binding var isRecording: Bool
    let shortcut: AssistantSidebarShortcut?
    let label: String
    let onRecord: (AssistantSidebarShortcut) -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.target = context.coordinator
        button.action = #selector(Coordinator.beginRecording(_:))
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        button.focusRingType = .exterior
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        context.coordinator.parent = self
        button.isRecording = isRecording
        button.title = isRecording ? "Press a shortcut…" : (shortcut?.displayName ?? "Set shortcut…")
        button.setAccessibilityLabel(label + " shortcut")
        button.onKeyDown = { [weak coordinator = context.coordinator] key, flags in
            coordinator?.capture(key: key, flags: flags)
        }
        button.onCancel = { [weak coordinator = context.coordinator] in
            coordinator?.parent.isRecording = false
        }
    }

    final class Coordinator: NSObject {
        var parent: KeyboardShortcutRecorder

        init(parent: KeyboardShortcutRecorder) {
            self.parent = parent
        }

        @objc func beginRecording(_ sender: ShortcutRecorderButton) {
            sender.window?.makeFirstResponder(sender)
            parent.isRecording = true
        }

        func capture(key: String, flags: NSEvent.ModifierFlags) {
            let flags = flags.intersection(.deviceIndependentFlagsMask)
            var modifiers: [String] = []
            if flags.contains(.command) { modifiers.append("command") }
            if flags.contains(.option) { modifiers.append("option") }
            if flags.contains(.control) { modifiers.append("control") }
            if flags.contains(.shift) { modifiers.append("shift") }

            let shortcut = AssistantSidebarShortcut(key: key.lowercased(), modifiers: modifiers)
            if parent.onRecord(shortcut) { parent.isRecording = false }
        }
    }
}

final class ShortcutRecorderButton: NSButton {
    var isRecording = false
    var onKeyDown: ((String, NSEvent.ModifierFlags) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        window?.makeFirstResponder(self)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func resignFirstResponder() -> Bool {
        if isRecording { onCancel?() }
        return super.resignFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        guard let characters = event.charactersIgnoringModifiers,
              characters.count == 1 else {
            NSSound.beep()
            return
        }

        onKeyDown?(characters, event.modifierFlags)
    }
}

#endif
