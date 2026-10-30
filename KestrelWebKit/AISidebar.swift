#if canImport(SwiftUI) && canImport(WebKit)

import SwiftUI
import AppKit

/// Shared native system type styles for the browser's sidebars.
enum KestrelTypography {
    static let title = Font.system(.headline, design: .default)
    static let sectionTitle = Font.system(.title3, design: .default)
    static let body = Font.system(.body, design: .default)
    static let callout = Font.system(size: 14, weight: .regular)
    static let subheadline = Font.system(size: 13, weight: .regular)
    static let footnote = Font.system(size: 12, weight: .regular)
    static let caption = Font.system(size: 12, weight: .regular)
    static let code = Font.system(.caption, design: .monospaced)

    // Browser chrome shares a small set of legible native label roles.
    static let chromeLabelSize: CGFloat = 14
    static let chromeLabel = Font.system(size: chromeLabelSize, weight: .regular)
    static let chromeDetail = Font.system(size: 12, weight: .regular)
    static let searchSuggestion = Font.system(size: 15, weight: .regular, design: .default)
    static let addressField = chromeLabel
    static let floatingSearchField = Font.system(size: 18, weight: .regular, design: .default)

    // A dedicated reading scale keeps the full assistant page comfortable
    // without enlarging the compact browser sidecar.
    static let assistantPageTitle = Font.system(size: 24, weight: .semibold, design: .default)
    static let assistantPageBody = Font.system(size: 16, weight: .regular, design: .default)
    static let assistantPageHeading = Font.system(size: 21, weight: .semibold, design: .default)
    static let assistantPageSubheading = Font.system(size: 18, weight: .semibold, design: .default)
    static let assistantPageSupporting = Font.system(size: 15, weight: .regular, design: .default)
    static let assistantPageProgress = Font.system(size: 14, weight: .medium, design: .default)
    static let assistantPageCode = Font.system(size: 14, weight: .regular, design: .monospaced)
    static let assistantPageTable = Font.system(size: 14, weight: .regular, design: .default)
}

/// A browser sidecar for conversation and explicit, approval-gated actions.
struct AISidebar: View {
    @ObservedObject var chat: AIChatStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var browser: BrowserStore
    let width: CGFloat
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var colourScheme
    @FocusState private var inputFocused: Bool
    @State private var modelPickerIsPresented = false
    @State private var historyPopoverIsPresented = false
    @State private var confirmingClearHistory = false
    private var attachments: [NewTabAttachment] {
        get { chat.draftAttachments }
        nonmutating set { chat.draftAttachments = newValue }
    }
    private var attachmentError: String? {
        get { chat.draftAttachmentError }
        nonmutating set { chat.draftAttachmentError = newValue }
    }
    @ObservedObject private var modelCache = ProviderModelCache.shared

    private var attachmentCapacity: AttachmentCapacity {
        .forModel(
            provider: settings.ai.selectedProvider,
            contextWindow: modelCache.contextWindow(for: settings.ai)
        )
    }

    private var attachmentLimitWarning: String? {
        guard attachments.count > attachmentCapacity.maximumFiles else { return nil }
        let overBy = attachments.count - attachmentCapacity.maximumFiles
        let maximum = attachmentCapacity.maximumFiles == 1
            ? "1 file"
            : "up to \(attachmentCapacity.maximumFiles) files"
        let excess = overBy == 1 ? "1 file" : "\(overBy) files"
        return "This model supports \(maximum). Remove \(excess) before sending, or choose a model with a higher limit."
    }

    private var canSend: Bool {
        !chat.isBusy
            && chat.pendingProposal == nil
            && chat.pendingCursorPrompt == nil
            && attachments.count <= attachmentCapacity.maximumFiles
            && (!chat.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    /// The page the conversation is about, as shown by the card pinned under the
    /// header.
    ///
    /// This is deliberately not read straight from `chat.lastPageContext`. The
    /// store clears that at the start of every request — "never carry a previous
    /// page into a new request" — and only refills it when the fresh read comes
    /// back with something, so the card used to vanish the moment a follow-up
    /// was sent, and stay gone whenever that follow-up re-read nothing. The card
    /// describes what the whole conversation is about, so it holds on to the
    /// last page that was actually read.
    @State private var pinnedPageContext: PageContext?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.55)

            if chat.items.isEmpty {
                emptyState
            } else {
                transcript
            }

            if let errorMessage = chat.errorMessage {
                errorBanner(errorMessage)
                    .padding(.horizontal, 13)
                    .padding(.bottom, 8)
            }

            if let proposal = chat.pendingProposal {
                proposalBar(proposal)
                    .padding(.horizontal, 13)
                    .padding(.bottom, 8)
            }

            composer
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 10)
        }
        .frame(width: width)
        .fontDesign(.default)
        .onAppear {
            pinnedPageContext = chat.lastPageContext
        }
        .task(id: chat.currentConversationID) {
            inputFocused = false
            // Wait until the animated sidebar has joined the key window;
            // otherwise WebKit can retain the field-editor focus.
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            inputFocused = true
        }
        .onChange(of: chat.lastPageContext) { _, newValue in
            // Only ever move forward: a request that re-read nothing leaves the
            // card showing the page it was already showing.
            if let newValue, !newValue.isEmpty { pinnedPageContext = newValue }
        }
        .onChange(of: chat.currentConversationID) { _, _ in
            // A different conversation, or a cleared one, starts from whatever
            // it knows about its own page.
            pinnedPageContext = chat.lastPageContext
            historyPopoverIsPresented = false
            modelPickerIsPresented = false
        }
        .confirmationDialog(
            "Delete all saved assistant chats?",
            isPresented: $confirmingClearHistory,
            titleVisibility: .visible
        ) {
            Button("Delete All Chats", role: .destructive) {
                chat.deleteAllSavedConversations()
            }
            .help("Delete every locally saved assistant conversation")
        } message: {
            Text("This removes the locally saved assistant transcripts from this Mac.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 2) {
            Text(chat.conversationTitle ?? "Assistant")
                .font(KestrelTypography.title)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(chat.conversationTitle ?? "Assistant")

            Spacer(minLength: 6)

            SidebarHeaderIcon(
                systemImage: "clock.arrow.circlepath",
                help: "Previous chats",
                accessibilityLabel: "Previous chats",
                isEnabled: chat.canSwitchConversation
            ) {
                historyPopoverIsPresented.toggle()
            }
            .popover(isPresented: $historyPopoverIsPresented, arrowEdge: .bottom) {
                conversationHistoryPopover
            }

            SidebarHeaderIcon(
                systemImage: "square.and.pencil",
                help: "New conversation",
                accessibilityLabel: "New conversation",
                isEnabled: !(chat.items.isEmpty && chat.input.isEmpty && chat.draftAttachments.isEmpty)
            ) {
                chat.clearConversation()
            }

            SidebarHeaderIcon(
                systemImage: "gearshape",
                help: "Assistant settings",
                accessibilityLabel: "Assistant settings"
            ) {
                openSettings()
            }

            SidebarHeaderIcon(
                systemImage: "xmark",
                help: "Hide assistant",
                accessibilityLabel: "Hide assistant",
                symbolSize: 11,
                symbolWeight: .semibold
            ) {
                withAnimation(.snappy(duration: 0.22)) { chat.toggleSidebar() }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 46)
    }

    private var conversationHistoryPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Previous chats")
                    .font(KestrelTypography.title)
                Spacer()
                Button("Clear") { confirmingClearHistory = true }
                    .font(KestrelTypography.callout)
                    .help("Delete all saved chats from this Mac")
                    .disabled(chat.savedConversations.isEmpty)
            }

            if chat.savedConversations.isEmpty {
                ContentUnavailableView(
                    "No saved chats",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Your assistant conversations will appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(chat.savedConversations) { conversation in
                            HStack(spacing: 4) {
                                Button {
                                    chat.openConversation(conversation.id)
                                    historyPopoverIsPresented = false
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(conversation.title)
                                            .font(KestrelTypography.callout)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        if Date.now.timeIntervalSince(conversation.updatedAt) >= 86_400 {
                                            Text(conversation.updatedAt, style: .date)
                                                .font(KestrelTypography.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 8)
                                    .contentShape(RoundedRectangle(cornerRadius: 9))
                                }
                                .buttonStyle(.plain)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                                .help("Reopen chat: \(conversation.title)")

                                Button(role: .destructive) {
                                    chat.deleteSavedConversation(conversation.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 28, height: 34)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Delete chat")
                                .accessibilityLabel("Delete \(conversation.title)")
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(12)
        .frame(width: 270, height: 330)
    }

    // MARK: - Conversation

    /// The transcript itself is shared with the assistant page, so a row type
    /// added for one surface can never go missing from the other. Only the
    /// measurements are the sidecar's own.
    private var transcript: some View {
        AssistantTranscript(chat: chat, settings: settings, style: .sidebar, pageContext: pinnedPageContext)
            .id(chat.currentConversationID)
    }

    private var emptyState: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let issue = chat.configurationIssue {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Assistant setup", systemImage: "gearshape")
                                .font(KestrelTypography.callout)
                            Text(issue)
                                .font(KestrelTypography.footnote)
                                .foregroundStyle(.secondary)
                            Button("Open Settings") { openSettings() }
                                .font(KestrelTypography.callout)
                                .help("Open Kestrel Settings to configure the assistant")
                        }
                        .padding(11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    } else {
                        Text("Ask anything")
                            .font(.system(size: 16, weight: .semibold))
                            .padding(.bottom, 2)
                        Text("Ask about this page or turn on Agent mode to browse.")
                            .font(KestrelTypography.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: max(0, geometry.size.height - 24), alignment: .bottomLeading)
                .padding(12)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: - Banners

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
            Text(message)
                .font(KestrelTypography.footnote)
                .textSelection(.enabled)
            Spacer(minLength: 0)
            Button {
                chat.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss error")
        }
        .padding(10)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func proposalBar(_ proposal: ProposedAction) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let preview = chat.pendingProfileFillPreview, proposal.action == .fillProfile(preview.id) {
                ProfileFillApprovalPreview(preview: preview)
            }
            HStack(spacing: 8) {
                Text("Run this action?")
                    .font(KestrelTypography.footnote)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button("Decline") { chat.declinePendingProposal() }
                    .help("Reject this proposed browser action")
                if proposal.action.kind == .fillProfile {
                    Button("Fill these details") { chat.approvePendingProposal() }
                        .help("Share only the previewed details with this website")
                } else {
                    Button("Approve") { chat.approvePendingProposal() }
                        .help("Allow this proposed browser action to run")
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .buttonStyle(.borderless)
        .font(KestrelTypography.footnote)
        .padding(9)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Approval required for \(proposal.action.summary)")
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            modelPickerRow
                .padding(.horizontal, 12)
            messageBox
        }
    }

    private var modelPickerRow: some View {
        HStack(spacing: 7) {
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    modelPickerIsPresented.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    ProviderMark(provider: settings.ai.selectedProvider, size: 14)
                    AssistantModelSelectionLabel(settings: settings)
                    Image(systemName: modelPickerIsPresented ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(.primary.opacity(0.82))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .modifier(ComposerAccessorySurface(isActive: modelPickerIsPresented))
            .background {
                AssistantModelPopover(isPresented: $modelPickerIsPresented, settings: settings)
            }
            .help("Choose the assistant model or provider")
            .accessibilityLabel("Assistant model: \(settings.ai.selectedProvider.displayName)")
            .accessibilityValue(settings.ai.settings(for: settings.ai.selectedProvider).model)

            Spacer(minLength: 0)

            if let issue = chat.configurationIssue {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .help(issue)
                    .accessibilityLabel("Assistant setup needs attention")
            }
        }
    }

    private var messageBox: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !attachments.isEmpty {
                FadingHorizontalScroll {
                    HStack(spacing: 6) {
                        ForEach(attachments) { attachment in
                            attachmentChip(attachment)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                }
                .frame(height: 38)
                .padding(.horizontal, 7)
                .padding(.top, 7)
                .accessibilityLabel("Attached files")
                .transition(.opacity.combined(with: .offset(y: 4)))
            }

            if let attachmentError = attachmentError ?? attachmentLimitWarning {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text(attachmentError)
                        .font(KestrelTypography.footnote)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .transition(.opacity.combined(with: .offset(y: 4)))
            }

            TextField("Ask a question…", text: $chat.input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(KestrelTypography.chromeLabel)
                .lineLimit(3...6)
                .focused($inputFocused)
                .onSubmit(sendMessage)
                .disabled(chat.isBusy || chat.pendingProposal != nil || chat.pendingCursorPrompt != nil)
                .accessibilityLabel("Assistant message")
                .help("Write a question for the selected assistant")
                .padding(.horizontal, 12)
                .padding(.top, 11)
                .padding(.bottom, 9)

            HStack(spacing: 6) {
                attachmentControl
                browseControl
                Spacer(minLength: 0)
                sendControl
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(ComposerAccessoryPalette.composerSurface(isDark: colourScheme == .dark))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(ComposerAccessoryPalette.composerSurfaceEdge(isDark: colourScheme == .dark), lineWidth: 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(colourScheme == .dark ? 0.035 : 0.82), lineWidth: 0.8)
                .padding(1)
                .allowsHitTesting(false)
        }
        .shadow(color: Color.black.opacity(colourScheme == .dark ? 0.16 : 0.07), radius: 6, x: 0, y: 2)
        .shadow(color: ComposerAccessoryPalette.lavender.opacity(colourScheme == .dark ? 0.025 : 0.09), radius: colourScheme == .dark ? 7 : 10, x: 0, y: 4)
        .animation(.easeInOut(duration: 0.18), value: attachments.count)
        .animation(.easeInOut(duration: 0.18), value: attachmentError)
        .animation(.easeInOut(duration: 0.18), value: attachmentCapacity.maximumFiles)
    }

    private var browseControl: some View {
        AgentModeControl(chat: chat)
    }

    @ViewBuilder
    private var attachmentControl: some View {
        Button(action: uploadFiles) {
            Image(systemName: "paperclip")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(ComposerAccessoryPalette.accessoryForeground(
                    isActive: false,
                    isDark: colourScheme == .dark
                ))
                .scaleEffect(x: -1, y: 1)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(ComposerAccessorySurface(shape: .circle))
        .disabled(
            chat.isBusy || chat.pendingProposal != nil || chat.pendingCursorPrompt != nil
                || attachments.count >= attachmentCapacity.maximumFiles
        )
        .help("Attach files (\(attachments.count) of \(attachmentCapacity.maximumFiles) allowed)")
        .accessibilityLabel("Attach files")
        .accessibilityValue("\(attachments.count) of \(attachmentCapacity.maximumFiles) files")
    }

    @ViewBuilder
    private var sendControl: some View {
        if chat.isBusy {
            Button(action: chat.cancel) {
                Label("Stop", systemImage: "stop.fill")
                    .font(KestrelTypography.footnote.weight(.semibold))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 11)
                    .frame(height: 31)
                    .background(Color.red.opacity(0.09), in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(Color.red.opacity(0.16), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .help("Stop the current assistant or browser action")
            .accessibilityLabel("Stop assistant")
        } else {
            Button(action: sendMessage) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(colourScheme == .dark ? Color.black : Color.white)
                    .frame(width: 32, height: 32)
                    .background(canSend ? Color.primary : Color.secondary.opacity(0.35), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("Send this question to the selected assistant")
            .accessibilityLabel("Send message")
        }
    }

    private func sendMessage() {
        guard !chat.isBusy, chat.pendingProposal == nil, chat.pendingCursorPrompt == nil else { return }
        guard attachments.count <= attachmentCapacity.maximumFiles else { return }
        guard !attachments.isEmpty else {
            chat.send(allowsWebSearch: settings.assistantWebSearchEnabled)
            return
        }

        let prompt = NewTabAttachmentBuilder.question(chat.input, attachments: attachments)
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let pending = attachments
        chat.input = ""
        attachments = []
        attachmentError = nil
        chat.send(
            prompt: prompt,
            attachments: pending,
            maximumAttachmentCharacters: attachmentCapacity.maximumTextCharacters,
            allowsWebSearch: settings.assistantWebSearchEnabled
        )
    }

    private func attachmentChip(_ attachment: NewTabAttachment) -> some View {
        HStack(spacing: 6) {
            NewTabAttachmentThumbnail(attachment: attachment)
            Text(attachment.label)
                .font(KestrelTypography.footnote.weight(.medium))
                .lineLimit(1)
            Button {
                attachments.removeAll { $0.id == attachment.id }
                if attachments.count <= attachmentCapacity.maximumFiles { attachmentError = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .padding(3)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(chat.isBusy || chat.pendingProposal != nil || chat.pendingCursorPrompt != nil)
            .help("Remove \(attachment.label)")
            .accessibilityLabel("Remove \(attachment.label)")
        }
        .foregroundStyle(.primary.opacity(0.85))
        .padding(.leading, 9)
        .padding(.trailing, 6)
        .frame(height: 30)
        .modifier(AttachmentChipSurface())
        .help(attachment.origin)
    }

    private func uploadFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.resolvesAliases = true
        panel.allowedContentTypes = NewTabAttachmentBuilder.selectableContentTypes()
        panel.allowsOtherFileTypes = false
        panel.message = "Choose images, PDFs, Office documents or text files to add to your question"
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }

        var failure: String?
        for url in panel.urls {
            guard attachments.count < attachmentCapacity.maximumFiles else {
                failure = NewTabAttachmentError
                    .tooMany(limit: attachmentCapacity.maximumFiles)
                    .errorDescription
                break
            }
            do {
                let attachment = try NewTabAttachmentBuilder.attachment(
                    forFileAt: url,
                    existingCount: attachments.count
                )
                if !attachments.contains(where: { $0.origin == attachment.origin }) {
                    attachments.append(attachment)
                }
            } catch {
                failure = (error as? LocalizedError)?.errorDescription
                    ?? "Kestrel could not read “\(url.lastPathComponent)”."
            }
        }
        attachmentError = failure
    }

}

enum AssistantMarkdownParser {
    enum Content: Equatable {
        case paragraph(String)
        case heading(level: Int, text: String)
        /// `depth` is the nesting level, so a sub-list can be indented instead
        /// of collapsing onto the same margin as its parent.
        case bullet(depth: Int, text: String)
        case numbered(depth: Int, number: Int, text: String)
        case quote(String)
        case code(String)
        case table(headers: [String], rows: [[String]])
        /// A thematic break — the `---` models put between sections.
        case rule
    }

    struct Block: Identifiable, Equatable {
        let id: Int
        let content: Content
    }

    static func parse(_ markdown: String) -> [Block] {
        let normalised = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let lines = repairingProse(in: normalised.components(separatedBy: "\n"))

        var blocks: [Block] = []
        var paragraphLines: [String] = []
        var codeLines: [String] = []
        var isInsideCodeFence = false

        func append(_ content: Content) {
            blocks.append(Block(id: blocks.count, content: content))
        }

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            let paragraph = paragraphLines.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            paragraphLines.removeAll(keepingCapacity: true)
            for readableParagraph in readableParagraphs(paragraph) {
                append(.paragraph(readableParagraph))
            }
        }

        func flushCode() {
            guard !codeLines.isEmpty else { return }
            append(.code(codeLines.joined(separator: "\n")))
            codeLines.removeAll(keepingCapacity: true)
        }

        var index = 0
        while index < lines.count {
            let rawLine = lines[index]
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```") {
                flushParagraph()
                if isInsideCodeFence {
                    flushCode()
                    isInsideCodeFence = false
                } else {
                    isInsideCodeFence = true
                }
                index += 1
                continue
            }

            if isInsideCodeFence {
                codeLines.append(rawLine)
                index += 1
                continue
            }

            guard !line.isEmpty else {
                flushParagraph()
                index += 1
                continue
            }

            let headingLevel = line.prefix(while: { $0 == "#" }).count
            if (1...6).contains(headingLevel), line.dropFirst(headingLevel).first == " " {
                flushParagraph()
                append(.heading(
                    level: headingLevel,
                    text: String(line.dropFirst(headingLevel)).trimmingCharacters(in: .whitespaces)
                ))
                index += 1
                continue
            }

            // Checked before the list rules, because a table row can begin with
            // a dash in the delimiter line.
            if let table = table(at: index, in: lines) {
                flushParagraph()
                append(.table(headers: table.headers, rows: table.rows))
                index += table.consumed
                continue
            }

            // Also before the list rules: `* * *` is a thematic break, and the
            // bullet rule would otherwise read it as a bullet whose text is
            // "* *".
            if isThematicBreak(line) {
                flushParagraph()
                append(.rule)
                index += 1
                continue
            }

            if let marker = line.range(of: #"^[-*+]\s+"#, options: .regularExpression) {
                flushParagraph()
                append(.bullet(depth: listDepth(of: rawLine), text: String(line[marker.upperBound...])))
                index += 1
                continue
            }

            // At most three digits. Four is a year: markdown reads "2026. That
            // was the year" as an ordered list starting at 2026, and a sentence
            // is not a list item.
            if let marker = line.range(of: #"^\d{1,3}[.)]\s+"#, options: .regularExpression) {
                flushParagraph()
                let number = Int(line[..<marker.upperBound].prefix(while: \.isNumber)) ?? 1
                append(.numbered(
                    depth: listDepth(of: rawLine),
                    number: number,
                    text: String(line[marker.upperBound...])
                ))
                index += 1
                continue
            }

            if line.hasPrefix("> ") {
                flushParagraph()
                append(.quote(String(line.dropFirst(2))))
                index += 1
                continue
            }

            paragraphLines.append(line)
            index += 1
        }

        flushParagraph()
        flushCode()
        return blocks
    }

    /// Builds a readable VoiceOver label from the rendered Markdown blocks.
    /// Keep headings, list items, quotes, code and tables identifiable without
    /// announcing Markdown delimiters such as `#`, `**` or backticks.
    static func accessibilityText(_ markdown: String) -> String {
        parse(markdown).compactMap { block in
            switch block.content {
            case .paragraph(let text):
                return plainInlineText(text)
            case .heading(_, let text):
                return "Heading: \(plainInlineText(text))"
            case .bullet(_, let text):
                return "List item: \(plainInlineText(text))"
            case .numbered(_, let number, let text):
                return "List item \(number): \(plainInlineText(text))"
            case .quote(let text):
                return "Quote: \(plainInlineText(text))"
            case .code(let text):
                return "Code block: \(text)"
            case .table(let headers, let rows):
                let columns = headers.map(plainInlineText).joined(separator: ", ")
                let rowText = rows.enumerated().map { index, row in
                    let cells = zip(headers, row).map { header, value in
                        "\(plainInlineText(header)): \(plainInlineText(value))"
                    }
                    return "Row \(index + 1): " + cells.joined(separator: ", ")
                }.joined(separator: ". ")
                return rowText.isEmpty
                    ? "Table with columns: \(columns)"
                    : "Table with columns: \(columns). \(rowText)"
            case .rule:
                return nil
            }
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    private static func plainInlineText(_ source: String) -> String {
        let attributed = (try? AttributedString(markdown: source)) ?? AttributedString(source)
        return String(AssistantMarkdownLinks.plainText(attributed).characters)
    }

    // MARK: - Prose repairs

    /// Repairs the run-on sentences some models emit, without touching code.
    ///
    /// These repairs used to run over the whole document before it was parsed,
    /// which rewrote the user's code: a full stop before a capital turned
    /// `obj.Method()` into `obj. Method()`, and a colon before a capital turned
    /// `init(frame:CGRect)` into `init(frame: CGRect)`. A missing space in prose
    /// is a blemish; silently editing someone's code is a bug.
    static func repairingProse(in lines: [String]) -> [String] {
        var output: [String] = []
        var isInsideCodeFence = false
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                isInsideCodeFence.toggle()
                output.append(line)
                continue
            }
            guard !isInsideCodeFence else {
                output.append(line)
                continue
            }
            output.append(contentsOf: repair(line).components(separatedBy: "\n"))
        }
        return output
    }

    /// Repairs one line of prose, leaving code spans alone.
    ///
    /// Splitting on a backtick alternates prose and code, so every odd piece is
    /// left exactly as the model wrote it. Joining the pieces back with a
    /// backtick restores the span delimiters, including a lone unbalanced
    /// backtick, which a line like "5 ` 3" contains.
    private static func repair(_ line: String) -> String {
        var pieces: [String] = []
        var followsCodeSpan = false

        for (index, piece) in line.components(separatedBy: "`").enumerated() {
            guard index.isMultiple(of: 2) else {
                pieces.append(piece)
                followsCodeSpan = true
                continue
            }

            // The backticks belong to the neighbouring pieces, so a full stop at
            // the start of this one has lost the character it follows. Hand the
            // spacing rules a stand-in for it: in "see `x`.Then" that full stop
            // follows a word, and it has to keep looking like one.
            let context = followsCodeSpan ? "xx" : ""
            let repaired = repairingSpacing(in: context + repairingBoldRuns(in: piece))
            pieces.append(String(repaired.dropFirst(context.count)))
            followsCodeSpan = false
        }

        return pieces.joined(separator: "`")
    }

    /// Splits a bold run from the sentence glued to it.
    ///
    /// Models write `**Summary**On 18 September` — a bold run run straight into
    /// the next sentence. The lookbehind is what stops a *closing* `**` from
    /// being read as an opening one: without it, `**Mars**, **Earth**` pairs the
    /// end of Mars with the start of Earth and breaks the line in the middle of
    /// a sentence, leaving the rest of the asterisks on screen as literal text.
    private static func repairingBoldRuns(in text: String) -> String {
        text.replacingOccurrences(
            of: #"(?<![\w*])\*\*[^*\n]{1,48}\*\*(?=[A-Z])"#,
            with: "$0\n\n",
            options: .regularExpression
        )
    }

    /// Puts back the space a model left out between two sentences.
    ///
    /// Both rules fire only after two lowercase letters, which is what keeps
    /// them off the dots that are not sentence endings. Looking merely for a
    /// capital after the dot turns `README.MD` into `README. MD` and
    /// `https://example.com/a.B` into `.../a. B`.
    private static func repairingSpacing(in text: String) -> String {
        text
            .replacingOccurrences(
                of: #"(?<=[a-z]{2})([.!?])(?=[A-Z])"#,
                with: "$1 ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"(?<=[a-z]{2})(:)(?=[A-Z])"#,
                with: "$1 ",
                options: .regularExpression
            )
    }

    // MARK: - Lists and tables

    /// How far a list item is indented, in levels.
    ///
    /// Models nest with anything from two to four spaces, so the indentation is
    /// bucketed rather than trusted: one level per two columns, capped, so a
    /// deeply nested list cannot march off the side of a narrow sidebar.
    static func listDepth(of line: String) -> Int {
        var columns = 0
        for character in line {
            if character == " " {
                columns += 1
            } else if character == "\t" {
                columns += 3
            } else {
                break
            }
        }
        return min(columns / 2, 3)
    }

    /// A pipe table, if one starts at this line.
    ///
    /// A header row alone is not enough: markdown requires a delimiter row of
    /// dashes beneath it, and insisting on that is what stops a sentence that
    /// happens to contain a pipe from being read as a table.
    static func table(
        at index: Int,
        in lines: [String]
    ) -> (headers: [String], rows: [[String]], consumed: Int)? {
        guard index + 1 < lines.count else { return nil }
        let headers = tableCells(lines[index])
        guard headers.count >= 2 else { return nil }
        guard isTableDelimiter(lines[index + 1], columns: headers.count) else { return nil }

        var rows: [[String]] = []
        var cursor = index + 2
        while cursor < lines.count {
            let cells = tableCells(lines[cursor])
            // `tableCells` returns nothing at all for a line without a pipe, so
            // this is the rule that ends the table — and therefore the rule
            // that stops the prose after it from being swallowed. A row with
            // too few cells is padded rather than rejected: models emit ragged
            // tables, and dropping a row loses data.
            guard !cells.isEmpty else { break }
            rows.append(cells.count == headers.count
                ? cells
                : cells.count > headers.count
                    ? Array(cells.prefix(headers.count))
                    : cells + Array(repeating: "", count: headers.count - cells.count))
            cursor += 1
        }
        return (headers, rows, cursor - index)
    }

    private static func tableCells(_ line: String) -> [String] {
        var value = line.trimmingCharacters(in: .whitespaces)
        guard value.contains("|") else { return [] }
        if value.hasPrefix("|") { value.removeFirst() }
        if value.hasSuffix("|") { value.removeLast() }
        return value
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func isTableDelimiter(_ line: String, columns: Int) -> Bool {
        let cells = tableCells(line)
        guard cells.count == columns else { return false }
        return cells.allSatisfy { cell in
            !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    /// A thematic break: three or more of `-`, `*` or `_`, spaces allowed
    /// between them.
    ///
    /// Without this the line is prose, and a model's section separator renders
    /// as a literal row of dashes across the sidebar.
    static func isThematicBreak(_ line: String) -> Bool {
        let compact = line.filter { !$0.isWhitespace }
        guard compact.count >= 3, let marker = compact.first else { return false }
        guard marker == "-" || marker == "*" || marker == "_" else { return false }
        return compact.allSatisfy { $0 == marker }
    }

    private static func readableParagraphs(_ paragraph: String) -> [String] {
        guard paragraph.count > 420,
              let sentenceBoundary = try? NSRegularExpression(
                pattern: #"(?<=[.!?])\s+(?=[A-Z0-9“‘])"#
              ) else {
            return [paragraph]
        }

        let source = paragraph as NSString
        let boundaries = sentenceBoundary.matches(
            in: paragraph,
            range: NSRange(location: 0, length: source.length)
        )
        guard boundaries.count >= 4 else { return [paragraph] }

        var sentences: [String] = []
        var start = 0
        for boundary in boundaries {
            let range = NSRange(location: start, length: boundary.range.location - start)
            let sentence = source.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { sentences.append(sentence) }
            start = NSMaxRange(boundary.range)
        }
        let remainder = source.substring(from: start).trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainder.isEmpty { sentences.append(remainder) }
        guard sentences.count >= 5 else { return [paragraph] }

        var paragraphs: [String] = []
        var current = ""
        var sentenceCount = 0
        for sentence in sentences {
            if !current.isEmpty && (current.count + sentence.count + 1 > 280 || sentenceCount >= 3) {
                paragraphs.append(current)
                current = ""
                sentenceCount = 0
            }
            current = current.isEmpty ? sentence : "\(current) \(sentence)"
            sentenceCount += 1
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs
    }
}

/// Inline markdown — bold, italics, code spans — rendered as a `Text`.
///
/// Shared by the prose blocks and by table cells, so `**bold**` reads the same
/// inside a table as it does in a paragraph. Falls back to the raw string when
/// the model emits something `AttributedString` refuses to parse; a stray
/// asterisk on screen beats a blank cell.
///
/// Links are flattened to their text. A citation belongs in the source cards
/// under the answer, where it is a deliberate target; a link buried in a
/// sentence duplicates that surface and is easy to hit by accident.
private func assistantInlineMarkdown(_ source: String) -> Text {
    var formatted = (try? AttributedString(markdown: source)) ?? AttributedString(source)
    formatted = AssistantMarkdownLinks.plainText(formatted)
    return Text(formatted)
}

/// Removes hyperlink styling from parsed Markdown while keeping its text.
enum AssistantMarkdownLinks {
    static func plainText(_ attributed: AttributedString) -> AttributedString {
        var result = attributed
        for run in attributed.runs where run.link != nil {
            result[run.range].link = nil
            result[run.range].underlineStyle = nil
            result[run.range].foregroundColor = nil
        }
        return result
    }
}

/// Renders an assistant reply's Markdown.
///
/// Not private: `AssistantTranscript` in `AssistantChatPage.swift` draws the
/// assistant page's rows with it, so a reply looks the same wherever it is
/// read.
struct AssistantMarkdownView: View {
    let markdown: String
    let style: AssistantTranscript.Style

    private var blocks: [AssistantMarkdownParser.Block] {
        AssistantMarkdownParser.parse(markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: style == .page ? 14 : 10) {
            ForEach(blocks) { block in
                blockView(block.content)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ content: AssistantMarkdownParser.Content) -> some View {
        switch content {
        case .paragraph(let text):
            assistantInlineMarkdown(text)
                .font(style.bodyFont)
                .lineSpacing(style == .page ? 6 : 4)
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let level, let text):
            assistantInlineMarkdown(text)
                .font(style.headingFont(level: level))
                .padding(.top, style == .page ? 8 : 5)
                .fixedSize(horizontal: false, vertical: true)

        case .bullet(let depth, let text):
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(depth == 0 ? "•" : "◦")
                    .font(style.bodyFont.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 9, alignment: .leading)
                assistantInlineMarkdown(text)
                    .font(style.bodyFont)
                    .lineSpacing(style == .page ? 5 : 3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 3 + CGFloat(depth) * 14)

        case .numbered(let depth, let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number).")
                    .font(style.calloutFont.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 18, alignment: .trailing)
                assistantInlineMarkdown(text)
                    .font(style.bodyFont)
                    .lineSpacing(style == .page ? 5 : 3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 14)

        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                Capsule()
                    .fill(Color.primary.opacity(0.16))
                    .frame(width: 2)
                assistantInlineMarkdown(text)
                    .font(style.calloutFont)
                    .foregroundStyle(.secondary)
                    .lineSpacing(style == .page ? 5 : 3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)

        case .table(let headers, let rows):
            AssistantTableView(headers: headers, rows: rows, style: style)

        case .rule:
            Rectangle()
                .fill(Color.primary.opacity(0.13))
                .frame(height: 1)
                .padding(.vertical, 3)

        case .code(let text):
            // Code scrolls sideways rather than wrapping. A wrapped line of code
            // is worse than no line of code: the indentation that carries the
            // meaning is what disappears first.
            ScrollView(.horizontal) {
                Text(text)
                    .font(style.codeFont)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(10)
            }
            .scrollIndicators(.never)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

/// A markdown pipe table, drawn as a bordered grid that fits the sidebar.
///
/// A sidebar is roughly 320 points wide, which is narrower than most tables a
/// model will emit. Two decisions follow from that:
///
/// * Up to three columns the cells share the width equally. Equal columns are
///   not ideal typography, but they are *predictable* — every cell wraps and
///   nothing ever leaves the sidebar, which is what matters when the reader
///   cannot widen the pane.
/// * Past three columns an equal split squeezes every cell to about the width
///   of a word, so the grid stops shrinking and scrolls sideways at a legible
///   column width instead. Same trade the code blocks make.
private struct AssistantTableView: View {
    let headers: [String]
    let rows: [[String]]
    let style: AssistantTranscript.Style

    private static let maximumFittingColumns = 3
    private var scrolledColumnWidth: CGFloat { style == .page ? 160 : 108 }

    private var columnCount: Int { max(headers.count, 1) }
    private var scrollsSideways: Bool { columnCount > Self.maximumFittingColumns }

    var body: some View {
        if headers.isEmpty {
            EmptyView()
        } else {
            Group {
                if scrollsSideways {
                    ScrollView(.horizontal) {
                        grid
                            .frame(width: CGFloat(columnCount) * scrolledColumnWidth)
                    }
                    .scrollIndicators(.never)
                } else {
                    grid
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.7)
            }
        }
    }

    private var grid: some View {
        VStack(spacing: 0) {
            row(headers, isHeader: true)

            ForEach(Array(rows.enumerated()), id: \.offset) { _, cells in
                Rectangle()
                    .fill(Color.primary.opacity(0.09))
                    .frame(height: 0.7)
                row(cells, isHeader: false)
            }
        }
    }

    private func row(_ cells: [String], isHeader: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<columnCount, id: \.self) { column in
                cellView(
                    column < cells.count ? cells[column] : "",
                    isHeader: isHeader,
                    isFirst: column == 0
                )
            }
        }
        .background(isHeader ? Color.primary.opacity(0.055) : Color.clear)
    }

    private func cellView(_ text: String, isHeader: Bool, isFirst: Bool) -> some View {
        assistantInlineMarkdown(text)
            .font(style.tableFont.weight(isHeader ? .semibold : .regular))
            .foregroundStyle(isHeader ? Color.primary : Color.secondary)
            .lineSpacing(style == .page ? 4 : 2)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                if !isFirst {
                    Rectangle()
                        .fill(Color.primary.opacity(0.09))
                        .frame(width: 0.7)
                }
            }
    }
}

struct PageContextCard: View {
    let context: PageContext
    let faviconURL: URL?

    private var components: URLComponents? {
        URLComponents(string: context.url)
    }

    private var host: String {
        let value = components?.host ?? context.url
        return value.hasPrefix("www.") ? String(value.dropFirst(4)) : value
    }

    private var title: String {
        let query = components?.queryItems?.first(where: { $0.name == "q" || $0.name == "query" })?.value
        if let query, !query.isEmpty { return query }
        return context.title.isEmpty ? host : context.title
    }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let faviconURL {
                    AsyncImage(url: faviconURL) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFit().padding(7)
                        } else {
                            Image(systemName: "globe").foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Image(systemName: "globe")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 34, height: 34)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.7)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(KestrelTypography.callout)
                    .lineLimit(1)
                Text(host)
                    .font(KestrelTypography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: 290, alignment: .leading)
        .background(Color.primary.opacity(0.075), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page context: \(title), \(host)")
    }
}

struct ProviderMark: View {
    let provider: AIProviderKind
    var size: CGFloat = 16
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            switch provider {
            case .codexCLI:
                templateMark("ProviderOpenAI")
            case .workBuddyCLI:
                Image(systemName: "terminal").resizable().scaledToFit()
            case .kiloCLI:
                templateMark("ProviderKilo")
            case .openRouter:
                assetMark(colorScheme == .dark ? "ProviderOpenRouterDark" : "ProviderOpenRouter")
                    .resizable()
                    .scaledToFit()
            case .mistral:
                assetMark("ProviderMistral")
                    .resizable()
                    .scaledToFit()
            case .googleGemini:
                templateMark("ProviderGemini")
            case .groq:
                templateMark("ProviderGroq")
            case .deepSeek:
                templateMark("ProviderDeepSeek")
            case .xAI:
                templateMark("ProviderXAI")
            case .customOpenAI:
                templateMark("ProviderOpenAI")
            case .appleLocalModel:
                if #available(macOS 26.0, *) {
                    Image(systemName: "apple.intelligence")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.primary)
                } else {
                    Image(systemName: "sparkles")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.primary)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func templateMark(_ name: String) -> some View {
        assetMark(name)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(.primary)
    }

    private func assetMark(_ name: String) -> Image {
#if SWIFT_PACKAGE
        Image(name, bundle: KestrelAssets.bundle)
#else
        Image(name)
#endif
    }
}

/// Three dots breathing in sequence while the assistant works.
///
/// The loop is derived from the clock in `TimelineView` rather than from
/// animated state, so there is nothing to start or stop and the view cannot
/// leave a repeating animation behind when it disappears mid-request — which a
/// `repeatForever` on a row that is about to be replaced very much can.
struct ThinkingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var dotSize: CGFloat = 5
    var spacing: CGFloat = 4
    var tint: Color = .secondary

    /// One dot's fade, and the gap between the dots' phases.
    private static let cycle: Double = 1.15
    private static let dotCount = 3
    /// Thirty a second is smooth for three dots and leaves the rest of the
    /// sidebar alone.
    private static let frameInterval: Double = 1.0 / 30.0

    var body: some View {
        TimelineView(.animation(minimumInterval: Self.frameInterval, paused: reduceMotion)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: Self.cycle) / Self.cycle

            HStack(spacing: spacing) {
                ForEach(0..<Self.dotCount, id: \.self) { index in
                    let offset = Double(index) / Double(Self.dotCount)
                    let local = (phase + offset).truncatingRemainder(dividingBy: 1)
                    // A smooth bump per cycle: each dot rises, peaks and settles
                    // a third of a cycle apart, so the eye reads a wave moving
                    // along the row rather than three dots blinking together.
                    let lift = reduceMotion ? 0.5 : (1 - cos(local * 2 * .pi)) / 2

                    Circle()
                        .fill(tint.opacity(0.28 + 0.72 * lift))
                        .frame(width: dotSize, height: dotSize)
                        .scaleEffect(reduceMotion ? 1 : 0.82 + 0.24 * lift)
                }
            }
        }
        // Reserve the row's full height so the label beside it does not shift
        // as the dots scale.
        .frame(height: dotSize * 1.5)
        .accessibilityHidden(true)
    }
}

/// One control in a sidebar header.
///
/// Every glyph gets the same square hit area and the same hover highlight, so a
/// row of differently shaped SF Symbols still reads as an evenly spaced,
/// aligned set instead of a ragged line of icons. The glyph size is a
/// parameter because optically equal weight is not the same as equal point
/// size: a cross needs to be a little smaller than a gear to look the same.
private struct SidebarHeaderIcon: View {
    let systemImage: String
    let help: String
    let accessibilityLabel: String
    var symbolSize: CGFloat = 12
    var symbolWeight: Font.Weight = .medium
    var isEnabled = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: symbolSize, weight: symbolWeight))
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isHovering && isEnabled ? Color.primary.opacity(0.07) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(accessibilityLabel)
    }
}

#endif
